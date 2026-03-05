import os
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

app = Flask(__name__)


def _auth_ok() -> bool:
    if not API_KEY:
        return True
    return request.headers.get("X-API-Key", "") == API_KEY


def _run_script(script_path: str):
    p = subprocess.run(
        [VENV_PY, script_path],
        capture_output=True,
        text=True,
    )
    stdout = (p.stdout or "")[-2000:]
    stderr = (p.stderr or "")[-2000:]
    return p.returncode, stdout, stderr

@app.get("/health")
def health():
    return jsonify({
        "status": "ok",
        "time_utc": datetime.now(timezone.utc).isoformat(),
    })


@app.get("/queue")
def queue():
    if not _auth_ok():
        return jsonify({"error": "unauthorized"}), 401

    if not (SUPABASE_URL and SUPABASE_KEY and SUPABASE_TABLE):
        return jsonify({"error": "missing SUPABASE env config"}), 500

    sb = create_client(SUPABASE_URL, SUPABASE_KEY)

    def count_status(st: str) -> int:
        r = sb.table(SUPABASE_TABLE).select("id").eq("status", st).limit(10000).execute()
        return len(r.data or [])

    return jsonify({
        "table": SUPABASE_TABLE,
        "READY": count_status("READY"),
        "ERROR": count_status("ERROR"),
        "SENT": count_status("SENT"),
    })


@app.post("/trigger/selector")
def trigger_selector():
    if not _auth_ok():
        return jsonify({"error": "unauthorized"}), 401

    code, out, err = _run_script(SELECTOR_PATH)
    return jsonify({
        "ok": code == 0,
        "exit_code": code,
        "stdout": out,
        "stderr": err,
    }), (200 if code == 0 else 500)


@app.post("/trigger/connector")
def trigger_connector():
    if not _auth_ok():
        return jsonify({"error": "unauthorized"}), 401

    code, out, err = _run_script(CONNECTOR_PATH)
    return jsonify({
        "ok": code == 0,
        "exit_code": code,
        "stdout": out,
        "stderr": err,
    }), (200 if code == 0 else 500)


if __name__ == "__main__":
    app.run(host=HOST, port=PORT)
