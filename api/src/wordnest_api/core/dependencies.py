"""Shared FastAPI dependencies.

Everything a route needs is injected, so a test can replace any of it with
`app.dependency_overrides` rather than by monkey-patching a module.
"""

from collections.abc import AsyncIterator
from typing import Annotated

from fastapi import Depends, Request, WebSocket
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.ext.asyncio import AsyncSession

from ..features.auth.email_sender import EmailSender
from ..features.auth.service import AuthService
from ..features.auth.tokens import AccessTokenClaims, read_access_token
from ..features.speech.provider import SpeechProvider
from ..features.speech.service import SpeechRelayService
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


def get_socket_settings(websocket: WebSocket) -> Settings:
    """`get_app_settings` reads a `Request`, which a WebSocket route has none
    of. Same value, taken off the same app."""
    return websocket.app.state.settings


SocketSettingsDep = Annotated[Settings, Depends(get_socket_settings)]


def current_session_ws(
    websocket: WebSocket,
    settings: Settings,
) -> AccessTokenClaims:
    """The account and device on the other end of a speech socket.

    `current_session` cannot be reused: it depends on `HTTPBearer`, which takes
    a `Request`, and a WebSocket is an `HTTPConnection` but not a `Request`. The
    token verification itself is shared — this reads the header and hands it to
    the same `read_access_token`.
    """
    from ..features.auth.tokens import InvalidCredentialsError

    header = websocket.headers.get("authorization", "")
    scheme, _, token = header.partition(" ")
    if scheme.lower() != "bearer" or not token:
        raise InvalidCredentialsError("This socket needs an access token.")
    return read_access_token(token, secret=settings.jwt_secret)


def get_speech_provider(websocket: WebSocket) -> SpeechProvider:
    """Built once at startup, like the translation provider and for the same
    reason: it owns a connection pool."""
    return websocket.app.state.speech_provider


def get_speech_relay(
    provider: Annotated[SpeechProvider, Depends(get_speech_provider)],
) -> SpeechRelayService:
    return SpeechRelayService(provider)


def get_speech_rate_limiter(websocket: WebSocket) -> TokenBucketRateLimiter:
    return websocket.app.state.speech_rate_limiter


def socket_client_key(websocket: WebSocket) -> str:
    """Identifies the caller for rate limiting, as `client_key` does for HTTP."""
    forwarded = websocket.headers.get("X-Forwarded-For")
    if forwarded:
        return forwarded.split(",")[0].strip()
    return websocket.client.host if websocket.client else "unknown"


SpeechRelayDep = Annotated[SpeechRelayService, Depends(get_speech_relay)]
SpeechRateLimiterDep = Annotated[
    TokenBucketRateLimiter, Depends(get_speech_rate_limiter)
]
SocketClientKeyDep = Annotated[str, Depends(socket_client_key)]
