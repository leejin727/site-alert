import os

from sqlmodel import Session, create_engine



def normalize_url(url: str) -> str:
    """호스팅(Railway 등)이 주는 postgres:// · postgresql:// 주소를 이 프로젝트의 드라이버(psycopg 3)용으로 바꿈."""
    for prefix in ("postgres://", "postgresql://"):
        if url.startswith(prefix):
            return "postgresql+psycopg://" + url[len(prefix):]
    return url


# 환경변수 DATABASE_URL이 있으면 그것을, 없거나 비어 있으면 로컬 개발용 기본값을 사용
# 형식: postgresql+psycopg://사용자:비밀번호@호스트:포트/DB이름
DATABASE_URL = normalize_url(
    os.getenv("DATABASE_URL") or "postgresql+psycopg://sitealert:sitealert@localhost:5432/sitealert"
)

engine = create_engine(DATABASE_URL)
# 테이블 구조는 alembic/versions/의 마이그레이션으로 관리 (python3 -m alembic -c serve/alembic.ini upgrade head)


def get_session():
    with Session(engine) as session:
        yield session