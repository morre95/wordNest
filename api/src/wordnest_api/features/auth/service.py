"""Identity: registering a device, keeping it signed in, and joining accounts.

The shape of it: every install registers and immediately gets an account of its
own, anonymous, with no user-visible step. Syncing and backup work from that
moment. A second device is brought in by *merging* accounts — never by
replacing one — because the first device may have a week of talking in it.
"""

import logging
from datetime import UTC, datetime, timedelta

from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from ...core.config import Settings
from ...core.db.models import (
    Account,
    Device,
    GlossaryEntry,
    GlossaryOccurrence,
    MagicLinkToken,
    PairingCode,
    RefreshToken,
    ReviewLog,
    SequenceCounter,
    Utterance,
)
from ...core.errors import ValidationError, WordNestError
from ...core.ids import new_id
from .email_sender import EmailSender
from .schemas import TokenPair
from .tokens import (
    InvalidCredentialsError,
    SessionExpiredError,
    constant_time_equals,
    hash_secret,
    issue_access_token,
    new_magic_link_token,
    new_pairing_code,
    new_refresh_token,
)

logger = logging.getLogger(__name__)

#: Every table whose rows belong to an account and therefore move when two
#: accounts are merged. Missing one here would silently lose data, so the list
#: lives in one place and the merge iterates it.
ACCOUNT_OWNED_TABLES = (
    Utterance,
    GlossaryEntry,
    GlossaryOccurrence,
    ReviewLog,
)


class PairingCodeInvalidError(WordNestError):
    status_code = 400
    code = "PAIRING_CODE_INVALID"


class DeviceRevokedError(WordNestError):
    status_code = 401
    code = "DEVICE_REVOKED"


class AuthService:
    def __init__(
        self,
        session: AsyncSession,
        settings: Settings,
        email_sender: EmailSender,
    ) -> None:
        self._session = session
        self._settings = settings
        self._email = email_sender

    def _now(self) -> datetime:
        return datetime.now(UTC)

    # --- Registration and sessions -----------------------------------------

    async def register_device(
        self, *, device_id: str, display_name: str, platform: str
    ) -> TokenPair:
        """First launch: an account and a device, created silently.

        Idempotent on `device_id`, so a retry after a dropped connection
        re-issues tokens for the same device instead of orphaning the first one
        and its account.
        """
        existing = await self._session.get(Device, device_id)
        if existing is not None:
            if not existing.is_active:
                raise DeviceRevokedError("This device has been signed out.")
            return await self._issue_session(existing)

        account = Account(id=new_id())
        self._session.add(account)
        self._session.add(SequenceCounter(account_id=account.id, value=0))
        device = Device(
            id=device_id,
            account_id=account.id,
            display_name=display_name,
            platform=platform,
            last_seen_at=self._now(),
        )
        self._session.add(device)
        await self._session.flush()
        return await self._issue_session(device)

    async def refresh_session(self, *, refresh_token: str) -> TokenPair:
        """Exchanges a refresh token for a new pair, rotating it.

        Rotation means a token is good exactly once. A second use of an already
        used token means it was captured, so every token for that device is
        revoked and the user has to sign in again — losing a session is better
        than sharing one.
        """
        token_hash = hash_secret(refresh_token)
        stored = (
            await self._session.execute(
                select(RefreshToken).where(RefreshToken.token_hash == token_hash)
            )
        ).scalar_one_or_none()

        if stored is None or not constant_time_equals(stored.token_hash, token_hash):
            raise InvalidCredentialsError("This refresh token is not valid.")
        if stored.revoked_at is not None:
            raise InvalidCredentialsError("This session has been signed out.")
        if stored.used_at is not None:
            await self._revoke_device_tokens(stored.device_id)
            logger.warning(
                "Refresh token reuse detected for device %s; all its tokens revoked",
                stored.device_id,
            )
            raise InvalidCredentialsError(
                "This session has been signed out for your safety."
            )
        if _as_utc(stored.expires_at) <= self._now():
            raise SessionExpiredError("This session has expired.")

        device = await self._session.get(Device, stored.device_id)
        if device is None or not device.is_active:
            raise DeviceRevokedError("This device has been signed out.")

        stored.used_at = self._now()
        return await self._issue_session(device)

    async def _issue_session(self, device: Device) -> TokenPair:
        now = self._now()
        device.last_seen_at = now

        account = await self._session.get(Account, device.account_id)
        if account is None:
            raise InvalidCredentialsError("This device has no account.")

        # An account that was merged away hands its devices to the survivor,
        # so a device that synced before the merge keeps working afterwards.
        if account.merged_into_account_id is not None:
            device.account_id = account.merged_into_account_id
            account = await self._session.get(Account, account.merged_into_account_id)
            if account is None:
                raise InvalidCredentialsError("This account no longer exists.")

        access_token, expires_at = issue_access_token(
            account_id=account.id,
            device_id=device.id,
            secret=self._settings.jwt_secret,
            lifetime_minutes=self._settings.access_token_lifetime_minutes,
            now=now,
        )
        refresh = new_refresh_token()
        self._session.add(
            RefreshToken(
                id=new_id(),
                device_id=device.id,
                token_hash=hash_secret(refresh),
                expires_at=now
                + timedelta(days=self._settings.refresh_token_lifetime_days),
            )
        )
        await self._session.flush()

        return TokenPair(
            access_token=access_token,
            refresh_token=refresh,
            expires_at=expires_at,
            account_id=account.id,
            device_id=device.id,
            is_anonymous=account.is_anonymous,
        )

    async def _revoke_device_tokens(self, device_id: str) -> None:
        await self._session.execute(
            update(RefreshToken)
            .where(
                RefreshToken.device_id == device_id,
                RefreshToken.revoked_at.is_(None),
            )
            .values(revoked_at=self._now())
        )

    # --- Devices ------------------------------------------------------------

    async def list_devices(self, *, account_id: str) -> list[Device]:
        result = await self._session.execute(
            select(Device)
            .where(Device.account_id == account_id)
            .order_by(Device.created_at)
        )
        return list(result.scalars())

    async def revoke_device(self, *, account_id: str, device_id: str) -> None:
        device = await self._session.get(Device, device_id)
        if device is None or device.account_id != account_id:
            raise ValidationError("That device is not on this account.")
        device.revoked_at = self._now()
        await self._revoke_device_tokens(device_id)

    # --- Bringing in a second device ---------------------------------------

    async def create_pairing_code(self, *, account_id: str) -> tuple[str, datetime]:
        code = new_pairing_code()
        expires_at = self._now() + timedelta(
            minutes=self._settings.pairing_code_lifetime_minutes
        )
        self._session.add(
            PairingCode(
                id=new_id(),
                account_id=account_id,
                code_hash=hash_secret(code),
                expires_at=expires_at,
            )
        )
        await self._session.flush()
        return code, expires_at

    async def redeem_pairing_code(self, *, code: str, device_id: str) -> TokenPair:
        """Joins the device that typed the code onto the account that showed it.

        The typing device's own anonymous account is merged in rather than
        abandoned: it may already have sentences of its own from before the
        user thought to pair.
        """
        now = self._now()
        pairing = (
            await self._session.execute(
                select(PairingCode)
                .where(
                    PairingCode.code_hash == hash_secret(code),
                    PairingCode.consumed_at.is_(None),
                )
                .order_by(PairingCode.created_at.desc())
                .limit(1)
            )
        ).scalar_one_or_none()

        if pairing is None:
            # How fast a device may reach this line is capped by the rate
            # limiter on the route; see the note on [PairingCode].
            raise PairingCodeInvalidError("That code is not valid.")
        if _as_utc(pairing.expires_at) <= now:
            raise PairingCodeInvalidError("That code has expired. Ask for a new one.")

        device = await self._session.get(Device, device_id)
        if device is None:
            raise ValidationError("Register this device before pairing it.")
        if not device.is_active:
            raise DeviceRevokedError("This device has been signed out.")

        pairing.consumed_at = now
        await self._merge_accounts(
            source_account_id=device.account_id,
            target_account_id=pairing.account_id,
        )
        device.account_id = pairing.account_id
        await self._session.flush()
        return await self._issue_session(device)

    # --- Attaching a durable identity ---------------------------------------

    async def request_magic_link(self, *, email: str, account_id: str) -> datetime:
        """Starts attaching [email] to [account_id].

        Nothing is decided here: the account is not touched until the link is
        redeemed, so an unverified address never gains access to anything.
        """
        token = new_magic_link_token()
        expires_at = self._now() + timedelta(
            minutes=self._settings.magic_link_lifetime_minutes
        )
        self._session.add(
            MagicLinkToken(
                id=new_id(),
                email=email.lower(),
                account_id=account_id,
                token_hash=hash_secret(token),
                expires_at=expires_at,
            )
        )
        await self._session.flush()
        await self._email.send_magic_link(email=email, token=token)
        return expires_at

    async def redeem_magic_link(self, *, token: str, device_id: str) -> TokenPair:
        """Attaches the email, or joins the account that already has it.

        Two shapes, one path. If the address is new, this account simply gains
        an email. If the address already belongs to an account — the user is
        signing in on a second phone — this account is merged into that one,
        which is what stops a week of talking from disappearing.
        """
        now = self._now()
        link = (
            await self._session.execute(
                select(MagicLinkToken).where(
                    MagicLinkToken.token_hash == hash_secret(token),
                    MagicLinkToken.consumed_at.is_(None),
                )
            )
        ).scalar_one_or_none()

        if link is None:
            raise InvalidCredentialsError("That link is not valid.")
        if _as_utc(link.expires_at) <= now:
            raise SessionExpiredError("That link has expired. Ask for a new one.")

        link.consumed_at = now
        device = await self._session.get(Device, device_id)
        if device is None:
            raise ValidationError("Register this device first.")

        existing = (
            await self._session.execute(
                select(Account).where(Account.email == link.email)
            )
        ).scalar_one_or_none()

        if existing is None:
            account = await self._session.get(Account, link.account_id)
            if account is None:
                raise ValidationError("That account no longer exists.")
            account.email = link.email
            account.email_verified_at = now
        else:
            await self._merge_accounts(
                source_account_id=device.account_id,
                target_account_id=existing.id,
            )
            device.account_id = existing.id

        await self._session.flush()
        return await self._issue_session(device)

    # --- The merge ----------------------------------------------------------

    async def _merge_accounts(
        self, *, source_account_id: str, target_account_id: str
    ) -> None:
        """Moves every row from one account to another.

        The rows keep their client-generated ids, so a row that both accounts
        somehow hold is one row, not two. Every moved row gets a fresh sequence
        number from the target account's counter — otherwise the other devices
        on that account, whose cursors are already past the source's numbering,
        would never see any of it.
        """
        if source_account_id == target_account_id:
            return

        counter = await self._session.get(
            SequenceCounter, target_account_id, with_for_update=True
        )
        if counter is None:
            counter = SequenceCounter(account_id=target_account_id, value=0)
            self._session.add(counter)
            await self._session.flush()

        for table in ACCOUNT_OWNED_TABLES:
            moving = (
                await self._session.execute(
                    select(table)
                    .where(table.account_id == source_account_id)
                    .order_by(table.server_sequence)
                )
            ).scalars()
            for row in moving:
                counter.value += 1
                row.account_id = target_account_id
                row.server_sequence = counter.value

        # Devices follow their account, so a third device already paired to the
        # source keeps working after the merge.
        await self._session.execute(
            update(Device)
            .where(Device.account_id == source_account_id)
            .values(account_id=target_account_id)
        )

        source = await self._session.get(Account, source_account_id)
        if source is not None:
            source.merged_into_account_id = target_account_id
        await self._session.flush()


def _as_utc(moment: datetime) -> datetime:
    """SQLite hands back naive datetimes; Postgres hands back aware ones."""
    return moment if moment.tzinfo else moment.replace(tzinfo=UTC)
