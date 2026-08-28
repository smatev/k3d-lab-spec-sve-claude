#!/usr/bin/env bash
#
# Expose the cluster's web UIs on the host's public interface, permanently.
#
# This is the one part of the lab that is about the *host*, not the cluster. When the lab
# runs on a remote box (an EC2 instance reached over SSH) rather than a laptop, the
# `make argocd-ui` / `make gitea-ui` targets are no use: they bind 127.0.0.1, which is the
# right default and is unreachable from a browser anywhere else.
#
# Two things have to be true to reach a UI from outside:
#
#   1. The forward binds 0.0.0.0, not localhost.  <- this script
#   2. The port is open in the host's firewall.   <- not this script, see README
#
# Point 2 cannot be done from here and cannot be detected from here either. A blocked port
# times out (ERR_CONNECTION_TIMED_OUT); a port with nothing behind it refuses immediately.
# If you get a timeout, the firewall is the problem, not this script.
#
# SECURITY: a forward bound to 0.0.0.0 is reachable by anyone the firewall lets in. Argo CD
# here has cluster-admin over the lab, and Gitea's password is `lab-not-a-secret`, checked
# into this repo. Scope the firewall rule to your own address. Do not do this on a box that
# holds anything you care about.
#
# Persistence is systemd --user with Restart=always, which also covers the case that
# actually bites: `kubectl port-forward` dies when the pod behind it restarts, and pods in
# this lab restart whenever the box does.
#
# Usage:
#   scripts/remote-ui.sh install     write + enable + start both units (idempotent)
#   scripts/remote-ui.sh status      units, listeners, and what answers on each port
#   scripts/remote-ui.sh stop        stop both, leave them enabled for next boot
#   scripts/remote-ui.sh start       start both
#   scripts/remote-ui.sh uninstall   stop, disable, and remove the units
#   scripts/remote-ui.sh forward <name>   run one forward in the foreground (systemd calls this)

set -euo pipefail

readonly CONTEXT="k3d-lab"
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly UNIT_DIR="${HOME}/.config/systemd/user"
readonly UNIT="k3d-lab-ui@.service"

# name | namespace | service | host port | service port
#
# Host ports are overridable because which ports are open is a property of the box, not of
# the lab. Change them here or in the environment, then re-run `install`.
readonly ARGOCD_PORT="${ARGOCD_UI_PORT:-8080}"
readonly GITEA_PORT="${GITEA_UI_PORT:-8081}"

readonly SERVICES=(
  "argocd|argocd|svc/argocd-server|${ARGOCD_PORT}|80"
  "gitea|gitea|svc/gitea-http|${GITEA_PORT}|3000"
)

step() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[1;33m!\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }

lookup() {
  local want="$1" row
  for row in "${SERVICES[@]}"; do
    IFS='|' read -r name ns svc lport sport <<<"${row}"
    if [[ "${name}" == "${want}" ]]; then
      printf '%s|%s|%s|%s\n' "${ns}" "${svc}" "${lport}" "${sport}"
      return 0
    fi
  done
  return 1
}

names() {
  local row
  for row in "${SERVICES[@]}"; do printf '%s\n' "${row%%|*}"; done
}

# --- the thing systemd actually runs -----------------------------------------
#
# Exec'd in the foreground so systemd owns the process and can restart it. Everything the
# unit needs to know lives in the table above, so the unit file stays a template.
cmd_forward() {
  local want="${1:-}" fields
  [[ -n "${want}" ]] || { echo "usage: $0 forward <name>" >&2; exit 2; }
  fields="$(lookup "${want}")" || { echo "error: unknown service '${want}'" >&2; exit 2; }
  IFS='|' read -r ns svc lport sport <<<"${fields}"

  exec kubectl --context "${CONTEXT}" -n "${ns}" \
    port-forward --address 0.0.0.0 "${svc}" "${lport}:${sport}"
}

# --- install ------------------------------------------------------------------
cmd_install() {
  if ! command -v kubectl >/dev/null 2>&1; then
    echo "error: kubectl not on PATH. Run via 'make remote-ui', which adds mise's shims." >&2
    exit 1
  fi
  if ! kubectl --context "${CONTEXT}" get ns >/dev/null 2>&1; then
    echo "error: context '${CONTEXT}' is not reachable. Run 'make up' first." >&2
    exit 1
  fi

  # Without linger, a --user manager is torn down when the last login session ends, and
  # nothing starts at boot. That makes "permanent" a lie, so refuse to pretend.
  step "Enabling linger (so user units survive logout and start at boot)"
  if [[ "$(loginctl show-user "${USER}" --property=Linger --value 2>/dev/null)" == "yes" ]]; then
    ok "already enabled"
  elif loginctl enable-linger "${USER}" 2>/dev/null; then
    ok "enabled"
  else
    warn "could not enable linger — forwards will stop when you log out"
    warn "an admin can fix this with: sudo loginctl enable-linger ${USER}"
  fi

  step "Writing ${UNIT_DIR}/${UNIT}"
  mkdir -p "${UNIT_DIR}"
  # PATH is pinned to mise's shims because a systemd --user unit does not read your shell
  # profile; without this the unit starts and immediately fails on "kubectl: not found".
  cat >"${UNIT_DIR}/${UNIT}" <<EOF
[Unit]
Description=k3d-lab: expose %i on the host's public interface
Documentation=file://${REPO_ROOT}/README.md
# No After=network-online.target: the k3d cluster may well not be up yet at boot. The
# unit is expected to fail and be retried until it is, which is what Restart=always is for.

[Service]
Type=simple
# WorkingDirectory matters as much as PATH: mise's shims resolve a pinned version from
# .tool-versions in the cwd, and a systemd unit's cwd is otherwise \$HOME, not the repo —
# so without this, the shim runs but still fails with "No version is set for shim: kubectl".
WorkingDirectory=${REPO_ROOT}
Environment=PATH=${HOME}/.local/share/mise/shims:${HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=${REPO_ROOT}/scripts/remote-ui.sh forward %i
Restart=always
RestartSec=5
# Never stop retrying. The cluster being down at boot is normal, not a reason to give up.
StartLimitIntervalSec=0

[Install]
WantedBy=default.target
EOF
  ok "written"

  step "Enabling and starting"
  systemctl --user daemon-reload
  local name
  for name in $(names); do
    systemctl --user enable --now "k3d-lab-ui@${name}.service" >/dev/null 2>&1 \
      || systemctl --user restart "k3d-lab-ui@${name}.service"
    ok "k3d-lab-ui@${name}"
  done

  # port-forward returns before it is listening; poll rather than sleep and hope.
  step "Waiting for the ports to answer"
  local fields lport attempt
  for name in $(names); do
    fields="$(lookup "${name}")"
    IFS='|' read -r _ _ lport _ <<<"${fields}"
    for attempt in $(seq 1 30); do
      if curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:${lport}/" 2>/dev/null; then
        ok "${name} answering on :${lport}"
        break
      fi
      [[ "${attempt}" == 30 ]] && bad "${name} did not answer on :${lport}"
      sleep 1
    done
  done

  cmd_status
}

# --- status -------------------------------------------------------------------
cmd_status() {
  local ip name fields ns svc lport sport state code title token
  # EC2 IMDSv2: the unauthenticated v1 GET is refused, so mint a token first. Any failure
  # here is cosmetic — it only decides whether the URLs below are printed with a real
  # address or a placeholder — so never let it kill the script.
  token="$(curl -fsS -X PUT --max-time 2 http://169.254.169.254/latest/api/token \
             -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null || true)"
  ip="$(curl -fsS --max-time 2 http://169.254.169.254/latest/meta-data/public-ipv4 \
          -H "X-aws-ec2-metadata-token: ${token}" 2>/dev/null || true)"
  [[ -n "${ip}" ]] || ip="<this-host>"

  step "Forwards"
  for name in $(names); do
    fields="$(lookup "${name}")"
    IFS='|' read -r ns svc lport sport <<<"${fields}"

    state="$(systemctl --user is-active "k3d-lab-ui@${name}.service" 2>/dev/null || true)"
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${lport}/" 2>/dev/null || echo 000)"
    title="$(curl -s --max-time 3 "http://127.0.0.1:${lport}/" 2>/dev/null \
             | grep -io '<title>[^<]*</title>' | head -1 | sed 's/<[^>]*>//g' || true)"

    if [[ "${state}" == "active" && "${code}" == "200" ]]; then
      ok "$(printf '%-7s http://%s:%s  -> %s' "${name}" "${ip}" "${lport}" "${title:-200}")"
    elif [[ "${state}" == "active" ]]; then
      bad "$(printf '%-7s unit active but :%s answered %s' "${name}" "${lport}" "${code}")"
    else
      bad "$(printf '%-7s unit %s' "${name}" "${state:-not installed}")"
    fi
  done

  printf '\n  A browser timeout on these URLs is the host firewall, not this script.\n'
  printf '  See README.md, "Reaching the UIs from another machine".\n'
}

cmd_start()     { local n; for n in $(names); do systemctl --user start   "k3d-lab-ui@${n}.service"; ok "${n} started"; done; }
cmd_stop()      { local n; for n in $(names); do systemctl --user stop    "k3d-lab-ui@${n}.service" 2>/dev/null || true; ok "${n} stopped"; done; }

cmd_uninstall() {
  local n
  step "Removing units"
  for n in $(names); do
    systemctl --user disable --now "k3d-lab-ui@${n}.service" >/dev/null 2>&1 || true
    ok "k3d-lab-ui@${n} stopped and disabled"
  done
  rm -f "${UNIT_DIR}/${UNIT}"
  systemctl --user daemon-reload
  ok "${UNIT} removed"
  printf '\n  Linger was left enabled. To undo it too: loginctl disable-linger %s\n' "${USER}"
}

case "${1:-}" in
  install)   cmd_install ;;
  status)    cmd_status ;;
  start)     cmd_start ;;
  stop)      cmd_stop ;;
  uninstall) cmd_uninstall ;;
  forward)   shift; cmd_forward "$@" ;;
  *)
    sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
