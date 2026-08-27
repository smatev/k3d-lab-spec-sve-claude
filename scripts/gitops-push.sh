#!/usr/bin/env bash
#
# Publish this repository to the in-cluster Gitea, which is what Argo CD reconciles from.
#
# Why a port-forward rather than pushing to gitea.k3d.local through the Gateway: git has
# no `--resolve`. curl can be told where a hostname lives for one request, git cannot,
# and this lab does not touch /etc/hosts. A port-forward needs no name at all, so it is
# the DNS-free way in — the same trick `make dashboard` already uses for Traefik.
#
# Pushes HEAD, not the working tree. Uncommitted work is not GitOps; if the cluster is
# meant to run it, commit it.

set -euo pipefail

readonly CONTEXT="k3d-lab"
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

readonly GITEA_NS="gitea"
readonly GITEA_SVC="svc/gitea-http"
readonly GITEA_USER="lab"
readonly GITEA_PASSWORD="lab-not-a-secret"
readonly GITEA_REPO="k3d-lab"

# A high, unlikely-to-collide local port. Nothing binds it for longer than this script.
readonly LOCAL_PORT="${GITEA_LOCAL_PORT:-3300}"

# The branch Argo CD's root Application follows (targetRevision: HEAD -> default branch).
readonly TARGET_BRANCH="main"

k() { kubectl --context "${CONTEXT}" "$@"; }
step() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }

pf_pid=""
cleanup() {
  [[ -n "${pf_pid}" ]] && kill "${pf_pid}" 2>/dev/null || true
  [[ -n "${pf_pid}" ]] && wait "${pf_pid}" 2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
if ! k -n "${GITEA_NS}" get "${GITEA_SVC}" >/dev/null 2>&1; then
  echo "error: ${GITEA_SVC} not found in namespace ${GITEA_NS}. Run 'make bootstrap'." >&2
  exit 1
fi

if [[ -n "$(git -C "${REPO_ROOT}" status --porcelain)" ]]; then
  printf '\033[1;33mwarning:\033[0m working tree is dirty — pushing HEAD, not your edits.\n'
  git -C "${REPO_ROOT}" status --short | sed 's/^/    /'
fi

step "Port-forwarding ${GITEA_SVC} to 127.0.0.1:${LOCAL_PORT}"
k -n "${GITEA_NS}" port-forward "${GITEA_SVC}" "${LOCAL_PORT}:3000" >/dev/null 2>&1 &
pf_pid=$!

# port-forward returns before it is listening. Poll rather than sleep and hope.
for attempt in $(seq 1 30); do
  if curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:${LOCAL_PORT}/api/healthz" 2>/dev/null; then
    break
  fi
  if [[ "${attempt}" == 30 ]]; then
    echo "error: gitea did not answer on 127.0.0.1:${LOCAL_PORT}" >&2
    exit 1
  fi
  sleep 1
done

readonly API="http://127.0.0.1:${LOCAL_PORT}/api/v1"
readonly AUTH="${GITEA_USER}:${GITEA_PASSWORD}"

# ---------------------------------------------------------------------------
step "Ensuring repository ${GITEA_USER}/${GITEA_REPO} exists"
if curl -fsS -o /dev/null -u "${AUTH}" "${API}/repos/${GITEA_USER}/${GITEA_REPO}" 2>/dev/null; then
  echo "  already exists"
else
  # default_branch must match what Argo CD's targetRevision: HEAD resolves to.
  curl -fsS -o /dev/null -u "${AUTH}" -X POST "${API}/user/repos" \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"${GITEA_REPO}\",\"private\":false,\"default_branch\":\"${TARGET_BRANCH}\",\"auto_init\":false}"
  echo "  created"
fi

# ---------------------------------------------------------------------------
step "Pushing HEAD to ${TARGET_BRANCH}"
readonly PUSH_URL="http://${GITEA_USER}:${GITEA_PASSWORD}@127.0.0.1:${LOCAL_PORT}/${GITEA_USER}/${GITEA_REPO}.git"

# --force because this mirrors local history rather than collaborating with anyone. The
# in-cluster Gitea is a publishing target, not a place work is done.
#
# The URL carries the lab password, so keep it out of the terminal and out of any log.
if ! git -C "${REPO_ROOT}" push --force "${PUSH_URL}" "HEAD:refs/heads/${TARGET_BRANCH}" 2>&1 \
     | sed "s|${GITEA_PASSWORD}|****|g" | sed 's/^/    /'; then
  echo "error: push failed" >&2
  exit 1
fi

sha="$(git -C "${REPO_ROOT}" rev-parse --short HEAD)"
printf '\n\033[1;32mpushed:\033[0m %s -> %s/%s @ %s\n' \
  "${sha}" "${GITEA_USER}" "${GITEA_REPO}" "${TARGET_BRANCH}"
printf '  Argo CD reconciles from http://gitea-http.gitea.svc.cluster.local:3000/%s/%s.git\n' \
  "${GITEA_USER}" "${GITEA_REPO}"
