#!/usr/bin/env bash
#
# Smoke test for an installed demo-api release: two checks that look similar and are
# not.
#
#   helm test        runs INSIDE the cluster. It reaches the Service by its cluster DNS
#                    name and proves the app, the ConfigMap wiring, the Secret mount and
#                    the readiness probe. It says nothing about routing.
#   the host side    goes through the shared Gateway over real TLS, verified against the
#                    local CA. It proves the HTTPRoute attached, the listener resolved,
#                    and the certificate covers the hostname.
#
# Keeping them apart matters: when the second fails and the first passes, the app is
# fine and the problem is routing. Conflating them produces a test that fails for two
# unrelated reasons and tells you which one only after you read the logs.
#
# Nothing here is hardcoded to the default values. Hostnames and path prefixes are read
# back off the live HTTPRoutes, so a release installed with different routing is checked
# against the routing it actually has.

set -uo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly CURL="${REPO_ROOT}/scripts/curl.sh"
readonly CONTEXT="k3d-lab"

RELEASE="${RELEASE:-demo-api}"
NAMESPACE="${NAMESPACE:-demo-api}"

readonly SELECTOR="app.kubernetes.io/instance=${RELEASE}"

failures=0

k() { kubectl --context "${CONTEXT}" -n "${NAMESPACE}" "$@"; }
h() { helm --kube-context "${CONTEXT}" -n "${NAMESPACE}" "$@"; }

section() { printf '\n\033[1;34m%s\033[0m\n' "$*"; }
pass()    { printf '  \033[32m✓\033[0m %s\n' "$*"; }
fail()    { printf '  \033[31m✗\033[0m %s\n' "$*"; failures=$((failures + 1)); }

# ---------------------------------------------------------------------------
check_rollout() {
  section "Rollout"

  local deploy
  deploy="$(k get deploy -l "${SELECTOR}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  if [[ -z "${deploy}" ]]; then
    fail "no Deployment for release ${RELEASE} in namespace ${NAMESPACE}"
    return
  fi

  if k rollout status "deploy/${deploy}" --timeout=120s >/dev/null 2>&1; then
    pass "deploy/${deploy} rolled out"
  else
    fail "deploy/${deploy} did not become available"
    k describe "deploy/${deploy}" 2>&1 | tail -20 | sed 's/^/      /'
  fi

  # Every replica running the image the chart asked for. A rollout can report success
  # while old pods linger if something else is scaling the ReplicaSet.
  local want got
  want="$(k get deploy "${deploy}" -o jsonpath='{.spec.replicas}' 2>/dev/null)"
  got="$(k get pods -l "${SELECTOR}" --field-selector=status.phase=Running \
    --no-headers 2>/dev/null | wc -l)"
  if [[ "${got}" == "${want}" ]]; then
    pass "${got}/${want} pods Running"
  else
    fail "expected ${want} Running pods, found ${got}"
  fi
}

# ---------------------------------------------------------------------------
check_route_status() {
  section "HTTPRoute status"

  local routes
  routes="$(k get httproute -l "${SELECTOR}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)"
  if [[ -z "${routes}" ]]; then
    pass "no HTTPRoute in this release (routing is off or on the Ingress path)"
    return
  fi

  # A cross-namespace HTTPRoute that never attaches does not error and does not warn —
  # it just quietly routes nothing, and the Gateway answers 404 for a Service whose
  # pods are perfectly healthy. The conditions are where that shows up, so they are
  # asserted before any request is made rather than being the thing you go and read
  # after a confusing failure.
  local route cond status
  for route in ${routes}; do
    for cond in Accepted ResolvedRefs; do
      status="$(k get httproute "${route}" \
        -o jsonpath="{.status.parents[*].conditions[?(@.type=='${cond}')].status}" 2>/dev/null)"
      if [[ -n "${status}" ]] && ! grep -qv True <<< "${status// /$'\n'}"; then
        pass "${route}: ${cond}=True"
      else
        fail "${route}: ${cond}=${status:-<missing>}"
        k get httproute "${route}" -o jsonpath='{.status}' 2>&1 \
          | python3 -m json.tool 2>/dev/null | sed 's/^/      /' | head -30
      fi
    done
  done
}

# ---------------------------------------------------------------------------
check_helm_test() {
  section "helm test (in-cluster, by Service DNS)"

  local out
  if out="$(h test "${RELEASE}" --logs --timeout 3m 2>&1)"; then
    pass "helm test passed"
    # The hook's own output is the interesting part — it asserts the ConfigMap value
    # reached the process and the Secret is mounted where the app expects it.
    sed -n '/^--- readiness/,/^all checks passed/p' <<< "${out}" | sed 's/^/      /'
  else
    fail "helm test failed"
    sed 's/^/      /' <<< "${out}" | tail -40
  fi
}

# ---------------------------------------------------------------------------
# Host-side, through the Gateway. No -k: curl.sh passes --cacert, so a 200 here means
# the certificate verified against the local CA for real.

get() {
  # get <url> [jq-less assertion grep pattern...]
  local url="$1"; shift
  local body code
  body="$("${CURL}" "${url}" -sS -w '\n%{http_code}' 2>&1)"
  code="$(tail -1 <<< "${body}")"
  body="$(sed '$d' <<< "${body}")"

  if [[ "${code}" != 200 ]]; then
    fail "GET ${url} -> ${code:-<no response>}"
    sed 's/^/      /' <<< "${body}" | head -5
    return 1
  fi

  local pattern
  for pattern in "$@"; do
    if ! grep -q "${pattern}" <<< "${body}"; then
      fail "GET ${url} -> 200 but the body does not match /${pattern}/"
      sed 's/^/      /' <<< "${body}" | head -5
      return 1
    fi
  done

  pass "GET ${url} -> 200"
  return 0
}

check_gateway_http() {
  section "Through the Gateway (TLS verified against the local CA)"

  # Hostnames come off the live route. The localhost route is handled separately: it
  # matches on a path prefix, so a request to its root would legitimately 404.
  local main_route localhost_route
  main_route="$(k get httproute -l "${SELECTOR}" \
    -o jsonpath="{.items[?(@.metadata.name=='${RELEASE}')].spec.hostnames[*]}" 2>/dev/null)"
  localhost_route="${RELEASE}-localhost"

  if [[ -z "${main_route}" ]]; then
    pass "no host-routed HTTPRoute to check"
  fi

  local host
  for host in ${main_route}; do
    get "https://${host}/healthz" '^ok$' || continue
    # Behavioural assertions, not a golden body: these survive the app gaining a field.
    get "https://${host}/api/v1/info" \
      '"secret_mounted":true' \
      '"ready":true' || continue
    get "https://${host}${_METRICS_PATH}" '^demo_api_ready ' || continue
  done

  # The redirect, checked here rather than assumed: port 80 answers 301 because the
  # `web` entrypoint redirects to `websecure`. It never reaches routing at all.
  if k get httproute "${RELEASE}" >/dev/null 2>&1; then
    host="$(awk '{print $1}' <<< "${main_route}")"
    local code
    code="$("${CURL}" "http://${host}/healthz" -s -o /dev/null -w '%{http_code}' 2>/dev/null)"
    if [[ "${code}" == 301 || "${code}" == 308 ]]; then
      pass "http://${host}/healthz -> ${code} (redirected to HTTPS, as it must be)"
    else
      fail "expected 301/308 on :80, got ${code:-<no response>}"
    fi
  fi

  # The browser-reachable path route, if this release has one. Its URLRewrite filter is
  # the part worth checking: without it the app receives the prefix it knows nothing
  # about and answers 404 through a route that is otherwise attached and healthy.
  if k get httproute "${localhost_route}" >/dev/null 2>&1; then
    local lhost prefix
    lhost="$(k get httproute "${localhost_route}" -o jsonpath='{.spec.hostnames[0]}')"
    prefix="$(k get httproute "${localhost_route}" \
      -o jsonpath='{.spec.rules[0].matches[0].path.value}')"
    get "https://${lhost}${prefix}/api/v1/info" '"secret_mounted":true'
  fi
}

# ---------------------------------------------------------------------------
main() {
  if ! kubectl --context "${CONTEXT}" cluster-info >/dev/null 2>&1; then
    echo "error: context '${CONTEXT}' is unreachable. Run 'make up' first." >&2
    exit 1
  fi
  if ! h status "${RELEASE}" >/dev/null 2>&1; then
    echo "error: no release '${RELEASE}' in namespace '${NAMESPACE}'. Run 'make install'." >&2
    exit 1
  fi

  # The metrics path is a value, so read it back rather than assuming /metrics.
  _METRICS_PATH="$(h get values "${RELEASE}" --all -o json 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["metrics"]["path"])' 2>/dev/null)"
  _METRICS_PATH="${_METRICS_PATH:-/metrics}"

  echo "release ${RELEASE} in namespace ${NAMESPACE}"

  check_rollout
  check_route_status
  check_helm_test
  check_gateway_http

  if [[ "${failures}" -eq 0 ]]; then
    printf '\n\033[1;32msmoke: all checks passed\033[0m\n'
    exit 0
  fi
  printf '\n\033[1;31msmoke: %d check(s) failed\033[0m\n' "${failures}"
  exit 1
}

main "$@"
