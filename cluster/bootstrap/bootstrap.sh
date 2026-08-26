#!/usr/bin/env bash
#
# Bootstrap the lab cluster: Gateway API CRDs, cert-manager + a local CA, Traefik, and
# the shared Gateway.
#
# Idempotent by construction — every step is `apply` or `upgrade --install` followed by
# an explicit wait, so running it twice changes nothing. `make bootstrap` proves it.
#
# Ordering matters in exactly one place: Traefik's Gateway API provider needs the CRDs
# to exist when it starts, so the CRDs go first.

set -euo pipefail

readonly CONTEXT="k3d-lab"
readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

readonly CERT_MANAGER_VERSION="v1.21.1"
readonly TRAEFIK_CHART_VERSION="41.3.0"

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

main() {
  require_cluster
  install_gateway_api
  install_cert_manager
  install_local_ca
  install_traefik
  install_gateway
  step "Bootstrap complete."
}

main "$@"
