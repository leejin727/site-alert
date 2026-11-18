"""직접 만든 일정(시험·공모전) 확인용. 사용법: python3 -m serve.test_planner

DB는 트랜잭션 안에서 실행한 뒤 롤백하므로 실제 데이터는 남지 않습니다.
"""
from datetime import date, timedelta

from fastapi.testclient import TestClient
from sqlmodel import Session, func, select

from serve import main
from serve.db import engine, get_session
from serve.models import NoticeDeadline, Post, Schedule, Site, Task, User
from serve.reviews import week_range
from serve.schedule import CHECKLISTS, PHASES, back_from, plan_dates, today_kst


def test_rules():
    today = date(2026, 11, 10)
    assert back_from(date(2026, 11, 20), 3, today) == date(2026, 11, 17)
    assert back_from(date(2026, 11, 20), 0, today) == date(2026, 11, 20)
    assert back_from(date(2026, 11, 20), 14, today) == today      # 오늘보다 앞이면 오늘
    assert back_from(date(2026, 11, 1), 2, today) == today        # 이미 지난 날짜
    # 공지 역산 배치는 같은 함수를 쓰고 결과도 그대로: 마지막 할 일이 마감 3일 전, 그 앞은 하루 간격
    assert plan_dates("기간 내 제출", [(1, date(2026, 11, 20)), (2, date(2026, 11, 20))], today) == {
        2: date(2026, 11, 17), 1: date(2026, 11, 16),
    }
    assert [len(CHECKLISTS[k]) for k in ("exam", "contest")] == [9, 10]
    assert PHASES == {"exam": ["준비", "공부", "직전"], "contest": ["준비", "제작", "제출"]}
    assert CHECKLISTS["contest"][-1] == ("제출", "제출하고 접수 확인", 0)


def test_schedule_api():
    with engine.connect() as conn, conn.begin() as tx:
        session = Session(bind=conn, join_transaction_mode="create_savepoint")
        main.app.dependency_overrides[get_session] = lambda: session
        try:
            client = TestClient(main.app)
            today = today_kst()
            far, near = today + timedelta(days=30), today + timedelta(days=5)

            # 등록: 기본 체크리스트가 '날짜 − 며칠 전'으로 들어감
            r = client.post("/schedules", json={"kind": "exam", "title": " 자료구조 중간고사 ", "target_date": str(far)})
            assert r.status_code == 201
            exam = r.json()
            assert (exam["kind"], exam["title"], exam["target_date"]) == ("exam", "자료구조 중간고사", str(far))
            assert exam["phases"] == ["준비", "공부", "직전"]
            assert [(t["phase"], t["title"]) for t in exam["tasks"]] == [(p, t) for p, t, _ in CHECKLISTS["exam"]]
            assert [t["scheduled_date"] for t in exam["tasks"]] == [str(far - timedelta(days=d)) for _, _, d in CHECKLISTS["exam"]]
            assert all(t["source"] == "user" and not t["is_done"] for t in exam["tasks"])

            # 가까운 날짜: 오늘보다 앞이 되는 항목은 오늘로
            contest = client.post("/schedules", json={"kind": "contest", "title": "캡스톤 공모전", "target_date": str(near)}).json()
            dates = {t["title"]: t["scheduled_date"] for t in contest["tasks"]}
            assert dates["공고문 정독: 참가 자격·제출물·심사 기준"] == dates["프로토타입·구현"] == str(today)
            assert dates["발표 자료·시연 영상"] == str(near - timedelta(days=4))
            assert dates["제출하고 접수 확인"] == str(near)

            # 체크리스트 없이 시작, 잘못된 값
            empty = client.post("/schedules", json={"kind": "exam", "title": "빈 일정", "target_date": str(far), "use_checklist": False}).json()
            assert empty["tasks"] == []
            assert client.post("/schedules", json={"kind": "quiz", "title": "x", "target_date": str(far)}).status_code == 400
            assert client.post("/schedules", json={"kind": "exam", "title": "  ", "target_date": str(far)}).status_code == 400

            # 항목 추가: 그 단계의 맨 뒤. 단계가 없으면 맨 뒤. 다른 항목의 예정일은 그대로
            url = f"/schedules/{exam['id']}"
            added = client.post(f"{url}/tasks", json={"title": "스터디 모임", "phase": "공부", "scheduled_date": str(today)})
            assert added.status_code == 201 and added.json()["phase"] == "공부" and added.json()["scheduled_date"] == str(today)
            loose = client.post(f"{url}/tasks", json={"title": "간식 사기"}).json()
            assert loose["phase"] is None and loose["scheduled_date"] is None
            assert client.post(f"{url}/tasks", json={"title": "x", "phase": "제작"}).status_code == 400  # 시험에 없는 단계
            assert client.post(f"{url}/tasks", json={"title": " "}).status_code == 400
            detail = client.get(url).json()
            titles = [t["title"] for t in detail["tasks"]]
            assert titles.index("스터디 모임") == titles.index("틀린 문제 오답 정리") + 1 and titles[-1] == "간식 사기"
            before = {t["id"]: t["scheduled_date"] for t in exam["tasks"]}
            assert {t["id"]: t["scheduled_date"] for t in detail["tasks"] if t["id"] in before} == before

            # 기존 PATCH /tasks 로 완료·예정일 변경
            by_title = {t["title"]: t for t in detail["tasks"]}
            done_id, moved_id = by_title["시험 범위와 출제 유형 확인"]["id"], by_title["1회독: 개념 정리"]["id"]
            assert client.patch(f"/tasks/{done_id}", json={"is_done": True}).json()["is_done"]
            moved_to = str(today + timedelta(days=1))
            assert client.patch(f"/tasks/{moved_id}", json={"scheduled_date": moved_to}).json()["scheduled_date"] == moved_to

            # 날짜를 바꾸면 완료하지 않은 기본 항목만 다시 계산 (완료한 것, 직접 날짜를 고친 것, 직접 추가한 것은 그대로)
            later = far + timedelta(days=7)
            changed = client.patch(url, json={"title": "자료구조 기말고사", "target_date": str(later)}).json()
            assert (changed["title"], changed["target_date"]) == ("자료구조 기말고사", str(later))
            after = {t["title"]: t["scheduled_date"] for t in changed["tasks"]}
            assert after["2회독: 문제 풀이"] == str(later - timedelta(days=5))
            assert after["시험 시간·장소·준비물 확인"] == str(later - timedelta(days=1))
            assert after["시험 범위와 출제 유형 확인"] == str(far - timedelta(days=14))  # 완료
            assert after["1회독: 개념 정리"] == moved_to                                   # 직접 고친 날짜
            assert after["스터디 모임"] == str(today) and after["간식 사기"] is None      # 직접 추가
            assert client.patch(url, json={"target_date": None}).status_code == 400
            assert client.patch(url, json={"title": ""}).status_code == 400

            # 내 할 일: 근거 없는 일정 할 일도 걸러지지 않고, 일정 날짜가 마감으로 나옴
            mine = [t for t in client.get("/tasks").json() if t["schedule"] and t["schedule"]["id"] == exam["id"]]
            assert len(mine) == 11 and all(t["notice"] is None and t["source"] == "user" for t in mine)
            assert mine[0]["schedule"] == {"id": exam["id"], "kind": "exam", "title": "자료구조 기말고사", "target_date": str(later)}
            assert mine[0]["deadline"] == {"id": None, "label": "시험일", "deadline_date": str(later), "deadline_time": None}
            assert not mine[0]["deadline_from_notice"]

            # 캘린더 마감: 일정 날짜가 함께 나옴
            marks = [d for d in client.get("/deadlines").json() if d["schedule"] and d["schedule"]["id"] in (exam["id"], contest["id"])]
            assert [(d["label"], d["deadline_date"], d["notice"]) for d in marks] == [("마감일", str(near), None), ("시험일", str(later), None)]

            # 주간 회고: 그 주에 예정된 일정 할 일이 계획에 들어감
            week = week_range(later - timedelta(days=5))[0]
            review = client.get("/reviews/weekly", params={"week": str(week)}).json()
            in_week = [t for t in review["unfinished"] if t["schedule"] and t["schedule"]["id"] == exam["id"]]
            assert "2회독: 문제 풀이" in [t["title"] for t in in_week] and in_week[0]["notice"] is None

            # 일정 목록: 다가오는 것이 가까운 순, 지난 것은 아래(최근에 지난 것 먼저), 날짜 없는 것은 맨 아래. 공지에서 담은 것도 함께
            site = Site(name="테스트", rss_url="https://example.com/planner-rss")
            session.add(site)
            session.commit()
            soon, undated = (Post(site_id=site.id, post_key=f"p{i}", title=f"공지{i}", link=f"https://example.com/{i}") for i in "SU")
            session.add_all([soon, undated])
            session.commit()
            session.add_all([
                NoticeDeadline(notice_id=soon.id, deadline_order=0, label="지난 것", deadline_date=today - timedelta(days=10), confidence="높음"),
                NoticeDeadline(notice_id=soon.id, deadline_order=1, label="곧", deadline_date=today + timedelta(days=2), confidence="높음"),
                NoticeDeadline(notice_id=soon.id, deadline_order=2, label="나중", deadline_date=today + timedelta(days=40), confidence="높음"),
                Task(user_id=1, notice_id=soon.id, title="담은 일", task_order=0, evidence="x", status="confirmed", is_done=True),
                Task(user_id=1, notice_id=soon.id, title="담은 일 2", task_order=1, evidence="x", status="confirmed"),
                Task(user_id=1, notice_id=soon.id, title="미리보기만", task_order=2, evidence="x", status="draft"),
                Task(user_id=1, notice_id=undated.id, title="마감 없는 공지의 일", task_order=0, evidence="x", status="confirmed"),
            ])
            session.commit()
            past1 = client.post("/schedules", json={"kind": "exam", "title": "지난 시험", "target_date": str(today - timedelta(days=3)), "use_checklist": False}).json()
            past2 = client.post("/schedules", json={"kind": "contest", "title": "더 지난 공모전", "target_date": str(today - timedelta(days=20)), "use_checklist": False}).json()
            ours = {exam["id"], contest["id"], empty["id"], past1["id"], past2["id"]}
            entries = [e for e in client.get("/schedules").json() if e["schedule_id"] in ours or e["notice_id"] in (soon.id, undated.id)]
            assert [(e["kind"], e["title"], e["date"]) for e in entries] == [
                ("notice", "공지S", str(today + timedelta(days=2))),
                ("contest", "캡스톤 공모전", str(near)),
                ("exam", "빈 일정", str(far)),
                ("exam", "자료구조 기말고사", str(later)),
                ("exam", "지난 시험", str(today - timedelta(days=3))),
                ("contest", "더 지난 공모전", str(today - timedelta(days=20))),
                ("notice", "공지U", None),
            ]
            by_title = {e["title"]: e for e in entries}
            assert (by_title["공지S"]["total"], by_title["공지S"]["done"]) == (2, 1)  # draft는 세지 않음
            assert by_title["공지S"]["link"] == "https://example.com/S" and by_title["공지S"]["schedule_id"] is None
            assert (by_title["자료구조 기말고사"]["total"], by_title["자료구조 기말고사"]["done"]) == (11, 1)
            assert (by_title["빈 일정"]["total"], by_title["빈 일정"]["notice_id"]) == (0, None)

            # 다른 사용자의 일정은 404
            session.add(User(id=999_003))
            session.commit()
            other = Schedule(user_id=999_003, kind="exam", title="남의 시험", target_date=far)
            session.add(other)
            session.commit()
            other_url = f"/schedules/{other.id}"
            assert client.get(other_url).status_code == 404
            assert client.patch(other_url, json={"title": "x"}).status_code == 404
            assert client.post(f"{other_url}/tasks", json={"title": "x"}).status_code == 404
            assert client.delete(other_url).status_code == 404
            assert "남의 시험" not in [e["title"] for e in client.get("/schedules").json()]

            # 항목 삭제, 일정 삭제(체크리스트도 함께)
            assert client.delete(f"/tasks/{loose['id']}").status_code == 204
            assert len(client.get(url).json()["tasks"]) == 10
            assert client.delete(url).status_code == 204
            assert client.get(url).status_code == 404
            assert session.exec(select(func.count()).select_from(Task).where(Task.schedule_id == exam["id"])).one() == 0
        finally:
            main.app.dependency_overrides.clear()
            session.close()
            tx.rollback()


if __name__ == "__main__":
    test_rules()
    test_schedule_api()
    print("OK")
