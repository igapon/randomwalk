import importlib
import pytest
from fastapi.testclient import TestClient


@pytest.fixture()
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("LEADERBOARD_DB", str(tmp_path / "lb.sqlite"))
    import app as app_module
    importlib.reload(app_module)
    return TestClient(app_module.app)


def submit(client, uid="user-0001", pseudo="iaro", km=10.0):
    return client.post("/v1/score",
                       json={"user_id": uid, "pseudo": pseudo, "total_km": km})


def test_submit_and_rank(client):
    assert submit(client, "a" * 8, "alice", 5.0).json()["rank"] == 1
    assert submit(client, "b" * 8, "bob", 9.0).json()["rank"] == 1
    r = client.get("/v1/leaderboard", params={"user_id": "a" * 8}).json()
    assert [e["pseudo"] for e in r["top"]] == ["bob", "alice"]
    assert r["me"]["rank"] == 2


def test_score_never_decreases(client):
    submit(client, "c" * 8, "carol", 50.0)
    assert submit(client, "c" * 8, "carol", 10.0).json()["total_km"] == 50.0


def test_daily_increase_is_capped(client):
    submit(client, "d" * 8, "dave", 0.0)
    r = submit(client, "d" * 8, "dave", 10_000.0)
    assert r.json()["total_km"] <= 301.0  # ~300 km max sur la fenêtre minimale


def test_validation(client):
    assert client.post("/v1/score", json={"user_id": "x", "pseudo": "", "total_km": -1}).status_code == 422


def test_me_absent(client):
    assert client.get("/v1/leaderboard").json()["me"] is None
