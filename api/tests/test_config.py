"""Configuration that has to be right before anything starts.

The env file is switched off deliberately: these assert on defaults, and a
developer's `.env` must not be able to decide what they see.
"""

from wordnest_api.core.config import Environment, Settings


def test_a_managed_postgres_url_gains_the_async_driver() -> None:
    """Railway hands out `postgresql://`, which resolves to psycopg2."""
    settings = Settings(
        _env_file="",
        environment=Environment.test,
        database_url="postgresql://user:pass@postgres.internal:5432/railway",
    )
    assert settings.database_url == (
        "postgresql+asyncpg://user:pass@postgres.internal:5432/railway"
    )


def test_an_explicit_driver_is_left_alone() -> None:
    settings = Settings(
        _env_file="",
        environment=Environment.test,
        database_url="postgresql+asyncpg://user:pass@host:5432/db",
    )
    assert settings.database_url == "postgresql+asyncpg://user:pass@host:5432/db"


def test_sqlite_is_left_alone() -> None:
    settings = Settings(
        _env_file="",
        environment=Environment.test,
        database_url="sqlite+aiosqlite:///./wordnest.db",
    )
    assert settings.database_url == "sqlite+aiosqlite:///./wordnest.db"
