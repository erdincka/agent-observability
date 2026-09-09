# Built on the pve Docker context, which is native x86_64 — this workstation is
# arm64 and the cluster is amd64, so building locally produces images that will
# not run. See scripts/build-image.sh.
FROM python:3.12-slim

COPY --from=ghcr.io/astral-sh/uv:0.5.11 /uv /usr/local/bin/uv

WORKDIR /app
COPY pyproject.toml ./
COPY src ./src

RUN uv pip install --system --no-cache .

# Unbuffered so logs appear in kubectl logs as they happen rather than at exit.
ENV PYTHONUNBUFFERED=1
ENTRYPOINT ["python", "-m", "workflow"]
