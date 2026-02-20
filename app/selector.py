import os
import re
import json
from datetime import datetime, date
from typing import Any, Dict, List, Tuple

import pyodbc
from dotenv import dotenv_values
from supabase import create_client

import time
import traceback  

ENV_PATH = "/opt/nl-connector/config/.env"

LOG_PATH_DEFAULT = "/var/log/nl-connector/connector.log"
API1_FILE_NAME = "selector.py"


def utc_iso() -> str:

    return datetime.utcnow().isoformat(timespec="milliseconds") + "Z"


def log_event(
    *,
    level: str,
    event: str,
    message: str,
    batch_id: str = "",
    file_name: str = API1_FILE_NAME,
    log_path: str = LOG_PATH_DEFAULT,
) -> None:

    entry = {
        "timestamp": utc_iso(),
        "level": level,
        "event": event,
        "batch_id": batch_id or "",
        "file_name": file_name,
        "message": message,
    }

    try:
        os.makedirs(os.path.dirname(log_path), exist_ok=True)
        with open(log_path, "a", encoding="utf-8") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except Exception:

        pass


def detect_trigger() -> str:

    return "systemd" if os.getenv("INVOCATION_ID") else "manual"


def clean_product_name(name: str) -> str:
    if not name:
        return name

    name = re.sub(r"\[.*?\]", "", name)
    name = re.sub(r"\(.*?\)", "", name)
    name = re.sub(r"\s+", " ", name).strip()
    name = name.rstrip("- ").strip()
    return name


def fetch_top10(conn) -> list[dict]:
    cur = conn.cursor()
    cur.execute("SET NOCOUNT ON;")
    cur.execute("EXEC dbo.NiceLabel_GetTop10RecipesToPrint")

    cols = [c[0] for c in cur.description]
    out = []
    while True:
        row = cur.fetchone()
        if not row:
            break
        out.append({cols[i]: row[i] for i in range(len(cols))})
    return out


def fetch_recipe_details(conn, code_liste: int, code_trans: int, code_nutrient_set: int) -> dict:
    cur = conn.cursor()
    cur.execute("SET NOCOUNT ON;")
    cur.execute("EXEC dbo.NiceLabel_GetRecipeDetails ?, ?, ?", (code_liste, code_trans, code_nutrient_set))

    parts = []
    while True:
        r = cur.fetchone()
        if not r:
            break
        if r[0] is not None:
            parts.append(str(r[0]))

    raw = "".join(parts).strip()
    if not raw:
        raise RuntimeError("No JSON returned from NiceLabel_GetRecipeDetails.")
    if not raw.endswith("}"):
        raise RuntimeError(f"JSON appears incomplete (len={len(raw)}). Tail: {raw[-120:]}")
    return json.loads(raw)


def pick(item: dict, *keys, default=None):

    for k in keys:
        if k in item and item[k] is not None:
            return item[k]
    return default


def join_allergens_short(details: dict) -> str:
    content = details.get("content") or {}
    allergens = content.get("allergens") or []
    if isinstance(allergens, list):
        s = ", ".join(str(a).strip() for a in allergens if str(a).strip())
        return s
    return str(allergens).strip()


def join_ingredients_text(details: dict) -> str:
    content = details.get("content") or {}
    ingredients = content.get("ingredients") or []
    if not isinstance(ingredients, list) or not ingredients:
        return ""

    parts = []
    for ing in ingredients:
        seq = ing.get("sequence", "")
        name = (ing.get("name") or "").strip()
        amount = (ing.get("amount") or "").strip()
        unit = (ing.get("unit") or "").strip()

        qty = " ".join(x for x in [amount, unit] if x).strip()
        if qty:
            parts.append(f"{seq}) {name} - {qty}".strip())
        else:
            parts.append(f"{seq}) {name}".strip())

    return "; ".join(p for p in parts if p)


def extract_site(details: dict) -> str:
    content = details.get("content") or {}
    ref = content.get("calcmenu_reference") or {}
    site = ref.get("code_site")
    return "" if site is None else str(site)


def parse_batch_date_from_top10(item: dict) -> str:
    v = pick(item, "StartDate", "start_date", "startDate", default=None)
    if v is None:
        v = pick(item, "CreatedAt", "created_at", "createdAt", default=None)

    if v is None:
        return datetime.now().strftime("%Y%m%d")

    if isinstance(v, datetime):
        return v.strftime("%Y%m%d")
    if isinstance(v, date):
        return v.strftime("%Y%m%d")

    s = str(v).strip()
    if not s:
        return datetime.now().strftime("%Y%m%d")

    for fmt in ("%Y-%m-%d", "%Y/%m/%d", "%Y%m%d", "%d/%m/%Y", "%m/%d/%Y"):
        try:
            return datetime.strptime(s[:10], fmt).strftime("%Y%m%d")
        except Exception:
            pass

    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).strftime("%Y%m%d")
    except Exception:
        return datetime.now().strftime("%Y%m%d")


def site_code_from_site(site: str) -> str:
    s = (site or "").strip().upper()

    if not s:
        return "XXX"

    if s.isdigit():
        try:
            return str(int(s))
        except Exception:
            return s

    s = re.sub(r"[^A-Z0-9]+", "", s)
    if len(s) >= 3:
        return s[:3]
    return s.ljust(3, "X")

def next_run_seq_for_prefix(sb, table: str, prefix: str) -> int:
    like_pattern = f"{prefix}%"
    resp = sb.table(table).select("batch_id").like("batch_id", like_pattern).limit(2000).execute()

    existing = resp.data or []
    max_seq = 0
    for r in existing:
        bid = (r.get("batch_id") or "").strip()
        parts = bid.split("-")
        if len(parts) >= 4 and parts[-1].isdigit():
            try:
                max_seq = max(max_seq, int(parts[-1]))
            except Exception:
                pass
    return max_seq + 1

def main():
    env = dotenv_values(ENV_PATH)

    trigger = detect_trigger()
    log_event(
        level="INFO",
        event="SYNC_STARTED",
        message=f"trigger={trigger}",
        batch_id="",
    )

    try:
        server = env.get("SQL_SERVER", "192.168.1.28,1510")
        db = env.get("SQL_DATABASE", "CMC_2025")
        user = env.get("SQL_USER", "egs.khalid")
        pwd = env.get("SQL_PASSWORD") or os.environ.get("SQL_PASSWORD")

        if not pwd:
            raise SystemExit("Missing SQL_PASSWORD in /opt/nl-connector/config/.env (or export it).")

        conn_str = (
            "DRIVER={ODBC Driver 18 for SQL Server};"
            f"SERVER={server};DATABASE={db};"
            f"UID={user};PWD={pwd};"
            "Encrypt=yes;TrustServerCertificate=yes;"
        )

        sb_url = env.get("SUPABASE_URL") or os.getenv("SUPABASE_URL")
        sb_key = env.get("SUPABASE_SERVICE_ROLE_KEY") or os.getenv("SUPABASE_SERVICE_ROLE_KEY")
        sb_table = env.get("SUPABASE_TABLE") or os.getenv("SUPABASE_TABLE") or "nl_print_queue"

        if not sb_url or not sb_key:
            raise SystemExit("Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY.")

        sb = create_client(sb_url, sb_key)

        status_to_set = env.get("STATUS_TO_SET", "READY")
        qty_default = int(env.get("QTY_DEFAULT", "1"))
        language_override = (env.get("LANGUAGE_DEFAULT", "") or "").strip()

        site_name_for_code = (env.get("SITE_NAME_FOR_CODE", "") or "").strip()

        inserted = 0
        failed = 0

        with pyodbc.connect(conn_str, timeout=30) as conn:
            conn.setdecoding(pyodbc.SQL_CHAR, encoding="utf-8")
            conn.setdecoding(pyodbc.SQL_WCHAR, encoding="utf-8")
            conn.setencoding(encoding="utf-8")

            t0 = time.time()
            try:
                top10 = fetch_top10(conn)

                log_event(
                    level="INFO",
                    event="CM_FETCH_OK",
                    message=f"sp=NiceLabel_GetTop10RecipesToPrint rows={len(top10)} duration_ms={int((time.time()-t0)*1000)}",
                    batch_id="",
                )


            except Exception as e:
                log_event(
                    level="ERROR",
                    event="CM_FETCH_FAILED",
                    message=f"sp=NiceLabel_GetTop10RecipesToPrint err={type(e).__name__}:{e}",
                    batch_id="",
                )
                raise

            candidates: List[Dict[str, Any]] = []

            for item in top10:
                code_liste = pick(item, "CodeListe", "code")
                code_trans = pick(item, "CodeTrans", default=1)
                code_nutrient_set = pick(item, "CodeNutrientSet", default=0)
                template_name = pick(item, "TemplateName", "template", default="RestaurantLabel_1")
                qty_from_item = pick(item, "Qty", "Quantity", "qty", "quantity", "QTY", default=None)

                if code_liste is None:
                    raise RuntimeError(f"Top10 row missing CodeListe/code. Row={item}")

                code_liste = int(code_liste)
                code_trans = int(code_trans or 1)
                code_nutrient_set = int(code_nutrient_set or 0)
                template_name = str(template_name)

                batch_date = parse_batch_date_from_top10(item)

                try:
                    details = fetch_recipe_details(conn, code_liste, code_trans, code_nutrient_set)
                    content = details.get("content") or {}

                    product_name = (content.get("title") or details.get("title") or "").strip()
                    product_name = clean_product_name(product_name)

                    description = (content.get("description") or "").strip()

                    allergens_short = join_allergens_short(details)
                    if not allergens_short:
                        allergens_short = "None"

                    ingredients_text = join_ingredients_text(details)

                    site = extract_site(details) or "1"
                    language = language_override if language_override else str(code_trans)

                    try:
                        qty = int(qty_from_item) if qty_from_item is not None and str(qty_from_item).strip() else qty_default
                    except Exception:
                        qty = qty_default

                    candidates.append(
                        {
                            "_batch_date": batch_date,
                            "site": site,
                            "template_name": template_name,
                            "language": language,
                            "product_name": product_name,
                            "allergens_short": allergens_short,
                            "description": description,
                            "ingredients": ingredients_text,
                            "status": status_to_set,
                            "qty": qty,
                            "error_reason": None,
                        }
                    )

                except json.JSONDecodeError as e:
                    failed += 1
                    log_event(
                        level="ERROR",
                        event="DATA_PARSE_FAILED",
                        message=f"code_liste={code_liste} err=JSONDecodeError:{e}",
                        batch_id="",
                    )
                    print(f"Failed CodeListe={code_liste}: {e}")

                except Exception as e:
                    failed += 1
                    log_event(
                        level="ERROR",
                        event="DATA_PARSE_FAILED",
                        message=f"code_liste={code_liste} err={type(e).__name__}:{e}",
                        batch_id="",
                    )
                    print(f"Failed CodeListe={code_liste}: {e}")

            if not candidates:
                print("No candidates to insert. Exiting.")

                log_event(
                    level="INFO",
                    event="SYNC_COMPLETED",
                    message=f"inserted={inserted} failed={failed} batches=0 trigger={trigger}",
                    batch_id="",
                )

                return 0 if failed == 0 else 1

            groups: Dict[Tuple[str, str], List[Dict[str, Any]]] = {}
            for r in candidates:
                key = (r["_batch_date"], r["site"])
                groups.setdefault(key, []).append(r)

            batches = len(groups)

            for (batch_date, site), rows in groups.items():
                row_count_4 = f"{len(rows):04d}"

                site_code_source = site_name_for_code if site_name_for_code else site
                site_code = site_code_from_site(site_code_source)

                prefix = f"{batch_date}-{row_count_4}-{site_code}-"
                seq = next_run_seq_for_prefix(sb, sb_table, prefix)

                batch_id = f"{batch_date}-{row_count_4}-{site_code}-{seq:03d}"

                payload = []
                for r in rows:
                    rr = dict(r)
                    rr.pop("_batch_date", None)
                    rr["batch_id"] = batch_id
                    payload.append(rr)

                log_event(
                    level="INFO",
                    event="BATCH_CREATED",
                    message=f"rows={len(payload)} site={site}",
                    batch_id=batch_id,
                )

                try:
                    sb.table(sb_table).insert(payload).execute()
                    inserted += len(payload)

                    log_event(
                        level="INFO",
                        event="SUPABASE_INSERT_OK",
                        message=f"rows={len(payload)} site={site}",
                        batch_id=batch_id,
                    )

                    print(f"Inserted batch_id={batch_id} site={site} rows={len(payload)}")

                except Exception as e:
                    failed += len(payload)

                    log_event(
                        level="ERROR",
                        event="SUPABASE_INSERT_FAILED",
                        message=f"rows={len(payload)} site={site} err={type(e).__name__}:{e}",
                        batch_id=batch_id,
                    )

                    print(f"FAILED inserting batch_id={batch_id} site={site} rows={len(payload)} err={e}")

        print(f"\nDONE inserted={inserted} failed={failed} table={sb_table}")

        log_event(
            level="INFO",
            event="SYNC_COMPLETED",
            message=f"inserted={inserted} failed={failed} batches={batches} trigger={trigger}",
            batch_id="",
        )

        return 0 if failed == 0 else 1

    except Exception as e:
        log_event(
            level="ERROR",
            event="SYNC_FAILED",
            message=f"err={type(e).__name__}:{e}",
            batch_id="",
        )
        raise


if __name__ == "__main__":
    raise SystemExit(main())

