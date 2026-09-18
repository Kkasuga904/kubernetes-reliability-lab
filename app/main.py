"""Kubernetes Reliability Lab - demo app.

Purpose: expose Kubernetes observable behavior (probes, shutdown, load),
not business logic. Keep it tiny.
"""

import asyncio
import logging
import os
import signal
import threading
import time

from contextlib import asynccontextmanager

from fastapi import FastAPI, Query, Response

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("reliability-lab")


@asynccontextmanager
async def lifespan(app: FastAPI):  # noqa: ARG001
    yield
    log.warning("Shutdown complete - application stopped")


app = FastAPI(title="kubernetes-reliability-lab", lifespan=lifespan)

# ---- mutable failure-injection state (in-memory, per Pod) ----
state = {
    "readiness_fail": False,   # when True, /ready returns 500 (no restart expected)
    "liveness_fail": False,    # when True, /health returns 500 (restart expected)
    "slow_requests": 0,
}

# Slow-start support for the startupProbe experiment.
# STARTUP_DELAY_SECONDS=N makes /health and /ready return 500 for N seconds
# after process start, simulating slow initialization.
STARTUP_DELAY_SECONDS = float(os.getenv("STARTUP_DELAY_SECONDS", "0"))
_boot_time = time.monotonic()

# Graceful-shutdown observability.
_shutdown_started = threading.Event()


def _startup_complete() -> bool:
    return (time.monotonic() - _boot_time) >= STARTUP_DELAY_SECONDS


def _handle_sigterm(signum, frame):  # noqa: ARG001
    # Uvicorn also handles SIGTERM; this hook exists so the shutdown
    # is visible in `kubectl logs` as plain evidence.
    log.warning("Received SIGTERM - starting graceful shutdown (in-flight requests drain first)")
    _shutdown_started.set()


signal.signal(signal.SIGTERM, _handle_sigterm)


@app.get("/")
def root():
    return {
        "service": "kubernetes-reliability-lab",
        "endpoints": ["/", "/health", "/ready", "/cpu", "/slow", "/state"],
    }


def _probe_status(fail_flag: str):
    if not _startup_complete():
        return Response(
            content=f"STARTING: still initializing ({STARTUP_DELAY_SECONDS}s delay)",
            status_code=500,
            media_type="text/plain",
        )
    if state[fail_flag]:
        return Response(
            content=f"FAIL injected: {fail_flag}=True",
            status_code=500,
            media_type="text/plain",
        )
    return {"status": "ok"}


@app.get("/health")
def health():
    """Liveness endpoint. Failing this triggers container restarts."""
    result = _probe_status("liveness_fail")
    if isinstance(result, Response):
        log.info("liveness probe FAILED (500)")
    return result


@app.get("/ready")
def ready():
    """Readiness endpoint. Failing this removes the Pod from Endpoints (no restart)."""
    result = _probe_status("readiness_fail")
    if isinstance(result, Response):
        log.info("readiness probe FAILED (500)")
    return result


@app.get("/cpu")
def cpu(milliseconds: int = Query(default=200, ge=0, le=10000)):
    """Burn CPU for ~N milliseconds to drive HPA CPU utilization.

    Single-threaded busy loop; intentionally simple so that
    `requests.cpu` vs actual usage is easy to reason about.
    """
    deadline = time.monotonic() + milliseconds / 1000.0
    x = 0
    while time.monotonic() < deadline:
        x += 1
    return {"status": "ok", "burned_ms": milliseconds, "iterations": x}


@app.get("/slow")
async def slow(duration: int = Query(default=10, ge=0, le=120)):
    """Sleep N seconds. Used to observe in-flight requests during rolling update / SIGTERM."""
    log.info(f"/slow started duration={duration}s")
    await asyncio.sleep(duration)
    log.info(f"/slow finished duration={duration}s")
    return {"status": "ok", "slept_s": duration}


@app.get("/state")
def get_state():
    return {
        **state,
        "startup_delay_seconds": STARTUP_DELAY_SECONDS,
        "startup_complete": _startup_complete(),
        "uptime_seconds": round(time.monotonic() - _boot_time, 1),
    }


@app.post("/admin/fail-readiness")
def fail_readiness(fail: bool = True):
    """Toggle readiness failure safely: POST /admin/fail-readiness?fail=true|false"""
    state["readiness_fail"] = fail
    log.warning(f"readiness_fail set to {fail}")
    return {"readiness_fail": fail}


@app.post("/admin/fail-liveness")
def fail_liveness(fail: bool = True):
    """Toggle liveness failure safely: POST /admin/fail-liveness?fail=true|false"""
    state["liveness_fail"] = fail
    log.warning(f"liveness_fail set to {fail}")
    return {"liveness_fail": fail}
