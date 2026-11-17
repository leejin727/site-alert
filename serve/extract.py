"""
실제 공지 추출 테스트: 공지 URL이나 저장된 글 번호를 넣으면 Gemini 추출 결과를 DB에 저장(갱신)하고,
JSON으로 출력하고 파일로도 남깁니다. DB에 없는 명지대 공지 주소면 그 게시판을 사이트로 등록하고 공지를 저장합니다.

사용법:  python3 -m serve.extract                       (아래 TEST_NOTICES 5개)
         python3 -m serve.extract 236065                (DB에 저장된 글 번호)
         python3 -m serve.extract https://www.mju.ac.kr/bbs/mjukr/143/236065/artclView.do  (여러 개 넣어도 됨)
결과:    extract_results/<글번호>_<프롬프트버전>_<실행시각>.json
"""
import json
import os
import re
import sys
import time
from datetime import datetime
from pathlib import Path

from google import genai
from sqlmodel import Session, or_, select

from serve.analyze import MODEL, PROMPT_VERSION, WAIT_SECONDS, analyze_post, save_analysis
from serve.db import engine
from serve.models import Post, Site
from serve.rss import ensure_post_for_url

OUT_DIR = Path(__file__).with_name("extract_results")

# 성격이 다른 실제 공지 5개 (학사·장학·공모전)
TEST_NOTICES = [
    "https://www.mju.ac.kr/bbs/mjukr/143/236065/artclView.do",  # 2026-2학기 학점포기 신청 안내
    "https://www.mju.ac.kr/bbs/mjukr/145/235220/artclView.do",  # 2026년도 2학기 고졸 후학습자 장학금 신청 안내
    "https://www.mju.ac.kr/bbs/mjukr/145/235219/artclView.do",  # 2026년 2학기 중소기업 취업연계 장학금 신청 안내
    "https://www.mju.ac.kr/bbs/mjukr/145/235221/artclView.do",  # [미래에셋박현주재단] 제36기 미래에셋 해외교환 장학생 모집 안내
    "https://www.mju.ac.kr/bbs/mjukr/141/236152/artclView.do",  # [교수학습센터] 2026학년도 2학기 『WHAT-SSUP 공모전』 모집 안내
]


def find_post(session: Session, arg: str) -> tuple[Post, str]:
    """DB에서 글 번호·주소로 찾고, 없으면 명지대 주소로 게시판·공지를 등록."""
    row = session.exec(
        select(Post, Site.name).join(Site, Post.site_id == Site.id).where(or_(Post.post_key == arg, Post.link == arg))
    ).first()
    if row:
        return row
    if not arg.startswith("http"):
        raise ValueError(f"DB에서 글 번호 {arg}를 찾지 못했습니다. 상세 페이지 주소를 넣어 보세요")
    post = ensure_post_for_url(session, arg)
    return post, session.get(Site, post.site_id).name


def run(client, session: Session, arg: str) -> dict:
    record = {"입력": arg, "프롬프트버전": PROMPT_VERSION, "실행시각": datetime.now().isoformat(timespec="seconds")}
    try:
        post, board = find_post(session, arg)
        record.update({
            "공지id": post.id, "글번호": post.post_key, "제목": post.title, "링크": post.link,
            "게시일": post.published, "게시판": board,
        })
        a, used_model, source, body_len, n_images = analyze_post(client, board, post)
        deadlines, unclear = save_analysis(session, post, a, used_model, source, n_images)
        record.update({
            "사용모델": used_model, "본문출처": source, "본문길이": body_len, "이미지수": n_images,
            "결과": a.model_dump(), "마감(저장값)": deadlines, "확인불가": unclear,
        })
    except Exception as e:
        session.rollback()
        record["오류"] = str(e)[:500]
    return record


def main() -> None:
    if not os.getenv("GEMINI_API_KEY"):
        sys.exit('GEMINI_API_KEY가 없습니다. 먼저 export GEMINI_API_KEY="발급받은키" 를 실행하세요.')
    args = sys.argv[1:] or TEST_NOTICES
    client = genai.Client()
    OUT_DIR.mkdir(exist_ok=True)
    print(f"모델 {MODEL} / 프롬프트 {PROMPT_VERSION} / 공지 {len(args)}개", file=sys.stderr)

    failed = 0
    with Session(engine) as session:
        for i, arg in enumerate(args):
            if i:
                time.sleep(WAIT_SECONDS)
            record = run(client, session, arg)
            failed += "오류" in record
            text = json.dumps(record, ensure_ascii=False, indent=2, default=str)  # 마감의 date·time 값은 문자열로
            print(text)
            key = re.sub(r"\W+", "_", record.get("글번호", arg))[-60:]
            path = OUT_DIR / f"{key}_{PROMPT_VERSION}_{datetime.now():%Y%m%d-%H%M%S}.json"
            path.write_text(text, encoding="utf-8")
            print(f"저장: {path.name}" + (f" (실패: {record['오류'][:80]})" if "오류" in record else ""), file=sys.stderr)

    print(f"\n완료: 성공 {len(args) - failed}개, 실패 {failed}개", file=sys.stderr)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
