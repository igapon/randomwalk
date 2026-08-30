"""RandomWalk primitive leaderboard — anonymous ids, SQLite, plausibility cap."""
import os
import sqlite3
import threading
import time

from fastapi import FastAPI
from pydantic import BaseModel, Field

MAX_KM_PER_DAY = 300.0
MIN_WINDOW_DAYS = 1 / 24  # tolère une petite hausse même juste après un envoi

app = FastAPI()
_lock = threading.Lock()


def _db() -> sqlite3.Connection:
    conn = sqlite3.connect(os.environ.get("LEADERBOARD_DB", "/data/leaderboard.sqlite"))
    conn.execute(
        "CREATE TABLE IF NOT EXISTS scores("
        " user_id TEXT PRIMARY KEY, pseudo TEXT NOT NULL,"
        " total_km REAL NOT NULL, updated_at REAL NOT NULL)")
    return conn


class Score(BaseModel):
    user_id: str = Field(min_length=8, max_length=64)
    pseudo: str = Field(min_length=1, max_length=24)
    total_km: float = Field(ge=0, le=1_000_000)


def _rank(conn: sqlite3.Connection, km: float) -> int:
    return conn.execute(
        "SELECT COUNT(*) + 1 FROM scores WHERE total_km > ?", (km,)).fetchone()[0]


@app.post("/v1/score")
def submit_score(s: Score):
    now = time.time()
    with _lock, _db() as conn:
        row = conn.execute(
            "SELECT total_km, updated_at FROM scores WHERE user_id = ?",
            (s.user_id,)).fetchone()
        km = s.total_km
        if row:
            prev_km, prev_at = row
            window_days = max((now - prev_at) / 86400.0, MIN_WINDOW_DAYS)
            km = min(km, prev_km + MAX_KM_PER_DAY * window_days)
            km = max(km, prev_km)
        conn.execute(
            "INSERT INTO scores(user_id, pseudo, total_km, updated_at)"
            " VALUES(?,?,?,?) ON CONFLICT(user_id) DO UPDATE SET"
            " pseudo = excluded.pseudo, total_km = ?, updated_at = ?",
            (s.user_id, s.pseudo, km, now, km, now))
        return {"rank": _rank(conn, km), "total_km": km}


@app.get("/v1/leaderboard")
def leaderboard(user_id: str | None = None):
    with _db() as conn:
        top = [{"pseudo": p, "total_km": k, "rank": i + 1}
               for i, (p, k) in enumerate(conn.execute(
                   "SELECT pseudo, total_km FROM scores"
                   " ORDER BY total_km DESC, updated_at ASC LIMIT 50"))]
        me = None
        if user_id:
            row = conn.execute(
                "SELECT pseudo, total_km FROM scores WHERE user_id = ?",
                (user_id,)).fetchone()
            if row:
                me = {"pseudo": row[0], "total_km": row[1],
                      "rank": _rank(conn, row[1])}
        return {"top": top, "me": me}
