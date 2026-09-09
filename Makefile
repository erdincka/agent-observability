# Enterprise Agent Observability & Governance Lab
#
# Every command used to build this lab lives here. If a step is not a target in
# this file, it is not reproducible, and the project's done-criterion is that the
# whole thing rebuilds from this repo and LEARNINGS.md alone.

SHELL := /bin/bash
PLATFORM_NS := agent-obs-platform
APP_NS      := agent-obs-app
COLLECTOR_CHART_VERSION := 0.172.1
OPENLIT_CHART_VERSION   := 1.24.0

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
	@set -a; . ./.env; set +a; \
	kubectl create secret generic litellm-auth \
		--namespace $(PLATFORM_NS) \
		--from-literal=LITELLM_MASTER_KEY="$$LITELLM_MASTER_KEY" \
		--from-literal=OLLAMA_BASE_URL="$$OLLAMA_BASE_URL" \
		--from-literal=OPENROUTER_API_KEY="$$OPENROUTER_API_KEY" \
		--dry-run=client -o yaml | kubectl apply -f -
	@set -a; . ./.env; set +a; \
	kubectl create secret generic gateway-auth \
		--namespace $(APP_NS) \
		--from-literal=GATEWAY_API_KEY="$$LITELLM_MASTER_KEY" \
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

.PHONY: openlit
openlit: ## Deploy the OpenLIT UI over our ClickHouse
	helm upgrade --install openlit openlit/openlit \
		--version $(OPENLIT_CHART_VERSION) \
		--namespace $(PLATFORM_NS) \
		--values deploy/30-openlit/values.yaml \
		--wait --timeout 5m
	kubectl apply -f deploy/30-openlit/httproute.yaml

.PHONY: openlit-logs
openlit-logs: ## Tail OpenLIT
	kubectl logs -n $(PLATFORM_NS) -l app.kubernetes.io/name=openlit -f --tail=100

.PHONY: step2
step2: openlit ## Everything in step 2

.PHONY: ollama
ollama: ## Deploy the self-hosted Ollama model route
	kubectl apply -f deploy/40-ollama/ollama.yaml
	kubectl rollout status deployment/ollama -n $(PLATFORM_NS) --timeout=300s

.PHONY: ollama-pull
ollama-pull: env-check ## Pull the default model into Ollama (slow, one-off)
	@set -a; . ./.env; set +a; \
	echo "pulling $$OLLAMA_MODEL ..."; \
	kubectl exec -n $(PLATFORM_NS) deploy/ollama -- ollama pull "$$OLLAMA_MODEL"

.PHONY: litellm
# Depends on `secrets` deliberately. Rendering the config from .env while leaving
# the Secret stale applies half a change: the route appears, its credential does
# not, and the failure surfaces as a 401 from the provider rather than as
# anything pointing at .env. Cost an hour once; not again.
litellm: env-check secrets ## Render config and deploy the LiteLLM gateway
	./scripts/render-litellm-config.py
	kubectl create configmap litellm-config \
		--namespace $(PLATFORM_NS) \
		--from-file=config.yaml=deploy/50-litellm/config.rendered.yaml \
		--dry-run=client -o yaml | kubectl apply -f -
	@set -a; . ./.env; set +a; \
	sum=$$( { cat deploy/50-litellm/config.rendered.yaml; \
		echo "$$OPENROUTER_API_KEY$$LITELLM_MASTER_KEY$$OLLAMA_BASE_URL"; } \
		| shasum -a 256 | cut -c1-16); \
	sed "s/REPLACED_AT_DEPLOY/$$sum/" deploy/50-litellm/litellm.yaml | kubectl apply -f -
	kubectl apply -f deploy/50-litellm/httproute.yaml
	kubectl rollout status deployment/litellm -n $(PLATFORM_NS) --timeout=300s

.PHONY: litellm-logs
litellm-logs: ## Tail the LiteLLM gateway
	kubectl logs -n $(PLATFORM_NS) -l app.kubernetes.io/name=litellm -f --tail=100

.PHONY: step3
step3: ollama ollama-pull litellm ## Everything in step 3

.PHONY: postgres
postgres: ## Deploy the workflow's PostgreSQL (CloudNativePG)
	kubectl apply -f deploy/60-postgres/cluster.yaml
	kubectl wait --for=condition=Ready cluster/workflow-db -n $(APP_NS) --timeout=300s

.PHONY: workflow-image
workflow-image: ## Build and push the workflow image on the pve context
	./scripts/build-image.sh workflow

.PHONY: workflow-probe
workflow-probe: ## Run the plumbing proof: a trace starting in the workflow
	-kubectl delete job workflow-probe -n $(APP_NS) --ignore-not-found
	kubectl apply -f deploy/70-workflow/probe-job.yaml
	kubectl wait --for=condition=complete job/workflow-probe -n $(APP_NS) --timeout=600s
	kubectl logs -n $(APP_NS) job/workflow-probe

.PHONY: mcp-image
mcp-image: ## Build and push the MCP servers image (context = repo root)
	./scripts/build-image.sh mcp 0.1.0 .

.PHONY: mcp
mcp: ## Deploy the three MCP tool servers
	kubectl apply -f deploy/80-mcp/servers.yaml
	kubectl rollout status deployment/mcp-metrics  -n $(APP_NS) --timeout=300s
	kubectl rollout status deployment/mcp-changes  -n $(APP_NS) --timeout=300s
	kubectl rollout status deployment/mcp-runbooks -n $(APP_NS) --timeout=300s

.PHONY: mcp-probe
mcp-probe: ## List the tools each MCP server exposes
	./scripts/mcp-probe.sh

.PHONY: step5
step5: mcp-image mcp mcp-probe ## Everything in step 5
