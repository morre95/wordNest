"""Delta sync: apply what a device pushed, return what it has not seen.

Both halves happen in one transaction, and the cursor the client gets back is
the highest sequence number in the page it was handed — never "now" — so a
write landing mid-request is picked up next time rather than skipped.
"""

import logging
from collections.abc import Sequence
from datetime import UTC, datetime

from sqlalchemy import func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from ...core.config import Settings
from ...core.db.models import (
    GlossaryEntry,
    GlossaryOccurrence,
    ReviewLog,
    SequenceCounter,
    Utterance,
)
from . import merge as rules
from .schemas import (
    ChangeSet,
    GlossaryEntryPayload,
    GlossaryOccurrencePayload,
    ReviewLogPayload,
    SyncRejection,
    SyncRequest,
    SyncResponse,
    UtterancePayload,
)

logger = logging.getLogger(__name__)


def _utc(moment: datetime | None) -> datetime | None:
    if moment is None:
        return None
    return moment if moment.tzinfo else moment.replace(tzinfo=UTC)


class SyncService:
    def __init__(self, session: AsyncSession, settings: Settings) -> None:
        self._session = session
        self._limit = settings.sync_batch_limit

    async def sync(
        self, request: SyncRequest, *, account_id: str, device_id: str
    ) -> SyncResponse:
        applied, rejected = await self._apply_push(
            request.changes, account_id=account_id, device_id=device_id
        )
        changes, cursor, has_more = await self._pull(
            account_id=account_id, cursor=request.cursor
        )
        return SyncResponse(
            changes=changes,
            cursor=cursor,
            has_more=has_more,
            applied=applied,
            rejected=rejected,
        )

    # --- Push ---------------------------------------------------------------

    async def _next_sequence(self, account_id: str) -> int:
        """Takes the next number, holding a row lock so two devices syncing at
        once cannot be handed the same one."""
        counter = await self._session.get(
            SequenceCounter, account_id, with_for_update=True
        )
        if counter is None:
            counter = SequenceCounter(account_id=account_id, value=0)
            self._session.add(counter)
            await self._session.flush()
        counter.value += 1
        return counter.value

    async def _apply_push(
        self, changes: ChangeSet, *, account_id: str, device_id: str
    ) -> tuple[int, list[SyncRejection]]:
        applied = 0
        rejected: list[SyncRejection] = []

        # Order matters: an occurrence points at an entry and an utterance, and
        # a review log points at an entry. Applying parents first means a
        # single batch is internally consistent.
        applied += await self._push_utterances(
            changes.utterances, account_id, device_id, rejected
        )
        applied += await self._push_glossary_entries(
            changes.glossary_entries, account_id, device_id
        )
        applied += await self._push_occurrences(
            changes.glossary_occurrences, account_id, device_id
        )
        applied += await self._push_review_logs(
            changes.review_logs, account_id, device_id
        )

        # Counts are derived, so they are recomputed once at the end rather
        # than after every row.
        touched = {
            *(entry.id for entry in changes.glossary_entries),
            *(
                occurrence.glossary_entry_id
                for occurrence in changes.glossary_occurrences
            ),
        }
        for entry_id in touched:
            await self._recompute_seen_count(account_id, entry_id)

        return applied, rejected

    async def _push_utterances(
        self,
        payloads: Sequence[UtterancePayload],
        account_id: str,
        device_id: str,
        rejected: list[SyncRejection],
    ) -> int:
        applied = 0
        for payload in payloads:
            stored = await self._get(Utterance, account_id, payload.id)
            snapshot = rules.UtteranceSnapshot(
                id=payload.id,
                origin_device_id=device_id,
                updated_at=payload.updated_at,
                deleted_at=payload.deleted_at,
                source_text=payload.source_text,
                translation_text=payload.translation_text,
                literal_gloss=payload.literal_gloss,
                enrichment_state=payload.enrichment_state,
                is_flagged=payload.is_flagged,
            )
            result = rules.merge_utterance(
                stored=None
                if stored is None
                else rules.UtteranceSnapshot(
                    id=stored.id,
                    origin_device_id=stored.origin_device_id,
                    updated_at=_utc(stored.updated_at),  # type: ignore[arg-type]
                    deleted_at=_utc(stored.deleted_at),
                    source_text=stored.source_text,
                    translation_text=stored.translation_text,
                    literal_gloss=stored.literal_gloss,
                    enrichment_state=stored.enrichment_state,
                    is_flagged=stored.is_flagged,
                ),
                incoming=snapshot,
                writing_device_id=device_id,
            )

            if result.outcome is rules.MergeOutcome.rejected:
                rejected.append(
                    SyncRejection(
                        id=payload.id,
                        table="utterances",
                        code="NOT_YOUR_UTTERANCE",
                        message=(
                            "An utterance can only be changed by the device "
                            "that recorded it."
                        ),
                    )
                )
                continue
            if not result.should_write:
                continue

            row = stored or Utterance(id=payload.id, account_id=account_id)
            row.source_text = result.value.source_text
            row.translation_text = result.value.translation_text
            row.literal_gloss = result.value.literal_gloss
            row.source_language = payload.source_language
            row.target_language = payload.target_language
            row.spoken_at = payload.spoken_at
            row.enrichment_state = result.value.enrichment_state
            row.is_flagged = result.value.is_flagged
            row.updated_at = result.value.updated_at
            row.deleted_at = result.value.deleted_at
            row.origin_device_id = device_id
            row.server_sequence = await self._next_sequence(account_id)
            self._session.add(row)
            applied += 1
        await self._session.flush()
        return applied

    async def _push_glossary_entries(
        self,
        payloads: Sequence[GlossaryEntryPayload],
        account_id: str,
        device_id: str,
    ) -> int:
        applied = 0
        for payload in payloads:
            # A glossary entry is identified by its id, but two devices that
            # learned the same word offline generated different ids for it. The
            # word itself is the real key, so fall back to that.
            stored = await self._get(
                GlossaryEntry, account_id, payload.id
            ) or await self._get_entry_by_word(account_id, payload)

            incoming = rules.GlossaryEntrySnapshot(
                id=payload.id,
                lemma=payload.lemma,
                surface_form=payload.surface_form,
                part_of_speech=payload.part_of_speech,
                target_form=payload.target_form,
                source_language=payload.source_language,
                target_language=payload.target_language,
                seen_count=payload.seen_count,
                example_utterance_id=payload.example_utterance_id,
                is_flagged=payload.is_flagged,
                interval_days=payload.interval_days,
                ease_factor=payload.ease_factor,
                repetition_count=payload.repetition_count,
                due_at=payload.due_at,
                last_reviewed_at=payload.last_reviewed_at,
                updated_at=payload.updated_at,
                deleted_at=payload.deleted_at,
            )
            result = rules.merge_glossary_entry(
                stored=None if stored is None else self._entry_snapshot(stored),
                incoming=incoming,
            )
            if not result.should_write:
                continue

            row = stored or GlossaryEntry(id=payload.id, account_id=account_id)
            merged = result.value
            row.lemma = merged.lemma
            row.surface_form = merged.surface_form
            row.part_of_speech = merged.part_of_speech
            row.target_form = merged.target_form
            row.source_language = merged.source_language
            row.target_language = merged.target_language
            row.example_utterance_id = merged.example_utterance_id
            row.is_flagged = merged.is_flagged
            row.interval_days = merged.interval_days
            row.ease_factor = merged.ease_factor
            row.repetition_count = merged.repetition_count
            row.due_at = merged.due_at
            row.last_reviewed_at = merged.last_reviewed_at
            row.updated_at = merged.updated_at
            row.deleted_at = merged.deleted_at
            row.origin_device_id = device_id
            row.server_sequence = await self._next_sequence(account_id)
            self._session.add(row)
            applied += 1
        await self._session.flush()
        return applied

    async def _push_occurrences(
        self,
        payloads: Sequence[GlossaryOccurrencePayload],
        account_id: str,
        device_id: str,
    ) -> int:
        applied = 0
        for payload in payloads:
            stored = await self._get(
                GlossaryOccurrence, account_id, payload.id
            ) or await self._get_occurrence_by_sighting(account_id, payload)

            result = rules.merge_glossary_occurrence(
                stored=None
                if stored is None
                else rules.GlossaryOccurrenceSnapshot(
                    id=stored.id,
                    glossary_entry_id=stored.glossary_entry_id,
                    utterance_id=stored.utterance_id,
                    surface_form=stored.surface_form,
                    updated_at=_utc(stored.updated_at),  # type: ignore[arg-type]
                    deleted_at=_utc(stored.deleted_at),
                ),
                incoming=rules.GlossaryOccurrenceSnapshot(
                    id=payload.id,
                    glossary_entry_id=payload.glossary_entry_id,
                    utterance_id=payload.utterance_id,
                    surface_form=payload.surface_form,
                    updated_at=payload.updated_at,
                    deleted_at=payload.deleted_at,
                ),
            )
            if not result.should_write:
                continue

            row = stored or GlossaryOccurrence(id=payload.id, account_id=account_id)
            row.glossary_entry_id = result.value.glossary_entry_id
            row.utterance_id = result.value.utterance_id
            row.surface_form = result.value.surface_form
            row.updated_at = result.value.updated_at
            row.deleted_at = result.value.deleted_at
            row.origin_device_id = device_id
            row.server_sequence = await self._next_sequence(account_id)
            self._session.add(row)
            applied += 1
        await self._session.flush()
        return applied

    async def _push_review_logs(
        self,
        payloads: Sequence[ReviewLogPayload],
        account_id: str,
        device_id: str,
    ) -> int:
        applied = 0
        for payload in payloads:
            stored = await self._get(ReviewLog, account_id, payload.id)
            if stored is not None:
                # An event never changes after the fact; a retried push is a
                # no-op rather than a second review.
                continue

            self._session.add(
                ReviewLog(
                    id=payload.id,
                    account_id=account_id,
                    glossary_entry_id=payload.glossary_entry_id,
                    reviewed_at=payload.reviewed_at,
                    grade=payload.grade,
                    scheduled_interval_days=payload.scheduled_interval_days,
                    scheduled_ease_factor=payload.scheduled_ease_factor,
                    updated_at=payload.updated_at,
                    deleted_at=payload.deleted_at,
                    origin_device_id=device_id,
                    server_sequence=await self._next_sequence(account_id),
                )
            )
            applied += 1
        await self._session.flush()
        return applied

    async def _recompute_seen_count(self, account_id: str, entry_id: str) -> None:
        """Counts the live sightings, rather than trusting either device's
        number. This is what makes two offline devices converge on the total."""
        total = (
            await self._session.execute(
                select(func.count(GlossaryOccurrence.id)).where(
                    GlossaryOccurrence.account_id == account_id,
                    GlossaryOccurrence.glossary_entry_id == entry_id,
                    GlossaryOccurrence.deleted_at.is_(None),
                )
            )
        ).scalar_one()
        entry = await self._get(GlossaryEntry, account_id, entry_id)
        if entry is not None:
            entry.seen_count = total

    # --- Pull ---------------------------------------------------------------

    async def _pull(
        self, *, account_id: str, cursor: int
    ) -> tuple[ChangeSet, int, bool]:
        """Returns everything above `cursor`, oldest first, capped at one page.

        The returned cursor is the highest sequence actually included, so a row
        written while this request was running is picked up next time instead of
        being stepped over.
        """
        changes = ChangeSet()
        highest = cursor
        remaining = self._limit

        for table, collect in (
            (Utterance, self._collect_utterances),
            (GlossaryEntry, self._collect_entries),
            (GlossaryOccurrence, self._collect_occurrences),
            (ReviewLog, self._collect_review_logs),
        ):
            if remaining <= 0:
                break
            rows = (
                await self._session.execute(
                    select(table)
                    .where(
                        table.account_id == account_id,
                        table.server_sequence > cursor,
                    )
                    .order_by(table.server_sequence)
                    .limit(remaining)
                )
            ).scalars()
            rows = list(rows)
            remaining -= len(rows)
            for row in rows:
                highest = max(highest, row.server_sequence)
            collect(changes, rows)

        has_more = await self._has_more_after(account_id, highest)
        return changes, highest, has_more

    async def _has_more_after(self, account_id: str, cursor: int) -> bool:
        for table in (Utterance, GlossaryEntry, GlossaryOccurrence, ReviewLog):
            exists = (
                await self._session.execute(
                    select(table.id)
                    .where(
                        table.account_id == account_id,
                        table.server_sequence > cursor,
                    )
                    .limit(1)
                )
            ).first()
            if exists is not None:
                return True
        return False

    @staticmethod
    def _collect_utterances(changes: ChangeSet, rows: Sequence[Utterance]) -> None:
        changes.utterances = [
            UtterancePayload(
                id=row.id,
                updated_at=row.updated_at,
                deleted_at=row.deleted_at,
                source_text=row.source_text,
                translation_text=row.translation_text,
                literal_gloss=row.literal_gloss,
                source_language=row.source_language,
                target_language=row.target_language,
                spoken_at=row.spoken_at,
                enrichment_state=row.enrichment_state,
                is_flagged=row.is_flagged,
            )
            for row in rows
        ]

    @staticmethod
    def _collect_entries(changes: ChangeSet, rows: Sequence[GlossaryEntry]) -> None:
        changes.glossary_entries = [
            GlossaryEntryPayload(
                id=row.id,
                updated_at=row.updated_at,
                deleted_at=row.deleted_at,
                lemma=row.lemma,
                surface_form=row.surface_form,
                part_of_speech=row.part_of_speech,
                target_form=row.target_form,
                source_language=row.source_language,
                target_language=row.target_language,
                seen_count=row.seen_count,
                example_utterance_id=row.example_utterance_id,
                is_flagged=row.is_flagged,
                interval_days=row.interval_days,
                ease_factor=row.ease_factor,
                repetition_count=row.repetition_count,
                due_at=row.due_at,
                last_reviewed_at=row.last_reviewed_at,
            )
            for row in rows
        ]

    @staticmethod
    def _collect_occurrences(
        changes: ChangeSet, rows: Sequence[GlossaryOccurrence]
    ) -> None:
        changes.glossary_occurrences = [
            GlossaryOccurrencePayload(
                id=row.id,
                updated_at=row.updated_at,
                deleted_at=row.deleted_at,
                glossary_entry_id=row.glossary_entry_id,
                utterance_id=row.utterance_id,
                surface_form=row.surface_form,
            )
            for row in rows
        ]

    @staticmethod
    def _collect_review_logs(changes: ChangeSet, rows: Sequence[ReviewLog]) -> None:
        changes.review_logs = [
            ReviewLogPayload(
                id=row.id,
                updated_at=row.updated_at,
                deleted_at=row.deleted_at,
                glossary_entry_id=row.glossary_entry_id,
                reviewed_at=row.reviewed_at,
                grade=row.grade,
                scheduled_interval_days=row.scheduled_interval_days,
                scheduled_ease_factor=row.scheduled_ease_factor,
            )
            for row in rows
        ]

    # --- Lookups ------------------------------------------------------------

    async def _get(self, table: type, account_id: str, row_id: str):
        row = await self._session.get(table, row_id)
        # An id from another account is not ours to touch, and must read as
        # absent rather than as somebody else's row.
        if row is not None and row.account_id != account_id:
            return None
        return row

    async def _get_entry_by_word(
        self, account_id: str, payload: GlossaryEntryPayload
    ) -> GlossaryEntry | None:
        return (
            await self._session.execute(
                select(GlossaryEntry).where(
                    GlossaryEntry.account_id == account_id,
                    GlossaryEntry.lemma == payload.lemma,
                    GlossaryEntry.source_language == payload.source_language,
                    GlossaryEntry.target_language == payload.target_language,
                )
            )
        ).scalar_one_or_none()

    async def _get_occurrence_by_sighting(
        self, account_id: str, payload: GlossaryOccurrencePayload
    ) -> GlossaryOccurrence | None:
        return (
            (
                await self._session.execute(
                    select(GlossaryOccurrence).where(
                        GlossaryOccurrence.account_id == account_id,
                        or_(
                            GlossaryOccurrence.id == payload.id,
                            (
                                GlossaryOccurrence.glossary_entry_id
                                == payload.glossary_entry_id
                            )
                            & (GlossaryOccurrence.utterance_id == payload.utterance_id),
                        ),
                    )
                )
            )
            .scalars()
            .first()
        )

    @staticmethod
    def _entry_snapshot(row: GlossaryEntry) -> rules.GlossaryEntrySnapshot:
        return rules.GlossaryEntrySnapshot(
            id=row.id,
            lemma=row.lemma,
            surface_form=row.surface_form,
            part_of_speech=row.part_of_speech,
            target_form=row.target_form,
            source_language=row.source_language,
            target_language=row.target_language,
            seen_count=row.seen_count,
            example_utterance_id=row.example_utterance_id,
            is_flagged=row.is_flagged,
            interval_days=row.interval_days,
            ease_factor=row.ease_factor,
            repetition_count=row.repetition_count,
            due_at=_utc(row.due_at),
            last_reviewed_at=_utc(row.last_reviewed_at),
            updated_at=_utc(row.updated_at),  # type: ignore[arg-type]
            deleted_at=_utc(row.deleted_at),
        )
