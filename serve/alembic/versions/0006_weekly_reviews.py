"""weekly_reviews

Revision ID: 0006
Revises: 0005
Create Date: 2026-11-03 12:31:09.216184

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
import sqlmodel  # noqa: F401  autogenerate가 sqlmodel.AutoString을 쓸 때 필요


# revision identifiers, used by Alembic.
revision: str = '0006'
down_revision: Union[str, Sequence[str], None] = '0005'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    op.create_table('weekly_reviews',
    sa.Column('id', sa.Integer(), nullable=False),
    sa.Column('user_id', sa.Integer(), nullable=False),
    sa.Column('week_start', sa.Date(), nullable=False),
    sa.Column('memo', sqlmodel.sql.sqltypes.AutoString(), nullable=True),
    sa.Column('created_at', sqlmodel.sql.sqltypes.UTCDateTime(), nullable=False),
    sa.Column('updated_at', sqlmodel.sql.sqltypes.UTCDateTime(), nullable=False),
    sa.ForeignKeyConstraint(['user_id'], ['users.id'], ),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('user_id', 'week_start')  # 사용자별 조회도 이 인덱스로 충분
    )


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_table('weekly_reviews')
