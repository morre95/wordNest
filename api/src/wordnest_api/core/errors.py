"""Domain errors and the handlers that turn them into the standard envelope.

Route handlers raise these rather than FastAPI's HTTPException, so that every
failure — including the ones FastAPI raises itself — leaves the service in the
same shape.
"""

import logging
from http import HTTPStatus

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

logger = logging.getLogger(__name__)


class WordNestError(Exception):
    """Base class for every failure this service raises deliberately."""

    status_code: int = HTTPStatus.INTERNAL_SERVER_ERROR
    code: str = "INTERNAL_ERROR"

    def __init__(
        self,
        message: str,
        *,
        details: dict[str, object] | None = None,
    ) -> None:
        super().__init__(message)
        self.message = message
        self.details = details


class ValidationError(WordNestError):
    status_code = HTTPStatus.UNPROCESSABLE_ENTITY
    code = "VALIDATION_ERROR"


class UnsupportedLanguagePairError(WordNestError):
    status_code = HTTPStatus.UNPROCESSABLE_ENTITY
    code = "UNSUPPORTED_LANGUAGE_PAIR"


class RateLimitedError(WordNestError):
    status_code = HTTPStatus.TOO_MANY_REQUESTS
    code = "RATE_LIMITED"

    def __init__(self, message: str, *, retry_after_seconds: int) -> None:
        super().__init__(message, details={"retry_after_seconds": retry_after_seconds})
        self.retry_after_seconds = retry_after_seconds


class TranslationUnavailableError(WordNestError):
    """The language model could not be reached or refused the request.

    The client falls back to its on-device translation, so this is a degraded
    service rather than a broken one.
    """

    status_code = HTTPStatus.SERVICE_UNAVAILABLE
    code = "TRANSLATION_UNAVAILABLE"


def _envelope(
    status_code: int,
    code: str,
    message: str,
    details: dict[str, object] | None = None,
    headers: dict[str, str] | None = None,
) -> JSONResponse:
    error: dict[str, object] = {"code": code, "message": message}
    if details:
        error["details"] = details
    return JSONResponse(
        status_code=status_code,
        content={"success": False, "error": error},
        headers=headers,
    )


def register_error_handlers(app: FastAPI) -> None:
    """Wires every failure path to the standard envelope."""

    @app.exception_handler(WordNestError)
    async def _handle_domain_error(
        request: Request, error: WordNestError
    ) -> JSONResponse:
        headers = None
        if isinstance(error, RateLimitedError):
            headers = {"Retry-After": str(error.retry_after_seconds)}
        return _envelope(
            error.status_code, error.code, error.message, error.details, headers
        )

    @app.exception_handler(RequestValidationError)
    async def _handle_request_validation(
        request: Request, error: RequestValidationError
    ) -> JSONResponse:
        # Pydantic's own error list, reshaped into field -> reason so a client
        # can point at the offending input instead of parsing prose.
        fields: dict[str, object] = {}
        for problem in error.errors():
            location = ".".join(str(part) for part in problem["loc"][1:])
            fields[location or "body"] = problem["msg"]
        return _envelope(
            HTTPStatus.BAD_REQUEST,
            "VALIDATION_ERROR",
            "The request body is not valid.",
            fields,
        )

    @app.exception_handler(StarletteHTTPException)
    async def _handle_http_exception(
        request: Request, error: StarletteHTTPException
    ) -> JSONResponse:
        status = HTTPStatus(error.status_code)
        return _envelope(
            error.status_code,
            status.name.upper().replace(" ", "_"),
            str(error.detail),
        )

    @app.exception_handler(Exception)
    async def _handle_unexpected(request: Request, error: Exception) -> JSONResponse:
        # The real cause goes to the log; the client gets nothing it could use
        # to learn about the inside of this service.
        logger.exception("Unhandled error on %s %s", request.method, request.url.path)
        return _envelope(
            HTTPStatus.INTERNAL_SERVER_ERROR,
            "INTERNAL_ERROR",
            "Something went wrong on our side.",
        )
