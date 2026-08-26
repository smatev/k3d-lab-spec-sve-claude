# The only entrypoint anyone should need.
#
# Nothing here is done by hand. If it isn't in the repo, it doesn't exist — the test is
# `make down && make up && make verify`.

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

CLUSTER  := lab
CONTEXT  := k3d-$(CLUSTER)
KUBECTL  := kubectl --context $(CONTEXT)
LOCAL    := .local

# Put mise's shims on PATH for every recipe, so the pinned versions are used whether or
# not the operator has activated mise in their shell — and so bootstrap.sh and verify.sh
# inherit them too. Harmless when mise isn't installed.
MISE_SHIMS := $(HOME)/.local/share/mise/shims
ifneq ($(wildcard $(MISE_SHIMS)),)
export PATH := $(MISE_SHIMS):$(HOME)/.local/bin:$(PATH)
endif

.PHONY: help tools doctor up down bootstrap ca verify idempotent reset dashboard

help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

## --- setup ----------------------------------------------------------------

tools: ## Install the pinned toolchain (mise) plus helm plugins
	mise install
	@# helm-unittest is a helm plugin, not a mise tool. Idempotent: skip if present.
	@if ! helm plugin list 2>/dev/null | grep -q '^unittest'; then \
		helm plugin install https://github.com/helm-unittest/helm-unittest --version 1.1.2; \
	else \
		echo "helm-unittest already installed"; \
	fi

doctor: ## Check every pinned tool is present and on the right version
	./scripts/doctor.sh

## --- cluster lifecycle ----------------------------------------------------

up: ## Create the cluster and bootstrap it
	k3d cluster create --config cluster/k3d.yaml
	$(MAKE) bootstrap
	$(MAKE) ca

down: ## Delete the cluster and every trace of it
	k3d cluster delete --config cluster/k3d.yaml
	rm -rf $(LOCAL)

bootstrap: ## Bootstrap only, against an existing cluster (idempotent)
	./cluster/bootstrap/bootstrap.sh

reset: down up ## down + up

## --- local TLS ------------------------------------------------------------

ca: ## Extract the local root CA to .local/ca.crt
	@mkdir -p $(LOCAL)
	@$(KUBECTL) -n cert-manager get secret k3d-lab-ca \
		-o jsonpath='{.data.ca\.crt}' | base64 -d > $(LOCAL)/ca.crt
	@echo "wrote $(LOCAL)/ca.crt"

## --- the loop that matters ------------------------------------------------

verify: ## Run the acceptance test
	./scripts/verify.sh

idempotent: ## Prove a second bootstrap changes nothing
	./scripts/check-idempotent.sh

## --- conveniences ---------------------------------------------------------

dashboard: ## Port-forward the Traefik dashboard to http://127.0.0.1:8080/dashboard/
	@echo "http://127.0.0.1:8080/dashboard/  (trailing slash required)"
	$(KUBECTL) -n traefik port-forward deploy/traefik 8080:8080
