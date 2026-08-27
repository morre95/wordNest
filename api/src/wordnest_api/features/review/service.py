"""Reviews over HTTP.

A review is two things: an immutable event, and a change to a word's schedule.
Both happen here, in one transaction, under exactly the rules `features/sync`
applies — so a review recorded through this endpoint and one pushed through
sync leave the account in the same state.
"""

from datetime import UTC, datetime

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ...core.db.models import GlossaryEntry, ReviewLog, SequenceCounter
from ...core.errors import WordNestError
from ..glossary.service import GlossaryEntryNotFoundError
from ..sync.merge import due_date_from
from .schemas import ReviewLogCreate


class ReviewNotAllowedError(WordNestError):
    status_code = 422
    code = "REVIEW_NOT_ALLOWED"


class ReviewService:
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    def _now(self) -> datetime:
        return datetime.now(UTC)

    async def _next_sequence(self, account_id: str) -> int:
        counter = await self._session.get(
            SequenceCounter, account_id, with_for_update=True
        )
        if counter is None:
            counter = SequenceCounter(account_id=account_id, value=0)
            self._session.add(counter)
            await self._session.flush()
        counter.value += 1
        return counter.value

    async def list_reviews(
        self,
        *,
        account_id: str,
        glossary_entry_id: str | None,
        cursor: int,
        limit: int,
    ) -> tuple[list[ReviewLog], int, bool]:
        """Cursor paged on the server sequence.

        A cursor rather than an offset because this is an append-only timeline:
        rows arrive while a reader is paging through it, and an offset would
        shift underneath them and skip or repeat a row.
        """
        query = select(ReviewLog).where(
            ReviewLog.account_id == account_id,
            ReviewLog.server_sequence > cursor,
        )
        if glossary_entry_id is not None:
            query = query.where(ReviewLog.glossary_entry_id == glossary_entry_id)

        rows = list(
            (
                await self._session.execute(
                    query.order_by(ReviewLog.server_sequence).limit(limit + 1)
                )
            ).scalars()
        )
        has_more = len(rows) > limit
        rows = rows[:limit]
        next_cursor = rows[-1].server_sequence if rows else cursor
        return rows, next_cursor, has_more

    async def record(
        self, review: ReviewLogCreate, *, account_id: str, device_id: str
    ) -> tuple[ReviewLog, GlossaryEntry, bool]:
        entry = await self._session.get(GlossaryEntry, review.glossary_entry_id)
        if (
            entry is None
            or entry.account_id != account_id
            or entry.deleted_at is not None
        ):
            raise GlossaryEntryNotFoundError("That word is not in this glossary.")

        existing = await self._session.get(ReviewLog, review.id)
        if existing is not None:
            if existing.account_id != account_id:
                raise ReviewNotAllowedError("That review id is already taken.")
            # An event never changes after the fact. A retry is a no-op, not a
            # second review.
            return existing, entry, False

        now = self._now()
        log = ReviewLog(
            id=review.id,
            account_id=account_id,
            glossary_entry_id=review.glossary_entry_id,
            reviewed_at=review.reviewed_at,
            grade=review.grade,
            scheduled_interval_days=review.scheduled_interval_days,
            scheduled_ease_factor=review.scheduled_ease_factor,
            updated_at=now,
            origin_device_id=device_id,
            server_sequence=await self._next_sequence(account_id),
        )
        self._session.add(log)

        applied = await self._apply_schedule(
            entry,
            review=review,
            account_id=account_id,
            device_id=device_id,
            now=now,
        )
        await self._session.flush()
        return log, entry, applied

    async def _apply_schedule(
        self,
        entry: GlossaryEntry,
        *,
        review: ReviewLogCreate,
        account_id: str,
        device_id: str,
        now: datetime,
    ) -> bool:
        """Moves the entry's schedule on, unless a later review already did.

        The same rule the merge module applies: the side that reviewed most
        recently wins, and the due date is recomputed from the winning state so
        a stale one cannot resurface a word already scheduled out. A review
        arriving late from a device that was offline must not undo a newer one.
        """
        reviewed_at = _as_utc(review.reviewed_at)
        last = _as_utc(entry.last_reviewed_at)
        if last is not None and reviewed_at <= last:
            return False

        entry.interval_days = review.scheduled_interval_days
        entry.ease_factor = review.scheduled_ease_factor
        # A lapse restarts the count; anything else advances it. Derived here
        # rather than sent, so a client cannot claim a streak it did not earn.
        entry.repetition_count = 0 if review.grade < 3 else entry.repetition_count + 1
        entry.last_reviewed_at = reviewed_at
        entry.due_at = due_date_from(
            last_reviewed_at=reviewed_at,
            interval_days=review.scheduled_interval_days,
        )
        entry.updated_at = now
        entry.origin_device_id = device_id
        entry.server_sequence = await self._next_sequence(account_id)
        return True


def _as_utc(moment: datetime | None) -> datetime | None:
    if moment is None:
        return None
    return moment if moment.tzinfo else moment.replace(tzinfo=UTC)
