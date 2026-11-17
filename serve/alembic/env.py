from logging.config import fileConfig

from alembic import context
from sqlmodel import SQLModel

from serve import models  # noqa: F401  테이블 정의를 metadata에 등록
from serve.db import DATABASE_URL, engine

config = context.config
if config.config_file_name is not None:
    fileConfig(config.config_file_name)

# 접속 정보는 alembic.ini가 아니라 db.py(환경변수 DATABASE_URL)를 그대로 사용
target_metadata = SQLModel.metadata


def run_migrations_offline() -> None:
    context.configure(url=DATABASE_URL, target_metadata=target_metadata, literal_binds=True)
    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    with engine.connect() as connection:
        context.configure(connection=connection, target_metadata=target_metadata)
        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
