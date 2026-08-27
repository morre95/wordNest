"""Shared FastAPI dependencies.

Everything a route needs is injected, so a test can replace any of it with
`app.dependency_overrides` rather than by monkey-patching a module.
"""

from typing import Annotated

from fastapi import Depends, Request

from ..features.translation.provider import TranslationProvider
from ..features.translation.service import TranslationService
from .config import Settings
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
