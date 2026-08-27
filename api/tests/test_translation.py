"""The translation endpoint, against the deterministic fake provider."""

import pytest
from httpx import AsyncClient

TRANSLATIONS = "/api/v1/translations"


async def translate(client: AsyncClient, **overrides: object) -> object:
    body = {
        "source_text": "the bakery is closed",
        "source_language": "en",
        "target_language": "es",
    } | overrides
    return await client.post(TRANSLATIONS, json=body)


async def test_returns_a_translation_and_a_word_breakdown(
    client: AsyncClient,
) -> None:
    response = await translate(client)

    assert response.status_code == 200
    body = response.json()
    assert body["success"] is True
    data = body["data"]
    assert data["source_text"] == "the bakery is closed"
    assert data["source_language"] == "en"
    assert data["target_language"] == "es"
    assert data["translation"] == "[Spanish] the bakery is closed"
    assert [token["surface_form"] for token in data["tokens"]] == [
        "the",
        "bakery",
        "is",
        "closed",
    ]


async def test_marks_which_words_are_worth_learning(client: AsyncClient) -> None:
    response = await translate(client)

    tokens = response.json()["data"]["tokens"]
    content = [token["lemma"] for token in tokens if token["is_content_word"]]
    assert content == ["bakery", "closed"]


async def test_every_token_carries_the_fields_the_glossary_needs(
    client: AsyncClient,
) -> None:
    response = await translate(client)

    for token in response.json()["data"]["tokens"]:
        assert set(token) == {
            "surface_form",
            "lemma",
            "part_of_speech",
            "target_form",
            "is_content_word",
        }


async def test_reports_rate_limit_headroom_in_meta(client: AsyncClient) -> None:
    response = await translate(client)

    assert response.json()["meta"]["rate_limit_remaining"] == 59


async def test_language_tags_are_normalised(client: AsyncClient) -> None:
    response = await translate(client, source_language="EN", target_language="Es")

    assert response.status_code == 200
    assert response.json()["data"]["source_language"] == "en"


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("source_text", ""),
        ("source_text", "   "),
        ("source_text", "x" * 1001),
        ("source_language", "e"),
        ("source_language", "12"),
    ],
)
async def test_rejects_malformed_input_with_field_level_detail(
    client: AsyncClient, field: str, value: str
) -> None:
    response = await translate(client, **{field: value})

    assert response.status_code == 400
    body = response.json()
    assert body["success"] is False
    assert body["error"]["code"] == "VALIDATION_ERROR"
    assert field in body["error"]["details"]


async def test_rejects_a_language_it_cannot_translate(client: AsyncClient) -> None:
    response = await translate(client, target_language="zz")

    assert response.status_code == 422
    body = response.json()
    assert body["error"]["code"] == "UNSUPPORTED_LANGUAGE_PAIR"
    assert body["error"]["details"]["unsupported_languages"] == ["zz"]


async def test_rejects_translating_a_language_into_itself(
    client: AsyncClient,
) -> None:
    response = await translate(client, target_language="en")

    assert response.status_code == 422
    assert response.json()["error"]["code"] == "UNSUPPORTED_LANGUAGE_PAIR"


async def test_ignores_a_region_subtag_when_resolving_the_language(
    client: AsyncClient,
) -> None:
    response = await translate(client, source_language="en-GB")

    assert response.status_code == 200
    assert response.json()["data"]["translation"].startswith("[Spanish]")


async def test_an_unknown_route_returns_the_same_error_shape(
    client: AsyncClient,
) -> None:
    response = await client.get("/api/v1/nothing-here")

    assert response.status_code == 404
    body = response.json()
    assert body["success"] is False
    assert body["error"]["code"] == "NOT_FOUND"
