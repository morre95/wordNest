"""Production deployment must prepare the database before serving requests."""

import json
from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]


def test_railway_runs_migrations_before_deploying_the_api() -> None:
    """A fresh Railway database cannot authenticate speech without its tables."""
    config = json.loads((REPOSITORY_ROOT / "railway.json").read_text())

    assert config["deploy"]["preDeployCommand"] == ["alembic upgrade head"]


def test_the_runtime_image_contains_the_migration_files() -> None:
    """The pre-deploy command runs inside the built image."""
    dockerfile = (REPOSITORY_ROOT / "api" / "Dockerfile").read_text()

    assert "COPY alembic ./alembic" in dockerfile
    assert "COPY alembic.ini ./alembic.ini" in dockerfile
