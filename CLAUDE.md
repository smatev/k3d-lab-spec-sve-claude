# k3d-lab

Local Kubernetes learning lab. Everything is code — no manual kubectl apply.

## Facts

- Cluster: k3d 5.9.0, 1 server + 2 agents, Kubernetes v1.36.3 (`rancher/k3s:v1.36.3-k3s1`).
- Cluster name is `lab`; the kube context is `k3d-lab`.
- k3s ships Traefik but we DISABLE it (`--disable=traefik`) and install a pinned Traefik
  via Helm ourselves — chart `41.3.0`, Traefik v3.7.11.
- cert-manager `v1.21.1`. Gateway API `v1.6.1`, standard channel, vendored to
  `cluster/bootstrap/gateway-api-crds.yaml`. Never curl CRDs at runtime.
- Routing: Gateway API (HTTPRoute) is primary. A shared Gateway lives in the `gateway`
  namespace, `allowedRoutes.namespaces.from: All`. Ingress is supported only as a
  compatibility toggle in the app chart.
- ingress-nginx is retired as of March 2026. Never suggest it.
- Local registry: `k3d-registry:5000` inside the cluster, `localhost:5000` from the host.
  Image refs in values.yaml use the in-cluster name.

## Facts that are easy to get wrong

- **Gateway listener ports are 8000 and 8443, not 80 and 443.** Traefik binds a listener
  to the entrypoint with the *matching port number*, and the chart's entrypoints are
  `web: 8000` / `websecure: 8443`. The Service maps 80→8000 and 443→8443. A listener on
  port 80 resolves to no entrypoint and silently routes nothing.
- **The Traefik chart creates a Gateway and GatewayClass by default.** We set
  `gateway.enabled: false` and `gatewayClass.enabled: false` because both live in
  `cluster/bootstrap/gateway/`. Do not re-enable them.
- **Port 80 returns 301, not 404.** `web` redirects to `websecure` (`permanent: true`, so
  301), and plain HTTP never reaches routing. The Traefik 404 for an unrouted host is
  observable on :443 only.
- **The Traefik chart's values.schema.json is strict.** TLS on an entrypoint is
  `ports.websecure.http.tls`, not `ports.websecure.tls`, and the logging key is `log`,
  not `logs`. Wrong spellings are rejected at install time rather than ignored.
- **k3d does not prepend `k3d-` to the registry name.** `registries.create.name` in
  cluster/k3d.yaml is used verbatim as the container name, the Docker-network DNS name,
  and the mirror key in each node's registries.yaml. It is spelled `k3d-registry` there
  on purpose.
- **Helm is pinned to 3.21.4 on purpose.** Helm 4 changed the plugin API and neither
  chart-testing nor helm-unittest supports it. Do not "upgrade" it.
- A wildcard certificate for `*.k3d.local` does not cover `localhost`, or a bare
  `k3d.local`. All three are listed explicitly in the Gateway's Certificate.
- **`helm.sh/hook-delete-policy` on the test pod is `before-hook-creation` ONLY.**
  Adding `hook-succeeded` breaks `helm test --logs`: Helm deletes the pod on success,
  then fails to read its logs, so a *passing* test exits non-zero with
  `pods "…-test-connection" not found`.
- **`ct` needs `chart_schema.yaml` and `lintconf.yaml`, and `yamale` and `yamllint`.**
  Upstream ships the first two inside its Docker image at `/etc/ct`; we run the binary,
  so they are vendored in `etc/` and named in `ct.yaml`. Without any of the four, `ct
  lint` exits before it lints anything. `ct` resolves those paths relative to the
  working directory, so `scripts/lint.sh` runs it from the repo root.
- **`.helmignore` patterns match at any depth unless anchored.** A bare `tests/`
  silently excludes `templates/tests/` too, which is the `helm test` hook. The symptom
  is `TEST SUITE: None` and nothing saying why. Ours are `/tests/` and `/ci/`.
- `rollout status` returns when the new pods are Ready, which with `maxUnavailable: 0`
  is *before* the old ones finish terminating. A check that reads the app right after it
  can still hit a draining pod.

## Rules — DNS

- There is NO external DNS in this project. No nip.io, sslip.io, or similar.
- Never add /etc/hosts entries. Never suggest them as a fix.
- All HTTP checks use `scripts/curl.sh`, which wraps `curl --resolve <host>:<port>:127.0.0.1`
  and `--cacert .local/ca.crt`. Use it; do not hand-roll curl invocations.
- Never use `curl -k`. If TLS verification fails, that is a real bug — fix it.
  `scripts/curl.sh` refuses `-k` outright.
- Do not build on `*.localhost` resolving automatically. Fine as a convenience, useless
  as a contract.

## Rules — general

- The only kube context this repo touches is `k3d-lab`. Never any other context. Every
  `kubectl`/`helm` call passes `--context` / `--kube-context` explicitly.
- Every change must keep `make verify` passing. A chart change must also keep `make ci`
  passing. Run them before saying you're done.
- kube-score findings are silenced by name, never wholesale, and always with the reason
  written next to them — in the manifest (`kube-score/ignore` on the test pod) or in the
  one `ci/` value set the finding is expected in. `--ignore-test` in `scripts/lint.sh`
  is repo-wide and is the last resort.
- Chart and tool versions are pinned in `.tool-versions` and `bootstrap.sh`. Do not bump
  them without being asked.
- `bootstrap.sh` must stay idempotent: running it twice changes nothing.
- Nothing generated gets committed. `.local/` is gitignored; `git status` is clean after
  a full `make up && make verify`.

## Layout

```
cluster/k3d.yaml              declarative cluster definition
cluster/bootstrap/            bootstrap.sh + pinned values and manifests
app/                          the demo service + Dockerfile
charts/demo-api/              the chart; ci/ = chart-testing value sets, tests/ = unit specs
schemas/crds/                 CRDs the lab validates against but does not install
etc/                          chart-testing's vendored schema and yamllint config
scripts/curl.sh               the only way this repo makes an HTTP request
scripts/verify.sh             the acceptance test for the cluster
scripts/lint.sh               helm lint + ct lint + kubeconform + kube-score
scripts/gen-schemas.sh        vendored CRDs -> JSON schemas in .local/ (via crd-to-jsonschema.py)
scripts/build.sh              docker build + push, tagged from Chart.yaml appVersion
scripts/smoke.sh              the acceptance test for an installed release
scripts/rollout-test.sh       config-change rollout, zero-drop upgrade, rollback
scripts/hpa-test.sh           burn load -> scale up -> scale back down
```

## Current state

Parts 1 and 2 are built. `make ci` (lint, unit, build, install, smoke) is green, as are
`make ct-install`, `make rollout`, `make hpa` and `make verify`.

Part 3 is not started; the candidates are in `k3d-lab-spec.md`. Two things already point
at it: `metrics.serviceMonitor` is off by default because `monitoring.coreos.com` is not
installed (the CRD is vendored in `schemas/crds/` for validation only), and
`ct.yaml` disables `check-version-increment` because the chart is developed in place
rather than published — turn it back on the day it is pushed to the registry.
