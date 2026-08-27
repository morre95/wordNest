"""Configuration, read once from the environment.

Every value has a development default except the LLM API key, which has none:
a missing key must fail loudly rather than quietly degrade to a fake.
"""

from enum import StrEnum
from functools import lru_cache
from pathlib import Path

from pydantic import Field, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Environment(StrEnum):
    development = "development"
    test = "test"
    production = "production"


class TranslationProviderName(StrEnum):
    """Which implementation backs the translation endpoint."""

    anthropic = "anthropic"

    #: A deterministic stand-in used by the test suite and by local development
    #: without an API key. Never selectable in production.
    fake = "fake"


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="WORDNEST_",
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    environment: Environment = Environment.development

    #: Postgres in production, SQLite for local development and tests. Both are
    #: driven through SQLAlchemy's async API, so the code path is identical.
    database_url: str = "sqlite+aiosqlite:///./wordnest.db"

    #: Signs access tokens. A development default exists so the service starts
    #: out of the box; `_reject_dev_secret_in_production` refuses it in
    #: production, where a predictable signing key would let anyone mint a
    #: token for anyone's account.
    jwt_secret: str = "development-only-do-not-use-in-production"  # noqa: S105
    access_token_lifetime_minutes: int = 15
    refresh_token_lifetime_days: int = 90

    #: A pairing code is six digits — little entropy — so its safety comes from
    #: expiring fast and from a cap on how fast one device may guess.
    pairing_code_lifetime_minutes: int = 10
    pairing_redemptions_per_minute: int = 5
    magic_link_lifetime_minutes: int = 20

    #: Rows accepted or returned in one sync page. Capped so a device coming
    #: back after a fortnight cannot ask for everything at once.
    sync_batch_limit: int = 500

    #: Origins allowed to call the API from a browser. A mobile client sends no
    #: Origin header, so this list stays empty in production unless a web
    #: client exists — never "*".
    cors_origins: list[str] = Field(default_factory=list)

    translation_provider: TranslationProviderName = TranslationProviderName.fake

    #: Supplied as WORDNEST_ANTHROPIC_API_KEY, or via the SDK's own
    #: ANTHROPIC_API_KEY when this is unset.
    anthropic_api_key: str | None = None
    translation_model: str = "claude-opus-5"

    #: Per-client ceiling on the translation endpoint. Chosen to be generous for
    #: a person speaking and impossible for a script to abuse cheaply.
    translation_rate_limit_per_minute: int = 60

    #: Off by default: user sentences are personal, and an access log that
    #: contains them is a data-retention problem nobody asked for. Turn on only
    #: to debug, and only in development.
    log_request_bodies: bool = False

    log_level: str = "INFO"

    prompts_directory: Path = Path(__file__).resolve().parents[3] / "prompts"

    @property
    def is_production(self) -> bool:
        return self.environment is Environment.production

    @model_validator(mode="after")
    def _reject_dev_secret_in_production(self) -> "Settings":
        if self.is_production and self.jwt_secret.startswith("development-only"):
            raise ValueError(
                "WORDNEST_JWT_SECRET must be set to a real secret in production."
            )
        return self


@lru_cache
def get_settings() -> Settings:
    """Cached so the environment is read once per process."""
    return Settings()
