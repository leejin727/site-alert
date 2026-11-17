"""기준점: create_all로 만들어져 있던 sites, posts, post_analyses

기존 DB에는 실행하지 않고 `alembic stamp 0001`로 적용 표시만 한다.

Revision ID: 0001
Revises:
Create Date: 2026-10-23
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0001"
down_revision: Union[str, Sequence[str], None] = None
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "sites",
        sa.Column("id", sa.Integer(), nullable=False),
        sa.Column("name", sa.String(), nullable=False),
        sa.Column("rss_url", sa.String(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("last_checked_at", sa.DateTime(timezone=True), nullable=True),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("rss_url"),
    )
    op.create_table(
        "posts",
        sa.Column("id", sa.Integer(), nullable=False),
        sa.Column("site_id", sa.Integer(), nullable=False),
        sa.Column("post_key", sa.String(), nullable=False),
        sa.Column("title", sa.String(), nullable=False),
        sa.Column("link", sa.String(), nullable=False),
        sa.Column("summary", sa.String(), nullable=False),
        sa.Column("published", sa.String(), nullable=False),
        sa.Column("detected_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("notified", sa.Boolean(), nullable=False),
        sa.ForeignKeyConstraint(["site_id"], ["sites.id"]),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("site_id", "post_key"),
    )
    op.create_index("ix_posts_site_id", "posts", ["site_id"])
    op.create_table(
        "post_analyses",
        sa.Column("id", sa.Integer(), nullable=False),
        sa.Column("post_id", sa.Integer(), nullable=False),
        sa.Column("model", sa.String(), nullable=False),
        sa.Column("body_source", sa.String(), nullable=False),
        sa.Column("image_count", sa.Integer(), nullable=False),
        sa.Column("result", postgresql.JSONB(), nullable=False),
        sa.Column("unclear", postgresql.JSONB(), nullable=False),
        sa.Column("analyzed_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["post_id"], ["posts.id"]),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("post_id"),
    )


def downgrade() -> None:
    op.drop_table("post_analyses")
    op.drop_index("ix_posts_site_id", table_name="posts")
    op.drop_table("posts")
    op.drop_table("sites")
