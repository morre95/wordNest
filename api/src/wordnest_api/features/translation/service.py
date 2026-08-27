"""Translation business logic: validate the pair, ask the provider, shape the
result. No HTTP here, and no knowledge of which provider is in use.
"""

from collections.abc import AsyncIterator

from ...core.errors import UnsupportedLanguagePairError
from .languages import language_name
from .provider import TranslationDelta, TranslationProvider
from .schemas import TranslationBreakdown, TranslationRequest, TranslationResult


class TranslationService:
    def __init__(self, provider: TranslationProvider) -> None:
        self._provider = provider

    def validate(self, request: TranslationRequest) -> tuple[str, str]:
        """Resolves both language names, or says which one it could not.

        Public because the streaming endpoint has to check the pair *before*
        it starts responding: once the status line is sent, a refusal can only
        be an event nobody is obliged to read.
        """
        source_name = language_name(request.source_language)
        target_name = language_name(request.target_language)

        unknown = [
            code
            for code, name in (
                (request.source_language, source_name),
                (request.target_language, target_name),
            )
            if name is None
        ]
        if unknown:
            raise UnsupportedLanguagePairError(
                "WordNest does not translate that language.",
                details={"unsupported_languages": unknown},
            )
        if request.source_language == request.target_language:
            raise UnsupportedLanguagePairError(
                "The source and target languages are the same.",
                details={"language": request.source_language},
            )
        return source_name, target_name  # type: ignore[return-value]

    async def translate(self, request: TranslationRequest) -> TranslationResult:
        source_name, target_name = self.validate(request)

        breakdown = await self._provider.translate(
            source_text=request.source_text,
            source_language_name=source_name,
            target_language_name=target_name,
        )
        return self._result(request, breakdown)

    async def stream_translate(
        self, request: TranslationRequest
    ) -> AsyncIterator[TranslationDelta | TranslationResult]:
        """The same answer, but the natural translation arrives as it is written.

        The language pair is validated before anything is streamed, so an
        unsupported pair is still an ordinary error response rather than an
        error buried inside a stream that already returned 200.
        """
        source_name, target_name = self.validate(request)

        async for event in self._provider.stream_translate(
            source_text=request.source_text,
            source_language_name=source_name,
            target_language_name=target_name,
        ):
            if isinstance(event, TranslationDelta):
                yield event
            else:
                yield self._result(request, event)

    def _result(
        self, request: TranslationRequest, breakdown: TranslationBreakdown
    ) -> TranslationResult:
        return TranslationResult(
            source_text=request.source_text,
            source_language=request.source_language,
            target_language=request.target_language,
            translation=breakdown.translation,
            literal_gloss=breakdown.literal_gloss,
            tokens=breakdown.tokens,
        )
