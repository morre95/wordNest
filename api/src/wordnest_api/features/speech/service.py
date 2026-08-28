"""The relay: audio in from the app, text back out.

AUDIO POLICY: this is a pipe. A frame is forwarded the moment it arrives and no
reference to it is kept; nothing here opens a file, and nothing accumulates.
The service that never receives audio now receives it and lets go of it
immediately, which is a weaker promise than before and the reason
`tests/test_speech_privacy.py` exists.
"""

import asyncio
import logging
from dataclasses import dataclass

from ...core.errors import SpeechUnavailableError, WordNestError
from .protocol import error_frame, final_frame, partial_frame
from .provider import SpeechProvider

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class AudioFrame:
    """One slice of PCM on its way through."""

    data: bytes


@dataclass(frozen=True)
class Finalize:
    """The speaker stopped."""


@dataclass(frozen=True)
class CloseSession:
    """The client is abandoning this session."""


ClientEvent = AudioFrame | Finalize | CloseSession


class SpeechRelayService:
    """Carries one session's audio to the provider and its text back.

    Deliberately transport-agnostic: it is handed an async source of client
    events and an async sink for frames, so the whole relay is testable without
    a WebSocket, and the router stays a thin adapter over it.
    """

    def __init__(self, provider: SpeechProvider) -> None:
        self._provider = provider

    async def run(
        self,
        *,
        language: str,
        events,
        send,
        session_seconds: int,
    ) -> None:
        try:
            async with self._provider.open(language=language) as session:
                await self._pump(
                    session=session,
                    events=events,
                    send=send,
                    session_seconds=session_seconds,
                )
        except SpeechUnavailableError as failure:
            await send(error_frame(failure.code, failure.message))
        except WordNestError as failure:
            await send(error_frame(failure.code, failure.message))

    async def _pump(self, *, session, events, send, session_seconds) -> None:
        async def carry_audio() -> None:
            async for event in events:
                match event:
                    case AudioFrame(data=data):
                        await session.send_audio(data)
                    case Finalize():
                        await session.finalize()
                    case CloseSession():
                        return

        async def carry_text() -> None:
            async for transcript in session.transcripts():
                await send(
                    final_frame(transcript.text, confidence=transcript.confidence)
                    if transcript.is_final
                    else partial_frame(transcript.text)
                )

        audio = asyncio.create_task(carry_audio())
        text = asyncio.create_task(carry_text())
        try:
            # A ceiling rather than a courtesy: a client that stops sending
            # without closing would otherwise hold a paid upstream session open
            # for as long as its socket survives.
            done, _ = await asyncio.wait(
                {audio, text},
                timeout=session_seconds,
                return_when=asyncio.FIRST_COMPLETED,
            )
            for task in done:
                task.result()
            if not done:
                logger.info("Speech session hit its ceiling and was closed.")
        finally:
            for task in (audio, text):
                if not task.done():
                    task.cancel()
            await asyncio.gather(audio, text, return_exceptions=True)
