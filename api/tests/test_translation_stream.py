"""The streaming translation endpoint.

The contract a reader depends on: deltas concatenate into exactly the final
translation, `breakdown` carries the whole result, and `done` always arrives
last — including after an error, so there is one place to stop.
"""

import json

from httpx import ASGITransport, AsyncClient

from wordnest_api.core.config import (
    Environment,
    Settings,
    TranslationProviderName,
)
from wordnest_api.core.errors import TranslationUnavailableError
from wordnest_api.features.translation.events import format_event
from wordnest_api.main import create_app

STREAM = "/api/v1/translations/stream"


def parse_events(body: str) -> list[tuple[str, dict]]:
    """Reads the SSE wire format back into (event, data) pairs."""
    events = []
    for block in body.split("\n\n"):
        if not block.strip():
            continue
        name = None
        payload = None
        for line in block.splitlines():
            if line.startswith("event: "):
                name = line.removeprefix("event: ")
            elif line.startswith("data: "):
                payload = json.loads(line.removeprefix("data: "))
        assert name is not None
        events.append((name, payload or {}))
    return events


async def stream(client: AsyncClient, **overrides) -> list[tuple[str, dict]]:
    body = {
        "source_text": "the bakery is closed",
        "source_language": "en",
        "target_language": "es",
    } | overrides
    response = await client.post(STREAM, json=body)
    assert response.status_code == 200, response.text
    assert response.headers["content-type"].startswith("text/event-stream")
    return parse_events(response.text)


class TestTheWireFormat:
    def test_an_event_is_one_line_each_and_a_blank_line(self) -> None:
        rendered = format_event("delta", {"text": "hola"})

        assert rendered == 'event: delta\ndata: {"text":"hola"}\n\n'

    def test_a_newline_in_the_payload_cannot_break_the_framing(self) -> None:
        # A raw newline inside `data:` would end the message early and the rest
        # would be read as a new one.
        rendered = format_event("delta", {"text": "line one\nline two"})

        event_line, data_line, blank = rendered.splitlines()
        assert event_line == "event: delta"
        assert blank == ""
        assert "\\n" in data_line, "the newline must be escaped, not literal"

    def test_non_ascii_survives_unescaped(self) -> None:
        rendered = format_event("delta", {"text": "panadería"})

        assert "panadería" in rendered

    def test_an_event_with_no_payload_still_has_a_data_line(self) -> None:
        # A reader that splits on the blank line needs every message to have
        # the same shape.
        assert format_event("done") == "event: done\ndata: {}\n\n"


class TestStreaming:
    async def test_the_deltas_spell_out_the_translation(
        self, client: AsyncClient
    ) -> None:
        events = await stream(client)

        deltas = [data["text"] for name, data in events if name == "delta"]
        breakdown = next(data for name, data in events if name == "breakdown")
        assert "".join(deltas) == breakdown["translation"]
        assert len(deltas) > 1, "a stream of one chunk is not a stream"

    async def test_the_breakdown_carries_the_whole_result(
        self, client: AsyncClient
    ) -> None:
        events = await stream(client)

        breakdown = next(data for name, data in events if name == "breakdown")
        assert breakdown["source_text"] == "the bakery is closed"
        assert breakdown["source_language"] == "en"
        assert breakdown["target_language"] == "es"
        assert [token["surface_form"] for token in breakdown["tokens"]] == [
            "the",
            "bakery",
            "is",
            "closed",
        ]

    async def test_done_arrives_last_and_only_once(self, client: AsyncClient) -> None:
        events = await stream(client)

        names = [name for name, _ in events]
        assert names[-1] == "done"
        assert names.count("done") == 1

    async def test_the_breakdown_comes_after_every_delta(
        self, client: AsyncClient
    ) -> None:
        events = await stream(client)

        names = [name for name, _ in events]
        assert names.index("breakdown") > max(
            index for index, name in enumerate(names) if name == "delta"
        )


class TestRefusalsHappenBeforeTheStream:
    async def test_an_unsupported_pair_is_an_ordinary_error_not_an_event(
        self, client: AsyncClient
    ) -> None:
        # Once the status line is sent, a refusal can only be an event nobody
        # is obliged to read.
        response = await client.post(
            STREAM,
            json={
                "source_text": "hello",
                "source_language": "en",
                "target_language": "zz",
            },
        )

        assert response.status_code == 422
        assert response.json()["error"]["code"] == "UNSUPPORTED_LANGUAGE_PAIR"

    async def test_a_malformed_body_is_refused_the_same_way(
        self, client: AsyncClient
    ) -> None:
        response = await client.post(
            STREAM,
            json={
                "source_text": "",
                "source_language": "en",
                "target_language": "es",
            },
        )

        assert response.status_code == 400
        assert response.json()["error"]["code"] == "VALIDATION_ERROR"

    async def test_the_stream_is_rate_limited_like_the_plain_endpoint(
        self,
    ) -> None:
        settings = Settings(
            environment=Environment.test,
            translation_provider=TranslationProviderName.fake,
            translation_rate_limit_per_minute=1,
        )
        app = create_app(settings)
        body = {
            "source_text": "hello",
            "source_language": "en",
            "target_language": "es",
        }

        async with (
            AsyncClient(
                transport=ASGITransport(app=app), base_url="http://testserver"
            ) as client,
            app.router.lifespan_context(app),
        ):
            first = await client.post(STREAM, json=body)
            second = await client.post(STREAM, json=body)

        assert first.status_code == 200
        assert second.status_code == 429


class TestAProviderThatGivesUpMidStream:
    async def test_becomes_an_error_event_followed_by_done(self) -> None:
        class FailsAfterOneDelta:
            async def translate(self, **_: object) -> object:
                raise TranslationUnavailableError("down")

            async def stream_translate(self, **_: object):
                from wordnest_api.features.translation.provider import (
                    TranslationDelta,
                )

                yield TranslationDelta(text="la pan")
                raise TranslationUnavailableError("the model stopped")

        settings = Settings(
            environment=Environment.test,
            translation_provider=TranslationProviderName.fake,
        )
        app = create_app(settings)
        async with (
            AsyncClient(
                transport=ASGITransport(app=app), base_url="http://testserver"
            ) as client,
            app.router.lifespan_context(app),
        ):
            app.state.translation_provider = FailsAfterOneDelta()
            response = await client.post(
                STREAM,
                json={
                    "source_text": "the bakery is closed",
                    "source_language": "en",
                    "target_language": "es",
                },
            )

        events = parse_events(response.text)
        names = [name for name, _ in events]
        assert names == ["delta", "error", "done"], (
            "a stream that simply stops leaves a reader waiting forever"
        )
        error = next(data for name, data in events if name == "error")
        assert error["code"] == "TRANSLATION_UNAVAILABLE"
