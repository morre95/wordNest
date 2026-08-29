"""Sending the magic link.

Behind an interface because delivering email is an operational choice, not a
design one. The logging sender is what development and tests use; a real
provider is a class with the same one method.
"""

import logging
from typing import Protocol

import httpx

from ...core.config import Settings
from ...core.errors import EmailUndeliverableError

logger = logging.getLogger(__name__)

_RESEND_ENDPOINT = "https://api.resend.com/emails"

#: Redeeming needs the caller's own session — the device id comes from its
#: bearer token, not from the link — so the token is delivered as something to
#: type back into the app that asked for it, not as a URL to click. A link
#: opened in a mail client would arrive with no session and could not complete
#: the flow.
_SUBJECT = "Your WordNest sign-in code"

_TEXT_BODY = """\
Enter this code in WordNest to attach this address to your account:

{token}

The code expires in {minutes} minutes. If you did not ask for it, ignore this
email — nothing has changed.
"""

_HTML_BODY = """\
<p>Enter this code in WordNest to attach this address to your account:</p>
<p style="font-family:monospace;font-size:18px;word-break:break-all">{token}</p>
<p>The code expires in {minutes} minutes. If you did not ask for it, ignore
this email — nothing has changed.</p>
"""


class EmailSender(Protocol):
    async def send_magic_link(self, *, email: str, token: str) -> None: ...


class LoggingEmailSender:
    """Writes the link to the log instead of sending it.

    Deliberately the default: it makes the whole upgrade flow runnable locally
    with no provider account, and a link in a development log is no more
    sensitive than the database it sits next to. Never use it in production —
    `build_email_sender` refuses to.
    """

    def __init__(self) -> None:
        self.sent: list[tuple[str, str]] = []

    async def send_magic_link(self, *, email: str, token: str) -> None:
        self.sent.append((email, token))
        logger.warning("Magic link for %s (development only): token=%s", email, token)


class ResendEmailSender:
    """Backed by Resend's HTTP API.

    Owns its HTTP client for the same reason the translation provider does:
    one connection pool, built at startup rather than per send.
    """

    def __init__(
        self,
        *,
        api_key: str,
        from_address: str,
        link_lifetime_minutes: int,
        client: httpx.AsyncClient | None = None,
    ) -> None:
        self._api_key = api_key
        self._from_address = from_address
        self._link_lifetime_minutes = link_lifetime_minutes
        self._client = client or httpx.AsyncClient(
            # A sign-in email nobody is waiting on is worse than an error the
            # caller can retry, so this fails rather than holding the request.
            timeout=httpx.Timeout(10.0),
        )

    async def send_magic_link(self, *, email: str, token: str) -> None:
        payload = {
            "from": self._from_address,
            "to": [email],
            "subject": _SUBJECT,
            "text": _TEXT_BODY.format(token=token, minutes=self._link_lifetime_minutes),
            "html": _HTML_BODY.format(token=token, minutes=self._link_lifetime_minutes),
        }
        try:
            response = await self._client.post(
                _RESEND_ENDPOINT,
                json=payload,
                # On the request rather than the client: the key must travel
                # with the send whichever client this was handed.
                headers={"Authorization": f"Bearer {self._api_key}"},
            )
            response.raise_for_status()
        except httpx.HTTPStatusError as error:
            # The body carries the provider's reason — an unverified sending
            # domain, most often — and the token never appears in it.
            logger.error(
                "Resend rejected the magic link email: %s %s",
                error.response.status_code,
                error.response.text,
            )
            raise EmailUndeliverableError(
                "The sign-in email could not be sent. Please try again."
            ) from error
        except httpx.HTTPError as error:
            logger.error("Resend could not be reached: %s", error)
            raise EmailUndeliverableError(
                "The sign-in email could not be sent. Please try again."
            ) from error


def build_email_sender(settings: Settings) -> EmailSender:
    """Chooses the sender named in configuration.

    Mirrors the translation and speech factories: the real provider is opt-in,
    and the stand-in is refused in production rather than silently swallowing
    every sign-in email.
    """
    from ...core.config import EmailProviderName

    if settings.email_provider is EmailProviderName.resend:
        if not settings.resend_api_key:
            raise RuntimeError(
                "WORDNEST_RESEND_API_KEY must be set when "
                "WORDNEST_EMAIL_PROVIDER=resend."
            )
        if not settings.email_from_address:
            raise RuntimeError(
                "WORDNEST_EMAIL_FROM_ADDRESS must be set when "
                "WORDNEST_EMAIL_PROVIDER=resend, and its domain must be "
                "verified with Resend."
            )
        return ResendEmailSender(
            api_key=settings.resend_api_key,
            from_address=settings.email_from_address,
            link_lifetime_minutes=settings.magic_link_lifetime_minutes,
        )

    if settings.is_production:
        raise RuntimeError(
            "The logging email sender cannot be used in production: it writes "
            "sign-in tokens to the log. Set WORDNEST_EMAIL_PROVIDER=resend."
        )

    logger.warning(
        "Using the logging email sender. Magic links go to the log, not to an inbox."
    )
    return LoggingEmailSender()
