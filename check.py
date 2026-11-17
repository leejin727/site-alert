"""
1단계: RSS 새 글 감지 스크립트
- 실행할 때마다 RSS를 읽고, 이전에 본 적 없는 글만 출력합니다.
- 게시판별 첫 실행에서는 기존 글을 '본 것'으로 저장만 하고 출력하지 않습니다.
- 지금은 1회 실행 방식입니다. 주기 실행(4시간)은 3단계에서 스케줄러로 붙입니다.
"""
import json
import re
from pathlib import Path
from urllib.parse import urljoin

import feedparser
import requests

BASE_URL = "https://www.mju.ac.kr"
STATE_FILE = Path(__file__).with_name("seen.json")
MAX_SEEN = 500  # 게시판별로 기억할 최대 ID 수 (파일이 끝없이 커지는 것 방지)

# 감시할 게시판: 이름 -> RSS 주소 (각 게시판의 'RSS 2.0' 버튼에서 복사)
FEEDS = {
    "일반공지": "https://www.mju.ac.kr/bbs/mjukr/141/rssList.do?row=50",
    # "학사공지": "여기에 학사공지 RSS 주소",
}

ID_PATTERN = re.compile(r"/(\d+)/artclView\.do")


def load_state() -> dict:
    if STATE_FILE.exists():
        return json.loads(STATE_FILE.read_text(encoding="utf-8"))
    return {}


def save_state(state: dict) -> None:
    # 임시 파일에 먼저 쓰고 교체: 저장 도중 중단돼도 기존 파일이 깨지지 않음
    tmp = STATE_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(STATE_FILE)


def fetch_posts(rss_url: str):
    """성공하면 글 목록(list), 실패하면 None을 반환합니다."""
    try:
        resp = requests.get(rss_url, timeout=10)
        resp.raise_for_status()
    except requests.RequestException as e:
        print(f"  [진단] 요청 실패: {e}")
        return None
    feed = feedparser.parse(resp.content)  # 다운로드는 requests, 해석만 feedparser
    if not feed.entries:
        print(f"  [진단] 응답은 받았지만 글 0개 / 오류: {feed.get('bozo_exception')}")
        print(f"  [진단] 응답 앞부분: {resp.text.strip()[:200]!r}")
        return None
    posts = []
    for entry in feed.entries:
        link = urljoin(BASE_URL, entry.get("link", ""))  # 상대경로 링크 보정
        match = ID_PATTERN.search(link)
        if not match:
            continue
        posts.append({
            "id": match.group(1),
            "title": entry.get("title", "").strip(),
            "link": link,
            "summary": entry.get("summary", "").strip(),  # 7단계 AI 요약에 활용 예정
            "published": entry.get("published", ""),
        })
    if not posts:
        print(f"  [진단] 글 {len(feed.entries)}개를 받았지만 ID를 찾지 못함. 첫 링크: {feed.entries[0].get('link')}")
        return None
    return posts


def check_feed(name: str, rss_url: str, state: dict):
    """새 글 목록(list)을 반환합니다. 가져오기에 실패하면 None."""
    posts = fetch_posts(rss_url)
    if posts is None:
        # 네트워크 오류 등: 상태를 건드리지 않고 다음 실행에 다시 시도
        print(f"[{name}] 글을 가져오지 못했습니다. 이번 확인은 건너뜁니다.")
        return None

    is_first_run = rss_url not in state
    seen = set(state.get(rss_url, []))
    new_posts = [p for p in posts if p["id"] not in seen]

    all_ids = seen | {p["id"] for p in posts}
    state[rss_url] = sorted(all_ids, key=int, reverse=True)[:MAX_SEEN]

    if is_first_run:
        print(f"[{name}] 첫 실행: 기존 글 {len(posts)}개를 기준점으로 저장했습니다.")
        return []
    return new_posts


def main() -> None:
    state = load_state()
    for name, rss_url in FEEDS.items():
        new_posts = check_feed(name, rss_url, state)
        if new_posts is None:
            continue  # 실패한 경우 '새 글 없음'을 출력하지 않음
        if not new_posts:
            print(f"[{name}] 새 글 없음")
        for p in new_posts:
            # 나중에 이 부분이 '푸시 알림 발송'으로 바뀝니다
            print(f"[새 글][{name}] {p['title']}\n  {p['link']}")
    save_state(state)


if __name__ == "__main__":
    main()