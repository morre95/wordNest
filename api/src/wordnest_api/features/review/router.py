"""The review-log endpoint."""

from typing import Annotated

from fastapi import APIRouter, Depends, Query, status

from ...core.dependencies import CurrentSessionDep, SessionDep
from ...core.envelope import Failure, Success
from .schemas import (
    DEFAULT_PAGE_SIZE,
    MAX_PAGE_SIZE,
    RecordedReview,
    ReviewLogCreate,
    ReviewLogPage,
    ReviewLogView,
)
from .service import ReviewService

router = APIRouter(prefix="/review-logs", tags=["review"])

_UNAUTHORIZED = {401: {"model": Failure, "description": "No usable session."}}


def get_review_service(session: SessionDep) -> ReviewService:
    return ReviewService(session)


ReviewServiceDep = Annotated[ReviewService, Depends(get_review_service)]


@router.get(
    "",
    response_model=Success[ReviewLogPage],
    summary="Reviews recorded on this account",
    description=(
        "Cursor paged on the server sequence, because this is an append-only "
        "timeline: rows arrive while a reader is paging, and an offset would "
        "shift underneath them."
    ),
    responses=_UNAUTHORIZED,
)
async def list_reviews(
    current: CurrentSessionDep,
    service: ReviewServiceDep,
    glossary_entry_id: Annotated[str | None, Query(max_length=64)] = None,
    cursor: Annotated[int, Query(ge=0)] = 0,
    limit: Annotated[int, Query(ge=1, le=MAX_PAGE_SIZE)] = DEFAULT_PAGE_SIZE,
) -> Success[ReviewLogPage]:
    reviews, next_cursor, has_more = await service.list_reviews(
        account_id=current.account_id,
        glossary_entry_id=glossary_entry_id,
        cursor=cursor,
        limit=limit,
    )
    return Success(
        data=ReviewLogPage(
            reviews=[
                ReviewLogView.model_validate(review, from_attributes=True)
                for review in reviews
            ]
        ),
        meta={"pagination": {"cursor": next_cursor, "has_more": has_more}},
    )


@router.post(
    "",
    status_code=status.HTTP_201_CREATED,
    response_model=Success[RecordedReview],
    summary="Record a review and move the word's schedule on",
    description=(
        "Idempotent on the client-generated id: a retry after a dropped "
        "connection lands on the row already there rather than counting the "
        "review twice. A review that is older than one already applied is "
        "kept as an event but does not move the schedule backwards."
    ),
    responses={
        **_UNAUTHORIZED,
        404: {
            "model": Failure,
            "description": "That word is not in this glossary.",
        },
    },
)
async def record_review(
    review: ReviewLogCreate,
    current: CurrentSessionDep,
    service: ReviewServiceDep,
    session: SessionDep,
) -> Success[RecordedReview]:
    log, entry, applied = await service.record(
        review,
        account_id=current.account_id,
        device_id=current.device_id,
    )
    await session.commit()
    return Success(
        data=RecordedReview(
            review=ReviewLogView.model_validate(log, from_attributes=True),
            applied=applied,
            entry_interval_days=entry.interval_days,
            entry_ease_factor=entry.ease_factor,
            entry_due_at=entry.due_at,
        )
    )
