"""Add encrypted pre-voyage GPX plan lookups.

Revision ID: 0003
Revises: 0002
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0003"
down_revision: str | None = "0002"
branch_labels: str | Sequence[str] | None = None
depends_on: str | None = None


def upgrade() -> None:
    op.create_table(
        "voyage_plans",
        sa.Column("code", sa.String(length=16), nullable=False),
        sa.Column("name", sa.String(length=200), nullable=True),
        sa.Column("gpx_ciphertext", sa.LargeBinary(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.PrimaryKeyConstraint("code"),
    )
    op.create_index("ix_voyage_plans_expiry", "voyage_plans", ["expires_at"])


def downgrade() -> None:
    op.drop_index("ix_voyage_plans_expiry", table_name="voyage_plans")
    op.drop_table("voyage_plans")
