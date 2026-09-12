# Built on the pve Docker context, which is native x86_64 — this workstation is
# arm64 and the cluster is amd64, so building locally produces images that will
# not run. See scripts/build-image.sh.
#
# Reproducible from the commit. The base is pinned by digest, and dependencies
# install from uv.lock rather than being resolved at build time. The previous
# `uv pip install .` took whatever was newest on the day, so two builds of one
# commit could differ, and the span-leak guard in telemetry.py depends on
# openlit 1.45.0's internals. uv.lock was generated with --exclude-newer set to
# the verified image's build time, so it reproduces that image's versions.

# The same Python patch and Debian release as the image verified in phase 1, at
# the digest that tag carried on 2026-09-13.
FROM python:3.12.14-slim-trixie@sha256:78387bc3881b8273120a12ebe6c1ab22b018ccc2c9adf565ae1ac9b536e184ea

COPY --from=ghcr.io/astral-sh/uv:0.12.6 /uv /usr/local/bin/uv

WORKDIR /app

# --frozen fails the build if uv.lock and pyproject.toml disagree, rather than
# quietly re-resolving. --no-install-project puts the source on PYTHONPATH
# instead of building a wheel, so no build backend is fetched — the one thing
# uv.lock does not pin. The base interpreter is used, never a downloaded one.
ENV UV_PYTHON_DOWNLOADS=never UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project

COPY src ./src

# Unbuffered so logs appear in kubectl logs as they happen rather than at exit.
ENV PATH="/app/.venv/bin:$PATH" PYTHONPATH=/app/src PYTHONUNBUFFERED=1
ENTRYPOINT ["python", "-m", "workflow"]
