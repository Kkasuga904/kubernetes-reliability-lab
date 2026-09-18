"""Unit tests for the reliability-lab demo app (no cluster needed)."""

from fastapi.testclient import TestClient

from main import app, state

client = TestClient(app)


def setup_function(_):
    state["readiness_fail"] = False
    state["liveness_fail"] = False


def test_root():
    r = client.get("/")
    assert r.status_code == 200
    assert "health" in str(r.json())


def test_health_ok():
    assert client.get("/health").status_code == 200


def test_ready_ok():
    assert client.get("/ready").status_code == 200


def test_readiness_failure_does_not_affect_liveness():
    client.post("/admin/fail-readiness?fail=true")
    assert client.get("/ready").status_code == 500
    # liveness stays healthy -> models "Running but not Ready"
    assert client.get("/health").status_code == 200


def test_liveness_failure():
    client.post("/admin/fail-liveness?fail=true")
    assert client.get("/health").status_code == 500


def test_cpu_endpoint():
    r = client.get("/cpu?milliseconds=50")
    assert r.status_code == 200
    assert r.json()["burned_ms"] == 50
