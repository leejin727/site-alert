"""등록된 모든 사이트를 주기적으로 자동 확인하고, 분석 안 된 글을 Gemini로 분석해 저장. 저장하지 않은 draft 할 일도 정리."""
import logging
import os
import time
from datetime import datetime, timedelta

from apscheduler.schedulers.background import BackgroundScheduler
from google import genai
from google.genai import types
from sqlmodel import Session, select

from serve.analyze import FALLBACK_MODEL, MODEL, WAIT_SECONDS, analyze_post, save_analysis
from serve.db import engine
from serve.models import Post, PostAnalysis, Site, now_utc
from serve.rss import check_site
from serve.tasks import delete_stale_drafts

# uvicorn 로그와 같은 형식으로 터미널에 출력
logger = logging.getLogger("uvicorn.error")

# 확인 간격(분). 서버가 켜질 때도 한 번 확인함. 테스트할 땐 환경변수로 1 등을 지정
CHECK_INTERVAL_MINUTES = float(os.getenv("CHECK_INTERVAL_MINUTES", "10"))
# 분석 재시도 간격(분). 새 글은 확인 직후 바로 분석하고, 이 주기는 실패한 글과 수동 확인(/sites/{id}/check)으로 들어온 글을 처리
ANALYZE_INTERVAL_MINUTES = float(os.getenv("ANALYZE_INTERVAL_MINUTES", "30"))
ANALYZE_BATCH = 20  # 한 번에 읽어 오는 글 수. 남은 글이 없을 때까지 이어서 분석
# 새 공지가 빨리 보이도록 자동 분석은 빠른 모델을 먼저 쓰고, 실패하면 기본 모델로
AUTO_MODELS = (FALLBACK_MODEL, MODEL)
FAST_TIMEOUT_SECONDS = 60  # 빠른 모델이 이 시간 안에 답하지 않으면 기본 모델로
# 모델 한 번 호출의 제한 시간(초). 기본 모델은 1~2분씩 걸리기도 해서 넉넉히. 멈춘 호출이 뒤 글의 분석을 막지 않게 함
GEMINI_TIMEOUT_SECONDS = int(os.getenv("GEMINI_TIMEOUT_SECONDS", "300"))
DRAFT_TTL = timedelta(hours=24)  # 미리보기만 열고 저장하지 않은 할 일을 남겨 두는 시간
CLEANUP_INTERVAL_MINUTES = 60

scheduler = BackgroundScheduler()


def check_all_sites() -> dict:
    """모든 사이트 확인. 한 사이트가 실패해도 나머지는 계속 진행."""
    summary = {"checked": 0, "failed": 0, "new_posts": 0}
    with Session(engine) as session:
        sites = session.exec(select(Site).order_by(Site.id)).all()
        for site in sites:
            name = site.name
            try:
                new_posts = check_site(session, site)
            except Exception as e:  # RSS 오류, DB 오류 등
                session.rollback()
                summary["failed"] += 1
                logger.warning("[자동확인] %s 실패: %s", name, e)
                continue
            summary["checked"] += 1
            summary["new_posts"] += len(new_posts)
            for p in new_posts:
                # 5단계에서 이 부분이 '푸시 알림 발송'으로 바뀝니다
                logger.info("[새 글][%s] %s %s", name, p.title, p.link)
    logger.info("[자동확인] 완료: %s", summary)
    if summary["new_posts"]:
        analyze_now()
    return summary


def analyze_now() -> None:
    """분석 주기를 기다리지 않고 바로 실행. 이미 분석 중이면 그 실행이 새 글까지 이어서 처리함."""
    if scheduler.running:
        scheduler.modify_job("analyze_pending", next_run_time=datetime.now().astimezone())


def analyze_pending() -> dict:
    """분석 결과가 없는 글을 최근 감지 순으로, 남은 글이 없을 때까지 분석해 저장. 실패하면 이번 회차는 멈추고 다음 주기에 재시도."""
    summary = {"analyzed": 0, "failed": 0}
    if not os.getenv("GEMINI_API_KEY"):
        logger.warning("[자동분석] GEMINI_API_KEY가 없어 건너뜁니다")
        return summary
    client = genai.Client(http_options=types.HttpOptions(timeout=GEMINI_TIMEOUT_SECONDS * 1000))
    with Session(engine) as session:
        while not summary["failed"]:
            rows = session.exec(
                select(Post, Site.name)
                .join(Site, Post.site_id == Site.id)
                .outerjoin(PostAnalysis, PostAnalysis.post_id == Post.id)
                .where(PostAnalysis.id == None)  # noqa: E711 (SQL의 IS NULL)
                .order_by(Post.detected_at.desc(), Post.id.desc())
                .limit(ANALYZE_BATCH)
            ).all()
            if not rows:
                break
            for post, board in rows:
                if summary["analyzed"]:
                    time.sleep(WAIT_SECONDS)
                try:
                    a, used_model, source, _, n_images = analyze_post(client, board, post, AUTO_MODELS, FAST_TIMEOUT_SECONDS)
                    save_analysis(session, post, a, used_model, source, n_images)
                except Exception as e:
                    # 할당량 소진·네트워크 오류면 나머지도 실패할 것이므로 멈춤
                    # shortcut: 항상 실패하는 글은 매 주기 재시도되고 그보다 오래된 글 분석을 막음, 그런 글이 보이면 실패 기록 컬럼 추가
                    session.rollback()
                    summary["failed"] += 1
                    logger.warning("[자동분석] %s 실패, 다음 주기에 재시도: %s", post.title, str(e)[:200])
                    break
                summary["analyzed"] += 1
                logger.info("[자동분석] %s → 학부생 %s, 마감 %d개, %s", post.title, a.undergrad, len(a.deadlines), a.apply_method)
    if summary["analyzed"] or summary["failed"]:
        logger.info("[자동분석] 완료: %s", summary)
    return summary


def cleanup_drafts() -> int:
    """미리보기만 열고 '저장'하지 않은 draft 할 일을 정리. 마지막으로 만들거나 고친 지 DRAFT_TTL이 지난 것만 삭제."""
    with Session(engine) as session:
        deleted = delete_stale_drafts(session, now_utc() - DRAFT_TTL)
    if deleted:
        logger.info("[draft정리] 저장하지 않은 할 일 %d개 삭제", deleted)
    return deleted


def start_scheduler() -> None:
    now = datetime.now().astimezone()
    for func, minutes, first_run in [
        (check_all_sites, CHECK_INTERVAL_MINUTES, now),
        (analyze_pending, ANALYZE_INTERVAL_MINUTES, now),  # 서버가 꺼져 있던 동안 남은 글
        (cleanup_drafts, CLEANUP_INTERVAL_MINUTES, now + timedelta(minutes=CLEANUP_INTERVAL_MINUTES)),
    ]:
        scheduler.add_job(
            func,
            "interval",
            minutes=minutes,
            next_run_time=first_run,
            id=func.__name__,
            max_instances=1,          # 이전 실행이 안 끝났으면 겹쳐 실행하지 않음
            coalesce=True,            # 밀린 실행이 여러 번이어도 한 번만 실행
            misfire_grace_time=None,  # 맥이 잠자기에서 깨어나면 밀린 실행을 바로 실행
            replace_existing=True,
        )
    scheduler.start()
    for job in scheduler.get_jobs():
        logger.info("[스케줄러] %s 시작, 다음 실행 %s", job.id, job.next_run_time)


def stop_scheduler() -> None:
    if scheduler.running:
        scheduler.shutdown(wait=False)