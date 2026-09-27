# Enterprise Agent Observability & Governance Lab
#
# Every command used to build this lab lives here. If a step is not a target in
# this file, it is not reproducible, and the project's done-criterion is that the
# whole thing rebuilds from this repo and LEARNINGS.md alone.

SHELL := /bin/bash
PLATFORM_NS := agent-obs-platform
# Defaults for `make workflow-triage`; override on the command line.
INCIDENT    ?= checkout-latency
ROUTE       ?= local
# Identity (chapters 6 and 7): on whose behalf, in which role, on which key.
PRINCIPAL   ?= oncall-engineer
AGENT_ROLE  ?= reader
KEY_PROFILE ?= per-agent
# Chapter 8: SDK content capture on for one run, to show redaction working.
CAPTURE     ?= false
APP_NS      := agent-obs-app
COLLECTOR_CHART_VERSION := 0.172.1
OPENLIT_CHART_VERSION   := 1.24.0
REGISTRY    := 10.1.1.240:5000

# Immutable image tags: the last commit that touched each image's inputs, with
# `-dirty` appended when those inputs have uncommitted changes. Recursive (=), so
# they are read when used. See scripts/image-tag.sh and scripts/build-image.sh.
WORKFLOW_TAG = $(shell scripts/image-tag.sh workflow)
MCP_TAG      = $(shell scripts/image-tag.sh mcp)
PERSES_TAG   = $(shell scripts/image-tag.sh perses)
PERSES_CHART_VERSION := 0.23.2
# A clean tag names exactly one image, so a cached copy is correct. A -dirty tag
# is rebuilt in place, so it has to be pulled every time.
pull_policy  = $(if $(findstring -dirty,$(1)),Always,IfNotPresent)

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show available targets
	grep -E '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

.PHONY: env-check
env-check: ## Fail early if .env is missing
	@test -f .env || { echo "ERROR: no .env — copy .env.example to .env and fill it in"; exit 1; }

# ---------------------------------------------------------------- step 0 -----
# MinIO lives outside the cluster, so it comes before the cluster's own steps.

.PHONY: minio-vm
minio-vm: env-check ## Provision the standalone MinIO VM on the Proxmox host
	./deploy/05-minio/provision-vm.sh

.PHONY: minio-buckets
minio-buckets: env-check ## Create the buckets and the cluster's scoped credential
	./deploy/05-minio/bootstrap-buckets.sh

.PHONY: minio-secret
# The scoped key, not the root credential — the root user never enters the
# cluster. Published into both namespaces because the consumers are split
# across them: telemetry archival on the platform side, database backups and
# workflow artefacts on the app side.
minio-secret: env-check namespaces ## Publish the MinIO credential into both namespaces
	@set -a; . ./.env; set +a; \
	for ns in $(PLATFORM_NS) $(APP_NS); do \
		kubectl create secret generic minio-auth \
			--namespace $$ns \
			--from-literal=AWS_ACCESS_KEY_ID="$$MINIO_K8S_ACCESS_KEY" \
			--from-literal=AWS_SECRET_ACCESS_KEY="$$MINIO_K8S_SECRET_KEY" \
			--from-literal=S3_ENDPOINT="$$MINIO_ENDPOINT" \
			--dry-run=client -o yaml | kubectl apply -f -; \
	done

.PHONY: minio-verify
minio-verify: env-check ## Round-trip an object from inside the cluster, and prove the key is scoped
	./deploy/05-minio/verify-from-cluster.sh

.PHONY: minio-status
minio-status: env-check ## Show the MinIO service and its disk
	@set -a; . ./.env; set +a; \
	ssh "$${MINIO_VM_USER:-ubuntu}@$$MINIO_VM_IP" \
		'systemctl is-active minio; df -h /mnt/minio/disk1; sudo mc --version 2>/dev/null | head -1'

.PHONY: minio
minio: minio-vm minio-buckets minio-secret minio-verify ## Everything MinIO, in order

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
		--from-literal=CLICKHOUSE_RESTRICTED_PASSWORD="$$CLICKHOUSE_RESTRICTED_PASSWORD" \
		--dry-run=client -o yaml | kubectl apply -f -
	@set -a; . ./.env; set +a; \
	kubectl create secret generic perses-clickhouse \
		--namespace $(PLATFORM_NS) \
		--from-literal=password="$$CLICKHOUSE_PERSES_PASSWORD" \
		--dry-run=client -o yaml | kubectl apply -f -
	@set -a; . ./.env; set +a; \
	kubectl create secret generic litellm-auth \
		--namespace $(PLATFORM_NS) \
		--from-literal=LITELLM_MASTER_KEY="$$LITELLM_MASTER_KEY" \
		--from-literal=OLLAMA_BASE_URL="$$OLLAMA_BASE_URL" \
		--from-literal=OPENROUTER_API_KEY="$$OPENROUTER_API_KEY" \
		--from-literal=LITELLM_SALT_KEY="$$LITELLM_SALT_KEY" \
		--from-literal=LITELLM_UI_USERNAME="$$LITELLM_UI_USERNAME" \
		--from-literal=LITELLM_UI_PASSWORD="$$LITELLM_UI_PASSWORD" \
		--dry-run=client -o yaml | kubectl apply -f -
	@set -a; . ./.env; set +a; \
	kubectl create secret generic gateway-auth \
		--namespace $(APP_NS) \
		--from-literal=GATEWAY_API_KEY="$$LITELLM_MASTER_KEY" \
		--dry-run=client -o yaml | kubectl apply -f -
	@set -a; . ./.env; set +a; \
	kubectl create secret generic agent-tool-tokens \
		--namespace $(APP_NS) \
		--from-literal=TOOL_TOKEN_READER="$$TOOL_TOKEN_READER" \
		--from-literal=TOOL_TOKEN_OPERATOR="$$TOOL_TOKEN_OPERATOR" \
		--dry-run=client -o yaml | kubectl apply -f -

.PHONY: clickhouse
clickhouse: minio-secret ## Deploy ClickHouse (hot store, with the S3 cold disk)
	kubectl apply -f deploy/10-clickhouse/clickhouse.yaml
	kubectl rollout status statefulset/clickhouse -n $(PLATFORM_NS) --timeout=300s

.PHONY: collector
collector: minio-secret ## Deploy the OpenTelemetry Collector
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

.PHONY: litellm-db
litellm-db: ## Deploy the LiteLLM gateway's PostgreSQL (CloudNativePG)
	kubectl apply -f deploy/45-litellm-db/cluster.yaml
	kubectl wait --for=condition=Ready cluster/litellm-db -n $(PLATFORM_NS) --timeout=300s

.PHONY: litellm
# Depends on `secrets` deliberately. Rendering the config from .env while leaving
# the Secret stale applies half a change: the route appears, its credential does
# not, and the failure surfaces as a 401 from the provider rather than as
# anything pointing at .env. Cost an hour once; not again.
litellm: env-check secrets litellm-db ## Render config and deploy the LiteLLM gateway
	./scripts/render-litellm-config.py
	kubectl create configmap litellm-config \
		--namespace $(PLATFORM_NS) \
		--from-file=config.yaml=deploy/50-litellm/config.rendered.yaml \
		--from-file=agent_obs_guardrail.py=deploy/50-litellm/agent_obs_guardrail.py \
		--dry-run=client -o yaml | kubectl apply -f -
	@sum=$$(./scripts/litellm-checksum.sh); \
	sed "s/REPLACED_AT_DEPLOY/$$sum/" deploy/50-litellm/litellm.yaml | kubectl apply -f -
	kubectl apply -f deploy/50-litellm/httproute.yaml
	kubectl rollout status deployment/litellm -n $(PLATFORM_NS) --timeout=300s

.PHONY: litellm-keys
# Runs inside the gateway pod: no route from the workstation is needed and the
# master key never leaves the pod's environment. Idempotent. The keys are
# deterministic from the master key, so re-running renders the same Secret.
litellm-keys: ## Mint the per-agent virtual keys and publish them as Secret agent-keys (chapter 6)
	@kubectl exec -i -n $(PLATFORM_NS) deploy/litellm -- python - < scripts/litellm-keys.py > /tmp/agent-keys.json
	@python3 -c 'import json,sys; d=json.load(open("/tmp/agent-keys.json")); print("\n".join(f"--from-literal={k}={v}" for k,v in d.items()))' \
		| xargs kubectl create secret generic agent-keys --namespace $(APP_NS) --dry-run=client -o yaml \
		| kubectl apply -f -
	@rm -f /tmp/agent-keys.json
	@echo "agent-keys published: $$(kubectl get secret agent-keys -n $(APP_NS) -o jsonpath='{.data}' | python3 -c 'import json,sys; print(sorted(json.load(sys.stdin)))')"

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
	./scripts/require-image.sh workflow
	-kubectl delete job workflow-probe -n $(APP_NS) --ignore-not-found
	sed -e 's|__WORKFLOW_TAG__|$(WORKFLOW_TAG)|g' -e 's|__PULL_POLICY__|$(call pull_policy,$(WORKFLOW_TAG))|g' \
		deploy/70-workflow/probe-job.yaml | kubectl apply -f -
	kubectl wait --for=condition=complete job/workflow-probe -n $(APP_NS) --timeout=600s
	kubectl logs -n $(APP_NS) job/workflow-probe

.PHONY: workflow-triage
# INCIDENT and ROUTE are templated into the Job so a comparison run is a flag,
# not an edit: `make workflow-triage ROUTE=remote INCIDENT=no-evidence`.
workflow-triage: ## Run the triage workflow (INCIDENT=, ROUTE=)
	./scripts/require-image.sh workflow
	-kubectl delete job workflow-triage -n $(APP_NS) --ignore-not-found
	sed -e 's|__INCIDENT__|$(INCIDENT)|' -e 's|__ROUTE__|$(ROUTE)|' \
		-e 's|__PRINCIPAL__|$(PRINCIPAL)|' -e 's|__AGENT_ROLE_UPPER__|$(shell echo $(AGENT_ROLE) | tr a-z A-Z)|' \
		-e 's|__AGENT_ROLE__|$(AGENT_ROLE)|' -e 's|__KEY_PROFILE__|$(KEY_PROFILE)|' -e 's|__CAPTURE__|$(CAPTURE)|' \
		-e 's|__WORKFLOW_TAG__|$(WORKFLOW_TAG)|g' -e 's|__PULL_POLICY__|$(call pull_policy,$(WORKFLOW_TAG))|g' \
		deploy/70-workflow/triage-job.yaml | kubectl apply -f -
	kubectl wait --for=condition=complete job/workflow-triage -n $(APP_NS) --timeout=900s
	kubectl logs -n $(APP_NS) job/workflow-triage

.PHONY: workflow-call
# One tool call, no model: the deterministic authorization probe (chapter 7).
#   make workflow-call TOOL=restart_deployment ARGS=name=mcp-runbooks AGENT_ROLE=reader    -> denied
#   make workflow-call TOOL=restart_deployment ARGS=name=mcp-runbooks AGENT_ROLE=operator  -> restarted
workflow-call: ## Call one MCP tool as AGENT_ROLE (TOOL=, ARGS=k=v)
	@./scripts/require-image.sh workflow
	@set -a; . ./.env; set +a; \
	tok=$$(eval echo \$$TOOL_TOKEN_$(shell echo $(AGENT_ROLE) | tr a-z A-Z)); \
	kubectl run workflow-call-$$$$ --namespace $(APP_NS) --rm -i --quiet --restart=Never \
		--labels=app.kubernetes.io/name=workflow,agent-obs.io/governed=true \
		--image=$(REGISTRY)/agent-obs/workflow:$(WORKFLOW_TAG) \
		--image-pull-policy=$(call pull_policy,$(WORKFLOW_TAG)) \
		--env=AGENT_ROLE=$(AGENT_ROLE) --env=TOOL_TOKEN=$$tok --env=PRINCIPAL=$(PRINCIPAL) \
		--command -- python -m workflow --call $(TOOL) $(ARGS)

.PHONY: workflow-incidents
workflow-incidents: ## List the fixed incident corpus
	@./scripts/require-image.sh workflow
	kubectl run workflow-incidents-$$$$ --namespace $(APP_NS) --rm -i --quiet \
		--restart=Never --image=$(REGISTRY)/agent-obs/workflow:$(WORKFLOW_TAG) \
		--image-pull-policy=$(call pull_policy,$(WORKFLOW_TAG)) \
		--command -- python -m workflow --list

.PHONY: mcp-image
mcp-image: ## Build and push the MCP servers image (context = repo root)
	./scripts/build-image.sh mcp .

.PHONY: mcp
mcp: secrets ## Deploy the four MCP tool servers and the role->tool policy
	./scripts/require-image.sh mcp
	kubectl create configmap tool-policy --namespace $(APP_NS) \
		--from-file=policy.json=deploy/80-mcp/policy.json \
		--dry-run=client -o yaml | kubectl apply -f -
	sed -e 's|__MCP_TAG__|$(MCP_TAG)|g' -e 's|__PULL_POLICY__|$(call pull_policy,$(MCP_TAG))|g' \
		deploy/80-mcp/servers.yaml | kubectl apply -f -
	kubectl rollout status deployment/mcp-metrics  -n $(APP_NS) --timeout=300s
	kubectl rollout status deployment/mcp-changes  -n $(APP_NS) --timeout=300s
	kubectl rollout status deployment/mcp-runbooks -n $(APP_NS) --timeout=300s
	kubectl rollout status deployment/mcp-ops      -n $(APP_NS) --timeout=300s

# ------------------------------------------------------------ chapter 8 ------

.PHONY: ch-restricted-user
# A reader that can SELECT from the restricted database and nothing else. The
# password comes from .env (CLICKHOUSE_RESTRICTED_PASSWORD); the statement is
# idempotent. `make demo-restricted-access` proves the scope both ways.
ch-restricted-user: env-check ## Create the restricted-store reader in ClickHouse (chapter 8)
	@set -a; . ./.env; set +a; \
	kubectl exec -i -n $(PLATFORM_NS) clickhouse-0 -- \
		clickhouse-client --user "$$CLICKHOUSE_USER" --password "$$CLICKHOUSE_PASSWORD" --multiquery --query \
		"CREATE DATABASE IF NOT EXISTS otel_restricted; \
		 CREATE USER IF NOT EXISTS restricted_reader IDENTIFIED WITH sha256_password BY '$$CLICKHOUSE_RESTRICTED_PASSWORD'; \
		 GRANT SELECT ON otel_restricted.* TO restricted_reader; \
		 REVOKE SELECT ON otel.* FROM restricted_reader;"
	@echo "restricted_reader: SELECT on otel_restricted.* only"

.PHONY: retention
# Switches the hot table to the tiered policy and sets the retention TTL:
# parts move to the S3 volume after a day and are deleted after seven years.
# The exporter's own 30-day DELETE TTL is replaced, not extended: the archive
# in MinIO is the long-horizon copy, and the cold volume is what ClickHouse
# still queries. Idempotent.
retention: ## Put otel_traces on the tiered storage policy with a 7-year TTL (chapter 8)
	$(MAKE) -s ch-query Q="ALTER TABLE otel.otel_traces MODIFY SETTING storage_policy='tiered'"
	$(MAKE) -s ch-query Q="ALTER TABLE otel.otel_traces MODIFY TTL toDateTime(Timestamp) + toIntervalDay(1) TO VOLUME 'cold', toDateTime(Timestamp) + toIntervalYear(7) DELETE"
	$(MAKE) -s ch-query Q="SELECT name AS table, storage_policy FROM system.tables WHERE database='otel' AND name='otel_traces'"

.PHONY: retention-status
retention-status: ## Where each partition of otel_traces lives (hot disk or S3), and what the archive holds
	@echo "--- otel_traces parts by disk ---"
	@$(MAKE) -s ch-query Q="SELECT partition, disk_name, count() AS parts, formatReadableSize(sum(bytes_on_disk)) AS size, sum(rows) AS rows FROM system.parts WHERE database='otel' AND table='otel_traces' AND active GROUP BY partition, disk_name ORDER BY partition FORMAT PrettyCompact"
	@echo "--- objects in MinIO ---"
	@./deploy/05-minio/list-buckets.sh otel-archive clickhouse-cold

.PHONY: retention-move-oldest
retention-move-oldest: ## Move the oldest hot partition of otel_traces to the S3 volume now (what the TTL does nightly)
	@p=$$($(MAKE) -s ch-query Q="SELECT min(partition) FROM system.parts WHERE database='otel' AND table='otel_traces' AND active AND disk_name='default'"); \
	echo "moving partition $$p to volume cold"; \
	$(MAKE) -s ch-query Q="ALTER TABLE otel.otel_traces MOVE PARTITION '$$p' TO VOLUME 'cold'"; \
	$(MAKE) -s ch-query Q="SELECT partition, disk_name, rows FROM system.parts WHERE database='otel' AND table='otel_traces' AND active AND partition='$$p' FORMAT PrettyCompact"

.PHONY: restricted-promote
restricted-promote: env-check ## Copy flagged traces, whole, into the restricted store (chapter 8)
	./scripts/promote-flagged.sh

.PHONY: demo-content-redacted
# The honest version of the no-content claim: emit content on purpose, prove
# it never lands. The run's spans carry redaction.masked.keys instead.
demo-content-redacted: ## Turn SDK content capture ON for one run and prove the Collector strips it before storage
	$(MAKE) workflow-triage CAPTURE=true
	@./scripts/content-check.sh "$$(kubectl logs -n $(APP_NS) job/workflow-triage | sed -n 's/^=== run \([0-9a-f]*\) .*/\1/p')"

.PHONY: demo-restricted-access
demo-restricted-access: env-check ## The restricted reader can read otel_restricted and is refused on otel
	@set -a; . ./.env; set +a; \
	echo -n "restricted_reader on otel_restricted.otel_traces: "; \
	kubectl exec -i -n $(PLATFORM_NS) clickhouse-0 -- clickhouse-client --user restricted_reader --password "$$CLICKHOUSE_RESTRICTED_PASSWORD" \
		--query "SELECT count() AS flagged_spans FROM otel_restricted.otel_traces" ; \
	echo -n "restricted_reader on otel.otel_traces: "; \
	out=$$(kubectl exec -i -n $(PLATFORM_NS) clickhouse-0 -- clickhouse-client --user restricted_reader --password "$$CLICKHOUSE_RESTRICTED_PASSWORD" \
		--query "SELECT count() FROM otel.otel_traces" 2>&1); \
	case "$$out" in *ACCESS_DENIED*|*"Not enough privileges"*) echo "refused (ACCESS_DENIED) — as intended";; *) echo "UNEXPECTED: $$out"; exit 1;; esac

# ------------------------------------------------------------ chapter 10 -----

.PHONY: perses-image
perses-image: ## Build Perses with the ClickHouse trace-query plugin from the upstream PR
	./scripts/build-image.sh perses

.PHONY: ch-perses-user
ch-perses-user: env-check ## Create the read-only ClickHouse user Perses queries as
	@set -a; . ./.env; set +a; \
	kubectl exec -i -n $(PLATFORM_NS) clickhouse-0 -- \
		clickhouse-client --user "$$CLICKHOUSE_USER" --password "$$CLICKHOUSE_PASSWORD" --multiquery --query \
		"CREATE USER IF NOT EXISTS perses_reader IDENTIFIED WITH sha256_password BY '$$CLICKHOUSE_PERSES_PASSWORD'; \
		 GRANT SELECT ON otel.* TO perses_reader; GRANT SELECT ON otel_restricted.* TO perses_reader; \
		 GRANT SELECT ON system.parts TO perses_reader;"
	@echo "perses_reader: SELECT on otel.*, otel_restricted.*, system.parts"

.PHONY: perses-dashboards
perses-dashboards: ## (Re)publish the provisioning files as the ConfigMap Perses reads
	kubectl create configmap perses-provisioning --namespace $(PLATFORM_NS) \
		--from-file=deploy/90-perses/provisioning/ \
		--dry-run=client -o yaml | kubectl apply -f -

.PHONY: perses
perses: secrets ch-perses-user perses-dashboards ## Deploy Perses (chapter 10)
	./scripts/require-image.sh perses
	sed -e 's|__REGISTRY__|$(REGISTRY)|' -e 's|__PERSES_TAG__|$(PERSES_TAG)|' -e 's|__PULL_POLICY__|$(call pull_policy,$(PERSES_TAG))|' \
		deploy/90-perses/values.yaml > /tmp/perses-values.rendered.yaml
	helm upgrade --install perses perses/perses \
		--version $(PERSES_CHART_VERSION) \
		--namespace $(PLATFORM_NS) \
		--values /tmp/perses-values.rendered.yaml \
		--wait --timeout 5m
	kubectl apply -f deploy/90-perses/httproute.yaml

.PHONY: perses-logs
perses-logs: ## Tail Perses
	kubectl logs -n $(PLATFORM_NS) -l app.kubernetes.io/name=perses -f --tail=100

# ------------------------------------------------------------ chapter 11 -----
MLFLOW_CHART_VERSION := 1.11.7
N ?= 1

.PHONY: mlflow-db
mlflow-db: ## Deploy MLflow's PostgreSQL (CloudNativePG)
	kubectl apply -f deploy/95-mlflow/cluster.yaml
	kubectl wait --for=condition=Ready cluster/mlflow-db -n $(PLATFORM_NS) --timeout=300s

.PHONY: mlflow
mlflow: env-check minio-secret mlflow-db ## Deploy MLflow, the evaluation loop (chapter 11)
	@set -a; . ./.env; set +a; \
	sed -e "s|__MINIO_ENDPOINT__|$$MINIO_ENDPOINT|" deploy/95-mlflow/values.yaml > /tmp/mlflow-values.rendered.yaml
	@u=$$(kubectl get secret mlflow-db-app -n $(PLATFORM_NS) -o jsonpath='{.data.username}' | base64 -d); \
	p=$$(kubectl get secret mlflow-db-app -n $(PLATFORM_NS) -o jsonpath='{.data.password}' | base64 -d); \
	helm upgrade --install mlflow community-charts/mlflow \
		--version $(MLFLOW_CHART_VERSION) \
		--namespace $(PLATFORM_NS) \
		--values /tmp/mlflow-values.rendered.yaml \
		--set backendStore.postgres.user="$$u" --set backendStore.postgres.password="$$p" \
		--wait --timeout 10m
	kubectl apply -f deploy/95-mlflow/httproute.yaml

.PHONY: evaluate
evaluate: ## Run the corpus N times and score each run in MLflow: make evaluate N=1 ROUTE=local
	./scripts/evaluate.py --n $(N) --route $(ROUTE)

.PHONY: mlflow-logs
mlflow-logs: ## Tail MLflow
	kubectl logs -n $(PLATFORM_NS) -l app.kubernetes.io/name=mlflow -f --tail=100

# ------------------------------------------------------------ chapter 9 ------

.PHONY: receipt
receipt: ## The reviewer's receipt for one run: make receipt RUN=<run id>
	@./scripts/receipt.sh $(RUN)

.PHONY: runs
runs: ## List recent runs with outcome per agent
	@$(MAKE) -s ch-query Q="SELECT r.run AS run, r.incident AS incident, r.route AS route, r.started AS started, arrayStringConcat(groupArray(concat(a.agent, '=', a.outcome)), ' ') AS outcomes FROM (SELECT SpanAttributes['triage.run_id'] AS run, SpanAttributes['triage.incident_id'] AS incident, SpanAttributes['triage.model_route'] AS route, toStartOfSecond(Timestamp) AS started, TraceId FROM otel_traces WHERE SpanName='triage_run') AS r LEFT JOIN (SELECT TraceId, SpanAttributes['gen_ai.agent.name'] AS agent, SpanAttributes['triage.outcome'] AS outcome FROM otel_traces WHERE SpanAttributes['gen_ai.operation.name']='invoke_agent' AND SpanAttributes['triage.outcome']!='') AS a ON r.TraceId=a.TraceId GROUP BY 1,2,3,4 ORDER BY started DESC LIMIT 20 FORMAT PrettyCompact"

.PHONY: netpol
netpol: ## Apply the NetworkPolicies that make the gateway unbypassable (chapter 7)
	kubectl apply -f deploy/85-netpol/policies.yaml

# ------------------------------------------------------------- demos (ch 6/7) --
# Each one is a run whose trace shows a control being applied. Read the
# outcome on the triage.agent spans (triage.outcome, triage.denied_by) and on
# the tool servers' spans (authz.decision).
#
# One at a time. The triage demos share the `workflow-triage` Job name, and a
# second one started while the first runs deletes it — the first then reports
# the second's logs as its own.

.PHONY: demo-model-denied
demo-model-denied: ## Every agent on a key that may only use `remote`, run on `local`: gateway refuses
	$(MAKE) workflow-triage KEY_PROFILE=restricted ROUTE=local

.PHONY: demo-rate-limited
demo-rate-limited: ## Every agent on a 2 rpm key: the retriever is cut off mid-loop
	$(MAKE) workflow-triage KEY_PROFILE=throttled

.PHONY: demo-guardrail
demo-guardrail: ## An incident containing a credential-shaped string: the guardrail refuses it
	$(MAKE) workflow-triage INCIDENT=leaked-secret

.PHONY: demo-tool-denied
demo-tool-denied: ## The reader role asks mcp-ops to restart a deployment: denied on the server's span
	$(MAKE) workflow-call TOOL=restart_deployment ARGS=name=mcp-runbooks AGENT_ROLE=reader

.PHONY: demo-tool-allowed
demo-tool-allowed: ## The operator role does the same: allowed, and mcp-runbooks restarts
	$(MAKE) workflow-call TOOL=restart_deployment ARGS=name=mcp-runbooks AGENT_ROLE=operator

.PHONY: demo-egress-denied
# The probe sleeps before its first request. k3s's embedded network policy
# controller (kube-router) programs a new pod's firewall chain asynchronously
# after the pod appears, and a request in the first second or two goes through.
# Measured on this cluster: +0s allowed, +2s and later blocked. A finding in its
# own right (chapter 7): policy takes effect shortly after a pod starts, not
# at the instant it starts.
demo-egress-denied: ## A governed pod tries Ollama directly, around the gateway: blocked; via the gateway: fine
	@kubectl run egress-probe-$$$$ --namespace $(APP_NS) --rm -i --quiet --restart=Never \
		--labels=app.kubernetes.io/name=workflow,agent-obs.io/governed=true \
		--image=curlimages/curl:8.10.1 -- sh -c '\
		sleep 3; \
		c=$$(curl -s -m 4 -o /dev/null -w "%{http_code}" http://ollama.agent-obs-platform.svc.cluster.local:11434/api/tags || true); \
		echo "ollama direct, around the gateway: $${c:-blocked} (expected: blocked)"; \
		c=$$(curl -s -m 4 -o /dev/null -w "%{http_code}" http://litellm.agent-obs-platform.svc.cluster.local:4000/health/liveliness || true); \
		echo "gateway: HTTP $${c:-blocked} (expected: 200)"' 2>&1 | grep -v "^warning"

.PHONY: mcp-probe
mcp-probe: ## List the tools each MCP server exposes
	./scripts/mcp-probe.sh

.PHONY: mcp-degrade-test
mcp-degrade-test: ## Prove one unreachable tool server degrades a run instead of aborting it
	./scripts/require-image.sh workflow
	./scripts/mcp-degrade-test.sh

.PHONY: step5
step5: mcp-image mcp mcp-probe ## Everything in step 5

# ------------------------------------------------------------ verification ---

.PHONY: teardown
# Deliberately not wired into any other target, and refuses to run without
# CONFIRM=yes. The inverse of the build: see scripts/teardown.sh for why the
# order (releases, then CNPG clusters, then namespaces) is not arbitrary.
teardown: ## Remove the lab from the cluster (CONFIRM=yes); leaves MinIO and lab infrastructure alone
	CONFIRM=$(CONFIRM) ./scripts/teardown.sh

.PHONY: drift
drift: env-check ## Does the cluster run what this repo describes? (kubectl diff + helm values)
	./scripts/drift.sh
