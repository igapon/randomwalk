"""RandomWalk primitive leaderboard — anonymous ids, SQLite, plausibility cap."""
import contextlib
import datetime
import os
import sqlite3
import threading
import time

from fastapi import FastAPI
from pydantic import BaseModel, Field

MAX_KM_PER_DAY = 300.0

app = FastAPI()
_lock = threading.Lock()


def _db() -> sqlite3.Connection:
    conn = sqlite3.connect(os.environ.get("LEADERBOARD_DB", "/data/leaderboard.sqlite"))
    conn.execute(
        "CREATE TABLE IF NOT EXISTS scores("
        " user_id TEXT PRIMARY KEY, pseudo TEXT NOT NULL,"
        " total_km REAL NOT NULL, updated_at REAL NOT NULL,"
        " day TEXT, day_base_km REAL)")
    return conn


class Score(BaseModel):
    user_id: str = Field(min_length=8, max_length=64)
    pseudo: str = Field(min_length=1, max_length=24)
    total_km: float = Field(ge=0, le=1_000_000)


def _rank(conn: sqlite3.Connection, km: float) -> int:
    """Competition ranking: count users with strictly more km, then add 1."""
    return conn.execute(
        "SELECT COUNT(*) + 1 FROM scores WHERE total_km > ?", (km,)).fetchone()[0]


@app.post("/v1/score")
def submit_score(s: Score):
    now = time.time()
    today_utc = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    with _lock, contextlib.closing(_db()) as conn:
        row = conn.execute(
            "SELECT total_km, updated_at, day, day_base_km FROM scores WHERE user_id = ?",
            (s.user_id,)).fetchone()
        km = s.total_km
        if row:
            prev_km, prev_at, prev_day, prev_day_base_km = row
            # If day changed, reset day_base_km to previous total_km
            if prev_day != today_utc:
                day_base_km = prev_km
            else:
                # Same day: keep the day_base_km from start of day (don't update it)
                day_base_km = prev_day_base_km if prev_day_base_km is not None else 0.0
            # Cap to per-day budget: day_base_km + 300
            km = min(km, day_base_km + MAX_KM_PER_DAY)
            # Never decrease
            km = max(km, prev_km)

            # Update: only change day_base_km if the day changed
            if prev_day != today_utc:
                # Day changed, so update day_base_km to the boundary value
                conn.execute(
                    "UPDATE scores SET pseudo = ?, total_km = ?, updated_at = ?, day = ?, day_base_km = ?"
                    " WHERE user_id = ?",
                    (s.pseudo, km, now, today_utc, day_base_km, s.user_id))
            else:
                # Same day, keep day_base_km unchanged
                conn.execute(
                    "UPDATE scores SET pseudo = ?, total_km = ?, updated_at = ?"
                    " WHERE user_id = ?",
                    (s.pseudo, km, now, s.user_id))
        else:
            # First submission: day_base_km = 0
            day_base_km = 0.0
            conn.execute(
                "INSERT INTO scores(user_id, pseudo, total_km, updated_at, day, day_base_km)"
                " VALUES(?,?,?,?,?,?)",
                (s.user_id, s.pseudo, km, now, today_utc, day_base_km))

        conn.commit()
        return {"rank": _rank(conn, km), "total_km": km}


@app.get("/v1/leaderboard")
def leaderboard(user_id: str | None = None):
    with contextlib.closing(_db()) as conn:
        # Use window function RANK() for consistent competition ranking
        top = [{"pseudo": p, "total_km": k, "rank": r}
               for p, k, r in conn.execute(
                   "SELECT pseudo, total_km, RANK() OVER (ORDER BY total_km DESC) AS rnk"
                   " FROM scores"
                   " ORDER BY total_km DESC, updated_at ASC LIMIT 50")]
        me = None
        if user_id:
            row = conn.execute(
                "SELECT pseudo, total_km FROM scores WHERE user_id = ?",
                (user_id,)).fetchone()
            if row:
                me = {"pseudo": row[0], "total_km": row[1],
                      "rank": _rank(conn, row[1])}
        return {"top": top, "me": me}
