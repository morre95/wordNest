"""Read and update models for the glossary.

The app itself never calls these — it is local-first and reads from its own
database. They exist for a client that does not speak the sync protocol: an
export tool, a web view, anything without an on-device store.
"""

from datetime import datetime
from enum import StrEnum
from typing import Annotated

from pydantic import BaseModel, Field

from ..sync.schemas import UtcDatetime

#: Default and ceiling for every list endpoint. No unbounded result sets.
DEFAULT_PAGE_SIZE = 20
MAX_PAGE_SIZE = 100

PageLimit = Annotated[int, Field(default=DEFAULT_PAGE_SIZE, ge=1, le=MAX_PAGE_SIZE)]


class GlossarySort(StrEnum):
    """Matches the orders the app's own glossary screen offers."""

    recency = "recency"
    struggle = "struggle"
    alphabetical = "alphabetical"


class GlossaryDifficulty(StrEnum):
    all = "all"

    #: Flagged by the user, or performing badly under review.
    struggling = "struggling"

    #: Due or overdue.
    due = "due"


class GlossaryEntryView(BaseModel):
    """One word, as a reader sees it.

    Everything here is derived from the row; nothing is writable through this
    model. Updates go through [GlossaryEntryUpdate], which names its fields
    explicitly so a request body cannot reach a column it has no business
    setting.
    """

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
    due_at: UtcDatetime | None
    last_reviewed_at: UtcDatetime | None
    updated_at: UtcDatetime


class GlossaryEntryUpdate(BaseModel):
    """The only field a client may set directly.

    Scheduling state is not here on purpose: it is a consequence of a review,
    not something to be typed in, and letting it be set directly would let a
    client write a schedule the algorithm never produced. Record a review
    instead — `POST /review-logs`.
    """

    is_flagged: bool


class Pagination(BaseModel):
    """Offset paging, because this is a searchable, sortable, bounded list.

    The review log uses a cursor instead: it is an append-only timeline, where
    an offset would shift underneath a reader as new rows arrive.
    """

    total: int
    limit: int
    offset: int
    has_more: bool


class GlossaryPage(BaseModel):
    entries: list[GlossaryEntryView]


class GlossaryStatisticsView(BaseModel):
    word_count: int
    utterance_count: int
    review_count: int
    due_count: int
    struggling_count: int
    learned_count: int
    language_pairs: list[str]
    first_spoken_at: datetime | None
    last_spoken_at: datetime | None
