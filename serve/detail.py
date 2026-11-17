"""공지 상세 페이지에서 본문 전체·이미지 주소·첨부파일 이름을 가져오는 모듈.

RSS의 summary는 본문 앞부분뿐이라, AI 분석에는 이 모듈로 가져온 본문 전체를 사용합니다.
"""
import re
from dataclasses import dataclass, field
from urllib.parse import urljoin

import requests
from bs4 import BeautifulSoup

# 본문 영역 후보 (앞에서부터 먼저 찾은 것을 사용. 명지대는 .artclView)
CONTENT_SELECTORS = [".artclView", ".view-con", ".view-content", ".bbs_view", "#contents", "article"]
TITLE_SELECTORS = [".artclViewTitle", ".view-title", "h2", "h1"]
ATTACHMENT_SELECTOR = ".attfile a"
INFO_SELECTOR = ".head_info li"  # 명지대: <li><strong>작성일</strong>2026.10.06</li>
# 줄바꿈을 넣을 블록 태그 (넣지 않으면 <span> 단위로 글자가 조각나거나 문단이 붙어 버림)
BLOCK_TAGS = ["p", "div", "li", "tr", "table", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote"]
MAX_BODY_CHARS = 15_000  # 아주 긴 공지로 요청이 너무 커지지 않도록 자름
MAX_IMAGES = 5
MIN_IMAGE_BYTES = 20_000  # 이보다 작은 이미지는 아이콘·버튼으로 보고 제외
SUPPORTED_MIME = {"image/png", "image/jpeg", "image/webp", "image/heic", "image/heif"}


@dataclass
class PageDetail:
    url: str
    title: str = ""
    published: str = ""  # 작성일 (못 찾으면 빈 문자열)
    text: str = ""
    area: str = ""  # 본문으로 사용한 영역 (진단용)
    image_urls: list[str] = field(default_factory=list)
    attachments: list[str] = field(default_factory=list)  # 첨부파일 이름


def html_to_text(area) -> str:
    """표·문단 구조를 살려 읽기 쉬운 텍스트로 변환."""
    # 표는 한 행을 한 줄로 ("일정 | 시간 | 장소"). 칸 안의 <p> 때문에 칸마다 줄이 나뉘는 것을 막음
    for br in area.find_all("br"):
        br.replace_with("\n")
    for row in area.find_all("tr"):
        for block in row.find_all(BLOCK_TAGS):
            block.insert_after(" ")
        cells = [re.sub(r"\s+", " ", c.get_text()).strip() for c in row.find_all(["td", "th"])]
        row.replace_with(" | ".join(cells) + "\n")
    for block in area.find_all(BLOCK_TAGS):
        block.insert_after("\n")
    lines = (re.sub(r"[ \t ]+", " ", line).strip(" |") for line in area.get_text().splitlines())
    text = "\n".join(line for line in lines if line)
    if len(text) > MAX_BODY_CHARS:
        text = text[:MAX_BODY_CHARS] + "\n(본문이 길어 이후 생략)"
    return text


def fetch_detail(url: str) -> PageDetail:
    """상세 페이지를 받아 본문 텍스트·이미지·첨부파일을 추출 (requests 오류 발생 가능)."""
    resp = requests.get(url, timeout=10)
    resp.raise_for_status()
    soup = BeautifulSoup(resp.content, "html.parser")
    detail = PageDetail(url=url)

    for sel in TITLE_SELECTORS:
        found = soup.select_one(sel)
        if found and found.get_text(strip=True):
            detail.title = found.get_text(" ", strip=True)
            break

    for li in soup.select(INFO_SELECTOR):
        text = li.get_text(" ", strip=True)
        if text.startswith("작성일"):
            detail.published = text.removeprefix("작성일").strip()
            break

    detail.attachments = [a.get_text(" ", strip=True) for a in soup.select(ATTACHMENT_SELECTOR) if a.get_text(strip=True)]

    area = None
    for sel in CONTENT_SELECTORS:
        area = soup.select_one(sel)
        if area:
            detail.area = sel
            break
    if area is None:
        return detail  # 본문 영역을 못 찾음 → 호출한 쪽에서 RSS 요약으로 대체

    for img in area.find_all("img"):
        src = img.get("src") or img.get("data-src") or ""
        if src and not src.startswith("data:"):
            detail.image_urls.append(urljoin(url, src))
    detail.text = html_to_text(area)
    return detail


def download_images(detail: PageDetail) -> tuple[list[tuple[str, bytes]], list[str]]:
    """본문 이미지를 내려받음. 반환: ([(MIME, 데이터)], 이미지별 진단 메시지)"""
    images, notes = [], []
    for i, url in enumerate(detail.image_urls, 1):
        try:
            r = requests.get(url, timeout=15, headers={"Referer": detail.url})
            r.raise_for_status()
        except requests.RequestException as e:
            notes.append(f"{i}. 실패 {url} ({e})")
            continue
        mime = r.headers.get("Content-Type", "").split(";")[0].strip()
        size = len(r.content)
        if mime not in SUPPORTED_MIME:
            notes.append(f"{i}. 제외(형식 {mime or '알 수 없음'}) {url}")
            continue
        if size < MIN_IMAGE_BYTES:
            notes.append(f"{i}. 제외(작음 {size // 1024}KB) {url}")
            continue
        images.append((mime, r.content))
        notes.append(f"{i}. 사용 ({size // 1024}KB, {mime}) {url}")
        if len(images) >= MAX_IMAGES:
            notes.append(f"최대 {MAX_IMAGES}장까지만 사용합니다")
            break
    return images, notes
