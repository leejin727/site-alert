"""tasks.status

Revision ID: 0005
Revises: 0004
Create Date: 2026-10-28 10:52:26.622464

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
import sqlmodel  # noqa: F401  autogenerate가 sqlmodel.AutoString을 쓸 때 필요


# revision identifiers, used by Alembic.
revision: str = '0005'
down_revision: Union[str, Sequence[str], None] = '0004'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    # 기존 할 일은 모두 사용자가 담은 것이므로 confirmed로 채운 뒤, 기본값은 없앰 (새 행은 코드가 draft로 넣음)
    op.add_column('tasks', sa.Column('status', sqlmodel.sql.sqltypes.AutoString(), server_default='confirmed', nullable=False))
    op.alter_column('tasks', 'status', server_default=None)
    op.create_check_constraint('ck_tasks_status', 'tasks', "status IN ('draft', 'confirmed')")
    op.create_index(op.f('ix_tasks_status'), 'tasks', ['status'], unique=False)


def downgrade() -> None:
    """Downgrade schema."""
    # 이전 스키마에는 draft 개념이 없어 저장하지 않은 할 일이 담긴 것처럼 보이게 되므로 지움
    op.execute("DELETE FROM tasks WHERE status = 'draft'")
    op.drop_index(op.f('ix_tasks_status'), table_name='tasks')
    op.drop_constraint('ck_tasks_status', 'tasks', type_='check')
    op.drop_column('tasks', 'status')
