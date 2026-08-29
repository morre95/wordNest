"""Application factory.

Everything the app needs is assembled here and nowhere else, so a test can build
a second app with different settings instead of reaching into a global.
"""

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from .core.config import Settings, get_settings
from .core.db.session import create_engine, create_session_factory
from .core.errors import register_error_handlers
from .core.logging import configure_logging, register_request_logging
from .core.rate_limit import TokenBucketRateLimiter
from .features.auth.email_sender import build_email_sender
from .features.auth.router import router as auth_router
from .features.glossary.router import router as glossary_router
from .features.health.router import router as health_router
from .features.review.router import router as review_router
from .features.speech.provider import build_speech_provider
from .features.speech.router import router as speech_router
from .features.sync.router import router as sync_router
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
        # A separate bucket from translation: guessing a pairing code and
        # translating a sentence are different budgets.
        app.state.pairing_rate_limiter = TokenBucketRateLimiter(
            limit_per_minute=settings.pairing_redemptions_per_minute
        )
        # Same reasoning as translation: one client, one pool, built at
        # startup rather than per session.
        app.state.speech_provider = build_speech_provider(settings)
        # Its own bucket again: opening a transcription session and translating
        # a finished sentence are different budgets, and this one costs money
        # by the minute rather than by the request.
        app.state.speech_rate_limiter = TokenBucketRateLimiter(
            limit_per_minute=settings.speech_rate_limit_per_minute
        )
        app.state.email_sender = build_email_sender(settings)
        engine = create_engine(settings)
        app.state.engine = engine
        app.state.session_factory = create_session_factory(engine)
        try:
            yield
        finally:
            await engine.dispose()

    app = FastAPI(
        title="wordnest-api",
        version="0.1.0",
        summary="Translation with linguistic breakdown for WordNest.",
        description=(
            "Every endpoint returns the same envelope: `{success, data, meta}` "
            "on success, `{success, error: {code, message}}` on failure.\n\n"
            "Every endpoint but one sees only text the device has already "
            "transcribed. The exception is the speech socket, which relays "
            "live audio to a transcription service and the text back; it "
            "buffers nothing and writes nothing."
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
    app.include_router(auth_router, prefix=API_PREFIX)
    app.include_router(translation_router, prefix=API_PREFIX)
    app.include_router(sync_router, prefix=API_PREFIX)
    app.include_router(glossary_router, prefix=API_PREFIX)
    app.include_router(review_router, prefix=API_PREFIX)
    app.include_router(speech_router, prefix=API_PREFIX)
    return app


app = create_app()
