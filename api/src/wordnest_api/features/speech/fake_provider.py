"""A deterministic stand-in for the transcription service.

Same audio, same transcript, every time — so tests can assert exact values, and
so the whole app runs end to end with no API key. It does not transcribe: it
reports how much audio it was sent, which is enough to prove the relay carried
the bytes and obvious enough that nobody mistakes it for the real thing.
"""

import asyncio
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from .provider import AUDIO_SAMPLE_RATE, Transcript


class FakeSpeechProvider:
    """Opens sessions that echo the shape of what they were given."""

    def __init__(self, *, partial_every: int = 4) -> None:
        #: Frames between interim results. Low enough that a short test session
        #: still sees a partial before its final.
        self._partial_every = partial_every

    @asynccontextmanager
    async def open(self, *, language: str) -> AsyncIterator["FakeSpeechSession"]:
        session = FakeSpeechSession(
            language=language,
            partial_every=self._partial_every,
        )
        try:
            yield session
        finally:
            await session.close()


class FakeSpeechSession:
    def __init__(self, *, language: str, partial_every: int) -> None:
        self.language = language
        self.frames = 0
        self.bytes_forwarded = 0
        self._partial_every = partial_every
        self._results: asyncio.Queue[Transcript | None] = asyncio.Queue()

    async def send_audio(self, frame: bytes) -> None:
        self.frames += 1
        self.bytes_forwarded += len(frame)
        if self.frames % self._partial_every == 0:
            await self._results.put(
                Transcript(text=self._say(), is_final=False)
            )

    async def finalize(self) -> None:
        await self._results.put(
            Transcript(text=self._say(), is_final=True, confidence=1.0)
        )

    async def close(self) -> None:
        await self._results.put(None)

    async def transcripts(self) -> AsyncIterator[Transcript]:
        while True:
            result = await self._results.get()
            if result is None:
                return
            yield result

    def _say(self) -> str:
        seconds = self.bytes_forwarded / (AUDIO_SAMPLE_RATE * 2)
        return f"[{self.language}] {seconds:.2f} seconds of audio"
