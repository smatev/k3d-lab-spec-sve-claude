#!/usr/bin/env bash
#
# Prove that running bootstrap.sh again changes nothing.
#
# "Changes nothing" needs a precise definition. `helm upgrade --install` records a new
# release revision on every run by design — that is the pattern working, not a bug, and
# it is what makes the script converge rather than drift. What must NOT happen is any
# actual mutation: no workload restarted, no resource spec bumped.
#
# So this checks the substantive thing: pod identities and resource generations are
# identical before and after a second bootstrap.

set -uo pipefail

readonly CONTEXT="k3d-lab"
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

k() { kubectl --context "${CONTEXT}" "$@"; }

# Pod UIDs, not names: a recreated pod gets a new UID even if the name is reused.
#
# Job-owned pods are excluded. The argo-cd chart's redis-secret-init is a Helm hook
# annotated `pre-install,pre-upgrade` with `hook-delete-policy: before-hook-creation`,
# which means it is *defined* to be deleted and recreated on every upgrade — the hook
# working, in the same way an incrementing release revision is `upgrade --install`
# working. It creates the redis auth Secret if one is missing and leaves behind nothing
# but a Completed pod.
#
# Filtered on the owning Job rather than on the hook annotation, because the Job
# controller does not copy a Job's own annotations onto the pods it creates — only
# spec.template's. Filtering on helm.sh/hook here would silently match nothing and look
# like it worked. Nothing that serves traffic in this lab is owned by a Job.
snapshot_pods() {
  k get pods -A \
    -o jsonpath='{range .items[*]}{.metadata.ownerReferences[0].kind}{"\t"}{.metadata.namespace}/{.metadata.name} {.metadata.uid} restarts={.status.containerStatuses[0].restartCount}{"\n"}{end}' \
    2>/dev/null | awk -F'\t' '$1 != "Job" { print $2 }' | sort
}

# generation increments only when the *spec* changes, which is exactly the signal wanted.
snapshot_generations() {
  {
    k get gateway,httproute -A \
      -o jsonpath='{range .items[*]}{.kind}/{.metadata.namespace}/{.metadata.name} gen={.metadata.generation}{"\n"}{end}' 2>/dev/null
    k get gatewayclass,clusterissuer \
      -o jsonpath='{range .items[*]}{.kind}/{.metadata.name} gen={.metadata.generation}{"\n"}{end}' 2>/dev/null
    k get certificate,issuer -A \
      -o jsonpath='{range .items[*]}{.kind}/{.metadata.namespace}/{.metadata.name} gen={.metadata.generation}{"\n"}{end}' 2>/dev/null
    k get deploy,daemonset -A \
      -o jsonpath='{range .items[*]}{.kind}/{.metadata.namespace}/{.metadata.name} gen={.metadata.generation}{"\n"}{end}' 2>/dev/null
  } | sort
}

main() {
  if ! k cluster-info >/dev/null 2>&1; then
    echo "error: context '${CONTEXT}' is unreachable. Run 'make up' first." >&2
    exit 1
  fi

  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' EXIT

  snapshot_pods        > "${tmp}/pods.before"
  snapshot_generations > "${tmp}/gens.before"

  printf '\033[1;34m==>\033[0m Re-running bootstrap...\n'
  if ! "${REPO_ROOT}/cluster/bootstrap/bootstrap.sh" > "${tmp}/bootstrap.log" 2>&1; then
    echo "error: bootstrap.sh failed on its second run — that alone is a failure" >&2
    tail -30 "${tmp}/bootstrap.log" >&2
    exit 1
  fi

  snapshot_pods        > "${tmp}/pods.after"
  snapshot_generations > "${tmp}/gens.after"

  local failures=0

  printf '\n\033[1;34mPods\033[0m\n'
  if diff -q "${tmp}/pods.before" "${tmp}/pods.after" >/dev/null; then
    printf '  \033[32m✓\033[0m no pod recreated or restarted\n'
  else
    printf '  \033[31m✗\033[0m pods changed:\n'
    diff "${tmp}/pods.before" "${tmp}/pods.after" | sed 's/^/      /'
    failures=$((failures + 1))
  fi

  printf '\n\033[1;34mResource generations\033[0m\n'
  if diff -q "${tmp}/gens.before" "${tmp}/gens.after" >/dev/null; then
    printf '  \033[32m✓\033[0m no resource spec mutated\n'
  else
    printf '  \033[31m✗\033[0m generations changed:\n'
    diff "${tmp}/gens.before" "${tmp}/gens.after" | sed 's/^/      /'
    failures=$((failures + 1))
  fi

  if [[ "${failures}" -eq 0 ]]; then
    printf '\n\033[1;32midempotent: a second bootstrap changed nothing\033[0m\n'
    printf '(Helm release revisions do increment — `upgrade --install` records one per\n'
    printf ' run by design. No deployed object changed, which is the property that matters.)\n'
    exit 0
  fi
  printf '\n\033[1;31midempotent: %d difference(s) — bootstrap.sh is not idempotent\033[0m\n' "${failures}"
  exit 1
}

main "$@"
