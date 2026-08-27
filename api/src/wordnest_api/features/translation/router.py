"""HTTP surface for translation: validate, rate-limit, delegate, wrap."""

from fastapi import APIRouter

from ...core.dependencies import ClientKeyDep, RateLimiterDep, TranslationServiceDep
from ...core.envelope import Failure, Success
from .schemas import TranslationRequest, TranslationResult

router = APIRouter(prefix="/translations", tags=["translation"])


@router.post(
    "",
    response_model=Success[TranslationResult],
    summary="Translate one utterance and break it into vocabulary",
    responses={
        400: {"model": Failure, "description": "The request body is not valid."},
        422: {
            "model": Failure,
            "description": "The language pair is not supported, or is the same "
            "language twice.",
        },
        429: {"model": Failure, "description": "Too many requests."},
        503: {
            "model": Failure,
            "description": "The translation provider is unavailable. The client "
            "should keep its on-device translation and retry later.",
        },
    },
)
async def create_translation(
    request: TranslationRequest,
    service: TranslationServiceDep,
    rate_limiter: RateLimiterDep,
    caller: ClientKeyDep,
) -> Success[TranslationResult]:
    rate_limiter.check(caller)
    result = await service.translate(request)
    return Success(
        data=result,
        meta={"rate_limit_remaining": rate_limiter.remaining(caller)},
    )
