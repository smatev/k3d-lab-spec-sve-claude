#!/usr/bin/env bash
#
# The acceptance test. This is the point of the whole exercise: a single command that
# says in ~30 seconds whether the lab still works.
#
# Exits non-zero on any failure, and runs every check before reporting so one broken
# thing does not hide three others.

set -uo pipefail

readonly CONTEXT="k3d-lab"
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly CURL="${REPO_ROOT}/scripts/curl.sh"

# A hostname nothing routes to. Requests for it should reach Traefik and be rejected by
# Traefik — which is exactly what proves the path host -> k3d loadbalancer -> Traefik.
readonly DEAD_HOST="nothing.k3d.local"

readonly REGISTRY_HOST_REF="localhost:5000"
readonly REGISTRY_CLUSTER_REF="k3d-registry:5000"
readonly VERIFY_IMAGE="verify-registry:v1"

failures=0

k() { kubectl --context "${CONTEXT}" "$@"; }

section() { printf '\n\033[1;34m%s\033[0m\n' "$*"; }
pass()    { printf '  \033[32m✓\033[0m %s\n' "$*"; }
fail()    { printf '  \033[31m✗\033[0m %s\n' "$*"; failures=$((failures + 1)); }

# ---------------------------------------------------------------------------
check_nodes() {
  section "Nodes"
  local total ready
  total="$(k get nodes --no-headers 2>/dev/null | wc -l)"
  ready="$(k get nodes --no-headers 2>/dev/null | awk '$2 == "Ready"' | wc -l)"

  if [[ "${total}" == 3 && "${ready}" == 3 ]]; then
    pass "3/3 nodes Ready"
  else
    fail "expected 3 Ready nodes, got ${ready} Ready of ${total}"
    k get nodes 2>&1 | sed 's/^/      /'
  fi
}

# ---------------------------------------------------------------------------
check_pods() {
  section "Pods"
  local ns bad
  for ns in kube-system cert-manager traefik gateway gitea argocd; do
    # Anything not Running or Completed is a problem. Pods with restarts still count as
    # healthy here — a restart loop shows up as CrashLoopBackOff.
    bad="$(k -n "${ns}" get pods --no-headers 2>/dev/null \
      | awk '$3 != "Running" && $3 != "Completed" { print "        " $1 " (" $3 ")" }')"
    if [[ -z "${bad}" ]]; then
      pass "${ns}: all pods Running/Completed"
    else
      fail "${ns}: unhealthy pods"
      printf '%s\n' "${bad}"
    fi
  done
}

# ---------------------------------------------------------------------------
check_gateway() {
  section "Gateway"

  local programmed
  programmed="$(k -n gateway get gateway shared-gateway \
    -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)"
  if [[ "${programmed}" == "True" ]]; then
    pass "shared-gateway Programmed=True"
  else
    fail "shared-gateway Programmed=${programmed:-<missing>}"
  fi

  # Per-listener ResolvedRefs. This is where a bad certificateRef or a listener bound to
  # a port with no matching Traefik entrypoint shows up.
  local listeners name status any=0
  listeners="$(k -n gateway get gateway shared-gateway \
    -o jsonpath='{range .status.listeners[*]}{.name}{"="}{.conditions[?(@.type=="ResolvedRefs")].status}{"\n"}{end}' 2>/dev/null)"
  while IFS='=' read -r name status; do
    [[ -z "${name}" ]] && continue
    any=1
    if [[ "${status}" == "True" ]]; then
      pass "listener ${name} ResolvedRefs=True"
    else
      fail "listener ${name} ResolvedRefs=${status:-<missing>}"
    fi
  done <<< "${listeners}"
  [[ "${any}" == 1 ]] || fail "gateway reported no listener status at all"
}

# ---------------------------------------------------------------------------
check_no_dns() {
  section "No DNS dependency"

  # The lab must work on a plane. If this hostname ever starts resolving, something
  # added an /etc/hosts entry or a wildcard resolver and the lab has quietly grown a
  # dependency on state outside the repo.
  if getent hosts "${DEAD_HOST}" >/dev/null 2>&1; then
    fail "${DEAD_HOST} resolves — check /etc/hosts and your resolver"
  else
    pass "${DEAD_HOST} does not resolve (no /etc/hosts entry, no wildcard resolver)"
  fi

  # Belt and braces: a plain curl with no --resolve must fail outright. If this ever
  # succeeds, the requests below are not proving what they claim to prove.
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    "https://${DEAD_HOST}/" 2>/dev/null)"
  if [[ "${code}" == 000 ]]; then
    pass "plain curl without --resolve fails, as it must"
  else
    fail "plain curl reached the host (got ${code}) — DNS is resolving it somehow"
  fi
}

# ---------------------------------------------------------------------------
check_http_redirect() {
  section "HTTP :80 -> HTTPS redirect"
  local out code location
  out="$("${CURL}" "http://${DEAD_HOST}/" -s -o /dev/null -D - 2>/dev/null)"
  code="$(printf '%s' "${out}" | awk 'NR==1 {print $2}')"
  location="$(printf '%s' "${out}" | tr -d '\r' | awk 'tolower($1) == "location:" {print $2}')"

  # NB: the spec asks for a Traefik 404 here, but with web -> websecure redirection
  # enabled port 80 answers 301 (permanent: true) and never reaches routing. The
  # redirect is the honest assertion; the 404 check moved to HTTPS below.
  if [[ "${code}" == 301 || "${code}" == 308 ]]; then
    pass "http://${DEAD_HOST}/ -> ${code}"
  else
    fail "expected 308/301 on :80, got ${code:-<no response>}"
  fi

  if [[ "${location}" == https://* ]]; then
    pass "redirects to ${location}"
  else
    fail "expected an https:// Location header, got '${location:-<none>}'"
  fi
}

# ---------------------------------------------------------------------------
check_https_404() {
  section "HTTPS :443 through the Gateway"
  # No -k anywhere: curl.sh passes --cacert, so a successful request here means the
  # handshake verified against the local CA for real.
  local code
  code="$("${CURL}" "https://${DEAD_HOST}/" -s -o /dev/null -w '%{http_code}' 2>/dev/null)"

  if [[ "${code}" == 404 ]]; then
    pass "TLS verified against local CA; Traefik answered 404 (no route, as expected)"
  else
    fail "expected 404 over verified TLS, got ${code:-<handshake failed>}"
    "${CURL}" "https://${DEAD_HOST}/" -sS -o /dev/null 2>&1 | sed 's/^/      /'
  fi
}

# ---------------------------------------------------------------------------
check_registry() {
  section "Local registry round trip"

  # The registry has two names. Push to the host-facing one...
  if ! printf 'FROM busybox:1.37\nCMD ["true"]\n' \
       | docker build -q -t "${REGISTRY_HOST_REF}/${VERIFY_IMAGE}" - >/dev/null 2>&1; then
    fail "docker build failed"
    return
  fi
  if ! docker push -q "${REGISTRY_HOST_REF}/${VERIFY_IMAGE}" >/dev/null 2>&1; then
    fail "docker push to ${REGISTRY_HOST_REF} failed"
    return
  fi
  pass "pushed ${REGISTRY_HOST_REF}/${VERIFY_IMAGE}"

  # ...and pull from the in-cluster one. Getting these two mixed up is the single most
  # common k3d registry mistake, so the check exercises both deliberately.
  k delete pod verify-registry --ignore-not-found --wait=true >/dev/null 2>&1
  if ! k run verify-registry \
        --image="${REGISTRY_CLUSTER_REF}/${VERIFY_IMAGE}" \
        --image-pull-policy=Always \
        --restart=Never --command -- true >/dev/null 2>&1; then
    fail "could not create the test pod"
    return
  fi

  if k wait --for=jsonpath='{.status.phase}'=Succeeded --timeout=90s \
       pod/verify-registry >/dev/null 2>&1; then
    pass "pod pulled ${REGISTRY_CLUSTER_REF}/${VERIFY_IMAGE} and ran to completion"
  else
    fail "test pod did not complete"
    k describe pod verify-registry 2>&1 | tail -15 | sed 's/^/      /'
  fi
  k delete pod verify-registry --ignore-not-found --wait=false >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
check_gitops() {
  section "GitOps machinery"

  # Deliberately checks that the machinery is *installed and reachable*, not that
  # anything is Synced. A fresh `make up` leaves the root Application pointing at a
  # repository nobody has pushed yet, so asserting Synced here would fail by design.
  # Whether reconciliation actually works is scripts/gitops-test.sh's job.
  if k -n argocd get application root >/dev/null 2>&1; then
    pass "root Application exists"
  else
    fail "root Application missing — bootstrap did not seed Argo CD"
  fi

  if k -n argocd get appproject lab >/dev/null 2>&1; then
    pass "AppProject 'lab' exists"
  else
    fail "AppProject 'lab' missing"
  fi

  # Both UIs attach to the shared Gateway from their own namespaces, which is the same
  # cross-namespace attachment the app chart relies on — so this doubles as a second,
  # independent check that allowedRoutes is still open.
  local host code
  for host in argocd.k3d.local gitea.k3d.local; do
    code="$("${CURL}" "https://${host}/" -s -o /dev/null -w '%{http_code}' 2>/dev/null)"
    if [[ "${code}" == 200 ]]; then
      pass "https://${host}/ -> 200"
    else
      fail "https://${host}/ -> ${code:-<no response>}"
    fi
  done
}

# ---------------------------------------------------------------------------
main() {
  if ! k cluster-info >/dev/null 2>&1; then
    echo "error: context '${CONTEXT}' is unreachable. Run 'make up' first." >&2
    exit 1
  fi
  if [[ ! -f "${REPO_ROOT}/.local/ca.crt" ]]; then
    echo "error: .local/ca.crt missing. Run 'make ca' first." >&2
    exit 1
  fi

  check_nodes
  check_pods
  check_gateway
  check_no_dns
  check_http_redirect
  check_https_404
  check_registry
  check_gitops

  if [[ "${failures}" -eq 0 ]]; then
    printf '\n\033[1;32mverify: all checks passed\033[0m\n'
    exit 0
  fi
  printf '\n\033[1;31mverify: %d check(s) failed\033[0m\n' "${failures}"
  exit 1
}

main "$@"
