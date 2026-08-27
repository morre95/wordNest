"""Liveness and readiness.

Deliberately free of authentication and rate limiting: a load balancer must be
able to call it, and a health check that can be rate-limited is not one.
"""

from fastapi import APIRouter
from pydantic import BaseModel

from ...core.config import Environment
from ...core.dependencies import SettingsDep
from ...core.envelope import Success

router = APIRouter(tags=["health"])


class Health(BaseModel):
    status: str
    environment: Environment
    version: str


@router.get("/health", response_model=Success[Health], summary="Health check")
async def health(settings: SettingsDep) -> Success[Health]:
    return Success(
        data=Health(
            status="ok",
            environment=settings.environment,
            version="0.1.0",
        )
    )
