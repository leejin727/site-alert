"""배포용 설정 확인용. 사용법: python3 -m serve.test_deploy

Gemini 호출은 가짜 함수로 바꿔 끼우고, DB는 트랜잭션 안에서 실행한 뒤 롤백하므로 실제 데이터는 남지 않습니다.
"""
import os
import subprocess
import sys
from datetime import timedelta
from pathlib import Path

from fastapi.testclient import TestClient
from sqlmodel import Session, create_engine

from serve import main
from serve import tasks
from serve.analyze import NoticeAnalysis, save_analysis
from serve.db import engine, get_session, normalize_url
from serve.models import Post, Site
from serve.schedule import today_kst
from serve.tasks import BreakdownItem, BreakdownResult

KEY = {"X-Admin-Key": "test-admin-key"}


def test_normalize_url():
    assert normalize_url("postgres://u:p@host:5432/db") == "postgresql+psycopg://u:p@host:5432/db"
    assert normalize_url("postgresql://u:p@host:5432/db") == "postgresql+psycopg://u:p@host:5432/db"
    assert normalize_url("postgresql+psycopg://u:p@host/db") == "postgresql+psycopg://u:p@host/db"
    assert normalize_url("postgresql://u:postgres://x@host/db") == "postgresql+psycopg://u:postgres://x@host/db"  # 맨 앞만 바꿈


def test_healthz():
    client = TestClient(main.app)  # with 없이 써서 스케줄러(lifespan)는 켜지 않음
    res = client.get("/healthz")
    assert res.status_code == 200 and res.json() == {"status": "ok"}
    unreachable = create_engine("postgresql+psycopg://x:x@127.0.0.1:1/x")  # 아무것도 듣지 않는 포트
    main.app.dependency_overrides[get_session] = lambda: Session(unreachable)
    try:
        assert client.get("/healthz").status_code == 503
    finally:
        main.app.dependency_overrides.clear()


def test_web():
    assert main.WEB_DIR.is_dir(), "serve/web이 없습니다. ./build_web.sh 를 먼저 실행하세요"
    client = TestClient(main.app)
    for path in ("/", "/index.html"):
        res = client.get(path)
        assert res.status_code == 200 and res.headers["content-type"].startswith("text/html"), path
        assert "flutter_bootstrap.js" in res.text
        assert res.headers["cache-control"] == "no-cache"
    assert client.get("/main.dart.js").status_code == 200
    assert client.get("/canvaskit/canvaskit.wasm").status_code == 200  # 화면 엔진도 같은 서버에서
    # API 경로는 화면 파일보다 먼저 걸림
    for path in ("/notices?limit=1", "/sites", "/tasks", "/schedules"):
        res = client.get(path)
        assert res.status_code == 200 and res.headers["content-type"] == "application/json", path
    assert client.get("/no-such-page").status_code == 404
    assert client.get("/../.env").status_code == 404


def test_admin_key():
    client = TestClient(main.app)
    original = main.PRODUCTION, main.ADMIN_KEY, main.check_all_sites
    main.check_all_sites = lambda: {"checked": 0}  # 실제 수집을 하지 않도록
    # 관리자 확인을 통과하면 각 엔드포인트가 원래 내던 응답이 나옴 (잘못된 주소 400, 없는 id 404)
    requests = [
        ("post", "/sites", {"json": {"name": "x", "rss_url": "ftp://example.com/rss"}}, 400),
        ("delete", "/sites/999999999", {}, 404),
        ("post", "/sites/999999999/check", {}, 404),
        ("post", "/check-all", {}, 200),
        ("post", "/notices/999999999/tasks?regenerate=true", {}, 404),
    ]

    def statuses(headers):
        return [getattr(client, method)(url, headers=headers, **kwargs).status_code for method, url, kwargs, _ in requests]

    try:
        main.PRODUCTION, main.ADMIN_KEY = False, ""
        assert statuses({}) == [expected for *_, expected in requests]  # 로컬: 키 없이 그대로

        main.PRODUCTION, main.ADMIN_KEY = True, "test-admin-key"
        assert statuses({}) == [403] * 5
        assert statuses({"X-Admin-Key": "wrong"}) == [403] * 5
        assert statuses({"X-Admin-Key": ""}) == [403] * 5
        assert statuses(KEY) == [expected for *_, expected in requests]
        assert client.post("/notices/999999999/tasks").status_code == 404  # regenerate 없는 미리보기는 누구나
        assert client.get("/notices?limit=1").status_code == 200

        main.ADMIN_KEY = ""  # 키를 설정하지 않은 배포 서버: 빈 헤더로도 통과하지 못함
        assert statuses({"X-Admin-Key": ""}) == [403] * 5
        assert statuses({}) == [403] * 5
    finally:
        main.PRODUCTION, main.ADMIN_KEY, main.check_all_sites = original


def test_daily_limit():
    calls = []

    def fake_request(post, board, apply_method, deadlines):
        calls.append(post.title)
        return BreakdownResult(tasks=[BreakdownItem(title="신청서 제출", deadline_index=None, evidence="신청서 제출")]), "fake-model", "신청서 제출"

    with engine.connect() as conn, conn.begin() as tx:
        session = Session(bind=conn, join_transaction_mode="create_savepoint")
        main.app.dependency_overrides[get_session] = lambda: session
        original = tasks.request_breakdown, tasks.DAILY_LIMIT, tasks.today_kst, dict(tasks._calls)
        tasks.request_breakdown = fake_request
        try:
            site = Site(name="테스트", rss_url="https://example.com/test-deploy-rss")
            session.add(site)
            session.commit()
            posts = [Post(site_id=site.id, post_key=f"deploy-{i}", title=f"공지 {i}", link=f"https://example.com/{i}", published="2026.11.18") for i in range(4)]
            session.add_all(posts)
            session.commit()
            analysis = NoticeAnalysis(
                summary="안내", category="학사", target="재학생", target_evidence=None, undergrad="불명확", undergrad_evidence=None,
                deadlines=[], apply_method="기간 내 제출", apply_method_evidence=None,
            )
            for post in posts:
                save_analysis(session, post, analysis, "m", "상세페이지", 0)
            session.commit()
            client = TestClient(main.app)
            url = lambda i: f"/notices/{posts[i].id}/tasks"

            tasks.DAILY_LIMIT = None  # 로컬: 제한 없음, 세지도 않음
            tasks._calls.update(day=None, count=0)
            assert client.post(url(0)).status_code == 200 and tasks._calls["count"] == 0

            tasks.DAILY_LIMIT = 2
            assert client.post(url(1)).status_code == 200
            assert client.post(url(2)).status_code == 200
            res = client.post(url(3))
            assert res.status_code == 429 and "내일 다시" in res.json()["detail"]
            assert calls == ["공지 0", "공지 1", "공지 2"]  # 상한을 넘으면 Gemini를 부르지 않음
            assert client.post(url(1)).status_code == 200  # 이미 분해한 공지는 상한과 무관하게 열림
            assert len(calls) == 3

            tomorrow = today_kst() + timedelta(days=1)
            tasks.today_kst = lambda: tomorrow  # 날짜가 바뀌면 다시 0부터
            assert client.post(url(3)).status_code == 200
            assert tasks._calls == {"day": tomorrow, "count": 1}
        finally:
            tasks.request_breakdown, tasks.DAILY_LIMIT, tasks.today_kst, calls_before = original
            tasks._calls.update(calls_before)
            main.app.dependency_overrides.clear()
            session.close()
            tx.rollback()


def test_production_startup():
    """APP_ENV는 서버를 시작할 때 읽으므로 새 프로세스에서 확인."""
    code = (
        "from fastapi.testclient import TestClient\n"
        "from serve import main, tasks\n"
        "client = TestClient(main.app)\n"
        "docs = [client.get(p).status_code for p in ('/docs', '/redoc', '/openapi.json')]\n"
        "assert docs == EXPECTED_DOCS, docs\n"
        "assert tasks.DAILY_LIMIT == EXPECTED_LIMIT, tasks.DAILY_LIMIT\n"
        "assert client.get('/healthz').status_code == 200\n"
        "assert client.delete('/sites/999999999').status_code == EXPECTED_DELETE\n"
    )
    root = Path(__file__).resolve().parent.parent
    cases = [
        ({"APP_ENV": "production", "TASK_DAILY_LIMIT": "7", "ADMIN_KEY": "k"}, "[404, 404, 404]", "7", "403"),
        ({"APP_ENV": "production", "TASK_DAILY_LIMIT": "", "ADMIN_KEY": ""}, "[404, 404, 404]", "50", "403"),
        ({"APP_ENV": "", "TASK_DAILY_LIMIT": "7", "ADMIN_KEY": "k"}, "[200, 200, 200]", "None", "404"),
    ]
    for env, docs, limit, deleted in cases:
        script = code.replace("EXPECTED_DOCS", docs).replace("EXPECTED_LIMIT", limit).replace("EXPECTED_DELETE", deleted)
        result = subprocess.run([sys.executable, "-c", script], cwd=root, env={**os.environ, **env}, capture_output=True, text=True)
        assert result.returncode == 0, f"{env}\n{result.stderr}"


if __name__ == "__main__":
    test_normalize_url()
    test_healthz()
    test_web()
    test_admin_key()
    test_daily_limit()
    test_production_startup()
    print("OK")
