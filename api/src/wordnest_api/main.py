"""Application factory.

Everything the app needs is assembled here and nowhere else, so a test can build
a second app with different settings instead of reaching into a global.
"""

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from .core.config import Settings, get_settings
from .core.errors import register_error_handlers
from .core.logging import configure_logging, register_request_logging
from .core.rate_limit import TokenBucketRateLimiter
from .features.health.router import router as health_router
from .features.translation.provider import build_translation_provider
from .features.translation.router import router as translation_router

API_PREFIX = "/api/v1"


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or get_settings()
    configure_logging(settings)

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        # Built once: the provider owns an HTTP client with a connection pool,
        # and the rate limiter's buckets have to outlive a single request.
        app.state.translation_provider = build_translation_provider(settings)
        app.state.translation_rate_limiter = TokenBucketRateLimiter(
            limit_per_minute=settings.translation_rate_limit_per_minute
        )
        yield

    app = FastAPI(
        title="wordnest-api",
        version="0.1.0",
        summary="Translation with linguistic breakdown for WordNest.",
        description=(
            "Every endpoint returns the same envelope: `{success, data, meta}` "
            "on success, `{success, error: {code, message}}` on failure.\n\n"
            "This service never receives audio. It sees only text the device "
            "has already transcribed."
        ),
        lifespan=lifespan,
        docs_url=None if settings.is_production else "/docs",
        redoc_url=None,
    )

    if settings.cors_origins:
        app.add_middleware(
            CORSMiddleware,
            allow_origins=settings.cors_origins,
            allow_credentials=True,
            allow_methods=["GET", "POST", "PATCH", "DELETE"],
            allow_headers=["Authorization", "Content-Type", "X-Request-Id"],
        )

    app.state.settings = settings
    register_request_logging(app, settings)
    register_error_handlers(app)

    app.include_router(health_router, prefix=API_PREFIX)
    app.include_router(translation_router, prefix=API_PREFIX)
    return app


app = create_app()
