"""Alembic environment.

The database URL comes from application settings, never from `alembic.ini`, so
there is one source of truth and no credentials in a committed file.
"""

import asyncio
from logging.config import fileConfig

from alembic import context
from sqlalchemy import pool
from sqlalchemy.engine import Connection
from sqlalchemy.ext.asyncio import async_engine_from_config

from wordnest_api.core.config import get_settings

# Imported for the side effect of registering every table on Base.metadata.
# Without this, autogenerate produces an empty migration.
from wordnest_api.core.db import models  # noqa: F401
from wordnest_api.core.db.base import Base

config = context.config

# A caller that already set a URL — the test fixture, or a one-off migration
# against a specific database — wins. Otherwise it comes from application
# settings, so there is one source of truth and no credentials in a committed
# file.
if not config.get_main_option("sqlalchemy.url", default=None):
    config.set_main_option("sqlalchemy.url", get_settings().database_url)

# Only when Alembic is driven from the command line. Running migrations from
# inside a process — the test fixture does, on every run — must not tear down
# the logging that process already configured; `fileConfig` replaces the root
# handlers, which would silently swallow everything afterwards.
if config.config_file_name is not None and config.attributes.get(
    "configure_logging", True
):
    fileConfig(config.config_file_name, disable_existing_loggers=False)

target_metadata = Base.metadata


def run_migrations_offline() -> None:
    context.configure(
        url=config.get_main_option("sqlalchemy.url"),
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
    )
    with context.begin_transaction():
        context.run_migrations()


def do_run_migrations(connection: Connection) -> None:
    context.configure(
        connection=connection,
        target_metadata=target_metadata,
        # SQLite cannot ALTER most things in place; batch mode rebuilds the
        # table instead, so the same migration runs on SQLite and Postgres.
        render_as_batch=connection.dialect.name == "sqlite",
        compare_type=True,
    )
    with context.begin_transaction():
        context.run_migrations()


async def run_async_migrations() -> None:
    connectable = async_engine_from_config(
        config.get_section(config.config_ini_section, {}),
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
    )
    async with connectable.connect() as connection:
        await connection.run_sync(do_run_migrations)
    await connectable.dispose()


def run_migrations_online() -> None:
    asyncio.run(run_async_migrations())


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
