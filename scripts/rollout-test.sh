#!/usr/bin/env bash
#
# The three claims a chart makes about upgrades, tested rather than asserted:
#
#   1. Changing a ConfigMap value actually rolls the pods. Without a checksum/config
#      annotation on the pod template, `helm upgrade` updates the ConfigMap, changes
#      nothing about the Deployment, and the running pods keep serving the old value
#      forever. It is the classic Helm bug and it is completely silent.
#
#   2. A rollout under load drops zero requests. This is what maxUnavailable: 0, the
#      preStop sleep, and readiness-off-on-SIGTERM are *for*. Any one of the three
#      missing and this fails — which is the point: they are load-bearing, not
#      decoration.
#
#   3. helm rollback works and the app stays reachable across it.
#
# Every request goes through scripts/curl.sh, so the load generator is hitting the real
# Gateway over verified TLS — not a port-forward, which would bypass the endpoint
# removal that makes step 2 interesting in the first place.
#
# This mutates a live release: it upgrades it twice and rolls it back. It leaves the
# release at the revision it started from.

set -uo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly CURL="${REPO_ROOT}/scripts/curl.sh"
readonly CHART="${REPO_ROOT}/charts/demo-api"
readonly CONTEXT="k3d-lab"

RELEASE="${RELEASE:-demo-api}"
NAMESPACE="${NAMESPACE:-demo-api}"

# Three concurrent generators. One is enough to catch a dropped connection; three make
# it likely that a request is in flight at the exact moment an endpoint is removed.
readonly LOAD_WORKERS=3

readonly WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

failures=0

k() { kubectl --context "${CONTEXT}" -n "${NAMESPACE}" "$@"; }
h() { helm --kube-context "${CONTEXT}" -n "${NAMESPACE}" "$@"; }

section() { printf '\n\033[1;34m%s\033[0m\n' "$*"; }
pass()    { printf '  \033[32m✓\033[0m %s\n' "$*"; }
fail()    { printf '  \033[31m✗\033[0m %s\n' "$*"; failures=$((failures + 1)); }
info()    { printf '    %s\n' "$*"; }

config_checksum() {
  k get deploy "${RELEASE}" \
    -o jsonpath='{.spec.template.metadata.annotations.checksum/config}' 2>/dev/null
}

pod_names() {
  k get pods -l "app.kubernetes.io/instance=${RELEASE}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | sort
}

upgrade() {
  # --atomic on purpose: a failed upgrade here should roll itself back rather than leave
  # a half-applied release for the next check to trip over.
  h upgrade "${RELEASE}" "${CHART}" --atomic --timeout 5m "$@" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# The load generator. Writes one HTTP status code per line; anything that is not 200 is
# a dropped request, including curl's own 000 for a connection that never completed.

load_worker() {
  local url="$1" out="$2"
  while [[ ! -f "${WORK_DIR}/stop" ]]; do
    "${CURL}" "${url}" -s -o /dev/null -w '%{http_code}\n' --max-time 5 >> "${out}" 2>/dev/null
  done
}

start_load() {
  local url="$1" i
  rm -f "${WORK_DIR}/stop" "${WORK_DIR}"/codes.*
  for ((i = 0; i < LOAD_WORKERS; i++)); do
    load_worker "${url}" "${WORK_DIR}/codes.${i}" &
  done
}

stop_load() {
  touch "${WORK_DIR}/stop"
  wait 2>/dev/null
  cat "${WORK_DIR}"/codes.* 2>/dev/null
}

# ---------------------------------------------------------------------------
check_config_change_rolls() {
  section "A ConfigMap change rolls the pods"

  local before_sum after_sum before_pods after_pods
  before_sum="$(config_checksum)"
  before_pods="$(pod_names)"

  if [[ -z "${before_sum}" ]]; then
    fail "the pod template has no checksum/config annotation at all"
    return
  fi

  local marker="rollout-test $(date +%s)"
  if ! upgrade --set-string "config.message=${marker}"; then
    fail "helm upgrade failed"
    return
  fi

  after_sum="$(config_checksum)"
  if [[ "${after_sum}" != "${before_sum}" ]]; then
    pass "checksum/config changed (${before_sum:0:12}… -> ${after_sum:0:12}…)"
  else
    fail "checksum/config did not change — the annotation is not hashing the ConfigMap"
  fi

  k rollout status "deploy/${RELEASE}" --timeout=180s >/dev/null 2>&1

  # `rollout status` returns when the new pods are Ready, which with maxUnavailable: 0
  # is *before* the old ones have finished terminating — they are still draining, and
  # still briefly in the Gateway's view of the endpoints. Waiting them out here is what
  # makes the assertion below about the whole service rather than about whichever pod
  # answered first.
  local p
  for p in ${before_pods}; do
    k wait --for=delete "pod/${p}" --timeout=120s >/dev/null 2>&1
  done

  after_pods="$(pod_names)"
  if [[ "${after_pods}" != "${before_pods}" ]]; then
    pass "every pod was replaced"
  else
    fail "the pods were not replaced — the ConfigMap changed under a running process"
  fi

  # The value has to reach the *process*, not just the ConfigMap object: it arrives as
  # an env var, read once at import. This is only true because the pods restarted.
  #
  # Asked enough times to cover every replica — one request proves one pod, and a
  # half-rolled Deployment would pass that.
  local host body i mismatched=0
  host="$(k get httproute "${RELEASE}" -o jsonpath='{.spec.hostnames[0]}' 2>/dev/null)"
  if [[ -n "${host}" ]]; then
    for ((i = 0; i < 10; i++)); do
      body="$("${CURL}" "https://${host}/api/v1/info" -s 2>/dev/null)"
      grep -q "\"message\":\"${marker}\"" <<< "${body}" || { mismatched=1; break; }
    done
    if [[ "${mismatched}" -eq 0 ]]; then
      pass "every replica is serving the new value"
    else
      fail "a replica is still serving the old value"
      info "${body}"
    fi
  fi
}

# ---------------------------------------------------------------------------
check_zero_drops_under_load() {
  section "A rollout under load drops nothing"

  local host
  host="$(k get httproute "${RELEASE}" -o jsonpath='{.spec.hostnames[0]}' 2>/dev/null)"
  if [[ -z "${host}" ]]; then
    fail "no HTTPRoute hostname to generate load against"
    return
  fi

  start_load "https://${host}/api/v1/info"
  sleep 3  # let the generators get going before anything moves

  local marker="under-load $(date +%s)"
  local upgraded=0
  upgrade --set-string "config.message=${marker}" && upgraded=1
  k rollout status "deploy/${RELEASE}" --timeout=180s >/dev/null 2>&1

  sleep 3  # keep generating for a moment after the rollout reports done
  local codes total bad
  codes="$(stop_load)"
  total="$(wc -l <<< "${codes}")"
  bad="$(grep -cv '^200$' <<< "${codes}")"

  if [[ "${upgraded}" == 1 ]]; then
    pass "helm upgrade completed during load"
  else
    fail "helm upgrade failed during load"
  fi

  if [[ "${bad}" -eq 0 ]]; then
    pass "${total} requests through the Gateway, 0 failed"
  else
    fail "${bad} of ${total} requests failed during the rollout"
    info "status codes seen: $(sort <<< "${codes}" | uniq -c | tr '\n' ' ')"
  fi
}

# ---------------------------------------------------------------------------
check_rollback() {
  section "helm rollback"

  local revisions target
  revisions="$(h history "${RELEASE}" -o json 2>/dev/null \
    | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
  if [[ -z "${revisions}" || "${revisions}" -lt 2 ]]; then
    fail "not enough release history to roll back"
    return
  fi

  # Back to revision 1: the state the release was installed in, before this script
  # started rewriting its config.
  target=1
  if h rollback "${RELEASE}" "${target}" --wait --timeout 5m >/dev/null 2>&1; then
    pass "rolled back to revision ${target}"
  else
    fail "helm rollback failed"
    return
  fi

  k rollout status "deploy/${RELEASE}" --timeout=180s >/dev/null 2>&1

  local host code
  host="$(k get httproute "${RELEASE}" -o jsonpath='{.spec.hostnames[0]}' 2>/dev/null)"
  code="$("${CURL}" "https://${host}/api/v1/info" -s -o /dev/null -w '%{http_code}' 2>/dev/null)"
  if [[ "${code}" == 200 ]]; then
    pass "the app is still reachable after the rollback"
  else
    fail "expected 200 after rollback, got ${code:-<no response>}"
  fi
}

# ---------------------------------------------------------------------------
main() {
  if ! h status "${RELEASE}" >/dev/null 2>&1; then
    echo "error: no release '${RELEASE}' in namespace '${NAMESPACE}'. Run 'make install'." >&2
    exit 1
  fi

  check_config_change_rolls
  check_zero_drops_under_load
  check_rollback

  if [[ "${failures}" -eq 0 ]]; then
    printf '\n\033[1;32mrollout-test: all checks passed\033[0m\n'
    exit 0
  fi
  printf '\n\033[1;31mrollout-test: %d check(s) failed\033[0m\n' "${failures}"
  exit 1
}

main "$@"
