import os
import json
import subprocess
from datetime import datetime, timezone

from dotenv import load_dotenv
from flask import Flask, request, jsonify
from supabase import create_client

load_dotenv("/opt/nl-connector/config/.env")

SUPABASE_URL = os.getenv("SUPABASE_URL", "")
SUPABASE_KEY = os.getenv("SUPABASE_SERVICE_ROLE_KEY", "")
SUPABASE_TABLE = os.getenv("SUPABASE_TABLE", "")

API_KEY = os.getenv("CONTROL_API_KEY", "")
HOST = os.getenv("CONTROL_API_HOST", "192.168.254.106")
PORT = int(os.getenv("CONTROL_API_PORT", "8088"))

VENV_PY = "/opt/nl-connector/app/.venv/bin/python"
SELECTOR_PATH = "/opt/nl-connector/app/selector.py"
CONNECTOR_PATH = "/opt/nl-connector/app/connector.py"

CONNECTOR_LOCK = "/var/lock/nl-connector.lock"
SELECTOR_LOCK = "/var/lock/nl-selector.lock"

CONNECTOR_LOG = "/var/log/nl-connector/connector.log"
SELECTOR_LOG = "/var/log/nl-connector/connector.log"

MOUNT_PATH = "/mnt/nicelabel/in"
STAGING_PATH = "/opt/nl-connector/staging"
LOG_DIR = "/var/log/nl-connector"

app = Flask(__name__)


def _auth_ok() -> bool:
    if not API_KEY:
        return True
    return request.headers.get("X-API-Key", "") == API_KEY


def _sb():
    return create_client(SUPABASE_URL, SUPABASE_KEY)


def _tail_jsonl(path: str, max_lines: int = 50):
    if not os.path.exists(path):
        return {"exists": False, "path": path, "tail": [], "last_event": None}

    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = f.read().splitlines()[-max_lines:]
    except Exception as e:
        return {"exists": True, "path": path, "tail": [], "last_event": None, "error": str(e)}

    tail = []
    last_event = None
    for ln in lines:
        try:
            obj = json.loads(ln)
            tail.append(obj)
            last_event = obj
        except Exception:
            tail.append({"raw": ln})

    return {"exists": True, "path": path, "tail": tail, "last_event": last_event}


def _lock_status(lock_path: str):
    if not os.path.exists(lock_path):
        return {"locked": False, "lock_path": lock_path, "pid": None}

    pid = None
    try:
        with open(lock_path, "r", encoding="utf-8") as f:
            pid_str = (f.read() or "").strip()
            pid = int(pid_str) if pid_str.isdigit() else None
    except Exception:
        pid = None

    return {"locked": True, "lock_path": lock_path, "pid": pid}


def _start_script_async(script_path: str):
    p = subprocess.Popen(
        [VENV_PY, script_path],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        close_fds=True,
    )
    return p.pid


def _path_writable(path: str):
    try:
        os.makedirs(path, exist_ok=True)
        test_file = os.path.join(path, ".write_test")
        with open(test_file, "w", encoding="utf-8") as f:
            f.write("ok")
        os.remove(test_file)
        return True, None
    except Exception as e:
        return False, str(e)


@app.get("/health")
def health():
    return jsonify({
        "ok": True,
        "service": "nl-connector-control",
        "time_utc": datetime.now(timezone.utc).isoformat(),
    })


@app.get("/queue")
def queue():
    if not _auth_ok():
        return jsonify({"ok": False, "error": "unauthorized"}), 401

    if not (SUPABASE_URL and SUPABASE_KEY and SUPABASE_TABLE):
        return jsonify({"ok": False, "error": "missing SUPABASE env config"}), 500

    sb = _sb()

    def count_status(st: str) -> int:
        r = sb.table(SUPABASE_TABLE).select("id").eq("status", st).limit(10000).execute()
        return len(r.data or [])

    oldest_ready = None
    try:
        r0 = (
            sb.table(SUPABASE_TABLE)
            .select("created_at")
            .eq("status", "READY")
            .order("created_at")
            .limit(1)
            .execute()
        )
        if r0.data:
            oldest_ready = r0.data[0].get("created_at")
    except Exception:
        oldest_ready = None

    return jsonify({
        "ok": True,
        "table": SUPABASE_TABLE,
        "counts": {
            "READY": count_status("READY"),
            "VALIDATING": count_status("VALIDATING"),
            "ERROR": count_status("ERROR"),
            "SENT": count_status("SENT"),
        },
        "oldest_ready_created_at": oldest_ready,
    })


@app.get("/status/connector")
def status_connector():
    if not _auth_ok():
        return jsonify({"ok": False, "error": "unauthorized"}), 401

    return jsonify({
        "ok": True,
        "lock": _lock_status(CONNECTOR_LOCK),
        "log": _tail_jsonl(CONNECTOR_LOG, max_lines=50),
    })


@app.get("/status/selector")
def status_selector():
    if not _auth_ok():
        return jsonify({"ok": False, "error": "unauthorized"}), 401

    return jsonify({
        "ok": True,
        "lock": _lock_status(SELECTOR_LOCK),
        "log": _tail_jsonl(SELECTOR_LOG, max_lines=50),
    })


@app.get("/diagnostics")
def diagnostics():
    if not _auth_ok():
        return jsonify({"ok": False, "error": "unauthorized"}), 401

    mount_ok = os.path.exists(MOUNT_PATH)
    mount_write, mount_err = _path_writable(MOUNT_PATH) if mount_ok else (False, "mount path missing")

    staging_ok = os.path.exists(STAGING_PATH)
    staging_write, staging_err = _path_writable(STAGING_PATH)

    log_ok = os.path.exists(LOG_DIR)
    log_write, log_err = _path_writable(LOG_DIR)

    supabase_ok = False
    supabase_err = None
    try:
        if SUPABASE_URL and SUPABASE_KEY and SUPABASE_TABLE:
            sb = _sb()
            sb.table(SUPABASE_TABLE).select("id").limit(1).execute()
            supabase_ok = True
        else:
            supabase_err = "missing SUPABASE env config"
    except Exception as e:
        supabase_err = str(e)

    return jsonify({
        "ok": True,
        "paths": {
            "mount": {"path": MOUNT_PATH, "exists": mount_ok, "writable": mount_write, "error": mount_err},
            "staging": {"path": STAGING_PATH, "exists": staging_ok, "writable": staging_write, "error": staging_err},
            "log_dir": {"path": LOG_DIR, "exists": log_ok, "writable": log_write, "error": log_err},
        },
        "supabase": {"ok": supabase_ok, "error": supabase_err},
        "locks": {
            "connector": _lock_status(CONNECTOR_LOCK),
            "selector": _lock_status(SELECTOR_LOCK),
        }
    })


@app.post("/trigger/selector")
def trigger_selector():
    if not _auth_ok():
        return jsonify({"ok": False, "error": "unauthorized"}), 401

    if os.path.exists(SELECTOR_LOCK):
        return jsonify({"ok": True, "started": False, "reason": "selector already running"}), 200

    pid = _start_script_async(SELECTOR_PATH)
    return jsonify({"ok": True, "started": True, "pid": pid}), 200


@app.post("/trigger/connector")
def trigger_connector():
    if not _auth_ok():
        return jsonify({"ok": False, "error": "unauthorized"}), 401

    if os.path.exists(CONNECTOR_LOCK):
        return jsonify({"ok": True, "started": False, "reason": "connector already running"}), 200

    pid = _start_script_async(CONNECTOR_PATH)
    return jsonify({"ok": True, "started": True, "pid": pid}), 200

@app.get("/logs")
def logs():
    if not _auth_ok():
        return jsonify({"ok": False, "error": "unauthorized"}), 401

    service_filter = request.args.get("service")  
    level_filter = request.args.get("level")     
    limit = int(request.args.get("limit", "100"))

    path = CONNECTOR_LOG 

    if not os.path.exists(path):
        return jsonify({"ok": False, "error": "log file not found", "path": path}), 404

    overfetch = max(limit * 10, 200)

    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = f.read().splitlines()[-overfetch:]
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 500

    events = []
    for ln in reversed(lines):
        if len(events) >= limit:
            break
        try:
            obj = json.loads(ln)
        except Exception:
            continue

        if service_filter and obj.get("service") != service_filter:
            continue
        if level_filter and obj.get("level") != level_filter:
            continue

        events.append(obj)

    return jsonify({
        "ok": True,
        "path": path,
        "filters": {"service": service_filter, "level": level_filter, "limit": limit},
        "count": len(events),
        "logs": events
    })

@app.get("/runtime")
def runtime():
    if not _auth_ok():
        return jsonify({"ok": False, "error": "unauthorized"}), 401

    connector_lock = _lock_status(CONNECTOR_LOCK)
    selector_lock = _lock_status(SELECTOR_LOCK)

    connector_log = _tail_jsonl(CONNECTOR_LOG, max_lines=200)
    selector_log = _tail_jsonl(SELECTOR_LOG, max_lines=200)

    last_validation = None
    if connector_log.get("tail"):
        for e in reversed(connector_log["tail"]):
            if isinstance(e, dict) and e.get("event") in ("VALIDATION_FAILED", "BATCH_CREATED", "BATCH_COPIED"):
                last_validation = e
                break

    return jsonify({
        "ok": True,
        "connector": {
            "running": connector_lock["locked"],
            "pid": connector_lock["pid"],
            "last_event": connector_log.get("last_event"),
            "last_validation_event": last_validation
        },
        "selector": {
            "running": selector_lock["locked"],
            "pid": selector_lock["pid"],
            "last_event": selector_log.get("last_event")
        }
    })

if __name__ == "__main__":
    app.run(host=HOST, port=PORT)
