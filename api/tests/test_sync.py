"""Delta sync end to end, with two devices on one account.

The scenario throughout is the real one: two installs sharing an account, both
going offline, diverging, and reconciling.
"""

from datetime import UTC, datetime, timedelta

from httpx import AsyncClient

from .conftest import bearer, register

AUTH = "/api/v1/auth"
SYNC = "/api/v1/sync"

MONDAY = datetime(2026, 3, 2, 9, 0, tzinfo=UTC)


def iso(moment: datetime) -> str:
    return moment.isoformat()


def rid(name: str) -> str:
    """Pads a readable test id out to the length a real UUIDv7 has.

    The wire schema requires at least 8 characters, which is a sanity guard
    against a client sending something that is not an id at all.
    """
    return f"{name}-000000000000"


def utterance(row_id: str, text: str, *, at: datetime = MONDAY) -> dict:
    return {
        "id": rid(row_id),
        "updated_at": iso(at),
        "source_text": text,
        "translation_text": f"[es] {text}",
        "source_language": "en",
        "target_language": "es",
        "spoken_at": iso(at),
    }


def entry(row_id: str, lemma: str, *, at: datetime = MONDAY, **extra) -> dict:
    return {
        "id": rid(row_id),
        "updated_at": iso(at),
        "lemma": lemma,
        "surface_form": lemma,
        "source_language": "en",
        "target_language": "es",
    } | extra


def occurrence(row_id: str, entry_id: str, utterance_id: str, *, at=MONDAY) -> dict:
    return {
        "id": rid(row_id),
        "updated_at": iso(at),
        "glossary_entry_id": rid(entry_id),
        "utterance_id": rid(utterance_id),
        "surface_form": "bakery",
    }


def review(row_id: str, entry_id: str, *, grade: int = 4, at=MONDAY) -> dict:
    return {
        "id": rid(row_id),
        "updated_at": iso(at),
        "glossary_entry_id": rid(entry_id),
        "reviewed_at": iso(at),
        "grade": grade,
        "scheduled_interval_days": 1,
        "scheduled_ease_factor": 2.5,
    }


async def push(
    client: AsyncClient, session: dict, changes: dict, *, cursor: int = 0
) -> dict:
    response = await client.post(
        SYNC,
        headers=bearer(session),
        json={"cursor": cursor, "changes": changes},
    )
    assert response.status_code == 200, response.text
    return response.json()["data"]


async def pull(client: AsyncClient, session: dict, *, cursor: int = 0) -> dict:
    return await push(client, session, {}, cursor=cursor)


async def paired_devices(client: AsyncClient) -> tuple[dict, dict]:
    """Two installs on one account, as pairing produces."""
    first = await register(client, device_id="device-phone", display_name="Phone")
    code = (await client.post(f"{AUTH}/pairing-codes", headers=bearer(first))).json()[
        "data"
    ]["code"]
    second = await register(client, device_id="device-tablet", display_name="Tablet")
    joined = (
        await client.post(
            f"{AUTH}/pairing-codes/redeem",
            headers=bearer(second),
            json={"code": code},
        )
    ).json()["data"]
    return first, joined


class TestTheCursor:
    async def test_a_fresh_device_pulls_everything_from_zero(
        self, client: AsyncClient
    ) -> None:
        phone, tablet = await paired_devices(client)
        await push(client, phone, {"utterances": [utterance("u1", "hello")]})

        pulled = await pull(client, tablet, cursor=0)

        assert [row["source_text"] for row in pulled["changes"]["utterances"]] == [
            "hello"
        ]
        assert pulled["cursor"] > 0

    async def test_syncing_again_with_the_returned_cursor_pulls_nothing(
        self, client: AsyncClient
    ) -> None:
        phone, tablet = await paired_devices(client)
        await push(client, phone, {"utterances": [utterance("u1", "hello")]})
        first = await pull(client, tablet)

        second = await pull(client, tablet, cursor=first["cursor"])

        assert second["changes"]["utterances"] == []
        assert second["cursor"] == first["cursor"]

    async def test_the_cursor_is_a_sequence_number_not_a_timestamp(
        self, client: AsyncClient
    ) -> None:
        # Two rows written in the same millisecond still get distinct numbers,
        # which is exactly what a wall clock cannot promise.
        phone, tablet = await paired_devices(client)
        await push(
            client,
            phone,
            {
                "utterances": [
                    utterance("u1", "one", at=MONDAY),
                    utterance("u2", "two", at=MONDAY),
                ]
            },
        )

        first_page = await pull(client, tablet)
        assert len(first_page["changes"]["utterances"]) == 2
        assert first_page["cursor"] == 2

    async def test_a_row_written_during_a_pull_is_not_stepped_over(
        self, client: AsyncClient
    ) -> None:
        # The cursor returned is the highest sequence actually handed over, not
        # "now", so nothing can slip into the gap.
        phone, tablet = await paired_devices(client)
        await push(client, phone, {"utterances": [utterance("u1", "one")]})
        pulled = await pull(client, tablet)

        await push(client, phone, {"utterances": [utterance("u2", "two")]})
        later = await pull(client, tablet, cursor=pulled["cursor"])

        assert [row["id"] for row in later["changes"]["utterances"]] == [rid("u2")]


class TestIdempotence:
    async def test_the_same_push_twice_creates_one_row(
        self, client: AsyncClient
    ) -> None:
        phone, tablet = await paired_devices(client)
        payload = {"utterances": [utterance("u1", "hello")]}

        await push(client, phone, payload)
        await push(client, phone, payload)

        pulled = await pull(client, tablet)
        assert len(pulled["changes"]["utterances"]) == 1

    async def test_a_retried_review_is_not_recorded_twice(
        self, client: AsyncClient
    ) -> None:
        phone, tablet = await paired_devices(client)
        await push(
            client,
            phone,
            {"glossary_entries": [entry("e1", "bakery")]},
        )
        payload = {"review_logs": [review("r1", "e1")]}

        await push(client, phone, payload)
        await push(client, phone, payload)

        pulled = await pull(client, tablet)
        assert len(pulled["changes"]["review_logs"]) == 1


class TestPaging:
    async def test_a_large_backlog_arrives_in_pages(
        self, client: AsyncClient, settings
    ) -> None:
        settings.sync_batch_limit = 10
        phone, tablet = await paired_devices(client)
        await push(
            client,
            phone,
            {
                "utterances": [
                    utterance(f"u{index}", f"sentence {index}") for index in range(25)
                ]
            },
        )

        seen: list[str] = []
        cursor = 0
        for _ in range(10):
            page = await pull(client, tablet, cursor=cursor)
            seen.extend(row["id"] for row in page["changes"]["utterances"])
            cursor = page["cursor"]
            if not page["has_more"]:
                break

        assert len(seen) == 25
        assert len(set(seen)) == 25, "no row may arrive twice"

    async def test_has_more_says_when_to_sync_again_straight_away(
        self, client: AsyncClient, settings
    ) -> None:
        settings.sync_batch_limit = 2
        phone, tablet = await paired_devices(client)
        await push(
            client,
            phone,
            {"utterances": [utterance(f"u{i}", f"s{i}") for i in range(5)]},
        )

        page = await pull(client, tablet)

        assert page["has_more"] is True


class TestOwnership:
    async def test_another_account_cannot_see_your_rows(
        self, client: AsyncClient
    ) -> None:
        mine = await register(client, device_id="device-mine")
        theirs = await register(client, device_id="device-theirs")
        await push(client, mine, {"utterances": [utterance("u1", "private")]})

        pulled = await pull(client, theirs)

        assert pulled["changes"]["utterances"] == []

    async def test_another_device_cannot_rewrite_your_utterance(
        self, client: AsyncClient
    ) -> None:
        phone, tablet = await paired_devices(client)
        await push(client, phone, {"utterances": [utterance("u1", "mine")]})

        result = await push(
            client,
            tablet,
            {
                "utterances": [
                    utterance("u1", "rewritten", at=MONDAY + timedelta(days=1))
                ]
            },
        )

        assert [rejection["code"] for rejection in result["rejected"]] == [
            "NOT_YOUR_UTTERANCE"
        ]
        pulled = await pull(client, phone)
        assert pulled["changes"]["utterances"][0]["source_text"] == "mine"

    async def test_one_bad_row_does_not_stop_the_good_ones(
        self, client: AsyncClient
    ) -> None:
        phone, tablet = await paired_devices(client)
        await push(client, phone, {"utterances": [utterance("u1", "mine")]})

        result = await push(
            client,
            tablet,
            {
                "utterances": [
                    utterance("u1", "rewritten", at=MONDAY + timedelta(days=1)),
                    utterance("u2", "the tablet's own sentence"),
                ]
            },
        )

        assert result["applied"] == 1
        assert len(result["rejected"]) == 1


class TestTwoDevicesDiverging:
    async def test_the_same_word_learned_independently_becomes_one_entry(
        self, client: AsyncClient
    ) -> None:
        # Both were offline; both generated their own id for "bakery".
        phone, tablet = await paired_devices(client)
        await push(
            client,
            phone,
            {
                "utterances": [utterance("u-phone", "the bakery")],
                "glossary_entries": [entry("e-phone", "bakery")],
                "glossary_occurrences": [occurrence("o-phone", "e-phone", "u-phone")],
            },
        )

        await push(
            client,
            tablet,
            {
                "utterances": [utterance("u-tablet", "which bakery")],
                "glossary_entries": [
                    entry("e-tablet", "bakery", at=MONDAY + timedelta(hours=1))
                ],
                "glossary_occurrences": [occurrence("o-tablet", "e-phone", "u-tablet")],
            },
        )

        pulled = await pull(client, tablet)
        entries = pulled["changes"]["glossary_entries"]
        assert len(entries) == 1, "one word is one row"
        assert entries[0]["seen_count"] == 2, "counted from both sightings"

    async def test_a_review_on_one_and_an_edit_on_the_other_both_survive(
        self, client: AsyncClient
    ) -> None:
        phone, tablet = await paired_devices(client)
        await push(client, phone, {"glossary_entries": [entry("e1", "bakery")]})

        tuesday = MONDAY + timedelta(days=1)
        wednesday = MONDAY + timedelta(days=2)
        await push(
            client,
            phone,
            {
                "glossary_entries": [
                    entry(
                        "e1",
                        "bakery",
                        at=tuesday,
                        last_reviewed_at=iso(tuesday),
                        interval_days=6,
                        ease_factor=2.6,
                        repetition_count=2,
                    )
                ]
            },
        )
        await push(
            client,
            tablet,
            {
                "glossary_entries": [
                    entry("e1", "bakery", at=wednesday, is_flagged=True)
                ]
            },
        )

        merged = (await pull(client, phone))["changes"]["glossary_entries"][0]
        assert merged["is_flagged"] is True, "the tablet's edit survives"
        assert merged["interval_days"] == 6, "the phone's review survives"
        assert merged["due_at"].startswith(iso(tuesday + timedelta(days=6))[:10]), (
            "the due date follows the winning schedule"
        )

    async def test_both_devices_reviewing_offline_both_contribute(
        self, client: AsyncClient
    ) -> None:
        phone, tablet = await paired_devices(client)
        await push(client, phone, {"glossary_entries": [entry("e1", "bakery")]})

        await push(client, phone, {"review_logs": [review("r-phone", "e1")]})
        await push(client, tablet, {"review_logs": [review("r-tablet", "e1")]})

        logs = (await pull(client, phone))["changes"]["review_logs"]
        assert {log["id"] for log in logs} == {rid("r-phone"), rid("r-tablet")}

    async def test_a_deletion_racing_an_update_settles_the_same_way_both_ways(
        self, client: AsyncClient
    ) -> None:
        phone, tablet = await paired_devices(client)
        await push(client, phone, {"glossary_entries": [entry("e1", "bakery")]})

        tuesday = MONDAY + timedelta(days=1)
        wednesday = MONDAY + timedelta(days=2)
        await push(
            client,
            tablet,
            {"glossary_entries": [entry("e1", "bakery", at=tuesday, is_flagged=True)]},
        )
        await push(
            client,
            phone,
            {
                "glossary_entries": [
                    entry("e1", "bakery", at=wednesday, deleted_at=iso(wednesday))
                ]
            },
        )

        from_phone = (await pull(client, phone))["changes"]["glossary_entries"][0]
        from_tablet = (await pull(client, tablet))["changes"]["glossary_entries"][0]
        assert from_phone["deleted_at"] is not None
        assert from_phone["deleted_at"] == from_tablet["deleted_at"]

    async def test_a_device_back_after_a_fortnight_converges(
        self, client: AsyncClient
    ) -> None:
        phone, tablet = await paired_devices(client)

        # The phone kept working for two weeks.
        for day in range(14):
            await push(
                client,
                phone,
                {
                    "utterances": [
                        utterance(
                            f"u-phone-{day}",
                            f"day {day}",
                            at=MONDAY + timedelta(days=day),
                        )
                    ]
                },
            )

        # The tablet was off, and comes back with its own backlog.
        tablet_backlog = {
            "utterances": [
                utterance(
                    f"u-tablet-{day}",
                    f"tablet day {day}",
                    at=MONDAY + timedelta(days=day),
                )
                for day in range(14)
            ]
        }
        await push(client, tablet, tablet_backlog)

        on_phone = await pull(client, phone)
        on_tablet = await pull(client, tablet)

        phone_ids = {row["id"] for row in on_phone["changes"]["utterances"]}
        tablet_ids = {row["id"] for row in on_tablet["changes"]["utterances"]}
        assert len(phone_ids) == 28
        assert phone_ids == tablet_ids, "both devices end up holding everything"

    async def test_a_dropped_connection_mid_batch_loses_nothing_on_retry(
        self, client: AsyncClient
    ) -> None:
        phone, tablet = await paired_devices(client)
        batch = {
            "utterances": [utterance(f"u{i}", f"s{i}") for i in range(5)],
            "glossary_entries": [entry("e1", "bakery")],
        }

        await push(client, phone, batch)
        # The client never saw the response, so it sends the same batch again.
        retried = await push(client, phone, batch)

        assert retried["applied"] == 0, "nothing changed, so nothing was written"
        pulled = await pull(client, tablet)
        assert len(pulled["changes"]["utterances"]) == 5
        assert len(pulled["changes"]["glossary_entries"]) == 1


class TestValidation:
    async def test_a_malformed_row_is_refused_with_field_detail(
        self, client: AsyncClient, device: dict
    ) -> None:
        response = await client.post(
            SYNC,
            headers=bearer(device),
            json={
                "cursor": 0,
                "changes": {
                    "review_logs": [
                        {
                            "id": rid("r1"),
                            "updated_at": iso(MONDAY),
                            "glossary_entry_id": rid("e1"),
                            "reviewed_at": iso(MONDAY),
                            "grade": 99,
                        }
                    ]
                },
            },
        )

        assert response.status_code == 400
        assert response.json()["error"]["code"] == "VALIDATION_ERROR"

    async def test_syncing_needs_a_session(self, client: AsyncClient) -> None:
        response = await client.post(SYNC, json={"cursor": 0, "changes": {}})

        assert response.status_code == 401

    async def test_a_negative_cursor_is_refused(
        self, client: AsyncClient, device: dict
    ) -> None:
        response = await client.post(
            SYNC, headers=bearer(device), json={"cursor": -1, "changes": {}}
        )

        assert response.status_code == 400


class TestTimestampsOnTheWire:
    """A timestamp with no zone is read in the reader's zone.

    SQLite has no time zone type, so a row read back from it is naive. If it
    were serialised as-is, a client an hour or two off UTC would parse it as a
    different instant — enough to lose a last-write-wins comparison and drop a
    change the user actually made.
    """

    async def test_every_timestamp_states_its_zone(self, client: AsyncClient) -> None:
        phone, tablet = await paired_devices(client)
        await push(
            client,
            phone,
            {
                "utterances": [utterance("u1", "hello")],
                "glossary_entries": [
                    entry(
                        "e1",
                        "bakery",
                        last_reviewed_at=iso(MONDAY),
                        interval_days=3,
                    )
                ],
            },
        )

        pulled = await pull(client, tablet)

        stamps = [
            pulled["changes"]["utterances"][0]["updated_at"],
            pulled["changes"]["utterances"][0]["spoken_at"],
            pulled["changes"]["glossary_entries"][0]["updated_at"],
            pulled["changes"]["glossary_entries"][0]["due_at"],
        ]
        for stamp in stamps:
            assert stamp.endswith("Z") or "+00:00" in stamp, stamp

    async def test_a_session_expiry_states_its_zone(self, client: AsyncClient) -> None:
        session = await register(client, device_id="device-zoned")

        assert session["expires_at"].endswith("Z") or (
            "+00:00" in session["expires_at"]
        )
