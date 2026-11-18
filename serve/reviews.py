"""주간 회고: 한 주(일요일 시작)에 하기로 한 할 일의 완료율과 회고 메모.

계획 = 그 주에 scheduled_date가 있는 confirmed 할 일, 완료 = 그중 체크한 것 (언제 체크했든).
완료율은 저장하지 않고 열 때마다 계산하므로, 지난주 할 일을 나중에 체크하면 지난주 완료율도 바뀝니다.
"""
from datetime import date, timedelta
from typing import Optional

from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlmodel import Session, select

from serve.models import Post, Schedule, Task, WeeklyReview, now_utc
from serve.tasks import task_source
from serve.schedule import today_kst

MEMO_MAX_LENGTH = 2000


def week_range(day: date) -> tuple[date, date]:
    """day가 속한 주의 (일요일, 토요일)."""
    start = day - timedelta(days=day.isoweekday() % 7)  # isoweekday: 월 1 … 일 7
    return start, start + timedelta(days=6)


def weekly_review(session: Session, user_id: int, day: Optional[date]) -> dict:
    start, end = week_range(day or today_kst())
    rows = session.exec(
        select(Task, Post, Schedule)
        .outerjoin(Post, Task.notice_id == Post.id)
        .outerjoin(Schedule, Task.schedule_id == Schedule.id)
        .where(Task.user_id == user_id, Task.status == "confirmed", Task.scheduled_date.between(start, end))
        .order_by(Task.scheduled_date, Task.notice_id, Task.schedule_id, Task.task_order, Task.id)
    ).all()
    done = sum(task.is_done for task, _, _ in rows)
    review = session.exec(
        select(WeeklyReview).where(WeeklyReview.user_id == user_id, WeeklyReview.week_start == start)
    ).first()
    return {
        "week_start": start, "week_end": end,
        "planned": len(rows), "done": done, "rate": done / len(rows) if rows else None,  # 계획이 없으면 null
        "unfinished": [
            {
                "id": task.id, "title": task.title, "scheduled_date": task.scheduled_date,
                **task_source(post, schedule),
            }
            for task, post, schedule in rows if not task.is_done
        ],
        "memo": review.memo if review else None,
        "updated_at": review.updated_at if review else None,
    }


def save_memo(session: Session, user_id: int, day: Optional[date], memo: Optional[str]) -> dict:
    """그 주의 회고 메모를 저장(이미 있으면 덮어씀)하고 회고 전체를 반환. ValueError: 너무 긴 메모."""
    memo = (memo or "").strip() or None
    if memo and len(memo) > MEMO_MAX_LENGTH:
        raise ValueError(f"메모는 {MEMO_MAX_LENGTH}자까지 쓸 수 있습니다")
    start, _ = week_range(day or today_kst())
    now = now_utc()
    stmt = pg_insert(WeeklyReview).values(user_id=user_id, week_start=start, memo=memo, created_at=now, updated_at=now)
    session.exec(stmt.on_conflict_do_update(index_elements=["user_id", "week_start"], set_={"memo": memo, "updated_at": now}))
    session.commit()
    return weekly_review(session, user_id, start)
