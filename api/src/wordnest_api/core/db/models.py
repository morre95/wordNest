"""Every table in the service, in one place.

Identity is two layers: an [Account] owns the data, a [Device] is one install
that can reach it. An account starts anonymous — created silently on first
launch, with no email and no password — and is later upgraded by attaching a
durable identity, without ever losing what it already holds.
"""

from datetime import datetime

from sqlalchemy import (
    Boolean,
    CheckConstraint,
    DateTime,
    Float,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
    UniqueConstraint,
    func,
)
from sqlalchemy.orm import Mapped, mapped_column

from .base import Base, SyncedRow


class Account(Base):
    """One user's data, however many devices they use.

    Anonymous until [email] is set. Merging one account into another is what
    "signing in on a second device" means; [merged_into_account_id] records
    where an account's data went so a stale token can be told.
    """

    __tablename__ = "accounts"

    id: Mapped[str] = mapped_column(String(64), primary_key=True)

    #: Null while anonymous. Unique once set — it is the durable identity.
    email: Mapped[str | None] = mapped_column(String(320), unique=True)
    email_verified_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    merged_into_account_id: Mapped[str | None] = mapped_column(
        String(64), ForeignKey("accounts.id")
    )

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
        onupdate=func.now(),
    )

    @property
    def is_anonymous(self) -> bool:
        return self.email is None


class Device(Base):
    """One install. Registering is what gets an app its first token."""

    __tablename__ = "devices"

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    account_id: Mapped[str] = mapped_column(
        String(64), ForeignKey("accounts.id"), index=True, nullable=False
    )

    #: Shown in the device list in settings, so a user can tell them apart.
    display_name: Mapped[str] = mapped_column(String(120), nullable=False)
    platform: Mapped[str] = mapped_column(String(32), nullable=False)

    #: Set when the user revokes the device. A revoked device's refresh token
    #: stops working, and its access token expires within minutes.
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    last_seen_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )

    @property
    def is_active(self) -> bool:
        return self.revoked_at is None


class RefreshToken(Base):
    """A long-lived credential, stored only as a hash.

    A leaked database must not yield working tokens, and a refresh token is a
    high-entropy random string rather than a password, so a plain SHA-256 is
    the right hash: no stretching is needed and none is wanted on a hot path.
    """

    __tablename__ = "refresh_tokens"

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    device_id: Mapped[str] = mapped_column(
        String(64), ForeignKey("devices.id"), index=True, nullable=False
    )
    token_hash: Mapped[str] = mapped_column(String(64), unique=True, nullable=False)
    expires_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False
    )

    #: Set when the token is exchanged. Refresh tokens rotate, so a token used
    #: twice means it was stolen — see the reuse check in the auth service.
    used_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )


class PairingCode(Base):
    """A short code shown on a signed-in device and typed into a new one.

    The no-email path to a second device. Short-lived and single-use, and
    stored hashed like any other credential.

    Six digits is little entropy, so the protection is the ten-minute expiry
    plus a limit on how fast a device may guess. That limit is deliberately
    *not* a counter on this row: a blind guesser does not name a code, so
    counting a wrong guess against every live code would let one attacker
    invalidate every other user's pairing at will.
    """

    __tablename__ = "pairing_codes"

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    account_id: Mapped[str] = mapped_column(
        String(64), ForeignKey("accounts.id"), index=True, nullable=False
    )
    code_hash: Mapped[str] = mapped_column(String(64), nullable=False, index=True)
    expires_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False
    )
    consumed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )


class MagicLinkToken(Base):
    """A one-time token emailed to attach an email address to an account."""

    __tablename__ = "magic_link_tokens"

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    email: Mapped[str] = mapped_column(String(320), nullable=False, index=True)

    #: The account asking to be upgraded — usually an anonymous one with a
    #: week of data in it.
    account_id: Mapped[str] = mapped_column(
        String(64), ForeignKey("accounts.id"), nullable=False
    )
    token_hash: Mapped[str] = mapped_column(String(64), unique=True, nullable=False)
    expires_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False
    )
    consumed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )


class Utterance(Base, SyncedRow):
    """Immutable once finalised, apart from enrichment, which only the
    originating device writes. That is what makes these conflict-free."""

    __tablename__ = "utterances"
    __table_args__ = (
        Index("ix_utterances_account_sequence", "account_id", "server_sequence"),
        CheckConstraint(
            "source_language <> target_language", name="ck_utterances_pair"
        ),
    )

    source_text: Mapped[str] = mapped_column(Text, nullable=False)
    translation_text: Mapped[str] = mapped_column(Text, nullable=False, default="")
    literal_gloss: Mapped[str | None] = mapped_column(Text)
    source_language: Mapped[str] = mapped_column(String(8), nullable=False)
    target_language: Mapped[str] = mapped_column(String(8), nullable=False)
    spoken_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    enrichment_state: Mapped[str] = mapped_column(
        String(16), nullable=False, default="pending"
    )
    is_flagged: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)


class GlossaryEntry(Base, SyncedRow):
    """The only genuinely mergeable row type. See `features/sync/merge.py`."""

    __tablename__ = "glossary_entries"
    __table_args__ = (
        UniqueConstraint(
            "account_id",
            "lemma",
            "source_language",
            "target_language",
            name="uq_glossary_entries_word",
        ),
        Index("ix_glossary_entries_account_sequence", "account_id", "server_sequence"),
        CheckConstraint("ease_factor >= 1.3", name="ck_glossary_ease"),
        CheckConstraint("seen_count >= 0", name="ck_glossary_seen_count"),
    )

    lemma: Mapped[str] = mapped_column(String(160), nullable=False)
    surface_form: Mapped[str] = mapped_column(String(160), nullable=False)
    part_of_speech: Mapped[str | None] = mapped_column(String(16))
    target_form: Mapped[str | None] = mapped_column(String(160))
    source_language: Mapped[str] = mapped_column(String(8), nullable=False)
    target_language: Mapped[str] = mapped_column(String(8), nullable=False)

    #: Derived from the occurrence rows, never copied between devices.
    seen_count: Mapped[int] = mapped_column(Integer, nullable=False, default=0)

    example_utterance_id: Mapped[str | None] = mapped_column(String(64))
    is_flagged: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)

    interval_days: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    ease_factor: Mapped[float] = mapped_column(Float, nullable=False, default=2.5)
    repetition_count: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    due_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    last_reviewed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class GlossaryOccurrence(Base, SyncedRow):
    """One sighting of a word in one sentence.

    These are what `seen_count` is recomputed from, which is why two devices
    that each heard a word twice offline converge on four rather than on
    whichever number synced last.
    """

    __tablename__ = "glossary_occurrences"
    __table_args__ = (
        UniqueConstraint(
            "glossary_entry_id",
            "utterance_id",
            name="uq_glossary_occurrences_sighting",
        ),
        Index(
            "ix_glossary_occurrences_account_sequence",
            "account_id",
            "server_sequence",
        ),
    )

    glossary_entry_id: Mapped[str] = mapped_column(String(64), nullable=False)
    utterance_id: Mapped[str] = mapped_column(String(64), nullable=False)
    surface_form: Mapped[str] = mapped_column(String(160), nullable=False)


class ReviewLog(Base, SyncedRow):
    """An immutable event. Append-only, deduplicated by id, so two devices
    reviewing offline both contribute rather than one overwriting the other."""

    __tablename__ = "review_logs"
    __table_args__ = (
        Index("ix_review_logs_account_sequence", "account_id", "server_sequence"),
        CheckConstraint("grade BETWEEN 0 AND 5", name="ck_review_logs_grade"),
    )

    glossary_entry_id: Mapped[str] = mapped_column(
        String(64), nullable=False, index=True
    )
    reviewed_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False
    )
    grade: Mapped[int] = mapped_column(Integer, nullable=False)
    scheduled_interval_days: Mapped[int] = mapped_column(
        Integer, nullable=False, default=0
    )
    scheduled_ease_factor: Mapped[float] = mapped_column(
        Float, nullable=False, default=2.5
    )


class SequenceCounter(Base):
    """The monotonic server sequence, one row per account.

    Per-account rather than global so one busy account cannot push another's
    cursor forward, and so a pull only walks rows that could be relevant.
    Incremented inside the same transaction as the writes it numbers.
    """

    __tablename__ = "sequence_counters"

    account_id: Mapped[str] = mapped_column(
        String(64), ForeignKey("accounts.id"), primary_key=True
    )
    value: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
