import os

from sqlmodel import Session, create_engine

# 환경변수 DATABASE_URL이 있으면 그것을, 없으면 로컬 개발용 기본값을 사용
# 형식: postgresql+psycopg://사용자:비밀번호@호스트:포트/DB이름
DATABASE_URL = os.getenv(
    "DATABASE_URL",
    "postgresql+psycopg://sitealert:sitealert@localhost:5432/sitealert",
)

engine = create_engine(DATABASE_URL)
# 테이블 구조는 alembic/versions/의 마이그레이션으로 관리 (python3 -m alembic -c serve/alembic.ini upgrade head)


def get_session():
    with Session(engine) as session:
        yield session