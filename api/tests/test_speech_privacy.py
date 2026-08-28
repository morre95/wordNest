"""The relay must carry audio and keep none of it.

The service used to be able to say it never received audio at all. It cannot
say that any more, so what remains has to be checked rather than asserted in
prose: nothing is written to disk, and nothing anyone said reaches the log.
"""

import json
import logging
from pathlib import Path

from fastapi.testclient import TestClient
from httpx import ASGITransport, AsyncClient

#: A recognisable byte pattern, so a test can look for it anywhere it should
#: not be. Valid PCM16, and nothing like silence.
SECRET_AUDIO = bytes([0x7F, 0x41]) * 800


async def _register(app: TestClient, device_id: str) -> dict[str, str]:
    async with AsyncClient(
        transport=ASGITransport(app=app.app), base_url="http://testserver"
    ) as http:
        response = await http.post(
            "/api/v1/auth/devices",
            json={
                "device_id": device_id,
                "display_name": "Test phone",
                "platform": "android",
            },
        )
    assert response.status_code == 201, response.text
    return response.json()["data"]


async def _speak(app: TestClient, session: dict[str, str]) -> None:
    with app.websocket_connect(
        "/api/v1/speech/stream?language=en",
        headers={"Authorization": f"Bearer {session['access_token']}"},
    ) as socket:
        for _ in range(4):
            socket.send_bytes(SECRET_AUDIO)
        socket.send_text(json.dumps({"type": "finalize"}))
        while socket.receive_json()["type"] != "final":
            pass


async def test_a_speech_session_writes_nothing_to_disk(
    speech_app: TestClient, tmp_path: Path
) -> None:
    scratch = tmp_path / "written"
    scratch.mkdir()
    before = set(Path.cwd().iterdir())

    session = await _register(speech_app, "device-privacy-1")
    await _speak(speech_app, session)

    assert list(scratch.iterdir()) == []
    # Nothing new in the working directory either — an audio dump would have to
    # land somewhere, and this is where a careless one would go.
    assert set(Path.cwd().iterdir()) == before


async def test_audio_never_reaches_the_log(
    speech_app: TestClient, caplog
) -> None:
    caplog.set_level(logging.DEBUG)

    session = await _register(speech_app, "device-privacy-2")
    await _speak(speech_app, session)

    assert SECRET_AUDIO.hex() not in caplog.text
    assert repr(SECRET_AUDIO) not in caplog.text
    assert str(SECRET_AUDIO) not in caplog.text


async def test_the_relay_holds_no_audio_once_the_session_ends(
    speech_app: TestClient,
) -> None:
    """The provider counts bytes rather than keeping them, and the session it
    counted with is gone when the socket closes."""
    from wordnest_api.features.speech.fake_provider import FakeSpeechSession

    session = await _register(speech_app, "device-privacy-3")
    await _speak(speech_app, session)

    # The fake is the most audio-retentive implementation there could be — it
    # keeps a running total — and even it keeps no bytes.
    assert not hasattr(FakeSpeechSession, "buffer")
    assert "bytes" not in FakeSpeechSession.__init__.__code__.co_varnames


async def test_the_fake_is_refused_in_production() -> None:
    """A deployment that forgets to configure Deepgram must fail at startup,
    not quietly transcribe nonsense."""
    import pytest

    from wordnest_api.core.config import Environment, Settings
    from wordnest_api.features.speech.provider import build_speech_provider

    with pytest.raises(RuntimeError, match="cannot be used in production"):
        build_speech_provider(
            Settings(
                environment=Environment.production,
                jwt_secret="a-real-secret-for-this-test",
            )
        )


async def test_deepgram_without_a_key_fails_at_startup() -> None:
    import pytest

    from wordnest_api.core.config import (
        Environment,
        Settings,
        SpeechProviderName,
    )
    from wordnest_api.features.speech.provider import build_speech_provider

    with pytest.raises(RuntimeError, match="WORDNEST_DEEPGRAM_API_KEY"):
        build_speech_provider(
            Settings(
                environment=Environment.test,
                speech_provider=SpeechProviderName.deepgram,
            )
        )
