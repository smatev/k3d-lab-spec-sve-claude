#!/usr/bin/env bash
#
# Bootstrap the lab cluster: Gateway API CRDs, cert-manager + a local CA, Traefik, the
# shared Gateway, and then the GitOps machinery — an in-cluster Git server and Argo CD.
#
# Idempotent by construction — every step is `apply` or `upgrade --install` followed by
# an explicit wait, so running it twice changes nothing. `make bootstrap` proves it.
#
# Ordering matters in exactly one place: Traefik's Gateway API provider needs the CRDs
# to exist when it starts, so the CRDs go first.
#
# Where this script stops is the interesting part. It installs Argo CD and applies ONE
# Application — the root. Every workload after that arrives because it was committed,
# not because anything here applied it. `make gitops` publishes the repo to the
# in-cluster Gitea and the cluster converges on its own.

set -euo pipefail

readonly CONTEXT="k3d-lab"
readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

readonly CERT_MANAGER_VERSION="v1.21.1"
readonly TRAEFIK_CHART_VERSION="41.3.0"
readonly GITEA_CHART_VERSION="12.7.0"
readonly ARGOCD_CHART_VERSION="10.4.0"

# Pin the context on every call. This repo touches k3d-lab and nothing else — never the
# operator's current context, whatever that happens to be.
k() { kubectl --context "${CONTEXT}" "$@"; }
h() { helm --kube-context "${CONTEXT}" "$@"; }

step() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }

require_cluster() {
  if ! k cluster-info >/dev/null 2>&1; then
    echo "error: context '${CONTEXT}' is unreachable. Run 'make up' first." >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# 1. Gateway API CRDs
# ---------------------------------------------------------------------------
install_gateway_api() {
  step "Gateway API CRDs (vendored, standard channel)"
  k apply --server-side --force-conflicts -f "${HERE}/gateway-api-crds.yaml"

  # Applying a CRD and using it in the same breath is a race. Wait for the API server to
  # actually serve them.
  local crd
  for crd in gatewayclasses gateways httproutes referencegrants; do
    k wait --for=condition=Established --timeout=90s \
      "crd/${crd}.gateway.networking.k8s.io"
  done
}

# ---------------------------------------------------------------------------
# 2. cert-manager
# ---------------------------------------------------------------------------
install_cert_manager() {
  step "cert-manager ${CERT_MANAGER_VERSION}"
  h repo add jetstack https://charts.jetstack.io --force-update >/dev/null
  h repo update jetstack >/dev/null

  h upgrade --install cert-manager jetstack/cert-manager \
    --version "${CERT_MANAGER_VERSION}" \
    --namespace cert-manager --create-namespace \
    --values "${HERE}/cert-manager.values.yaml" \
    --wait --timeout 5m

  k -n cert-manager rollout status deploy/cert-manager --timeout=180s
  k -n cert-manager rollout status deploy/cert-manager-webhook --timeout=180s
  k -n cert-manager rollout status deploy/cert-manager-cainjector --timeout=180s
}

# ---------------------------------------------------------------------------
# 3. Local CA + ClusterIssuer
# ---------------------------------------------------------------------------
install_local_ca() {
  step "Local root CA and ClusterIssuer"

  # The webhook can accept connections before it is genuinely ready to admit; retry
  # rather than fail the whole bootstrap on a cold start.
  local attempt
  for attempt in 1 2 3 4 5 6; do
    if k apply -f "${HERE}/local-ca/ca-certificate.yaml" 2>/dev/null; then
      break
    fi
    if [[ "${attempt}" == 6 ]]; then
      echo "error: cert-manager webhook never became ready" >&2
      k apply -f "${HERE}/local-ca/ca-certificate.yaml"  # surface the real error
      exit 1
    fi
    echo "  cert-manager webhook not ready yet, retrying (${attempt}/6)..."
    sleep 5
  done

  k -n cert-manager wait --for=condition=Ready --timeout=120s certificate/k3d-lab-ca
  k apply -f "${HERE}/local-ca/cluster-issuer.yaml"
  k wait --for=condition=Ready --timeout=60s clusterissuer/k3d-lab-ca-issuer
}

# ---------------------------------------------------------------------------
# 4. Traefik
# ---------------------------------------------------------------------------
install_traefik() {
  step "Traefik (chart ${TRAEFIK_CHART_VERSION})"
  h repo add traefik https://traefik.github.io/charts --force-update >/dev/null
  h repo update traefik >/dev/null

  h upgrade --install traefik traefik/traefik \
    --version "${TRAEFIK_CHART_VERSION}" \
    --namespace traefik --create-namespace \
    --values "${HERE}/traefik.values.yaml" \
    --wait --timeout 5m

  k -n traefik rollout status deploy/traefik --timeout=180s
}

# ---------------------------------------------------------------------------
# 5. Shared Gateway
# ---------------------------------------------------------------------------
install_gateway() {
  step "Shared Gateway"
  # Applied in dependency order rather than by globbing the directory: the namespace
  # must exist before the Certificate, and the cert secret before the Gateway listener
  # can resolve its refs.
  k apply -f "${HERE}/gateway/namespace.yaml"
  k apply -f "${HERE}/gateway/gatewayclass.yaml"
  k apply -f "${HERE}/gateway/certificate.yaml"
  k -n gateway wait --for=condition=Ready --timeout=120s certificate/gateway-tls

  k apply -f "${HERE}/gateway/gateway.yaml"
  k -n gateway wait --for=condition=Programmed --timeout=120s gateway/shared-gateway
}

# ---------------------------------------------------------------------------
# 6. Gitea — the Git server Argo CD reconciles from
# ---------------------------------------------------------------------------
install_gitea() {
  step "Gitea (chart ${GITEA_CHART_VERSION})"
  k apply -f "${HERE}/gitops/namespaces.yaml"

  h repo add gitea-charts https://dl.gitea.com/charts/ --force-update >/dev/null
  h repo update gitea-charts >/dev/null

  h upgrade --install gitea gitea-charts/gitea \
    --version "${GITEA_CHART_VERSION}" \
    --namespace gitea \
    --values "${HERE}/gitea.values.yaml" \
    --wait --timeout 5m

  # A Deployment despite the PVC — the chart dropped the StatefulSet years ago. Note
  # gitea-http is a *headless* Service (clusterIP: None); it resolves to pod IPs, which
  # is fine for both Argo CD's clone and the HTTPRoute, but it means `kubectl get svc`
  # shows no ClusterIP and that is not a fault.
  k -n gitea rollout status deployment/gitea --timeout=300s
}

# ---------------------------------------------------------------------------
# 7. Argo CD
# ---------------------------------------------------------------------------
install_argocd() {
  step "Argo CD (chart ${ARGOCD_CHART_VERSION})"
  h repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
  h repo update argo >/dev/null

  h upgrade --install argocd argo/argo-cd \
    --version "${ARGOCD_CHART_VERSION}" \
    --namespace argocd \
    --values "${HERE}/argocd.values.yaml" \
    --wait --timeout 10m

  k -n argocd rollout status deploy/argocd-server --timeout=300s
  k -n argocd rollout status deploy/argocd-repo-server --timeout=300s
  k -n argocd rollout status statefulset/argocd-application-controller --timeout=300s

  # Applying an Application before its CRD is served is the same race as the Gateway API
  # CRDs above, just later in the script.
  k wait --for=condition=Established --timeout=90s \
    crd/applications.argoproj.io crd/appprojects.argoproj.io
}

# ---------------------------------------------------------------------------
# 8. The GitOps seed — routes, the project, and exactly one Application
# ---------------------------------------------------------------------------
install_gitops() {
  step "GitOps seed (AppProject + root Application)"
  k apply -f "${HERE}/gitops/httproutes.yaml"
  k apply -f "${HERE}/gitops/project.yaml"
  k apply -f "${HERE}/gitops/root-app.yaml"

  # Deliberately no wait. The root Application points at a repository that does not
  # exist until `make gitops` pushes it, so a fresh bootstrap legitimately leaves it
  # Unknown. Blocking here would make the first bootstrap fail by design.
  printf '    root Application applied. It has nothing to sync until:\n'
  printf '      make gitops    (publish the chart + this repo, then wait for convergence)\n'
}

main() {
  require_cluster
  install_gateway_api
  install_cert_manager
  install_local_ca
  install_traefik
  install_gateway
  install_gitea
  install_argocd
  install_gitops
  step "Bootstrap complete."
}

main "$@"
