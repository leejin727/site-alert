"""
이미지 공지 실험: 공지 상세 페이지에서 본문 이미지를 찾아 Gemini에 함께 보내 분석합니다.

사용법:  python3 -m serve.imagetest 236106
         (글 번호 대신 상세 페이지 주소를 넣어도 됩니다)
결과:    image_test_<글번호>/ 폴더에 내려받은 이미지와 result.json 저장
"""
import json
import os
import sys
from pathlib import Path

import requests
from google import genai
from google.genai import types
from sqlmodel import Session, select

from serve.analyze import FALLBACK_MODEL, IMAGE_NOTE, MODEL, PROMPT_VERSION, build_prompt, format_deadline, resolve_analysis, run_with_retry
from serve.db import engine
from serve.detail import CONTENT_SELECTORS, PageDetail, download_images, fetch_detail
from serve.models import Post, Site


def find_post(arg: str):
    """글 번호면 DB에서 찾고, 주소면 그대로 사용."""
    if arg.startswith("http"):
        return None, "알 수 없음", arg
    with Session(engine) as session:
        row = session.exec(
            select(Post, Site.name).join(Site, Post.site_id == Site.id).where(Post.post_key == arg)
        ).first()
    if not row:
        sys.exit(f"DB에서 글 번호 {arg}를 찾지 못했습니다. 상세 페이지 주소를 직접 넣어 보세요.")
    post, board = row
    return post, board, post.link


def collect_images(detail: PageDetail, out_dir: Path) -> list[types.Part]:
    print("\n[진단] 본문 영역")
    if detail.area:
        print(f"  사용한 영역: {detail.area} / 텍스트 {len(detail.text)}자, 이미지 {len(detail.image_urls)}개")
        print(f"  텍스트 앞부분: {detail.text[:150]!r}")
    else:
        print(f"  ※ 본문 영역을 못 찾았습니다. detail.py의 CONTENT_SELECTORS({', '.join(CONTENT_SELECTORS)})를 조정하세요")
    print(f"  첨부파일: {', '.join(detail.attachments) or '없음'}")

    print("\n[진단] 이미지 내려받기")
    images, notes = download_images(detail)
    for note in notes:
        print(f"  {note}")
    out_dir.mkdir(exist_ok=True)
    for i, (mime, data) in enumerate(images, 1):
        ext = mime.split("/")[1].replace("jpeg", "jpg")
        (out_dir / f"img{i}.{ext}").write_bytes(data)
    return [types.Part.from_bytes(data=data, mime_type=mime) for mime, data in images]


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit("사용법: python3 -m serve.imagetest 글번호(예: 236106) 또는 상세페이지주소")
    if not os.getenv("GEMINI_API_KEY"):
        sys.exit('GEMINI_API_KEY가 없습니다. 먼저 export GEMINI_API_KEY="발급받은키" 를 실행하세요.')

    post, board, page_url = find_post(sys.argv[1])
    key = post.post_key if post else "url"
    out_dir = Path(__file__).with_name(f"image_test_{key}")
    print(f"대상: {post.title if post else page_url}")

    try:
        detail = fetch_detail(page_url)
    except requests.RequestException as e:
        sys.exit(f"상세 페이지를 가져오지 못했습니다: {e}")
    parts = collect_images(detail, out_dir)
    if not parts:
        sys.exit("\n분석할 이미지를 찾지 못했습니다. 위 [진단] 출력을 그대로 보내 주세요.")

    # 주소만 넣은 경우에도 같은 규칙의 프롬프트를 쓰도록, 제목은 페이지에서 가져옴
    prompt = build_prompt(
        board=board,
        title=post.title if post else detail.title,
        published=post.published if post else "",
        body=detail.text or (post.summary if post else ""),
        attachments=detail.attachments,
    )
    prompt += IMAGE_NOTE.format(n=len(parts))

    print(f"\n[분석] 이미지 {len(parts)}장 + 텍스트를 Gemini에 전송 (모델 {MODEL}, 대체 {FALLBACK_MODEL})")
    client = genai.Client()
    result, used_model = run_with_retry(client, [prompt, *parts])

    print(f"\n[결과] 사용 모델: {used_model}")
    for k, v in result.model_dump().items():
        print(f"  {k}: {v}")
    deadlines, unclear = resolve_analysis(result, post.published if post else detail.published)
    for d in deadlines:
        print(f"  마감(저장값): {format_deadline(d)}")
    print(f"  확인불가: {', '.join(unclear) or '없음'}")

    record = {"대상": page_url, "사용모델": used_model, "이미지수": len(parts), "프롬프트버전": PROMPT_VERSION, "프롬프트": prompt, "결과": result.model_dump(), "마감(저장값)": deadlines, "확인불가": unclear}
    (out_dir / "result.json").write_text(json.dumps(record, ensure_ascii=False, indent=2, default=str), encoding="utf-8")
    print(f"\n저장: {out_dir}/ (내려받은 이미지와 result.json)")


if __name__ == "__main__":
    main()