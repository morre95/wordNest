"""The delta-sync endpoint: one round trip, both directions."""

from fastapi import APIRouter

from ...core.dependencies import CurrentSessionDep, SessionDep, SyncServiceDep
from ...core.envelope import Failure, Success
from .schemas import SyncRequest, SyncResponse

router = APIRouter(prefix="/sync", tags=["sync"])


@router.post(
    "",
    response_model=Success[SyncResponse],
    summary="Push local changes and pull everything since a cursor",
    description=(
        "`cursor` is a monotonic server sequence number, not a timestamp: "
        "device clocks drift, and a client syncing in the same millisecond as "
        "a write would otherwise miss it. Rows are keyed by their "
        "client-generated ids, so a retried request after a dropped "
        "connection cannot duplicate anything. Both directions are paged; "
        "`has_more` means sync again straight away."
    ),
    responses={
        401: {"model": Failure, "description": "No usable session."},
        400: {"model": Failure, "description": "The batch is not valid."},
    },
)
async def sync(
    request: SyncRequest,
    current: CurrentSessionDep,
    service: SyncServiceDep,
    session: SessionDep,
) -> Success[SyncResponse]:
    result = await service.sync(
        request,
        account_id=current.account_id,
        device_id=current.device_id,
    )
    # One transaction for push and pull together: a half-applied batch must
    # never be committed, and the cursor must match what was actually stored.
    await session.commit()
    return Success(data=result)
