SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

SERVICES := auth-svc tasks-svc notifier-svc
ROOT := $(shell pwd)

help: ## Show this help
	@awk 'BEGIN {FS=":.*##"} /^[a-zA-Z_-]+:.*##/ {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# ── Apps ────────────────────────────────────────────────────────────────
mod-tidy: ## Run go mod tidy for every Go service (creates go.sum)
	@for s in $(SERVICES); do echo "→ $$s"; (cd apps/$$s && go mod tidy); done

vet: ## go vet across all Go services
	@for s in $(SERVICES); do echo "→ $$s"; (cd apps/$$s && go vet ./...); done

test: ## Run unit tests in every Go service
	@for s in $(SERVICES); do echo "→ $$s"; (cd apps/$$s && go test ./... -race -count=1); done

frontend-dev: ## Run the Next.js frontend in dev mode
	cd apps/frontend && npm install && npm run dev

# ── Helm ────────────────────────────────────────────────────────────────
chart-lint: ## helm lint each chart
	@for c in charts/*/; do echo "→ $$c"; helm lint --strict $$c; done

chart-template: ## helm template a chart against an env's overlay (CHART=auth-svc ENV=dev)
	@helm template charts/$(CHART) \
		-f gitops/overlays/$(ENV)/_common.yaml \
		-f gitops/overlays/$(ENV)/$(CHART).yaml

# ── Terraform ───────────────────────────────────────────────────────────
tf-fmt: ## terraform fmt -recursive
	terraform -chdir=infra/terraform fmt -recursive

tf-validate: ## terraform validate every env (run after init)
	@for e in _shared nonprod prod; do \
		echo "→ envs/$$e"; \
		terraform -chdir=infra/terraform/envs/$$e validate || exit 1; \
	done

# ── Demos ───────────────────────────────────────────────────────────────
demo-ami: ## Run AMI-rotation demo against $(URL)
	./tools/scripts/demo-ami-rotation.sh $(URL)

demo-schema: ## Print the schema-migration walkthrough
	./tools/scripts/demo-schema-migration.sh

k6-zero-downtime: ## Probe an env for dropped requests (URL=https://...)
	k6 run -e BASE_URL=$(URL) tools/load-test/k6-zero-downtime.js

.PHONY: help mod-tidy vet test frontend-dev chart-lint chart-template tf-fmt tf-validate demo-ami demo-schema k6-zero-downtime
