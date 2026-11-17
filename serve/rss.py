"""1단계 check_rss.py의 수집 로직을 서버용으로 옮긴 모듈."""
import re
from urllib.parse import urljoin

import feedparser
import requests
from sqlmodel import Session, select

from serve.detail import fetch_detail
from serve.models import Post, Site, now_utc

# 명지대 게시판 링크의 글 번호 (예: /bbs/mjukr/141/233523/artclView.do)
ID_PATTERN = re.compile(r"/(\d+)/artclView\.do")
# 명지대 상세 주소 → (게시판 주소, 게시판 번호, 글 번호)
BOARD_PATTERN = re.compile(r"^(https?://[^/]+/bbs/\w+/(\d+))/(\d+)/artclView\.do")
# RSS·게시판 페이지에 이름이 없어 홈페이지 메뉴에서 확인한 이름을 사용
BOARD_NAMES = {
    "141": "일반공지", "142": "행사공지", "143": "학사공지",
    "145": "장학/학자금공지", "146": "진로/취업/창업공지", "853": "학생활동공지",
}


class FeedError(Exception):
    """RSS를 가져오거나 해석하지 못했을 때."""


def fetch_posts(rss_url: str) -> list[dict]:
    try:
        resp = requests.get(rss_url, timeout=10)
        resp.raise_for_status()
    except requests.RequestException as e:
        raise FeedError(f"요청 실패: {e}") from e

    feed = feedparser.parse(resp.content)  # 다운로드는 requests, 해석만 feedparser
    if not feed.entries:
        raise FeedError(f"응답은 받았지만 글이 0개입니다 (오류: {feed.get('bozo_exception')})")

    posts = []
    for entry in feed.entries:
        raw_link = entry.get("link", "")
        if not raw_link:
            continue
        link = urljoin(rss_url, raw_link)  # 상대경로 링크를 RSS 주소 기준으로 보정
        match = ID_PATTERN.search(link)
        posts.append({
            "key": match.group(1) if match else link,  # 다른 사이트는 링크 자체를 고유값으로
            "title": entry.get("title", "").strip(),
            "link": link,
            "summary": entry.get("summary", "").strip(),
            "published": entry.get("published", ""),
        })
    if not posts:
        raise FeedError("글은 받았지만 링크가 있는 항목이 없습니다")
    return posts


def save_new_posts(session: Session, site: Site, posts: list[dict], notified: bool) -> list[Post]:
    """DB에 없는 글만 저장하고, 저장한 글 목록을 반환."""
    existing = set(session.exec(select(Post.post_key).where(Post.site_id == site.id)).all())
    new_posts = []
    for p in posts:
        if p["key"] in existing:
            continue
        existing.add(p["key"])  # 같은 피드 안의 중복 방지
        post = Post(
            site_id=site.id,
            post_key=p["key"],
            title=p["title"],
            link=p["link"],
            summary=p["summary"],
            published=p["published"],
            notified=notified,
        )
        session.add(post)
        new_posts.append(post)

    site.last_checked_at = now_utc()
    session.add(site)
    session.commit()
    for post in new_posts:
        session.refresh(post)
    return new_posts


def check_site(session: Session, site: Site) -> list[Post]:
    """사이트를 확인해 새 글을 저장하고 반환 (FeedError 발생 가능)."""
    posts = fetch_posts(site.rss_url)
    return save_new_posts(session, site, posts, notified=False)


def create_site(session: Session, name: str, rss_url: str) -> tuple[Site, list[Post]]:
    """RSS를 실제로 받아 검증한 뒤 사이트를 등록 (FeedError 발생 가능).

    기준점: 등록 시점의 기존 글은 '알림 완료'로 저장 (알림 폭탄 방지)
    """
    posts = fetch_posts(rss_url)
    site = Site(name=name, rss_url=rss_url)
    session.add(site)
    session.commit()
    session.refresh(site)
    baseline = save_new_posts(session, site, posts, notified=True)
    session.refresh(site)  # 커밋 후 만료된 값을 다시 읽어와야 응답에 내용이 담김
    return site, baseline


def ensure_post_for_url(session: Session, url: str) -> Post:
    """명지대 상세 주소의 글을 DB에서 찾고, 없으면 게시판을 사이트로 등록하고 글을 저장.

    ValueError(명지대 주소 아님), FeedError, requests 오류 발생 가능
    """
    match = BOARD_PATTERN.match(url)
    if not match:
        raise ValueError("명지대 게시판 상세 주소가 아니라 게시판을 등록할 수 없습니다")
    board_url, board_id, key = match.groups()
    # row 값은 게시판마다 다를 수 있으므로(일반공지는 100) 주소 앞부분으로 찾음
    site = session.exec(select(Site).where(Site.rss_url.startswith(f"{board_url}/rssList.do"))).first()
    if not site:
        site, _ = create_site(session, BOARD_NAMES.get(board_id, f"게시판 {board_id}"), f"{board_url}/rssList.do?row=50")
    post = session.exec(select(Post).where(Post.site_id == site.id, Post.post_key == key)).first()
    if post:
        return post
    # RSS 최근 50개에 없는 오래된 글: 상세 페이지에서 직접 저장 (새 글 감지가 아니므로 알림 대상 아님)
    detail = fetch_detail(url)
    post = Post(site_id=site.id, post_key=key, title=detail.title, link=url, published=detail.published, notified=True)
    session.add(post)
    session.commit()
    session.refresh(post)
    return post
