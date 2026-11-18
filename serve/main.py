import os
import secrets
from contextlib import asynccontextmanager
from datetime import date, time
from pathlib import Path
from typing import Literal, Optional

from fastapi import Depends, FastAPI, Header, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from sqlalchemy.exc import SQLAlchemyError
from sqlmodel import Session, delete, func, select

from serve import PRODUCTION
from serve.db import get_session
from serve.models import (
    NoticeDeadline, Post, PostAnalysis, ReviewUpdate, Schedule, ScheduleCreate, ScheduleTaskCreate, ScheduleUpdate,
    Site, SiteCreate, Task, TaskBreakdown, TaskCreate, TaskUpdate,
)
from serve.planner import (
    add_schedule_task, create_schedule, delete_schedule, get_schedule, list_schedules, schedule_detail, update_schedule,
)
from serve.reviews import save_memo, weekly_review
from serve.rss import FeedError, check_site, create_site, homepage_url
from serve.schedule import today_kst
from serve.scheduler import check_all_sites, start_scheduler, stop_scheduler
from serve.tasks import BreakdownError, DailyLimitError, NotAnalyzedError, add_task, apply_update, confirm_tasks, list_confirmed_deadlines, list_confirmed_tasks, prepare_tasks, reschedule

FIXED_USER_ID = 1  # alembic 0003에서 만든 사용자
ADMIN_KEY = os.getenv("ADMIN_KEY", "")
WEB_DIR = Path(__file__).with_name("web")  # Flutter 웹 빌드 결과 (build_web.sh가 채움)


def current_user_id() -> int:
    # shortcut: 로그인 전이라 모든 요청을 사용자 1로 처리, 로그인 단계에서 토큰으로 사용자를 찾도록 이 함수만 교체
    return FIXED_USER_ID


def is_admin(x_admin_key: Optional[str] = Header(None)) -> bool:
    """배포 서버에서는 X-Admin-Key 헤더가 ADMIN_KEY와 같을 때만 관리자. ADMIN_KEY가 비어 있으면 아무도 관리자가 아님. 로컬에서는 항상 허용."""
    if not PRODUCTION:
        return True
    return bool(ADMIN_KEY) and x_admin_key is not None and secrets.compare_digest(x_admin_key.encode(), ADMIN_KEY.encode())


def require_admin(admin: bool = Depends(is_admin)) -> None:
    if not admin:
        raise HTTPException(403, "관리자 키가 필요합니다")


@asynccontextmanager
async def lifespan(app: FastAPI):
    # 테이블은 서버 시작 전에 `alembic upgrade head`로 만들어 둠
    start_scheduler()   # 3단계: 서버가 켜지면 자동 확인 시작
    yield
    stop_scheduler()    # 서버가 꺼질 때 함께 정리


# 로그인이 없는 배포 서버에서는 API 목록(/docs, /redoc, /openapi.json)을 공개하지 않음
DOCS_OFF = {"docs_url": None, "redoc_url": None, "openapi_url": None} if PRODUCTION else {}
app = FastAPI(title="사이트 알림 서버", lifespan=lifespan, **DOCS_OFF)

# 웹 앱(브라우저)에서 부르기 위한 CORS. `flutter run -d chrome`은 실행할 때마다 포트가 바뀌어 로컬 주소는 포트와 무관하게 허용.
# 배포한 웹 주소는 CORS_ORIGINS에 쉼표로 구분해 적음 (예: https://app.example.com)
LOCAL_ORIGIN_REGEX = r"http://(localhost|127\.0\.0\.1)(:\d+)?"
CORS_ORIGINS = [o.strip() for o in os.getenv("CORS_ORIGINS", "").split(",") if o.strip()]

app.add_middleware(
    CORSMiddleware,
    allow_origins=CORS_ORIGINS,
    allow_origin_regex=LOCAL_ORIGIN_REGEX,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/healthz")
def healthz(session: Session = Depends(get_session)):
    """상태 확인: 서버가 떠 있고 DB에 연결되면 200."""
    try:
        session.exec(select(1))
    except SQLAlchemyError:
        raise HTTPException(503, "DB에 연결할 수 없습니다")
    return {"status": "ok"}


@app.post("/sites", status_code=201, dependencies=[Depends(require_admin)])
def register_site(data: SiteCreate, session: Session = Depends(get_session)):
    rss_url = data.rss_url.strip()
    if not rss_url.startswith(("http://", "https://")):
        raise HTTPException(400, "RSS 주소는 http:// 또는 https:// 로 시작해야 합니다")
    if session.exec(select(Site).where(Site.rss_url == rss_url)).first():
        raise HTTPException(409, "이미 등록된 RSS 주소입니다")

    try:
        site, baseline = create_site(session, data.name.strip(), rss_url)
    except FeedError as e:
        raise HTTPException(400, f"RSS를 확인할 수 없습니다: {e}")
    return {"site": site, "baseline_posts": len(baseline)}


@app.get("/sites")
def list_sites(session: Session = Depends(get_session)):
    return session.exec(select(Site).order_by(Site.id)).all()


@app.delete("/sites/{site_id}", status_code=204, dependencies=[Depends(require_admin)])
def delete_site(site_id: int, session: Session = Depends(get_session)):
    site = session.get(Site, site_id)
    if not site:
        raise HTTPException(404, "사이트를 찾을 수 없습니다")
    post_ids = select(Post.id).where(Post.site_id == site_id)
    # 글을 참조하는 테이블부터 삭제 (tasks는 마감도 참조하므로 마감보다 먼저)
    session.exec(delete(Task).where(Task.notice_id.in_(post_ids)))
    session.exec(delete(TaskBreakdown).where(TaskBreakdown.notice_id.in_(post_ids)))
    session.exec(delete(NoticeDeadline).where(NoticeDeadline.notice_id.in_(post_ids)))
    session.exec(delete(PostAnalysis).where(PostAnalysis.post_id.in_(post_ids)))
    session.exec(delete(Post).where(Post.site_id == site_id))
    session.delete(site)
    session.commit()


@app.post("/sites/{site_id}/check", dependencies=[Depends(require_admin)])
def check_now(site_id: int, session: Session = Depends(get_session)):
    """테스트용: 지금 바로 확인. 3단계에서 스케줄러가 같은 함수를 주기적으로 호출."""
    site = session.get(Site, site_id)
    if not site:
        raise HTTPException(404, "사이트를 찾을 수 없습니다")
    try:
        new_posts = check_site(session, site)
    except FeedError as e:
        raise HTTPException(502, f"확인 실패: {e}")
    return {"new_count": len(new_posts), "new_posts": new_posts}


@app.post("/check-all", dependencies=[Depends(require_admin)])
def check_all_now():
    """테스트용: 스케줄러가 하는 '전체 확인'을 지금 바로 1회 실행."""
    return check_all_sites()


@app.get("/posts")
def list_posts(
    site_id: Optional[int] = None,
    limit: int = 50,
    session: Session = Depends(get_session),
):
    query = select(Post).order_by(Post.detected_at.desc(), Post.id.desc()).limit(min(limit, 200))
    if site_id is not None:
        query = query.where(Post.site_id == site_id)
    return session.exec(query).all()


@app.get("/notices")
def list_notices(
    site_id: Optional[int] = None,
    limit: int = 50,
    sort: Literal["latest", "deadline"] = "latest",
    session: Session = Depends(get_session),
    user_id: int = Depends(current_user_id),
):
    """공지 카드 목록. 분석 전인 공지도 포함 (analyzed=false).

    sort=latest는 게시일 최신순. deadline은 다가오는 마감이 가까운 순이고, 다가오는 마감이 없는 공지는 그 뒤에 최신순.
    """
    today = today_kst()
    # 게시일은 '2026-10-07 09:00:00.0'(RSS)과 '2026.10.07'(상세 페이지) 두 형식이라 구분자를 맞춰 비교
    published = func.replace(Post.published, ".", "-")
    order = [published.desc(), Post.id.desc()]
    query = (
        select(Post, Site.name, PostAnalysis)
        .join(Site, Post.site_id == Site.id)
        .outerjoin(PostAnalysis, PostAnalysis.post_id == Post.id)
    )
    if sort == "deadline":
        # 카드에 보이는 '다음 마감'과 같은 기준. 시간이 없는 마감은 그날 끝으로 봄
        upcoming = (
            select(
                NoticeDeadline.notice_id,
                func.min(NoticeDeadline.deadline_date + func.coalesce(NoticeDeadline.deadline_time, time(23, 59, 59))).label("at"),
            )
            .where(NoticeDeadline.deadline_date >= today)
            .group_by(NoticeDeadline.notice_id)
            .subquery()
        )
        query = query.outerjoin(upcoming, upcoming.c.notice_id == Post.id)
        order.insert(0, upcoming.c.at.asc().nulls_last())
    query = query.order_by(*order).limit(min(limit, 200))
    if site_id is not None:
        query = query.where(Post.site_id == site_id)
    rows = session.exec(query).all()
    ids = [post.id for post, _, _ in rows]
    next_deadline = {}
    for d in session.exec(
        select(NoticeDeadline)
        .where(NoticeDeadline.notice_id.in_(ids), NoticeDeadline.deadline_date >= today)
        .order_by(NoticeDeadline.deadline_date, NoticeDeadline.deadline_time)
    ).all():
        next_deadline.setdefault(d.notice_id, d)
    saved = set(session.exec(
        select(Task.notice_id).where(Task.user_id == user_id, Task.notice_id.in_(ids), Task.status == "confirmed")
    ).all())
    return [
        {
            "id": post.id, "title": post.title, "link": homepage_url(post.link), "board": board, "published": post.published,
            "analyzed": analysis is not None,
            "summary": analysis.result.get("summary") if analysis else None,
            "apply_method": analysis.result.get("apply_method") if analysis else None,
            "next_deadline": next_deadline.get(post.id),
            "saved": post.id in saved,
        }
        for post, board, analysis in rows
    ]


def get_post(session: Session, notice_id: int) -> Post:
    post = session.get(Post, notice_id)
    if not post:
        raise HTTPException(404, "공지를 찾을 수 없습니다")
    return post


def get_my_task(session: Session, task_id: int, user_id: int) -> Task:
    task = session.get(Task, task_id)
    if not task or task.user_id != user_id:
        raise HTTPException(404, "할 일을 찾을 수 없습니다")
    return task


@app.get("/tasks")
def my_tasks(session: Session = Depends(get_session), user_id: int = Depends(current_user_id)):
    """'내 할 일': 저장(confirmed)한 할 일을 마감이 가까운 순으로. 완료한 것도 포함 (is_done으로 구분)."""
    return list_confirmed_tasks(session, user_id)


@app.get("/deadlines")
def my_deadlines(session: Session = Depends(get_session), user_id: int = Depends(current_user_id)):
    """캘린더: 내가 담은 공지의 날짜 있는 마감을 빠른 순으로."""
    return list_confirmed_deadlines(session, user_id)


@app.post("/notices/{notice_id}/tasks")
def create_tasks(
    notice_id: int,
    regenerate: bool = False,
    session: Session = Depends(get_session),
    user_id: int = Depends(current_user_id),
    admin: bool = Depends(is_admin),
):
    """'이거 할래' 미리보기: 할 일을 draft로 만들고, 미리보기에 필요한 마감·신청 방식(근거 포함)·unclear와 함께 반환.

    할 일이 이미 있으면(저장한 공지 포함) 그대로 반환하고 Gemini를 다시 부르지 않음. '저장'은 /confirm. 처음 분해하는 공지면 10초 안팎 걸림. regenerate=true면 다시 분해 (배포 서버에서는 관리자만).
    """
    if regenerate and not admin:
        raise HTTPException(403, "관리자 키가 필요합니다")
    post = get_post(session, notice_id)
    try:
        return prepare_tasks(session, user_id, post, regenerate)
    except NotAnalyzedError as e:
        raise HTTPException(409, str(e))
    except DailyLimitError as e:
        raise HTTPException(429, str(e))
    except BreakdownError as e:
        raise HTTPException(502, f"할 일 분해 실패: {e}")


@app.post("/notices/{notice_id}/tasks/confirm")
def confirm_notice_tasks(
    notice_id: int,
    session: Session = Depends(get_session),
    user_id: int = Depends(current_user_id),
):
    """미리보기의 '저장': 이 공지의 내 draft 할 일을 모두 confirmed로 (이미 저장했으면 그대로)."""
    return confirm_tasks(session, user_id, get_post(session, notice_id))


@app.post("/notices/{notice_id}/tasks/items", status_code=201)
def create_task_item(
    notice_id: int,
    data: TaskCreate,
    session: Session = Depends(get_session),
    user_id: int = Depends(current_user_id),
):
    """할 일 직접 추가 (근거 없음)."""
    post = get_post(session, notice_id)
    try:
        return add_task(session, user_id, post, data.title, data.note)
    except ValueError as e:
        raise HTTPException(400, str(e))


@app.delete("/tasks/{task_id}", status_code=204)
def delete_task(
    task_id: int,
    session: Session = Depends(get_session),
    user_id: int = Depends(current_user_id),
):
    task = get_my_task(session, task_id, user_id)
    session.delete(task)
    if task.notice_id is not None:  # 일정의 할 일은 항목마다 날짜가 정해져 있어 다시 배정하지 않음
        reschedule(session, user_id, task.notice_id)
    session.commit()


@app.patch("/tasks/{task_id}")
def update_task(
    task_id: int,
    data: TaskUpdate,
    session: Session = Depends(get_session),
    user_id: int = Depends(current_user_id),
):
    task = get_my_task(session, task_id, user_id)
    try:
        apply_update(task, data.model_dump(exclude_unset=True))
    except ValueError as e:
        raise HTTPException(400, str(e))
    session.add(task)
    session.commit()
    session.refresh(task)
    return task


def get_my_schedule(session: Session, schedule_id: int, user_id: int) -> Schedule:
    schedule = get_schedule(session, user_id, schedule_id)
    if not schedule:
        raise HTTPException(404, "일정을 찾을 수 없습니다")
    return schedule


@app.get("/schedules")
def my_schedules(session: Session = Depends(get_session), user_id: int = Depends(current_user_id)):
    """일정 목록: 직접 만든 일정(시험·공모전)과 공지에서 담은 것을 함께."""
    return list_schedules(session, user_id, today_kst())


@app.post("/schedules", status_code=201)
def create_my_schedule(data: ScheduleCreate, session: Session = Depends(get_session), user_id: int = Depends(current_user_id)):
    try:
        return create_schedule(session, user_id, data.kind, data.title, data.target_date, data.use_checklist)
    except ValueError as e:
        raise HTTPException(400, str(e))


@app.get("/schedules/{schedule_id}")
def my_schedule(schedule_id: int, session: Session = Depends(get_session), user_id: int = Depends(current_user_id)):
    return schedule_detail(session, get_my_schedule(session, schedule_id, user_id))


@app.patch("/schedules/{schedule_id}")
def update_my_schedule(
    schedule_id: int,
    data: ScheduleUpdate,
    session: Session = Depends(get_session),
    user_id: int = Depends(current_user_id),
):
    """제목·날짜 수정. 날짜가 바뀌면 완료하지 않은 기본 체크리스트 항목의 예정일을 다시 계산."""
    schedule = get_my_schedule(session, schedule_id, user_id)
    try:
        return update_schedule(session, schedule, data.model_dump(exclude_unset=True))
    except ValueError as e:
        raise HTTPException(400, str(e))


@app.delete("/schedules/{schedule_id}", status_code=204)
def delete_my_schedule(schedule_id: int, session: Session = Depends(get_session), user_id: int = Depends(current_user_id)):
    """일정과 그 체크리스트를 함께 삭제."""
    delete_schedule(session, get_my_schedule(session, schedule_id, user_id))


@app.post("/schedules/{schedule_id}/tasks", status_code=201)
def create_schedule_task(
    schedule_id: int,
    data: ScheduleTaskCreate,
    session: Session = Depends(get_session),
    user_id: int = Depends(current_user_id),
):
    schedule = get_my_schedule(session, schedule_id, user_id)
    try:
        return add_schedule_task(session, user_id, schedule, data.title, data.phase, data.scheduled_date)
    except ValueError as e:
        raise HTTPException(400, str(e))


@app.get("/reviews/weekly")
def get_weekly_review(
    week: Optional[date] = None,
    session: Session = Depends(get_session),
    user_id: int = Depends(current_user_id),
):
    """주간 회고: week(그 주의 아무 날짜, 없으면 오늘)가 속한 주(일~토)의 완료율·못 끝낸 할 일·메모."""
    return weekly_review(session, user_id, week)


@app.put("/reviews/weekly")
def put_weekly_review(
    data: ReviewUpdate,
    week: Optional[date] = None,
    session: Session = Depends(get_session),
    user_id: int = Depends(current_user_id),
):
    """회고 메모 저장 (그 주에 이미 있으면 덮어씀, 비우면 null). 저장 후 회고 전체를 반환."""
    try:
        return save_memo(session, user_id, week, data.memo)
    except ValueError as e:
        raise HTTPException(400, str(e))


class WebFiles(StaticFiles):
    """Flutter 웹 화면. 파일 이름에 버전이 없어, 다시 배포한 뒤 옛 화면이 남지 않도록 브라우저가 매번 서버에 확인하게 함."""

    async def get_response(self, path, scope):
        response = await super().get_response(path, scope)
        response.headers["Cache-Control"] = "no-cache"
        return response


# 위의 API 경로에 해당하지 않는 요청만 여기로 옴 (반드시 맨 마지막에 등록). 빌드 결과가 없으면 API만 제공
if WEB_DIR.is_dir():
    app.mount("/", WebFiles(directory=WEB_DIR, html=True), name="web")
