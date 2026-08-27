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
HELM     := helm --kube-context $(CONTEXT)
LOCAL    := .local

# Part 2. Overridable so a second release can be installed side by side — which is how
# the Gateway's cross-namespace routing gets exercised for real:
#   make install RELEASE=demo-api-b NAMESPACE=demo-api-b
CHART     := charts/demo-api
RELEASE   ?= demo-api
NAMESPACE ?= demo-api

# Put mise's shims on PATH for every recipe, so the pinned versions are used whether or
# not the operator has activated mise in their shell — and so bootstrap.sh and verify.sh
# inherit them too. Harmless when mise isn't installed.
MISE_SHIMS := $(HOME)/.local/share/mise/shims
ifneq ($(wildcard $(MISE_SHIMS)),)
export PATH := $(MISE_SHIMS):$(HOME)/.local/bin:$(PATH)
endif

.PHONY: help tools doctor up down bootstrap ca verify idempotent reset dashboard \
        schemas build lint unit install uninstall smoke ct-install rollout hpa ci \
        chart-push gitops-push gitops gitops-test argocd-ui gitea-ui argocd-password

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

## --- the chart ------------------------------------------------------------

schemas: ## Generate CRD JSON schemas for kubeconform (into .local/, gitignored)
	./scripts/gen-schemas.sh

build: ## Build the app image and push it to the k3d registry
	./scripts/build.sh

lint: schemas ## helm lint, ct lint, kubeconform --strict, kube-score
	./scripts/lint.sh

unit: ## Template logic tests (helm unittest) — no cluster needed
	helm unittest $(CHART)

install: ## helm upgrade --install --atomic
	@# --atomic rolls back a failed upgrade instead of leaving the release wedged
	@# half-applied, and it implies --wait: the command returns when the pods are
	@# actually ready, not when the API server accepted the objects. --timeout bounds
	@# how long "actually ready" is allowed to take, because --atomic without one waits
	@# forever on an image that will never pull.
	$(HELM) upgrade --install $(RELEASE) $(CHART) \
		--namespace $(NAMESPACE) --create-namespace \
		--atomic --timeout 5m

uninstall: ## Remove the release and its namespace
	-$(HELM) uninstall $(RELEASE) --namespace $(NAMESPACE) --wait
	-$(KUBECTL) delete namespace $(NAMESPACE) --ignore-not-found

smoke: ## helm test (in-cluster) + host-side check through the Gateway
	RELEASE=$(RELEASE) NAMESPACE=$(NAMESPACE) ./scripts/smoke.sh

ct-install: ## Install every ci/ value set into a throwaway namespace and helm test it
	ct install --config ct.yaml

rollout: ## Prove: config change rolls pods, a rollout under load drops nothing, rollback works
	RELEASE=$(RELEASE) NAMESPACE=$(NAMESPACE) ./scripts/rollout-test.sh

hpa: ## Prove: /api/v1/burn scales the HPA up, and it scales back down afterwards
	RELEASE=$(RELEASE) NAMESPACE=$(NAMESPACE) ./scripts/hpa-test.sh

ci: lint unit build install smoke ## The loop that matters
	@printf '\n\033[1;32mci: green\033[0m\n'

## --- Part 3: GitOps ---------------------------------------------------------

chart-push: ## Package the chart and push it to the k3d registry as an OCI artifact
	./scripts/chart-push.sh

gitops-push: ## Publish this repo (HEAD) to the in-cluster Gitea that Argo CD watches
	./scripts/gitops-push.sh

gitops: build chart-push gitops-push ## Publish image + chart + repo, then wait for Argo CD to converge
	@# Nothing here applies a workload. It publishes artifacts and then waits for the
	@# cluster to agree with the repository on its own.
	@printf '\n\033[1;34m==>\033[0m Waiting for Argo CD to converge\n'
	$(KUBECTL) -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced \
		application/root --timeout=180s
	$(KUBECTL) -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced \
		application/demo-api --timeout=300s
	$(KUBECTL) -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy \
		application/demo-api --timeout=300s
	@printf '\n\033[1;32mgitops: converged\033[0m\n'

gitops-test: ## Prove: delete a Deployment by hand and watch Argo CD put it back
	./scripts/gitops-test.sh

argocd-ui: ## Port-forward the Argo CD UI to http://127.0.0.1:8081 (user: admin)
	@echo "http://127.0.0.1:8081   user 'admin', password from: make argocd-password"
	$(KUBECTL) -n argocd port-forward svc/argocd-server 8081:80

argocd-password: ## Print the generated Argo CD admin password
	@$(KUBECTL) -n argocd get secret argocd-initial-admin-secret \
		-o jsonpath='{.data.password}' | base64 -d; echo

gitea-ui: ## Port-forward Gitea to http://127.0.0.1:3300 (user: lab / lab-not-a-secret)
	@echo "http://127.0.0.1:3300   user 'lab', password 'lab-not-a-secret'"
	$(KUBECTL) -n gitea port-forward svc/gitea-http 3300:3000

## --- conveniences ---------------------------------------------------------

dashboard: ## Port-forward the Traefik dashboard to http://127.0.0.1:8080/dashboard/
	@echo "http://127.0.0.1:8080/dashboard/  (trailing slash required)"
	$(KUBECTL) -n traefik port-forward deploy/traefik 8080:8080
