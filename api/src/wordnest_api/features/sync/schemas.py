"""The delta-sync wire format.

Field names match the device's Drift columns exactly, so a row travels as
itself and there is no mapping layer to keep in step.
"""

from datetime import UTC, datetime
from typing import Annotated

from pydantic import AfterValidator, BaseModel, Field

RowId = Annotated[str, Field(min_length=8, max_length=64)]


def _assume_utc(value: datetime) -> datetime:
    """Every timestamp on the wire is UTC, stated explicitly.

    Two reasons this cannot be left implicit. SQLite has no time zone type, so
    a row read back from it is naive; serialised as-is, a client would parse it
    in its own zone and the instant would move by hours — enough to lose a
    last-write-wins comparison. And a device in another zone may send an offset
    of its own, which has to be normalised before it can be compared.
    """
    return value if value.tzinfo else value.replace(tzinfo=UTC)


#: Use for every datetime that crosses the wire.
UtcDatetime = Annotated[datetime, AfterValidator(_assume_utc)]


class SyncedRowBase(BaseModel):
    id: RowId
    updated_at: UtcDatetime
    deleted_at: UtcDatetime | None = None


class UtterancePayload(SyncedRowBase):
    source_text: str = Field(max_length=4000)
    translation_text: str = Field(default="", max_length=4000)
    literal_gloss: str | None = Field(default=None, max_length=4000)
    source_language: str = Field(min_length=2, max_length=8)
    target_language: str = Field(min_length=2, max_length=8)
    spoken_at: UtcDatetime
    enrichment_state: str = Field(default="pending", max_length=16)
    is_flagged: bool = False


class GlossaryEntryPayload(SyncedRowBase):
    lemma: str = Field(max_length=160)
    surface_form: str = Field(max_length=160)
    part_of_speech: str | None = Field(default=None, max_length=16)
    target_form: str | None = Field(default=None, max_length=160)
    source_language: str = Field(min_length=2, max_length=8)
    target_language: str = Field(min_length=2, max_length=8)

    #: Sent for completeness but never trusted: the server recomputes it from
    #: the occurrence rows after every merge.
    seen_count: int = Field(default=0, ge=0)
    example_utterance_id: str | None = None
    is_flagged: bool = False
    interval_days: int = Field(default=0, ge=0)
    ease_factor: float = Field(default=2.5, ge=1.3)
    repetition_count: int = Field(default=0, ge=0)
    due_at: UtcDatetime | None = None
    last_reviewed_at: UtcDatetime | None = None


class GlossaryOccurrencePayload(SyncedRowBase):
    glossary_entry_id: RowId
    utterance_id: RowId
    surface_form: str = Field(max_length=160)


class ReviewLogPayload(SyncedRowBase):
    glossary_entry_id: RowId
    reviewed_at: UtcDatetime
    grade: int = Field(ge=0, le=5)
    scheduled_interval_days: int = Field(default=0, ge=0)
    scheduled_ease_factor: float = Field(default=2.5, ge=1.3)


class ChangeSet(BaseModel):
    """Rows moving in one direction. Empty lists are normal, not an error."""

    utterances: list[UtterancePayload] = Field(default_factory=list)
    glossary_entries: list[GlossaryEntryPayload] = Field(default_factory=list)
    glossary_occurrences: list[GlossaryOccurrencePayload] = Field(default_factory=list)
    review_logs: list[ReviewLogPayload] = Field(default_factory=list)

    @property
    def total(self) -> int:
        return (
            len(self.utterances)
            + len(self.glossary_entries)
            + len(self.glossary_occurrences)
            + len(self.review_logs)
        )


class SyncRequest(BaseModel):
    """One round trip: push what changed here, pull what changed there.

    `cursor` is the server sequence number this device has already seen, not a
    timestamp — device clocks drift, and a client syncing in the same
    millisecond as a write would miss it.
    """

    cursor: int = Field(default=0, ge=0)
    changes: ChangeSet = Field(default_factory=ChangeSet)


class SyncRejection(BaseModel):
    """A row the server would not take, and why.

    Reported rather than failing the whole batch: one bad row must not stop a
    fortnight of good ones from landing.
    """

    id: str
    table: str
    code: str
    message: str


class SyncResponse(BaseModel):
    changes: ChangeSet
    cursor: int

    #: True when the pull hit the page limit. The client should sync again
    #: immediately rather than waiting for the next trigger.
    has_more: bool = False

    #: How many pushed rows were applied, for the sync status line.
    applied: int = 0
    rejected: list[SyncRejection] = Field(default_factory=list)
