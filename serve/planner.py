"""직접 만든 일정(시험·공모전)과 그 체크리스트.

Gemini를 쓰지 않습니다. 기본 체크리스트와 예정일 계산 규칙은 schedule.py에 있고, 할 일은 공지 할 일과 같은 tasks 테이블에 넣습니다
(source='user', 근거 없음, 처음부터 confirmed).
"""
from collections import defaultdict
from datetime import date
from typing import Optional

from sqlmodel import Session, delete, func, select

from serve.models import NoticeDeadline, Post, Schedule, Task
from serve.rss import homepage_url
from serve.schedule import CHECKLISTS, PHASES, back_from, today_kst
from serve.tasks import clean_title


def get_schedule(session: Session, user_id: int, schedule_id: int) -> Optional[Schedule]:
    schedule = session.get(Schedule, schedule_id)
    return schedule if schedule and schedule.user_id == user_id else None


def task_item(task: Task) -> dict:
    return {
        "id": task.id, "title": task.title, "note": task.note, "phase": task.phase,
        "scheduled_date": task.scheduled_date, "is_done": task.is_done, "source": task.source,
    }


def schedule_detail(session: Session, schedule: Schedule) -> dict:
    """일정과 체크리스트. 할 일은 단계 순서대로, 단계 안에서는 넣은 순서대로 (단계가 없는 것은 맨 뒤)."""
    phases = PHASES[schedule.kind]
    tasks = session.exec(select(Task).where(Task.schedule_id == schedule.id).order_by(Task.task_order, Task.id)).all()
    tasks = sorted(tasks, key=lambda t: phases.index(t.phase) if t.phase in phases else len(phases))
    return {
        "id": schedule.id, "kind": schedule.kind, "title": schedule.title, "target_date": schedule.target_date,
        "phases": phases, "tasks": [task_item(t) for t in tasks],
    }


def create_schedule(session: Session, user_id: int, kind: str, title: Optional[str], target_date: date, use_checklist: bool) -> dict:
    """일정을 만들고 상세를 반환 (ValueError: 잘못된 값). use_checklist면 기본 체크리스트를 날짜에 맞춰 넣음."""
    if kind not in CHECKLISTS:
        raise ValueError("종류는 exam 또는 contest여야 합니다")
    schedule = Schedule(user_id=user_id, kind=kind, title=clean_title(title), target_date=target_date)
    session.add(schedule)
    session.flush()
    if use_checklist:
        today = today_kst()
        for order, (phase, item, days) in enumerate(CHECKLISTS[kind]):
            session.add(Task(
                user_id=user_id, schedule_id=schedule.id, title=item, phase=phase, days_before=days, task_order=order,
                source="user", status="confirmed", scheduled_date=back_from(target_date, days, today),
            ))
    session.commit()
    return schedule_detail(session, session.get(Schedule, schedule.id))


def update_schedule(session: Session, schedule: Schedule, changes: dict) -> dict:
    """제목·날짜 수정 (ValueError: 잘못된 값).

    날짜가 바뀌면 기본 체크리스트 항목의 예정일을 다시 계산. 완료한 항목과 사용자가 예정일을 직접 고친 항목은 그대로 둠
    (공지 할 일의 tasks.reschedule과 같은 기준). 직접 추가한 항목은 '며칠 전' 값이 없어 대상이 아님.
    """
    if "title" in changes:
        schedule.title = clean_title(changes["title"])
    if "target_date" in changes:
        if changes["target_date"] is None:
            raise ValueError("날짜는 비워 둘 수 없습니다")
        if changes["target_date"] != schedule.target_date:
            schedule.target_date = changes["target_date"]
            today = today_kst()
            targets = session.exec(
                select(Task).where(Task.schedule_id == schedule.id, Task.days_before.is_not(None), Task.is_done.is_(False))
            ).all()
            for task in targets:
                if "scheduled_date" not in task.edited_fields:
                    task.scheduled_date = back_from(schedule.target_date, task.days_before, today)
                    session.add(task)
    session.add(schedule)
    session.commit()
    return schedule_detail(session, session.get(Schedule, schedule.id))


def add_schedule_task(
    session: Session, user_id: int, schedule: Schedule, title: Optional[str], phase: Optional[str], scheduled_date: Optional[date],
) -> dict:
    """체크리스트에 항목 직접 추가 (ValueError: 잘못된 값). 다른 항목의 예정일은 바꾸지 않음."""
    if phase is not None and phase not in PHASES[schedule.kind]:
        raise ValueError(f"단계는 {', '.join(PHASES[schedule.kind])} 중 하나여야 합니다")
    last = session.exec(select(func.max(Task.task_order)).where(Task.schedule_id == schedule.id)).one()
    task = Task(
        user_id=user_id, schedule_id=schedule.id, title=clean_title(title), phase=phase,
        task_order=0 if last is None else last + 1, source="user", status="confirmed", scheduled_date=scheduled_date,
    )
    session.add(task)
    session.commit()
    return task_item(session.get(Task, task.id))


def delete_schedule(session: Session, schedule: Schedule) -> None:
    session.exec(delete(Task).where(Task.schedule_id == schedule.id))
    session.delete(schedule)
    session.commit()


def list_schedules(session: Session, user_id: int, today: date) -> list[dict]:
    """일정 목록: 직접 만든 일정과 공지에서 담은(confirmed) 것을 함께. 다가오는 것이 가까운 순으로 위, 지난 것은 아래, 날짜 없는 것은 맨 아래.

    공지의 날짜는 그 공지의 마감 중 오늘 이후 가장 가까운 것, 없으면 가장 늦은 지난 마감.
    """
    progress = defaultdict(lambda: [0, 0])  # (schedule|notice, id) → [전체, 완료]
    for task in session.exec(select(Task).where(Task.user_id == user_id, Task.status == "confirmed")).all():
        key = ("schedule", task.schedule_id) if task.schedule_id else ("notice", task.notice_id)
        progress[key][0] += 1
        progress[key][1] += task.is_done
    notice_ids = [key_id for kind, key_id in progress if kind == "notice"]

    entries = []
    for schedule in session.exec(select(Schedule).where(Schedule.user_id == user_id)).all():
        total, done = progress[("schedule", schedule.id)]
        entries.append({
            "kind": schedule.kind, "schedule_id": schedule.id, "notice_id": None, "link": None,
            "title": schedule.title, "date": schedule.target_date, "total": total, "done": done,
        })
    dates = defaultdict(list)
    for deadline in session.exec(
        select(NoticeDeadline).where(NoticeDeadline.notice_id.in_(notice_ids), NoticeDeadline.deadline_date.is_not(None))
    ).all():
        dates[deadline.notice_id].append(deadline.deadline_date)
    for post in session.exec(select(Post).where(Post.id.in_(notice_ids))).all():
        upcoming = [d for d in dates[post.id] if d >= today]
        total, done = progress[("notice", post.id)]
        entries.append({
            "kind": "notice", "schedule_id": None, "notice_id": post.id, "link": homepage_url(post.link),
            "title": post.title, "date": min(upcoming) if upcoming else max(dates[post.id], default=None),
            "total": total, "done": done,
        })

    def order(entry):
        day = entry["date"]
        if day is None:
            return (2, 0, entry["title"])
        return (0, day.toordinal(), entry["title"]) if day >= today else (1, -day.toordinal(), entry["title"])

    return sorted(entries, key=order)
