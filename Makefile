# Enterprise Agent Observability & Governance Lab
#
# Every command used to build this lab lives here. If a step is not a target in
# this file, it is not reproducible, and the project's done-criterion is that the
# whole thing rebuilds from this repo and LEARNINGS.md alone.

SHELL := /bin/bash
PLATFORM_NS := agent-obs-platform
APP_NS      := agent-obs-app
COLLECTOR_CHART_VERSION := 0.172.1

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show available targets
	grep -E '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

.PHONY: env-check
env-check: ## Fail early if .env is missing
	@test -f .env || { echo "ERROR: no .env — copy .env.example to .env and fill it in"; exit 1; }

# ---------------------------------------------------------------- step 1 -----

.PHONY: namespaces
namespaces: ## Create the platform and app namespaces
	kubectl apply -f deploy/00-namespace/namespaces.yaml

.PHONY: secrets
secrets: env-check ## Render .env into Kubernetes Secrets (never committed)
	@set -a; . ./.env; set +a; \
	kubectl create secret generic clickhouse-auth \
		--namespace $(PLATFORM_NS) \
		--from-literal=CLICKHOUSE_USER="$$CLICKHOUSE_USER" \
		--from-literal=CLICKHOUSE_PASSWORD="$$CLICKHOUSE_PASSWORD" \
		--from-literal=CLICKHOUSE_DB="$$CLICKHOUSE_DB" \
		--dry-run=client -o yaml | kubectl apply -f -

.PHONY: clickhouse
clickhouse: ## Deploy ClickHouse (hot store)
	kubectl apply -f deploy/10-clickhouse/clickhouse.yaml
	kubectl rollout status statefulset/clickhouse -n $(PLATFORM_NS) --timeout=300s

.PHONY: collector
collector: ## Deploy the OpenTelemetry Collector
	helm upgrade --install otel-collector \
		open-telemetry/opentelemetry-collector \
		--version $(COLLECTOR_CHART_VERSION) \
		--namespace $(PLATFORM_NS) \
		--values deploy/20-otel-collector/values.yaml \
		--wait --timeout 5m

.PHONY: smoke-trace
smoke-trace: ## Push one hand-built OTLP span and prove it lands in ClickHouse
	./scripts/smoke-trace.sh

.PHONY: ch
ch: ## Open a clickhouse-client shell against the cluster instance
	@set -a; . ./.env; set +a; \
	kubectl exec -it -n $(PLATFORM_NS) clickhouse-0 -- \
		clickhouse-client --user "$$CLICKHOUSE_USER" --password "$$CLICKHOUSE_PASSWORD" --database "$$CLICKHOUSE_DB"

.PHONY: ch-query
ch-query: ## Run one SQL statement: make ch-query Q="select 1"
	@set -a; . ./.env; set +a; \
	kubectl exec -i -n $(PLATFORM_NS) clickhouse-0 -- \
		clickhouse-client --user "$$CLICKHOUSE_USER" --password "$$CLICKHOUSE_PASSWORD" \
		--database "$$CLICKHOUSE_DB" --query "$(Q)"

.PHONY: collector-logs
collector-logs: ## Tail the Collector
	kubectl logs -n $(PLATFORM_NS) -l app.kubernetes.io/name=opentelemetry-collector -f --tail=100

.PHONY: step1
step1: namespaces secrets clickhouse collector smoke-trace ## Everything in step 1, in order
