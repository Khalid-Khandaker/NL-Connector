import csv, json, os, shutil, sys, time
from datetime import datetime, timezone
from dotenv import load_dotenv
from supabase import create_client

BASE = "/opt/nl-connector"
INBOX = f"{BASE}/inbox"
STAGING = f"{BASE}/staging"
ARCHIVE = f"{BASE}/archive"
ERROR = f"{BASE}/error"
LOG_PATH = "/var/log/nl-connector/connector.log"
DEST = "/mnt/nicelabel/in"

RETRIES = 3
RETRY_DELAY_SEC = 10

REQUIRED = [
  ("batch_id", 40, "text"),
  ("site", 60, "text"),
  ("template_name", 80, "text"),
  ("language", 10, "text"),
  ("product_name", 120, "text"),
  ("allergens_short", 80, "text"),
  ("qty", None, "int_1_999"),
]

def log(level, event, batch_id, file_name, message):
    obj = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "level": level,
        "event": event,
        "batch_id": batch_id or "",
        "file_name": file_name or "",
        "message": message,
    }
    with open(LOG_PATH, "a", encoding="utf-8") as f:
        f.write(json.dumps(obj, ensure_ascii=False) + "\n")

def validate_row(row):
    for key, maxlen, typ in REQUIRED:
        if key not in row or row[key] in (None, ""):
            return False, f"Missing required field: {key}"
        val = str(row[key])
        if maxlen and len(val) > maxlen:
            return False, f"Field too long: {key} (max {maxlen})"
        if typ == "int_1_999":
            try:
                n = int(row[key])
            except:
                return False, "qty must be integer"
            if not (1 <= n <= 999):
                return False, "qty must be 1..999"
    return True, "OK"

def _safe_name(s: str, fallback: str, max_len: int):
    s = s or ""
    safe = "".join(c for c in s if c.isalnum() or c in ("-", "_"))
    safe = safe[:max_len].strip("-_")
    return safe if safe else fallback

def make_filename(site, batch_id):
    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    safe_site = _safe_name(site, "site", 30)
    safe_batch = _safe_name(batch_id, "batch", 40)
    return f"{ts}-{safe_site}-{safe_batch}.csv"

def atomic_write_csv(file_name, rows):
    os.makedirs(STAGING, exist_ok=True)
    tmp_path = os.path.join(STAGING, file_name + ".tmp")
    csv_path = os.path.join(STAGING, file_name)

    with open(tmp_path, "w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=[k for k,_,_ in REQUIRED])
        w.writeheader()
        for r in rows:
            w.writerow({k: r[k] for k,_,_ in REQUIRED})

    os.replace(tmp_path, csv_path)  # atomic rename
    return csv_path

def copy_with_retry(src_path, dest_dir, file_name):
    os.makedirs(dest_dir, exist_ok=True)
    dest_path = os.path.join(dest_dir, file_name)

    last_err = None
    for attempt in range(1, RETRIES + 1):
        try:
            shutil.copy2(src_path, dest_path)
            return True, dest_path
        except Exception as e:
            last_err = str(e)
            time.sleep(RETRY_DELAY_SEC)
    return False, last_err

def write_validation_error_artifacts(site, run_id, batch_id, file_name, rows, reason, failing_row_id=None):
    """
    Store validation failures under:
      /opt/nl-connector/error/<run_id>/<site>/

    Writes:
      - CSV snapshot
      - .error.json metadata
    """
    safe_site = _safe_name(site, "site", 60)

    # New structure:
    # /opt/nl-connector/error/<run_id>/<site>/
    run_dir = os.path.join(ERROR, run_id, safe_site)
    os.makedirs(run_dir, exist_ok=True)

    # 1) CSV snapshot
    csv_out = os.path.join(run_dir, file_name)
    try:
        with open(csv_out, "w", encoding="utf-8", newline="") as f:
            w = csv.DictWriter(f, fieldnames=[k for k,_,_ in REQUIRED])
            w.writeheader()
            for r in rows:
                w.writerow({k: r.get(k, "") for k,_,_ in REQUIRED})
    except Exception as e:
        log("ERROR", "UNEXPECTED_ERROR", batch_id, file_name, f"Failed writing error CSV snapshot: {e}")

    # 2) Error metadata
    meta_out = os.path.join(run_dir, file_name + ".error.json")
    try:
        with open(meta_out, "w", encoding="utf-8") as f:
            json.dump({
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "site": site,
                "batch_id": batch_id,
                "file_name": file_name,
                "failing_row_id": failing_row_id,
                "error_reason": reason,
                "rows_count": len(rows),
            }, f, ensure_ascii=False, indent=2)
    except Exception as e:
        log("ERROR", "UNEXPECTED_ERROR", batch_id, file_name, f"Failed writing error metadata: {e}")

def mark_batch_error_row_owned(sb, table, batch_id, failing_row_id, reason):
    """
    Goal:
      - Block the whole batch from reprocessing: set status=ERROR for ALL rows in batch_id
      - Assign error_reason ONLY to the failing row (identified by id)
      - Do NOT overwrite other rows' error_reason (should stay NULL)

    We do it in two safe steps:
      1) batch: status=ERROR (no error_reason)
      2) failing row: status=ERROR + error_reason=reason (fallback if column doesn't exist)
    """
    # Step 1: block the entire batch (no error_reason here)
    try:
        sb.table(table).update({"status": "ERROR"}).eq("batch_id", batch_id).execute()
    except Exception as e:
        log("ERROR", "UNEXPECTED_ERROR", batch_id, "", f"Failed to mark batch status ERROR: {e}")
        # If we can't even block the batch, return; otherwise it will keep retrying
        return

    # Step 2: set error_reason only on the failing row
    if not failing_row_id:
        return

    # Try with error_reason first
    try:
        sb.table(table).update({"status": "ERROR", "error_reason": reason}).eq("id", failing_row_id).execute()
        return
    except Exception:
        # fallback if error_reason column doesn't exist
        try:
            sb.table(table).update({"status": "ERROR"}).eq("id", failing_row_id).execute()
        except Exception as e:
            log("ERROR", "UNEXPECTED_ERROR", batch_id, "", f"Failed to set failing row ERROR: {e}")

def main():
    # One run id per execution (used for error folder grouping)
    run_id = datetime.now().strftime("%Y%m%d-%H%M%S")

    load_dotenv("/opt/nl-connector/config/.env")
    url = os.getenv("SUPABASE_URL")
    key = os.getenv("SUPABASE_SERVICE_ROLE_KEY")
    table = os.getenv("SUPABASE_TABLE")

    if not url or not key or not table:
        log("ERROR", "VALIDATION_FAILED", "", "", "Missing SUPABASE env config")
        return 1

    sb = create_client(url, key)

    resp = sb.table(table).select("*").eq("status", "READY").limit(500).execute()
    items = resp.data or []
    if not items:
        log("INFO", "BATCH_CREATED", "", "", "No READY rows found")
        return 0

    # Group by batch_id (one file per batch)
    batches = {}
    for r in items:
        batch_id = r.get("batch_id", "")
        ok, reason = validate_row(r)

        if not ok:
            site = r.get("site", "site")
            failing_row_id = r.get("id")  # <-- your chosen row identifier

            file_name = make_filename(site, batch_id or "batch")

            # Log the failing row id in message for faster debugging
            log("ERROR", "VALIDATION_FAILED", batch_id, file_name, f"{reason} (failing_row_id={failing_row_id})")

            batch_rows = [x for x in items if x.get("batch_id") == batch_id] or [r]
            write_validation_error_artifacts(
                site=site,
                run_id=run_id,
                batch_id=batch_id,
                file_name=file_name,
                rows=batch_rows,
                reason=reason,
                failing_row_id=failing_row_id
            )

            # NEW: prevent spam + preserve ownership:
            # - whole batch status ERROR
            # - only failing row gets error_reason
            mark_batch_error_row_owned(sb, table, batch_id, failing_row_id, reason)

            return 1

        batches.setdefault(r["batch_id"], []).append(r)

    for batch_id, rows in batches.items():
        site = rows[0]["site"]
        file_name = make_filename(site, batch_id)

        log("INFO", "BATCH_CREATED", batch_id, file_name, f"Rows={len(rows)}")

        csv_path = atomic_write_csv(file_name, rows)

        ok, info = copy_with_retry(csv_path, DEST, file_name)
        if not ok:
            log("ERROR", "COPY_FAILED", batch_id, file_name, info)
            return 2

        # Archive structure:
        # /opt/nl-connector/archive/<YYYYMMDD>/<YYYYMMDD-HHMMSS>/
        archive_date = datetime.now().strftime("%Y%m%d")
        archive_run = run_id  # already YYYYMMDD-HHMMSS

        archive_dir = os.path.join(ARCHIVE, archive_date, archive_run)
        os.makedirs(archive_dir, exist_ok=True)

        shutil.move(csv_path, os.path.join(archive_dir, file_name))

        log("INFO", "BATCH_COPIED", batch_id, file_name, f"Delivered to {info}")

        # mark rows as SENT
        ids = [r["id"] for r in rows if "id" in r]
        if ids:
            sb.table(table).update({"status": "SENT"}).in_("id", ids).execute()

    return 0

if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        log("ERROR", "UNEXPECTED_ERROR", "", "", str(e))
        sys.exit(3)
