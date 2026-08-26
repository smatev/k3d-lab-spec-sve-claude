#!/usr/bin/env bash
#
# Confirm the pinned toolchain is actually what's on PATH.
#
# A clear "you have helm 4, this repo wants 3.21.4" beats a confusing failure three
# steps into a bootstrap.

set -uo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly TOOL_VERSIONS="${REPO_ROOT}/.tool-versions"

failures=0

ok()   { printf '  \033[32m✓\033[0m %-14s %s\n' "$1" "$2"; }
warn() { printf '  \033[33m!\033[0m %-14s %s\n' "$1" "$2"; failures=$((failures + 1)); }
bad()  { printf '  \033[31m✗\033[0m %-14s %s\n' "$1" "$2"; failures=$((failures + 1)); }

pinned() { awk -v k="$1" '$1 == k { print $2 }' "${TOOL_VERSIONS}"; }

# The version flag differs per tool and cannot be derived, so each is named explicitly.
# $1 binary, $2 key in .tool-versions, $3.. the command that prints its version.
check_tool() {
  local bin="$1" key="$2"; shift 2
  local want got
  want="$(pinned "${key}")"

  if [[ -z "${want}" ]]; then
    bad "${bin}" "no pin for '${key}' in .tool-versions"
    return
  fi
  if ! command -v "${bin}" >/dev/null 2>&1; then
    bad "${bin}" "missing (run: make tools)"
    return
  fi

  got="$("$@" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  if [[ "${got}" == "${want}" ]]; then
    ok "${bin}" "${got}"
  else
    warn "${bin}" "want ${want}, got ${got:-unknown}"
  fi
}

check_tool k3d         k3d                     k3d version
check_tool kubectl     kubectl                 kubectl version --client
check_tool helm        helm                    helm version
check_tool kubeconform kubeconform             kubeconform -v
check_tool kube-score  kube-score              kube-score version
check_tool ct          aqua:helm/chart-testing ct version

# helm-unittest is a helm plugin, not a mise tool, so it needs its own check.
if helm plugin list 2>/dev/null | grep -q '^unittest'; then
  ok helm-unittest "$(helm plugin list 2>/dev/null | awk '$1 == "unittest" { print $2 }')"
else
  warn helm-unittest "missing (run: make tools)"
fi

if docker info >/dev/null 2>&1; then
  ok docker "$(docker version --format '{{.Server.Version}}' 2>/dev/null)"
else
  bad docker "daemon unreachable"
fi

if [[ "${failures}" -eq 0 ]]; then
  printf '\n\033[1;32mdoctor: toolchain matches .tool-versions\033[0m\n'
  exit 0
fi
printf '\n\033[1;31mdoctor: %d problem(s)\033[0m\n' "${failures}"
exit 1
