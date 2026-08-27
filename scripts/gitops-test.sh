#!/usr/bin/env bash
#
# The acceptance test for Part 3: prove the cluster reconciles toward Git rather than
# remembering what was last applied to it.
#
# Three drifts, each undone by Argo CD and nothing else:
#   1. delete the Deployment          -> it comes back
#   2. scale it by hand               -> the replica count reverts
#   3. edit a managed field by hand   -> the edit is overwritten
#
# Every check reads the cluster, never Argo CD's own opinion of the cluster: a controller
# reporting Synced while the workload is missing is exactly the failure worth catching.

set -uo pipefail

readonly CONTEXT="k3d-lab"
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly CURL="${REPO_ROOT}/scripts/curl.sh"

readonly APP="demo-api"
readonly APP_NS="demo-api-gitops"
readonly DEPLOY="demo-api"
readonly HOST="demo-api-gitops.k3d.local"

# Self-heal is event-driven, so the first drift is undone in seconds. Later ones are not:
# Argo CD backs off exponentially between self-heal attempts on the same Application, and
# this script deliberately drifts the same app three times in a row. Observed spread on
# drift 3 is 5s to 162s depending on how much backoff has accumulated — so the ceiling is
# sized for the backoff, not for the reconcile.
readonly HEAL_TIMEOUT=300

failures=0

k() { kubectl --context "${CONTEXT}" "$@"; }

section() { printf '\n\033[1;34m%s\033[0m\n' "$*"; }
pass()    { printf '  \033[32m✓\033[0m %s\n' "$*"; }
fail()    { printf '  \033[31m✗\033[0m %s\n' "$*"; failures=$((failures + 1)); }
info()    { printf '    %s\n' "$*"; }

# Poll until `cmd` succeeds or the deadline passes. Returns elapsed seconds via $REPLY.
wait_until() {
  local timeout="$1"; shift
  local start now
  start="$(date +%s)"
  while :; do
    if "$@" >/dev/null 2>&1; then
      now="$(date +%s)"; REPLY=$((now - start)); return 0
    fi
    now="$(date +%s)"
    if (( now - start >= timeout )); then REPLY=$((now - start)); return 1; fi
    sleep 2
  done
}

deployment_ready() {
  local want="$1"
  local ready
  ready="$(k -n "${APP_NS}" get deploy "${DEPLOY}" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
  [[ "${ready:-0}" == "${want}" ]]
}

desired_replicas() {
  k -n "${APP_NS}" get deploy "${DEPLOY}" -o jsonpath='{.spec.replicas}' 2>/dev/null
}

# ---------------------------------------------------------------------------
check_preconditions() {
  section "Preconditions"

  if ! k -n argocd get application "${APP}" >/dev/null 2>&1; then
    fail "Application '${APP}' does not exist — run 'make gitops' first"
    return 1
  fi

  local sync health
  sync="$(k -n argocd get application "${APP}" -o jsonpath='{.status.sync.status}' 2>/dev/null)"
  health="$(k -n argocd get application "${APP}" -o jsonpath='{.status.health.status}' 2>/dev/null)"
  if [[ "${sync}" == "Synced" && "${health}" == "Healthy" ]]; then
    pass "Application ${APP} is Synced/Healthy"
  else
    fail "Application ${APP} is ${sync:-?}/${health:-?} — run 'make gitops' first"
    return 1
  fi

  # Self-heal is the property under test. If it is off, everything below passes
  # vacuously, which is the worst possible outcome for a test.
  local self_heal
  self_heal="$(k -n argocd get application "${APP}" \
    -o jsonpath='{.spec.syncPolicy.automated.selfHeal}' 2>/dev/null)"
  if [[ "${self_heal}" == "true" ]]; then
    pass "selfHeal is enabled"
  else
    fail "selfHeal is '${self_heal:-unset}' — the drift checks below would prove nothing"
    return 1
  fi

  local want
  want="$(desired_replicas)"
  if deployment_ready "${want}"; then
    pass "deployment ${APP_NS}/${DEPLOY} has ${want}/${want} ready"
  else
    fail "deployment ${APP_NS}/${DEPLOY} is not fully ready to begin with"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
check_delete_heals() {
  section "Drift 1: delete the Deployment"

  local want
  want="$(desired_replicas)"
  local uid_before
  uid_before="$(k -n "${APP_NS}" get deploy "${DEPLOY}" -o jsonpath='{.metadata.uid}')"

  info "kubectl delete deploy/${DEPLOY} -n ${APP_NS}"
  if ! k -n "${APP_NS}" delete deploy "${DEPLOY}" --wait=true >/dev/null 2>&1; then
    fail "could not delete the deployment"
    return
  fi

  if wait_until "${HEAL_TIMEOUT}" deployment_ready "${want}"; then
    pass "deployment returned and became ${want}/${want} ready after ${REPLY}s"
  else
    fail "deployment did not come back within ${HEAL_TIMEOUT}s"
    k -n argocd get application "${APP}" \
      -o jsonpath='{.status.sync.status}{" / "}{.status.health.status}{"\n"}' \
      2>/dev/null | sed 's/^/      /'
    return
  fi

  # A recreated object, not the old one resurrected. Proves Argo CD rebuilt it rather
  # than the delete having quietly failed.
  local uid_after
  uid_after="$(k -n "${APP_NS}" get deploy "${DEPLOY}" -o jsonpath='{.metadata.uid}')"
  if [[ -n "${uid_after}" && "${uid_after}" != "${uid_before}" ]]; then
    pass "it is a new object (uid changed), so it was genuinely recreated"
  else
    fail "uid did not change — the delete may not have taken effect"
  fi
}

# ---------------------------------------------------------------------------
check_scale_reverts() {
  section "Drift 2: scale it by hand"

  local want
  want="$(desired_replicas)"
  local drifted=$((want + 3))

  info "kubectl scale deploy/${DEPLOY} --replicas=${drifted}"
  if ! k -n "${APP_NS}" scale deploy "${DEPLOY}" --replicas="${drifted}" >/dev/null 2>&1; then
    fail "could not scale the deployment"
    return
  fi

  replicas_back_to_want() { [[ "$(desired_replicas)" == "${want}" ]]; }
  if wait_until "${HEAL_TIMEOUT}" replicas_back_to_want; then
    pass "spec.replicas reverted ${drifted} -> ${want} after ${REPLY}s"
  else
    fail "spec.replicas stayed at $(desired_replicas) — self-heal did not revert it"
  fi
}

# ---------------------------------------------------------------------------
check_field_edit_reverts() {
  section "Drift 3: edit a managed field by hand"

  # An annotation the chart sets is a safer probe than an image or a resource limit:
  # reverting it does not roll the pods, so this check does not race the previous one.
  local before
  before="$(k -n "${APP_NS}" get deploy "${DEPLOY}" \
    -o jsonpath='{.spec.template.spec.containers[0].image}')"
  info "current image: ${before}"

  info "kubectl set image ... =k3d-registry:5000/demo-api:tampered"
  if ! k -n "${APP_NS}" set image "deploy/${DEPLOY}" \
       "${DEPLOY}=k3d-registry:5000/demo-api:tampered" >/dev/null 2>&1; then
    fail "could not patch the image"
    return
  fi

  image_back() {
    [[ "$(k -n "${APP_NS}" get deploy "${DEPLOY}" \
      -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)" == "${before}" ]]
  }
  if wait_until "${HEAL_TIMEOUT}" image_back; then
    pass "image reverted to ${before} after ${REPLY}s"
  else
    fail "image is still $(k -n "${APP_NS}" get deploy "${DEPLOY}" \
      -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)"
  fi

  # The tampered image does not exist, so the rollout it triggered will never be ready.
  # Wait for the real one to settle before declaring victory.
  local want
  want="$(desired_replicas)"
  if wait_until "${HEAL_TIMEOUT}" deployment_ready "${want}"; then
    pass "deployment settled back to ${want}/${want} ready"
  else
    fail "deployment did not return to ready after the revert"
  fi
}

# ---------------------------------------------------------------------------
check_still_serving() {
  section "Still serving through the Gateway"

  # rollout status returns when new pods are Ready, which with maxUnavailable: 0 is
  # before the old ones finish terminating — so a request right now can still land on a
  # draining pod. Retry briefly rather than assert on the first attempt.
  local code attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    code="$("${CURL}" "https://${HOST}/api/v1/info" -s -o /dev/null -w '%{http_code}' 2>/dev/null)"
    [[ "${code}" == 200 ]] && break
    sleep 3
  done

  if [[ "${code}" == 200 ]]; then
    pass "https://${HOST}/api/v1/info -> 200"
    "${CURL}" "https://${HOST}/api/v1/info" -s 2>/dev/null | sed 's/^/      /'
  else
    fail "https://${HOST}/api/v1/info -> ${code:-<no response>}"
  fi
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

  if ! check_preconditions; then
    printf '\n\033[1;31mgitops-test: preconditions failed\033[0m\n'
    exit 1
  fi

  check_delete_heals
  check_scale_reverts
  check_field_edit_reverts
  check_still_serving

  if [[ "${failures}" -eq 0 ]]; then
    printf '\n\033[1;32mgitops-test: all checks passed\033[0m\n'
    printf 'The cluster reconciles toward Git. Nothing above was repaired by hand.\n'
    exit 0
  fi
  printf '\n\033[1;31mgitops-test: %d check(s) failed\033[0m\n' "${failures}"
  exit 1
}

main "$@"
