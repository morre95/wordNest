"""SQLAlchemy declarative base and the columns every synced row carries.

The schema mirrors the device's Drift schema deliberately: same table names,
same column names, same client-generated ids. A sync payload is then the row
itself, with no translation layer to keep in step.
"""

from datetime import UTC, datetime

from sqlalchemy import BigInteger, DateTime, String, func
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column


class Base(DeclarativeBase):
    pass


def utc_now() -> datetime:
    return datetime.now(UTC)


class SyncedRow:
    """Mixin for anything that travels between devices.

    `server_sequence` is the whole point: a monotonic counter, assigned by the
    database on every write, that the delta-sync cursor walks. Wall-clock time
    cannot do this job — device clocks drift, and a client polling at the same
    millisecond as a write would miss it.
    """

    id: Mapped[str] = mapped_column(String(64), primary_key=True)

    account_id: Mapped[str] = mapped_column(String(64), index=True, nullable=False)

    #: The device that last wrote this row. Utterances are only writable by the
    #: device that created them; this is what makes that checkable.
    origin_device_id: Mapped[str | None] = mapped_column(String(64))

    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False
    )
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    server_sequence: Mapped[int] = mapped_column(BigInteger, nullable=False, index=True)

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )
