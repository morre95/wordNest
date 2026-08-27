"""Reading and updating the glossary over HTTP.

Every write here goes through the same two steps a sync push does: bump
`updated_at` and take a new `server_sequence`. Without the sequence the change
would be invisible to every other device — it would sit in the database with a
number below their cursors and never be pulled.
"""

from datetime import UTC, datetime

from sqlalchemy import Select, and_, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from ...core.db.models import (
    GlossaryEntry,
    ReviewLog,
    SequenceCounter,
    Utterance,
)
from ...core.errors import ValidationError, WordNestError
from .schemas import (
    GlossaryDifficulty,
    GlossaryEntryUpdate,
    GlossarySort,
    GlossaryStatisticsView,
)


class GlossaryEntryNotFoundError(WordNestError):
    status_code = 404
    code = "GLOSSARY_ENTRY_NOT_FOUND"


#: Below this ease factor a word counts as one the learner struggles with.
#: The same threshold the app uses, so the two agree about what "struggling"
#: means.
STRUGGLING_EASE_FACTOR = 2.0

#: Recalled this many times running counts as sticking.
LEARNED_REPETITIONS = 3


class GlossaryService:
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    def _now(self) -> datetime:
        return datetime.now(UTC)

    # --- Reading ------------------------------------------------------------

    def _base_query(
        self,
        *,
        account_id: str,
        search: str | None,
        language_pair: str | None,
        difficulty: GlossaryDifficulty,
    ) -> Select[tuple[GlossaryEntry]]:
        query = select(GlossaryEntry).where(
            GlossaryEntry.account_id == account_id,
            GlossaryEntry.deleted_at.is_(None),
        )

        if search:
            # Matches the source word, the form first heard, and the
            # target-language form, so a reader can find a word by whichever
            # side they remember.
            pattern = f"%{search.strip().lower()}%"
            query = query.where(
                or_(
                    func.lower(GlossaryEntry.lemma).like(pattern),
                    func.lower(GlossaryEntry.surface_form).like(pattern),
                    func.lower(GlossaryEntry.target_form).like(pattern),
                )
            )

        if language_pair:
            parts = language_pair.split("-")
            if len(parts) != 2:
                raise ValidationError(
                    "A language pair looks like 'en-es'.",
                    details={"language_pair": language_pair},
                )
            query = query.where(
                and_(
                    GlossaryEntry.source_language == parts[0],
                    GlossaryEntry.target_language == parts[1],
                )
            )

        match difficulty:
            case GlossaryDifficulty.struggling:
                query = query.where(
                    or_(
                        GlossaryEntry.is_flagged.is_(True),
                        GlossaryEntry.ease_factor < STRUGGLING_EASE_FACTOR,
                    )
                )
            case GlossaryDifficulty.due:
                query = query.where(
                    or_(
                        GlossaryEntry.due_at.is_(None),
                        GlossaryEntry.due_at <= self._now(),
                    )
                )
            case GlossaryDifficulty.all:
                pass

        return query

    async def list_entries(
        self,
        *,
        account_id: str,
        search: str | None = None,
        language_pair: str | None = None,
        difficulty: GlossaryDifficulty = GlossaryDifficulty.all,
        sort: GlossarySort = GlossarySort.recency,
        limit: int,
        offset: int,
    ) -> tuple[list[GlossaryEntry], int]:
        query = self._base_query(
            account_id=account_id,
            search=search,
            language_pair=language_pair,
            difficulty=difficulty,
        )

        total = (
            await self._session.execute(
                select(func.count()).select_from(query.subquery())
            )
        ).scalar_one()

        ordering = {
            GlossarySort.recency: (GlossaryEntry.updated_at.desc(),),
            GlossarySort.alphabetical: (GlossaryEntry.lemma.asc(),),
            # Flagged first, then least well known, then most often stumbled
            # over — the same order the app's "hardest first" offers.
            GlossarySort.struggle: (
                GlossaryEntry.is_flagged.desc(),
                GlossaryEntry.ease_factor.asc(),
                GlossaryEntry.seen_count.desc(),
            ),
        }[sort]

        rows = (
            await self._session.execute(
                query.order_by(*ordering, GlossaryEntry.id.asc())
                .limit(limit)
                .offset(offset)
            )
        ).scalars()
        return list(rows), total

    async def get_entry(self, *, account_id: str, entry_id: str) -> GlossaryEntry:
        entry = await self._session.get(GlossaryEntry, entry_id)
        # A tombstoned entry reads as gone, and one belonging to another account
        # must be indistinguishable from one that does not exist.
        if (
            entry is None
            or entry.account_id != account_id
            or entry.deleted_at is not None
        ):
            raise GlossaryEntryNotFoundError("No such word in this glossary.")
        return entry

    # --- Writing ------------------------------------------------------------

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

    async def update_entry(
        self,
        *,
        account_id: str,
        entry_id: str,
        update: GlossaryEntryUpdate,
        device_id: str,
    ) -> GlossaryEntry:
        entry = await self.get_entry(account_id=account_id, entry_id=entry_id)

        if entry.is_flagged == update.is_flagged:
            # Nothing changed. Writing anyway would burn a sequence number and
            # wake every other device for a change that is not one.
            return entry

        entry.is_flagged = update.is_flagged
        entry.updated_at = self._now()
        entry.origin_device_id = device_id
        entry.server_sequence = await self._next_sequence(account_id)
        await self._session.flush()
        return entry

    async def delete_entry(
        self, *, account_id: str, entry_id: str, device_id: str
    ) -> None:
        """Tombstones the entry, so the deletion reaches the other devices."""
        entry = await self.get_entry(account_id=account_id, entry_id=entry_id)
        now = self._now()
        entry.deleted_at = now
        entry.updated_at = now
        entry.origin_device_id = device_id
        entry.server_sequence = await self._next_sequence(account_id)
        await self._session.flush()

    # --- Statistics ---------------------------------------------------------

    async def statistics(self, *, account_id: str) -> GlossaryStatisticsView:
        entries = list(
            (
                await self._session.execute(
                    select(GlossaryEntry).where(
                        GlossaryEntry.account_id == account_id,
                        GlossaryEntry.deleted_at.is_(None),
                    )
                )
            ).scalars()
        )
        now = self._now()

        utterance_count = (
            await self._session.execute(
                select(func.count(Utterance.id)).where(
                    Utterance.account_id == account_id,
                    Utterance.deleted_at.is_(None),
                )
            )
        ).scalar_one()

        review_count = (
            await self._session.execute(
                select(func.count(ReviewLog.id)).where(
                    ReviewLog.account_id == account_id
                )
            )
        ).scalar_one()

        spoken = (
            await self._session.execute(
                select(
                    func.min(Utterance.spoken_at), func.max(Utterance.spoken_at)
                ).where(
                    Utterance.account_id == account_id,
                    Utterance.deleted_at.is_(None),
                )
            )
        ).one()

        return GlossaryStatisticsView(
            word_count=len(entries),
            utterance_count=utterance_count,
            review_count=review_count,
            due_count=sum(
                1
                for entry in entries
                if entry.due_at is None or _as_utc(entry.due_at) <= now
            ),
            struggling_count=sum(
                1
                for entry in entries
                if entry.is_flagged or entry.ease_factor < STRUGGLING_EASE_FACTOR
            ),
            learned_count=sum(
                1 for entry in entries if entry.repetition_count >= LEARNED_REPETITIONS
            ),
            language_pairs=sorted(
                {
                    f"{entry.source_language}-{entry.target_language}"
                    for entry in entries
                }
            ),
            first_spoken_at=spoken[0],
            last_spoken_at=spoken[1],
        )


def _as_utc(moment: datetime) -> datetime:
    """SQLite hands back naive datetimes; Postgres hands back aware ones."""
    return moment if moment.tzinfo else moment.replace(tzinfo=UTC)
