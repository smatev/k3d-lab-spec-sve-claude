# k3d-lab

A reproducible local Kubernetes lab, entirely as code. Traefik with Gateway API as the
routing surface, real TLS from an in-cluster CA, and no external DNS anywhere.

The point is not the cluster. It's `make verify` — one command that says in ~30 seconds
whether the thing still works.

## Requirements

Docker, and the pinned toolchain in [.tool-versions](.tool-versions). With
[mise](https://mise.jdx.dev):

```bash
make tools     # mise install + helm plugins
make doctor    # confirm every tool is present at the pinned version
```

Nothing else. No DNS setup, no `/etc/hosts` edits, no wildcard resolver service.

## Use

```bash
make up        # create the cluster, bootstrap it, extract the CA
make verify    # the acceptance test — exits non-zero on any failure
make down      # delete the cluster and every generated file
```

`make reset` is `down` then `up`. `make bootstrap` re-runs the bootstrap against an
existing cluster, and `make idempotent` proves that doing so changes nothing — it
snapshots pod identities and resource generations, re-runs the bootstrap, and diffs.

(Helm release revisions *do* increment on each bootstrap. That is `upgrade --install`
working as intended, and it is why the script converges rather than drifts. No deployed
object changes, which is the property that actually matters.)

`make` on its own lists every target.

## The chart

`charts/demo-api` is the application half of the lab: a small FastAPI service with
genuinely different `/healthz` and `/readyz` semantics, graceful shutdown, Prometheus
metrics, and a `/api/v1/burn` endpoint that exists to give the HPA something to react to.

```bash
make ci        # lint + unit + build + install + smoke — the loop that matters
```

Individually:

| | |
|---|---|
| `make build` | docker build, push to `localhost:5000`, tagged from `appVersion` |
| `make lint` | `helm lint`, `ct lint`, `kubeconform --strict`, `kube-score` — over the defaults *and* every `ci/` value set |
| `make unit` | `helm unittest` — template logic, no cluster needed |
| `make install` | `helm upgrade --install --atomic --timeout 5m` |
| `make smoke` | `helm test` in-cluster, plus a host-side check through the Gateway |
| `make ct-install` | install every `ci/` value set into a throwaway namespace and `helm test` it |
| `make rollout` | a ConfigMap change rolls the pods; a rollout under load drops zero requests; rollback works |
| `make hpa` | `/api/v1/burn` scales the HPA up, and it scales back down afterwards |

`make ci` includes `build` — the spec lists it as `lint + unit + install + smoke`, but on
a clean cluster `install` has nothing to pull until the image has been pushed.

`RELEASE` and `NAMESPACE` are overridable, so a second release can be installed alongside
the first: `make install RELEASE=demo-api-b NAMESPACE=demo-api-b`.

## GitOps

From Part 3 on, the cluster's desired state is what Git says — not what a script last
did. `make bootstrap` installs Gitea and Argo CD and applies exactly **one** Application,
the root app-of-apps. Every workload after that arrives because it was committed.

```bash
make gitops        # publish image + chart + repo, then wait for Argo CD to converge
make gitops-test   # delete/scale/edit by hand and prove Argo CD undoes all three
```

| | |
|---|---|
| `make chart-push` | `helm package` + push to the OCI registry — the release step |
| `make gitops-push` | publish `HEAD` to the in-cluster Gitea (pushes commits, not your working tree) |
| `make argocd-ui` | port-forward the Argo CD UI; `make argocd-password` prints the admin password |
| `make gitea-ui` | port-forward Gitea (user `lab`) |

**The Git server is in the cluster.** Not GitHub: this lab has no DNS contract, commits
no credentials, and must come up on a machine with no account anywhere. Gitea runs on
sqlite in a single pod, and `make down` destroys it — it is a publishing target, not
where work happens.

**Git holds the declaration, the registry holds the artifact.** `gitops/apps/` contains
Application manifests; the chart itself is pulled from `k3d-registry:5000/charts`.
Shipping a change is therefore two steps — `make chart-push`, then a commit pointing
`targetRevision` at the new version — which is exactly the record a `helm upgrade`
does not leave.

Argo CD manages the demo app into `demo-api-gitops`, separately from the Helm-managed
release in `demo-api`. Both run at once, on different hostnames, which is also a second
exercise of the shared Gateway's cross-namespace routing.

## Reaching the cluster

Everything binds to `127.0.0.1:80` and `127.0.0.1:443`. The only open question is how a
*hostname* gets attached to a request, since routing rules and TLS certificates both key
off one. The answer is [scripts/curl.sh](scripts/curl.sh):

```bash
./scripts/curl.sh https://demo-api.k3d.local/api/v1/info
```

It wraps `curl --resolve <host>:<port>:127.0.0.1 --cacert .local/ca.crt`. No DNS lookup
happens, and unlike `-H "Host: ..."` it sets TLS SNI correctly — which matters as soon as
cert-manager is issuing per-host certificates. It refuses `-k`: a TLS failure here is a
real bug, not something to skip past.

Port 80 redirects to 443, so plain HTTP answers `301` rather than reaching any route.

## Reaching the UIs from another machine

`make argocd-ui`, `make gitea-ui` and `make dashboard` bind `127.0.0.1`. That is correct
for a lab on a laptop and useless for a lab on a remote box: a browser elsewhere cannot
reach another machine's loopback. `make remote-ui` is the remote case.

```bash
make remote-ui           # install + start, idempotent
make remote-ui-status    # units, listeners, and what actually answers
make remote-ui-stop      # stop, still enabled at next boot
make remote-ui-uninstall # stop, disable, remove
```

It exposes Argo CD on `:8080` and Gitea on `:8081`, bound to `0.0.0.0`, as systemd
`--user` units with `Restart=always`, plus `loginctl enable-linger` so they start at boot
and outlive your SSH session. The restart policy is not paranoia: `kubectl port-forward`
dies when the pod behind it restarts, and these pods restart whenever the box does.

Two ports mean both UIs are reachable at once. Change which ports with
`ARGOCD_UI_PORT` / `GITEA_UI_PORT`, then re-run `make remote-ui`.

**This exposes Argo CD, which holds cluster-admin over the lab, and Gitea, whose password
is in this repo.** Scope your firewall rule to your own address, and do not do this on a
box that holds anything you care about.

**Two prerequisites, and only one of them is in this repo.** The forward must bind
`0.0.0.0` — that is what this script does. The port must also be open in the host's
firewall, which it cannot do or even detect. The symptoms are distinguishable, so use
them:

| Browser says | Meaning |
|---|---|
| `ERR_CONNECTION_TIMED_OUT` | The firewall is dropping the packets. Nothing on the box will fix it. |
| `ERR_CONNECTION_REFUSED` | The port is open; nothing is listening. `make remote-ui-status`. |
| The page loads | Both are satisfied. |

On EC2 that firewall is the instance's security group, and there is no `aws` CLI on the
box — it is a console change.

**These ports collide with two of the localhost targets.** `make argocd-ui` wants 8081,
which is Gitea's here, and `make dashboard` wants 8080, which is Argo CD's. With the
permanent forwards running, both fail to bind. Use `make remote-ui-stop` first, or give
the one-off a different port.

The app hostnames are a different matter and are **not** reachable this way. There is no
DNS, so `https://demo-api.k3d.local/` from a browser resolves nowhere, and pointing one at
the host's address sends `Host: <ip>`, which matches no HTTPRoute and gets Traefik's 404.
That is what [scripts/curl.sh](scripts/curl.sh) is for. These forwards work precisely
because they bypass the Gateway.

## What `make up` builds

| | |
|---|---|
| Cluster | k3d, 1 server + 2 agents, k3s v1.36.3, bundled Traefik disabled |
| Registry | `localhost:5000` from the host, `k3d-registry:5000` inside the cluster |
| Routing | Gateway API v1.6.1 (standard channel), Traefik v3.7.11 |
| Gateway | `shared-gateway` in the `gateway` namespace, open to routes from all namespaces |
| TLS | cert-manager, a self-signed root CA, `ClusterIssuer/k3d-lab-ca-issuer` |
| Git | Gitea (chart 12.7.0) in-cluster, sqlite, one pod |
| GitOps | Argo CD (chart 10.4.0, v3.5.1) plus one root Application and nothing else |

The Traefik dashboard is enabled but not exposed. Reach it with `make dashboard`.

## Two things worth knowing

**The registry has two names.** `localhost:5000` from the host, `k3d-registry:5000` from
inside the cluster. Image references in Helm values must use the in-cluster one.
`make verify` exercises both directions on purpose.

**Gateway listeners use ports 8000 and 8443**, not 80 and 443. Traefik binds a listener
to the entrypoint with the matching port number, and the Service maps 80→8000 and
443→8443. A listener on port 80 resolves to no entrypoint and silently routes nothing.

**`insecure` and "plain HTTP" are different things.** Pointing Argo CD at the k3d
registry needs `insecureOCIForceHttp: "true"`. The obvious-looking `insecure: "true"`
means *skip certificate verification*, so Argo CD still dials HTTPS and fails with
`server gave HTTP response to HTTPS client` — and setting both is worse than setting
neither, because helm ignores `--plain-http` whenever `--insecure-skip-tls-verify` is
also present.

## Layout

```
cluster/k3d.yaml           declarative cluster definition — the whole create invocation
cluster/bootstrap/         bootstrap.sh, pinned values files, Gateway and CA manifests
app/                       the demo service and its Dockerfile
charts/demo-api/           the chart. ci/ holds the value sets chart-testing installs,
                           tests/ the helm-unittest specs — both excluded by .helmignore
schemas/crds/              vendored CRDs the lab validates against but does not install
etc/                       chart-testing's schema and yamllint config, vendored
cluster/bootstrap/gitops/  the AppProject, the two UI routes, and the one root Application
gitops/apps/               child Applications — what the root app watches, in Git
scripts/curl.sh            the only way this repo makes an HTTP request
scripts/verify.sh          the acceptance test for the cluster
scripts/smoke.sh           the acceptance test for an installed release
scripts/gitops-test.sh     the acceptance test for reconciliation
scripts/remote-ui.sh       expose the UIs on 0.0.0.0 permanently — about the host, not
                           the cluster; the only script here that touches systemd
.local/                    generated (CA cert, CRD schemas). Gitignored, never committed.
```

## Status

Parts 1, 2 and 3 are done: the cluster is code, the chart is built, linted, unit-tested
and installed by `make ci`, and Argo CD reconciles the whole thing from an in-cluster
Git server. `make verify`, `make ci`, `make ct-install`, `make rollout`, `make hpa`,
`make gitops` and `make gitops-test` are all green.

Part 3 took candidate **A (GitOps)** from [k3d-lab-spec.md](k3d-lab-spec.md); B through
E — supply chain/CI, observability, policy, progressive delivery — are still open.
