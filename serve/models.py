from datetime import date, datetime, time, timezone
from typing import Optional

from sqlalchemy import CheckConstraint, Column, UniqueConstraint
from sqlalchemy.dialects.postgresql import JSONB
from sqlmodel import Field, SQLModel


def now_utc() -> datetime:
    return datetime.now(timezone.utc)


class Site(SQLModel, table=True):
    __tablename__ = "sites"

    id: Optional[int] = Field(default=None, primary_key=True)
    name: str
    rss_url: str = Field(unique=True)
    created_at: datetime = Field(default_factory=now_utc)
    last_checked_at: Optional[datetime] = None


class Post(SQLModel, table=True):
    __tablename__ = "posts"
    # 같은 게시판에서 같은 글은 한 번만 저장 (seen.json 역할)
    __table_args__ = (UniqueConstraint("site_id", "post_key"),)

    id: Optional[int] = Field(default=None, primary_key=True)
    site_id: int = Field(foreign_key="sites.id", index=True)
    post_key: str  # 게시판 글 ID (명지대: 링크 속 숫자, 그 외: 링크 전체)
    title: str
    link: str
    summary: str = ""  # RSS 본문 앞부분 (AI 요약 단계에서 활용)
    published: str = ""
    detected_at: datetime = Field(default_factory=now_utc)
    notified: bool = False  # 푸시 알림 단계에서 사용


class PostAnalysis(SQLModel, table=True):
    """글 하나의 Gemini 분석 결과 (다시 분석하면 같은 행을 갱신)."""
    __tablename__ = "post_analyses"

    id: Optional[int] = Field(default=None, primary_key=True)
    post_id: int = Field(foreign_key="posts.id", unique=True)
    model: str
    body_source: str  # 상세페이지, 이미지뿐, RSS요약(...) 등
    image_count: int = 0
    result: dict = Field(sa_column=Column(JSONB, nullable=False))  # Gemini 응답 원본 (근거 포함, 연도 보정 전)
    unclear: list[str] = Field(sa_column=Column(JSONB, nullable=False))  # 확인 불가 필드 이름
    analyzed_at: datetime = Field(default_factory=now_utc)


class NoticeDeadline(SQLModel, table=True):
    """분석 결과의 마감 하나 (연도 보정 후). 다시 분석해도 같은 순번의 행은 id가 유지됨."""
    __tablename__ = "notice_deadlines"
    __table_args__ = (UniqueConstraint("notice_id", "deadline_order"),)

    id: Optional[int] = Field(default=None, primary_key=True)
    notice_id: int = Field(foreign_key="posts.id", index=True)
    deadline_order: int  # 분석 결과 deadlines 배열의 순번 (0부터)
    label: str
    deadline_date: Optional[date] = None  # 날짜를 특정할 수 없으면 null (unclear에 기록됨)
    deadline_time: Optional[time] = None
    year_corrected: bool = False  # 원문에 연도가 없어 코드가 게시일 기준으로 채움
    confidence: str
    evidence: Optional[str] = None


class User(SQLModel, table=True):
    __tablename__ = "users"

    id: Optional[int] = Field(default=None, primary_key=True)
    created_at: datetime = Field(default_factory=now_utc)


class TaskBreakdown(SQLModel, table=True):
    """공지 하나를 프롬프트 B로 할 일 분해한 결과 (공지 단위, 사용자와 무관). 사용자 tasks의 원본."""
    __tablename__ = "task_breakdowns"

    id: Optional[int] = Field(default=None, primary_key=True)
    notice_id: int = Field(foreign_key="posts.id", unique=True)
    model: str
    prompt_version: str
    result: dict = Field(sa_column=Column(JSONB, nullable=False))  # {"tasks": [근거 검증을 통과한 항목]}
    generated_at: datetime = Field(default_factory=now_utc)


class Task(SQLModel, table=True):
    """사용자가 '이거 할래'로 담은 공지의 할 일 하나."""
    __tablename__ = "tasks"
    __table_args__ = (CheckConstraint("status IN ('draft', 'confirmed')", name="ck_tasks_status"),)

    id: Optional[int] = Field(default=None, primary_key=True)
    user_id: int = Field(foreign_key="users.id", index=True)
    notice_id: int = Field(foreign_key="posts.id", index=True)
    # 다시 분석해서 마감이 사라지면 연결만 끊음 (할 일과 사용자 체크는 유지)
    deadline_id: Optional[int] = Field(default=None, foreign_key="notice_deadlines.id", ondelete="SET NULL")
    title: str
    note: Optional[str] = None  # 사용자 메모 (AI는 채우지 않음)
    task_order: int
    source: str = Field(default="ai", sa_column_kwargs={"server_default": "ai"})  # ai: 분해 결과에서 옴, user: 사용자가 직접 추가
    evidence: Optional[str] = None  # ai 항목은 반드시 있음 (task_breakdowns에서 복사). user 항목은 없음
    scheduled_date: Optional[date] = None  # 자동 배정(tasks.reschedule, 규칙은 schedule.py) 또는 사용자가 정한 날짜
    is_done: bool = False
    done_at: Optional[datetime] = None
    created_at: datetime = Field(default_factory=now_utc)
    # 사용자가 직접 바꾼 필드 이름 (예: ["title", "scheduled_date"]). 자동 배정이 사용자가 정한 날짜를 덮어쓰지 않게 함
    edited_fields: list[str] = Field(default_factory=list, sa_column=Column(JSONB, nullable=False))
    updated_at: Optional[datetime] = None
    # draft: 미리보기를 열 때 만들어짐(저장 안 하면 24시간 뒤 scheduler.cleanup_drafts가 삭제), confirmed: '저장'을 누름.
    # 카드의 '담은 할 일'과 플래너는 confirmed만 대상
    status: str = Field(default="draft", index=True)



class WeeklyReview(SQLModel, table=True):
    """사용자의 주간 회고 메모 (한 주에 하나). 완료율은 저장하지 않고 열 때마다 할 일에서 계산."""
    __tablename__ = "weekly_reviews"
    __table_args__ = (UniqueConstraint("user_id", "week_start"),)

    id: Optional[int] = Field(default=None, primary_key=True)
    user_id: int = Field(foreign_key="users.id")
    week_start: date  # 그 주의 일요일
    memo: Optional[str] = None
    created_at: datetime = Field(default_factory=now_utc)
    updated_at: datetime = Field(default_factory=now_utc)


# ---- API 요청용 모델 (테이블 아님) ----
class SiteCreate(SQLModel):
    name: str
    rss_url: str


class TaskCreate(SQLModel):
    """사용자가 직접 추가하는 할 일."""
    title: str
    note: Optional[str] = None


class TaskUpdate(SQLModel):
    """보낸 필드만 바뀜. note·scheduled_date는 null을 보내면 비워짐."""
    title: Optional[str] = None
    note: Optional[str] = None
    scheduled_date: Optional[date] = None
    is_done: Optional[bool] = None


class ReviewUpdate(SQLModel):
    memo: Optional[str] = None
