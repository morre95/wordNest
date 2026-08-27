"""Identity endpoints.

Registration and the two redeem paths are the only ones that do not require an
access token — everything else does, because everything else acts on an account.
"""

from fastapi import APIRouter, status

from ...core.dependencies import (
    AuthServiceDep,
    CurrentSessionDep,
    PairingRateLimiterDep,
    SessionDep,
)
from ...core.envelope import Failure, Success
from .schemas import (
    DeviceList,
    DeviceRegistrationRequest,
    DeviceSummary,
    MagicLinkRequest,
    MagicLinkSent,
    PairingCodeResponse,
    RedeemMagicLinkRequest,
    RedeemPairingCodeRequest,
    RefreshRequest,
    TokenPair,
)

router = APIRouter(prefix="/auth", tags=["auth"])

_UNAUTHORIZED = {401: {"model": Failure, "description": "No usable session."}}


@router.post(
    "/devices",
    status_code=status.HTTP_201_CREATED,
    response_model=Success[TokenPair],
    summary="Register this install and get a session",
    description=(
        "Called silently on first launch. Creates an anonymous account, so "
        "sync and backup work immediately with no email and no password. "
        "Idempotent on `device_id`."
    ),
)
async def register_device(
    request: DeviceRegistrationRequest,
    auth: AuthServiceDep,
    session: SessionDep,
) -> Success[TokenPair]:
    tokens = await auth.register_device(
        device_id=request.device_id,
        display_name=request.display_name,
        platform=request.platform,
    )
    await session.commit()
    return Success(data=tokens)


@router.post(
    "/refresh",
    response_model=Success[TokenPair],
    summary="Exchange a refresh token for a new session",
    description=(
        "Refresh tokens rotate: each is good exactly once. A second use means "
        "the token was captured, and every token for that device is revoked."
    ),
    responses=_UNAUTHORIZED,
)
async def refresh_session(
    request: RefreshRequest,
    auth: AuthServiceDep,
    session: SessionDep,
) -> Success[TokenPair]:
    tokens = await auth.refresh_session(refresh_token=request.refresh_token)
    await session.commit()
    return Success(data=tokens)


@router.get(
    "/devices",
    response_model=Success[DeviceList],
    summary="Devices signed in to this account",
    responses=_UNAUTHORIZED,
)
async def list_devices(
    current: CurrentSessionDep,
    auth: AuthServiceDep,
) -> Success[DeviceList]:
    devices = await auth.list_devices(account_id=current.account_id)
    return Success(
        data=DeviceList(
            devices=[
                DeviceSummary(
                    id=device.id,
                    display_name=device.display_name,
                    platform=device.platform,
                    last_seen_at=device.last_seen_at,
                    created_at=device.created_at,
                    revoked_at=device.revoked_at,
                    is_current=device.id == current.device_id,
                )
                for device in devices
            ]
        )
    )


@router.delete(
    "/devices/{device_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    summary="Sign a device out",
    responses=_UNAUTHORIZED,
)
async def revoke_device(
    device_id: str,
    current: CurrentSessionDep,
    auth: AuthServiceDep,
    session: SessionDep,
) -> None:
    await auth.revoke_device(account_id=current.account_id, device_id=device_id)
    await session.commit()


@router.post(
    "/pairing-codes",
    status_code=status.HTTP_201_CREATED,
    response_model=Success[PairingCodeResponse],
    summary="Show a code for a second device to type in",
    responses=_UNAUTHORIZED,
)
async def create_pairing_code(
    current: CurrentSessionDep,
    auth: AuthServiceDep,
    session: SessionDep,
) -> Success[PairingCodeResponse]:
    code, expires_at = await auth.create_pairing_code(account_id=current.account_id)
    await session.commit()
    return Success(data=PairingCodeResponse(code=code, expires_at=expires_at))


@router.post(
    "/pairing-codes/redeem",
    response_model=Success[TokenPair],
    summary="Join the account that showed this code",
    description=(
        "The device redeeming must already be registered. Its own anonymous "
        "account is merged into the other one, never discarded."
    ),
    responses={
        **_UNAUTHORIZED,
        400: {"model": Failure, "description": "Wrong or expired code."},
        429: {"model": Failure, "description": "Too many attempts."},
    },
)
async def redeem_pairing_code(
    request: RedeemPairingCodeRequest,
    current: CurrentSessionDep,
    auth: AuthServiceDep,
    session: SessionDep,
    rate_limiter: PairingRateLimiterDep,
) -> Success[TokenPair]:
    # Six digits is a million possibilities; capping guesses per device is what
    # makes that safe, and the device is the only honest axis to cap on — a
    # blind guesser does not name the code they are aiming at.
    rate_limiter.check(current.device_id)
    tokens = await auth.redeem_pairing_code(
        code=request.code, device_id=current.device_id
    )
    await session.commit()
    return Success(data=tokens)


@router.post(
    "/magic-links",
    response_model=Success[MagicLinkSent],
    summary="Email a link that attaches an address to this account",
    responses=_UNAUTHORIZED,
)
async def request_magic_link(
    request: MagicLinkRequest,
    current: CurrentSessionDep,
    auth: AuthServiceDep,
    session: SessionDep,
) -> Success[MagicLinkSent]:
    expires_at = await auth.request_magic_link(
        email=request.email, account_id=current.account_id
    )
    await session.commit()
    # Says nothing about whether the address is already known: that would be
    # an account enumeration hole with nothing to gain.
    return Success(data=MagicLinkSent(expires_at=expires_at))


@router.post(
    "/magic-links/redeem",
    response_model=Success[TokenPair],
    summary="Attach the address, or join the account that already has it",
    responses={
        **_UNAUTHORIZED,
        400: {"model": Failure, "description": "The link is not valid."},
    },
)
async def redeem_magic_link(
    request: RedeemMagicLinkRequest,
    current: CurrentSessionDep,
    auth: AuthServiceDep,
    session: SessionDep,
) -> Success[TokenPair]:
    tokens = await auth.redeem_magic_link(
        token=request.token, device_id=current.device_id
    )
    await session.commit()
    return Success(data=tokens)
