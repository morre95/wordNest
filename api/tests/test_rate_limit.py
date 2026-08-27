"""The token bucket, both as a unit and through the endpoint."""

import pytest
from httpx import ASGITransport, AsyncClient

from wordnest_api.core.config import (
    Environment,
    Settings,
    TranslationProviderName,
)
from wordnest_api.core.errors import RateLimitedError
from wordnest_api.core.rate_limit import TokenBucketRateLimiter
from wordnest_api.main import create_app


class FakeClock:
    def __init__(self) -> None:
        self.seconds = 0.0

    def __call__(self) -> float:
        return self.seconds

    def advance(self, seconds: float) -> None:
        self.seconds += seconds


def test_allows_exactly_the_limit_then_refuses() -> None:
    limiter = TokenBucketRateLimiter(limit_per_minute=3, now=FakeClock())

    for _ in range(3):
        limiter.check("device-a")

    with pytest.raises(RateLimitedError):
        limiter.check("device-a")


def test_one_client_hitting_the_limit_does_not_affect_another() -> None:
    limiter = TokenBucketRateLimiter(limit_per_minute=2, now=FakeClock())
    limiter.check("device-a")
    limiter.check("device-a")

    limiter.check("device-b")  # must not raise

    with pytest.raises(RateLimitedError):
        limiter.check("device-a")


def test_refills_continuously_rather_than_locking_out_for_a_whole_minute() -> None:
    clock = FakeClock()
    limiter = TokenBucketRateLimiter(limit_per_minute=60, now=clock)
    for _ in range(60):
        limiter.check("device-a")
    with pytest.raises(RateLimitedError):
        limiter.check("device-a")

    clock.advance(1.0)  # 60/minute means one token per second

    limiter.check("device-a")


def test_says_how_long_to_wait() -> None:
    limiter = TokenBucketRateLimiter(limit_per_minute=6, now=FakeClock())
    for _ in range(6):
        limiter.check("device-a")

    with pytest.raises(RateLimitedError) as raised:
        limiter.check("device-a")

    # Six per minute is one every ten seconds.
    assert 1 <= raised.value.retry_after_seconds <= 11


def test_never_hands_out_more_than_the_limit_after_a_long_idle() -> None:
    clock = FakeClock()
    limiter = TokenBucketRateLimiter(limit_per_minute=5, now=clock)
    limiter.check("device-a")

    clock.advance(3600)  # an hour of not using the app

    for _ in range(5):
        limiter.check("device-a")
    with pytest.raises(RateLimitedError):
        limiter.check("device-a")


async def test_the_endpoint_refuses_with_the_standard_envelope() -> None:
    settings = Settings(
        environment=Environment.test,
        translation_provider=TranslationProviderName.fake,
        translation_rate_limit_per_minute=2,
    )
    app = create_app(settings)
    body = {
        "source_text": "hello",
        "source_language": "en",
        "target_language": "es",
    }

    async with (
        AsyncClient(
            transport=ASGITransport(app=app), base_url="http://testserver"
        ) as client,
        app.router.lifespan_context(app),
    ):
        for _ in range(2):
            assert (
                await client.post("/api/v1/translations", json=body)
            ).status_code == 200

        response = await client.post("/api/v1/translations", json=body)

    assert response.status_code == 429
    payload = response.json()
    assert payload["success"] is False
    assert payload["error"]["code"] == "RATE_LIMITED"
    assert int(response.headers["Retry-After"]) >= 1
