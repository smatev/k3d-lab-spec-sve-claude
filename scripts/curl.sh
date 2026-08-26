#!/usr/bin/env bash
#
# DNS-free curl wrapper. The single way this repo makes an HTTP request.
#
#   scripts/curl.sh https://demo-api.k3d.local/api/v1/info [extra curl args...]
#
# Everything in the lab binds to 127.0.0.1:80 and 127.0.0.1:443. The only open question
# is how a *hostname* gets attached to the request, since routing rules and TLS
# certificates both key off one. `--resolve` injects the mapping into curl's own
# resolver: no DNS lookup happens, and unlike `-H "Host: ..."` it sets TLS SNI
# correctly — which matters the moment cert-manager issues per-host certificates.
#
# For https it also passes --cacert, so we do real verification against the local CA
# rather than reaching for -k.

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly CA_CERT="${REPO_ROOT}/.local/ca.crt"

if [[ $# -lt 1 ]]; then
  echo "usage: $(basename "$0") <url> [curl args...]" >&2
  exit 2
fi

url="$1"
shift

# Refuse to skip verification. If TLS fails here it is a real bug in the lab, and
# papering over it defeats the point of running a local CA at all.
for arg in "$@"; do
  case "${arg}" in
    -k|--insecure)
      echo "error: refusing -k/--insecure. A TLS failure here is a real bug — fix it." >&2
      exit 2
      ;;
  esac
done

scheme="${url%%://*}"
rest="${url#*://}"
hostport="${rest%%/*}"
host="${hostport%%:*}"
port="${hostport##*:}"
if [[ "${port}" == "${host}" ]]; then
  # No explicit port in the URL — infer it from the scheme.
  case "${scheme}" in
    https) port=443 ;;
    http)  port=80 ;;
    *) echo "error: unsupported scheme '${scheme}'" >&2; exit 2 ;;
  esac
fi

args=(--resolve "${host}:${port}:127.0.0.1")

if [[ "${scheme}" == "https" ]]; then
  if [[ ! -f "${CA_CERT}" ]]; then
    echo "error: ${CA_CERT} missing. Run 'make ca'." >&2
    exit 1
  fi
  args+=(--cacert "${CA_CERT}")
fi

exec curl "${args[@]}" "$@" "${url}"
