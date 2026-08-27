"""A per-client token bucket for the endpoints that cost money to serve.

In-process on purpose: one bucket store per worker, no Redis to run. That means
the effective limit is `limit x workers`, which is the right trade for a service
whose limit exists to stop abuse rather than to meter a paid quota. Swapping in
a shared store later means replacing this class, not its callers.
"""

import time
from dataclasses import dataclass, field

from .errors import RateLimitedError


@dataclass
class _Bucket:
    tokens: float
    updated_at: float


@dataclass
class TokenBucketRateLimiter:
    """Refills continuously, so a client is never locked out for a whole minute
    after one burst — it regains one request every `60 / limit` seconds."""

    limit_per_minute: int
    now: object = field(default=time.monotonic)

    def __post_init__(self) -> None:
        self._buckets: dict[str, _Bucket] = {}

    @property
    def _refill_per_second(self) -> float:
        return self.limit_per_minute / 60.0

    def check(self, client_key: str) -> None:
        """Consumes one token for `client_key`, or raises [RateLimitedError]."""
        current = float(self.now())  # type: ignore[operator]
        bucket = self._buckets.get(client_key)

        if bucket is None:
            self._buckets[client_key] = _Bucket(
                tokens=self.limit_per_minute - 1, updated_at=current
            )
            return

        elapsed = max(0.0, current - bucket.updated_at)
        bucket.tokens = min(
            float(self.limit_per_minute),
            bucket.tokens + elapsed * self._refill_per_second,
        )
        bucket.updated_at = current

        if bucket.tokens < 1.0:
            seconds_to_one_token = (1.0 - bucket.tokens) / self._refill_per_second
            raise RateLimitedError(
                "Too many translation requests. Try again shortly.",
                retry_after_seconds=max(1, int(seconds_to_one_token) + 1),
            )

        bucket.tokens -= 1.0

    def remaining(self, client_key: str) -> int:
        bucket = self._buckets.get(client_key)
        if bucket is None:
            return self.limit_per_minute
        return int(bucket.tokens)

    def reset(self) -> None:
        self._buckets.clear()
