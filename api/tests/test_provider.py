"""The provider boundary: what happens when the language model does not answer."""

import anthropic
import httpx2
import pytest

from wordnest_api.core.config import (
    Environment,
    Settings,
    TranslationProviderName,
)
from wordnest_api.core.errors import TranslationUnavailableError
from wordnest_api.features.translation.provider import (
    AnthropicTranslationProvider,
    build_translation_provider,
)
from wordnest_api.features.translation.schemas import (
    TranslationRequest,
)
from wordnest_api.features.translation.service import TranslationService


class RefusingProvider:
    async def translate(self, **_: object) -> object:
        raise TranslationUnavailableError("nope")


async def test_a_provider_failure_reaches_the_client_as_503(
    client_factory,
) -> None:
    response = await client_factory(RefusingProvider())

    assert response.status_code == 503
    assert response.json()["error"]["code"] == "TRANSLATION_UNAVAILABLE"


@pytest.fixture
def client_factory():
    from httpx import ASGITransport, AsyncClient

    from wordnest_api.main import create_app

    async def call(provider: object):
        settings = Settings(
            environment=Environment.test,
            translation_provider=TranslationProviderName.fake,
        )
        app = create_app(settings)
        async with (
            AsyncClient(
                transport=ASGITransport(app=app), base_url="http://testserver"
            ) as http,
            app.router.lifespan_context(app),
        ):
            app.state.translation_provider = provider
            return await http.post(
                "/api/v1/translations",
                json={
                    "source_text": "hello",
                    "source_language": "en",
                    "target_language": "es",
                },
            )

    return call


async def test_an_api_error_becomes_a_degraded_service_not_a_crash() -> None:
    provider = AnthropicTranslationProvider(
        Settings(environment=Environment.test, anthropic_api_key="test-key")
    )

    async def fail(**_: object) -> object:
        raise anthropic.APIStatusError(
            "overloaded",
            response=httpx2.Response(
                529, request=httpx2.Request("POST", "https://api.anthropic.com")
            ),
            body=None,
        )

    provider._client.messages.parse = fail  # type: ignore[method-assign]

    with pytest.raises(TranslationUnavailableError):
        await provider.translate(
            source_text="hello",
            source_language_name="English",
            target_language_name="Spanish",
        )


async def test_an_unreachable_provider_becomes_a_degraded_service() -> None:
    provider = AnthropicTranslationProvider(
        Settings(environment=Environment.test, anthropic_api_key="test-key")
    )

    async def fail(**_: object) -> object:
        raise anthropic.APIConnectionError(
            request=httpx2.Request("POST", "https://api.anthropic.com")
        )

    provider._client.messages.parse = fail  # type: ignore[method-assign]

    with pytest.raises(TranslationUnavailableError):
        await provider.translate(
            source_text="hello",
            source_language_name="English",
            target_language_name="Spanish",
        )


def test_the_fake_provider_is_refused_in_production() -> None:
    settings = Settings(
        environment=Environment.production,
        translation_provider=TranslationProviderName.fake,
    )

    with pytest.raises(RuntimeError, match="cannot be used in production"):
        build_translation_provider(settings)


async def test_the_service_asks_the_provider_in_language_names_not_codes() -> None:
    seen: dict[str, str] = {}

    class RecordingProvider:
        async def translate(self, **kwargs: str):
            seen.update(kwargs)
            from wordnest_api.features.translation.schemas import (
                TranslationBreakdown,
            )

            return TranslationBreakdown(translation="hola")

    await TranslationService(RecordingProvider()).translate(  # type: ignore[arg-type]
        TranslationRequest(
            source_text="hello", source_language="en", target_language="es"
        )
    )

    assert seen["source_language_name"] == "English"
    assert seen["target_language_name"] == "Spanish"
