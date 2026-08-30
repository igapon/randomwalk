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
    # Per-day budget: 300 km, so 0 + 300 = 300 exactly
    assert r.json()["total_km"] == 300.0


def test_validation(client):
    assert client.post("/v1/score", json={"user_id": "x", "pseudo": "", "total_km": -1}).status_code == 422


def test_me_absent(client):
    assert client.get("/v1/leaderboard").json()["me"] is None


def test_tied_users_consistent_rank(client):
    """Two users with equal total_km both get rank 1, ranking is competition-style."""
    r1 = submit(client, "a" * 8, "alice", 100.0)
    r2 = submit(client, "b" * 8, "bob", 100.0)
    # Both should get rank 1 (competition ranking: no one has > 100 km)
    assert r1.json()["rank"] == 1
    assert r2.json()["rank"] == 1
    # Get leaderboard and verify both appear with rank 1
    lb_alice = client.get("/v1/leaderboard", params={"user_id": "a" * 8}).json()
    lb_bob = client.get("/v1/leaderboard", params={"user_id": "b" * 8}).json()
    assert lb_alice["me"]["rank"] == 1
    assert lb_bob["me"]["rank"] == 1


def test_rapid_submissions_same_day_capped(client):
    """Multiple rapid submissions in same day cannot exceed initial + 300."""
    submit(client, "e" * 8, "eve", 0.0)
    # Rapid submission 1: try 100 km
    r1 = submit(client, "e" * 8, "eve", 100.0)
    assert r1.json()["total_km"] == 100.0
    # Rapid submission 2: try 350 (exceeds budget from day_base_km 0), should cap at 300
    r2 = submit(client, "e" * 8, "eve", 350.0)
    assert r2.json()["total_km"] == 300.0
    # Rapid submission 3: try more, should stay at 300 (already at cap)
    r3 = submit(client, "e" * 8, "eve", 400.0)
    assert r3.json()["total_km"] == 300.0


def test_plausible_daily_increase_accepted(client):
    """A plausible increase below 300 in a day is accepted as-is."""
    submit(client, "f" * 8, "frank", 0.0)
    r = submit(client, "f" * 8, "frank", 42.0)
    assert r.json()["total_km"] == 42.0
