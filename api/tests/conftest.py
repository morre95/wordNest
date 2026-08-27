"""Shared fixtures.

Every test runs against an app built with test settings and the deterministic
fake provider, so the suite needs no API key and never reaches the network.
"""

from collections.abc import AsyncIterator

import pytest
from httpx import ASGITransport, AsyncClient

from wordnest_api.core.config import (
    Environment,
    Settings,
    TranslationProviderName,
)
from wordnest_api.main import create_app


@pytest.fixture
def settings() -> Settings:
    return Settings(
        environment=Environment.test,
        translation_provider=TranslationProviderName.fake,
        translation_rate_limit_per_minute=60,
        log_request_bodies=False,
    )


@pytest.fixture
async def client(settings: Settings) -> AsyncIterator[AsyncClient]:
    app = create_app(settings)
    # The lifespan has to run too, so the provider and rate limiter exist.
    async with (
        AsyncClient(
            transport=ASGITransport(app=app),
            base_url="http://testserver",
        ) as http_client,
        app.router.lifespan_context(app),
    ):
        yield http_client
