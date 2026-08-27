"""Glossary read and update endpoints.

The app does not use these — it reads its own local database. They are for a
client without an on-device store, and for exporting. Every write is visible to
sync, because it takes a sequence number like any other change.
"""

from typing import Annotated

from fastapi import APIRouter, Depends, Query, status

from ...core.dependencies import CurrentSessionDep, SessionDep
from ...core.envelope import Failure, Success
from .schemas import (
    DEFAULT_PAGE_SIZE,
    MAX_PAGE_SIZE,
    GlossaryDifficulty,
    GlossaryEntryUpdate,
    GlossaryEntryView,
    GlossaryPage,
    GlossarySort,
    GlossaryStatisticsView,
)
from .service import GlossaryService

router = APIRouter(prefix="/glossary", tags=["glossary"])

_UNAUTHORIZED = {401: {"model": Failure, "description": "No usable session."}}
_NOT_FOUND = {404: {"model": Failure, "description": "No such word in this glossary."}}


def get_glossary_service(session: SessionDep) -> GlossaryService:
    return GlossaryService(session)


GlossaryServiceDep = Annotated[GlossaryService, Depends(get_glossary_service)]


@router.get(
    "",
    response_model=Success[GlossaryPage],
    summary="The words on this account",
    description=(
        "Offset paged, because this is a searchable, sortable, bounded list. "
        "`search` matches the source word, the form first heard and the "
        "target-language form, so a word can be found from either side."
    ),
    responses=_UNAUTHORIZED,
)
async def list_glossary(
    current: CurrentSessionDep,
    service: GlossaryServiceDep,
    search: Annotated[str | None, Query(max_length=160)] = None,
    language_pair: Annotated[
        str | None,
        Query(max_length=17, pattern=r"^[a-zA-Z-]+$", examples=["en-es"]),
    ] = None,
    difficulty: GlossaryDifficulty = GlossaryDifficulty.all,
    sort: GlossarySort = GlossarySort.recency,
    limit: Annotated[int, Query(ge=1, le=MAX_PAGE_SIZE)] = DEFAULT_PAGE_SIZE,
    offset: Annotated[int, Query(ge=0)] = 0,
) -> Success[GlossaryPage]:
    entries, total = await service.list_entries(
        account_id=current.account_id,
        search=search,
        language_pair=language_pair,
        difficulty=difficulty,
        sort=sort,
        limit=limit,
        offset=offset,
    )
    return Success(
        data=GlossaryPage(
            entries=[
                GlossaryEntryView.model_validate(entry, from_attributes=True)
                for entry in entries
            ]
        ),
        meta={
            "pagination": {
                "total": total,
                "limit": limit,
                "offset": offset,
                "has_more": offset + len(entries) < total,
            }
        },
    )


@router.get(
    "/statistics",
    response_model=Success[GlossaryStatisticsView],
    summary="What this glossary looks like as a whole",
    responses=_UNAUTHORIZED,
)
async def glossary_statistics(
    current: CurrentSessionDep,
    service: GlossaryServiceDep,
) -> Success[GlossaryStatisticsView]:
    return Success(data=await service.statistics(account_id=current.account_id))


@router.get(
    "/{entry_id}",
    response_model=Success[GlossaryEntryView],
    summary="One word",
    responses={**_UNAUTHORIZED, **_NOT_FOUND},
)
async def get_glossary_entry(
    entry_id: str,
    current: CurrentSessionDep,
    service: GlossaryServiceDep,
) -> Success[GlossaryEntryView]:
    entry = await service.get_entry(account_id=current.account_id, entry_id=entry_id)
    return Success(data=GlossaryEntryView.model_validate(entry, from_attributes=True))


@router.patch(
    "/{entry_id}",
    response_model=Success[GlossaryEntryView],
    summary="Mark a word as difficult, or unmark it",
    description=(
        "Only the user's own difficulty flag is writable. Scheduling state is "
        "a consequence of a review, not something to be set directly — record "
        "a review instead."
    ),
    responses={**_UNAUTHORIZED, **_NOT_FOUND},
)
async def update_glossary_entry(
    entry_id: str,
    update: GlossaryEntryUpdate,
    current: CurrentSessionDep,
    service: GlossaryServiceDep,
    session: SessionDep,
) -> Success[GlossaryEntryView]:
    entry = await service.update_entry(
        account_id=current.account_id,
        entry_id=entry_id,
        update=update,
        device_id=current.device_id,
    )
    await session.commit()
    return Success(data=GlossaryEntryView.model_validate(entry, from_attributes=True))


@router.delete(
    "/{entry_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    summary="Remove a word",
    description=(
        "Leaves a tombstone rather than deleting the row, so the removal "
        "reaches the other devices instead of being undone by their next pull."
    ),
    responses={**_UNAUTHORIZED, **_NOT_FOUND},
)
async def delete_glossary_entry(
    entry_id: str,
    current: CurrentSessionDep,
    service: GlossaryServiceDep,
    session: SessionDep,
) -> None:
    await service.delete_entry(
        account_id=current.account_id,
        entry_id=entry_id,
        device_id=current.device_id,
    )
    await session.commit()
