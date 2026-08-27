"""Shared FastAPI dependencies.

Everything a route needs is injected, so a test can replace any of it with
`app.dependency_overrides` rather than by monkey-patching a module.
"""

from collections.abc import AsyncIterator
from typing import Annotated

from fastapi import Depends, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.ext.asyncio import AsyncSession

from ..features.auth.email_sender import EmailSender
from ..features.auth.service import AuthService
from ..features.auth.tokens import AccessTokenClaims, read_access_token
from ..features.sync.service import SyncService
from ..features.translation.provider import TranslationProvider
from ..features.translation.service import TranslationService
from .config import Settings
from .db.session import session_scope
from .rate_limit import TokenBucketRateLimiter


def get_app_settings(request: Request) -> Settings:
    """The settings this app was built with.

    Deliberately not `get_settings()`: that reads the process environment once
    and caches it, which would make `create_app(settings)` a lie — a test app
    built with test settings would still see the ambient ones.
    """
    return request.app.state.settings


SettingsDep = Annotated[Settings, Depends(get_app_settings)]


def get_translation_provider(request: Request) -> TranslationProvider:
    """Built once at startup and kept on the app, because constructing an HTTP
    client per request would leak connections."""
    return request.app.state.translation_provider


def get_translation_service(
    provider: Annotated[TranslationProvider, Depends(get_translation_provider)],
) -> TranslationService:
    return TranslationService(provider)


def get_translation_rate_limiter(request: Request) -> TokenBucketRateLimiter:
    return request.app.state.translation_rate_limiter


def get_pairing_rate_limiter(request: Request) -> TokenBucketRateLimiter:
    return request.app.state.pairing_rate_limiter


PairingRateLimiterDep = Annotated[
    TokenBucketRateLimiter, Depends(get_pairing_rate_limiter)
]


def client_key(request: Request) -> str:
    """Identifies the caller for rate limiting.

    The client IP for now. From milestone 4 a registered device has a token, and
    that is a far better key — an IP is shared by everyone behind one NAT.
    """
    forwarded = request.headers.get("X-Forwarded-For")
    if forwarded:
        return forwarded.split(",")[0].strip()
    return request.client.host if request.client else "unknown"


TranslationServiceDep = Annotated[TranslationService, Depends(get_translation_service)]
RateLimiterDep = Annotated[
    TokenBucketRateLimiter, Depends(get_translation_rate_limiter)
]
ClientKeyDep = Annotated[str, Depends(client_key)]


async def get_session(request: Request) -> AsyncIterator[AsyncSession]:
    """One session per request, committed by the route that owns the write."""
    async for session in session_scope(request.app.state.session_factory):
        yield session


SessionDep = Annotated[AsyncSession, Depends(get_session)]


def get_email_sender(request: Request) -> EmailSender:
    return request.app.state.email_sender


def get_auth_service(
    session: SessionDep,
    settings: SettingsDep,
    email_sender: Annotated[EmailSender, Depends(get_email_sender)],
) -> AuthService:
    return AuthService(session, settings, email_sender)


def get_sync_service(session: SessionDep, settings: SettingsDep) -> SyncService:
    return SyncService(session, settings)


AuthServiceDep = Annotated[AuthService, Depends(get_auth_service)]
SyncServiceDep = Annotated[SyncService, Depends(get_sync_service)]

#: `auto_error=False` so a missing header produces our own error envelope
#: rather than FastAPI's bare 403.
_bearer = HTTPBearer(auto_error=False)


def current_session(
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(_bearer)],
    settings: SettingsDep,
) -> AccessTokenClaims:
    """The account and device making this request.

    Every mutating endpoint depends on this. Verification is a signature check
    with no database round trip, which is the point of a short-lived token: a
    revoked device stops working when its access token expires, minutes later.
    """
    from ..features.auth.tokens import InvalidCredentialsError

    if credentials is None or not credentials.credentials:
        raise InvalidCredentialsError("This request needs an access token.")
    return read_access_token(credentials.credentials, secret=settings.jwt_secret)


CurrentSessionDep = Annotated[AccessTokenClaims, Depends(current_session)]
