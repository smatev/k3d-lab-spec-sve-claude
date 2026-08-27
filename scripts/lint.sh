#!/usr/bin/env bash
#
# Static checks on the chart. Nothing here needs a cluster.
#
#   helm lint     chart structure and metadata
#   ct lint       the same, plus chart-testing's own conventions
#   kubeconform   is the rendered YAML actually valid for this Kubernetes version,
#                 including the CRDs
#   kube-score    the things that are valid but unwise — missing probes, absent
#                 limits, a soft securityContext
#
# Every ci/ value set is rendered and checked, not just the defaults. A toggle that
# renders invalid YAML in one combination is exactly the bug this catches, and it is
# invisible if only the default path is validated.

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly CHART="${REPO_ROOT}/charts/demo-api"
readonly SCHEMA_DIR="${REPO_ROOT}/.local/schemas"
readonly CACHE_DIR="${REPO_ROOT}/.local/kubeconform-cache"

# Match the cluster in cluster/k3d.yaml. Validating against a different version is
# how a manifest passes CI and is rejected on apply.
readonly KUBE_VERSION="1.36.3"

# API versions to pretend are present while rendering.
#
# `.Capabilities.APIVersions.Has` consults the live cluster, so under `helm template`
# it is false for every CRD. A chart that gates its HTTPRoute and its ServiceMonitor
# on Capabilities therefore renders neither in CI, and the manifests validated here
# would be missing exactly the resources most likely to be wrong — while the summary
# still says "ok". This chart gates on values instead, so nothing can vanish; the flag
# is passed anyway so the render stays honest if a Capabilities check is ever added.
readonly API_VERSIONS=(
  --api-versions "gateway.networking.k8s.io/v1"
  --api-versions "monitoring.coreos.com/v1"
)

# kube-score checks that are wrong for this chart, each with its reason. Silencing a
# check without one is how a linter stops meaning anything.
readonly KUBE_SCORE_IGNORE=(
  # We pin an immutable tag from a local registry. Always would add a registry
  # round-trip per pod start to re-fetch a digest that cannot have changed.
  --ignore-test container-image-pull-policy
  # Superseded by topologySpreadConstraints, which express the same intent as a
  # preference rather than a hard rule. kube-score does not know about them.
  --ignore-test deployment-has-host-podantiaffinity
)

failures=0

section() { printf '\n\033[1;34m%s\033[0m\n' "$*"; }
pass()    { printf '  \033[32m✓\033[0m %s\n' "$*"; }
fail()    { printf '  \033[31m✗\033[0m %s\n' "$*"; failures=$((failures + 1)); }

value_sets() {
  # The defaults first, then every ci/ file.
  echo ""
  find "${CHART}/ci" -name '*-values.yaml' | sort
}

set_name() {
  [[ -z "$1" ]] && { echo "defaults"; return; }
  basename "$1" -values.yaml
}

# ---------------------------------------------------------------------------
check_helm_lint() {
  section "helm lint"
  local vf name
  while read -r vf; do
    name="$(set_name "${vf}")"
    local args=(lint "${CHART}" --strict)
    [[ -n "${vf}" ]] && args+=(--values "${vf}")
    if helm "${args[@]}" >/dev/null 2>&1; then
      pass "${name}"
    else
      fail "${name}"
      helm "${args[@]}" 2>&1 | sed 's/^/      /'
    fi
  done < <(value_sets)
}

# ---------------------------------------------------------------------------
check_ct_lint() {
  section "ct lint"
  # ct resolves chart-dirs and the two vendored config paths in ct.yaml relative to the
  # working directory, so run it from the repo root regardless of where lint.sh was
  # invoked from.
  cd "${REPO_ROOT}"
  if ct lint --config "${REPO_ROOT}/ct.yaml" >/dev/null 2>&1; then
    pass "chart structure and metadata"
  else
    fail "chart structure and metadata"
    ct lint --config "${REPO_ROOT}/ct.yaml" 2>&1 | tail -30 | sed 's/^/      /'
  fi
}

# ---------------------------------------------------------------------------
check_kubeconform() {
  section "kubeconform --strict (k8s ${KUBE_VERSION} + CRDs)"

  if [[ ! -d "${SCHEMA_DIR}" ]]; then
    fail "${SCHEMA_DIR} missing — run scripts/gen-schemas.sh"
    return
  fi
  mkdir -p "${CACHE_DIR}"

  local vf name out
  while read -r vf; do
    name="$(set_name "${vf}")"
    local render=(template demo-api "${CHART}" --namespace demo-api "${API_VERSIONS[@]}")
    [[ -n "${vf}" ]] && render+=(--values "${vf}")

    # -strict rejects unknown fields, which is the entire value of running this: a
    # typo'd key in a manifest is valid YAML and silently ignored by the API server.
    #
    # -verbose so `Skipped` is visible. A skipped resource is an unvalidated one, and
    # a summary that says "0 invalid" while skipping every CRD is worse than no check.
    if out="$(helm "${render[@]}" 2>&1 | kubeconform \
        -strict -summary -verbose \
        -kubernetes-version "${KUBE_VERSION}" \
        -cache "${CACHE_DIR}" \
        -schema-location default \
        -schema-location "${SCHEMA_DIR}/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" 2>&1)"; then
      if grep -q 'Skipped: [1-9]' <<< "${out}"; then
        fail "${name}: kubeconform skipped a resource (a missing CRD schema)"
        grep -i skipped <<< "${out}" | sed 's/^/      /'
      else
        pass "${name}: $(grep -o 'Valid: [0-9]*' <<< "${out}")"
      fi
    else
      fail "${name}"
      sed 's/^/      /' <<< "${out}"
    fi
  done < <(value_sets)
}

# ---------------------------------------------------------------------------
check_kube_score() {
  section "kube-score"
  local vf name out
  while read -r vf; do
    name="$(set_name "${vf}")"
    local render=(template demo-api "${CHART}" --namespace demo-api "${API_VERSIONS[@]}")
    [[ -n "${vf}" ]] && render+=(--values "${vf}")

    if out="$(helm "${render[@]}" 2>&1 | kube-score score - \
        "${KUBE_SCORE_IGNORE[@]}" 2>&1)"; then
      pass "${name}"
    else
      fail "${name}"
      sed 's/^/      /' <<< "${out}" | head -40
    fi
  done < <(value_sets)
}

# ---------------------------------------------------------------------------
check_hygiene() {
  section "Repo hygiene"

  # Each of these is a rule from CLAUDE.md, enforced rather than remembered. The
  # chart's own templates are searched, not the whole repo: scripts/curl.sh has to
  # mention -k in order to refuse it.
  # Each entry is pattern@@description@@scope. `@@` rather than a space because the
  # patterns themselves contain alternation; scope because one of these must not look
  # at values.yaml.
  local pattern desc scope bad entry rest
  local -a checks=(
    ':latest@@floating image tags@@chart'
    'nip\.io|sslip\.io|xip\.io@@external DNS services@@chart'
    'curl[^|]*[[:space:]]-k[[:space:]]@@curl with TLS verification disabled@@chart'
    '/etc/hosts@@/etc/hosts dependencies@@chart'
    # A namespace written into a *template* pins the chart to one install location and
    # breaks `ct install`, which installs into a randomly named namespace; the right
    # answer there is always .Release.Namespace. In values.yaml a namespace is fine and
    # sometimes required — route.httpRoute.parentRefs[].namespace names the namespace
    # the shared Gateway lives in, which is a fact about the cluster, not a default the
    # chart should be inventing. Hence templates only.
    '^[[:space:]]*namespace:[[:space:]]*[a-z]@@hardcoded namespaces in templates@@templates'
  )
  for entry in "${checks[@]}"; do
    pattern="${entry%%@@*}"
    rest="${entry#*@@}"
    desc="${rest%%@@*}"
    scope="${rest##*@@}"

    local -a targets=("${CHART}/templates")
    [[ "${scope}" == "chart" ]] && targets+=("${CHART}/values.yaml")

    bad="$(grep -rEn "${pattern}" "${targets[@]}" 2>/dev/null || true)"
    if [[ -z "${bad}" ]]; then
      pass "no ${desc}"
    else
      fail "found ${desc}"
      sed 's/^/      /' <<< "${bad}"
    fi
  done
}

# ---------------------------------------------------------------------------
main() {
  check_helm_lint
  check_ct_lint
  check_kubeconform
  check_kube_score
  check_hygiene

  if [[ "${failures}" -eq 0 ]]; then
    printf '\n\033[1;32mlint: all checks passed\033[0m\n'
    exit 0
  fi
  printf '\n\033[1;31mlint: %d check(s) failed\033[0m\n' "${failures}"
  exit 1
}

main "$@"
