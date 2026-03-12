import os
import re
import json
from datetime import datetime, timezone
from typing import Any, Dict, List, Tuple
import requests
from dotenv import dotenv_values
from supabase import create_client
import time

ENV_PATH = "/opt/nl-connector/config/.env"
SERVICE_NAME = "selector"
LOG_PATH_DEFAULT = "/var/log/nl-connector/connector.log"
API1_FILE_NAME = "selector.py"
LOCK_PATH = "/var/lock/nl-selector.lock"
ALLOWED_CODELISTE = {132072, 151637, 184573}

def acquire_lock() -> bool:
    os.makedirs("/var/lock", exist_ok=True)
    try:
        fd = os.open(LOCK_PATH, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        os.write(fd, str(os.getpid()).encode("utf-8"))
        os.close(fd)
        return True
    except FileExistsError:
        return False


def release_lock():
    try:
        os.remove(LOCK_PATH)
    except FileNotFoundError:
        pass


def utc_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def log_event(
    *,
    level: str,
    event: str,
    message: str,
    batch_id: str = "",
    file_name: str = API1_FILE_NAME,
    log_path: str = LOG_PATH_DEFAULT,
    run_id: str = "",
) -> None:
    entry = {
        "timestamp": utc_iso(),
        "service": SERVICE_NAME,
        "run_id": run_id or "",
        "pid": os.getpid(),
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
    """
    Remove bracketed and parenthesized suffixes.
    Examples:
      "mélange champignons [OPUS1542]" -> "mélange champignons"
      "Chicken Adobo (Test)" -> "Chicken Adobo"
    """
    if not name:
        return name

    name = re.sub(r"\[.*?\]", "", name)
    name = re.sub(r"\(.*?\)", "", name)
    name = re.sub(r"\s+", " ", name).strip()
    name = name.rstrip("- ").strip()
    return name


def get_api_config(env: dict) -> tuple[str, str, int]:
    base_url = (env.get("CALCMENU_API_BASE_URL") or os.getenv("CALCMENU_API_BASE_URL") or "").strip().rstrip("/")
    api_key = (env.get("CALCMENU_API_KEY") or os.getenv("CALCMENU_API_KEY") or "").strip()

    timeout_raw = (env.get("CALCMENU_API_TIMEOUT") or os.getenv("CALCMENU_API_TIMEOUT") or "30").strip()
    timeout = int(timeout_raw) if timeout_raw else 30

    if not base_url:
        raise SystemExit("Missing CALCMENU_API_BASE_URL in /opt/nl-connector/config/.env")

    if not api_key:
        raise SystemExit("Missing CALCMENU_API_KEY in /opt/nl-connector/config/.env")

    return base_url, api_key, timeout


def fetch_recipes_ready_for_print(base_url: str, api_key: str, timeout: int) -> list[dict]:
    url = f"{base_url}/recipes/ready-for-print"

    resp = requests.get(
        url,
        headers={"X-API-Key": api_key},
        timeout=timeout,
    )
    resp.raise_for_status()

    payload = resp.json()
    if not payload.get("ok"):
        raise RuntimeError(f"API returned ok=false for /recipes/top10: {payload}")

    data = payload.get("data")
    if not isinstance(data, list):
        raise RuntimeError(f"Unexpected /recipes/top10 response shape: {payload}")

    return data


def fetch_recipe_label_data(
    base_url: str,
    api_key: str,
    timeout: int,
    code_liste: int,
    code_trans: int,
    code_nutrient_set: int,
) -> dict:
    url = f"{base_url}/recipes/label-data"

    resp = requests.get(
        url,
        headers={"X-API-Key": api_key},
        params={
            "code_liste": int(code_liste),
            "code_trans": int(code_trans),
            "code_nutrient_set": int(code_nutrient_set),
        },
        timeout=timeout,
    )
    resp.raise_for_status()

    payload = resp.json()
    if not payload.get("ok"):
        raise RuntimeError(
            f"API returned ok=false for /recipes/details "
            f"(code_liste={code_liste}, code_trans={code_trans}, code_nutrient_set={code_nutrient_set}): {payload}"
        )

    data = payload.get("data")
    if not isinstance(data, dict):
        raise RuntimeError(f"Unexpected /recipes/details response shape: {payload}")

    return data


def pick(item: dict, *keys, default=None):
    """Return first non-None value among keys."""
    for k in keys:
        if k in item and item[k] is not None:
            return item[k]
    return default


def join_allergens_short(recipe_data: dict) -> str:
    content = recipe_data.get("content") or {}
    allergens = content.get("allergens") or []
    if isinstance(allergens, list):
        return ", ".join(str(a).strip() for a in allergens if str(a).strip())
    return str(allergens).strip()


def join_ingredients_text(recipe_data: dict) -> str:
    """
    Supports both:
    1) New SP format: content.ingredients is a plain text string
    2) Old SP format: content.ingredients is a list of ingredient objects
    """
    content = recipe_data.get("content") or {}
    ingredients = content.get("ingredients")

    if ingredients is None:
        return ""

    # New format from updated SP
    if isinstance(ingredients, str):
        return ingredients.strip()

    # Backward-compatible with old list format
    if isinstance(ingredients, list):
        if not ingredients:
            return ""

        parts = []
        for ing in ingredients:
            if not isinstance(ing, dict):
                continue

            seq = ing.get("sequence", "")
            name = (ing.get("name") or "").strip()
            amount = str(ing.get("amount") or "").strip()
            unit = (ing.get("unit") or "").strip()

            qty = " ".join(x for x in [amount, unit] if x).strip()
            if qty:
                parts.append(f"{seq}) {name} - {qty}".strip())
            else:
                parts.append(f"{seq}) {name}".strip())

        return "; ".join(p for p in parts if p)

    return str(ingredients).strip()


def extract_site(recipe_data: dict) -> str:
    content = recipe_data.get("content") or {}
    ref = content.get("calcmenu_reference") or {}
    site = ref.get("code_site")
    return "" if site is None else str(site)


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

    run_id = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")

    trigger = detect_trigger()
    log_event(
        level="INFO",
        event="SYNC_STARTED",
        message=f"trigger={trigger}",
        run_id=run_id,
        batch_id="",
    )

    if not acquire_lock():
        log_event(
            level="INFO",
            event="RUN_SKIPPED",
            run_id=run_id,
            message="selector lock exists; another run active",
        )
        return 0

    try:
        try:
            api_base_url, api_key, api_timeout = get_api_config(env)

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

            t0 = time.time()
            try:
                recipes_to_print = fetch_recipes_ready_for_print(api_base_url, api_key, api_timeout)

                log_event(
                    level="INFO",
                    event="RECIPES_FETCH_OK",
                    run_id=run_id,
                    message=f"endpoint=/recipes/ready-for-print recipes={len(recipes_to_print)} duration_ms={int((time.time()-t0)*1000)}",
                    batch_id="",
                )

            except Exception as e:
                log_event(
                    level="ERROR",
                    event="RECIPES_FETCH_FAILED",
                    run_id=run_id,
                    message=f"endpoint=/recipes/ready-for-print err={type(e).__name__}:{e}",
                    batch_id="",
                )
                raise

            candidates: List[Dict[str, Any]] = []

            for item in recipes_to_print:
                code_liste = pick(item, "CodeListe", "code")

                if code_liste not in ALLOWED_CODELISTE:
                    continue

                code_trans = pick(item, "CodeTrans", default=7)
                code_nutrient_set = pick(item, "CodeNutrientSet", default=0)
                template_name = pick(item, "TemplateName", "template", default="RestaurantLabel_1")

                if code_liste is None:
                    raise RuntimeError(f"Top10 row missing CodeListe/code. Row={item}")

                code_liste = int(code_liste)
                code_trans = int(code_trans or 7)
                code_nutrient_set = int(code_nutrient_set or 0)
                template_name = str(template_name).strip()

                batch_date = datetime.now().strftime("%Y%m%d")

                try:
                    recipe_data = fetch_recipe_label_data(
                        api_base_url,
                        api_key,
                        api_timeout,
                        code_liste,
                        code_trans,
                        code_nutrient_set,
                    )
                    content = recipe_data.get("content") or {}

                    product_name = (content.get("title") or recipe_data.get("title") or "").strip()
                    product_name = clean_product_name(product_name)

                    allergens_short = join_allergens_short(recipe_data)
                    if not allergens_short:
                        allergens_short = "None"

                    ingredients_text = join_ingredients_text(recipe_data)

                    site = extract_site(recipe_data) or "1"
                    language = language_override if language_override else str(code_trans)

                    qty = qty_default

                    candidates.append(
                        {
                            "_batch_date": batch_date,
                            "site": site,
                            "template_name": template_name,
                            "language": language,
                            "product_name": product_name,
                            "allergens_short": allergens_short,
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
                        event="RECIPE_PROCESS_FAILED",
                        run_id=run_id,
                        message=f"code_liste={code_liste} err=JSONDecodeError:{e}",
                        batch_id="",
                    )
                    print(f"Failed CodeListe={code_liste}: {e}")

                except Exception as e:
                    failed += 1
                    log_event(
                        level="ERROR",
                        event="RECIPE_PROCESS_FAILED",
                        run_id=run_id,
                        message=f"code_liste={code_liste} err={type(e).__name__}:{e}",
                        batch_id="",
                    )
                    print(f"Failed CodeListe={code_liste}: {e}")

            if not candidates:
                print("No candidates to insert. Exiting.")

                log_event(
                    level="INFO",
                    event="SYNC_COMPLETED",
                    run_id=run_id,
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
                    run_id=run_id,
                    message=f"rows={len(payload)} site={site}",
                    batch_id=batch_id,
                )

                try:
                    sb.table(sb_table).insert(payload).execute()
                    inserted += len(payload)

                    log_event(
                        level="INFO",
                        event="SUPABASE_INSERT_OK",
                        run_id=run_id,
                        message=f"rows={len(payload)} site={site}",
                        batch_id=batch_id,
                    )

                    print(f"Inserted batch_id={batch_id} site={site} rows={len(payload)}")

                except Exception as e:
                    failed += len(payload)

                    log_event(
                        level="ERROR",
                        event="SUPABASE_INSERT_FAILED",
                        run_id=run_id,
                        message=f"rows={len(payload)} site={site} err={type(e).__name__}:{e}",
                        batch_id=batch_id,
                    )

                    print(f"FAILED inserting batch_id={batch_id} site={site} rows={len(payload)} err={e}")

            print(f"\nDONE inserted={inserted} failed={failed} table={sb_table}")

            log_event(
                level="INFO",
                event="SYNC_COMPLETED",
                run_id=run_id,
                message=f"inserted={inserted} failed={failed} batches={batches} trigger={trigger}",
                batch_id="",
            )

            return 0 if failed == 0 else 1

        except Exception as e:
            log_event(
                level="ERROR",
                event="SYNC_FAILED",
                run_id=run_id,
                message=f"err={type(e).__name__}:{e}",
                batch_id="",
            )
            raise
    finally:
        release_lock()

if __name__ == "__main__":
    raise SystemExit(main())
