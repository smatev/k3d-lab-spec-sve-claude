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

## What `make up` builds

| | |
|---|---|
| Cluster | k3d, 1 server + 2 agents, k3s v1.36.3, bundled Traefik disabled |
| Registry | `localhost:5000` from the host, `k3d-registry:5000` inside the cluster |
| Routing | Gateway API v1.6.1 (standard channel), Traefik v3.7.11 |
| Gateway | `shared-gateway` in the `gateway` namespace, open to routes from all namespaces |
| TLS | cert-manager, a self-signed root CA, `ClusterIssuer/k3d-lab-ca-issuer` |

The Traefik dashboard is enabled but not exposed. Reach it with `make dashboard`.

## Two things worth knowing

**The registry has two names.** `localhost:5000` from the host, `k3d-registry:5000` from
inside the cluster. Image references in Helm values must use the in-cluster one.
`make verify` exercises both directions on purpose.

**Gateway listeners use ports 8000 and 8443**, not 80 and 443. Traefik binds a listener
to the entrypoint with the matching port number, and the Service maps 80→8000 and
443→8443. A listener on port 80 resolves to no entrypoint and silently routes nothing.

## Layout

```
cluster/k3d.yaml           declarative cluster definition — the whole create invocation
cluster/bootstrap/         bootstrap.sh, pinned values files, Gateway and CA manifests
app/                       the demo service and its Dockerfile
charts/demo-api/           the chart. ci/ holds the value sets chart-testing installs,
                           tests/ the helm-unittest specs — both excluded by .helmignore
schemas/crds/              vendored CRDs the lab validates against but does not install
etc/                       chart-testing's schema and yamllint config, vendored
scripts/curl.sh            the only way this repo makes an HTTP request
scripts/verify.sh          the acceptance test for the cluster
scripts/smoke.sh           the acceptance test for an installed release
.local/                    generated (CA cert, CRD schemas). Gitignored, never committed.
```

## Status

Parts 1 and 2 are done: the cluster is code and the chart is built, linted, unit-tested
and installed by `make ci`. Part 3 is open — see [k3d-lab-spec.md](k3d-lab-spec.md).
