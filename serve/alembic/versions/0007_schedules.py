"""schedules, tasks.schedule_id/phase/days_before

Revision ID: 0007
Revises: 0006
Create Date: 2026-11-18 10:00:00

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
import sqlmodel  # noqa: F401  autogenerate가 sqlmodel.AutoString을 쓸 때 필요


# revision identifiers, used by Alembic.
revision: str = '0007'
down_revision: Union[str, Sequence[str], None] = '0006'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    op.create_table('schedules',
    sa.Column('id', sa.Integer(), nullable=False),
    sa.Column('user_id', sa.Integer(), nullable=False),
    sa.Column('kind', sqlmodel.sql.sqltypes.AutoString(), nullable=False),
    sa.Column('title', sqlmodel.sql.sqltypes.AutoString(), nullable=False),
    sa.Column('target_date', sa.Date(), nullable=False),
    sa.Column('created_at', sqlmodel.sql.sqltypes.UTCDateTime(), nullable=False),
    sa.CheckConstraint("kind IN ('exam', 'contest')", name='ck_schedules_kind'),
    sa.ForeignKeyConstraint(['user_id'], ['users.id'], ),
    sa.PrimaryKeyConstraint('id')
    )
    op.create_index(op.f('ix_schedules_user_id'), 'schedules', ['user_id'], unique=False)
    # 기존 할 일은 모두 공지의 것: notice_id는 그대로이고 새 컬럼은 비어 있음 (행을 지우거나 고치지 않음)
    op.add_column('tasks', sa.Column('schedule_id', sa.Integer(), nullable=True))
    op.add_column('tasks', sa.Column('phase', sqlmodel.sql.sqltypes.AutoString(), nullable=True))
    op.add_column('tasks', sa.Column('days_before', sa.Integer(), nullable=True))
    op.create_foreign_key('tasks_schedule_id_fkey', 'tasks', 'schedules', ['schedule_id'], ['id'], ondelete='CASCADE')
    op.create_index(op.f('ix_tasks_schedule_id'), 'tasks', ['schedule_id'], unique=False)
    op.alter_column('tasks', 'notice_id', existing_type=sa.Integer(), nullable=True)
    op.create_check_constraint('ck_tasks_owner', 'tasks', '(notice_id IS NULL) <> (schedule_id IS NULL)')


def downgrade() -> None:
    """Downgrade schema."""
    # 이전 스키마에는 일정이 없어 일정의 할 일은 넣을 수 없으므로 삭제됨
    op.execute("DELETE FROM tasks WHERE schedule_id IS NOT NULL")
    op.drop_constraint('ck_tasks_owner', 'tasks', type_='check')
    op.alter_column('tasks', 'notice_id', existing_type=sa.Integer(), nullable=False)
    op.drop_index(op.f('ix_tasks_schedule_id'), table_name='tasks')
    op.drop_constraint('tasks_schedule_id_fkey', 'tasks', type_='foreignkey')
    op.drop_column('tasks', 'days_before')
    op.drop_column('tasks', 'phase')
    op.drop_column('tasks', 'schedule_id')
    op.drop_index(op.f('ix_schedules_user_id'), table_name='schedules')
    op.drop_table('schedules')
