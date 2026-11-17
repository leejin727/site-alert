"""'이거 할래': 공지를 프롬프트 B로 할 일 분해해 사용자의 할 일(tasks)로 담는 모듈.

분해 결과는 공지 단위(task_breakdowns)로 한 번만 만들고, 사용자가 담을 때 그 결과를 복사합니다.
근거(evidence)가 없거나 원문에서 찾을 수 없는 할 일은 저장하지 않고 로그를 남깁니다.
"""
import logging
import os
import re
from datetime import date, datetime, time
from pathlib import Path
from typing import Optional

from google import genai
from google.genai import types
from pydantic import BaseModel, Field
from sqlalchemy import text
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlmodel import Session, delete, func, select

from serve.analyze import FALLBACK_MODEL, MODEL, load_body, run_with_retry
from serve.models import NoticeDeadline, Post, PostAnalysis, Site, Task, TaskBreakdown, now_utc
from serve.rss import homepage_url
from serve.schedule import plan_dates, today_kst

logger = logging.getLogger("uvicorn.error")

# 프롬프트 A(analyze.py)와 따로 바꿔 가며 비교하므로 버전도 따로 관리. 예: TASK_PROMPT_VERSION=v2
TASK_PROMPT_VERSION = os.getenv("TASK_PROMPT_VERSION", "v1")
TASK_PROMPT = (Path(__file__).with_name("prompts") / "tasks" / f"{TASK_PROMPT_VERSION}.txt").read_text(encoding="utf-8")
# 사용자가 화면에서 기다리므로 빠른 모델이 먼저 (기본 모델은 수 분씩 걸릴 때가 있음). 계속 실패하면 공지 분석용 기본 모델로
TASK_MODEL = os.getenv("TASK_GEMINI_MODEL", FALLBACK_MODEL)
IMAGE_PREFIX = "(이미지)"  # 이미지에서 읽은 근거는 원문 텍스트가 없어 대조할 수 없음
EDITABLE_FIELDS = ("title", "note", "scheduled_date")  # 바꾸면 edited_fields에 기록 (is_done은 일반 사용이라 제외)


class BreakdownItem(BaseModel):
    title: str = Field(description="해야 할 일 하나. 짧은 명령형. 예: '재학증명서 발급'")
    deadline_index: Optional[int] = Field(description="[마감 목록]에서 이 할 일이 속한 마감의 번호. 없으면 null")
    evidence: str = Field(description="이 할 일이 나온 원문 문구 그대로")


class BreakdownResult(BaseModel):
    tasks: list[BreakdownItem] = Field(description="학생이 해야 할 일 목록 (해야 하는 순서대로). 없으면 빈 배열")


class NotAnalyzedError(Exception):
    """공지 분석(프롬프트 A) 결과가 아직 없음."""


class BreakdownError(Exception):
    """Gemini로 할 일 분해를 하지 못함."""


def format_deadlines(deadlines: list[NoticeDeadline]) -> str:
    lines = []
    for d in deadlines:
        when = " ".join(str(v) for v in (d.deadline_date or "날짜 미정", d.deadline_time) if v)
        lines.append(f"{d.deadline_order}. {d.label}: {when} (근거: {d.evidence or '없음'})")
    return "\n".join(lines) or "(없음)"


def request_breakdown(post: Post, board: str, apply_method: str, deadlines: list[NoticeDeadline]) -> tuple[BreakdownResult, str, str]:
    """본문을 가져와 프롬프트 B로 Gemini 호출. 반환: (결과, 사용 모델, 근거 대조용 원문)"""
    if not os.getenv("GEMINI_API_KEY"):
        raise BreakdownError("GEMINI_API_KEY가 없습니다")
    body, attachments, _, images = load_body(post)
    prompt = TASK_PROMPT.format(
        board=board, title=post.title or "알 수 없음", apply_method=apply_method,
        deadlines=format_deadlines(deadlines), attachments=", ".join(attachments) or "없음", body=body or "(본문 없음)",
    )
    contents = [prompt, *[types.Part.from_bytes(data=data, mime_type=mime) for mime, data in images]] if images else prompt
    try:
        result, used_model = run_with_retry(genai.Client(), contents, BreakdownResult, models=(TASK_MODEL, MODEL))
    except Exception as e:
        raise BreakdownError(f"Gemini 호출 실패: {str(e)[:200]}") from e
    return result, used_model, "\n".join([post.title, body, *attachments])


def squash(text: str) -> str:
    return re.sub(r"\s+", "", text)  # 줄바꿈·공백 차이는 무시하고 대조


def validate_items(notice_id: int, items: list[BreakdownItem], source_text: str, n_deadlines: int) -> list[dict]:
    """근거가 없거나 원문에 없는 항목은 버리고 로그를 남김. 반환: 저장할 항목 목록"""
    source = squash(source_text)
    kept = []
    for item in items:
        title, evidence = item.title.strip(), item.evidence.strip()
        if not title or not evidence:
            logger.warning("[할일분해] 공지 %s: '%s' 제외 (제목 또는 근거 없음)", notice_id, title)
            continue
        if not evidence.startswith(IMAGE_PREFIX) and squash(evidence) not in source:
            logger.warning("[할일분해] 공지 %s: '%s' 제외 (근거가 원문에 없음: %s)", notice_id, title, evidence[:80])
            continue
        index = item.deadline_index
        if index is not None and not 0 <= index < n_deadlines:
            logger.warning("[할일분해] 공지 %s: '%s' 마감 번호 %s가 범위 밖이라 연결하지 않음", notice_id, title, index)
            index = None
        kept.append({"title": title, "deadline_index": index, "evidence": evidence})
    return kept


def user_tasks(session: Session, user_id: int, notice_id: int) -> list[Task]:
    return session.exec(
        select(Task).where(Task.user_id == user_id, Task.notice_id == notice_id).order_by(Task.task_order, Task.id)
    ).all()


def generate_breakdown(session: Session, post: Post, analysis: PostAnalysis) -> TaskBreakdown:
    """Gemini로 분해하고 공지 단위 결과를 저장(같은 공지는 갱신). 커밋은 호출한 쪽에서."""
    deadlines = session.exec(
        select(NoticeDeadline).where(NoticeDeadline.notice_id == post.id).order_by(NoticeDeadline.deadline_order)
    ).all()
    board = session.get(Site, post.site_id).name
    result, used_model, source_text = request_breakdown(post, board, analysis.result.get("apply_method", "불명확"), deadlines)
    kept = validate_items(post.id, result.tasks, source_text, len(deadlines))
    values = {
        "notice_id": post.id, "model": used_model, "prompt_version": TASK_PROMPT_VERSION,
        "result": {"tasks": kept}, "generated_at": now_utc(),
    }
    stmt = pg_insert(TaskBreakdown).values(**values)
    session.exec(stmt.on_conflict_do_update(index_elements=["notice_id"], set_={k: stmt.excluded[k] for k in values}))
    # 이미 세션에 읽어 둔 이전 결과가 아니라 방금 저장한 값을 읽도록 덮어씀
    return session.exec(
        select(TaskBreakdown).where(TaskBreakdown.notice_id == post.id).execution_options(populate_existing=True)
    ).one()


def load_analysis(session: Session, post: Post) -> PostAnalysis:
    analysis = session.exec(select(PostAnalysis).where(PostAnalysis.post_id == post.id)).first()
    if analysis is None:
        raise NotAnalyzedError("아직 분석되지 않은 공지입니다")
    return analysis


def notice_deadlines(session: Session, notice_id: int) -> list[NoticeDeadline]:
    return session.exec(
        select(NoticeDeadline).where(NoticeDeadline.notice_id == notice_id).order_by(NoticeDeadline.deadline_order)
    ).all()


def prepare_tasks(session: Session, user_id: int, post: Post, regenerate: bool) -> dict:
    """'이거 할래' 미리보기: 이 공지의 내 할 일을 미리보기 화면에 필요한 내용과 함께 반환.

    할 일이 이미 있으면(저장했거나, 저장 전 draft가 남아 있으면) 그대로 반환하고 Gemini를 부르지 않음.
    없으면 분해 결과를 draft로 복사 ('저장'을 눌러야 confirmed). 분해 결과가 없거나 regenerate=True면 Gemini 호출.
    regenerate=True면 완료·수정·직접 추가한 할 일은 남기고 나머지만 새 결과로 교체.
    NotAnalyzedError, BreakdownError 발생 가능
    """
    analysis = load_analysis(session, post)
    # 같은 사용자·공지 요청이 동시에 오면(응답이 늦어 다시 누른 경우) 뒤 요청은 앞 요청이 끝날 때까지 기다렸다가
    # 그 결과를 그대로 반환 (Gemini를 또 불러 할 일이 중복으로 생기지 않게). 잠금은 트랜잭션이 끝나면 풀림
    session.execute(text("SELECT pg_advisory_xact_lock(:user_id, :notice_id)"), {"user_id": user_id, "notice_id": post.id})
    mine = user_tasks(session, user_id, post.id)
    if not mine or regenerate:
        breakdown = session.exec(select(TaskBreakdown).where(TaskBreakdown.notice_id == post.id)).first()
        if breakdown is None or regenerate:
            breakdown = generate_breakdown(session, post, analysis)  # 실패하면 기존 할 일은 그대로
        kept = [t for t in mine if t.is_done or t.edited_fields or t.source == "user"]
        for task in mine:
            if task not in kept:
                session.delete(task)
        deadline_ids = {d.deadline_order: d.id for d in notice_deadlines(session, post.id)}
        for order, item in enumerate(breakdown.result["tasks"], start=len(kept)):
            session.add(Task(
                user_id=user_id, notice_id=post.id, deadline_id=deadline_ids.get(item["deadline_index"]),
                title=item["title"], task_order=order, source="ai", evidence=item["evidence"],
            ))
        reschedule(session, user_id, post.id)
        session.commit()
        mine = user_tasks(session, user_id, post.id)
    return {
        "notice": {"id": post.id, "title": post.title, "link": homepage_url(post.link), "published": post.published},
        "apply_method": analysis.result.get("apply_method"),
        "apply_method_evidence": analysis.result.get("apply_method_evidence"),
        "deadlines": notice_deadlines(session, post.id),  # 커밋으로 만료된 객체는 응답에 빈 값으로 나가므로 다시 읽음
        "unclear": analysis.unclear,
        "confirmed": any(t.status == "confirmed" for t in mine),  # 이미 '저장'한 공지
        "tasks": mine,
    }


def add_task(session: Session, user_id: int, post: Post, title: Optional[str], note: Optional[str]) -> Task:
    """사용자가 직접 추가하는 할 일 (근거 없음, source=user). ValueError: 빈 제목.

    이미 저장한 공지면 바로 confirmed, 저장 전 미리보기 중이면 draft.
    """
    mine = user_tasks(session, user_id, post.id)
    status = "confirmed" if any(t.status == "confirmed" for t in mine) else "draft"
    task = Task(
        user_id=user_id, notice_id=post.id, title=clean_title(title), note=clean_note(note),
        task_order=len(mine), source="user", status=status,
    )
    session.add(task)
    reschedule(session, user_id, post.id)
    session.commit()
    session.refresh(task)
    return task


def confirm_tasks(session: Session, user_id: int, post: Post) -> list[Task]:
    """미리보기의 '저장': 이 공지의 내 draft를 모두 confirmed로."""
    for task in user_tasks(session, user_id, post.id):
        if task.status == "draft":
            task.status = "confirmed"
            session.add(task)
    reschedule(session, user_id, post.id)
    session.commit()
    return user_tasks(session, user_id, post.id)


def delete_stale_drafts(session: Session, cutoff: datetime) -> int:
    """마지막으로 만들거나 고친 시각이 cutoff 이전인 draft 할 일을 삭제하고 개수를 반환."""
    deleted = session.exec(
        delete(Task).where(Task.status == "draft", func.coalesce(Task.updated_at, Task.created_at) < cutoff)
    ).rowcount
    session.commit()
    return deleted


def task_deadlines(session: Session, tasks: list[Task]) -> dict[int, tuple[Optional[NoticeDeadline], bool]]:
    """할 일 id → (기준 마감, 공지의 마감을 빌려 썼는지).

    할 일에 연결된 마감에 날짜가 없으면 그 공지에서 가장 빠른 마감을 쓰고, 공지에도 날짜 있는 마감이 없으면 None.
    """
    deadlines = session.exec(
        select(NoticeDeadline)
        .where(NoticeDeadline.notice_id.in_({t.notice_id for t in tasks}), NoticeDeadline.deadline_date.is_not(None))
        .order_by(NoticeDeadline.deadline_date, NoticeDeadline.deadline_time)
    ).all()
    by_id = {d.id: d for d in deadlines}
    earliest = {}
    for d in deadlines:
        earliest.setdefault(d.notice_id, d)
    result = {}
    for task in tasks:
        own = by_id.get(task.deadline_id)
        result[task.id] = (own, False) if own else (earliest.get(task.notice_id), task.notice_id in earliest)
    return result


def reschedule(session: Session, user_id: int, notice_id: int) -> None:
    """이 공지의 내 할 일에 scheduled_date를 배정 (규칙은 schedule.py). 커밋은 호출한 쪽에서.

    완료한 할 일과 사용자가 날짜를 직접 고친 할 일은 그대로 두고, 역산할 때 자리도 차지하지 않음.
    """
    analysis = session.exec(select(PostAnalysis).where(PostAnalysis.post_id == notice_id)).first()
    targets = [
        t for t in user_tasks(session, user_id, notice_id)
        if not t.is_done and "scheduled_date" not in t.edited_fields
    ]
    due = {task_id: d.deadline_date for task_id, (d, _) in task_deadlines(session, targets).items() if d}
    planned = plan_dates(
        analysis and analysis.result.get("apply_method"), [(t.id, due.get(t.id)) for t in targets], today_kst(),
    )
    for task in targets:
        task.scheduled_date = planned[task.id]
        session.add(task)


def list_confirmed_tasks(session: Session, user_id: int) -> list[dict]:
    """'내 할 일': confirmed 할 일(완료 포함)을 마감이 가까운 순으로.

    할 일에 연결된 마감이 없으면 그 공지의 가장 빠른 마감을 쓰고(deadline_from_notice=true), 공지에도 없으면 맨 뒤.
    """
    rows = session.exec(
        select(Task, Post)
        .join(Post, Task.notice_id == Post.id)
        .where(Task.user_id == user_id, Task.status == "confirmed")
    ).all()
    deadlines = task_deadlines(session, [task for task, _ in rows])

    items = []
    for task, post in rows:
        deadline, from_notice = deadlines[task.id]
        items.append({
            "id": task.id, "title": task.title, "note": task.note, "is_done": task.is_done, "done_at": task.done_at,
            "source": task.source, "scheduled_date": task.scheduled_date,
            "notice": {"id": post.id, "title": post.title, "link": homepage_url(post.link)},
            "deadline": deadline and {
                "id": deadline.id, "label": deadline.label, "deadline_date": deadline.deadline_date, "deadline_time": deadline.deadline_time,
            },
            "deadline_from_notice": from_notice,
            "_sort": (
                deadline is None,
                deadline.deadline_date if deadline else date.max,
                (deadline and deadline.deadline_time) or time.max,  # 시각이 없으면 그날의 맨 뒤
                post.id, task.task_order, task.id,
            ),
        })
    items.sort(key=lambda item: item["_sort"])
    for item in items:
        del item["_sort"]
    return items


def clean_title(title: Optional[str]) -> str:
    title = (title or "").strip()
    if not title:
        raise ValueError("제목은 비워 둘 수 없습니다")
    return title


def clean_note(note: Optional[str]) -> Optional[str]:
    return (note or "").strip() or None


def apply_update(task: Task, changes: dict) -> None:
    """PATCH 내용을 반영 (ValueError: 잘못된 값). 값이 실제로 바뀐 필드만 edited_fields에 기록."""
    if "title" in changes:
        changes["title"] = clean_title(changes["title"])
    if "note" in changes:
        changes["note"] = clean_note(changes["note"])
    if "is_done" in changes:
        if changes["is_done"] is None:
            raise ValueError("is_done은 true 또는 false여야 합니다")
        if changes["is_done"] != task.is_done:
            task.done_at = now_utc() if changes["is_done"] else None
        task.is_done = changes["is_done"]

    edited = list(task.edited_fields)  # 새 목록을 넣어야 JSONB 변경이 저장됨
    for field_name in EDITABLE_FIELDS:
        if field_name in changes and changes[field_name] != getattr(task, field_name):
            setattr(task, field_name, changes[field_name])
            if field_name not in edited:
                edited.append(field_name)
    task.edited_fields = edited
    task.updated_at = now_utc()
