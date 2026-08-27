"""Sending the magic link.

Behind an interface because delivering email is an operational choice, not a
design one. The logging sender is what development and tests use; a real
provider is a class with the same one method.
"""

import logging
from typing import Protocol

logger = logging.getLogger(__name__)


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


def build_email_sender(is_production: bool) -> EmailSender:
    if is_production:
        raise RuntimeError(
            "No production email sender is configured. Implement EmailSender "
            "against your provider and wire it here before deploying."
        )
    return LoggingEmailSender()
