#!/usr/bin/env bash
set -euo pipefail

if [ -n "${1:-}" ]; then
  SUDO_PASS="$1"          # set only by the sg-docker re-exec below, never typed here
else
  read -r -s -p "sudo password: " SUDO_PASS
  echo
fi
unset K3D_LAB_SUDO_PASS  # only a re-exec sets this; don't leak it into make/docker

export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"

# `usermod -aG docker` below edits /etc/group, but a process's group list is fixed at
# login: this shell, and every make/k3d/docker it spawns, keeps the credentials it
# started with. The symptom is "permission denied ... /var/run/docker.sock" even though
# `getent group docker` clearly lists you. Re-exec under the group instead of telling the
# user to log out — `sg` starts one new process with the group applied, no new session.
reexec_with_docker_group() {
  [ -n "${K3D_LAB_SG_REEXEC:-}" ] && return 0          # already re-execed; don't loop
  command -v docker >/dev/null 2>&1 || return 0        # nothing installed yet to test
  docker info >/dev/null 2>&1 && return 0              # socket already reachable
  id -nG | tr ' ' '\n' | grep -qx docker && return 0   # in-session already, real failure
  getent group docker | grep -q "\b${USER}\b" || return 0

  echo "==> docker group not active in this session, re-executing via 'sg docker'"
  # Args go through the environment, not the command line: `sg -c` hands the string to
  # sh, so quoting the sudo password back through it is both fragile and visible to
  # anyone running ps. The re-exec re-reads it from K3D_LAB_SUDO_PASS below.
  export K3D_LAB_SG_REEXEC=1
  export K3D_LAB_SUDO_PASS="$SUDO_PASS"
  K3D_LAB_SCRIPT="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  export K3D_LAB_SCRIPT
  exec sg docker -c 'exec bash "$K3D_LAB_SCRIPT" "$K3D_LAB_SUDO_PASS"'
}

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
    echo "==> docker.io installed."
  fi

  if ! command -v mise >/dev/null 2>&1; then
    curl -fsSL https://mise.jdx.dev/install.sh | sh
  fi

  reexec_with_docker_group
else
  echo "==> Toolchain already present, skipping install"
  reexec_with_docker_group
fi

# `reexec_with_docker_group` only returns here once the docker group is confirmed
# active — either because it was already active, or because this is the re-exec'd
# process. `exec` replaces the process on an actual re-exec, so `make tools` must live
# outside both branches above: putting it inside the `if` branch means it never runs,
# because the re-exec'd process takes the `else` branch instead (docker and mise are
# now both installed) and never reaches it either.
make tools

if ! docker info >/dev/null 2>&1; then
  echo "ERROR: cannot reach the Docker daemon at /var/run/docker.sock." >&2
  echo "  in docker group: $(id -nG | tr ' ' '\n' | grep -qx docker && echo yes || echo no)" >&2
  echo "  daemon running:  $(systemctl is-active docker 2>/dev/null || echo unknown)" >&2
  echo "If the group says no, log out and back in. Otherwise start the daemon." >&2
  exit 1
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
