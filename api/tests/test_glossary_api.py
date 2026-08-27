"""Glossary read and update over HTTP.

The rule that matters most: a change made here has to be visible to sync. A
write that does not take a sequence number would sit in the database with a
number below every device's cursor and never be pulled.
"""

from datetime import timedelta

from httpx import AsyncClient

from .conftest import bearer, register
from .test_sync import MONDAY, entry, iso, occurrence, pull, push, rid, utterance

GLOSSARY = "/api/v1/glossary"


async def paired(client: AsyncClient) -> tuple[dict, dict]:
    """Two devices on one account, so sync visibility can be checked."""
    phone = await register(client, device_id="device-phone")
    code = (
        await client.post("/api/v1/auth/pairing-codes", headers=bearer(phone))
    ).json()["data"]["code"]
    tablet = await register(client, device_id="device-tablet")
    joined = (
        await client.post(
            "/api/v1/auth/pairing-codes/redeem",
            headers=bearer(tablet),
            json={"code": code},
        )
    ).json()["data"]
    return phone, joined


async def seed(client: AsyncClient, session: dict) -> None:
    """A small glossary: two words, one sentence, one sighting each."""
    await push(
        client,
        session,
        {
            "utterances": [utterance("u1", "the bakery is closed")],
            "glossary_entries": [
                entry("e-bakery", "bakery", target_form="panadería"),
                entry(
                    "e-harbour",
                    "harbour",
                    at=MONDAY + timedelta(hours=1),
                    target_form="puerto",
                ),
            ],
            "glossary_occurrences": [
                occurrence("o1", "e-bakery", "u1"),
                occurrence("o2", "e-harbour", "u1"),
            ],
        },
    )


class TestReading:
    async def test_lists_the_words_on_the_account(self, client: AsyncClient) -> None:
        phone, _ = await paired(client)
        await seed(client, phone)

        response = await client.get(GLOSSARY, headers=bearer(phone))

        assert response.status_code == 200
        body = response.json()
        assert {row["lemma"] for row in body["data"]["entries"]} == {
            "bakery",
            "harbour",
        }
        assert body["meta"]["pagination"]["total"] == 2
        assert body["meta"]["pagination"]["has_more"] is False

    async def test_search_matches_the_source_word(self, client: AsyncClient) -> None:
        phone, _ = await paired(client)
        await seed(client, phone)

        response = await client.get(
            GLOSSARY, headers=bearer(phone), params={"search": "bak"}
        )

        assert [row["lemma"] for row in response.json()["data"]["entries"]] == [
            "bakery"
        ]

    async def test_search_matches_the_target_form_too(
        self, client: AsyncClient
    ) -> None:
        # A reader may only remember the word from the other side.
        phone, _ = await paired(client)
        await seed(client, phone)

        response = await client.get(
            GLOSSARY, headers=bearer(phone), params={"search": "panad"}
        )

        assert [row["lemma"] for row in response.json()["data"]["entries"]] == [
            "bakery"
        ]

    async def test_filters_by_language_pair(self, client: AsyncClient) -> None:
        phone, _ = await paired(client)
        await seed(client, phone)

        matching = await client.get(
            GLOSSARY, headers=bearer(phone), params={"language_pair": "en-es"}
        )
        other = await client.get(
            GLOSSARY, headers=bearer(phone), params={"language_pair": "en-sv"}
        )

        assert len(matching.json()["data"]["entries"]) == 2
        assert other.json()["data"]["entries"] == []

    async def test_a_malformed_language_pair_is_refused(
        self, client: AsyncClient
    ) -> None:
        phone, _ = await paired(client)

        response = await client.get(
            GLOSSARY, headers=bearer(phone), params={"language_pair": "english"}
        )

        assert response.status_code == 422
        assert response.json()["error"]["code"] == "VALIDATION_ERROR"

    async def test_sorts_hardest_first(self, client: AsyncClient) -> None:
        phone, _ = await paired(client)
        await seed(client, phone)
        await client.patch(
            f"{GLOSSARY}/{rid('e-harbour')}",
            headers=bearer(phone),
            json={"is_flagged": True},
        )

        response = await client.get(
            GLOSSARY, headers=bearer(phone), params={"sort": "struggle"}
        )

        entries = response.json()["data"]["entries"]
        assert entries[0]["lemma"] == "harbour"

    async def test_pages_rather_than_returning_everything(
        self, client: AsyncClient
    ) -> None:
        phone, _ = await paired(client)
        await seed(client, phone)

        first = await client.get(GLOSSARY, headers=bearer(phone), params={"limit": 1})

        assert len(first.json()["data"]["entries"]) == 1
        assert first.json()["meta"]["pagination"]["has_more"] is True

    async def test_refuses_an_unbounded_page(self, client: AsyncClient) -> None:
        phone, _ = await paired(client)

        response = await client.get(
            GLOSSARY, headers=bearer(phone), params={"limit": 5000}
        )

        assert response.status_code == 400

    async def test_one_word_can_be_fetched_on_its_own(
        self, client: AsyncClient
    ) -> None:
        phone, _ = await paired(client)
        await seed(client, phone)

        response = await client.get(
            f"{GLOSSARY}/{rid('e-bakery')}", headers=bearer(phone)
        )

        assert response.status_code == 200
        assert response.json()["data"]["target_form"] == "panadería"

    async def test_another_accounts_word_is_indistinguishable_from_a_missing_one(
        self, client: AsyncClient
    ) -> None:
        phone, _ = await paired(client)
        await seed(client, phone)
        stranger = await register(client, device_id="device-stranger")

        response = await client.get(
            f"{GLOSSARY}/{rid('e-bakery')}", headers=bearer(stranger)
        )

        assert response.status_code == 404
        assert response.json()["error"]["code"] == "GLOSSARY_ENTRY_NOT_FOUND"

    async def test_reading_needs_a_session(self, client: AsyncClient) -> None:
        assert (await client.get(GLOSSARY)).status_code == 401


class TestUpdating:
    async def test_flagging_a_word_reaches_the_other_device(
        self, client: AsyncClient
    ) -> None:
        # The whole point of the endpoint taking a sequence number.
        phone, tablet = await paired(client)
        await seed(client, phone)
        seen = await pull(client, tablet)

        await client.patch(
            f"{GLOSSARY}/{rid('e-bakery')}",
            headers=bearer(phone),
            json={"is_flagged": True},
        )

        changed = await pull(client, tablet, cursor=seen["cursor"])
        flagged = [
            row
            for row in changed["changes"]["glossary_entries"]
            if row["lemma"] == "bakery"
        ]
        assert len(flagged) == 1
        assert flagged[0]["is_flagged"] is True

    async def test_setting_the_flag_to_what_it_already_is_changes_nothing(
        self, client: AsyncClient
    ) -> None:
        # Rewriting would burn a sequence number and wake every other device
        # for a change that is not one.
        phone, tablet = await paired(client)
        await seed(client, phone)
        seen = await pull(client, tablet)

        await client.patch(
            f"{GLOSSARY}/{rid('e-bakery')}",
            headers=bearer(phone),
            json={"is_flagged": False},
        )

        after = await pull(client, tablet, cursor=seen["cursor"])
        assert after["changes"]["glossary_entries"] == []

    async def test_scheduling_state_cannot_be_set_directly(
        self, client: AsyncClient
    ) -> None:
        # A client must not be able to write a schedule the algorithm never
        # produced. Extra fields are ignored, not applied.
        phone, _ = await paired(client)
        await seed(client, phone)

        response = await client.patch(
            f"{GLOSSARY}/{rid('e-bakery')}",
            headers=bearer(phone),
            json={"is_flagged": True, "interval_days": 9999, "ease_factor": 5.0},
        )

        assert response.status_code == 200
        assert response.json()["data"]["interval_days"] == 0
        assert response.json()["data"]["ease_factor"] == 2.5

    async def test_deleting_leaves_a_tombstone_the_other_device_sees(
        self, client: AsyncClient
    ) -> None:
        phone, tablet = await paired(client)
        await seed(client, phone)
        seen = await pull(client, tablet)

        response = await client.delete(
            f"{GLOSSARY}/{rid('e-bakery')}", headers=bearer(phone)
        )

        assert response.status_code == 204
        changed = await pull(client, tablet, cursor=seen["cursor"])
        removed = [
            row
            for row in changed["changes"]["glossary_entries"]
            if row["id"] == rid("e-bakery")
        ]
        assert removed[0]["deleted_at"] is not None

    async def test_a_deleted_word_reads_as_gone(self, client: AsyncClient) -> None:
        phone, _ = await paired(client)
        await seed(client, phone)
        await client.delete(f"{GLOSSARY}/{rid('e-bakery')}", headers=bearer(phone))

        listed = await client.get(GLOSSARY, headers=bearer(phone))
        fetched = await client.get(
            f"{GLOSSARY}/{rid('e-bakery')}", headers=bearer(phone)
        )

        assert [row["lemma"] for row in listed.json()["data"]["entries"]] == ["harbour"]
        assert fetched.status_code == 404

    async def test_cannot_change_another_accounts_word(
        self, client: AsyncClient
    ) -> None:
        phone, _ = await paired(client)
        await seed(client, phone)
        stranger = await register(client, device_id="device-stranger")

        response = await client.patch(
            f"{GLOSSARY}/{rid('e-bakery')}",
            headers=bearer(stranger),
            json={"is_flagged": True},
        )

        assert response.status_code == 404


class TestStatistics:
    async def test_an_empty_glossary_reports_zeroes(self, client: AsyncClient) -> None:
        phone, _ = await paired(client)

        response = await client.get(f"{GLOSSARY}/statistics", headers=bearer(phone))

        data = response.json()["data"]
        assert data["word_count"] == 0
        assert data["review_count"] == 0
        assert data["language_pairs"] == []
        assert data["first_spoken_at"] is None

    async def test_counts_words_sentences_and_pairs(self, client: AsyncClient) -> None:
        phone, _ = await paired(client)
        await seed(client, phone)

        data = (
            await client.get(f"{GLOSSARY}/statistics", headers=bearer(phone))
        ).json()["data"]

        assert data["word_count"] == 2
        assert data["utterance_count"] == 1
        assert data["language_pairs"] == ["en-es"]
        assert data["due_count"] == 2, "nothing reviewed yet is all due"

    async def test_counts_what_the_user_finds_hard(self, client: AsyncClient) -> None:
        phone, _ = await paired(client)
        await seed(client, phone)
        await client.patch(
            f"{GLOSSARY}/{rid('e-bakery')}",
            headers=bearer(phone),
            json={"is_flagged": True},
        )

        data = (
            await client.get(f"{GLOSSARY}/statistics", headers=bearer(phone))
        ).json()["data"]

        assert data["struggling_count"] == 1

    async def test_statistics_are_scoped_to_the_account(
        self, client: AsyncClient
    ) -> None:
        phone, _ = await paired(client)
        await seed(client, phone)
        stranger = await register(client, device_id="device-stranger")

        data = (
            await client.get(f"{GLOSSARY}/statistics", headers=bearer(stranger))
        ).json()["data"]

        assert data["word_count"] == 0


class TestTimestamps:
    async def test_every_timestamp_states_its_zone(self, client: AsyncClient) -> None:
        phone, _ = await paired(client)
        await push(
            client,
            phone,
            {
                "glossary_entries": [
                    entry(
                        "e1",
                        "bakery",
                        last_reviewed_at=iso(MONDAY),
                        interval_days=3,
                        due_at=iso(MONDAY + timedelta(days=3)),
                    )
                ]
            },
        )

        row = (await client.get(GLOSSARY, headers=bearer(phone))).json()["data"][
            "entries"
        ][0]

        for field in ("updated_at", "due_at", "last_reviewed_at"):
            assert row[field].endswith("Z") or "+00:00" in row[field], field
