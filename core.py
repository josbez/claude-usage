"""Pure logic for ClaudeUsage — no PyObjC imports, so it is testable without AppKit.

Shared by app.py (the menu bar app) and fetch_limits.py (standalone debug script).
Keep it that way: anything that needs Foundation/AppKit/WebKit belongs in app.py.
"""

import json
import os
import glob
import sqlite3
import shutil
import subprocess
import tempfile
import hashlib
import time
from datetime import datetime, timezone, timedelta, date
from collections import defaultdict

from Crypto.Cipher import AES


STATS_CACHE = os.path.expanduser("~/.claude/stats-cache.json")
PROJECTS_DIR = os.path.expanduser("~/.claude/projects")
LIMITS_FILE = os.path.expanduser("~/.claude/usage-limits.json")
LOG_FILE = os.path.expanduser("~/Library/Logs/ClaudeUsage.log")
CLAUDE_APP_SUPPORT = os.path.expanduser("~/Library/Application Support/Claude")
DAYS_NL = ["ma", "di", "wo", "do", "vr", "za", "zo"]

# JS that fetches usage from all orgs and hands the best result to DELIVER(json_string).
# The caller substitutes DELIVER: app.py posts to a message handler, fetch_limits.py
# stores it on window so it can poll for it.
_FETCH_JS_TEMPLATE = """
(function() {
const deliver = (s) => { DELIVER };
fetch('/api/bootstrap', {credentials:'include', headers:{Accept:'application/json'}})
.then(r => r.json())
.then(async d => {
    const acct = d.account || {};
    const email = acct.email_address || acct.email || '';
    const memberships = acct.memberships || [];
    let best = null;
    for (const m of memberships) {
        const orgId = m.organization ? m.organization.uuid : null;
        if (!orgId) continue;
        try {
            const r = await fetch('/api/organizations/' + orgId + '/usage', {
                credentials: 'include',
                headers: {Accept: 'application/json'}
            });
            if (!r.ok) continue;
            const data = await r.json();
            if (data.five_hour === undefined) continue;
            const util = (data.five_hour && data.five_hour.utilization) || 0;
            if (!best || util > best.util) {
                best = {util, org_id: orgId, account_email: email, data};
            }
        } catch(e) { continue; }
    }
    if (best) {
        deliver(JSON.stringify({ok: true, org_id: best.org_id,
                                account_email: best.account_email, data: best.data}));
    } else {
        deliver(JSON.stringify({ok: false, error: 'no org with usage data'}));
    }
})
.catch(e => { deliver(JSON.stringify({ok: false, error: e.message})); });
})();
"""


def build_fetch_js(deliver_stmt: str) -> str:
    """deliver_stmt is a JS statement that consumes the result string `s`."""
    return _FETCH_JS_TEMPLATE.replace("DELIVER", deliver_stmt)


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

def log(msg: str):
    try:
        with open(LOG_FILE, "a") as f:
            f.write(f"{datetime.now().strftime('%Y-%m-%d %H:%M:%S')} {msg}\n")
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Cookie decryption (Chromium cookie store of the Claude desktop app)
# ---------------------------------------------------------------------------

def find_cookie_db(base: str = CLAUDE_APP_SUPPORT) -> str:
    """Return path to the Claude desktop app's cookie database, or ''.
    Newer Electron/Chromium versions moved Cookies into a Network subdir."""
    for candidate in (os.path.join(base, "Cookies"),
                      os.path.join(base, "Network", "Cookies")):
        if os.path.exists(candidate):
            return candidate
    return ""


def derive_cookie_key(safe_storage_password: str) -> bytes:
    """Chromium-on-macOS key derivation for the 'v10' cookie scheme."""
    return hashlib.pbkdf2_hmac("sha1", safe_storage_password.encode(), b"saltysalt", 1003, dklen=16)


def decrypt_cookie_value(enc_bytes: bytes, host: str, key: bytes):
    """Decrypt one encrypted_value; returns the ASCII string or None."""
    if enc_bytes[:3] != b"v10":
        return None
    dec = AES.new(key, AES.MODE_CBC, IV=b" " * 16).decrypt(enc_bytes[3:])
    pad = dec[-1]
    if not (1 <= pad <= 16 and dec.endswith(bytes([pad]) * pad)):
        return None
    dec = dec[:-pad]
    # Chromium >= v24 prefixes the value with sha256(host_key)
    if len(dec) >= 32 and dec[:32] == hashlib.sha256(host.encode()).digest():
        dec = dec[32:]
    try:
        return dec.decode("ascii")
    except UnicodeDecodeError:
        return None


def read_cookies(db_path: str, key: bytes) -> dict:
    """Read and decrypt all cookies from a Chromium cookie DB.
    Works on a copy: the desktop app keeps the live DB locked."""
    fd, dst = tempfile.mkstemp(suffix=".db")
    os.close(fd)
    shutil.copy2(db_path, dst)
    try:
        conn = sqlite3.connect(dst)
        try:
            rows = conn.execute(
                "SELECT name, encrypted_value, host_key, path FROM cookies"
            ).fetchall()
        finally:
            conn.close()
    finally:
        os.unlink(dst)

    return {
        name: {"value": val, "domain": host, "path": path}
        for name, enc, host, path in rows
        if (val := decrypt_cookie_value(bytes(enc), host, key))
    }


def read_safe_storage_password() -> str:
    # `security` is a system binary, not a Python interpreter — fine from the bundle.
    return subprocess.run(
        ["security", "find-generic-password", "-s", "Claude Safe Storage", "-w"],
        capture_output=True, text=True,
    ).stdout.strip()


def decrypt_claude_cookies() -> dict:
    """Decrypt cookies from the Claude desktop app's Chromium cookie store."""
    password = read_safe_storage_password()
    if not password:
        log("cookie decrypt: geen 'Claude Safe Storage' sleutel in keychain")
        return {}
    src = find_cookie_db()
    if not src:
        log("cookie decrypt: cookie-database niet gevonden")
        return {}
    return read_cookies(src, derive_cookie_key(password))


def session_key_from(cookies: dict) -> str:
    return cookies.get("sessionKey", {}).get("value", "")


# ---------------------------------------------------------------------------
# Formatting
# ---------------------------------------------------------------------------

def format_tokens(n: int) -> str:
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n / 1_000:.1f}k"
    return str(n)


def format_reset_time(iso_str: str) -> str:
    if not iso_str:
        return "—"
    try:
        dt = parse_dt(iso_str).astimezone()
        now = datetime.now(dt.tzinfo)
        diff = dt - now
        total_sec = int(diff.total_seconds())
        if 0 < total_sec < 86400:
            h = total_sec // 3600
            m = (total_sec % 3600) // 60
            if h > 0:
                return f"over {h}u {m}m"
            return f"over {m}m"
        day = DAYS_NL[dt.weekday()]
        return f"{day} {dt.strftime('%H:%M')}"
    except Exception:
        return "—"


def format_reset_compact(iso_str: str) -> str:
    """Compact countdown for the menu bar title, e.g. '2u15m' or '45m'."""
    if not iso_str:
        return "—"
    try:
        dt = parse_dt(iso_str).astimezone()
        now = datetime.now(dt.tzinfo)
        total_sec = int((dt - now).total_seconds())
        if total_sec <= 0:
            return "—"
        h = total_sec // 3600
        m = (total_sec % 3600) // 60
        if h > 0:
            return f"{h}u{m:02d}m"
        return f"{m}m"
    except Exception:
        return "—"


def face_icon(session_pct: int) -> str:
    """Tamagotchi-style face for the menu bar, stressing out as the session fills up."""
    if session_pct >= 100:
        return "💀"
    if session_pct >= 90:
        return "😱"
    if session_pct >= 75:
        return "😰"
    if session_pct >= 60:
        return "😨"
    if session_pct >= 40:
        return "😅"
    if session_pct >= 20:
        return "🙂"
    return "🚀"


def status_title(session_pct: int, weekly_pct: int, session_reset_compact: str) -> str:
    return f"{face_icon(session_pct)} {session_pct}% / {weekly_pct}% · {session_reset_compact}"


def title_from_limits(limits: dict) -> str:
    five_h = limits.get("five_hour") or {}
    seven_d = limits.get("seven_day") or {}
    session_pct = int(five_h.get("utilization", 0) or 0)
    weekly_pct = int(seven_d.get("utilization", 0) or 0)
    reset_compact = format_reset_compact(five_h.get("resets_at", ""))
    return status_title(session_pct, weekly_pct, reset_compact)


# ---------------------------------------------------------------------------
# Limits file
# ---------------------------------------------------------------------------

def parse_dt(s: str) -> datetime:
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    return datetime.fromisoformat(s)


def load_limits(path: str = LIMITS_FILE) -> dict:
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return {}


def limits_output(parsed: dict) -> dict:
    """Shape a successful fetch result into what gets written to LIMITS_FILE."""
    return {
        "fetched_at": datetime.now(timezone.utc).isoformat(),
        "org_id": parsed["org_id"],
        "account_email": parsed.get("account_email", ""),
        **parsed["data"],
    }


def limits_are_fresh(limits: dict, max_age_minutes: int = 5) -> bool:
    fetched = limits.get("fetched_at")
    if not fetched:
        return False
    try:
        dt = parse_dt(fetched)
        age = datetime.now(timezone.utc) - dt
        return age.total_seconds() < max_age_minutes * 60
    except Exception:
        return False


# ---------------------------------------------------------------------------
# Local Claude Code token statistics
# ---------------------------------------------------------------------------

def load_stats_cache(path: str = STATS_CACHE) -> dict:
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return {}


def scan_jsonl_files(projects_dir: str = PROJECTS_DIR) -> dict:
    daily: dict = defaultdict(lambda: {
        "msgs": 0, "input_tokens": 0, "output_tokens": 0, "cache_read": 0,
        "models": defaultdict(int),
    })
    for jsonl_path in glob.glob(os.path.join(projects_dir, "*", "*.jsonl")):
        try:
            with open(jsonl_path) as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        obj = json.loads(line)
                    except Exception:
                        continue
                    ts = obj.get("timestamp")
                    if not ts:
                        continue
                    try:
                        # Group by local calendar day, not UTC
                        date_key = parse_dt(ts).astimezone().date().isoformat()
                    except Exception:
                        continue
                    if obj.get("type") == "user" and obj.get("message", {}).get("role") == "user":
                        daily[date_key]["msgs"] += 1
                    elif obj.get("type") == "assistant":
                        usage = obj.get("message", {}).get("usage", {})
                        model = obj.get("message", {}).get("model", "unknown")
                        tok_in = usage.get("input_tokens", 0)
                        tok_out = usage.get("output_tokens", 0)
                        tok_cache = usage.get("cache_read_input_tokens", 0)
                        daily[date_key]["input_tokens"] += tok_in
                        daily[date_key]["output_tokens"] += tok_out
                        daily[date_key]["cache_read"] += tok_cache
                        daily[date_key]["models"][model] += tok_in + tok_out + tok_cache
        except Exception:
            pass
    return daily


_scan_cache = {"ts": 0.0, "data": None}


def scan_jsonl_files_cached(max_age_sec: float = 60.0) -> dict:
    """Cached wrapper: scanning every popover-open/refresh is wasteful."""
    now = time.monotonic()
    if _scan_cache["data"] is None or now - _scan_cache["ts"] > max_age_sec:
        _scan_cache["data"] = scan_jsonl_files()
        _scan_cache["ts"] = now
    return _scan_cache["data"]


def build_stats(jsonl_daily: dict = None, stats_cache: dict = None, now: datetime = None) -> dict:
    cache = load_stats_cache() if stats_cache is None else stats_cache
    if jsonl_daily is None:
        jsonl_daily = scan_jsonl_files_cached()
    if now is None:
        now = datetime.now()

    today = now.date()
    week_ago = today - timedelta(days=7)
    month_ago = today - timedelta(days=30)

    today_msgs = today_tokens = week_msgs = week_tokens = 0
    month_msgs = month_tokens = 0
    model_tokens: dict = defaultdict(int)

    for date_str, day in jsonl_daily.items():
        try:
            d = date.fromisoformat(date_str)
        except Exception:
            continue
        msgs = day["msgs"]
        tokens = day["input_tokens"] + day["output_tokens"]
        for model, tok in day["models"].items():
            model_tokens[model] += tok
        if d == today:
            today_msgs += msgs
            today_tokens += tokens
        if d >= week_ago:
            week_msgs += msgs
            week_tokens += tokens
        if d >= month_ago:
            month_msgs += msgs
            month_tokens += tokens

    return {
        "total_sessions": cache.get("totalSessions", 0),
        "total_messages": cache.get("totalMessages", 0),
        "today_msgs": today_msgs,
        "today_tokens": today_tokens,
        "week_msgs": week_msgs,
        "week_tokens": week_tokens,
        "month_msgs": month_msgs,
        "month_tokens": month_tokens,
        "model_totals": dict(model_tokens),
        "last_updated": now.strftime("%H:%M"),
        "jsonl_daily": {k: {"input_tokens": v["input_tokens"],
                             "output_tokens": v["output_tokens"],
                             "cache_read": v["cache_read"]}
                        for k, v in jsonl_daily.items()},
    }


def compute_weekly_tokens(jsonl_daily: dict, base_date: date) -> list:
    """Return list of 7 token counts (input+output only) for 7 days ending on base_date."""
    result = []
    for i in range(6, -1, -1):
        d = base_date - timedelta(days=i)
        day = jsonl_daily.get(d.isoformat(), {})
        tokens = day.get("input_tokens", 0) + day.get("output_tokens", 0)
        result.append(tokens)
    return result
