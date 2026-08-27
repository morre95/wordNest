"""The one response shape every endpoint returns.

Success and failure share a structure so a client can branch on `success`
before it has to know anything else about the payload.
"""

from pydantic import BaseModel, Field


class ErrorBody(BaseModel):
    """The machine-readable half of a failure."""

    code: str = Field(description="Stable UPPER_SNAKE_CASE identifier.")
    message: str = Field(description="Human-readable explanation.")
    details: dict[str, object] | None = Field(
        default=None,
        description="Field-level problems, when the failure is a validation one.",
    )


class Success[PayloadT](BaseModel):
    success: bool = Field(default=True, description="Always true.")
    data: PayloadT
    meta: dict[str, object] | None = Field(
        default=None,
        description="Pagination, rate-limit headroom, request id.",
    )


class Failure(BaseModel):
    success: bool = Field(default=False, description="Always false.")
    error: ErrorBody
