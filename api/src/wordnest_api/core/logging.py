"""Logging setup and the request log.

The one rule that matters here: a user's sentences never reach the log unless
someone deliberately turned that on. Everything else is ordinary access logging.
"""

import logging
import time
import uuid
from collections.abc import Awaitable, Callable

from fastapi import FastAPI, Request, Response

from .config import Settings

logger = logging.getLogger("wordnest")

REQUEST_ID_HEADER = "X-Request-Id"


def configure_logging(settings: Settings) -> None:
    logging.basicConfig(
        level=settings.log_level.upper(),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )


def register_request_logging(app: FastAPI, settings: Settings) -> None:
    @app.middleware("http")
    async def _log_request(
        request: Request, call_next: Callable[[Request], Awaitable[Response]]
    ) -> Response:
        request_id = request.headers.get(REQUEST_ID_HEADER) or uuid.uuid4().hex
        started = time.perf_counter()

        response = await call_next(request)

        duration_ms = (time.perf_counter() - started) * 1000
        logger.info(
            "%s %s -> %s in %.1fms [%s]",
            request.method,
            request.url.path,
            response.status_code,
            duration_ms,
            request_id,
        )
        response.headers[REQUEST_ID_HEADER] = request_id
        return response

    if settings.log_request_bodies:
        # Deliberately loud: this writes what people said into the log.
        logger.warning(
            "Request-body logging is ON. User sentences will be written to the "
            "log. Do not run this in production."
        )
