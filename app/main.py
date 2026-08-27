"""demo-api — a deliberately boring service with enough surface area to exercise a chart.

The interesting parts are not the endpoints. They are:

  * /healthz and /readyz having genuinely different semantics, so liveness and readiness
    probes in the chart mean two different things rather than one thing twice.
  * graceful shutdown: on SIGTERM, stop reporting ready *first*, then drain. Paired with
    a preStop sleep in the chart, that ordering is the difference between a rollout that
    drops connections and one that doesn't.
"""

from __future__ import annotations

import asyncio
import os
import socket
import time
from pathlib import Path

import uvicorn
from fastapi import FastAPI, Query, Request, Response
from fastapi.responses import JSONResponse, PlainTextResponse
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
)

APP_VERSION = os.environ.get("APP_VERSION", "dev")
APP_ENV = os.environ.get("APP_ENV", "local")
# Injected from the ConfigMap. Read once at import: an env var cannot change under a
# running process, which is exactly why the chart needs a checksum/config annotation to
# force a rollout when the ConfigMap changes.
APP_MESSAGE = os.environ.get("APP_MESSAGE", "<unset>")
SECRET_PATH = Path(os.environ.get("SECRET_PATH", "/etc/demo-api/secret/token"))
WARMUP_SECONDS = float(os.environ.get("WARMUP_SECONDS", "5"))
PORT = int(os.environ.get("PORT", "8000"))

HOSTNAME = socket.gethostname()

# --- metrics ---------------------------------------------------------------

REQUESTS = Counter(
    "demo_api_requests_total",
    "Total HTTP requests.",
    ["method", "path", "status"],
)
LATENCY = Histogram(
    "demo_api_request_duration_seconds",
    "HTTP request duration.",
    ["method", "path"],
)
READY = Gauge(
    "demo_api_ready",
    "1 when the service reports ready, 0 otherwise.",
)
BURNED = Counter(
    "demo_api_burn_milliseconds_total",
    "Cumulative CPU time deliberately burned by /api/v1/burn.",
)


class State:
    """Warm-up and shutdown are separate flags on purpose.

    `warm` goes true once, after start-up work finishes. `draining` goes true on SIGTERM
    and never goes back. Readiness is the conjunction, so a terminating pod is never
    ready again even though it keeps serving in-flight requests.
    """

    def __init__(self) -> None:
        self.warm = False
        self.draining = False

    @property
    def ready(self) -> bool:
        return self.warm and not self.draining


state = State()


async def _warm_up() -> None:
    await asyncio.sleep(WARMUP_SECONDS)
    state.warm = True
    READY.set(1)


async def lifespan(app: FastAPI):
    task = asyncio.create_task(_warm_up())
    READY.set(0)
    yield
    task.cancel()


app = FastAPI(title="demo-api", version=APP_VERSION, lifespan=lifespan)


@app.middleware("http")
async def record_metrics(request: Request, call_next):
    # Label on the route template, never the raw path — labelling on raw paths is how
    # you give Prometheus unbounded cardinality.
    route = request.scope.get("route")
    path = getattr(route, "path", "other")
    started = time.perf_counter()
    response = await call_next(request)
    LATENCY.labels(request.method, path).observe(time.perf_counter() - started)
    REQUESTS.labels(request.method, path, str(response.status_code)).inc()
    return response


@app.get("/healthz")
async def healthz() -> Response:
    """Liveness: 200 as soon as the process is up.

    This must NOT depend on warm-up or on any downstream. A liveness probe that fails
    when a dependency is slow turns a slow dependency into a restart loop.
    """
    return PlainTextResponse("ok")


@app.get("/readyz")
async def readyz() -> Response:
    """Readiness: 200 only once warm, and never again once draining."""
    if state.ready:
        return PlainTextResponse("ready")
    reason = "draining" if state.draining else "warming up"
    return PlainTextResponse(reason, status_code=503)


@app.get("/metrics")
async def metrics() -> Response:
    READY.set(1 if state.ready else 0)
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.get("/api/v1/info")
async def info() -> Response:
    return JSONResponse(
        {
            "version": APP_VERSION,
            "env": APP_ENV,
            "message": APP_MESSAGE,
            # Whether, never what. The value never leaves the pod.
            "secret_mounted": SECRET_PATH.is_file(),
            "hostname": HOSTNAME,
            "ready": state.ready,
        }
    )


@app.get("/api/v1/burn")
async def burn(ms: int = Query(default=100, ge=0, le=10_000)) -> Response:
    """Burn CPU for `ms` milliseconds, to give the HPA something to react to.

    Yields to the event loop between slices so /healthz stays answerable while burning —
    otherwise a load test aimed at this endpoint would trip the liveness probe and prove
    nothing except that we wrote a bad endpoint.
    """
    deadline = time.perf_counter() + ms / 1000.0
    while time.perf_counter() < deadline:
        for _ in range(20_000):
            pass
        await asyncio.sleep(0)
    BURNED.inc(ms)
    return JSONResponse({"burned_ms": ms, "hostname": HOSTNAME})


class GracefulServer(uvicorn.Server):
    """Flip readiness off *before* uvicorn starts refusing connections.

    Kubernetes removes a terminating pod from Endpoints in parallel with running preStop,
    so there is always a window where traffic still arrives. Reporting not-ready at the
    very start of shutdown shortens that window instead of relying on preStop alone.
    """

    def handle_exit(self, sig, frame) -> None:
        state.draining = True
        READY.set(0)
        super().handle_exit(sig, frame)


if __name__ == "__main__":
    config = uvicorn.Config(
        app,
        host="0.0.0.0",  # noqa: S104 - binding all interfaces is correct inside a pod
        port=PORT,
        access_log=False,
        # Must exceed the chart's preStop sleep plus expected in-flight request time, and
        # terminationGracePeriodSeconds must in turn exceed this.
        timeout_graceful_shutdown=20,
    )
    GracefulServer(config).run()
