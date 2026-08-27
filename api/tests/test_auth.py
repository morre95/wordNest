"""Identity: silent registration, sessions, and joining two devices.

The case that matters most is at the end: a user who has been talking to the
app for a week and then signs in on a new phone must not lose that week.
"""

from datetime import UTC, datetime, timedelta

from httpx import AsyncClient

from .conftest import bearer, register

AUTH = "/api/v1/auth"
SYNC = "/api/v1/sync"


async def say(
    client: AsyncClient,
    session: dict[str, str],
    *,
    row_id: str,
    text: str,
    cursor: int = 0,
) -> dict:
    """Pushes one utterance, as the app does after a sentence is finalised."""
    now = datetime.now(UTC).isoformat()
    response = await client.post(
        SYNC,
        headers=bearer(session),
        json={
            "cursor": cursor,
            "changes": {
                "utterances": [
                    {
                        "id": row_id,
                        "updated_at": now,
                        "source_text": text,
                        "translation_text": f"[es] {text}",
                        "source_language": "en",
                        "target_language": "es",
                        "spoken_at": now,
                    }
                ]
            },
        },
    )
    assert response.status_code == 200, response.text
    return response.json()["data"]


class TestRegistration:
    async def test_first_launch_gets_a_session_with_no_user_input(
        self, client: AsyncClient
    ) -> None:
        session = await register(client, device_id="device-first-launch")

        assert session["access_token"]
        assert session["refresh_token"]
        assert session["account_id"]
        assert session["is_anonymous"] is True

    async def test_registering_twice_returns_the_same_account(
        self, client: AsyncClient
    ) -> None:
        # A retry after a dropped connection must not orphan the first account
        # and everything already in it.
        first = await register(client, device_id="device-retry")
        second = await register(client, device_id="device-retry")

        assert first["account_id"] == second["account_id"]

    async def test_two_installs_start_on_separate_accounts(
        self, client: AsyncClient
    ) -> None:
        one = await register(client, device_id="device-one")
        other = await register(client, device_id="device-two")

        assert one["account_id"] != other["account_id"]


class TestSessions:
    async def test_a_request_without_a_token_is_refused(
        self, client: AsyncClient
    ) -> None:
        response = await client.get(f"{AUTH}/devices")

        assert response.status_code == 401
        assert response.json()["error"]["code"] == "INVALID_CREDENTIALS"

    async def test_a_forged_token_is_refused(self, client: AsyncClient) -> None:
        response = await client.get(
            f"{AUTH}/devices", headers={"Authorization": "Bearer not.a.token"}
        )

        assert response.status_code == 401

    async def test_an_expired_token_says_so_specifically(
        self, client: AsyncClient, settings, device: dict[str, str]
    ) -> None:
        # The client's response differs: refresh, versus sign in again.
        from wordnest_api.features.auth.tokens import issue_access_token

        expired, _ = issue_access_token(
            account_id=device["account_id"],
            device_id=device["device_id"],
            secret=settings.jwt_secret,
            lifetime_minutes=-1,
            now=datetime.now(UTC) - timedelta(hours=2),
        )

        response = await client.get(
            f"{AUTH}/devices", headers={"Authorization": f"Bearer {expired}"}
        )

        assert response.status_code == 401
        assert response.json()["error"]["code"] == "SESSION_EXPIRED"

    async def test_refreshing_returns_a_new_pair(
        self, client: AsyncClient, device: dict[str, str]
    ) -> None:
        response = await client.post(
            f"{AUTH}/refresh", json={"refresh_token": device["refresh_token"]}
        )

        assert response.status_code == 200
        refreshed = response.json()["data"]
        assert refreshed["refresh_token"] != device["refresh_token"]
        assert refreshed["account_id"] == device["account_id"]

    async def test_a_refresh_token_used_twice_kills_the_session(
        self, client: AsyncClient, device: dict[str, str]
    ) -> None:
        # A second use means it was captured. Losing a session is better than
        # sharing one.
        await client.post(
            f"{AUTH}/refresh", json={"refresh_token": device["refresh_token"]}
        )

        response = await client.post(
            f"{AUTH}/refresh", json={"refresh_token": device["refresh_token"]}
        )

        assert response.status_code == 401
        assert "safety" in response.json()["error"]["message"]

    async def test_a_revoked_device_cannot_refresh(
        self, client: AsyncClient, device: dict[str, str]
    ) -> None:
        await client.delete(
            f"{AUTH}/devices/{device['device_id']}", headers=bearer(device)
        )

        response = await client.post(
            f"{AUTH}/refresh", json={"refresh_token": device["refresh_token"]}
        )

        assert response.status_code == 401


class TestDeviceList:
    async def test_lists_the_devices_on_the_account_and_marks_this_one(
        self, client: AsyncClient, device: dict[str, str]
    ) -> None:
        response = await client.get(f"{AUTH}/devices", headers=bearer(device))

        devices = response.json()["data"]["devices"]
        assert len(devices) == 1
        assert devices[0]["is_current"] is True

    async def test_cannot_revoke_a_device_on_another_account(
        self, client: AsyncClient, device: dict[str, str]
    ) -> None:
        stranger = await register(client, device_id="device-stranger")

        response = await client.delete(
            f"{AUTH}/devices/{stranger['device_id']}", headers=bearer(device)
        )

        assert response.status_code == 422


class TestPairing:
    async def test_a_second_device_joins_by_typing_a_code(
        self, client: AsyncClient, device: dict[str, str]
    ) -> None:
        code = (
            await client.post(f"{AUTH}/pairing-codes", headers=bearer(device))
        ).json()["data"]["code"]
        second = await register(client, device_id="device-second")

        response = await client.post(
            f"{AUTH}/pairing-codes/redeem",
            headers=bearer(second),
            json={"code": code},
        )

        assert response.status_code == 200
        assert response.json()["data"]["account_id"] == device["account_id"]

    async def test_a_wrong_code_is_refused(
        self, client: AsyncClient, device: dict[str, str]
    ) -> None:
        await client.post(f"{AUTH}/pairing-codes", headers=bearer(device))
        second = await register(client, device_id="device-second")

        response = await client.post(
            f"{AUTH}/pairing-codes/redeem",
            headers=bearer(second),
            json={"code": "000000"},
        )

        assert response.status_code == 400
        assert response.json()["error"]["code"] == "PAIRING_CODE_INVALID"

    async def test_a_code_is_single_use(
        self, client: AsyncClient, device: dict[str, str]
    ) -> None:
        code = (
            await client.post(f"{AUTH}/pairing-codes", headers=bearer(device))
        ).json()["data"]["code"]
        second = await register(client, device_id="device-second")
        third = await register(client, device_id="device-third")
        await client.post(
            f"{AUTH}/pairing-codes/redeem",
            headers=bearer(second),
            json={"code": code},
        )

        response = await client.post(
            f"{AUTH}/pairing-codes/redeem",
            headers=bearer(third),
            json={"code": code},
        )

        assert response.status_code == 400

    async def test_a_device_cannot_guess_its_way_in(
        self, client: AsyncClient, device: dict[str, str], settings
    ) -> None:
        await client.post(f"{AUTH}/pairing-codes", headers=bearer(device))
        guesser = await register(client, device_id="device-guesser")

        statuses = []
        for attempt in range(settings.pairing_redemptions_per_minute + 2):
            response = await client.post(
                f"{AUTH}/pairing-codes/redeem",
                headers=bearer(guesser),
                json={"code": f"{attempt:06d}"},
            )
            statuses.append(response.status_code)

        assert statuses[-1] == 429
        assert statuses[-1] != 400, "guessing must be capped, not merely wrong"

    async def test_one_devices_guessing_does_not_break_another_users_pairing(
        self, client: AsyncClient, device: dict[str, str], settings
    ) -> None:
        # A blind guesser names no code, so a wrong guess must not be counted
        # against every live code — that would let one attacker invalidate
        # everyone else's pairing at will.
        code = (
            await client.post(f"{AUTH}/pairing-codes", headers=bearer(device))
        ).json()["data"]["code"]
        guesser = await register(client, device_id="device-guesser")
        for attempt in range(settings.pairing_redemptions_per_minute):
            await client.post(
                f"{AUTH}/pairing-codes/redeem",
                headers=bearer(guesser),
                json={"code": f"{attempt:06d}"},
            )

        honest = await register(client, device_id="device-honest")
        response = await client.post(
            f"{AUTH}/pairing-codes/redeem",
            headers=bearer(honest),
            json={"code": code},
        )

        assert response.status_code == 200


class TestUpgradingAnAnonymousAccount:
    async def test_attaching_an_email_keeps_the_same_account(
        self, client: AsyncClient, device: dict[str, str]
    ) -> None:
        sent = await client.post(
            f"{AUTH}/magic-links",
            headers=bearer(device),
            json={"email": "learner@example.com"},
        )
        assert sent.status_code == 200
        token = _last_magic_link_token(client)

        response = await client.post(
            f"{AUTH}/magic-links/redeem",
            headers=bearer(device),
            json={"token": token},
        )

        assert response.status_code == 200
        upgraded = response.json()["data"]
        assert upgraded["account_id"] == device["account_id"]
        assert upgraded["is_anonymous"] is False

    async def test_a_week_of_talking_survives_signing_in_on_a_new_phone(
        self, client: AsyncClient
    ) -> None:
        # The case the specification calls out by name.
        old_phone = await register(client, device_id="device-old-phone")
        for index in range(5):
            await say(
                client,
                old_phone,
                row_id=f"utterance-week-{index:04d}-0000",
                text=f"sentence {index}",
            )
        await client.post(
            f"{AUTH}/magic-links",
            headers=bearer(old_phone),
            json={"email": "learner@example.com"},
        )
        await client.post(
            f"{AUTH}/magic-links/redeem",
            headers=bearer(old_phone),
            json={"token": _last_magic_link_token(client)},
        )

        # A brand new phone, with a sentence of its own said before signing in.
        new_phone = await register(client, device_id="device-new-phone")
        await say(client, new_phone, row_id="utterance-on-new-phone-0000", text="hello")
        await client.post(
            f"{AUTH}/magic-links",
            headers=bearer(new_phone),
            json={"email": "learner@example.com"},
        )
        joined = (
            await client.post(
                f"{AUTH}/magic-links/redeem",
                headers=bearer(new_phone),
                json={"token": _last_magic_link_token(client)},
            )
        ).json()["data"]

        assert joined["account_id"] == old_phone["account_id"]

        pulled = await client.post(
            SYNC, headers=bearer(joined), json={"cursor": 0, "changes": {}}
        )
        texts = {
            row["source_text"] for row in pulled.json()["data"]["changes"]["utterances"]
        }
        assert texts == {
            "sentence 0",
            "sentence 1",
            "sentence 2",
            "sentence 3",
            "sentence 4",
            "hello",
        }, "neither the week nor the new phone's own sentence may be lost"

    async def test_the_old_phone_keeps_working_after_the_merge(
        self, client: AsyncClient
    ) -> None:
        first = await register(client, device_id="device-first")
        second = await register(client, device_id="device-second")
        await client.post(
            f"{AUTH}/magic-links",
            headers=bearer(second),
            json={"email": "learner@example.com"},
        )
        await client.post(
            f"{AUTH}/magic-links/redeem",
            headers=bearer(second),
            json={"token": _last_magic_link_token(client)},
        )
        # `first` was the one merged away; its refresh token must still work.
        await client.post(
            f"{AUTH}/magic-links",
            headers=bearer(first),
            json={"email": "learner@example.com"},
        )
        await client.post(
            f"{AUTH}/magic-links/redeem",
            headers=bearer(first),
            json={"token": _last_magic_link_token(client)},
        )

        refreshed = await client.post(
            f"{AUTH}/refresh", json={"refresh_token": first["refresh_token"]}
        )

        assert refreshed.status_code == 200
        assert refreshed.json()["data"]["account_id"] == second["account_id"]

    async def test_asking_for_a_link_never_reveals_whether_the_email_is_known(
        self, client: AsyncClient, device: dict[str, str]
    ) -> None:
        response = await client.post(
            f"{AUTH}/magic-links",
            headers=bearer(device),
            json={"email": "stranger@example.com"},
        )

        assert response.json()["data"] == {
            "sent": True,
            "expires_at": response.json()["data"]["expires_at"],
        }

    async def test_a_link_is_single_use(
        self, client: AsyncClient, device: dict[str, str]
    ) -> None:
        await client.post(
            f"{AUTH}/magic-links",
            headers=bearer(device),
            json={"email": "learner@example.com"},
        )
        token = _last_magic_link_token(client)
        await client.post(
            f"{AUTH}/magic-links/redeem",
            headers=bearer(device),
            json={"token": token},
        )

        response = await client.post(
            f"{AUTH}/magic-links/redeem",
            headers=bearer(device),
            json={"token": token},
        )

        assert response.status_code == 401


def _last_magic_link_token(client: AsyncClient) -> str:
    """Reads the token out of the development email sender.

    A real provider would deliver it; the logging sender keeps it in memory so
    the whole upgrade flow is testable without one.
    """
    sender = client._transport.app.state.email_sender  # type: ignore[attr-defined]
    return sender.sent[-1][1]
