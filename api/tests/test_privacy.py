"""The service must not write what people said into its logs.

Request-body logging is a debugging aid; it is off unless someone turns it on,
and turning it on says so loudly.
"""

import logging

from httpx import ASGITransport, AsyncClient

from wordnest_api.core.config import (
    Environment,
    Settings,
    TranslationProviderName,
)
from wordnest_api.main import create_app

SECRET_SENTENCE = "my passport number is in the blue drawer"


async def _post_a_sentence(settings: Settings) -> None:
    app = create_app(settings)
    async with (
        AsyncClient(
            transport=ASGITransport(app=app), base_url="http://testserver"
        ) as client,
        app.router.lifespan_context(app),
    ):
        await client.post(
            "/api/v1/translations",
            json={
                "source_text": SECRET_SENTENCE,
                "source_language": "en",
                "target_language": "es",
            },
        )


async def test_request_body_logging_is_off_by_default() -> None:
    assert Settings(environment=Environment.test).log_request_bodies is False


async def test_a_translated_sentence_never_reaches_the_log(caplog) -> None:
    caplog.set_level(logging.DEBUG)

    await _post_a_sentence(
        Settings(
            environment=Environment.test,
            translation_provider=TranslationProviderName.fake,
        )
    )

    assert SECRET_SENTENCE not in caplog.text


async def test_turning_body_logging_on_warns_that_it_is_on(caplog) -> None:
    caplog.set_level(logging.WARNING)

    await _post_a_sentence(
        Settings(
            environment=Environment.test,
            translation_provider=TranslationProviderName.fake,
            log_request_bodies=True,
        )
    )

    assert "Request-body logging is ON" in caplog.text


async def test_an_internal_failure_tells_the_client_nothing_useful() -> None:
    class ExplodingProvider:
        async def translate(self, **_: object) -> object:
            raise RuntimeError(f"connection string leaked: {SECRET_SENTENCE}")

    settings = Settings(
        environment=Environment.test,
        translation_provider=TranslationProviderName.fake,
    )
    app = create_app(settings)
    async with (
        AsyncClient(
            # Without `raise_app_exceptions=False` the transport re-raises instead
            # of letting the handler answer, which is not what a real server does.
            transport=ASGITransport(app=app, raise_app_exceptions=False),
            base_url="http://testserver",
        ) as client,
        app.router.lifespan_context(app),
    ):
        app.state.translation_provider = ExplodingProvider()
        response = await client.post(
            "/api/v1/translations",
            json={
                "source_text": "hello",
                "source_language": "en",
                "target_language": "es",
            },
        )

    assert response.status_code == 500
    body = response.json()
    assert body["error"]["code"] == "INTERNAL_ERROR"
    assert "connection string" not in response.text
