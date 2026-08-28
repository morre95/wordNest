"""The boundary between this service and whatever transcribes audio.

Everything above this line works in terms of [Transcript]; only the
implementations below know that Deepgram is involved. That is what lets the
test suite run against a deterministic stand-in with no network and no key, and
what keeps the vendor's name out of the app entirely.

AUDIO POLICY: an implementation may hold one frame long enough to forward it and
no longer. Nothing here opens a file, and nothing accumulates audio — the relay
is a pipe, not a buffer. `tests/test_speech_privacy.py` is the guard on that.
"""

import json
import logging
from collections.abc import AsyncIterator
from contextlib import AbstractAsyncContextManager, asynccontextmanager
from dataclasses import dataclass
from typing import Protocol

from ...core.config import Settings
from ...core.errors import SpeechUnavailableError

logger = logging.getLogger(__name__)

#: What the app sends and what Deepgram is told to expect. Fixed rather than
#: negotiated: one format, asserted at both ends, is one fewer thing that can
#: silently produce garbage transcripts.
AUDIO_ENCODING = "linear16"
AUDIO_SAMPLE_RATE = 16000
AUDIO_CHANNELS = 1


@dataclass(frozen=True)
class Transcript:
    """Some or all of one utterance."""

    text: str
    is_final: bool
    confidence: float | None = None


class SpeechSession(Protocol):
    """One live transcription, for as long as the socket is open."""

    async def send_audio(self, frame: bytes) -> None:
        """Forwards one PCM frame. Never stores it."""
        ...

    async def finalize(self) -> None:
        """Tells the recogniser the speaker has stopped."""
        ...

    def transcripts(self) -> AsyncIterator[Transcript]:
        """Yields results until the session ends."""
        ...


class SpeechProvider(Protocol):
    """Opens transcription sessions."""

    def open(self, *, language: str) -> AbstractAsyncContextManager[SpeechSession]:
        """Opens a session for [language], and closes it on the way out."""
        ...


class DeepgramSpeechProvider:
    """Backed by Deepgram's streaming API.

    The API key lives here and nowhere near a device — which, along with keeping
    the vendor swappable, is why the audio comes through this service at all
    rather than going straight from the phone.
    """

    _ENDPOINT = "wss://api.deepgram.com/v1/listen"

    def __init__(self, settings: Settings) -> None:
        self._model = settings.deepgram_model
        self._api_key = settings.deepgram_api_key

    @asynccontextmanager
    async def open(self, *, language: str) -> AsyncIterator[SpeechSession]:
        # Imported here so a deployment that never uses Deepgram, and every
        # test run, does not need the client to be importable.
        import websockets

        query = {
            "model": self._model,
            "language": language,
            "encoding": AUDIO_ENCODING,
            "sample_rate": str(AUDIO_SAMPLE_RATE),
            "channels": str(AUDIO_CHANNELS),
            "interim_results": "true",
            "punctuate": "true",
            "smart_format": "true",
            # A pause this long ends an utterance. Matched to the app's own
            # pause handling so the two recognisers feel alike to a speaker.
            "endpointing": "300",
            "utterance_end_ms": "1000",
        }
        url = self._ENDPOINT + "?" + "&".join(f"{k}={v}" for k, v in query.items())

        try:
            connection = await websockets.connect(
                url,
                additional_headers={"Authorization": f"Token {self._api_key}"},
            )
        except Exception as failure:
            logger.warning("Deepgram would not connect: %s", type(failure).__name__)
            raise SpeechUnavailableError(
                "The transcription service could not be reached."
            ) from failure

        try:
            yield _DeepgramSession(connection)
        finally:
            await connection.close()


class _DeepgramSession:
    def __init__(self, connection: object) -> None:
        self._connection = connection

    async def send_audio(self, frame: bytes) -> None:
        await self._connection.send(frame)

    async def finalize(self) -> None:
        await self._connection.send(json.dumps({"type": "Finalize"}))

    async def transcripts(self) -> AsyncIterator[Transcript]:
        async for message in self._connection:
            if isinstance(message, bytes):
                # Deepgram has no reason to send us audio, and we have no reason
                # to look at it if it does.
                continue
            transcript = _read_deepgram_result(message)
            if transcript is not None:
                yield transcript


def _read_deepgram_result(message: str) -> Transcript | None:
    """Pulls one transcript out of a Deepgram frame, or None if it holds none.

    Deepgram sends metadata, speech-started and utterance-end frames alongside
    results, and an empty transcript on every silence. Returning None for all of
    them keeps the shape-checking in one place.
    """
    try:
        payload = json.loads(message)
    except json.JSONDecodeError:
        logger.warning("Deepgram sent a frame that is not JSON.")
        return None

    if payload.get("type") != "Results":
        return None
    alternatives = payload.get("channel", {}).get("alternatives") or []
    if not alternatives:
        return None
    text = (alternatives[0].get("transcript") or "").strip()
    if not text:
        return None
    return Transcript(
        text=text,
        is_final=bool(payload.get("is_final")),
        confidence=alternatives[0].get("confidence"),
    )


def build_speech_provider(settings: Settings) -> SpeechProvider:
    """Chooses the provider named in configuration.

    Imported lazily so a production deployment never loads the fake, and a test
    run never needs the Deepgram client to be installed.
    """
    from ...core.config import SpeechProviderName

    if settings.speech_provider is SpeechProviderName.deepgram:
        if not settings.deepgram_api_key:
            raise RuntimeError(
                "WORDNEST_DEEPGRAM_API_KEY must be set when the speech "
                "provider is `deepgram`."
            )
        return DeepgramSpeechProvider(settings)

    if settings.is_production:
        raise RuntimeError(
            "The fake speech provider cannot be used in production. "
            "Set WORDNEST_SPEECH_PROVIDER=deepgram."
        )
    from .fake_provider import FakeSpeechProvider

    logger.warning(
        "Using the fake speech provider. Transcripts will be nonsense."
    )
    return FakeSpeechProvider()
