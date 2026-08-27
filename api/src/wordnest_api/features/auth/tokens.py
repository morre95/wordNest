"""Minting and reading credentials.

Access tokens are short-lived JWTs the client sends on every request. Refresh
tokens and pairing codes are random strings stored only as SHA-256 hashes: a
leaked database must not hand anyone a working credential. SHA-256 without
stretching is right here and wrong for passwords — these are already 256 bits of
entropy, so there is nothing to brute-force, and the check is on a hot path.
"""

import hashlib
import secrets
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

import jwt

from ...core.errors import WordNestError

ALGORITHM = "HS256"


class InvalidCredentialsError(WordNestError):
    status_code = 401
    code = "INVALID_CREDENTIALS"


class SessionExpiredError(WordNestError):
    status_code = 401
    code = "SESSION_EXPIRED"


@dataclass(frozen=True)
class AccessTokenClaims:
    account_id: str
    device_id: str
    expires_at: datetime


def hash_secret(secret: str) -> str:
    return hashlib.sha256(secret.encode("utf-8")).hexdigest()


def new_refresh_token() -> str:
    return secrets.token_urlsafe(32)


def new_pairing_code() -> str:
    """Six digits, because it is typed by hand from one screen onto another.

    Little entropy on purpose; safety comes from the ten-minute expiry and the
    attempt limit, both enforced where the code is redeemed.
    """
    return f"{secrets.randbelow(1_000_000):06d}"


def new_magic_link_token() -> str:
    return secrets.token_urlsafe(32)


def issue_access_token(
    *,
    account_id: str,
    device_id: str,
    secret: str,
    lifetime_minutes: int,
    now: datetime | None = None,
) -> tuple[str, datetime]:
    issued_at = now or datetime.now(UTC)
    expires_at = issued_at + timedelta(minutes=lifetime_minutes)
    token = jwt.encode(
        {
            "sub": account_id,
            "did": device_id,
            "iat": int(issued_at.timestamp()),
            "exp": int(expires_at.timestamp()),
        },
        secret,
        algorithm=ALGORITHM,
    )
    return token, expires_at


def read_access_token(token: str, *, secret: str) -> AccessTokenClaims:
    """Verifies and decodes an access token.

    An expired token is reported separately from an invalid one, because the
    client's response differs: refresh, versus sign in again.
    """
    try:
        payload = jwt.decode(token, secret, algorithms=[ALGORITHM])
    except jwt.ExpiredSignatureError as error:
        raise SessionExpiredError("This session has expired.") from error
    except jwt.InvalidTokenError as error:
        raise InvalidCredentialsError("This token is not valid.") from error

    account_id = payload.get("sub")
    device_id = payload.get("did")
    if not account_id or not device_id:
        raise InvalidCredentialsError("This token is missing its subject.")

    return AccessTokenClaims(
        account_id=account_id,
        device_id=device_id,
        expires_at=datetime.fromtimestamp(payload["exp"], tz=UTC),
    )


def constant_time_equals(left: str, right: str) -> bool:
    """Compares two hashes without leaking their difference through timing."""
    return secrets.compare_digest(left, right)
