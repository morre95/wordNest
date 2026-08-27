"""HTTP surface for translation: validate, rate-limit, delegate, wrap."""

from collections.abc import AsyncIterator

from fastapi import APIRouter
from fastapi.responses import StreamingResponse

from ...core.dependencies import ClientKeyDep, RateLimiterDep, TranslationServiceDep
from ...core.envelope import Failure, Success
from ...core.errors import WordNestError
from .events import breakdown_event, delta_event, done_event, error_event
from .provider import TranslationDelta
from .schemas import TranslationRequest, TranslationResult
from .service import TranslationService

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


@router.post(
    "/stream",
    summary="Translate one utterance, streaming the words as they are written",
    description=(
        "Server-sent events. `delta` carries more of the natural translation, "
        "`breakdown` the finished result with its word list, and `done` "
        "always arrives last — including after an `error`, so a reader has one "
        "place to stop.\n\n"
        "The language pair is validated before anything is streamed, so an "
        "unsupported pair is an ordinary error response rather than an error "
        "buried inside a stream that already returned 200.\n\n"
        "WordNest's own app does not use this: it shows an on-device "
        "translation immediately, so there is nothing for a stream to improve. "
        "It is here for a client with no on-device model, where the wait would "
        "otherwise be silent."
    ),
    response_class=StreamingResponse,
    responses={
        200: {
            "content": {"text/event-stream": {}},
            "description": "A stream of translation events.",
        },
        400: {"model": Failure, "description": "The request body is not valid."},
        422: {
            "model": Failure,
            "description": "The language pair is not supported.",
        },
        429: {"model": Failure, "description": "Too many requests."},
    },
)
async def stream_translation(
    request: TranslationRequest,
    service: TranslationServiceDep,
    rate_limiter: RateLimiterDep,
    caller: ClientKeyDep,
) -> StreamingResponse:
    # Both checks happen before the response begins: once the status line is
    # sent, a refusal can only be an event nobody is obliged to read.
    rate_limiter.check(caller)
    service.validate(request)

    return StreamingResponse(
        _translation_events(service, request),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-store",
            # Proxies that buffer would defeat the point of streaming at all.
            "X-Accel-Buffering": "no",
        },
    )


async def _translation_events(
    service: TranslationService, request: TranslationRequest
) -> AsyncIterator[str]:
    """Turns the service's events into SSE messages.

    A provider failure becomes an `error` event rather than an exception: by
    the time one can happen the response has already begun, and a half-written
    stream that simply stops leaves a reader waiting for something that will
    never come. Everything a client could have got wrong was rejected before
    this generator was started.
    """
    try:
        async for event in service.stream_translate(request):
            if isinstance(event, TranslationDelta):
                yield delta_event(event.text)
            else:
                yield breakdown_event(event.model_dump(mode="json"))
    except WordNestError as failure:
        yield error_event(failure.code, failure.message)
    yield done_event()
