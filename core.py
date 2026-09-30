"""Pure logic for ClaudeUsage — no PyObjC imports, so it is testable without AppKit.

Shared by app.py (the menu bar app) and fetch_limits.py (standalone debug script).
Keep it that way: anything that needs Foundation/AppKit/WebKit belongs in app.py.
"""

import json
import math
import os
import sqlite3
import shutil
import subprocess
import tempfile
import hashlib
from datetime import datetime, timezone, timedelta

from Crypto.Cipher import AES


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


def color_for_pct(pct: float) -> tuple:
    """Green -> orange -> red as usage fills up. Mirrors colorForPct() in
    dashboard.html so notification images match the popover."""
    pct = max(0.0, min(100.0, float(pct)))
    if pct <= 50:
        (p0, *c0), (p1, *c1) = (0, 47, 168, 74), (50, 255, 149, 0)
    else:
        (p0, *c0), (p1, *c1) = (50, 255, 149, 0), (100, 255, 59, 48)
    t = (pct - p0) / (p1 - p0)
    # math.floor(x + 0.5) == JS Math.round; Python's round() rounds half to even
    return tuple(math.floor(a + (b - a) * t + 0.5) for a, b in zip(c0, c1))


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
# Limit notifications (which thresholds to announce; posting lives in app.py)
# ---------------------------------------------------------------------------

FIVE_HOUR_THRESHOLDS = (80, 95)
WEEKLY_THRESHOLDS = (90,)
NOTIFY_STATE_FILE = os.path.expanduser("~/.claude/usage-tracker-notified.json")

_LIMIT_LABELS = {"five_hour": "5-uurslimiet", "seven_day": "Weeklimiet"}


def window_key(resets_at: str) -> str:
    """Stable id for one limit window. The API's resets_at jitters by a few
    microseconds between fetches, so round to the minute."""
    if not resets_at:
        return ""
    try:
        dt = parse_dt(resets_at).astimezone(timezone.utc)
    except Exception:
        return ""
    dt = (dt + timedelta(seconds=30)).replace(second=0, microsecond=0)
    return dt.isoformat()


def due_notifications(limits: dict, state: dict,
                      five_hour_thresholds=FIVE_HOUR_THRESHOLDS,
                      weekly_thresholds=WEEKLY_THRESHOLDS):
    """Return (notifications, new_state).

    One notification per limit per fetch at most: if several thresholds were
    crossed at once only the highest is announced, but all are marked sent.
    State is keyed per account and per limit, and resets when the window changes."""
    account = limits.get("account_email", "")
    new_state = dict(state)
    notes = []
    for limit, thresholds in (("five_hour", five_hour_thresholds),
                              ("seven_day", weekly_thresholds)):
        block = limits.get(limit) or {}
        wk = window_key(block.get("resets_at", ""))
        if not wk:
            continue
        pct = int(block.get("utilization", 0) or 0)
        key = f"{account}|{limit}"
        entry = state.get(key) or {}
        sent = list(entry.get("sent", [])) if entry.get("window") == wk else []
        crossed = [t for t in thresholds if pct >= t and t not in sent]
        if crossed:
            notes.append({
                "id": f"{key}|{wk}|{max(crossed)}",
                "title": f"Claude: {_LIMIT_LABELS[limit]} op {pct}%",
                "body": f"Reset {format_reset_time(block.get('resets_at', ''))}.",
                "limit": limit,
                "threshold": max(crossed),
                "pct": pct,
            })
            sent = sorted(set(sent) | set(crossed))
        new_state[key] = {"window": wk, "sent": sent}
    return notes, new_state


def load_notify_state(path: str = NOTIFY_STATE_FILE) -> dict:
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return {}


def save_notify_state(state: dict, path: str = NOTIFY_STATE_FILE):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f, indent=2)
    os.replace(tmp, path)


# ---------------------------------------------------------------------------
# User settings (toggled from the popover)
# ---------------------------------------------------------------------------

SETTINGS_FILE = os.path.expanduser("~/.claude/usage-tracker-settings.json")
DEFAULT_SETTINGS = {"notifications": True}


def load_settings(path: str = SETTINGS_FILE) -> dict:
    settings = dict(DEFAULT_SETTINGS)
    try:
        with open(path) as f:
            stored = json.load(f)
        settings.update({k: v for k, v in stored.items() if k in DEFAULT_SETTINGS})
    except Exception:
        pass
    return settings


def save_settings(settings: dict, path: str = SETTINGS_FILE):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(settings, f, indent=2)
    os.replace(tmp, path)
