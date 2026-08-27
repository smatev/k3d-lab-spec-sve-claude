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
- GitOps (Part 3): Argo CD chart `10.4.0` (app v3.5.1) and Gitea chart `12.7.0`
  (app 1.27.0), both installed by `bootstrap.sh`. Argo CD reconciles from the
  **in-cluster** Gitea, never from GitHub — the real remote is private and this lab
  commits no credentials.
- The app-of-apps root Application is the ONLY Application bootstrap.sh applies.
  Everything else arrives from `gitops/apps/` in the repo. The chart itself comes from
  the OCI registry (`k3d-registry:5000/charts`), not from Git.
- Argo CD manages `demo-api` into namespace `demo-api-gitops`, hostname
  `demo-api-gitops.k3d.local`. That is deliberately separate from `make install`, which
  is Helm-managed in namespace `demo-api`. Both run at once; they must not share a
  hostname or an object.

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
- **For a plain-HTTP OCI registry, Argo CD needs `insecureOCIForceHttp: "true"` on the
  repository — NOT `insecure: "true"`.** `insecure` means "skip certificate
  verification", so Argo CD still dials HTTPS and fails with `server gave HTTP response
  to HTTPS client`. Setting both is worse than setting neither: `insecure` adds
  `--insecure-skip-tls-verify` to the underlying `helm pull`, and helm ignores
  `--plain-http` when both flags are present, so the pull keeps using TLS.
- **The argo-cd chart has no `applicationSet.enabled`.** The key does not exist, so
  setting it is accepted and silently ignored — the ApplicationSet controller's
  Deployment template is unconditional, unlike `notifications`, which is genuinely
  guarded by `if .Values.notifications.enabled`. `applicationSet.replicas: 0` is the
  only way to not run it.
- **Gitea's chart deploys a Deployment, not a StatefulSet**, despite the PVC, and
  `gitea-http` is a *headless* Service (`clusterIP: None`). Both are fine; `rollout
  status statefulset/gitea` is not, and fails with a NotFound that reads like the
  install broke.
- **Argo CD's server must run with `server.insecure: true`** because Traefik terminates
  TLS. Left on HTTPS behind a TLS-terminating proxy it 307s every request to https and
  the browser loops.
- `git` has no `--resolve`, so the in-cluster Gitea cannot be pushed to through the
  Gateway the way `curl.sh` reaches everything else. `scripts/gitops-push.sh` uses a
  port-forward, which needs no hostname at all. Do not "fix" this with /etc/hosts.
- `helm push` to the k3d registry needs `--plain-http` for the same reason as above.
- **The argo-cd chart's `redis-secret-init` hook breaks a naive idempotency check.** It
  is `pre-install,pre-upgrade` with `hook-delete-policy: before-hook-creation`, so every
  bootstrap deletes and recreates its pod by design. `check-idempotent.sh` therefore
  ignores Job-owned pods — filtered on the owning Job, not on the `helm.sh/hook`
  annotation, because the Job controller does not copy a Job's annotations onto its
  pods and that filter would silently match nothing.

## Rules — remote access

- `make argocd-ui`, `make gitea-ui` and `make dashboard` bind `127.0.0.1` **on purpose**.
  Do not "fix" them to bind `0.0.0.0`. When the lab runs on a remote box and a browser
  elsewhere needs in, that is `make remote-ui` — a separate, opt-in path.
- `scripts/remote-ui.sh` is the only script here about the *host* rather than the cluster,
  and the only one that touches systemd. It installs `k3d-lab-ui@.service` as a
  `systemd --user` template unit and enables linger. The units live in `~/.config/systemd/`,
  outside the repo, so nothing generated is committed.
- **`kubectl port-forward` dies when the pod behind it restarts.** That is why the units
  are `Restart=always` with `StartLimitIntervalSec=0` — at boot the cluster is usually not
  up yet, so failing and retrying is the normal path, not an error.
- **A systemd `--user` unit does not read your shell profile.** The unit pins `PATH` to
  mise's shims explicitly; without that it starts and instantly dies on `kubectl: not
  found`.
- **The remote ports collide with the localhost targets.** Argo CD takes 8080, which
  `make dashboard` wants; Gitea takes 8081, which `make argocd-ui` wants. With the
  permanent forwards up, those one-off targets cannot bind.
- Whether a port is reachable is a firewall question this repo cannot answer or detect.
  Timeout = firewall dropping packets; refused = port open, nothing listening. On EC2
  there is no `aws` CLI on the box, so the security group is a console change.
- Exposing Argo CD this way hands cluster-admin to anyone the firewall admits, and Gitea's
  password is in this repo. Say so when suggesting it; scope the rule to one address.

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
cluster/bootstrap/gitops/     AppProject, HTTPRoutes, and the one root Application
gitops/apps/                  child Applications — what the root app watches, in Git
scripts/chart-push.sh         helm package + push to the OCI registry (the release step)
scripts/gitops-push.sh        publish HEAD to the in-cluster Gitea, over a port-forward
scripts/gitops-test.sh        delete/scale/edit by hand -> prove Argo CD undoes it
scripts/remote-ui.sh          expose Argo CD/Gitea on 0.0.0.0 permanently (systemd --user)
```

## Current state

Parts 1, 2 and 3 are built. `make verify`, `make ci` (lint, unit, build, install,
smoke), `make ct-install`, `make rollout`, `make hpa`, `make gitops` and
`make gitops-test` are all green.

Part 3 chose candidate **A (GitOps)** from `k3d-lab-spec.md`. The remaining candidates
there — supply chain/CI, observability, policy, progressive delivery — are still open.

Two loose ends worth knowing:

- `metrics.serviceMonitor` is off by default because `monitoring.coreos.com` is not
  installed (the CRD is vendored in `schemas/crds/` for validation only). Candidate C
  would change that.
- `ct.yaml` disables `check-version-increment`. The chart IS now published to the OCI
  registry by `make chart-push`, so the original reason ("developed in place, never
  published") has partly expired — but the registry holds no index `ct` can diff
  against, so turning it on still needs thought rather than a one-line flip.
