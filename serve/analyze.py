"""
공지 AI 분석. 서버에서는 scheduler.py가 analyze_post로 새 글을 자동 분석해 DB에 저장하고,
직접 실행하면 최근 공지를 분석해 DB에 저장(갱신)하고, 정확도를 직접 채점할 파일도 만듭니다.

날짜는 Gemini가 원문에 적힌 연·월·일만 옮기고, 연도 보정은 저장 직전에 resolve_analysis가 합니다.

본문은 RSS 요약(앞부분)이 아니라 상세 페이지에서 가져온 전문을 사용합니다 (실패하면 RSS 요약으로 대체).
본문이 이미지뿐이면 이미지를 함께 보냅니다.

사용법:  python3 -m serve.analyze [개수]        (기본 10개)
결과:    analysis_results.csv  → 직접 채점용 (맨 오른쪽 빈 칸에 O/X 기록)
         analysis_results.json → 대회 제출용 기록 (사용 모델, 프롬프트, 결과 원본)
"""
import csv
import json
import os
import re
import sys
import time
from datetime import date, datetime
from datetime import time as dtime
from pathlib import Path
from typing import Literal, Optional, Sequence

from google import genai
from google.genai import types
from pydantic import BaseModel, Field
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlmodel import Session, delete, select

from serve.db import engine
from serve.detail import download_images, fetch_detail
from serve.models import NoticeDeadline, Post, PostAnalysis, Site, now_utc

MODEL = os.getenv("GEMINI_MODEL", "gemini-3.8-flash")
FALLBACK_MODEL = os.getenv("GEMINI_FALLBACK_MODEL", "gemini-3.5-flash-lite")  # 기본 모델이 계속 붐빌 때
WAIT_SECONDS = 7  # 무료 등급의 분당 요청 제한을 넘지 않도록 요청 사이에 대기
RETRY_WAITS = [10, 30]  # 일시적 오류(503 등) 때 재시도 전 대기 시간(초)
RETRYABLE = ("429", "500", "503", "UNAVAILABLE", "RESOURCE_EXHAUSTED", "INTERNAL")


class Deadline(BaseModel):
    label: str = Field(description="무엇의 마감인지. 예: '1차 접수', '서류 제출'")
    year: Optional[int] = Field(description="원문에 적힌 연도. 원문에 연도가 없으면 null")
    month: Optional[int] = Field(description="원문에 적힌 월. 월·일이 적혀 있지 않으면 null")
    day: Optional[int] = Field(description="원문에 적힌 일. 월·일이 적혀 있지 않으면 null")
    time: Optional[str] = Field(description="마감 시각 'HH:MM'(24시간). 텍스트에 없으면 null")
    confidence: Literal["높음", "낮음"]
    evidence: str = Field(description="이 마감이 나온 원문 문구 그대로")


class NoticeAnalysis(BaseModel):
    summary: str = Field(description="공지 핵심을 1~2문장으로 요약")
    category: Literal["학사", "장학", "채용·취업", "행사·교육", "시설·생활", "기타"]
    target: str = Field(description="공지 대상. 예: 전체 학생, 4학년, 컴퓨터공학과. 알 수 없으면 '불명확'")
    target_evidence: Optional[str] = Field(description="대상 판단의 근거가 된 원문 문구 그대로. 없으면 null")
    undergrad: Literal["예", "아니오", "불명확"] = Field(description="학부생이 대상에 포함되는지")
    undergrad_evidence: Optional[str] = Field(description="학부생 포함 여부 판단의 근거가 된 원문 문구 그대로. 없으면 null")
    deadlines: list[Deadline] = Field(description="신청·접수·제출 마감 목록. 없으면 빈 배열")
    apply_method: Literal["선착순", "선발", "기간 내 제출", "신청 없음", "불명확"]
    apply_method_evidence: Optional[str] = Field(description="신청 방식 판단의 근거가 된 원문 문구 그대로. 없으면 null")


# 프롬프트는 버전별 파일로 관리 (비교 실험용). 예: PROMPT_VERSION=v3 python3 -m serve.analyze
# v1은 이전 스키마(date 문자열, todos)용이라 지금 코드로는 쓰지 않음
PROMPT_VERSION = os.getenv("PROMPT_VERSION", "v2")
PROMPT_DIR = Path(__file__).with_name("prompts") / PROMPT_VERSION
OUT_DIR = Path(__file__).parent  # 채점용 결과 파일은 실행 위치와 상관없이 serve/에
PROMPT = (PROMPT_DIR / "notice.txt").read_text(encoding="utf-8")
IMAGE_NOTE = (PROMPT_DIR / "image_note.txt").read_text(encoding="utf-8")

TIME_PATTERN = re.compile(r"\d{2}:\d{2}")
PUBLISHED_PATTERN = re.compile(r"(\d{4})[.-](\d{1,2})[.-](\d{1,2})")  # RSS '2026-10-02 11:21:37.0', 상세 '2026.10.06'


def parse_published(published: str) -> Optional[date]:
    match = PUBLISHED_PATTERN.search(published or "")
    return make_date(*map(int, match.groups())) if match else None


def make_date(year, month, day) -> Optional[date]:
    try:
        return date(year, month, day)
    except (TypeError, ValueError):  # 값 없음, 2월 30일 같은 없는 날짜
        return None


def parse_time(value: Optional[str]) -> Optional[dtime]:
    if not value or not TIME_PATTERN.fullmatch(value):
        return None
    try:
        return dtime.fromisoformat(value)
    except ValueError:  # 25:00 같은 없는 시각
        return None


def resolve_date(d: Deadline, published: Optional[date]) -> tuple[Optional[date], bool, bool]:
    """원문 연·월·일을 날짜로 확정. 반환: (날짜, 연도 보정 여부, 확인 필요 여부)

    - 연도가 없으면 게시일과 가장 가까운 연도를 고름 (12월 공지의 '1.5'는 다음 해, 기간 연장 공지의 지난 마감은 같은 해)
    - 연도가 적혀 있는데 게시일보다 과거면 원문 그대로 두고 확인 필요로 표시
    """
    if d.year is not None:
        found = make_date(d.year, d.month, d.day)
        return found, False, found is None or (published is not None and found < published)
    if published is None or d.month is None or d.day is None:
        return None, False, True
    candidates = [c for y in (published.year - 1, published.year, published.year + 1) if (c := make_date(y, d.month, d.day))]
    if not candidates:
        return None, False, True
    return min(candidates, key=lambda c: abs(c - published)), True, False


def resolve_analysis(a: NoticeAnalysis, published: str) -> tuple[list[dict], list[str]]:
    """저장 직전 처리: 마감 날짜를 코드로 확정하고 확인불가 필드 목록을 만듦.

    반환: (notice_deadlines 행 값 목록, 확인불가 필드 이름 목록 예: ['undergrad', 'deadlines[0].date'])
    """
    pub = parse_published(published)
    unclear = [f for f in ("target", "undergrad", "apply_method") if getattr(a, f) == "불명확"]
    rows = []
    for i, d in enumerate(a.deadlines):
        found, corrected, needs_check = resolve_date(d, pub)
        parsed_time = parse_time(d.time)
        if needs_check:
            unclear.append(f"deadlines[{i}].date")
        elif d.confidence == "낮음":
            unclear.append(f"deadlines[{i}]")
        if d.time and parsed_time is None:
            unclear.append(f"deadlines[{i}].time")
        rows.append({
            "deadline_order": i, "label": d.label, "deadline_date": found, "deadline_time": parsed_time,
            "year_corrected": corrected, "confidence": d.confidence, "evidence": d.evidence or None,
        })
    return rows, unclear


def save_analysis(session: Session, post: Post, a: NoticeAnalysis, used_model: str, source: str, n_images: int) -> tuple[list[dict], list[str]]:
    """분석 결과와 마감을 저장. 같은 공지를 다시 분석하면 행을 새로 만들지 않고 갱신함.

    반환: resolve_analysis와 같음 (마감 행 값 목록, 확인불가 필드 목록)
    """
    rows, unclear = resolve_analysis(a, post.published)
    values = {
        "post_id": post.id, "model": used_model, "body_source": source, "image_count": n_images,
        "result": a.model_dump(), "unclear": unclear, "analyzed_at": now_utc(),
    }
    stmt = pg_insert(PostAnalysis).values(**values)
    session.exec(stmt.on_conflict_do_update(index_elements=["post_id"], set_={k: stmt.excluded[k] for k in values}))
    for row in rows:
        stmt = pg_insert(NoticeDeadline).values(notice_id=post.id, **row)
        session.exec(stmt.on_conflict_do_update(
            index_elements=["notice_id", "deadline_order"], set_={k: stmt.excluded[k] for k in row},
        ))
    # 마감 수가 줄었으면 남는 순번만 삭제 (남은 마감의 id는 유지되어 할 일의 연결이 끊기지 않음)
    session.exec(delete(NoticeDeadline).where(NoticeDeadline.notice_id == post.id, NoticeDeadline.deadline_order >= len(rows)))
    session.commit()
    return rows, unclear


def call_model(client, model: str, contents, schema: type[BaseModel], timeout: int | None = None) -> BaseModel:
    resp = client.models.generate_content(
        model=model,
        contents=contents,  # 텍스트(str) 또는 [텍스트, 이미지...] 목록
        config=types.GenerateContentConfig(
            response_mime_type="application/json",
            response_schema=schema,
            temperature=0,
            # 함수 호출(tools)을 쓰지 않으므로 끔. 켜 두면 SDK가 'Direct use of AFC ...' 경고를 출력함
            automatic_function_calling=types.AutomaticFunctionCallingConfig(disable=True),
            http_options=types.HttpOptions(timeout=timeout * 1000) if timeout else None,  # 없으면 client 설정대로
        ),
    )
    if resp.parsed is None:
        raise ValueError(f"JSON 해석 실패: {(resp.text or '')[:200]}")
    return resp.parsed


def build_prompt(board: str, title: str, published: str, body: str, attachments: list[str]) -> str:
    return PROMPT.format(
        board=board,
        published=published or "알 수 없음",
        title=title or "알 수 없음",
        attachments=", ".join(attachments) or "없음",
        body=body or "(본문 없음)",
    )


def load_body(post: Post) -> tuple[str, list[str], str, list[tuple[str, bytes]]]:
    """상세 페이지에서 본문 전문과 첨부파일 이름을 가져옴. 실패하면 RSS 요약으로 대체.

    반환: (본문, 첨부파일 이름 목록, 본문 출처, 본문이 이미지뿐일 때의 이미지 [(MIME, 데이터)])
    """
    try:
        detail = fetch_detail(post.link)
    except Exception as e:
        print(f"  상세 페이지를 못 가져와 RSS 요약 사용: {str(e)[:60]}")
        return post.summary, [], "RSS요약(상세 실패)", []
    if not detail.area:  # 이 사이트 구조에서 본문 영역을 못 찾음 → detail.py의 CONTENT_SELECTORS 조정 필요
        return post.summary, detail.attachments, "RSS요약(본문 영역 없음)", []
    if not detail.text:
        images, _ = download_images(detail)
        source = "이미지뿐" if images else "이미지뿐(내려받기 실패)"
        return "(본문이 이미지로만 되어 있어 텍스트 없음)", detail.attachments, source, images
    return detail.text, detail.attachments, "상세페이지", []


def analyze_post(
    client, board: str, post: Post, models: Sequence[str] = (MODEL, FALLBACK_MODEL), skip_after: int | None = None,
) -> tuple[NoticeAnalysis, str, str, int, int]:
    """반환: (분석 결과, 사용 모델, 본문 출처, 본문 길이, 보낸 이미지 수)"""
    body, attachments, source, images = load_body(post)
    prompt = build_prompt(board, post.title, post.published, body, attachments)
    contents = prompt
    if images:
        contents = [prompt + IMAGE_NOTE.format(n=len(images))]
        contents += [types.Part.from_bytes(data=data, mime_type=mime) for mime, data in images]
    result, used_model = run_with_retry(client, contents, models=models, skip_after=skip_after)
    return result, used_model, source, len(body or ""), len(images)


def run_with_retry(
    client, contents, schema: type[BaseModel] = NoticeAnalysis, models: Sequence[str] = (MODEL, FALLBACK_MODEL),
    skip_after: int | None = None,
) -> tuple[BaseModel, str]:
    """재시도·대체 모델을 적용해 Gemini를 호출하고, schema 형식의 결과와 실제 사용된 모델 이름을 반환.

    models는 시도할 순서 (앞 모델이 계속 실패하면 다음 모델로).
    skip_after(초)를 주면 마지막 모델이 아닌 모델은 그 시간 안에 답이 없을 때 다음 모델로 넘어감.
    """
    last_error = None
    models = list(dict.fromkeys(models))
    for i, model in enumerate(models):
        for wait in [0] + RETRY_WAITS:
            if wait:
                print(f"  {wait}초 기다린 뒤 다시 시도 ({model})")
                time.sleep(wait)
            try:
                return call_model(client, model, contents, schema, skip_after if i + 1 < len(models) else None), model
            except Exception as e:
                last_error = e
                msg = str(e)
                # 모델 없음·제한 시간 초과·하루 한도 소진 → 재시도 무의미, 바로 대체 모델로
                if any(k in msg for k in ("404", "timed out", "DEADLINE_EXCEEDED", "PerDay")):
                    break
                if not any(k in msg for k in RETRYABLE):  # 키 오류 등: 재시도해도 소용없음
                    raise
                print(f"  일시적 오류: {msg[:60]}")
        if i + 1 < len(models):
            print(f"  {model} 계속 실패 → 대체 모델 {models[i + 1]}로 시도")
    raise last_error


def format_deadline(row: dict) -> str:
    """CSV·화면 확인용: '접수 마감: 2026-10-16 18:00 (높음, 연도보정) (근거: ...)'"""
    when = " ".join(str(v) for v in (row["deadline_date"] or "날짜 없음", row["deadline_time"]) if v)
    flags = ", ".join([row["confidence"]] + (["연도보정"] if row["year_corrected"] else []))
    return f"{row['label']}: {when} ({flags}) (근거: {row['evidence']})"


def main() -> None:
    limit = int(sys.argv[1]) if len(sys.argv) > 1 else 10
    if not os.getenv("GEMINI_API_KEY"):
        sys.exit('GEMINI_API_KEY가 없습니다. 먼저 터미널에서 export GEMINI_API_KEY="발급받은키" 를 실행하세요.')

    client = genai.Client()  # 환경변수 GEMINI_API_KEY를 자동으로 사용
    try:
        with Session(engine) as session:
            rows = session.exec(
                select(Post, Site.name)
                .join(Site, Post.site_id == Site.id)
                .order_by(Post.published.desc(), Post.id.desc())
                .limit(limit)
            ).all()
    except Exception as e:
        sys.exit(f"DB에 연결하지 못했습니다. PostgreSQL이 켜져 있는지 확인하세요 (brew services list).\n원인: {str(e).splitlines()[0]}")
    if not rows:
        sys.exit("DB에 공지가 없습니다. 서버에서 사이트를 먼저 등록하세요.")

    print(f"모델: {MODEL} (대체: {FALLBACK_MODEL}) / 공지 {len(rows)}개 분석 시작\n")
    results = []
    for i, (post, board) in enumerate(rows, 1):
        print(f"[{i}/{len(rows)}] {post.title}")
        row = {
            "번호": i, "게시판": board, "게시일": post.published, "제목": post.title, "링크": post.link,
            "본문출처": "", "본문길이": 0, "이미지수": 0, "사용모델": "", "AI요약": "", "분류": "",
            "대상": "", "대상근거": "", "학부생": "", "학부생근거": "", "마감일": "",
            "신청방식": "", "신청방식근거": "", "확인불가": "", "오류": "",
        }
        try:
            a, used_model, source, body_len, n_images = analyze_post(client, board, post)
            with Session(engine) as session:
                deadlines, unclear = save_analysis(session, post, a, used_model, source, n_images)
            row.update({
                "본문출처": source, "본문길이": body_len, "이미지수": n_images,
                "사용모델": used_model,
                "AI요약": a.summary, "분류": a.category,
                "대상": a.target, "대상근거": a.target_evidence or "",
                "학부생": a.undergrad, "학부생근거": a.undergrad_evidence or "",
                "마감일": "\n".join(format_deadline(d) for d in deadlines),
                "신청방식": a.apply_method, "신청방식근거": a.apply_method_evidence or "",
                "확인불가": ", ".join(unclear),
            })
            print(f"  → [{used_model}] {a.category} | 학부생 {a.undergrad} | 마감 {len(a.deadlines)}개 | {a.apply_method} | {a.summary}")
        except Exception as e:
            row["오류"] = str(e)[:300]
            print(f"  → 실패: {row['오류']}")
        results.append(row)
        if i < len(rows):
            time.sleep(WAIT_SECONDS)

    # 직접 채점용 CSV (엑셀·Numbers에서 한글이 깨지지 않도록 utf-8-sig)
    score_cols = ["요약OK", "분류OK", "학부생OK", "마감일OK", "신청방식OK", "메모"]
    with open(OUT_DIR / "analysis_results.csv", "w", newline="", encoding="utf-8-sig") as f:
        writer = csv.DictWriter(f, fieldnames=list(results[0].keys()) + score_cols)
        writer.writeheader()
        for r in results:
            writer.writerow({**r, **{c: "" for c in score_cols}})

    # 대회 제출용 기록 (어떤 모델·프롬프트로 무엇이 나왔는지)
    record = {
        "실행시각": datetime.now().isoformat(timespec="seconds"),
        "모델": MODEL,
        "대체모델": FALLBACK_MODEL,
        "프롬프트버전": PROMPT_VERSION,
        "프롬프트": PROMPT,
        "결과": results,
    }
    with open(OUT_DIR / "analysis_results.json", "w", encoding="utf-8") as f:
        json.dump(record, f, ensure_ascii=False, indent=2)

    failed = sum(1 for r in results if r["오류"])
    print(f"\n완료: 성공 {len(results) - failed}개, 실패 {failed}개")
    print("analysis_results.csv를 열어 원문 링크와 비교하며 오른쪽 칸에 O/X를 기록하세요.")


if __name__ == "__main__":
    main()