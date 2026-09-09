# Built with the REPOSITORY ROOT as context, not apps/mcp — the changes server
# reads this repo's own git history and the runbooks server reads docs/runbooks,
# so both need files from outside the app directory. See scripts/build-image.sh.
FROM python:3.12-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends git \
 && rm -rf /var/lib/apt/lists/*

COPY --from=ghcr.io/astral-sh/uv:0.5.11 /uv /usr/local/bin/uv

WORKDIR /app
COPY apps/mcp/pyproject.toml ./
COPY apps/mcp/src ./src
RUN uv pip install --system --no-cache .

# Evidence the tool servers serve. Baked in rather than mounted so the image is
# self-contained and a clone reproduces it exactly.
COPY .git /repo/.git
COPY docs/runbooks /runbooks

# `git -C /repo log` needs a checked-out worktree state to resolve HEAD; the
# bare .git alone is enough for log/show/diff once git is told it is safe to use
# a repo it does not own.
RUN git config --global --add safe.directory /repo \
 && git --git-dir=/repo/.git --work-tree=/repo checkout -f HEAD -- . 2>/dev/null || true

ENV PYTHONUNBUFFERED=1 PORT=8080
EXPOSE 8080
# No ENTRYPOINT: which server this pod runs is chosen by the Deployment's args,
# so one image backs three genuinely separate services.
