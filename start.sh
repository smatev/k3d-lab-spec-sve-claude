#!/usr/bin/env bash
set -euo pipefail

if [ -z "${1:-}" ]; then
  echo "Usage: $0 <sudo_password>"
  exit 1
fi
SUDO_PASS="$1"

export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"

is_new_server() {
  ! command -v docker >/dev/null 2>&1 || ! command -v mise >/dev/null 2>&1
}

if is_new_server; then
  echo "==> New server detected, installing toolchain"

  if ! command -v docker >/dev/null 2>&1; then
    echo "$SUDO_PASS" | sudo -S apt update
    echo "$SUDO_PASS" | sudo -S apt install -y docker.io
    echo "$SUDO_PASS" | sudo -S systemctl enable --now docker
    echo "$SUDO_PASS" | sudo -S usermod -aG docker "$USER"
    echo "==> docker.io installed. If this is the first install, log out and back in (or run 'newgrp docker') so group membership takes effect."
  fi

  if ! command -v mise >/dev/null 2>&1; then
    curl -fsSL https://mise.jdx.dev/install.sh | sh
  fi

  make tools
else
  echo "==> Toolchain already present, skipping install"
fi

make down && make up && make verify && make ci && make gitops && make gitops-test

# This box is reached over SSH, not a laptop: 127.0.0.1 forwards (make argocd-ui /
# gitea-ui) bind the server's own loopback, which a browser elsewhere can never reach.
# make remote-ui binds 0.0.0.0 instead, persists via systemd --user, and prints exactly
# this diagnosis if a port still doesn't answer — see README.md "Reaching the UIs from
# another machine". It also warns for a reason: Argo CD here has cluster-admin, and
# Gitea's password is public in this repo, so only your own address should reach these.
make remote-ui

ARGOCD_PASSWORD="$(kubectl --context k3d-lab -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"

echo ""
echo "==> Access points"
echo "Argo CD UI:  http://<this-host>:8080  (user: admin, password: ${ARGOCD_PASSWORD:-run 'make argocd-password'})"
echo "Gitea UI:    http://<this-host>:8081  (user: lab / lab-not-a-secret)"
echo "Both need the host firewall open to your IP on 8080/8081 — see README.md."
echo ""
echo "API docs are NOT browser-reachable here (no DNS for *.k3d.local from outside)."
echo "Use scripts/curl.sh instead:"
echo "  ./scripts/curl.sh https://demo-api.k3d.local/docs"
echo "  ./scripts/curl.sh https://demo-api-gitops.k3d.local/docs"
