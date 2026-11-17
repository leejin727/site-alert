"""할 일 날짜 자동 배정 규칙. 규칙을 바꿀 때는 이 파일만 고치면 됩니다.

Gemini는 마감 날짜를 읽기만 하고, 마감에서 거꾸로 날짜를 정하는 계산은 여기서 코드로 합니다.
"""
from collections import defaultdict
from datetime import date, datetime, timedelta
from typing import Optional
from zoneinfo import ZoneInfo

TODAY_METHODS = {"선착순"}  # 이 신청 방식이면 남은 할 일을 모두 오늘로. 그 외(기간 내 제출·선발·신청 없음·불명확)는 마감에서 역산
BACKWARD_START_DAYS = 3     # 마감 며칠 전에 마지막 할 일을 둘지
BACKWARD_STEP_DAYS = 1      # 그 앞의 할 일은 며칠 간격으로 거꾸로 둘지
TIMEZONE = ZoneInfo("Asia/Seoul")


def today_kst() -> date:
    return datetime.now(TIMEZONE).date()


def plan_dates(apply_method: Optional[str], tasks: list[tuple[int, Optional[date]]], today: date) -> dict[int, Optional[date]]:
    """tasks: (할 일 id, 기준 마감 날짜)를 할 일 순서대로. 반환: id → 배정 날짜 (역산인데 마감이 없으면 None).

    같은 마감 날짜끼리 묶어 마지막 할 일부터 거꾸로 배치하고, 오늘보다 앞이면 오늘로 당김.
    """
    if apply_method in TODAY_METHODS:
        return {task_id: today for task_id, _ in tasks}
    by_due = defaultdict(list)
    for task_id, due in tasks:
        by_due[due].append(task_id)
    planned = {}
    for due, ids in by_due.items():
        for back, task_id in enumerate(reversed(ids)):
            days = BACKWARD_START_DAYS + back * BACKWARD_STEP_DAYS
            planned[task_id] = None if due is None else max(today, due - timedelta(days=days))
    return planned
