import csv, json, os, shutil, sys, time
from datetime import datetime, timezone
from dotenv import load_dotenv
from supabase import create_client

BASE = "/opt/nl-connector"
STAGING = f"{BASE}/staging"
ARCHIVE = f"{BASE}/archive"
ERROR = f"{BASE}/error"
LOG_PATH = "/var/log/nl-connector/connector.log"
DEST = "/mnt/nicelabel/in"

RETRIES = 3
RETRY_DELAY_SEC = 10

COPY_INTERVAL_SEC = 5

REQUIRED = [
    ("batch_id", 40, "text"),
    ("site", 60, "text"),
    ("template_name", 80, "text"),
    ("language", 10, "text"),
    ("product_name", 120, "text"),
    ("allergens_short", 180, "text"),
    ("qty", None, "int_1_999"),
]


CSV_HEADERS = [k for k, _, _ in REQUIRED] + ["output_file_name"]


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

        if key == "allergens_short":
            val = row.get(key, "")
            if val is None:
                val = ""
            val = str(val)

            if maxlen and len(val) > maxlen:
                return False, f"Field too long: {key} (max {maxlen})"
            continue

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

    output_name = os.path.splitext(file_name)[0]

    with open(tmp_path, "w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=CSV_HEADERS)
        w.writeheader()
        for r in rows:
            row_data = {k: r.get(k, "") for k, _, _ in REQUIRED}
            row_data["output_file_name"] = output_name
            w.writerow(row_data)

    os.replace(tmp_path, csv_path)
    return csv_path


def copy_with_retry(src_path, dest_dir, file_name):
    os.makedirs(dest_dir, exist_ok=True)
    dest_path = os.path.join(dest_dir, file_name)

    last_err = None
    for _ in range(RETRIES):
        try:
            shutil.copy2(src_path, dest_path)
            return True, dest_path
        except Exception as e:
            last_err = str(e)
            time.sleep(RETRY_DELAY_SEC)

    return False, last_err


def write_validation_error_artifacts(site, run_id, batch_id, file_name, rows, reason, failing_row_id=None):
    safe_site = _safe_name(site, "site", 60)
    run_dir = os.path.join(ERROR, run_id, safe_site)
    os.makedirs(run_dir, exist_ok=True)

    csv_out = os.path.join(run_dir, file_name)
    try:
        with open(csv_out, "w", encoding="utf-8", newline="") as f:
            w = csv.DictWriter(f, fieldnames=[k for k, _, _ in REQUIRED])
            w.writeheader()
            for r in rows:
                w.writerow({k: r.get(k, "") for k, _, _ in REQUIRED})
    except Exception as e:
        log("ERROR", "UNEXPECTED_ERROR", batch_id, file_name, f"Failed writing error CSV snapshot: {e}")

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
    try:
        sb.table(table).update({"status": "ERROR"}).eq("batch_id", batch_id).execute()
    except Exception as e:
        log("ERROR", "UNEXPECTED_ERROR", batch_id, "", f"Failed to mark batch ERROR: {e}")
        return

    if not failing_row_id:
        return

    try:
        sb.table(table).update(
            {"status": "ERROR", "error_reason": reason}
        ).eq("id", failing_row_id).execute()
    except Exception:
        try:
            sb.table(table).update(
                {"status": "ERROR"}
            ).eq("id", failing_row_id).execute()
        except Exception as e:
            log("ERROR", "UNEXPECTED_ERROR", batch_id, "", f"Failed to set failing row ERROR: {e}")


def main():
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
        log("INFO", "EMPTY_QUEUE", "", "", "No READY rows found")
        return 0

    batches = {}
    errors = []

    for r in items:
        batch_id = r.get("batch_id", "")
        site = r.get("site", "site")

        ok, reason = validate_row(r)
        if not ok:
            errors.append((batch_id, site, r.get("id"), reason))

        batches.setdefault(batch_id, []).append(r)

    for batch_id, rows in batches.items():
        sites = {str(x.get("site", "")).strip() for x in rows}
        if len(sites) != 1:
            errors.append((batch_id, "mixed", None, f"Batch has multiple sites: {sorted(sites)}"))

    if errors:
        for (batch_id, site, failing_row_id, reason) in errors:
            file_name = make_filename(site, batch_id or "batch")

            log(
                "ERROR",
                "VALIDATION_FAILED",
                batch_id,
                file_name,
                f"{reason} (failing_row_id={failing_row_id})"
            )

            batch_rows = batches.get(batch_id) or []
            if batch_rows:
                write_validation_error_artifacts(
                    site=site,
                    run_id=run_id,
                    batch_id=batch_id,
                    file_name=file_name,
                    rows=batch_rows,
                    reason=reason,
                    failing_row_id=failing_row_id
                )

            mark_batch_error_row_owned(sb, table, batch_id, failing_row_id, reason)

        log("ERROR", "SYNC_FAILED", "", "", f"Validation failed for {len(errors)} issue(s); nothing delivered")
        return 1

    for batch_id, rows in batches.items():
        site = rows[0].get("site", "site")
        file_name = make_filename(site, batch_id)

        log("INFO", "BATCH_CREATED", batch_id, file_name, f"Rows={len(rows)}")

        csv_path = atomic_write_csv(file_name, rows)

        ok, info = copy_with_retry(csv_path, DEST, file_name)
        if not ok:
            log("ERROR", "COPY_FAILED", batch_id, file_name, info)
            return 2

        archive_date = datetime.now().strftime("%Y%m%d")
        archive_dir = os.path.join(ARCHIVE, archive_date, run_id)
        os.makedirs(archive_dir, exist_ok=True)

        shutil.move(csv_path, os.path.join(archive_dir, file_name))

        log("INFO", "BATCH_COPIED", batch_id, file_name, f"Delivered to {info}")

        ids = [r["id"] for r in rows if "id" in r]
        if ids:
            sb.table(table).update({"status": "SENT"}).in_("id", ids).execute()

        time.sleep(COPY_INTERVAL_SEC)

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        log("ERROR", "UNEXPECTED_ERROR", "", "", str(e))
        sys.exit(3)

