#!/usr/bin/env bash
#
# Prove the HPA actually autoscales: drive /api/v1/burn hard enough to move CPU past the
# target, watch the replica count go up, stop, watch it come back down.
#
# Two details decide whether this works at all:
#
#   * The HPA target is a percentage of the CPU *request*, not of the node. With
#     requests: 50m and a 60% target, the threshold is 30m of CPU per pod — which is
#     why /api/v1/burn moves the number at all on a laptop.
#   * metrics-server has a resolution window (~15s) and the HPA controller a sync period
#     (~15s), and scale-down adds a stabilization window on top. Nothing here happens
#     inside five seconds; the timeouts below are generous on purpose, and a slow pass
#     is still a pass.
#
# The release is upgraded to turn autoscaling on and rolled back to whatever it was when
# the script finishes — including on ^C, which is what the trap is for. A release left
# with an HPA attached would silently fight the next `make install` over spec.replicas.

set -uo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly CURL="${REPO_ROOT}/scripts/curl.sh"
readonly CHART="${REPO_ROOT}/charts/demo-api"
readonly CONTEXT="k3d-lab"

RELEASE="${RELEASE:-demo-api}"
NAMESPACE="${NAMESPACE:-demo-api}"

readonly MIN_REPLICAS=2
readonly MAX_REPLICAS=6
# 8 concurrent burners against 2 pods requesting 50m each. Comfortably past a 60%
# target, without being so much that the burn endpoint's own yields stop keeping
# /healthz answerable.
readonly BURN_WORKERS=8
readonly BURN_MS=500

readonly SCALE_UP_TIMEOUT=300
readonly SCALE_DOWN_TIMEOUT=420

readonly WORK_DIR="$(mktemp -d)"

failures=0
restore_needed=0

k() { kubectl --context "${CONTEXT}" -n "${NAMESPACE}" "$@"; }
h() { helm --kube-context "${CONTEXT}" -n "${NAMESPACE}" "$@"; }

section() { printf '\n\033[1;34m%s\033[0m\n' "$*"; }
pass()    { printf '  \033[32m✓\033[0m %s\n' "$*"; }
fail()    { printf '  \033[31m✗\033[0m %s\n' "$*"; failures=$((failures + 1)); }
info()    { printf '    %s\n' "$*"; }

cleanup() {
  touch "${WORK_DIR}/stop" 2>/dev/null
  wait 2>/dev/null
  if [[ "${restore_needed}" == 1 ]]; then
    printf '\n  restoring the release (autoscaling off)\n'
    h upgrade "${RELEASE}" "${CHART}" --atomic --timeout 5m \
      --set autoscaling.enabled=false >/dev/null 2>&1 \
      || echo "  warning: could not restore the release; run 'make install'" >&2
  fi
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT INT TERM

replicas() { k get deploy "${RELEASE}" -o jsonpath='{.status.replicas}' 2>/dev/null; }

hpa_current() {
  # Empty until metrics-server has reported for the target. `<unknown>` in kubectl's
  # TARGETS column is this being empty, and an HPA in that state is not managing
  # anything — starting the load before it clears would measure nothing.
  k get hpa "${RELEASE}" \
    -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null
}

burn_worker() {
  local url="$1"
  while [[ ! -f "${WORK_DIR}/stop" ]]; do
    "${CURL}" "${url}" -s -o /dev/null --max-time 30 >/dev/null 2>&1
  done
}

# ---------------------------------------------------------------------------
enable_autoscaling() {
  section "Turning autoscaling on"

  restore_needed=1
  if h upgrade "${RELEASE}" "${CHART}" --atomic --timeout 5m \
      --set autoscaling.enabled=true \
      --set autoscaling.minReplicas="${MIN_REPLICAS}" \
      --set autoscaling.maxReplicas="${MAX_REPLICAS}" \
      --set autoscaling.targetCPUUtilizationPercentage=60 \
      --set autoscaling.behavior.scaleDown.stabilizationWindowSeconds=30 \
      >/dev/null 2>&1; then
    pass "HPA ${MIN_REPLICAS}-${MAX_REPLICAS} replicas, target 60% of the CPU request"
  else
    fail "helm upgrade failed"
    return 1
  fi

  # Wait for a real reading before declaring the HPA operational.
  local waited=0 current
  while (( waited < 120 )); do
    current="$(hpa_current)"
    [[ -n "${current}" ]] && break
    sleep 5; waited=$((waited + 5))
  done

  if [[ -n "${current}" ]]; then
    pass "HPA is reading metrics (currently ${current}% of request)"
  else
    fail "HPA still reports <unknown> after ${waited}s — is metrics-server running?"
    return 1
  fi
}

# ---------------------------------------------------------------------------
check_scale_up() {
  section "Scale up under load"

  local host
  host="$(k get httproute "${RELEASE}" -o jsonpath='{.spec.hostnames[0]}' 2>/dev/null)"
  if [[ -z "${host}" ]]; then
    fail "no HTTPRoute hostname to drive load through"
    return 1
  fi

  rm -f "${WORK_DIR}/stop"
  local i
  for ((i = 0; i < BURN_WORKERS; i++)); do
    burn_worker "https://${host}/api/v1/burn?ms=${BURN_MS}" &
  done
  info "${BURN_WORKERS} workers burning ${BURN_MS}ms per request through the Gateway"

  local waited=0 now
  while (( waited < SCALE_UP_TIMEOUT )); do
    now="$(replicas)"
    if [[ -n "${now}" && "${now}" -gt "${MIN_REPLICAS}" ]]; then
      pass "scaled up to ${now} replicas after ${waited}s (cpu $(hpa_current)%)"
      return 0
    fi
    (( waited % 30 == 0 )) && info "${waited}s: ${now:-?} replicas, cpu $(hpa_current)%"
    sleep 10; waited=$((waited + 10))
  done

  fail "still at ${MIN_REPLICAS} replicas after ${SCALE_UP_TIMEOUT}s"
  k describe hpa "${RELEASE}" 2>&1 | tail -20 | sed 's/^/      /'
  return 1
}

# ---------------------------------------------------------------------------
check_scale_down() {
  section "Scale back down when the load stops"

  touch "${WORK_DIR}/stop"
  wait 2>/dev/null
  info "load stopped"

  local waited=0 now
  while (( waited < SCALE_DOWN_TIMEOUT )); do
    now="$(replicas)"
    if [[ -n "${now}" && "${now}" -le "${MIN_REPLICAS}" ]]; then
      pass "back to ${now} replicas after ${waited}s"
      return 0
    fi
    (( waited % 60 == 0 )) && info "${waited}s: ${now:-?} replicas, cpu $(hpa_current)%"
    sleep 15; waited=$((waited + 15))
  done

  fail "still at $(replicas) replicas after ${SCALE_DOWN_TIMEOUT}s"
  k describe hpa "${RELEASE}" 2>&1 | tail -20 | sed 's/^/      /'
  return 1
}

# ---------------------------------------------------------------------------
main() {
  if ! h status "${RELEASE}" >/dev/null 2>&1; then
    echo "error: no release '${RELEASE}' in namespace '${NAMESPACE}'. Run 'make install'." >&2
    exit 1
  fi

  enable_autoscaling && check_scale_up && check_scale_down

  if [[ "${failures}" -eq 0 ]]; then
    printf '\n\033[1;32mhpa-test: all checks passed\033[0m\n'
    exit 0
  fi
  printf '\n\033[1;31mhpa-test: %d check(s) failed\033[0m\n' "${failures}"
  exit 1
}

main "$@"
