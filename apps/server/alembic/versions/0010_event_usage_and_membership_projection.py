"""Add constant-time event usage and push membership projections.

Revision ID: 0010
Revises: 0009
Create Date: 2026-08-04
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0010"
down_revision: str | None = "0009"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "voyages",
        sa.Column("stored_event_count", sa.Integer(), nullable=False, server_default="0"),
    )
    op.add_column(
        "voyages",
        sa.Column("stored_event_bytes", sa.BigInteger(), nullable=False, server_default="0"),
    )
    # Existing encrypted journals are rebuilt once by the application. New
    # voyages are explicitly marked ready when claimed.
    op.add_column(
        "voyages",
        sa.Column(
            "membership_projection_ready",
            sa.Boolean(),
            nullable=False,
            server_default=sa.false(),
        ),
    )
    op.create_table(
        "voyage_members",
        sa.Column("voyage_id", sa.String(length=128), nullable=False),
        sa.Column("device_id", sa.String(length=128), nullable=False),
        sa.Column("role", sa.String(length=32), nullable=False),
        sa.Column("state", sa.String(length=16), nullable=False),
        sa.Column("last_seen_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["voyage_id"], ["voyages.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("voyage_id", "device_id"),
    )
    op.execute(
        sa.text(
            """
            UPDATE voyages
            SET stored_event_count = (
                    SELECT COUNT(*) FROM voyage_events WHERE voyage_events.voyage_id = voyages.id
                ),
                stored_event_bytes = (
                    SELECT COALESCE(SUM(LENGTH(body_ciphertext)), 0)
                    FROM voyage_events
                    WHERE voyage_events.voyage_id = voyages.id
                )
            """
        )
    )


def downgrade() -> None:
    op.drop_table("voyage_members")
    op.drop_column("voyages", "membership_projection_ready")
    op.drop_column("voyages", "stored_event_bytes")
    op.drop_column("voyages", "stored_event_count")
