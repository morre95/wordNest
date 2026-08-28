"""Shared fixtures.

Every test runs against an app built with test settings and the deterministic
fake provider, so the suite needs no API key and never reaches the network.
Each test gets its own SQLite file, created by running the real migrations —
so the migrations are exercised on every run rather than only when someone
remembers to.
"""

import uuid
from collections.abc import AsyncIterator, Iterator
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from fastapi.testclient import TestClient
from httpx import ASGITransport, AsyncClient

from wordnest_api.core.config import (
    Environment,
    Settings,
    SpeechProviderName,
    TranslationProviderName,
)
from wordnest_api.main import create_app

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def database_url(tmp_path: Path) -> str:
    """A fresh migrated database per test, so no test can see another's rows."""
    path = tmp_path / f"{uuid.uuid4().hex}.db"
    url = f"sqlite+aiosqlite:///{path}"

    config = Config(str(REPOSITORY_ROOT / "alembic.ini"))
    config.set_main_option("script_location", str(REPOSITORY_ROOT / "alembic"))
    config.set_main_option("sqlalchemy.url", url)
    # Leave pytest's log capture alone; see the note in alembic/env.py.
    config.attributes["configure_logging"] = False
    command.upgrade(config, "head")
    return url


@pytest.fixture
def settings(database_url: str) -> Settings:
    return Settings(
        environment=Environment.test,
        translation_provider=TranslationProviderName.fake,
        speech_provider=SpeechProviderName.fake,
        translation_rate_limit_per_minute=60,
        log_request_bodies=False,
        database_url=database_url,
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


@pytest.fixture
def speech_app(settings: Settings) -> Iterator[TestClient]:
    """A synchronous client, because WebSockets need one.

    `httpx` + `ASGITransport` cannot speak WebSocket, so the speech socket is
    the one part of the API that has to be exercised through Starlette's own
    test client. Its context manager runs the lifespan, as `client` does.
    """
    with TestClient(create_app(settings)) as test_client:
        yield test_client


@pytest.fixture
async def device(client: AsyncClient) -> dict[str, str]:
    """A registered device with a live session, as first launch produces."""
    return await register(client, device_id="device-" + uuid.uuid4().hex[:12])


async def register(
    client: AsyncClient,
    *,
    device_id: str,
    display_name: str = "Test phone",
    platform: str = "android",
) -> dict[str, str]:
    response = await client.post(
        "/api/v1/auth/devices",
        json={
            "device_id": device_id,
            "display_name": display_name,
            "platform": platform,
        },
    )
    assert response.status_code == 201, response.text
    return response.json()["data"]


def bearer(session: dict[str, str]) -> dict[str, str]:
    return {"Authorization": f"Bearer {session['access_token']}"}
