# Perses, with the ClickHouse trace-query plugin from this project's upstream PR.
#
# The stock image bundles every plugin from perses/plugins at
# /etc/perses/plugins-archive, including a ClickHouse plugin that has no trace
# query (CONTRIBUTIONS item 1, perses/plugins#813). This image builds the
# ClickHouse plugin from the PR branch — pinned to a commit, cloned from the
# fork, so the build is reproducible without uploading a checkout — and ships
# a curated archive directory: everything bundled, minus the old ClickHouse
# archive, plus the new one. The Deployment points Perses at that directory
# (PERSES_PLUGIN_ARCHIVE_PATHS_0), because the final stage is distroless and
# cannot delete the bundled file.
#
# Built on the pve Docker context like the app images; see scripts/build-image.sh.

# --- stage 1: the toolchain perses/plugins CI uses (from the PR's verification kit)
FROM golang:1.27.1-bookworm AS toolbox
COPY --from=node:24-bookworm-slim /usr/local/bin/node /usr/local/bin/node
COPY --from=node:24-bookworm-slim /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
 && ln -s /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx
# percli v0.54.0 and cue v0.16.1, as perses/plugins CI pins them. percli's
# plugin build runs `cue mod tidy` on the schema, so cue is not optional.
RUN curl -sSfL https://github.com/perses/perses/releases/download/v0.54.0/perses_0.54.0_linux_amd64.tar.gz \
    | tar -xz -C /usr/local/bin percli \
 && go install cuelang.org/go/cmd/cue@v0.16.1
RUN git config --global --add safe.directory '*'

# --- stage 2: the plugin, from the PR commit
FROM toolbox AS build
ARG PLUGINS_REPO=https://github.com/erdincka/plugins.git
ARG PLUGINS_COMMIT=2175f77fb70696eabd3f6d158e6cbee714565c51
WORKDIR /src
RUN git init -q . && git remote add origin "$PLUGINS_REPO" \
 && git fetch -q --depth 1 origin "$PLUGINS_COMMIT" && git checkout -q FETCH_HEAD
RUN npm ci --no-audit --no-fund \
 && percli plugin build --plugin.path=clickhouse --skip.npm-install=true \
 && ls -l clickhouse/*.tar.gz

# --- stage 3: curate the archive directory
FROM persesdev/perses:v0.54.0 AS stock
FROM debian:bookworm-slim AS curate
COPY --from=stock /etc/perses/plugins-archive /archives
RUN rm -v /archives/ClickHouse-*.tar.gz
COPY --from=build /src/clickhouse/*.tar.gz /archives/
RUN ls -1 /archives

# --- stage 4: Perses itself, unchanged, plus the curated archives
FROM persesdev/perses:v0.54.0
COPY --from=curate --chown=65532:65532 /archives /etc/perses/plugins-archive-lab
