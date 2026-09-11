#!/usr/bin/env python3
"""
Embedded Node Health Service
============================

A small, dependency-light service that tracks whether embedded Linux nodes
(BeagleBone Black, Raspberry Pi, BBAI, etc.) on a research subnet are alive.

Design notes
------------
* Nodes *push* a tiny JSON heartbeat on a fixed interval.  Push beats polling
  here: the server needs no knowledge of the address space, nothing scans the
  subnet, and a node behind a NAT/VLAN still reports in.
* A heartbeat is ~300 bytes of request plus ~60 bytes of response.  At the
  default 60 s interval that is roughly 6 bytes/second/node -- 100 nodes cost
  under 1 kB/s, which is nothing on a wired lab subnet.
* State lives in SQLite (WAL mode) so the dashboard survives a service restart
  or a server reboot and still shows the last-known state of every node.
* Liveness is derived at read time from ``last_seen``; there is no background
  sweeper thread to get stuck or to lose state on a worker restart.

Endpoints (mounted by nginx under /embedded_health/):
    GET  /                      dashboard
    POST /api/heartbeat         node check-in
    GET  /api/nodes             current fleet state (JSON)
    GET  /api/summary           counts only, cheap for external monitors
    POST /api/nodes/<id>/forget remove a decommissioned node
    GET  /api/healthz           service self-check
"""

from __future__ import annotations

import json
import os
import re
import sqlite3
import threading
import time
from pathlib import Path

from flask import Flask, jsonify, request, send_from_directory

BASE_DIR = Path(__file__).resolve().parent
STATIC_DIR = BASE_DIR / "static"


# --------------------------------------------------------------------------
# Configuration (environment driven; see deploy/server.env.example)
# --------------------------------------------------------------------------

def _env_int(name: str, default: int, minimum: int = 1) -> int:
    try:
        return max(minimum, int(os.environ.get(name, default)))
    except (TypeError, ValueError):
        return default


DB_PATH = os.environ.get("EH_DB_PATH", str(BASE_DIR.parent / "var" / "nodes.db"))

# Interval the agents are configured with.  Everything else is derived from it.
HEARTBEAT_INTERVAL = _env_int("EH_HEARTBEAT_INTERVAL", 60, minimum=5)

# Grace periods, expressed as multiples of the heartbeat interval.
LATE_AFTER_BEATS = _env_int("EH_LATE_AFTER_BEATS", 2)
OFFLINE_AFTER_BEATS = _env_int("EH_OFFLINE_AFTER_BEATS", 4)

# Nodes silent for longer than this are shown as decommissioned candidates.
STALE_AFTER_HOURS = _env_int("EH_STALE_AFTER_HOURS", 24)

# Abuse guards.  A well-behaved agent is nowhere near these.
MAX_BODY_BYTES = _env_int("EH_MAX_BODY_BYTES", 4096, minimum=512)
MIN_BEAT_SPACING = max(1, HEARTBEAT_INTERVAL // 6)
MAX_NODES = _env_int("EH_MAX_NODES", 2000, minimum=10)

LATE_AFTER = HEARTBEAT_INTERVAL * LATE_AFTER_BEATS
OFFLINE_AFTER = HEARTBEAT_INTERVAL * OFFLINE_AFTER_BEATS
STALE_AFTER = STALE_AFTER_HOURS * 3600

# device_id is a MAC address or systemd machine-id; keep it boring and safe.
ID_RE = re.compile(r"^[A-Za-z0-9:._-]{4,64}$")
SAFE_TEXT_RE = re.compile(r"[^\x20-\x7e]")


# --------------------------------------------------------------------------
# Storage
# --------------------------------------------------------------------------

SCHEMA = """
CREATE TABLE IF NOT EXISTS nodes (
    device_id     TEXT PRIMARY KEY,
    hostname      TEXT NOT NULL DEFAULT '',
    reported_ip   TEXT NOT NULL DEFAULT '',
    source_ip     TEXT NOT NULL DEFAULT '',
    mac           TEXT NOT NULL DEFAULT '',
    model         TEXT NOT NULL DEFAULT '',
    kernel        TEXT NOT NULL DEFAULT '',
    agent_version TEXT NOT NULL DEFAULT '',
    uptime_s      INTEGER NOT NULL DEFAULT 0,
    load1         REAL    NOT NULL DEFAULT 0,
    mem_used_pct  REAL    NOT NULL DEFAULT 0,
    disk_used_pct REAL    NOT NULL DEFAULT 0,
    temp_c        REAL,
    tags          TEXT    NOT NULL DEFAULT '',
    first_seen    REAL    NOT NULL,
    last_seen     REAL    NOT NULL,
    boot_id       TEXT    NOT NULL DEFAULT '',
    boots         INTEGER NOT NULL DEFAULT 1,
    beats         INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_nodes_last_seen ON nodes(last_seen);
"""

_local = threading.local()


def get_db() -> sqlite3.Connection:
    conn = getattr(_local, "conn", None)
    if conn is None:
        Path(DB_PATH).parent.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(DB_PATH, timeout=10, isolation_level=None)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA synchronous=NORMAL")
        conn.execute("PRAGMA busy_timeout=5000")
        _local.conn = conn
    return conn


def init_db() -> None:
    get_db().executescript(SCHEMA)


# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

def clean(value, limit: int = 120) -> str:
    """Coerce anything an agent sends into short, printable, injection-free text."""
    if value is None:
        return ""
    text = str(value)
    text = SAFE_TEXT_RE.sub("", text).strip()
    return text[:limit]


def num(value, default=0.0, low=None, high=None):
    try:
        out = float(value)
    except (TypeError, ValueError):
        return default
    if out != out or out in (float("inf"), float("-inf")):
        return default
    if low is not None:
        out = max(low, out)
    if high is not None:
        out = min(high, out)
    return out


def classify(age: float) -> str:
    if age <= LATE_AFTER:
        return "online"
    if age <= OFFLINE_AFTER:
        return "late"
    if age <= STALE_AFTER:
        return "offline"
    return "stale"


def row_to_node(row: sqlite3.Row, now: float) -> dict:
    age = max(0.0, now - row["last_seen"])
    return {
        "device_id": row["device_id"],
        "hostname": row["hostname"] or row["device_id"],
        "ip": row["reported_ip"] or row["source_ip"],
        "reported_ip": row["reported_ip"],
        "source_ip": row["source_ip"],
        "ip_mismatch": bool(
            row["reported_ip"] and row["source_ip"] and row["reported_ip"] != row["source_ip"]
        ),
        "mac": row["mac"],
        "model": row["model"],
        "kernel": row["kernel"],
        "agent_version": row["agent_version"],
        "uptime_s": row["uptime_s"],
        "load1": row["load1"],
        "mem_used_pct": row["mem_used_pct"],
        "disk_used_pct": row["disk_used_pct"],
        "temp_c": row["temp_c"],
        "tags": [t for t in row["tags"].split(",") if t],
        "first_seen": row["first_seen"],
        "last_seen": row["last_seen"],
        "age_s": round(age, 1),
        "boots": row["boots"],
        "beats": row["beats"],
        "status": classify(age),
    }


# --------------------------------------------------------------------------
# Application
# --------------------------------------------------------------------------

app = Flask(__name__, static_folder=None)
app.config["MAX_CONTENT_LENGTH"] = MAX_BODY_BYTES


@app.after_request
def security_headers(resp):
    resp.headers.setdefault("X-Content-Type-Options", "nosniff")
    resp.headers.setdefault("Referrer-Policy", "no-referrer")
    resp.headers.setdefault("X-Frame-Options", "SAMEORIGIN")
    return resp


@app.route("/", methods=["GET"])
def dashboard():
    return send_from_directory(STATIC_DIR, "index.html")


@app.route("/favicon.svg", methods=["GET"])
def favicon():
    return send_from_directory(STATIC_DIR, "favicon.svg")


@app.route("/api/heartbeat", methods=["POST"])
def heartbeat():
    payload = request.get_json(silent=True)
    if not isinstance(payload, dict):
        return jsonify(error="expected a JSON object"), 400

    device_id = clean(payload.get("device_id"), 64)
    if not ID_RE.match(device_id):
        return jsonify(error="device_id must be 4-64 chars of [A-Za-z0-9:._-]"), 400

    # X-Real-IP is set by our own nginx; fall back to the socket peer.
    source_ip = clean(request.headers.get("X-Real-IP") or request.remote_addr or "", 45)
    now = time.time()
    db = get_db()

    existing = db.execute(
        "SELECT last_seen, boot_id, boots, beats, first_seen FROM nodes WHERE device_id = ?",
        (device_id,),
    ).fetchone()

    if existing is None:
        count = db.execute("SELECT COUNT(*) AS c FROM nodes").fetchone()["c"]
        if count >= MAX_NODES:
            return jsonify(error="node table full"), 507
    elif now - existing["last_seen"] < MIN_BEAT_SPACING:
        # Chatty or looping agent: accept quietly but do not write.
        return jsonify(status="throttled", interval=HEARTBEAT_INTERVAL), 429

    boot_id = clean(payload.get("boot_id"), 64)
    boots = 1
    beats = 1
    first_seen = now
    if existing is not None:
        first_seen = existing["first_seen"]
        beats = existing["beats"] + 1
        boots = existing["boots"]
        if boot_id and boot_id != existing["boot_id"]:
            boots += 1

    tags = payload.get("tags")
    if isinstance(tags, list):
        tags = ",".join(clean(t, 24) for t in tags[:8] if clean(t, 24))
    else:
        tags = clean(tags, 120)

    temp = payload.get("temp_c")
    temp_c = None if temp in (None, "") else num(temp, 0.0, -50, 200)

    db.execute(
        """
        INSERT INTO nodes (device_id, hostname, reported_ip, source_ip, mac, model,
                           kernel, agent_version, uptime_s, load1, mem_used_pct,
                           disk_used_pct, temp_c, tags, first_seen, last_seen,
                           boot_id, boots, beats)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(device_id) DO UPDATE SET
            hostname=excluded.hostname, reported_ip=excluded.reported_ip,
            source_ip=excluded.source_ip, mac=excluded.mac, model=excluded.model,
            kernel=excluded.kernel, agent_version=excluded.agent_version,
            uptime_s=excluded.uptime_s, load1=excluded.load1,
            mem_used_pct=excluded.mem_used_pct, disk_used_pct=excluded.disk_used_pct,
            temp_c=excluded.temp_c, tags=excluded.tags, last_seen=excluded.last_seen,
            boot_id=excluded.boot_id, boots=excluded.boots, beats=excluded.beats
        """,
        (
            device_id,
            clean(payload.get("hostname"), 80),
            clean(payload.get("ip"), 45),
            source_ip,
            clean(payload.get("mac"), 32),
            clean(payload.get("model"), 80),
            clean(payload.get("kernel"), 80),
            clean(payload.get("agent_version"), 24),
            int(num(payload.get("uptime_s"), 0, 0, 10**9)),
            round(num(payload.get("load1"), 0, 0, 1000), 2),
            round(num(payload.get("mem_used_pct"), 0, 0, 100), 1),
            round(num(payload.get("disk_used_pct"), 0, 0, 100), 1),
            temp_c,
            tags,
            first_seen,
            now,
            boot_id,
            boots,
            beats,
        ),
    )

    # Tell the agent what cadence we expect so the interval is server-controlled.
    return jsonify(status="ok", interval=HEARTBEAT_INTERVAL, server_time=int(now)), 200


@app.route("/api/nodes", methods=["GET"])
def nodes():
    now = time.time()
    rows = get_db().execute("SELECT * FROM nodes ORDER BY hostname, device_id").fetchall()
    items = [row_to_node(r, now) for r in rows]
    counts = {"online": 0, "late": 0, "offline": 0, "stale": 0}
    for item in items:
        counts[item["status"]] += 1
    resp = jsonify(
        server_time=now,
        heartbeat_interval=HEARTBEAT_INTERVAL,
        late_after_s=LATE_AFTER,
        offline_after_s=OFFLINE_AFTER,
        counts=counts,
        total=len(items),
        nodes=items,
    )
    resp.headers["Cache-Control"] = "no-store"
    return resp


@app.route("/api/summary", methods=["GET"])
def summary():
    now = time.time()
    rows = get_db().execute("SELECT last_seen FROM nodes").fetchall()
    counts = {"online": 0, "late": 0, "offline": 0, "stale": 0}
    for row in rows:
        counts[classify(now - row["last_seen"])] += 1
    return jsonify(total=len(rows), counts=counts, server_time=now)


@app.route("/api/nodes/<device_id>/forget", methods=["POST"])
def forget(device_id: str):
    if not ID_RE.match(device_id):
        return jsonify(error="bad device_id"), 400
    cur = get_db().execute("DELETE FROM nodes WHERE device_id = ?", (device_id,))
    if cur.rowcount == 0:
        return jsonify(error="unknown device_id"), 404
    return jsonify(status="forgotten", device_id=device_id)


@app.route("/api/healthz", methods=["GET"])
def healthz():
    try:
        get_db().execute("SELECT 1").fetchone()
    except sqlite3.Error as exc:  # pragma: no cover - only on disk failure
        return jsonify(status="error", detail=str(exc)), 503
    return jsonify(status="ok", db=DB_PATH, interval=HEARTBEAT_INTERVAL)


@app.errorhandler(404)
def not_found(_):
    return jsonify(error="not found"), 404


@app.errorhandler(413)
def too_large(_):
    return jsonify(error="payload too large"), 413


init_db()


if __name__ == "__main__":  # development only; production uses gunicorn
    app.run(host=os.environ.get("EH_BIND", "127.0.0.1"), port=_env_int("EH_PORT", 8787))
