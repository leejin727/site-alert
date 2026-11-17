"""'이거 할래' API 확인용. 사용법: python3 -m serve.test_tasks

Gemini 호출은 가짜 함수로 바꿔 끼우고, DB는 트랜잭션 안에서 실행한 뒤 롤백하므로 실제 데이터는 남지 않습니다.
"""
from datetime import date, time, timedelta

from fastapi.testclient import TestClient
from sqlmodel import Session, select

from serve import main
from serve import tasks
from serve.analyze import Deadline, NoticeAnalysis, save_analysis
from serve.db import engine, get_session
from serve.models import NoticeDeadline, Post, Site, Task, User, WeeklyReview, now_utc
from serve.reviews import week_range
from serve.schedule import plan_dates, today_kst
from serve.tasks import BreakdownItem, BreakdownResult, delete_stale_drafts, validate_items

BODY = "1. 신청 기간: 10.16(금) 18:00까지\n2. 제출 서류: 재학증명서 1부\n3. 학사포털에서   신청서 작성 후 제출"


def item(title, evidence, index=None) -> BreakdownItem:
    return BreakdownItem(title=title, deadline_index=index, evidence=evidence)


def test_validate_items():
    kept = validate_items(0, [
        item("재학증명서 발급", "제출 서류: 재학증명서 1부", 0),
        item("신청서 작성", "학사포털에서 신청서 작성 후\n제출"),  # 공백·줄바꿈 차이는 통과
        item("근거 없음", "  "),
        item("지어낸 근거", "면접 일정은 추후 안내"),
        item("포스터 확인", "(이미지) 접수처: 학생지원팀"),  # 이미지 근거는 대조하지 않음
        item("번호 범위 밖", "신청 기간: 10.16(금) 18:00까지", 5),
    ], BODY, n_deadlines=1)
    assert [k["title"] for k in kept] == ["재학증명서 발급", "신청서 작성", "포스터 확인", "번호 범위 밖"]
    assert kept[0]["deadline_index"] == 0 and kept[3]["deadline_index"] is None


def test_plan_dates():
    today = date(2026, 11, 3)
    d = lambda month, day: date(2026, month, day)
    # 기간 내 제출: 마지막 할 일이 마감 3일 전, 앞의 할 일은 하루씩 거꾸로. 마감이 다르면 따로 계산
    assert plan_dates("기간 내 제출", [(1, d(11, 20)), (2, d(11, 20)), (3, d(11, 20)), (4, d(12, 1))], today) == {
        1: d(11, 15), 2: d(11, 16), 3: d(11, 17), 4: d(11, 28),
    }
    # 지난 날짜는 오늘로, 마감이 없으면 비워 둠
    assert plan_dates("기간 내 제출", [(1, d(11, 7)), (2, d(11, 7)), (3, None)], today) == {1: today, 2: d(11, 4), 3: None}
    # 선발·불명확 등도 역산, 선착순만 마감과 상관없이 오늘
    assert plan_dates("선발", [(1, d(11, 20))], today) == plan_dates(None, [(1, d(11, 20))], today) == {1: d(11, 17)}
    assert plan_dates("선착순", [(1, d(11, 20)), (2, None)], today) == {1: today, 2: today}


def test_api():
    calls = []

    def fake_request(post, board, apply_method, deadlines):
        calls.append(apply_method)
        n = len(calls)
        return BreakdownResult(tasks=[
            item(f"재학증명서 발급 {n}", "재학증명서 1부", 0),
            item(f"신청서 제출 {n}", "신청서 작성 후 제출", 0),
            item("근거 없는 일", ""),
        ]), "fake-model", BODY

    with engine.connect() as conn, conn.begin() as tx:
        session = Session(bind=conn, join_transaction_mode="create_savepoint")
        main.app.dependency_overrides[get_session] = lambda: session
        original = tasks.request_breakdown
        tasks.request_breakdown = fake_request
        try:
            site = Site(name="테스트", rss_url="https://example.com/test-rss")
            session.add(site)
            session.commit()
            post = Post(site_id=site.id, post_key="test-1", title="학점포기 신청 안내", link="https://example.com/1", published="2026.10.06")
            session.add(post)
            session.add(User(id=999_001))  # 다른 사용자
            session.commit()
            client = TestClient(main.app)  # with 없이 써서 스케줄러(lifespan)는 켜지 않음
            url = f"/notices/{post.id}/tasks"

            def card():
                return next(n for n in client.get("/notices", params={"site_id": site.id}).json() if n["id"] == post.id)

            def my_titles():
                return [t["title"] for t in client.post(url).json()["tasks"]]

            assert client.post("/notices/999999999/tasks").status_code == 404
            assert client.post(url).status_code == 409  # 분석 전
            assert card()["analyzed"] is False and card()["next_deadline"] is None

            due = today_kst() + timedelta(days=30)
            before = lambda days: (due - timedelta(days=days)).isoformat()
            analysis = NoticeAnalysis(
                summary="학점포기 안내", category="학사", target="재학생", target_evidence=None, undergrad="불명확", undergrad_evidence=None,
                deadlines=[Deadline(label="신청", year=due.year, month=due.month, day=due.day, time="18:00", confidence="높음", evidence="18:00까지")],
                apply_method="기간 내 제출", apply_method_evidence="기간 내 신청하여 주시기 바랍니다",
            )
            save_analysis(session, post, analysis, "m", "상세페이지", 0)
            c = card()
            assert c["analyzed"] and c["summary"] == "학점포기 안내" and c["apply_method"] == "기간 내 제출"
            assert c["next_deadline"]["deadline_date"] == due.isoformat() and c["saved"] is False

            # 미리보기 열기: Gemini 1회, 근거 없는 항목 제외, draft로 만들어지고 미리보기 내용을 함께 반환
            r = client.post(url).json()
            assert calls == ["기간 내 제출"]
            assert r["notice"]["link"] == "https://example.com/1" and r["unclear"] == ["undergrad"]
            assert r["apply_method_evidence"] == "기간 내 신청하여 주시기 바랍니다" and r["deadlines"][0]["evidence"] == "18:00까지"
            assert [(t["title"], t["source"], t["evidence"]) for t in r["tasks"]] == [
                ("재학증명서 발급 1", "ai", "재학증명서 1부"), ("신청서 제출 1", "ai", "신청서 작성 후 제출"),
            ]
            assert all(t["id"] and t["deadline_id"] == r["deadlines"][0]["id"] for t in r["tasks"])
            assert r["confirmed"] is False and {t["status"] for t in r["tasks"]} == {"draft"}
            assert [t["scheduled_date"] for t in r["tasks"]] == [before(4), before(3)]  # 마감에서 역산
            assert card()["saved"] is False  # 둘러보기만 해서는 담은 것으로 보이지 않음

            # 저장 전에 다시 열기: 남아 있는 draft를 그대로, Gemini 안 부름
            again = client.post(url).json()
            assert [t["id"] for t in again["tasks"]] == [t["id"] for t in r["tasks"]] and len(calls) == 1

            # PATCH 수정·완료
            first_id, second_id = r["tasks"][0]["id"], r["tasks"][1]["id"]
            t = client.patch(f"/tasks/{first_id}", json={"title": " 재학증명서 온라인 발급 ", "note": "학생증 필요"}).json()
            assert t["title"] == "재학증명서 온라인 발급" and t["edited_fields"] == ["title", "note"]
            t = client.patch(f"/tasks/{first_id}", json={"is_done": True}).json()
            assert t["is_done"] and t["done_at"] and t["edited_fields"] == ["title", "note"]
            assert client.patch(f"/tasks/{first_id}", json={"title": " "}).status_code == 400
            assert client.patch(f"/tasks/{first_id}", json={"is_done": None}).status_code == 400

            # 직접 추가(저장 전이라 draft)·삭제
            added = client.post(f"{url}/items", json={"title": " 부모님께 말씀드리기 "})
            assert added.status_code == 201
            added = added.json()
            assert added["source"] == "user" and added["evidence"] is None and added["task_order"] == 2
            assert added["status"] == "draft"
            # 직접 추가한 일(마감 없음 → 공지의 마감)이 맨 뒤로 들어가 다시 계산. 완료한 일은 자리를 차지하지 않고 날짜도 그대로
            assert added["scheduled_date"] == before(3)
            dates = {t["title"]: t["scheduled_date"] for t in client.post(url).json()["tasks"]}
            assert dates == {"재학증명서 온라인 발급": before(4), "신청서 제출 1": before(4), "부모님께 말씀드리기": before(3)}
            assert client.post(f"{url}/items", json={"title": "  "}).status_code == 400
            assert client.post("/notices/999999999/tasks/items", json={"title": "x"}).status_code == 404
            assert client.delete(f"/tasks/{second_id}").status_code == 204
            assert client.delete(f"/tasks/{second_id}").status_code == 404
            assert my_titles() == ["재학증명서 온라인 발급", "부모님께 말씀드리기"]

            # 사용자가 고친 날짜는 다시 계산해도(저장 시) 그대로
            my_date = (today_kst() + timedelta(days=1)).isoformat()
            assert client.patch(f"/tasks/{added['id']}", json={"scheduled_date": my_date}).json()["edited_fields"] == ["scheduled_date"]

            # 저장: draft가 모두 confirmed, 카드에 '담은 할 일'로 표시
            confirmed = client.post(f"{url}/confirm").json()
            assert confirmed[1]["scheduled_date"] == my_date
            assert [(t["title"], t["status"]) for t in confirmed] == [("재학증명서 온라인 발급", "confirmed"), ("부모님께 말씀드리기", "confirmed")]
            assert card()["saved"] is True
            assert client.post(f"{url}/confirm").status_code == 200  # 다시 눌러도 그대로
            assert client.post("/notices/999999999/tasks/confirm").status_code == 404

            # 저장한 공지를 다시 열기: 기존 할 일 그대로, Gemini 안 부름. 이후 직접 추가는 바로 confirmed
            reopened = client.post(url).json()
            assert reopened["confirmed"] is True and [t["id"] for t in reopened["tasks"]] == [t["id"] for t in confirmed] and len(calls) == 1
            later = client.post(f"{url}/items", json={"title": "나중에 추가"}).json()
            assert later["status"] == "confirmed"
            assert client.delete(f"/tasks/{later['id']}").status_code == 204

            # 다른 사용자의 할 일은 고치거나 지울 수 없음
            other = Task(user_id=999_001, notice_id=post.id, title="남의 일", task_order=0, evidence="x")
            session.add(other)
            session.commit()
            assert client.patch(f"/tasks/{other.id}", json={"is_done": True}).status_code == 404
            assert client.delete(f"/tasks/{other.id}").status_code == 404

            # 재분해: 완료·수정·직접 추가한 할 일은 남고 새 결과는 draft로 더해짐 (저장해야 확정)
            regen = client.post(url, params={"regenerate": "true"}).json()
            assert len(calls) == 2
            assert [(t["title"], t["status"]) for t in regen["tasks"]] == [
                ("재학증명서 온라인 발급", "confirmed"), ("부모님께 말씀드리기", "confirmed"),
                ("재학증명서 발급 2", "draft"), ("신청서 제출 2", "draft"),
            ]
            client.post(f"{url}/confirm")

            # draft 정리: 24시간 지난 draft만 삭제 (고친 시각이 최근이면 남김, confirmed는 남김)
            old = now_utc() - timedelta(hours=25)
            stale = Task(user_id=999_001, notice_id=post.id, title="오래된 draft", task_order=0, evidence="x", created_at=old)
            touched = Task(user_id=999_001, notice_id=post.id, title="최근에 고친 draft", task_order=1, evidence="x", created_at=old, updated_at=now_utc())
            fresh = Task(user_id=999_001, notice_id=post.id, title="방금 만든 draft", task_order=2, evidence="x")
            old_confirmed = Task(user_id=999_001, notice_id=post.id, title="오래된 확정", task_order=3, evidence="x", created_at=old, status="confirmed")
            session.add_all([stale, touched, fresh, old_confirmed])
            session.commit()
            ids = {t.id for t in (stale, touched, fresh, old_confirmed)}
            assert delete_stale_drafts(session, now_utc() - timedelta(hours=24)) >= 1
            left = {t.title for t in session.exec(select(Task).where(Task.id.in_(ids))).all()}
            assert left == {"최근에 고친 draft", "방금 만든 draft", "오래된 확정"}
            assert len(my_titles()) == 4  # 내 확정된 할 일은 그대로

            # 재분석으로 마감이 사라지면 할 일은 남고 연결만 끊김
            save_analysis(session, post, analysis.model_copy(update={"deadlines": []}), "m", "상세페이지", 0)
            session.expire_all()
            assert all(t["deadline_id"] is None for t in client.post(url).json()["tasks"])
        finally:
            tasks.request_breakdown = original
            main.app.dependency_overrides.clear()
            session.close()
            tx.rollback()


def test_my_tasks():
    """GET /tasks: confirmed만, 마감 가까운 순, 마감 없는 할 일은 공지의 가장 빠른 마감, 그것도 없으면 맨 뒤."""
    with engine.connect() as conn, conn.begin() as tx:
        session = Session(bind=conn, join_transaction_mode="create_savepoint")
        main.app.dependency_overrides[get_session] = lambda: session
        try:
            site = Site(name="테스트", rss_url="https://example.com/test-rss-2")
            session.add(site)
            session.commit()
            a, b, c = (Post(site_id=site.id, post_key=f"k{i}", title=f"공지{i}", link=f"https://example.com/{i}") for i in "ABC")
            session.add_all([a, b, c, User(id=999_002)])
            session.commit()
            a_late = NoticeDeadline(notice_id=a.id, deadline_order=0, label="최종", deadline_date=date(2026, 12, 1), confidence="높음")
            a_early = NoticeDeadline(notice_id=a.id, deadline_order=1, label="1차", deadline_date=date(2026, 11, 5), confidence="높음")
            b_dl = NoticeDeadline(notice_id=b.id, deadline_order=0, label="신청", deadline_date=date(2026, 11, 5), deadline_time=time(18), confidence="높음")
            a_undated = NoticeDeadline(notice_id=a.id, deadline_order=2, label="추후", confidence="낮음")
            session.add_all([a_late, a_early, b_dl, a_undated])
            session.commit()

            def add(post, title, deadline=None, status="confirmed", user=1, done=False, order=0):
                t = Task(user_id=user, notice_id=post.id, deadline_id=deadline and deadline.id, title=title,
                         task_order=order, evidence="x", status=status, is_done=done)
                session.add(t)
                return t

            add(a, "A 최종 제출", a_late)
            add(b, "B 신청", b_dl)
            add(a, "A 직접 추가(마감 없음)", order=1)              # 공지 A의 가장 빠른 마감(11/5, 시각 없음)으로 정렬
            add(c, "C 마감 없는 공지")                              # 맨 뒤
            add(a, "A 1차 완료", a_early, done=True, order=2)       # 완료도 포함
            add(a, "A 날짜 미정 마감", a_undated, order=3)          # 날짜 없는 마감 → 공지의 가장 빠른 마감
            add(a, "A draft", a_early, status="draft")              # 제외
            add(a, "남의 할 일", a_early, user=999_002)             # 제외
            session.commit()

            items = TestClient(main.app).get("/tasks").json()
            mine = [i for i in items if i["notice"]["id"] in (a.id, b.id, c.id)]
            # 같은 날(11/5)이면 시각이 있는 B(18:00)가 먼저, 시각 없는 A 항목들은 그날의 맨 뒤에서 할 일 순서대로
            assert [i["title"] for i in mine] == [
                "B 신청", "A 직접 추가(마감 없음)", "A 1차 완료", "A 날짜 미정 마감", "A 최종 제출", "C 마감 없는 공지",
            ]
            by_title = {i["title"]: i for i in mine}
            assert by_title["A 직접 추가(마감 없음)"]["deadline"]["label"] == "1차" and by_title["A 직접 추가(마감 없음)"]["deadline_from_notice"]
            assert by_title["A 1차 완료"]["is_done"] and not by_title["A 1차 완료"]["deadline_from_notice"]
            assert by_title["A 날짜 미정 마감"]["deadline"]["label"] == "1차" and by_title["A 날짜 미정 마감"]["deadline_from_notice"]
            assert by_title["B 신청"]["deadline"] == {"id": b_dl.id, "label": "신청", "deadline_date": "2026-11-05", "deadline_time": "18:00:00"}
            assert by_title["C 마감 없는 공지"]["deadline"] is None
            assert by_title["B 신청"]["scheduled_date"] is None  # 자동 배정은 저장·추가·삭제 때만 (여기선 직접 넣은 행)
            assert by_title["B 신청"]["notice"] == {"id": b.id, "title": "공지B", "link": "https://example.com/B"}
            assert "A draft" not in by_title and "남의 할 일" not in by_title
        finally:
            main.app.dependency_overrides.clear()
            session.close()
            tx.rollback()


def test_weekly_review():
    """주간 회고: 일요일 시작, 그 주에 하기로 한 내 confirmed 할 일만, 메모 저장·덮어쓰기. 실제 데이터와 겹치지 않게 2030년으로."""
    assert week_range(date(2030, 6, 5)) == (date(2030, 6, 2), date(2030, 6, 8))  # 수요일 → 그 주 일~토
    assert week_range(date(2030, 6, 2))[0] == date(2030, 6, 2) and week_range(date(2030, 6, 8))[0] == date(2030, 6, 2)
    with engine.connect() as conn, conn.begin() as tx:
        session = Session(bind=conn, join_transaction_mode="create_savepoint")
        main.app.dependency_overrides[get_session] = lambda: session
        try:
            site = Site(name="테스트", rss_url="https://example.com/test-rss-3")
            session.add(site)
            session.commit()
            post = Post(site_id=site.id, post_key="review-1", title="회고용 공지", link="https://example.com/r")
            session.add_all([post, User(id=999_003)])
            session.commit()

            def add(title, day, done=False, status="confirmed", user=1, order=0):
                session.add(Task(user_id=user, notice_id=post.id, title=title, task_order=order, evidence="x",
                                 scheduled_date=day, is_done=done, status=status))

            add("일요일 완료", date(2030, 6, 2), done=True)
            add("토요일 미완료", date(2030, 6, 8), order=1)
            add("수요일 미완료", date(2030, 6, 5), order=2)
            add("지난주 토요일", date(2030, 6, 1))          # 제외: 다른 주
            add("다음주 일요일", date(2030, 6, 9))          # 제외: 다른 주
            add("저장 안 한 일", date(2030, 6, 5), status="draft")  # 제외
            add("남의 일", date(2030, 6, 5), user=999_003)  # 제외
            session.commit()
            client = TestClient(main.app)

            def get(week=None):
                return client.get("/reviews/weekly", params={"week": week} if week else {}).json()

            def put(week, memo):
                return client.put("/reviews/weekly", params={"week": week}, json={"memo": memo})

            r = get("2030-06-05")
            assert (r["week_start"], r["week_end"]) == ("2030-06-02", "2030-06-08")
            assert (r["planned"], r["done"]) == (3, 1) and abs(r["rate"] - 1 / 3) < 1e-9
            assert [t["title"] for t in r["unfinished"]] == ["수요일 미완료", "토요일 미완료"]  # 날짜순
            assert r["unfinished"][0]["notice"] == {"id": post.id, "title": "회고용 공지", "link": "https://example.com/r"}
            assert r["memo"] is None and r["updated_at"] is None
            empty = get("2030-07-10")
            assert empty["planned"] == 0 and empty["rate"] is None and empty["unfinished"] == []
            assert get()["week_start"] == week_range(today_kst())[0].isoformat()  # 생략하면 이번 주

            # 수요일 날짜로 저장해도 그 주 일요일에 저장, 다시 저장하면 덮어씀, 비우면 null
            saved = put("2030-06-05", " 서류를 못 뗐다 ").json()
            assert saved["memo"] == "서류를 못 뗐다" and saved["planned"] == 3 and saved["updated_at"]
            assert get("2030-06-08")["memo"] == "서류를 못 뗐다"
            assert put("2030-06-02", "다시 씀").json()["memo"] == "다시 씀"
            rows = session.exec(select(WeeklyReview).where(WeeklyReview.user_id == 1, WeeklyReview.week_start == date(2030, 6, 2))).all()
            assert len(rows) == 1
            assert put("2030-06-02", "  ").json()["memo"] is None
            assert put("2030-06-02", "가" * 2001).status_code == 400
        finally:
            main.app.dependency_overrides.clear()
            session.close()
            tx.rollback()


def test_cors():
    client = TestClient(main.app)

    def preflight(origin):
        return client.options("/tasks/1", headers={
            "Origin": origin,
            "Access-Control-Request-Method": "PATCH",
            "Access-Control-Request-Headers": "content-type",
        })

    for origin in ("http://localhost:53124", "http://127.0.0.1:8765", "http://localhost"):
        res = preflight(origin)
        assert res.status_code == 200, origin
        assert res.headers["access-control-allow-origin"] == origin
        assert "PATCH" in res.headers["access-control-allow-methods"]
    for origin in ("https://evil.example.com", "http://localhost.evil.example.com", "http://127.0.0.1.evil.example.com:8000"):
        res = preflight(origin)
        assert res.status_code == 400, origin
        assert "access-control-allow-origin" not in res.headers


if __name__ == "__main__":
    test_validate_items()
    test_plan_dates()
    test_api()
    test_my_tasks()
    test_weekly_review()
    test_cors()
    print("OK")
