"""How two versions of a row become one.

Pure: no I/O, no database, no clock. Everything it needs is in its arguments,
so every awkward case can be tested directly. The same rules exist on the
device in `app/lib/core/sync/merge.dart`; the two are kept in step by the same
set of named cases.

Blanket last-write-wins is wrong here, because the three kinds of data merge
differently:

* **Utterances** are immutable once finalised. Only the device that created one
  ever writes it again, to attach the enriched translation. Two devices cannot
  disagree about one, so the only question is whether an incoming write is
  allowed at all.
* **Review logs** are immutable events. Two devices reviewing offline both
  contribute; the merge is deduplication by id, nothing more.
* **Glossary entries** genuinely merge, field by field, and are the reason this
  module exists.
"""

from dataclasses import dataclass, replace
from datetime import UTC, datetime, timedelta
from enum import StrEnum


class MergeOutcome(StrEnum):
    """What the merge decided, so a caller can log or count it."""

    #: The row is new here; insert it.
    inserted = "inserted"

    #: The incoming version won outright.
    replaced = "replaced"

    #: The stored version won; nothing to write.
    kept = "kept"

    #: Fields were taken from both sides.
    merged = "merged"

    #: The incoming write is not allowed. Utterances only.
    rejected = "rejected"


def _as_utc(moment: datetime | None) -> datetime | None:
    """Timestamps arrive from devices in different time zones and from the
    database with and without tzinfo. Comparing them requires one convention."""
    if moment is None:
        return None
    if moment.tzinfo is None:
        return moment.replace(tzinfo=UTC)
    return moment.astimezone(UTC)


def _later(left: datetime | None, right: datetime | None) -> bool:
    """True when `left` is strictly later than `right`.

    Strictly, so a tie leaves the stored version in place: an equal timestamp
    means nothing actually changed, and rewriting it would burn a sequence
    number and wake every other device for no reason.
    """
    left, right = _as_utc(left), _as_utc(right)
    if left is None:
        return False
    if right is None:
        return True
    return left > right


# --- Utterances -------------------------------------------------------------


@dataclass(frozen=True)
class UtteranceSnapshot:
    id: str
    origin_device_id: str | None
    updated_at: datetime
    deleted_at: datetime | None
    source_text: str
    translation_text: str
    literal_gloss: str | None
    enrichment_state: str
    is_flagged: bool


@dataclass(frozen=True)
class MergeResult[SnapshotT]:
    outcome: MergeOutcome
    value: SnapshotT

    @property
    def should_write(self) -> bool:
        return self.outcome in (
            MergeOutcome.inserted,
            MergeOutcome.replaced,
            MergeOutcome.merged,
        )


def merge_utterance(
    *,
    stored: UtteranceSnapshot | None,
    incoming: UtteranceSnapshot,
    writing_device_id: str,
) -> MergeResult[UtteranceSnapshot]:
    """Append-only, with one writer.

    A new utterance is inserted. An existing one may only be updated by the
    device that created it — that is what carries the enriched translation
    home. Another device pushing a change to someone else's utterance is a bug
    or an attack, and is rejected rather than silently applied.
    """
    if stored is None:
        return MergeResult(
            MergeOutcome.inserted,
            replace(incoming, origin_device_id=writing_device_id),
        )

    if stored.origin_device_id is not None and (
        stored.origin_device_id != writing_device_id
    ):
        return MergeResult(MergeOutcome.rejected, stored)

    # The flag is the user's, and can be set from the device that owns the row;
    # everything else on an utterance is set once and then enriched once.
    if not _later(incoming.updated_at, stored.updated_at):
        return MergeResult(MergeOutcome.kept, stored)

    return MergeResult(
        MergeOutcome.replaced,
        replace(incoming, origin_device_id=writing_device_id),
    )


# --- Review logs ------------------------------------------------------------


@dataclass(frozen=True)
class ReviewLogSnapshot:
    id: str
    glossary_entry_id: str
    reviewed_at: datetime
    grade: int
    scheduled_interval_days: int
    scheduled_ease_factor: float
    updated_at: datetime
    deleted_at: datetime | None


def merge_review_log(
    *,
    stored: ReviewLogSnapshot | None,
    incoming: ReviewLogSnapshot,
) -> MergeResult[ReviewLogSnapshot]:
    """Deduplication, and nothing else.

    A review happened or it did not. The id is client-generated, so a retried
    push after a dropped connection carries the same id and lands on the row
    that is already there instead of recording the review twice.
    """
    if stored is None:
        return MergeResult(MergeOutcome.inserted, incoming)
    return MergeResult(MergeOutcome.kept, stored)


# --- Glossary entries -------------------------------------------------------


@dataclass(frozen=True)
class GlossaryEntrySnapshot:
    id: str
    lemma: str
    surface_form: str
    part_of_speech: str | None
    target_form: str | None
    source_language: str
    target_language: str
    seen_count: int
    example_utterance_id: str | None
    is_flagged: bool
    interval_days: int
    ease_factor: float
    repetition_count: int
    due_at: datetime | None
    last_reviewed_at: datetime | None
    updated_at: datetime
    deleted_at: datetime | None


def due_date_from(
    *, last_reviewed_at: datetime | None, interval_days: int
) -> datetime | None:
    """Recomputes when an entry is next due.

    Called after every merge, so a due date can never survive the schedule it
    was derived from. Without this, a stale `due_at` from the losing side could
    resurface an entry the winning side had already scheduled far out.
    """
    reviewed = _as_utc(last_reviewed_at)
    if reviewed is None:
        return None
    return reviewed + timedelta(days=max(0, interval_days))


def merge_glossary_entry(
    *,
    stored: GlossaryEntrySnapshot | None,
    incoming: GlossaryEntrySnapshot,
) -> MergeResult[GlossaryEntrySnapshot]:
    """Field-level merge, because the fields do not agree on one rule.

    * `seen_count` is not merged at all — it is recomputed from the occurrence
      rows after the merge, so two devices that each heard the word twice
      converge on four instead of on whichever number arrived last.
    * `is_flagged` is the user's own signal: last-write-wins on `updated_at`.
    * The scheduling state moves as one block, decided by `last_reviewed_at` —
      the side that actually reviewed most recently knows best. Splitting the
      block field by field would produce a schedule neither device ever had.
    * `due_at` is then recomputed from the winning state.
    * The description (lemma, part of speech, target form) comes from backend
      enrichment, so last-write-wins on `updated_at` is right.
    * A deletion is just another field under last-write-wins, so a deletion
      racing an update is settled by which happened later — and saying the word
      again, which bumps `updated_at`, revives it.
    """
    if stored is None:
        return MergeResult(
            MergeOutcome.inserted,
            replace(
                incoming,
                due_at=due_date_from(
                    last_reviewed_at=incoming.last_reviewed_at,
                    interval_days=incoming.interval_days,
                ),
            ),
        )

    incoming_is_newer = _later(incoming.updated_at, stored.updated_at)
    described_by = incoming if incoming_is_newer else stored
    reviewed_by = (
        incoming
        if _later(incoming.last_reviewed_at, stored.last_reviewed_at)
        else stored
    )

    merged = replace(
        stored,
        lemma=described_by.lemma,
        surface_form=described_by.surface_form,
        part_of_speech=described_by.part_of_speech,
        target_form=described_by.target_form,
        example_utterance_id=described_by.example_utterance_id,
        is_flagged=described_by.is_flagged,
        deleted_at=described_by.deleted_at,
        interval_days=reviewed_by.interval_days,
        ease_factor=reviewed_by.ease_factor,
        repetition_count=reviewed_by.repetition_count,
        last_reviewed_at=reviewed_by.last_reviewed_at,
        updated_at=(incoming.updated_at if incoming_is_newer else stored.updated_at),
    )
    merged = replace(
        merged,
        due_at=due_date_from(
            last_reviewed_at=merged.last_reviewed_at,
            interval_days=merged.interval_days,
        ),
    )

    if merged == stored:
        return MergeResult(MergeOutcome.kept, stored)
    if described_by is incoming and reviewed_by is incoming:
        return MergeResult(MergeOutcome.replaced, merged)
    return MergeResult(MergeOutcome.merged, merged)


# --- Occurrences ------------------------------------------------------------


@dataclass(frozen=True)
class GlossaryOccurrenceSnapshot:
    id: str
    glossary_entry_id: str
    utterance_id: str
    surface_form: str
    updated_at: datetime
    deleted_at: datetime | None


def merge_glossary_occurrence(
    *,
    stored: GlossaryOccurrenceSnapshot | None,
    incoming: GlossaryOccurrenceSnapshot,
) -> MergeResult[GlossaryOccurrenceSnapshot]:
    """An occurrence is a fact: this word was in this sentence.

    Immutable except for two things that can change — a tombstone, when
    enrichment merges two entries and a duplicate sighting is dropped, and the
    entry it points at, when a lemma is re-keyed. Both follow `updated_at`.
    """
    if stored is None:
        return MergeResult(MergeOutcome.inserted, incoming)
    if not _later(incoming.updated_at, stored.updated_at):
        return MergeResult(MergeOutcome.kept, stored)
    return MergeResult(MergeOutcome.replaced, incoming)
