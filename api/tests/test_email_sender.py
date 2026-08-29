"""The email boundary: what is sent, and what happens when it cannot be.

The magic link is the whole of the sign-in flow, so the two failures that
matter are a provider that will not take the message and a build that silently
falls back to writing sign-in tokens into a log.
"""

import httpx
import pytest

from wordnest_api.core.config import EmailProviderName, Environment, Settings
from wordnest_api.core.errors import EmailUndeliverableError
from wordnest_api.features.auth.email_sender import (
    LoggingEmailSender,
    ResendEmailSender,
    build_email_sender,
)

A_REAL_SECRET = "a-real-secret-for-this-test"


def sender_with(handler: object) -> ResendEmailSender:
    """A Resend sender whose requests never leave the process."""
    return ResendEmailSender(
        api_key="test-key",
        from_address="WordNest <no-reply@example.com>",
        link_lifetime_minutes=20,
        client=httpx.AsyncClient(transport=httpx.MockTransport(handler)),  # type: ignore[arg-type]
    )


async def test_the_token_and_the_address_reach_the_provider() -> None:
    seen: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200, json={"id": "sent"})

    await sender_with(handler).send_magic_link(
        email="someone@example.com", token="the-token"
    )

    assert len(seen) == 1
    import json

    body = json.loads(seen[0].content)
    assert body["to"] == ["someone@example.com"]
    assert body["from"] == "WordNest <no-reply@example.com>"
    # Both parts carry the code: a text-only client must not get a blank email.
    assert "the-token" in body["text"]
    assert "the-token" in body["html"]
    assert "20 minutes" in body["text"]
    assert seen[0].headers["authorization"] == "Bearer test-key"


async def test_a_refused_send_becomes_a_retryable_error() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(403, json={"message": "domain is not verified"})

    with pytest.raises(EmailUndeliverableError):
        await sender_with(handler).send_magic_link(
            email="someone@example.com", token="the-token"
        )


async def test_an_unreachable_provider_becomes_a_retryable_error() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("no route to host")

    with pytest.raises(EmailUndeliverableError):
        await sender_with(handler).send_magic_link(
            email="someone@example.com", token="the-token"
        )


async def test_the_error_never_carries_the_token() -> None:
    """A sign-in token in an error body would travel back to the caller."""

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(500, text="upstream is unwell")

    with pytest.raises(EmailUndeliverableError) as raised:
        await sender_with(handler).send_magic_link(
            email="someone@example.com", token="the-token"
        )
    assert "the-token" not in raised.value.message


def test_the_logging_sender_is_refused_in_production() -> None:
    """Writing sign-in tokens to a production log is a way into an account."""
    with pytest.raises(RuntimeError, match="cannot be used in production"):
        build_email_sender(
            Settings(
                environment=Environment.production,
                jwt_secret=A_REAL_SECRET,
                email_provider=EmailProviderName.logging,
            )
        )


def test_the_logging_sender_is_what_development_gets() -> None:
    assert isinstance(
        build_email_sender(
            Settings(
                environment=Environment.test,
                email_provider=EmailProviderName.logging,
            )
        ),
        LoggingEmailSender,
    )


def test_resend_without_a_key_fails_at_startup() -> None:
    with pytest.raises(RuntimeError, match="WORDNEST_RESEND_API_KEY"):
        build_email_sender(
            Settings(
                environment=Environment.test,
                email_provider=EmailProviderName.resend,
                resend_api_key=None,
                email_from_address="WordNest <no-reply@example.com>",
            )
        )


def test_resend_without_a_from_address_fails_at_startup() -> None:
    """An unverified or absent sender domain is rejected on every send."""
    with pytest.raises(RuntimeError, match="WORDNEST_EMAIL_FROM_ADDRESS"):
        build_email_sender(
            Settings(
                environment=Environment.test,
                email_provider=EmailProviderName.resend,
                resend_api_key="test-key",
                email_from_address=None,
            )
        )


def test_production_accepts_a_configured_resend_sender() -> None:
    assert isinstance(
        build_email_sender(
            Settings(
                environment=Environment.production,
                jwt_secret=A_REAL_SECRET,
                email_provider=EmailProviderName.resend,
                resend_api_key="test-key",
                email_from_address="WordNest <no-reply@example.com>",
            )
        ),
        ResendEmailSender,
    )
