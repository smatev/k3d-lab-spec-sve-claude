# k3d Lab — Project Spec

A hands-on learning project: build a reproducible local Kubernetes lab entirely as code,
then ship a properly-built Helm chart onto it.

The real goal is not the cluster. It's building a **verification loop** — a `make` target that
tells you in 30 seconds whether the thing still works. That loop is what makes working with an
AI coding agent safe and fast, and it's the habit worth forming first.

**Two constraints drive the design:**

1. **Zero external dependencies at runtime.** No public DNS, no wildcard resolver services, no
   `/etc/hosts` edits. The lab works on a plane.
2. **Traefik, and Gateway API as the primary routing surface.** The community ingress-nginx
   controller was retired in March 2026 — archived, no security patches. The Ingress API itself
   survives but is feature-frozen; development moved to Gateway API. Learning `Ingress` as the
   default in 2026 is learning a dead end.

---

## Ground rules

1. **Nothing is done by hand.** If it isn't in the repo, it doesn't exist. The test is
   `make down && make up` — if the result differs, something was clicked.
2. **Every part ends with a `make` target that proves it works.** No "looks fine to me."
3. **Plan mode for anything touching more than one file.** Read the plan, then execute.
4. **Commit before letting the agent loose.** A clean `git diff` is the cheapest undo button
   that exists.

---

## Repo layout

```
k3d-lab/
├── .tool-versions                    # mise/asdf pins: k3d, kubectl, helm, kubeconform, ct
├── Makefile                          # the only entrypoint anyone should need
├── CLAUDE.md                         # project context for the agent
├── README.md
├── .gitignore                        # .local/ — generated CA cert, kubeconfig
├── cluster/
│   ├── k3d.yaml                      # declarative cluster definition
│   └── bootstrap/
│       ├── bootstrap.sh
│       ├── gateway-api-crds.yaml     # pinned Gateway API CRD bundle
│       ├── traefik.values.yaml
│       ├── cert-manager.values.yaml
│       ├── local-ca/
│       │   ├── ca-certificate.yaml
│       │   └── cluster-issuer.yaml
│       └── gateway/
│           ├── gatewayclass.yaml
│           ├── gateway.yaml          # shared Gateway, listeners + TLS
│           └── certificate.yaml
├── app/
│   ├── Dockerfile
│   └── main.go                       # or main.py — see notes
├── charts/
│   └── demo-api/
│       ├── Chart.yaml
│       ├── values.yaml
│       ├── values.schema.json
│       ├── .helmignore
│       ├── README.md
│       ├── templates/
│       ├── tests/                    # helm-unittest specs
│       └── ci/                       # value sets exercised by chart-testing
└── scripts/
    ├── verify.sh
    └── curl.sh                       # DNS-free curl wrapper — see Part 1
```

---

# Part 1 — k3d cluster, all as code

## Objective

`make up` produces an identical, working cluster on any machine with the pinned tools
installed, with no network access beyond pulling images. `make down` removes every trace.

## Components

### Tool pinning

`.tool-versions` (mise or asdf) pinning k3d, kubectl, helm, kubeconform, chart-testing, and
whatever else creeps in. Version skew between two laptops is the most boring possible way to
lose an afternoon.

### Cluster definition — `cluster/k3d.yaml`

k3d takes a declarative config file, which is the point — no long `k3d cluster create`
incantation buried in shell history. Generate a skeleton with `k3d config init` and check the
current `apiVersion` while you're there; it moves between k3d releases.

| Setting | Value | Why |
|---|---|---|
| servers / agents | 1 / 2 | Multi-node so `topologySpreadConstraints` and PDBs mean something |
| image | pinned k3s tag | Pin the Kubernetes version. Don't float. |
| ports | `80:80@loadbalancer`, `443:443@loadbalancer` | Reachable on plain `localhost` |
| registry | `create:` a local registry | Push images without a remote registry |
| k3s args | `--disable=traefik` | See below — you install your own, pinned |
| options | `wait: true`, sane `timeout` | `make up` should fail loudly, not half-succeed |

**Why disable the bundled Traefik and reinstall it?** k3s ships Traefik and configures it
through a `HelmChartConfig` CR dropped into the server manifests directory. That mechanism is
worth knowing — you *will* meet it in the wild, and k3d can mount files into that directory —
but it pins you to whatever Traefik version your k3s tag carries and splits configuration
across two idioms. Installing it yourself keeps `bootstrap.sh` uniform and the version explicit.
Do it the explicit way, and read up on `HelmChartConfig` separately.

**The registry gotcha, called out up front:** the registry has two names — one from the host
(`localhost:<mapped-port>`) and one from inside the cluster (`k3d-<name>:5000`). Image
references in Helm values must use the *in-cluster* name. This trips up everyone once; better
to hit it deliberately.

### Reaching the cluster without DNS

Everything binds to `127.0.0.1:80` and `127.0.0.1:443`. The only question is how a *hostname*
gets attached to a request, since routing rules and TLS certificates both key off one.

**Canonical method — `curl --resolve`:**

```bash
curl --resolve demo-api.k3d.local:443:127.0.0.1 \
     --cacert .local/ca.crt \
     https://demo-api.k3d.local/api/v1/info
```

`--resolve` injects the mapping into curl's own resolver. No DNS lookup happens, and unlike
`-H "Host: ..."` it sets TLS SNI correctly — which matters the moment cert-manager is issuing
per-host certificates. Wrap it in `scripts/curl.sh` so every test and every README example uses
the same path.

**Trusting the local CA:** a `make ca` target extracts the root CA from the cert-manager secret
to `.local/ca.crt` (gitignored). Now `--cacert` works and you're doing real TLS verification
locally, not `-k`. That distinction is worth internalising.

**For a browser**, `--resolve` isn't available. Two options, in order of preference:

- **Path-based routing on `localhost`.** A second `HTTPRoute` matching `PathPrefix: /demo` on
  hostname `localhost`, with a `URLRewrite` filter stripping the prefix. Needs nothing outside
  the repo, works in any browser, and teaches Gateway API filters. This is the recommended one.
- **`make hosts` / `make unhosts`.** Adds and removes `/etc/hosts` entries. Requires sudo and
  touches state outside the repo — document it as the explicit exception, never as a dependency
  of `make verify`.

Do **not** build on `*.localhost` resolving automatically. systemd-resolved does it, most
browsers do it, macOS doesn't reliably. Fine as a convenience, useless as a contract.

### Bootstrap — `cluster/bootstrap/bootstrap.sh`

Idempotent — running it twice is a no-op. In order:

1. **Gateway API CRDs** — applied from a pinned bundle vendored into the repo, not curled from
   a URL at runtime. Standard channel is enough; note that experimental features live in a
   separate channel.
2. **Traefik** via `helm upgrade --install`, pinned chart version, values file. Key settings:
   - Gateway API provider enabled (Traefik needs the CRDs present first — hence the ordering)
   - Kubernetes Ingress provider also enabled, so the chart's compat toggle is testable
   - `web` and `websecure` entrypoints, with `web` redirecting to `websecure`
   - Dashboard enabled but *not* exposed by default — reach it via `kubectl port-forward`
3. **cert-manager**, plus a self-signed root CA and a `ClusterIssuer` pointing at it. Real TLS,
   no public DNS, no Let's Encrypt.
4. **A shared `Gateway`** in its own namespace, with an HTTPS listener whose TLS secret is
   produced by an explicit `Certificate` resource. Set `allowedRoutes` to permit `HTTPRoute`s
   from other namespaces so the app chart can attach to it.

Reference the `Certificate` explicitly rather than relying on cert-manager's Gateway
annotation shim — the explicit resource is clearer and doesn't depend on a feature gate.

Keep this a plain shell script for now. Part 3 may replace it, and that replacement lands
better if you've felt the script's shortcomings first.

### Makefile

```
make up        # k3d cluster create --config cluster/k3d.yaml, then bootstrap
make down      # k3d cluster delete
make bootstrap # bootstrap only, against an existing cluster
make ca        # extract local root CA to .local/ca.crt
make verify    # scripts/verify.sh
make reset     # down + up
```

### `scripts/verify.sh` — the acceptance test

Exit non-zero on any failure:

- 3 nodes report `Ready`
- every pod in `kube-system`, `traefik`, `cert-manager` is `Running`/`Completed`
- the Gateway reports `Programmed=True` and its listeners `ResolvedRefs=True`
- `curl --resolve nothing.k3d.local:80:127.0.0.1 http://nothing.k3d.local/` returns a Traefik
  404 — proves host → k3d loadbalancer → Traefik routing end to end
- the same over HTTPS with `--cacert .local/ca.crt` completes the handshake without `-k`
- an image built locally, pushed to the k3d registry, pulls successfully in a test pod

## Part 1 acceptance criteria

- [ ] `make down && make up && make verify` passes from a clean machine state
- [ ] Under ~3 minutes on a laptop
- [ ] Passes with the machine's DNS resolver pointed at a black hole
- [ ] `/etc/hosts` is untouched unless `make hosts` was run explicitly
- [ ] Zero manual steps in the README beyond installing pinned tools
- [ ] `git status` clean afterwards — no generated kubeconfigs or CA files committed
- [ ] `make bootstrap` twice changes nothing

## Working with Claude Code on Part 1

Seed `CLAUDE.md` before starting:

```markdown
# k3d-lab

Local Kubernetes learning lab. Everything is code — no manual kubectl apply.

## Facts
- Cluster: k3d, 1 server + 2 agents, Kubernetes <version>
- k3s ships Traefik but we DISABLE it and install a pinned Traefik via Helm ourselves.
- Routing: Gateway API (HTTPRoute) is primary. A shared Gateway lives in the `gateway`
  namespace. Ingress is supported only as a compatibility toggle in the app chart.
- ingress-nginx is retired as of March 2026. Never suggest it.
- Local registry: `k3d-registry:5000` inside the cluster, `localhost:<port>` from the host.
  Image refs in values.yaml use the in-cluster name.

## Rules — DNS
- There is NO external DNS in this project. No nip.io, sslip.io, or similar.
- Never add /etc/hosts entries. Never suggest them as a fix.
- All HTTP checks use `scripts/curl.sh`, which wraps `curl --resolve <host>:<port>:127.0.0.1`
  and `--cacert .local/ca.crt`. Use it; do not hand-roll curl invocations.
- Never use `curl -k`. If TLS verification fails, that is a real bug — fix it.

## Rules — general
- The only kube context this repo touches is `k3d-<name>`. Never any other context.
- Every change must keep `make verify` passing. Run it before saying you're done.
- Chart versions in bootstrap.sh are pinned. Do not bump them without being asked.
```

Add a permission deny rule for `~/.kube/config` and `~/.aws` before starting. The agent has no
business reading credentials for clusters that aren't this one.

Good first prompt, in plan mode:

> Read cluster/k3d.yaml, bootstrap.sh, and scripts/verify.sh. I want verify.sh to also assert
> the Gateway's listeners have ResolvedRefs=True. Propose the change before making it.

---

# Part 2 — a Helm chart, done properly

## The demo app

Deliberately boring, but with enough surface area to exercise the chart. Go if you want the
distroless / non-root / tiny-image lesson; Python if you'd rather spend the time on Kubernetes.

| Path | Behaviour | Teaches |
|---|---|---|
| `GET /healthz` | 200 as soon as the process is up | Liveness — restart me if this fails |
| `GET /readyz` | 200 only after warm-up completes | Readiness — genuinely different semantics |
| `GET /metrics` | Prometheus exposition | ServiceMonitor, recording rules later |
| `GET /api/v1/info` | version, env, a ConfigMap value, and *whether* a secret mounted | Config wiring |
| `GET /api/v1/burn?ms=N` | Burns CPU | Gives the HPA something to react to |

Plus **graceful shutdown**: handle `SIGTERM`, stop reporting ready, drain in-flight requests,
then exit. Pair it with a `preStop` sleep in the chart. This is the difference between a rollout
that drops connections and one that doesn't, and it's observable with a load generator running
during `helm upgrade`.

`Dockerfile`: multi-stage, non-root user, no shell in the final layer if you went with Go.

## Chart requirements

### Structure

- `Chart.yaml` — `apiVersion: v2`. Understand the split: `version` is the *chart's* version,
  `appVersion` is the *app's*. They move independently. Add `kubeVersion` constraints.
- `_helpers.tpl` — `name`, `fullname`, `chart`, `labels`, `selectorLabels`, `serviceAccountName`.
  Selector labels are immutable after install; they must be a strict subset of labels and must
  never include anything version-dependent. This is the single most common way to make a chart
  un-upgradeable.
- Full `app.kubernetes.io/*` recommended label set.
- `NOTES.txt` printing a ready-to-paste `scripts/curl.sh` invocation — not a URL nobody can
  resolve.
- `.helmignore` excluding `tests/` and `ci/` from the packaged artifact.

### Templates

`deployment`, `service`, `serviceaccount`, `configmap`, `httproute`, `ingress` (compat),
`hpa`, `pdb`, `networkpolicy`, `servicemonitor`, and `templates/tests/test-connection.yaml`.

Everything optional is gated on `.Values.<x>.enabled`. Default to the *safe* state.

### Routing: HTTPRoute primary, Ingress optional

```yaml
route:
  # exactly one of these may be enabled — enforce it in values.schema.json
  httpRoute:
    enabled: true
    parentRefs:
      - name: shared-gateway
        namespace: gateway
    hostnames: [demo-api.k3d.local]
  ingress:
    enabled: false     # legacy compat only; the Ingress API is feature-frozen
```

Making these mutually exclusive is a genuinely good templating exercise: `fail` with a clear
message when both are on, and encode the constraint in `values.schema.json` too so it's caught
before templating. Try rendering an invalid combination and confirm the error is
comprehensible.

If you want to keep it lean, dropping the Ingress template entirely is a defensible call. The
argument for keeping it is that supporting two routing APIs during a migration window is
exactly what real charts are doing right now.

### Things that must be in there

- **`checksum/config` annotation** on the pod template, hashing the rendered ConfigMap. Without
  it, changing config does nothing until something else triggers a rollout. Classic bug.
- **`securityContext`**: `runAsNonRoot: true`, non-zero `runAsUser`, `readOnlyRootFilesystem: true`,
  `capabilities.drop: [ALL]`, `allowPrivilegeEscalation: false`, `seccompProfile: RuntimeDefault`.
  All overridable, all on by default.
- **Probes**: startup, liveness, readiness wired to the right endpoints, with every timing knob
  in values. Liveness must not point at `/readyz` — that turns a slow dependency into a restart
  loop.
- **Resources**: requests and limits both templated. Set memory limits. Leave a comment about
  the CPU-limits debate rather than pretending there's one right answer.
- **Rollout safety**: `maxUnavailable: 0`, a PDB, `terminationGracePeriodSeconds` exceeding the
  preStop sleep plus drain time.
- **Spreading**: `topologySpreadConstraints` across nodes, plus `affinity` / `nodeSelector`
  passthrough.
- **`values.schema.json`** — the most-skipped item here and one of the most useful. Typos fail
  at `helm template` time with a clear message instead of producing subtly wrong YAML.

### Gotchas worth hitting on purpose

- `.Capabilities.APIVersions.Has` works at install time but not under a bare `helm template`.
  CI validating rendered output needs `--api-versions` passed explicitly, or the conditional
  ServiceMonitor and HTTPRoute silently vanish from the tested manifests. With Gateway API this
  bites harder than it used to, because the CRDs are cluster-scoped prerequisites.
- `kubeconform` needs the Gateway API and Prometheus Operator schemas fed to it via
  `-schema-location`. Vendor them; don't fetch at CI time.
- A cross-namespace `HTTPRoute` attaches only if the Gateway's `allowedRoutes` permits it. When
  a route silently doesn't take effect, check the route's status conditions first — Gateway API
  reports this well, which is one of its genuine improvements over Ingress.
- Never put real secrets in `values.yaml`. Template a `Secret` from values for local dev, but
  structure it so an external secret can be referenced by name instead. Get the shape right now;
  it's painful to retrofit.
- `helm upgrade --install --atomic --timeout` is the pattern worth muscle-memorising.

### Testing — the part that makes the rest safe

| Tool | Catches |
|---|---|
| `helm lint` + `ct lint` | Chart structure, metadata, version bumps |
| `helm unittest` | Template logic: does `httpRoute.enabled=false` actually omit the route? |
| `kubeconform --strict` | Rendered manifests valid for the target k8s version + CRDs |
| `kube-score` / `polaris` | Missing probes, limits, weak securityContext |
| `helm test` | The deployed thing actually answers HTTP |
| `ct install` | Full install/upgrade cycle against the real k3d cluster |

`charts/demo-api/ci/` holds the value sets `ct` exercises: defaults, httproute-enabled,
ingress-compat, HPA-enabled, and a maximal "everything on" set.

`templates/tests/test-connection.yaml` runs *inside* the cluster, so it hits the Service by its
cluster DNS name directly — no `--resolve` needed there. Keep the through-the-Gateway check in
`verify.sh` on the host side. Two different things being tested; don't conflate them.

Aim for unit tests asserting *behaviour*, not string equality on rendered YAML. "The deployment
has no `runAsUser: 0`" survives refactoring; "line 34 equals X" does not.

### Makefile additions

```
make build     # docker build + push to the k3d registry
make lint      # helm lint, ct lint, kubeconform, kube-score
make unit      # helm unittest
make install   # helm upgrade --install --atomic
make smoke     # helm test + host-side check through the Gateway
make ci        # lint + unit + install + smoke  ← the loop that matters
```

## Part 2 acceptance criteria

- [ ] `make ci` passes from a clean cluster
- [ ] `helm template` with default values passes `kubeconform --strict` including Gateway API schemas
- [ ] Unit tests cover every `enabled` toggle in both states
- [ ] Enabling both `httpRoute` and `ingress` fails with a readable error, not weird YAML
- [ ] The app is reachable over HTTPS through the Gateway with full cert verification (no `-k`)
- [ ] Changing a ConfigMap value and re-running `make install` causes a pod rollout
- [ ] `helm upgrade` then `helm rollback` both succeed, app stays reachable
- [ ] With a load generator running, a rollout produces **zero** failed requests
- [ ] `/api/v1/burn` under load causes the HPA to scale up, then back down
- [ ] `git grep` finds no secrets, no `:latest`, no hardcoded namespace, no `nip.io`, no `-k`

## Working with Claude Code on Part 2

This is where the agent genuinely shines — Helm templating is fiddly, well-documented, and
instantly verifiable. Patterns worth using:

- **Write the test first, then ask for the template.** "Here's a helm-unittest spec asserting
  the HTTPRoute renders only when `route.httpRoute.enabled=true`. Make it pass." Now the agent
  has a target and you have a check.
- **Watch for stale training data on Gateway API.** It moved fast and there's a lot of outdated
  `v1alpha2` and `v1beta1` material out there. Pin the version in `CLAUDE.md`, and treat any
  generated `apiVersion` as suspect until `kubeconform` agrees.
- **Make it justify defaults.** "Why `maxUnavailable: 0` here, and what breaks if the PDB is
  stricter than the deployment's surge capacity?" Answers that don't survive scrutiny are the
  tell that it pattern-matched rather than reasoned.
- **Use it as a reviewer, not just an author.** "Read this chart as a PR from a junior engineer.
  List everything that breaks on upgrade." It's good at this, and it's a lower-trust way to get
  value.
- **Never accept a chart change without running `make ci`.** Rendered YAML looks plausible
  almost regardless of correctness — exactly the failure mode where confident and wrong overlap.

---

# Part 3 — candidates

Deliberately left open. Each builds directly on Parts 1 and 2.

**A. GitOps.** Argo CD installed by the bootstrap, app-of-apps pattern, the chart pulled from
the local OCI registry. Delete a Deployment by hand and watch it come back. The leap from "I ran
a script" to "the cluster reconciles toward a declared state" is the biggest one left here.

**B. Supply chain / CI.** GitHub Actions: lint → unit → spin up k3d in the runner → `ct install`
→ package → push OCI → sign with cosign, generate an SBOM. Turns `make ci` into a real gate, and
k3d-in-CI is a useful trick to own.

**C. Observability & SLOs.** kube-prometheus-stack, the chart's ServiceMonitor finally doing
something, recording rules, multi-window burn-rate alerts, Grafana dashboards as code. Closest
to day-job SRE work. Traefik's own metrics come along for free here.

**D. Policy as code.** Kyverno or Gatekeeper enforcing at admission exactly what the chart
already sets — non-root, no `:latest`, resources required. Nicely circular: the chart passes
because Part 2 was done properly, provable by trying to deploy something sloppy.

**E. Progressive delivery.** Traffic splitting is native to Gateway API — weighted `backendRefs`
across two Services, no service mesh required. Either drive it by hand first to see the
mechanism, then automate with Argo Rollouts and Prometheus-based analysis. Depends on C.
