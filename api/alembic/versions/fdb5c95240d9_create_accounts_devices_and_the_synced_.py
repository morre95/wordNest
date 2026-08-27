"""create accounts, devices and the synced tables

The whole schema in one migration because it is the first one: identity
(accounts, devices, refresh tokens, pairing codes, magic links) and the four
synced tables, each of which carries the client-generated id, updated_at,
deleted_at tombstone and server_sequence that delta sync walks.

Revision ID: fdb5c95240d9
Revises:
Create Date: 2026-08-27 09:25:34.352259

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = "fdb5c95240d9"
down_revision: str | Sequence[str] | None = None
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    """Upgrade schema."""
    op.create_table(
        "accounts",
        sa.Column("id", sa.String(length=64), nullable=False),
        sa.Column("email", sa.String(length=320), nullable=True),
        sa.Column("email_verified_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("merged_into_account_id", sa.String(length=64), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("(CURRENT_TIMESTAMP)"),
            nullable=False,
        ),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("(CURRENT_TIMESTAMP)"),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(
            ["merged_into_account_id"],
            ["accounts.id"],
        ),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("email"),
    )
    op.create_table(
        "glossary_entries",
        sa.Column("lemma", sa.String(length=160), nullable=False),
        sa.Column("surface_form", sa.String(length=160), nullable=False),
        sa.Column("part_of_speech", sa.String(length=16), nullable=True),
        sa.Column("target_form", sa.String(length=160), nullable=True),
        sa.Column("source_language", sa.String(length=8), nullable=False),
        sa.Column("target_language", sa.String(length=8), nullable=False),
        sa.Column("seen_count", sa.Integer(), nullable=False),
        sa.Column("example_utterance_id", sa.String(length=64), nullable=True),
        sa.Column("is_flagged", sa.Boolean(), nullable=False),
        sa.Column("interval_days", sa.Integer(), nullable=False),
        sa.Column("ease_factor", sa.Float(), nullable=False),
        sa.Column("repetition_count", sa.Integer(), nullable=False),
        sa.Column("due_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("last_reviewed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("id", sa.String(length=64), nullable=False),
        sa.Column("account_id", sa.String(length=64), nullable=False),
        sa.Column("origin_device_id", sa.String(length=64), nullable=True),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("deleted_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("server_sequence", sa.BigInteger(), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("(CURRENT_TIMESTAMP)"),
            nullable=False,
        ),
        sa.CheckConstraint("ease_factor >= 1.3", name="ck_glossary_ease"),
        sa.CheckConstraint("seen_count >= 0", name="ck_glossary_seen_count"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint(
            "account_id",
            "lemma",
            "source_language",
            "target_language",
            name="uq_glossary_entries_word",
        ),
    )
    with op.batch_alter_table("glossary_entries", schema=None) as batch_op:
        batch_op.create_index(
            batch_op.f("ix_glossary_entries_account_id"), ["account_id"], unique=False
        )
        batch_op.create_index(
            "ix_glossary_entries_account_sequence",
            ["account_id", "server_sequence"],
            unique=False,
        )
        batch_op.create_index(
            batch_op.f("ix_glossary_entries_server_sequence"),
            ["server_sequence"],
            unique=False,
        )

    op.create_table(
        "glossary_occurrences",
        sa.Column("glossary_entry_id", sa.String(length=64), nullable=False),
        sa.Column("utterance_id", sa.String(length=64), nullable=False),
        sa.Column("surface_form", sa.String(length=160), nullable=False),
        sa.Column("id", sa.String(length=64), nullable=False),
        sa.Column("account_id", sa.String(length=64), nullable=False),
        sa.Column("origin_device_id", sa.String(length=64), nullable=True),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("deleted_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("server_sequence", sa.BigInteger(), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("(CURRENT_TIMESTAMP)"),
            nullable=False,
        ),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint(
            "glossary_entry_id", "utterance_id", name="uq_glossary_occurrences_sighting"
        ),
    )
    with op.batch_alter_table("glossary_occurrences", schema=None) as batch_op:
        batch_op.create_index(
            batch_op.f("ix_glossary_occurrences_account_id"),
            ["account_id"],
            unique=False,
        )
        batch_op.create_index(
            "ix_glossary_occurrences_account_sequence",
            ["account_id", "server_sequence"],
            unique=False,
        )
        batch_op.create_index(
            batch_op.f("ix_glossary_occurrences_server_sequence"),
            ["server_sequence"],
            unique=False,
        )

    op.create_table(
        "review_logs",
        sa.Column("glossary_entry_id", sa.String(length=64), nullable=False),
        sa.Column("reviewed_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("grade", sa.Integer(), nullable=False),
        sa.Column("scheduled_interval_days", sa.Integer(), nullable=False),
        sa.Column("scheduled_ease_factor", sa.Float(), nullable=False),
        sa.Column("id", sa.String(length=64), nullable=False),
        sa.Column("account_id", sa.String(length=64), nullable=False),
        sa.Column("origin_device_id", sa.String(length=64), nullable=True),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("deleted_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("server_sequence", sa.BigInteger(), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("(CURRENT_TIMESTAMP)"),
            nullable=False,
        ),
        sa.CheckConstraint("grade BETWEEN 0 AND 5", name="ck_review_logs_grade"),
        sa.PrimaryKeyConstraint("id"),
    )
    with op.batch_alter_table("review_logs", schema=None) as batch_op:
        batch_op.create_index(
            batch_op.f("ix_review_logs_account_id"), ["account_id"], unique=False
        )
        batch_op.create_index(
            "ix_review_logs_account_sequence",
            ["account_id", "server_sequence"],
            unique=False,
        )
        batch_op.create_index(
            batch_op.f("ix_review_logs_glossary_entry_id"),
            ["glossary_entry_id"],
            unique=False,
        )
        batch_op.create_index(
            batch_op.f("ix_review_logs_server_sequence"),
            ["server_sequence"],
            unique=False,
        )

    op.create_table(
        "utterances",
        sa.Column("source_text", sa.Text(), nullable=False),
        sa.Column("translation_text", sa.Text(), nullable=False),
        sa.Column("literal_gloss", sa.Text(), nullable=True),
        sa.Column("source_language", sa.String(length=8), nullable=False),
        sa.Column("target_language", sa.String(length=8), nullable=False),
        sa.Column("spoken_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("enrichment_state", sa.String(length=16), nullable=False),
        sa.Column("is_flagged", sa.Boolean(), nullable=False),
        sa.Column("id", sa.String(length=64), nullable=False),
        sa.Column("account_id", sa.String(length=64), nullable=False),
        sa.Column("origin_device_id", sa.String(length=64), nullable=True),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("deleted_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("server_sequence", sa.BigInteger(), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("(CURRENT_TIMESTAMP)"),
            nullable=False,
        ),
        sa.CheckConstraint(
            "source_language <> target_language", name="ck_utterances_pair"
        ),
        sa.PrimaryKeyConstraint("id"),
    )
    with op.batch_alter_table("utterances", schema=None) as batch_op:
        batch_op.create_index(
            batch_op.f("ix_utterances_account_id"), ["account_id"], unique=False
        )
        batch_op.create_index(
            "ix_utterances_account_sequence",
            ["account_id", "server_sequence"],
            unique=False,
        )
        batch_op.create_index(
            batch_op.f("ix_utterances_server_sequence"),
            ["server_sequence"],
            unique=False,
        )

    op.create_table(
        "devices",
        sa.Column("id", sa.String(length=64), nullable=False),
        sa.Column("account_id", sa.String(length=64), nullable=False),
        sa.Column("display_name", sa.String(length=120), nullable=False),
        sa.Column("platform", sa.String(length=32), nullable=False),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("last_seen_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("(CURRENT_TIMESTAMP)"),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(
            ["account_id"],
            ["accounts.id"],
        ),
        sa.PrimaryKeyConstraint("id"),
    )
    with op.batch_alter_table("devices", schema=None) as batch_op:
        batch_op.create_index(
            batch_op.f("ix_devices_account_id"), ["account_id"], unique=False
        )

    op.create_table(
        "magic_link_tokens",
        sa.Column("id", sa.String(length=64), nullable=False),
        sa.Column("email", sa.String(length=320), nullable=False),
        sa.Column("account_id", sa.String(length=64), nullable=False),
        sa.Column("token_hash", sa.String(length=64), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("consumed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("(CURRENT_TIMESTAMP)"),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(
            ["account_id"],
            ["accounts.id"],
        ),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("token_hash"),
    )
    with op.batch_alter_table("magic_link_tokens", schema=None) as batch_op:
        batch_op.create_index(
            batch_op.f("ix_magic_link_tokens_email"), ["email"], unique=False
        )

    op.create_table(
        "pairing_codes",
        sa.Column("id", sa.String(length=64), nullable=False),
        sa.Column("account_id", sa.String(length=64), nullable=False),
        sa.Column("code_hash", sa.String(length=64), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("consumed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("(CURRENT_TIMESTAMP)"),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(
            ["account_id"],
            ["accounts.id"],
        ),
        sa.PrimaryKeyConstraint("id"),
    )
    with op.batch_alter_table("pairing_codes", schema=None) as batch_op:
        batch_op.create_index(
            batch_op.f("ix_pairing_codes_account_id"), ["account_id"], unique=False
        )
        batch_op.create_index(
            batch_op.f("ix_pairing_codes_code_hash"), ["code_hash"], unique=False
        )

    op.create_table(
        "sequence_counters",
        sa.Column("account_id", sa.String(length=64), nullable=False),
        sa.Column("value", sa.Integer(), nullable=False),
        sa.ForeignKeyConstraint(
            ["account_id"],
            ["accounts.id"],
        ),
        sa.PrimaryKeyConstraint("account_id"),
    )
    op.create_table(
        "refresh_tokens",
        sa.Column("id", sa.String(length=64), nullable=False),
        sa.Column("device_id", sa.String(length=64), nullable=False),
        sa.Column("token_hash", sa.String(length=64), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("used_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("(CURRENT_TIMESTAMP)"),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(
            ["device_id"],
            ["devices.id"],
        ),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("token_hash"),
    )
    with op.batch_alter_table("refresh_tokens", schema=None) as batch_op:
        batch_op.create_index(
            batch_op.f("ix_refresh_tokens_device_id"), ["device_id"], unique=False
        )


def downgrade() -> None:
    """Downgrade schema."""
    with op.batch_alter_table("refresh_tokens", schema=None) as batch_op:
        batch_op.drop_index(batch_op.f("ix_refresh_tokens_device_id"))

    op.drop_table("refresh_tokens")
    op.drop_table("sequence_counters")
    with op.batch_alter_table("pairing_codes", schema=None) as batch_op:
        batch_op.drop_index(batch_op.f("ix_pairing_codes_code_hash"))
        batch_op.drop_index(batch_op.f("ix_pairing_codes_account_id"))

    op.drop_table("pairing_codes")
    with op.batch_alter_table("magic_link_tokens", schema=None) as batch_op:
        batch_op.drop_index(batch_op.f("ix_magic_link_tokens_email"))

    op.drop_table("magic_link_tokens")
    with op.batch_alter_table("devices", schema=None) as batch_op:
        batch_op.drop_index(batch_op.f("ix_devices_account_id"))

    op.drop_table("devices")
    with op.batch_alter_table("utterances", schema=None) as batch_op:
        batch_op.drop_index(batch_op.f("ix_utterances_server_sequence"))
        batch_op.drop_index("ix_utterances_account_sequence")
        batch_op.drop_index(batch_op.f("ix_utterances_account_id"))

    op.drop_table("utterances")
    with op.batch_alter_table("review_logs", schema=None) as batch_op:
        batch_op.drop_index(batch_op.f("ix_review_logs_server_sequence"))
        batch_op.drop_index(batch_op.f("ix_review_logs_glossary_entry_id"))
        batch_op.drop_index("ix_review_logs_account_sequence")
        batch_op.drop_index(batch_op.f("ix_review_logs_account_id"))

    op.drop_table("review_logs")
    with op.batch_alter_table("glossary_occurrences", schema=None) as batch_op:
        batch_op.drop_index(batch_op.f("ix_glossary_occurrences_server_sequence"))
        batch_op.drop_index("ix_glossary_occurrences_account_sequence")
        batch_op.drop_index(batch_op.f("ix_glossary_occurrences_account_id"))

    op.drop_table("glossary_occurrences")
    with op.batch_alter_table("glossary_entries", schema=None) as batch_op:
        batch_op.drop_index(batch_op.f("ix_glossary_entries_server_sequence"))
        batch_op.drop_index("ix_glossary_entries_account_sequence")
        batch_op.drop_index(batch_op.f("ix_glossary_entries_account_id"))

    op.drop_table("glossary_entries")
    op.drop_table("accounts")
