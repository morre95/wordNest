"""Translation business logic: validate the pair, ask the provider, shape the
result. No HTTP here, and no knowledge of which provider is in use.
"""

from ...core.errors import UnsupportedLanguagePairError
from .languages import language_name
from .provider import TranslationProvider
from .schemas import TranslationRequest, TranslationResult


class TranslationService:
    def __init__(self, provider: TranslationProvider) -> None:
        self._provider = provider

    async def translate(self, request: TranslationRequest) -> TranslationResult:
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

        breakdown = await self._provider.translate(
            source_text=request.source_text,
            source_language_name=source_name,  # type: ignore[arg-type]
            target_language_name=target_name,  # type: ignore[arg-type]
        )

        return TranslationResult(
            source_text=request.source_text,
            source_language=request.source_language,
            target_language=request.target_language,
            translation=breakdown.translation,
            literal_gloss=breakdown.literal_gloss,
            tokens=breakdown.tokens,
        )
