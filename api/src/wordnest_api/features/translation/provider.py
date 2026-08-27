"""The boundary between this service and whatever produces translations.

Everything above this line works in terms of [TranslationBreakdown]; only the
implementations below know that a language model is involved. That is what lets
the test suite run against a deterministic stand-in with no network and no key.
"""

import logging
from typing import Protocol

import anthropic

from ...core.config import Settings
from ...core.errors import TranslationUnavailableError
from ...core.prompts import render_prompt
from .schemas import TranslationBreakdown

logger = logging.getLogger(__name__)


class TranslationProvider(Protocol):
    """Produces a translation and a word breakdown for one sentence."""

    async def translate(
        self,
        *,
        source_text: str,
        source_language_name: str,
        target_language_name: str,
    ) -> TranslationBreakdown: ...


class AnthropicTranslationProvider:
    """Backed by Claude.

    The API key lives here and nowhere near a device — which is the main reason
    this service exists at all.
    """

    def __init__(self, settings: Settings) -> None:
        self._model = settings.translation_model
        self._client = anthropic.AsyncAnthropic(
            # Falls back to the SDK's own ANTHROPIC_API_KEY when unset.
            api_key=settings.anthropic_api_key,
        )

    async def translate(
        self,
        *,
        source_text: str,
        source_language_name: str,
        target_language_name: str,
    ) -> TranslationBreakdown:
        variables = {
            "source_language_name": source_language_name,
            "target_language_name": target_language_name,
            "source_text": source_text,
        }
        try:
            response = await self._client.messages.parse(
                model=self._model,
                max_tokens=4096,
                system=render_prompt("translation/system.j2", **variables),
                messages=[
                    {
                        "role": "user",
                        "content": render_prompt(
                            "translation/translate.j2", **variables
                        ),
                    }
                ],
                output_format=TranslationBreakdown,
            )
        except anthropic.APIStatusError as error:
            logger.warning(
                "Translation provider returned %s", error.status_code, exc_info=True
            )
            raise TranslationUnavailableError(
                "The translation service is temporarily unavailable."
            ) from error
        except anthropic.APIConnectionError as error:
            logger.warning("Translation provider unreachable", exc_info=True)
            raise TranslationUnavailableError(
                "The translation service could not be reached."
            ) from error

        breakdown = response.parsed_output
        if breakdown is None:
            # A refusal or a truncated response. The device already has an
            # on-device translation to fall back on, so degrade rather than 500.
            logger.warning(
                "Translation produced no structured output (stop_reason=%s)",
                response.stop_reason,
            )
            raise TranslationUnavailableError(
                "The translation service returned nothing usable."
            )
        return breakdown


def build_translation_provider(settings: Settings) -> TranslationProvider:
    """Chooses the provider named in configuration.

    Imported lazily so a production deployment never loads the fake, and a test
    run never needs the Anthropic client to be constructible.
    """
    from ...core.config import TranslationProviderName

    if settings.translation_provider is TranslationProviderName.anthropic:
        return AnthropicTranslationProvider(settings)

    if settings.is_production:
        raise RuntimeError(
            "The fake translation provider cannot be used in production. "
            "Set WORDNEST_TRANSLATION_PROVIDER=anthropic."
        )
    from .fake_provider import FakeTranslationProvider

    logger.warning(
        "Using the fake translation provider. Translations will be nonsense."
    )
    return FakeTranslationProvider()
