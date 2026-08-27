# Build and run wordnest-api.
#
# Two stages so the runtime image carries no build tooling and no uv cache.
FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim AS builder

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never

WORKDIR /app

# Dependencies first, in their own layer, so editing source does not reinstall
# the world.
COPY pyproject.toml uv.lock README.md ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --locked --no-install-project --no-dev

COPY src ./src
COPY prompts ./prompts
COPY alembic ./alembic
COPY alembic.ini ./alembic.ini
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --locked --no-dev


FROM python:3.12-slim-bookworm AS runtime

# Never run as root: a translation service has no business being able to write
# to its own image.
RUN groupadd --system wordnest \
 && useradd --system --gid wordnest --home /app wordnest

WORKDIR /app
COPY --from=builder --chown=wordnest:wordnest /app /app

ENV PATH="/app/.venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    WORDNEST_ENVIRONMENT=production

USER wordnest
EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/api/v1/health').status == 200 else 1)"

CMD ["uvicorn", "wordnest_api.main:app", "--host", "0.0.0.0", "--port", "8000"]
