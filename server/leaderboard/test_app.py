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
    assert [e["user_id"] for e in r["top"]] == ["b" * 8, "a" * 8]
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


def test_top_entries_include_user_id_to_disambiguate_ties(client):
    """top[] carries user_id so a client can match "me" by id, not by rank
    (which is ambiguous whenever two or more rows tie — e.g. several users
    who have never submitted a real distance all sitting at 0 km)."""
    submit(client, "a" * 8, "alice", 100.0)
    submit(client, "b" * 8, "bob", 100.0)
    r = client.get("/v1/leaderboard").json()
    ids = {e["user_id"] for e in r["top"]}
    assert ids == {"a" * 8, "b" * 8}
    assert all(e["rank"] == 1 for e in r["top"])
    # pseudo/total_km/rank remain present alongside user_id.
    for e in r["top"]:
        assert set(e.keys()) == {"user_id", "pseudo", "total_km", "rank"}


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


def test_schema_migration_from_old_schema(tmp_path, monkeypatch):
    """Test migration from old schema (without day/day_base_km columns)."""
    import sqlite3

    # Create a DB with the OLD schema
    old_db_path = tmp_path / "old_lb.sqlite"
    conn = sqlite3.connect(str(old_db_path))
    conn.execute(
        "CREATE TABLE scores("
        " user_id TEXT PRIMARY KEY, pseudo TEXT NOT NULL,"
        " total_km REAL NOT NULL, updated_at REAL NOT NULL)")
    conn.execute(
        "INSERT INTO scores(user_id, pseudo, total_km, updated_at)"
        " VALUES(?, ?, ?, ?)",
        ("gggggggg", "grace", 150.0, 1000000.0))
    conn.commit()
    conn.close()

    # Point app to old DB and reload
    monkeypatch.setenv("LEADERBOARD_DB", str(old_db_path))
    import app as app_module
    importlib.reload(app_module)
    client = TestClient(app_module.app)

    # Both endpoints should work (old row accessible, schema migrated)
    r = client.get("/v1/leaderboard", params={"user_id": "gggggggg"}).json()
    assert r["me"] is not None
    assert r["me"]["pseudo"] == "grace"
    assert r["me"]["total_km"] == 150.0
    assert r["me"]["rank"] == 1

    # Verify the row can be updated (should handle NULL day as "not today")
    r = submit(client, "gggggggg", "grace", 160.0)
    assert r.json()["total_km"] == 160.0  # Should accept the increase
