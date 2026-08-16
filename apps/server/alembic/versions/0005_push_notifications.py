"""Add encrypted ride push registrations and delivery deduplication.

Revision ID: 0005
Revises: 0004
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0005"
down_revision: str | None = "0004"
branch_labels: str | Sequence[str] | None = None
depends_on: str | None = None


def upgrade() -> None:
    op.create_table(
        "push_registrations",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("ride_id", sa.String(length=128), nullable=False),
        sa.Column("installation_id", sa.String(length=128), nullable=False),
        sa.Column("platform", sa.String(length=16), nullable=False),
        sa.Column("provider", sa.String(length=16), nullable=False),
        sa.Column("token_hash", sa.LargeBinary(length=32), nullable=False),
        sa.Column("token_ciphertext", sa.LargeBinary(), nullable=False),
        sa.Column("role", sa.String(length=32), nullable=False),
        sa.Column("safety_enabled", sa.Boolean(), nullable=False),
        sa.Column("status_enabled", sa.Boolean(), nullable=False),
        sa.Column("administrative_enabled", sa.Boolean(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("last_seen_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(["ride_id"], ["rides.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint(
            "ride_id",
            "installation_id",
            "provider",
            name="uq_push_registration_installation",
        ),
    )
    op.create_index(
        "ix_push_registrations_active",
        "push_registrations",
        ["ride_id", "revoked_at"],
    )
    op.create_index(
        "ix_push_registrations_token",
        "push_registrations",
        ["provider", "token_hash"],
    )
    op.create_table(
        "push_deliveries",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("ride_id", sa.String(length=128), nullable=False),
        sa.Column("event_id", sa.String(length=128), nullable=False),
        sa.Column("registration_id", sa.Integer(), nullable=False),
        sa.Column("category", sa.String(length=24), nullable=False),
        sa.Column("status", sa.String(length=24), nullable=False),
        sa.Column("provider_message_id", sa.String(length=256), nullable=True),
        sa.Column("error_code", sa.String(length=80), nullable=True),
        sa.Column("attempted_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(
            ["registration_id"],
            ["push_registrations.id"],
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint(
            "ride_id",
            "event_id",
            "registration_id",
            name="uq_push_delivery_event_recipient",
        ),
    )
    op.create_index(
        "ix_push_deliveries_status",
        "push_deliveries",
        ["status", "attempted_at"],
    )


def downgrade() -> None:
    op.drop_index("ix_push_deliveries_status", table_name="push_deliveries")
    op.drop_table("push_deliveries")
    op.drop_index("ix_push_registrations_token", table_name="push_registrations")
    op.drop_index("ix_push_registrations_active", table_name="push_registrations")
    op.drop_table("push_registrations")
