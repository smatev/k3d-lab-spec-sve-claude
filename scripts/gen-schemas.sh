#!/usr/bin/env bash
#
# Turn vendored CRDs into JSON schemas kubeconform can validate against.
#
# kubeconform knows the built-in Kubernetes API out of the box and knows nothing about
# CRDs — so an HTTPRoute or a ServiceMonitor in a rendered manifest is skipped, not
# checked, unless a schema is supplied. Skipping exactly the resources most likely to
# be wrong is worse than not validating at all, because the output still says "ok".
#
# Inputs are vendored CRD YAML, never a URL:
#
#   cluster/bootstrap/gateway-api-crds.yaml   the same bundle the cluster installs, so
#                                             the schema and the cluster can never
#                                             disagree about what a valid HTTPRoute is
#   schemas/crds/*.yaml                        CRDs the lab validates against but does
#                                             not install (ServiceMonitor)
#
# Output goes to .local/schemas/, which is gitignored: it is derived, it is
# reproducible from the inputs above, and committing it would leave two copies of the
# same truth to drift apart.
#
# Conversion is kubectl (already pinned, already required) for YAML -> JSON, and
# python3's standard library for the reshaping. No new tool, no pip install.

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly OUT_DIR="${REPO_ROOT}/.local/schemas"

readonly INPUTS=(
  "${REPO_ROOT}/cluster/bootstrap/gateway-api-crds.yaml"
  "${REPO_ROOT}/schemas/crds"
)

main() {
  local input args=()
  for input in "${INPUTS[@]}"; do
    if [[ ! -e "${input}" ]]; then
      echo "error: missing schema input ${input}" >&2
      exit 1
    fi
    args+=(-f "${input}")
  done

  rm -rf "${OUT_DIR}"
  mkdir -p "${OUT_DIR}"

  # --dry-run=client keeps this entirely offline: kubectl parses and serialises the
  # manifests without ever contacting an API server.
  kubectl create "${args[@]}" --dry-run=client -o json \
    | python3 "${REPO_ROOT}/scripts/crd-to-jsonschema.py" "${OUT_DIR}"
}

main "$@"
