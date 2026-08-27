"""The identity API's request and response models."""

from pydantic import BaseModel, EmailStr, Field

from ..sync.schemas import UtcDatetime


class DeviceRegistrationRequest(BaseModel):
    """First launch. No email, no password, no user-visible step.

    The device generates its own id so a retried registration after a dropped
    connection lands on the same row instead of creating a second device.
    """

    device_id: str = Field(min_length=8, max_length=64)
    display_name: str = Field(min_length=1, max_length=120)
    platform: str = Field(min_length=1, max_length=32)


class TokenPair(BaseModel):
    access_token: str
    refresh_token: str
    expires_at: UtcDatetime
    account_id: str
    device_id: str

    #: False once the account has an email attached. The app uses this to
    #: decide whether to offer "back up your words" in settings.
    is_anonymous: bool


class RefreshRequest(BaseModel):
    refresh_token: str = Field(min_length=16, max_length=256)


class PairingCodeResponse(BaseModel):
    """Shown on the device that already has the data."""

    code: str
    expires_at: UtcDatetime


class RedeemPairingCodeRequest(BaseModel):
    """Sent by the new device, which is registered but anonymous."""

    code: str = Field(min_length=6, max_length=6, pattern=r"^\d{6}$")


class MagicLinkRequest(BaseModel):
    email: EmailStr


class MagicLinkSent(BaseModel):
    """Deliberately says nothing about whether the address is known.

    Telling an anonymous caller whether an email has an account is an account
    enumeration hole, and there is nothing to gain from it.
    """

    sent: bool = True
    expires_at: UtcDatetime


class RedeemMagicLinkRequest(BaseModel):
    token: str = Field(min_length=16, max_length=256)


class DeviceSummary(BaseModel):
    id: str
    display_name: str
    platform: str
    last_seen_at: UtcDatetime | None
    created_at: UtcDatetime
    revoked_at: UtcDatetime | None

    #: True for the device asking, so the list can say "this device".
    is_current: bool


class DeviceList(BaseModel):
    devices: list[DeviceSummary]
