"""Engine and session lifetime.

One engine per process with a connection pool; one session per request, closed
whether the request succeeds or not.
"""

from collections.abc import AsyncIterator

from sqlalchemy.ext.asyncio import (
    AsyncEngine,
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)

from ..config import Settings


def create_engine(settings: Settings) -> AsyncEngine:
    is_sqlite = settings.database_url.startswith("sqlite")
    return create_async_engine(
        settings.database_url,
        # SQLite has no server to pool connections to, and an in-memory URL
        # needs the same connection throughout or the schema vanishes.
        pool_pre_ping=not is_sqlite,
        pool_size=5 if not is_sqlite else 1,
        max_overflow=10 if not is_sqlite else 0,
        pool_recycle=1800,
        echo=False,
    )


def create_session_factory(engine: AsyncEngine) -> async_sessionmaker[AsyncSession]:
    return async_sessionmaker(
        engine,
        expire_on_commit=False,
        autoflush=False,
    )


async def session_scope(
    factory: async_sessionmaker[AsyncSession],
) -> AsyncIterator[AsyncSession]:
    """One session per request. Rolls back on any exception, so a half-applied
    sync batch is never committed."""
    async with factory() as session:
        try:
            yield session
        except Exception:
            await session.rollback()
            raise
