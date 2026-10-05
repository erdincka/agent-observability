# The MinIO client, as an image this lab builds for itself.
#
# Until 2026-10 the in-cluster checks pulled minio/mc from Docker Hub. MinIO
# withdrew its images from Docker Hub and its binaries from dl.min.io in the
# same move (deploy/05-minio/install-minio.sh has the dates), and no public
# registry serves the pinned tag now. The pinned release is still on GitHub
# with the checksum the lab recorded, so the image is built from that: the
# same binary the MinIO VM runs, in a minimal Debian, pushed to REGISTRY.
#
# Built by scripts/build-mc-image.sh (`make mc-image`); tagged with MC_VERSION
# rather than a commit, because the binary is the only input that matters.
FROM debian:trixie-slim
ARG MC_VERSION=RELEASE.2025-08-13T08-35-41Z
ARG MC_SHA256=01f866e9c5f9b87c2b09116fa5d7c06695b106242d829a8bb32990c00312e891
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && curl -fsSL -o /usr/local/bin/mc \
      "https://github.com/minio/mc/releases/download/${MC_VERSION}/mc.linux-amd64.${MC_VERSION}" \
 && echo "${MC_SHA256}  /usr/local/bin/mc" | sha256sum -c - \
 && chmod 0755 /usr/local/bin/mc \
 && apt-get purge -y curl && apt-get autoremove -y && rm -rf /var/lib/apt/lists/*
# No ENTRYPOINT: the verify scripts run `sh -c` with mc on PATH.
CMD ["mc", "--version"]
