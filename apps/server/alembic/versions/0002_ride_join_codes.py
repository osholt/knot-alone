"""Add encrypted six-digit ride-code lookups.

Revision ID: 0002
Revises: 0001
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0002"
down_revision: str | None = "0001"
branch_labels: str | Sequence[str] | None = None
depends_on: str | None = None


def upgrade() -> None:
    op.create_table(
        "ride_join_codes",
        sa.Column("code", sa.String(length=6), nullable=False),
        sa.Column("ride_id", sa.String(length=128), nullable=False),
        sa.Column("token_hash", sa.LargeBinary(length=32), nullable=False),
        sa.Column("secret_ciphertext", sa.LargeBinary(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.PrimaryKeyConstraint("code"),
    )
    op.create_index("ix_ride_join_codes_expiry", "ride_join_codes", ["expires_at"])


def downgrade() -> None:
    op.drop_index("ix_ride_join_codes_expiry", table_name="ride_join_codes")
    op.drop_table("ride_join_codes")
