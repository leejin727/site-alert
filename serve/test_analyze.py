"""연도 보정·확인불가·분석 저장·자동 분석 흐름 확인용. 사용법: python3 -m serve.test_analyze

DB 테스트는 트랜잭션 안에서 실행하고 끝나면 롤백하므로 실제 데이터는 남지 않습니다.
"""
from datetime import date, time
from types import SimpleNamespace

from sqlmodel import Session, select

from serve import analyze, scheduler
from serve.analyze import Deadline, NoticeAnalysis, parse_published, resolve_analysis, resolve_date, save_analysis
from serve.db import engine
from serve.models import NoticeDeadline, Post, PostAnalysis, Site


def make(**kw) -> NoticeAnalysis:
    base = dict(
        summary="s", category="학사", target="전체 학생", target_evidence=None,
        undergrad="예", undergrad_evidence=None, deadlines=[],
        apply_method="선착순", apply_method_evidence=None,
    )
    return NoticeAnalysis(**{**base, **kw})


def dl(month=None, day=None, year=None, time=None, confidence="높음", evidence="원문") -> Deadline:
    return Deadline(label="접수", year=year, month=month, day=day, time=time, confidence=confidence, evidence=evidence)


def test_parse_published():
    assert parse_published("2026-10-02 11:21:37.0") == date(2026, 10, 2)  # RSS
    assert parse_published("2026.10.06") == date(2026, 10, 6)  # 상세 페이지 작성일
    assert parse_published("") is None
    assert parse_published("Thu, 02 Oct 2026 11:21:37 GMT") is None


def test_resolve_date():
    dec, sep = date(2026, 12, 20), date(2026, 9, 23)
    assert resolve_date(dl(1, 5), dec) == (date(2027, 1, 5), True, False)  # 12월 공지의 '1.5'는 다음 해
    assert resolve_date(dl(9, 20), sep) == (date(2026, 9, 20), True, False)  # 기간 연장 공지의 지난 마감은 같은 해
    assert resolve_date(dl(12, 1, year=2025), date(2026, 10, 6)) == (date(2025, 12, 1), False, True)  # 적힌 연도는 그대로, 확인 필요
    assert resolve_date(dl(11, 13, year=2026), date(2026, 10, 7)) == (date(2026, 11, 13), False, False)
    assert resolve_date(dl(10, 16), None) == (None, False, True)  # 게시일 없으면 연도를 정할 수 없음
    assert resolve_date(dl(), sep) == (None, False, True)  # '추후 공지'
    assert resolve_date(dl(2, 30, year=2026), sep) == (None, False, True)  # 없는 날짜


def test_resolve_analysis():
    rows, unclear = resolve_analysis(make(), "2026.10.06")
    assert rows == [] and unclear == []
    a = make(undergrad="불명확", apply_method="불명확", deadlines=[
        dl(10, 16, time="18:00"), dl(), dl(11, 1, confidence="낮음"), dl(11, 2, time="25:00"),
    ])
    rows, unclear = resolve_analysis(a, "2026.10.06")
    assert unclear == ["undergrad", "apply_method", "deadlines[1].date", "deadlines[2]", "deadlines[3].time"]
    assert (rows[0]["deadline_date"], rows[0]["deadline_time"], rows[0]["year_corrected"]) == (date(2026, 10, 16), time(18, 0), True)
    assert rows[1]["deadline_date"] is None and rows[3]["deadline_time"] is None


def test_save_analysis():
    with engine.connect() as conn, conn.begin() as tx:
        session = Session(bind=conn, join_transaction_mode="create_savepoint")  # save_analysis의 commit이 실제로 확정되지 않게
        site = Site(name="테스트", rss_url="https://example.com/test-rss")
        session.add(site)
        session.commit()
        post = Post(site_id=site.id, post_key="test-1", title="t", link="https://example.com/1", published="2026.10.06")
        session.add(post)
        session.commit()

        # 날짜·근거가 비고 불명확뿐인 결과도 저장되어야 함
        empty = make(target="불명확", undergrad="불명확", apply_method="불명확", deadlines=[dl(evidence=""), dl(10, 16)])
        _, unclear = save_analysis(session, post, empty, "m1", "상세페이지", 0)
        assert "deadlines[0].date" in unclear
        first = session.exec(select(NoticeDeadline).where(NoticeDeadline.notice_id == post.id).order_by(NoticeDeadline.deadline_order)).all()
        assert [(d.deadline_date, d.evidence) for d in first] == [(None, None), (date(2026, 10, 16), "원문")]
        first_ids = [d.id for d in first]

        # 다시 분석: 행이 늘지 않고 갱신, 같은 순번의 마감 id 유지, 줄어든 마감은 삭제
        save_analysis(session, post, make(deadlines=[dl(10, 20)]), "m2", "상세페이지", 0)
        session.expire_all()
        analyses = session.exec(select(PostAnalysis).where(PostAnalysis.post_id == post.id)).all()
        assert len(analyses) == 1 and analyses[0].model == "m2" and analyses[0].unclear == []
        second = session.exec(select(NoticeDeadline).where(NoticeDeadline.notice_id == post.id)).all()
        assert [(d.id, d.deadline_date) for d in second] == [(first_ids[0], date(2026, 10, 20))]

        session.close()
        tx.rollback()


def test_timeout_fallback():
    calls = []

    def fake_call(client, model, contents, schema, timeout=None):
        calls.append((model, timeout))
        if model == "느린모델":
            raise TimeoutError("The read operation timed out")
        if model == "한도소진모델":
            raise RuntimeError("429 RESOURCE_EXHAUSTED quotaId: GenerateRequestsPerDayPerProjectPerModel-FreeTier")
        return "결과"

    original = analyze.call_model
    analyze.call_model = fake_call
    try:
        assert analyze.run_with_retry(None, "본문", models=("느린모델", "빠른모델"), skip_after=60) == ("결과", "빠른모델")
        assert calls == [("느린모델", 60), ("빠른모델", None)]  # 시간 초과한 모델은 다시 시도하지 않고, 마지막 모델은 제한 없이
        calls.clear()
        assert analyze.run_with_retry(None, "본문", models=("한도소진모델", "빠른모델")) == ("결과", "빠른모델")
        assert len(calls) == 2  # 하루 한도가 끝난 모델은 기다렸다 다시 시도하지 않음
    finally:
        analyze.call_model = original


def test_check_triggers_analysis():
    triggered = []
    originals = scheduler.check_site, scheduler.analyze_now
    scheduler.analyze_now = lambda: triggered.append(True)
    try:
        scheduler.check_site = lambda session, site: []
        scheduler.check_all_sites()
        assert not triggered
        scheduler.check_site = lambda session, site: [SimpleNamespace(title="새 글", link="x")]
        scheduler.check_all_sites()
        assert triggered
    finally:
        scheduler.check_site, scheduler.analyze_now = originals


if __name__ == "__main__":
    test_parse_published()
    test_resolve_date()
    test_resolve_analysis()
    test_save_analysis()
    test_timeout_fallback()
    test_check_triggers_analysis()
    print("OK")
