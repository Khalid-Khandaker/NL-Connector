import csv, json, os, shutil, sys, time
import pwd
from datetime import datetime, timezone
from dotenv import load_dotenv
from supabase import create_client

import re
from html import unescape

REQUIRED_USER = "nlconnector"

def require_service_user() -> None:
    current_user = pwd.getpwuid(os.geteuid()).pw_name
    if current_user != REQUIRED_USER:
        print(
            f"ERROR: This program must run as '{REQUIRED_USER}', not '{current_user}'.",
            file=sys.stderr,
        )
        sys.exit(1)

require_service_user()

LOCK_PATH = "/var/lock/nl-connector.lock"
BASE = "/opt/nl-connector"
STAGING = f"{BASE}/staging"
ARCHIVE = f"{BASE}/archive"
ERROR = f"{BASE}/error"
LOG_PATH = "/var/log/nl-connector/connector.log"
SERVICE_NAME = "connector"
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
OPTIONAL_CSV_FIELDS = ["ingredients"]
CSV_HEADERS = [k for k, _, _ in REQUIRED] + OPTIONAL_CSV_FIELDS + ["output_file_name"]

def acquire_global_lock() -> bool:
    os.makedirs("/var/lock", exist_ok=True)
    try:
        fd = os.open(LOCK_PATH, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        os.write(fd, str(os.getpid()).encode("utf-8"))
        os.close(fd)
        return True
    except FileExistsError:
        return False

def release_global_lock():
    try:
        os.remove(LOCK_PATH)
    except FileNotFoundError:
        pass

def _split_top_level(text: str):
    if not text:
        return []

    parts = []
    buf = []
    depth = 0

    for ch in text:
        if ch == "(":
            depth += 1
            buf.append(ch)
        elif ch == ")":
            if depth > 0:
                depth -= 1
            buf.append(ch)
        elif ch in [",", ";"] and depth == 0:
            part = "".join(buf).strip()
            if part:
                parts.append(part)
            buf = []
        else:
            buf.append(ch)

    tail = "".join(buf).strip()
    if tail:
        parts.append(tail)

    return parts


def _strip_html(text: str) -> str:
    if not text:
        return ""
    text = unescape(str(text))
    text = re.sub(r"</?b[^>]*>", "", text, flags=re.IGNORECASE)
    text = re.sub(r"<[^>]+>", "", text)
    return text


def _normalize_spaces(text: str) -> str:
    text = text.replace('"', " ")
    text = re.sub(r"\s+", " ", text)
    text = re.sub(r"\s*,\s*", ", ", text)
    text = re.sub(r"\s*\(\s*", " (", text)
    text = re.sub(r"\s*\)\s*", ")", text)
    return text.strip(" ,;-")


def _clean_allergen_blob(text: str) -> str:
    text = _strip_html(text)
    text = _normalize_spaces(text)

    m = re.search(r"\((.*)\)", text)
    if not m:
        return text

    inner = m.group(1).strip()
    if not inner:
        return ""

    items = []
    seen = set()
    for part in _split_top_level(inner):
        p = _normalize_spaces(_strip_html(part))
        if not p:
            continue
        key = p.casefold()
        if key not in seen:
            seen.add(key)
            items.append(p)

    return ", ".join(items)


def _prettify_base_name(base: str) -> str:
    if not base:
        return ""

    s = _strip_html(base).upper().strip()

    s = re.sub(r"^\d+\)\s*", "", s)

    replacements = [
        (r"^PDT DOUCE ROUGE.*$", "Patate douce rouge"),
        (r"^AVOCAT DEMI.*$", "Avocat"),
        (r"^QUINOA BLANC.*$", "Quinoa blanc"),
        (r"^ORANGE A DESSERT.*$", "Orange"),
        (r"^OEUF DUR ECALE.*$", "Œufs"),
        (r"^CHOU DE MAI.*$", "Chou de Mai"),
        (r"^GRAINE DE TOURNESOL.*$", "Graine de tournesol"),
        (r"^HUILE TOURNESOL/OLIVE.*$", "Huile tournesol/olive"),
        (r"^MIEL DU LUXEMBOURG.*$", "Miel"),
        (r"^FOND BRUN.*$", "Fond brun"),
        (r"^CIBOULETTE.*$", "Ciboulette"),
        (r"^CUMIN MOULU.*$", "Cumin moulu"),
        (r"^SEL FIN IODE.*$", "Sel fin iodé"),
        (r"^POIVRE NOIR MOULU.*$", "Poivre noir moulu"),
        (r"^FROM\.MOZZARELLA.*$", "Mozzarella"),
        (r"^FOND PIZZA.*$", "Fond pizza"),
        (r"^CHAMPIGNON PARIS.*$", "Champignon de Paris"),
        (r"^JAMBON CUIT.*$", "Jambon cuit"),
        (r"^MAIS EN GRAIN.*$", "Maïs en grain"),
        (r"^POIVRON TRICOLORE.*$", "Poivron tricolore"),
        (r"^SALAMI ARDENNE.*$", "Salami ardenne"),
        (r"^OLIVE NOIRE.*$", "Olive noire"),
        (r"^TOMATE CONCASSEE.*$", "Tomate concassée"),
        (r"^ORIGAN PIZZA.*$", "Origan"),
        (r"^OIGNON GROS.*$", "Oignon"),
        (r"^CAROTTE GEANTE.*$", "Carotte"),
        (r"^AIL EPLUCHE.*$", "Ail épluché"),
        (r"^EAU RECETTE.*$", "Eau"),
        (r"^BASILIC.*$", "Basilic"),
    ]

    for pattern, value in replacements:
        if re.match(pattern, s):
            return value

    s = re.split(r"\s*-\s*", s, maxsplit=1)[0]

    s = re.sub(r"\b\d+(?:[.,]\d+)?\s*(KG|G|GR|L|ML|U)\b", "", s)
    s = re.sub(r"\b\d+[Xx]\d+(?:[.,]\d+)?\b", "", s)
    s = re.sub(r"\bCAL\s*\d+/\d+\b", "", s)

    s = _normalize_spaces(s)

    if not s:
        return ""

    return s[:1] + s[1:].lower()


def _clean_single_ingredient(text: str) -> str:
    if not text:
        return ""

    text = _strip_html(text)
    text = _normalize_spaces(text)

    if not text:
        return ""
        
    if "product (" in text.lower():
        return _clean_allergen_blob(text)

    base = text
    if "(" in text:
        base = text.split("(", 1)[0].strip()

    clean = _prettify_base_name(base)
    return _normalize_spaces(clean)


def format_ingredients(ingredients):
    if not ingredients:
        return ""

    cleaned = []
    seen = set()

    if isinstance(ingredients, list):
        for item in ingredients:
            if isinstance(item, dict):
                raw = item.get("name", "")
            else:
                raw = str(item)

            clean = _clean_single_ingredient(raw)
            if clean:
                key = clean.casefold()
                if key not in seen:
                    seen.add(key)
                    cleaned.append(clean)

        return ", ".join(cleaned)

    raw = str(ingredients).strip()

    if "product (" in raw.lower():
        return _clean_allergen_blob(raw)

    for part in _split_top_level(raw):
        clean = _clean_single_ingredient(part)
        if clean:
            key = clean.casefold()
            if key not in seen:
                seen.add(key)
                cleaned.append(clean)

    return ", ".join(cleaned)

def log(level, event, batch_id, file_name, message, run_id=""):
    obj = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "service": SERVICE_NAME,
        "run_id": run_id or "",
        "pid": os.getpid(),
        "level": level,
        "event": event,
        "batch_id": batch_id or "",
        "file_name": file_name or "",
        "message": message,
    }
    with open(LOG_PATH, "a", encoding="utf-8") as f:
        f.write(json.dumps(obj, ensure_ascii=False) + "\n")

def clean_product_name(name: str) -> str:
    if not name:
        return ""

    name = str(name)
    name = name.replace('"', '').strip()
    name = re.sub(r'^EGS\s*CP\s*', '', name, flags=re.IGNORECASE)
    name = re.sub(r'\s+', ' ', name).strip()

    return name

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

    date_part = str(batch_id)[:8]

    site_part = str(site).strip().upper()[:3]

    if not date_part.isdigit():
        date_part = datetime.now().strftime("%Y%m%d")

    if not site_part:
        site_part = "SITE"

    return f"{site_part}_{date_part}.csv"

def make_output_pdf_name(site, batch_id, template_name):
    date_part = str(batch_id)[:8]
    if not date_part.isdigit():
        date_part = datetime.now().strftime("%Y%m%d")

    site_part = str(site).strip()
    if not site_part:
        site_part = "SITE"

    template_part = str(template_name or "").strip()

    template_part = os.path.basename(template_part.replace("\\", "/"))
    
    if template_part.lower().endswith(".nlbl"):
        template_part = template_part[:-5]

    template_part = _safe_name(template_part, "template", 80)

    return f"{site_part}_{date_part}_{template_part}.pdf"

def sort_rows_for_nicelabel(rows):
    def sort_key(r):
        template_name = str(r.get("template_name") or "").casefold()
        product_name = str(r.get("product_name") or "").casefold()
        row_id = str(r.get("id") or "")
        return (template_name, product_name, row_id)

    return sorted(rows, key=sort_key)

def atomic_write_csv(file_name, rows, template_base: str, label_base: str):
    os.makedirs(STAGING, exist_ok=True)
    tmp_path = os.path.join(STAGING, file_name + ".tmp")
    csv_path = os.path.join(STAGING, file_name)
    
    rows = sort_rows_for_nicelabel(rows)

    output_stem = os.path.splitext(file_name)[0]

    with open(tmp_path, "w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=CSV_HEADERS)
        w.writeheader()

        for r in rows:
            row_data = {k: r.get(k, "") for k, _, _ in REQUIRED}
            row_data["product_name"] = clean_product_name(row_data.get("product_name"))

            raw_template = str(row_data.get("template_name") or "").strip()

            if raw_template and not raw_template.lower().endswith(".nlbl"):
                raw_template += ".nlbl"

            if template_base and raw_template:
                row_data["template_name"] = (
                    template_base.rstrip("\\/") + "\\" +
                    raw_template.lstrip("\\/")
                )
            else:
                row_data["template_name"] = raw_template
                
            for k in OPTIONAL_CSV_FIELDS:
                if k == "ingredients":
                    row_data[k] = format_ingredients(r.get(k))
                else:
                    row_data[k] = r.get(k, "") or ""
                    
                output_file = make_output_pdf_name(
                    site=row_data.get("site", ""),
                    batch_id=row_data.get("batch_id", ""),
                    template_name=raw_template,
                )

                if label_base:
                    row_data["output_file_name"] = (
                        label_base.rstrip("\\/") + "\\" + output_file
                    )
                else:
                    row_data["output_file_name"] = output_file

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
        error_fields = [k for k, _, _ in REQUIRED] + OPTIONAL_CSV_FIELDS
        with open(csv_out, "w", encoding="utf-8", newline="") as f:
            w = csv.DictWriter(f, fieldnames=error_fields)
            w.writeheader()
            for r in rows:
                row_out = {k: r.get(k, "") for k, _, _ in REQUIRED}
                for k in OPTIONAL_CSV_FIELDS:
                    row_out[k] = r.get(k, "") or ""
                w.writerow(row_out)
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


def mark_batch_error_rows(sb, table, batch_id, errors):

    try:
        sb.table(table).update({"status": "ERROR"}).eq("batch_id", batch_id).execute()
    except Exception as e:
        log("ERROR", "UNEXPECTED_ERROR", batch_id, "", f"Failed to mark batch ERROR: {e}")
        return

    for row_id, reason in errors:
        log("ERROR", "ROW_VALIDATION_FAILED", batch_id, "", f"row_id={row_id} reason={reason}")
        try:
            sb.table(table).update({
                "status": "ERROR",
                "error_reason": reason
            }).eq("id", row_id).execute()
        except Exception:
            try:
                sb.table(table).update({
                    "status": "ERROR"
                }).eq("id", row_id).execute()
            except Exception as e:
                log("ERROR", "UNEXPECTED_ERROR", batch_id, "", f"Failed to mark row ERROR: {e}")

def fetch_ready_batch_ids_for_oldest_created_at(sb, table: str, limit_batches: int = 100):
    resp0 = (
        sb.table(table)
        .select("created_at")
        .eq("status", "READY")
        .order("created_at")
        .limit(1)
        .execute()
    )
    first = resp0.data or []
    if not first:
        return [], None

    run_created_at = first[0].get("created_at")
    if not run_created_at:
        return [], None

    resp1 = (
        sb.table(table)
        .select("batch_id")
        .eq("status", "READY")
        .eq("created_at", run_created_at)
        .order("batch_id")
        .limit(limit_batches * 50)
        .execute()
    )

    rows = resp1.data or []
    seen = set()
    batch_ids = []
    for r in rows:
        bid = (r.get("batch_id") or "").strip()
        if bid and bid not in seen:
            seen.add(bid)
            batch_ids.append(bid)
            if len(batch_ids) >= limit_batches:
                break

    return batch_ids, run_created_at


def claim_batch(sb, table: str, batch_id: str, run_id: str) -> bool:
    try:
        resp = (
            sb.table(table)
            .update({"status": "VALIDATING"})
            .eq("batch_id", batch_id)
            .eq("status", "READY")
            .execute()
        )
        updated = resp.data or []
        if updated:
            log("INFO", "BATCH_CLAIMED", batch_id, "", f"Claimed rows={len(updated)} run_id={run_id}")
            return True
        else:
            log("INFO", "BATCH_ALREADY_CLAIMED", batch_id, "", f"Skipped (not READY) run_id={run_id}")
            return False
    except Exception as e:
        log("ERROR", "CLAIM_FAILED", batch_id, "", f"{e} run_id={run_id}")
        return False


def fetch_full_batch_by_status(sb, table: str, batch_id: str, status: str, page_size: int = 500):
    all_rows = []
    offset = 0
    while True:
        resp = (
            sb.table(table)
            .select("*")
            .eq("batch_id", batch_id)
            .eq("status", status)
            .order("id")
            .range(offset, offset + page_size - 1)
            .execute()
        )
        page = resp.data or []
        if not page:
            break
        all_rows.extend(page)
        offset += page_size
    return all_rows

def main():
    run_id = datetime.now().strftime("%Y%m%d-%H%M%S")

    if not acquire_global_lock():
        log("INFO", "RUN_SKIPPED", "", "", "Another connector run is active")
        return 0

    try:
        load_dotenv("/opt/nl-connector/config/.env")
        
        dest = os.getenv("MOUNT_POINT", "").strip()
        if not dest:
            log("ERROR", "VALIDATION_FAILED", "", "", "MOUNT_POINT is not set in /opt/nl-connector/config/.env")
            return 1
        
        url = os.getenv("SUPABASE_URL")
        key = os.getenv("SUPABASE_SERVICE_ROLE_KEY")
        table = os.getenv("SUPABASE_TABLE")
        template_base = os.getenv("TEMPLATE_PATH", "").strip()
        label_base = os.getenv("LABEL_PATH", "").strip()

        if not url or not key or not table:
            log("ERROR", "VALIDATION_FAILED", "", "", "Missing SUPABASE env config")
            return 1

        sb = create_client(url, key)

        batch_ids, run_created_at = fetch_ready_batch_ids_for_oldest_created_at(sb, table, limit_batches=100)

        if not batch_ids:
            log("INFO", "EMPTY_QUEUE", "", "", "No READY rows found")
            return 0

        log("INFO", "RUN_GROUP_SELECTED", "", "", f"created_at={run_created_at} batches={len(batch_ids)}", run_id=run_id)

        batches = {}
        errors = []

        for batch_id in batch_ids:
            if not claim_batch(sb, table, batch_id, run_id):
                continue

            rows = fetch_full_batch_by_status(sb, table, batch_id, status="VALIDATING", page_size=500)
            if not rows:
                log("ERROR", "BATCH_CLAIMED_BUT_EMPTY", batch_id, "", f"run_id={run_id}")
                continue

            batches[batch_id] = rows

            for r in rows:
                site = r.get("site", "site")
                ok, reason = validate_row(r)
                if not ok:
                    errors.append((batch_id, site, r.get("id"), reason))

        for batch_id, rows in batches.items():
            sites = {str(x.get("site", "")).strip() for x in rows}
            if len(sites) != 1:
                errors.append((batch_id, "mixed", None, f"Batch has multiple sites: {sorted(sites)}"))

        if errors:
            log("ERROR", "VALIDATION_FAILED", "", "", f"{len(errors)} row errors detected")

            error_batches = set(b for (b, _, _, _) in errors)
            for batch_id in error_batches:
                batch_rows = batches.get(batch_id) or []
                site = batch_rows[0].get("site", "site") if batch_rows else "site"
                file_name = make_filename(site, batch_id)

                batch_errors = [(row_id, reason) for (b, _, row_id, reason) in errors if b == batch_id]

                log("ERROR", "VALIDATION_FAILED", batch_id, file_name, f"{len(batch_errors)} row errors")

                if batch_rows:
                    write_validation_error_artifacts(
                        site=site,
                        run_id=run_id,
                        batch_id=batch_id,
                        file_name=file_name,
                        rows=batch_rows,
                        reason="validation failed (see row reasons)",
                        failing_row_id=None
                    )

                mark_batch_error_rows(sb, table, batch_id, batch_errors)

            return 1

        for batch_id, rows in batches.items():
            site = rows[0].get("site", "site")
            file_name = make_filename(site, batch_id)

            log("INFO", "BATCH_CREATED", batch_id, file_name, f"Rows={len(rows)}")

            csv_path = atomic_write_csv(file_name, rows, template_base, label_base)

            ok, info = copy_with_retry(csv_path, dest, file_name)
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
                sb.table(table).update({"status": "SENT"}).in_("id", ids).eq("status", "VALIDATING").execute()

            time.sleep(COPY_INTERVAL_SEC)

        return 0

    finally:
        release_global_lock()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        log("ERROR", "UNEXPECTED_ERROR", "", "", str(e))
        sys.exit(3) 


