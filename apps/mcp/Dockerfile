# Built with the REPOSITORY ROOT as context, not apps/mcp — the changes server
# reads this repo's own git history and the runbooks server reads docs/runbooks,
# so both need files from outside the app directory. The root .dockerignore keeps
# .env and rendered config out of that context. See scripts/build-image.sh.
#
# Reproducible from the commit, as in apps/workflow/Dockerfile: base pinned by
# digest, dependencies from uv.lock, locked to this image's phase 1 build day.
# One input still floats: `git` comes from Debian's package index at build time.

# The same Python patch and Debian release as the image verified in phase 1, at
# the digest that tag carried on 2026-09-13.
FROM python:3.12.14-slim-trixie@sha256:78387bc3881b8273120a12ebe6c1ab22b018ccc2c9adf565ae1ac9b536e184ea

RUN apt-get update \
 && apt-get install -y --no-install-recommends git \
 && rm -rf /var/lib/apt/lists/*

COPY --from=ghcr.io/astral-sh/uv:0.12.6 /uv /usr/local/bin/uv

WORKDIR /app
ENV UV_PYTHON_DOWNLOADS=never UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy
COPY apps/mcp/pyproject.toml apps/mcp/uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project
COPY apps/mcp/src ./src

# Evidence the tool servers serve. Baked in rather than mounted so the image is
# self-contained and a clone reproduces it.
COPY .git /repo/.git
COPY docs/runbooks /runbooks

# `git -C /repo log` needs a checked-out worktree state to resolve HEAD; the
# bare .git alone is enough for log/show/diff once git is told it is safe to use
# a repo it does not own.
RUN git config --global --add safe.directory /repo \
 && git --git-dir=/repo/.git --work-tree=/repo checkout -f HEAD -- . 2>/dev/null || true

ENV PATH="/app/.venv/bin:$PATH" PYTHONPATH=/app/src PYTHONUNBUFFERED=1 PORT=8080
EXPOSE 8080
# No ENTRYPOINT: which server this pod runs is chosen by the Deployment's args,
# so one image backs three genuinely separate services.
