"""Recording and reading reviews over HTTP.

A review is two things at once: an immutable event, and a change to a word's
schedule. The tests below check both, and check that this endpoint and a sync
push leave the account in the same state — otherwise a user who reviews on one
device and syncs from another gets two different schedules.
"""

from datetime import timedelta

from httpx import AsyncClient

from .conftest import bearer, register
from .test_sync import MONDAY, entry, iso, pull, push, rid

REVIEWS = "/api/v1/review-logs"
GLOSSARY = "/api/v1/glossary"

TUESDAY = MONDAY + timedelta(days=1)
WEDNESDAY = MONDAY + timedelta(days=2)


async def paired(client: AsyncClient) -> tuple[dict, dict]:
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
    await push(client, session, {"glossary_entries": [entry("e-bakery", "bakery")]})


def review_body(
    row_id: str = "r1",
    *,
    entry_id: str = "e-bakery",
    grade: int = 4,
    interval: int = 1,
    ease: float = 2.5,
    at=MONDAY,
) -> dict:
    return {
        "id": rid(row_id),
        "glossary_entry_id": rid(entry_id),
        "reviewed_at": iso(at),
        "grade": grade,
        "scheduled_interval_days": interval,
        "scheduled_ease_factor": ease,
    }


class TestRecording:
    async def test_records_the_review_and_moves_the_schedule_on(
        self, client: AsyncClient
    ) -> None:
        phone, _ = await paired(client)
        await seed(client, phone)

        response = await client.post(
            REVIEWS, headers=bearer(phone), json=review_body(interval=6)
        )

        assert response.status_code == 201
        data = response.json()["data"]
        assert data["applied"] is True
        assert data["entry_interval_days"] == 6
        assert data["entry_due_at"].startswith(iso(MONDAY + timedelta(days=6))[:10])

    async def test_the_due_date_is_derived_not_supplied(
        self, client: AsyncClient
    ) -> None:
        # A client cannot claim a due date the interval does not imply.
        phone, _ = await paired(client)
        await seed(client, phone)

        await client.post(
            REVIEWS,
            headers=bearer(phone),
            json=review_body(interval=10, at=TUESDAY),
        )

        row = (
            await client.get(f"{GLOSSARY}/{rid('e-bakery')}", headers=bearer(phone))
        ).json()["data"]
        assert row["due_at"].startswith(iso(TUESDAY + timedelta(days=10))[:10])

    async def test_a_retry_records_one_review_not_two(
        self, client: AsyncClient
    ) -> None:
        phone, _ = await paired(client)
        await seed(client, phone)
        body = review_body()

        first = await client.post(REVIEWS, headers=bearer(phone), json=body)
        second = await client.post(REVIEWS, headers=bearer(phone), json=body)

        assert first.json()["data"]["applied"] is True
        assert second.json()["data"]["applied"] is False
        listed = await client.get(REVIEWS, headers=bearer(phone))
        assert len(listed.json()["data"]["reviews"]) == 1

    async def test_a_lapse_restarts_the_streak(self, client: AsyncClient) -> None:
        phone, _ = await paired(client)
        await seed(client, phone)
        await client.post(REVIEWS, headers=bearer(phone), json=review_body("r1"))
        await client.post(
            REVIEWS, headers=bearer(phone), json=review_body("r2", at=TUESDAY)
        )

        await client.post(
            REVIEWS,
            headers=bearer(phone),
            json=review_body("r3", grade=1, interval=1, at=WEDNESDAY),
        )

        row = (
            await client.get(f"{GLOSSARY}/{rid('e-bakery')}", headers=bearer(phone))
        ).json()["data"]
        assert row["repetition_count"] == 0

    async def test_a_success_advances_the_streak(self, client: AsyncClient) -> None:
        phone, _ = await paired(client)
        await seed(client, phone)

        await client.post(REVIEWS, headers=bearer(phone), json=review_body("r1"))
        await client.post(
            REVIEWS, headers=bearer(phone), json=review_body("r2", at=TUESDAY)
        )

        row = (
            await client.get(f"{GLOSSARY}/{rid('e-bakery')}", headers=bearer(phone))
        ).json()["data"]
        assert row["repetition_count"] == 2

    async def test_an_older_review_is_kept_but_does_not_move_the_schedule_back(
        self, client: AsyncClient
    ) -> None:
        # A device that was offline sends a review from last week. It happened,
        # so it is recorded — but it must not undo a newer one.
        phone, _ = await paired(client)
        await seed(client, phone)
        await client.post(
            REVIEWS,
            headers=bearer(phone),
            json=review_body("r-new", interval=20, at=WEDNESDAY),
        )

        response = await client.post(
            REVIEWS,
            headers=bearer(phone),
            json=review_body("r-old", interval=1, at=MONDAY),
        )

        assert response.status_code == 201
        assert response.json()["data"]["applied"] is False
        assert response.json()["data"]["entry_interval_days"] == 20
        listed = await client.get(REVIEWS, headers=bearer(phone))
        assert len(listed.json()["data"]["reviews"]) == 2

    async def test_reviewing_a_word_that_is_not_there_is_refused(
        self, client: AsyncClient
    ) -> None:
        phone, _ = await paired(client)

        response = await client.post(REVIEWS, headers=bearer(phone), json=review_body())

        assert response.status_code == 404
        assert response.json()["error"]["code"] == "GLOSSARY_ENTRY_NOT_FOUND"

    async def test_cannot_review_another_accounts_word(
        self, client: AsyncClient
    ) -> None:
        phone, _ = await paired(client)
        await seed(client, phone)
        stranger = await register(client, device_id="device-stranger")

        response = await client.post(
            REVIEWS, headers=bearer(stranger), json=review_body()
        )

        assert response.status_code == 404

    async def test_a_grade_outside_the_scale_is_refused(
        self, client: AsyncClient
    ) -> None:
        phone, _ = await paired(client)
        await seed(client, phone)

        response = await client.post(
            REVIEWS, headers=bearer(phone), json=review_body(grade=9)
        )

        assert response.status_code == 400
        assert "grade" in response.json()["error"]["details"]

    async def test_an_ease_factor_below_the_floor_is_refused(
        self, client: AsyncClient
    ) -> None:
        phone, _ = await paired(client)
        await seed(client, phone)

        response = await client.post(
            REVIEWS, headers=bearer(phone), json=review_body(ease=0.5)
        )

        assert response.status_code == 400

    async def test_recording_needs_a_session(self, client: AsyncClient) -> None:
        assert (await client.post(REVIEWS, json=review_body())).status_code == 401


class TestReading:
    async def test_lists_reviews_oldest_first(self, client: AsyncClient) -> None:
        phone, _ = await paired(client)
        await seed(client, phone)
        for index, moment in enumerate([MONDAY, TUESDAY, WEDNESDAY]):
            await client.post(
                REVIEWS,
                headers=bearer(phone),
                json=review_body(f"r{index}", at=moment),
            )

        response = await client.get(REVIEWS, headers=bearer(phone))

        ids = [row["id"] for row in response.json()["data"]["reviews"]]
        assert ids == [rid("r0"), rid("r1"), rid("r2")]

    async def test_the_cursor_walks_forward_without_repeating(
        self, client: AsyncClient
    ) -> None:
        phone, _ = await paired(client)
        await seed(client, phone)
        for index in range(5):
            await client.post(
                REVIEWS,
                headers=bearer(phone),
                json=review_body(f"r{index}", at=MONDAY + timedelta(days=index)),
            )

        seen: list[str] = []
        cursor = 0
        for _ in range(10):
            page = await client.get(
                REVIEWS,
                headers=bearer(phone),
                params={"cursor": cursor, "limit": 2},
            )
            body = page.json()
            seen.extend(row["id"] for row in body["data"]["reviews"])
            cursor = body["meta"]["pagination"]["cursor"]
            if not body["meta"]["pagination"]["has_more"]:
                break

        assert len(seen) == 5
        assert len(set(seen)) == 5

    async def test_can_be_narrowed_to_one_word(self, client: AsyncClient) -> None:
        phone, _ = await paired(client)
        await push(
            client,
            phone,
            {
                "glossary_entries": [
                    entry("e-bakery", "bakery"),
                    entry("e-harbour", "harbour", at=TUESDAY),
                ]
            },
        )
        await client.post(REVIEWS, headers=bearer(phone), json=review_body("r1"))
        await client.post(
            REVIEWS,
            headers=bearer(phone),
            json=review_body("r2", entry_id="e-harbour"),
        )

        response = await client.get(
            REVIEWS,
            headers=bearer(phone),
            params={"glossary_entry_id": rid("e-harbour")},
        )

        assert [row["id"] for row in response.json()["data"]["reviews"]] == [rid("r2")]

    async def test_another_account_sees_none_of_them(self, client: AsyncClient) -> None:
        phone, _ = await paired(client)
        await seed(client, phone)
        await client.post(REVIEWS, headers=bearer(phone), json=review_body())
        stranger = await register(client, device_id="device-stranger")

        response = await client.get(REVIEWS, headers=bearer(stranger))

        assert response.json()["data"]["reviews"] == []

    async def test_refuses_an_unbounded_page(self, client: AsyncClient) -> None:
        phone, _ = await paired(client)

        response = await client.get(
            REVIEWS, headers=bearer(phone), params={"limit": 10000}
        )

        assert response.status_code == 400


class TestAgreementWithSync:
    async def test_a_review_recorded_here_reaches_the_other_device(
        self, client: AsyncClient
    ) -> None:
        phone, tablet = await paired(client)
        await seed(client, phone)
        seen = await pull(client, tablet)

        await client.post(REVIEWS, headers=bearer(phone), json=review_body(interval=6))

        changed = await pull(client, tablet, cursor=seen["cursor"])
        assert [row["id"] for row in changed["changes"]["review_logs"]] == [rid("r1")]
        entries = changed["changes"]["glossary_entries"]
        assert entries[0]["interval_days"] == 6
        assert entries[0]["last_reviewed_at"] is not None

    async def test_a_review_pushed_through_sync_is_visible_here(
        self, client: AsyncClient
    ) -> None:
        # The two paths have to agree, or a user who reviews on one device and
        # reads on another sees a different history.
        phone, tablet = await paired(client)
        await seed(client, phone)

        await push(
            client,
            tablet,
            {
                "review_logs": [
                    {
                        "id": rid("r-sync"),
                        "updated_at": iso(TUESDAY),
                        "glossary_entry_id": rid("e-bakery"),
                        "reviewed_at": iso(TUESDAY),
                        "grade": 5,
                        "scheduled_interval_days": 4,
                        "scheduled_ease_factor": 2.6,
                    }
                ]
            },
        )

        response = await client.get(REVIEWS, headers=bearer(phone))
        assert [row["id"] for row in response.json()["data"]["reviews"]] == [
            rid("r-sync")
        ]

    async def test_every_timestamp_states_its_zone(self, client: AsyncClient) -> None:
        phone, _ = await paired(client)
        await seed(client, phone)
        await client.post(REVIEWS, headers=bearer(phone), json=review_body())

        row = (await client.get(REVIEWS, headers=bearer(phone))).json()["data"][
            "reviews"
        ][0]

        for field in ("reviewed_at", "updated_at"):
            assert row[field].endswith("Z") or "+00:00" in row[field], field
