"""Create the bounded relay store.

Revision ID: 0001
Revises:
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0001"
down_revision: str | None = None
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "rides",
        sa.Column("id", sa.String(length=128), nullable=False),
        sa.Column("token_hash", sa.LargeBinary(length=32), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("last_seen_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("delete_after", sa.DateTime(timezone=True), nullable=False),
        sa.Column("ended_at", sa.DateTime(timezone=True), nullable=True),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_table(
        "ride_events",
        sa.Column("sequence", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("ride_id", sa.String(length=128), nullable=False),
        sa.Column("event_id", sa.String(length=128), nullable=False),
        sa.Column("device_id", sa.String(length=128), nullable=False),
        sa.Column("event_type", sa.String(length=48), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("body_hash", sa.LargeBinary(length=32), nullable=False),
        sa.Column("body_ciphertext", sa.LargeBinary(), nullable=False),
        sa.ForeignKeyConstraint(["ride_id"], ["rides.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("sequence"),
        sa.UniqueConstraint("ride_id", "event_id", name="uq_ride_event_identity"),
    )
    op.create_index("ix_ride_events_cursor", "ride_events", ["ride_id", "sequence"])
    op.create_index("ix_ride_events_expiry", "ride_events", ["expires_at"])
    op.create_table(
        "idempotency_replays",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("ride_id", sa.String(length=128), nullable=False),
        sa.Column("idempotency_key", sa.String(length=64), nullable=False),
        sa.Column("request_hash", sa.LargeBinary(length=32), nullable=False),
        sa.Column("response_ciphertext", sa.LargeBinary(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["ride_id"], ["rides.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint(
            "ride_id",
            "idempotency_key",
            name="uq_ride_idempotency_key",
        ),
    )
    op.create_index(
        "ix_idempotency_replays_expiry",
        "idempotency_replays",
        ["expires_at"],
    )


def downgrade() -> None:
    op.drop_index("ix_idempotency_replays_expiry", table_name="idempotency_replays")
    op.drop_table("idempotency_replays")
    op.drop_index("ix_ride_events_expiry", table_name="ride_events")
    op.drop_index("ix_ride_events_cursor", table_name="ride_events")
    op.drop_table("ride_events")
    op.drop_table("rides")
