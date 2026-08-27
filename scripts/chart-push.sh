#!/usr/bin/env bash
#
# Package the chart and push it to the k3d registry as an OCI artifact.
#
# This is the lab's "release" step. Argo CD does not read charts/demo-api/ out of Git —
# it pulls a versioned artifact from the registry — so a chart change is invisible to the
# cluster until it has been pushed here AND a commit has pointed an Application at the
# new version. Two steps, deliberately.
#
# The registry's two names matter again: we push to the HOST name and Argo CD pulls from
# the IN-CLUSTER one. They are the same registry.

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly CHART_DIR="${REPO_ROOT}/charts/demo-api"
readonly OUT_DIR="${REPO_ROOT}/.local/charts"

# Push target: reachable from the host. Argo CD pulls the same artifact from
# k3d-registry:5000/charts, which is the same registry under its in-cluster name.
readonly REGISTRY_HOST="localhost:5000"

step() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }

version="$(helm show chart "${CHART_DIR}" | awk '$1 == "version:" { print $2 }')"
if [[ -z "${version}" ]]; then
  echo "error: could not read version from ${CHART_DIR}/Chart.yaml" >&2
  exit 1
fi

step "Packaging demo-api ${version}"
mkdir -p "${OUT_DIR}"
helm package "${CHART_DIR}" --destination "${OUT_DIR}" >/dev/null

readonly TARBALL="${OUT_DIR}/demo-api-${version}.tgz"
[[ -f "${TARBALL}" ]] || { echo "error: ${TARBALL} not produced" >&2; exit 1; }

step "Pushing to oci://${REGISTRY_HOST}/charts"
# --plain-http because the k3d registry speaks HTTP. Without it helm attempts TLS and
# fails with a handshake error that reads like a missing chart.
helm push "${TARBALL}" "oci://${REGISTRY_HOST}/charts" --plain-http

printf '\n\033[1;32mpushed:\033[0m demo-api %s\n' "${version}"
printf '  Argo CD pulls this as  k3d-registry:5000/charts  chart demo-api  targetRevision %s\n' \
  "${version}"
