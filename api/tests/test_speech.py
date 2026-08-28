"""The speech relay: audio in, WordNest's own frames back out.

Every test here runs against the deterministic fake provider, so the suite
needs no Deepgram key and never reaches the network.
"""

import json
from unittest.mock import AsyncMock

import pytest
from fastapi.testclient import TestClient
from httpx import AsyncClient
from starlette.websockets import WebSocketDisconnect

from wordnest_api.features.speech.protocol import (
    CLOSE_RATE_LIMITED,
    CLOSE_UNAUTHENTICATED,
    error_frame,
    final_frame,
    partial_frame,
    read_control,
)
from wordnest_api.features.speech.router import _close_quietly

#: 16-bit samples at 16 kHz. A tenth of a second of silence per frame is enough
#: for the fake to count, and small enough that a test sends several.
FRAME = b"\x00\x00" * 1600


def _open(client: TestClient, session: dict[str, str], *, language: str = "en"):
    return client.websocket_connect(
        f"/api/v1/speech/stream?language={language}",
        headers={"Authorization": f"Bearer {session['access_token']}"},
    )


async def _register(client: AsyncClient, device_id: str) -> dict[str, str]:
    response = await client.post(
        "/api/v1/auth/devices",
        json={
            "device_id": device_id,
            "display_name": "Test phone",
            "platform": "android",
        },
    )
    assert response.status_code == 201, response.text
    return response.json()["data"]


class TestProtocolFrames:
    """Pure shape checks, so the wire format can be asserted without a server."""

    def test_a_partial_carries_only_the_text(self) -> None:
        assert partial_frame("the bakery") == {
            "type": "partial",
            "text": "the bakery",
        }

    def test_a_final_omits_confidence_when_there_is_none(self) -> None:
        assert final_frame("the bakery is closed") == {
            "type": "final",
            "text": "the bakery is closed",
        }

    def test_a_final_carries_confidence_when_there_is_some(self) -> None:
        assert final_frame("hello", confidence=0.9)["confidence"] == 0.9

    def test_an_error_names_a_code_a_client_can_switch_on(self) -> None:
        assert error_frame("SPEECH_UNAVAILABLE", "down") == {
            "type": "error",
            "code": "SPEECH_UNAVAILABLE",
            "message": "down",
        }

    @pytest.mark.parametrize(
        ("message", "expected"),
        [
            ({"type": "finalize"}, "finalize"),
            ({"type": "close"}, "close"),
            ({"type": "something-new"}, None),
            ({}, None),
            ("not an object", None),
            (None, None),
        ],
    )
    def test_unknown_controls_are_ignored_not_fatal(
        self, message: object, expected: str | None
    ) -> None:
        # A client from a later version must not be able to kill a session by
        # saying something this one has never heard of.
        assert read_control(message) == expected


class TestSpeechSocket:
    async def test_an_already_disconnected_socket_closes_quietly(self) -> None:
        websocket = AsyncMock()
        websocket.close.side_effect = WebSocketDisconnect(code=1006)

        await _close_quietly(websocket)

        websocket.close.assert_awaited_once_with()

    async def test_audio_in_produces_a_final_out(
        self, speech_app: TestClient, client: AsyncClient
    ) -> None:
        session = await _register(client, "device-relay-1")

        with _open(speech_app, session) as socket:
            for _ in range(4):
                socket.send_bytes(FRAME)
            socket.send_text(json.dumps({"type": "finalize"}))

            frames = [socket.receive_json() for _ in range(2)]

        assert frames[0]["type"] == "partial"
        assert frames[1]["type"] == "final"
        # The fake reports what it was given, so this proves the bytes arrived.
        assert "0.40 seconds of audio" in frames[1]["text"]

    async def test_the_language_reaches_the_provider(
        self, speech_app: TestClient, client: AsyncClient
    ) -> None:
        session = await _register(client, "device-relay-2")

        with _open(speech_app, session, language="sv") as socket:
            socket.send_text(json.dumps({"type": "finalize"}))
            final = socket.receive_json()

        assert final["text"].startswith("[sv]")

    async def test_a_socket_with_no_token_is_refused_before_it_opens(
        self, speech_app: TestClient
    ) -> None:
        with (
            pytest.raises(WebSocketDisconnect) as refusal,
            speech_app.websocket_connect(
                "/api/v1/speech/stream?language=en"
            ) as socket,
        ):
            socket.receive_json()

        assert refusal.value.code == CLOSE_UNAUTHENTICATED

    async def test_a_socket_with_a_bad_token_is_refused(
        self, speech_app: TestClient
    ) -> None:
        with (
            pytest.raises(WebSocketDisconnect) as refusal,
            speech_app.websocket_connect(
                "/api/v1/speech/stream?language=en",
                headers={"Authorization": "Bearer not-a-token"},
            ) as socket,
        ):
            socket.receive_json()

        assert refusal.value.code == CLOSE_UNAUTHENTICATED

    async def test_a_missing_language_is_rejected(
        self, speech_app: TestClient, client: AsyncClient
    ) -> None:
        session = await _register(client, "device-relay-3")

        with pytest.raises(WebSocketDisconnect), speech_app.websocket_connect(
            "/api/v1/speech/stream",
            headers={"Authorization": f"Bearer {session['access_token']}"},
        ) as socket:
            socket.receive_json()

    async def test_close_ends_the_session_without_a_final(
        self, speech_app: TestClient, client: AsyncClient
    ) -> None:
        session = await _register(client, "device-relay-4")

        with _open(speech_app, session) as socket:
            socket.send_bytes(FRAME)
            socket.send_text(json.dumps({"type": "close"}))
            # Abandoning an utterance must not produce a transcript of it.
            with pytest.raises(WebSocketDisconnect):
                while True:
                    frame = socket.receive_json()
                    assert frame["type"] != "final"

    async def test_a_frame_that_is_not_json_does_not_end_the_session(
        self, speech_app: TestClient, client: AsyncClient
    ) -> None:
        session = await _register(client, "device-relay-5")

        with _open(speech_app, session) as socket:
            socket.send_text("{not json")
            socket.send_text(json.dumps({"type": "finalize"}))

            assert socket.receive_json()["type"] == "final"


class TestSpeechRateLimit:
    async def test_too_many_sessions_are_refused_with_their_own_code(
        self, database_url: str
    ) -> None:
        from wordnest_api.core.config import (
            Environment,
            Settings,
            TranslationProviderName,
        )
        from wordnest_api.main import create_app

        settings = Settings(
            environment=Environment.test,
            translation_provider=TranslationProviderName.fake,
            database_url=database_url,
            speech_rate_limit_per_minute=1,
        )
        with TestClient(create_app(settings)) as app:
            async with AsyncClient(
                transport=__import__(
                    "httpx", fromlist=["ASGITransport"]
                ).ASGITransport(app=app.app),
                base_url="http://testserver",
            ) as http:
                session = await _register(http, "device-throttled")

            with _open(app, session) as socket:
                socket.send_text(json.dumps({"type": "close"}))

            with (
                pytest.raises(WebSocketDisconnect) as refusal,
                _open(app, session) as socket,
            ):
                socket.receive_json()

        assert refusal.value.code == CLOSE_RATE_LIMITED
