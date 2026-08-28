"""The speech socket: a thin adapter between a WebSocket and the relay."""

import json
import logging
from collections.abc import AsyncIterator
from contextlib import suppress

from fastapi import APIRouter, Query, WebSocket, WebSocketDisconnect

from ...core.dependencies import (
    SocketClientKeyDep,
    SocketSettingsDep,
    SpeechRateLimiterDep,
    SpeechRelayDep,
)
from ...core.errors import RateLimitedError, WordNestError
from ..auth.tokens import InvalidCredentialsError
from .protocol import (
    CLOSE_RATE_LIMITED,
    CLOSE_UNAUTHENTICATED,
    read_control,
)
from .service import AudioFrame, CloseSession, Finalize

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/speech", tags=["speech"])


@router.websocket("/stream")
async def stream_speech(
    websocket: WebSocket,
    settings: SocketSettingsDep,
    relay: SpeechRelayDep,
    rate_limiter: SpeechRateLimiterDep,
    caller: SocketClientKeyDep,
    language: str = Query(min_length=2, max_length=8),
) -> None:
    """Transcribes live audio.

    The client sends binary PCM16 frames at the sample rate its query names, and
    `{"type":"finalize"}` when the speaker stops. The server sends `partial`,
    `final` and `error` frames — WordNest's vocabulary, never the vendor's.

    Refusals happen before `accept()`, with an application close code, so the
    client can tell "your session expired" from "you are going too fast" from
    "the service is down" without a body to read.
    """
    try:
        session = await _authenticate(websocket, settings)
    except InvalidCredentialsError:
        await websocket.close(code=CLOSE_UNAUTHENTICATED)
        return

    try:
        rate_limiter.check(caller)
    except RateLimitedError:
        await websocket.close(code=CLOSE_RATE_LIMITED)
        return

    await websocket.accept()
    logger.info("Speech session opened for device %s", session.device_id)

    try:
        await relay.run(
            language=language,
            events=_client_events(websocket),
            send=websocket.send_json,
            session_seconds=settings.speech_session_seconds,
        )
    except WebSocketDisconnect:
        # The ordinary way a session ends: the user let go and the app closed.
        pass
    except WordNestError as failure:
        logger.warning("Speech session failed: %s", failure.code)
    finally:
        logger.info("Speech session closed for device %s", session.device_id)
        await _close_quietly(websocket)


async def _authenticate(websocket: WebSocket, settings) -> object:
    from ...core.dependencies import current_session_ws

    return current_session_ws(websocket, settings)


async def _client_events(websocket: WebSocket) -> AsyncIterator[object]:
    """Turns raw frames into the relay's vocabulary.

    A frame is yielded and forgotten. Nothing here holds a reference to audio
    beyond the `yield` that passes it on.
    """
    while True:
        try:
            message = await websocket.receive()
        except WebSocketDisconnect:
            return

        if message.get("type") == "websocket.disconnect":
            return

        if (payload := message.get("bytes")) is not None:
            yield AudioFrame(data=payload)
            continue

        if (text := message.get("text")) is not None:
            try:
                decoded = json.loads(text)
            except json.JSONDecodeError:
                continue
            match read_control(decoded):
                case "finalize":
                    yield Finalize()
                case "close":
                    yield CloseSession()
                    return
                case _:
                    continue


async def _close_quietly(websocket: WebSocket) -> None:
    """Closing an already-closed socket is not an error worth reporting."""
    with suppress(RuntimeError):
        await websocket.close()
