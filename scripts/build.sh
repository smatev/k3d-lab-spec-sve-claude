#!/usr/bin/env bash
#
# Build the demo-api image and push it to the k3d registry.
#
# The tag is not a parameter. It comes from `appVersion` in Chart.yaml, because that is
# what the chart uses as the default image tag (values.yaml leaves image.tag empty).
# Deriving it here means "build" and "install" cannot disagree about which image the
# release runs — the failure mode when they can is a pod happily running last week's
# code while `helm get values` insists otherwise.
#
# The registry has two names and they are not interchangeable:
#
#   localhost:5000     from the host — where docker push goes
#   k3d-registry:5000  from inside the cluster — what values.yaml puts in the pod spec
#
# Pushing to the in-cluster name fails to resolve; putting the host name in the pod spec
# gives ImagePullBackOff while `docker push` reports success. Both names appear below,
# each used exactly once, deliberately.

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly CHART="${REPO_ROOT}/charts/demo-api"

readonly REGISTRY_HOST="localhost:5000"
readonly REGISTRY_CLUSTER="k3d-registry:5000"
readonly IMAGE_NAME="demo-api"

main() {
  local tag
  tag="$(helm show chart "${CHART}" | awk '$1 == "appVersion:" { gsub(/"/, "", $2); print $2 }')"
  if [[ -z "${tag}" ]]; then
    echo "error: could not read appVersion from ${CHART}/Chart.yaml" >&2
    exit 1
  fi

  # Refuse to build a floating tag even if someone sets appVersion to it. `latest` makes
  # the running image unidentifiable and every pod restart a coin flip.
  if [[ "${tag}" == "latest" ]]; then
    echo "error: appVersion is 'latest'. Pin a real version." >&2
    exit 1
  fi

  local host_ref="${REGISTRY_HOST}/${IMAGE_NAME}:${tag}"

  echo "==> building ${IMAGE_NAME}:${tag}"
  docker build --tag "${host_ref}" "${REPO_ROOT}/app"

  echo "==> pushing ${host_ref}"
  if ! docker push "${host_ref}"; then
    echo "error: push to ${REGISTRY_HOST} failed. Is the cluster up? (make up)" >&2
    exit 1
  fi

  # Confirm the registry actually has it, rather than trusting the exit code of a push
  # that can succeed against a stale local daemon cache.
  if ! curl -sf "http://${REGISTRY_HOST}/v2/${IMAGE_NAME}/tags/list" \
       | grep -q "\"${tag}\""; then
    echo "error: ${REGISTRY_HOST} does not list tag ${tag} after the push" >&2
    exit 1
  fi

  echo
  echo "pushed. The cluster pulls this as:"
  echo "  ${REGISTRY_CLUSTER}/${IMAGE_NAME}:${tag}"
}

main "$@"
