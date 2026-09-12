#!/usr/bin/env bash
# Does the cluster run what this repository says it runs?
#
# Written after the repository said Ollama was pinned to 0.33.3 for four days
# while the Deployment in the cluster still said `latest`: the manifest had been
# edited and never applied. A committed manifest is not a deployed one, and
# nothing else in the lab would have noticed. The first run also found an
# HTTPRoute that was committed and never applied (TODO.md item 4).
#
# Read-only. `kubectl diff` (a server-side dry run) for every manifest under
# deploy/, rendered exactly as `make` renders it, and a key-by-key comparison of
# Helm values and chart versions. Excluded: Jobs, which are recreated per run so
# a finished one is history rather than desired state, and Secrets, whose values
# live in .env.
#
# Exit 0 if everything matches, 1 on drift, 2 if a check could not run.
set -uo pipefail
cd "$(dirname "$0")/.."

PLATFORM_NS=agent-obs-platform
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
status=0

report() {  # report <label> <command...>; the command exits 0 same, 1 differs
  local label=$1; shift
  local out rc
  out=$("$@" 2>&1); rc=$?
  case $rc in
    0) printf '  same   %s\n' "$label" ;;
    1) printf '  DRIFT  %s\n' "$label"
       grep -E '^[+-] ' <<<"$out" \
         | grep -vE 'generation:|resourceVersion|managedFields|creationTimestamp|uid:|time:|manager:|operation:' \
         | head -12 | sed 's/^/           /'
       [ "$status" -eq 2 ] || status=1 ;;
    *) printf '  ERROR  %s: %s\n' "$label" "$(tail -1 <<<"$out")"; status=2 ;;
  esac
}
pull_policy() { [[ "$1" == *-dirty ]] && echo Always || echo IfNotPresent; }

echo "==> manifests under deploy/"
while IFS= read -r f; do
  case "$f" in
    */values.yaml|*/config.rendered.yaml|*.tmpl) continue ;;
    deploy/70-workflow/*) continue ;;
    deploy/80-mcp/servers.yaml)
      tag=$(scripts/image-tag.sh mcp)
      sed -e "s|__MCP_TAG__|$tag|g" -e "s|__PULL_POLICY__|$(pull_policy "$tag")|g" "$f" > "$TMP/servers.yaml"
      report "$f  (mcp:$tag)" kubectl diff -f "$TMP/servers.yaml" ;;
    deploy/50-litellm/litellm.yaml)
      ./scripts/render-litellm-config.py >/dev/null
      sed "s/REPLACED_AT_DEPLOY/$(scripts/litellm-checksum.sh)/" "$f" > "$TMP/litellm.yaml"
      report "$f" kubectl diff -f "$TMP/litellm.yaml"
      kubectl create configmap litellm-config -n "$PLATFORM_NS" \
        --from-file=config.yaml=deploy/50-litellm/config.rendered.yaml --dry-run=client -o yaml > "$TMP/litellm-cm.yaml"
      report "litellm-config ConfigMap, rendered from .env" kubectl diff -f "$TMP/litellm-cm.yaml" ;;
    *) report "$f" kubectl diff -f "$f" ;;
  esac
done < <(find deploy -name '*.yaml' | sort)

YAMLDIFF='import sys, yaml
repo = yaml.safe_load(open(sys.argv[1])) or {}
live = yaml.safe_load(open(sys.argv[2])) or {}
diffs = []
def walk(a, b, path):
    if isinstance(a, dict) and isinstance(b, dict):
        for k in sorted(set(a) | set(b), key=str):
            walk(a.get(k, "<absent>"), b.get(k, "<absent>"), f"{path}.{k}" if path else str(k))
    elif a != b:
        diffs.append((path, a, b))
walk(repo, live, "")
for path, a, b in diffs:
    print(f"- repo     {path}: {a!r}")
    print(f"+ cluster  {path}: {b!r}")
sys.exit(1 if diffs else 0)'

helm_check() {  # helm_check <release> <chart version from Makefile> <values file>
  local rel=$1 want=$2 file=$3 have
  have=$(helm list -n "$PLATFORM_NS" -f "^${rel}\$" -o json \
         | python3 -c 'import json,sys; r=json.load(sys.stdin); print(r[0]["chart"] if r else "")')
  if [ "${have##*-}" = "$want" ]; then
    printf '  same   %s chart version %s\n' "$rel" "$want"
  else
    printf '  DRIFT  %s chart: repo %s, cluster %s\n' "$rel" "$want" "${have:-absent}"
    [ "$status" -eq 2 ] || status=1
  fi
  if ! helm get values "$rel" -n "$PLATFORM_NS" -o yaml > "$TMP/$rel.yaml" 2>/dev/null; then
    printf '  ERROR  %s: helm get values failed\n' "$rel"; status=2; return
  fi
  report "$file  (helm values, $rel)" \
    uv run --quiet --no-project --with pyyaml python -c "$YAMLDIFF" "$file" "$TMP/$rel.yaml"
}

echo "==> Helm releases"
helm_check otel-collector "$(sed -n 's/^COLLECTOR_CHART_VERSION *:= *//p' Makefile)" deploy/20-otel-collector/values.yaml
helm_check openlit        "$(sed -n 's/^OPENLIT_CHART_VERSION *:= *//p' Makefile)"   deploy/30-openlit/values.yaml

echo
case $status in
  0) echo "==> no drift: the cluster runs what this repository describes" ;;
  1) echo "==> DRIFT: the cluster and the repository disagree (above)" ;;
  *) echo "==> INCOMPLETE: at least one check could not run (above)" ;;
esac
exit $status
