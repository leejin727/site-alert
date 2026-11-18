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


# 직접 만든 일정의 기본 체크리스트: (단계, 항목, 일정 날짜 며칠 전)
CHECKLISTS = {
    "exam": [
        ("준비", "시험 범위와 출제 유형 확인", 14),
        ("준비", "강의자료·필기·과제를 한곳에 모으기", 13),
        ("준비", "공부할 분량을 날짜별로 나누기", 12),
        ("공부", "1회독: 개념 정리", 8),
        ("공부", "2회독: 문제 풀이", 5),
        ("공부", "과제·기출 다시 풀기", 3),
        ("공부", "틀린 문제 오답 정리", 2),
        ("직전", "암기 항목 최종 점검", 1),
        ("직전", "시험 시간·장소·준비물 확인", 1),
    ],
    "contest": [
        ("준비", "공고문 정독: 참가 자격·제출물·심사 기준", 28),
        ("준비", "마감에서 거꾸로 중간 마감 잡기", 27),
        ("준비", "역할 나누기", 26),
        ("제작", "주제와 문제 정의 확정", 21),
        ("제작", "기획서 초안", 14),
        ("제작", "프로토타입·구현", 7),
        ("제작", "발표 자료·시연 영상", 4),
        ("제출", "제출 형식·분량·파일명 확인", 2),
        ("제출", "최종 검토: 오탈자·링크·실행", 1),
        ("제출", "제출하고 접수 확인", 0),
    ],
}
KIND_LABELS = {"exam": "시험", "contest": "공모전"}
DATE_LABELS = {"exam": "시험일", "contest": "마감일"}  # 일정 날짜를 마감처럼 보여줄 때의 이름
# 종류별 단계 순서 (체크리스트에 나온 순서)
PHASES = {kind: list(dict.fromkeys(phase for phase, _, _ in items)) for kind, items in CHECKLISTS.items()}


def back_from(due: date, days: int, today: date) -> date:
    """기준 날짜의 며칠 전. 오늘보다 앞이면 오늘로 당김. (공지 역산 배치와 일정 체크리스트가 함께 씀)"""
    return max(today, due - timedelta(days=days))


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
            planned[task_id] = None if due is None else back_from(due, days, today)
    return planned
