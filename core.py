"""Pure logic for ClaudeUsage — no PyObjC imports, so it is testable without AppKit.

Shared by app.py (the menu bar app) and fetch_limits.py (standalone debug script).
Keep it that way: anything that needs Foundation/AppKit/WebKit belongs in app.py.
"""

import base64
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
    // Only name and plan leave the page — never the whole bootstrap payload
    const name = acct.display_name || acct.full_name || '';
    const memberships = acct.memberships || [];
    let best = null;
    for (const m of memberships) {
        const org = m.organization || {};
        const orgId = org.uuid || null;
        if (!orgId) continue;
        // Raw plan data; core.plan_label() turns it into a label (observed values only)
        const plan = {label: org.plan_display_label || org.plan_display_name || '',
                      capabilities: org.capabilities || [], tier: org.rate_limit_tier || ''};
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
                best = {util, org_id: orgId, account_email: email, plan, data};
            }
        } catch(e) { continue; }
    }
    if (best) {
        deliver(JSON.stringify({ok: true, org_id: best.org_id,
                                account_email: best.account_email,
                                account_name: name, account_plan: best.plan,
                                data: best.data}));
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
# Languages: the app follows the macOS preferred language (nl, else en).
# All user-facing text lives here; logs stay Dutch (they're for the maintainer).
# ---------------------------------------------------------------------------

LANGS = ("nl", "en")
DEFAULT_LANG = "en"

DAYS = {
    "nl": ["ma", "di", "wo", "do", "vr", "za", "zo"],
    "en": ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"],
}

STRINGS = {
    "nl": {
        # popover
        "app_title": "Claude Stats",
        "settings_title": "Instellingen",
        "btn_refresh": "Vernieuwen",
        "btn_settings": "Instellingen",
        "btn_quit": "Afsluiten",
        "session_label": "Huidige sessie",
        "weekly_label": "Weeklimiet",
        "used_suffix": "% gebruikt",
        "elapsed_suffix": "% verstreken",
        "reset_prefix": "Reset",
        "day_of": "dag {day} van {days}",
        "week_tooltip": "dag {day} van {days} · {elapsed}% van de week verstreken · {used}% gebruikt",
        "updated": "Bijgewerkt: {when}",
        "status_ok": "Verbonden met Anthropic API",
        "status_stale": "Kon niet vernieuwen",
        "status_not_logged_in": "Niet ingelogd",
        "loading": "Laden…",
        "connecting": "Verbinden…",
        "set_notifications": "Meldingen",
        "set_notifications_sub": "Bij 80% en 95% sessie, 90% week",
        "set_menubar": "Menubalk",
        "style_full": "Alles",
        "style_session": "Sessie",
        "style_emoji": "Emoji",
        "set_version": "Versie",
        "up_to_date": "Up-to-date",
        "update_available": "v{version} is beschikbaar",
        "update_btn": "Bijwerken",
        "update_working": "Bijwerken…",
        "update_retry": "Opnieuw",
        "update_failed": "Mislukt: {message}",
        "set_connection": "Verbinding",
        # relative time / reset time
        "ago_now": "zojuist",
        "ago_one_min": "1 min geleden",
        "ago_min": "{n} min geleden",
        "in_hm": "over {h}u {m}m",
        "in_m": "over {m}m",
        "compact_hm": "{h}u{m:02d}m",
        "compact_m": "{m}m",
        # status reasons
        "reason_not_logged_in": "log in in de Claude desktop-app",
        "reason_failed_at": "kon niet vernieuwen, data van {time}",
        "reason_failed": "kon niet vernieuwen",
        "reason_not_fetched": "nog niet opgehaald",
        "reason_data_at": "data van {time}",
        "reason_stale": "data verouderd",
        # notifications
        "limit_five_hour": "5-uurslimiet",
        "limit_seven_day": "Weeklimiet",
        "notif_limit_title": "Claude: {limit} op {pct}%",
        "notif_limit_body": "Reset {when}.",
        "notif_update_title": "ClaudeUsage {version} is beschikbaar",
        "notif_update_body": "Open de instellingen (tandwiel) in de popover om bij te werken.",
        # update dialogs
        "alert_install_title": "ClaudeUsage {version} installeren?",
        "alert_install_body": "Je hebt nu versie {current}. De update wordt gedownload en "
                              "gecontroleerd; daarna sluit de app even af en start opnieuw.",
        "btn_update": "Bijwerken",
        "btn_later": "Later",
        "btn_whats_new": "Wat is er nieuw?",
        "alert_failed_title": "Bijwerken is niet gelukt",
        "alert_failed_body": "{error}. De huidige versie blijft gewoon werken.",
        # update errors
        "err_no_dmg": "deze release heeft geen DMG",
        "err_unsigned": "deze release is niet ondertekend",
        "err_not_newer": "{new} is niet nieuwer dan {current}",
        "err_download": "downloaden mislukt ({detail})",
        "err_bad_response": "onleesbaar antwoord van GitHub",
        "err_sig_invalid": "handtekening klopt niet — update geweigerd",
        "err_dmg_open": "DMG openen mislukt",
        "err_no_app": "geen ClaudeUsage.app in de DMG",
        "err_copy": "app kopiëren mislukt",
        "err_other_app": "DMG bevat een andere app",
        "err_version_mismatch": "versie in DMG ({got}) klopt niet met release ({expected})",
        "err_codesign": "code-signature van de nieuwe app ongeldig",
        "err_unexpected": "onverwachte fout: {detail}",
        "err_install": "installeren mislukt: {detail}",
    },
    "en": {
        "app_title": "Claude Stats",
        "settings_title": "Settings",
        "btn_refresh": "Refresh",
        "btn_settings": "Settings",
        "btn_quit": "Quit",
        "session_label": "Current session",
        "weekly_label": "Weekly limit",
        "used_suffix": "% used",
        "elapsed_suffix": "% elapsed",
        "reset_prefix": "Resets",
        "day_of": "day {day} of {days}",
        "week_tooltip": "day {day} of {days} · {elapsed}% of the week elapsed · {used}% used",
        "updated": "Updated: {when}",
        "status_ok": "Connected to Anthropic API",
        "status_stale": "Couldn't refresh",
        "status_not_logged_in": "Not logged in",
        "loading": "Loading…",
        "connecting": "Connecting…",
        "set_notifications": "Notifications",
        "set_notifications_sub": "At 80% and 95% session, 90% week",
        "set_menubar": "Menu bar",
        "style_full": "All",
        "style_session": "Session",
        "style_emoji": "Emoji",
        "set_version": "Version",
        "up_to_date": "Up to date",
        "update_available": "v{version} is available",
        "update_btn": "Update",
        "update_working": "Updating…",
        "update_retry": "Retry",
        "update_failed": "Failed: {message}",
        "set_connection": "Connection",
        "ago_now": "just now",
        "ago_one_min": "1 min ago",
        "ago_min": "{n} min ago",
        "in_hm": "in {h}h {m}m",
        "in_m": "in {m}m",
        "compact_hm": "{h}h{m:02d}m",
        "compact_m": "{m}m",
        "reason_not_logged_in": "log in to the Claude desktop app",
        "reason_failed_at": "couldn't refresh, data from {time}",
        "reason_failed": "couldn't refresh",
        "reason_not_fetched": "not fetched yet",
        "reason_data_at": "data from {time}",
        "reason_stale": "data out of date",
        "limit_five_hour": "5-hour limit",
        "limit_seven_day": "Weekly limit",
        "notif_limit_title": "Claude: {limit} at {pct}%",
        "notif_limit_body": "Resets {when}.",
        "notif_update_title": "ClaudeUsage {version} is available",
        "notif_update_body": "Open settings (gear) in the popover to update.",
        "alert_install_title": "Install ClaudeUsage {version}?",
        "alert_install_body": "You're on version {current}. The update will be downloaded and "
                              "verified; then the app briefly quits and restarts.",
        "btn_update": "Update",
        "btn_later": "Later",
        "btn_whats_new": "What's new?",
        "alert_failed_title": "Update failed",
        "alert_failed_body": "{error}. The current version keeps working.",
        "err_no_dmg": "this release has no DMG",
        "err_unsigned": "this release is not signed",
        "err_not_newer": "{new} is not newer than {current}",
        "err_download": "download failed ({detail})",
        "err_bad_response": "unreadable response from GitHub",
        "err_sig_invalid": "signature doesn't match — update refused",
        "err_dmg_open": "couldn't open the DMG",
        "err_no_app": "no ClaudeUsage.app in the DMG",
        "err_copy": "couldn't copy the app",
        "err_other_app": "the DMG contains a different app",
        "err_version_mismatch": "version in DMG ({got}) doesn't match release ({expected})",
        "err_codesign": "the new app's code signature is invalid",
        "err_unexpected": "unexpected error: {detail}",
        "err_install": "install failed: {detail}",
    },
}


def language_from(preferred) -> str:
    """macOS preferred languages (e.g. ['nl-NL', 'en-US']) -> 'nl' or 'en'.
    Only the first (= the user's chosen) language counts."""
    try:
        first = str(list(preferred)[0]).lower()
    except Exception:
        return DEFAULT_LANG
    return "nl" if first.split("-")[0].split("_")[0] == "nl" else DEFAULT_LANG


def t(key: str, lang: str = DEFAULT_LANG, **kw) -> str:
    table = STRINGS.get(lang, STRINGS[DEFAULT_LANG])
    text = table.get(key, STRINGS[DEFAULT_LANG].get(key, key))
    return text.format(**kw) if kw else text


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

def log(msg: str):
    try:
        with open(LOG_FILE, "a", encoding="utf-8") as f:
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
        capture_output=True, encoding="utf-8", errors="replace",
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

def format_reset_time(iso_str: str, lang: str = "nl") -> str:
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
                return t("in_hm", lang, h=h, m=m)
            return t("in_m", lang, m=m)
        day = DAYS.get(lang, DAYS[DEFAULT_LANG])[dt.weekday()]
        return f"{day} {dt.strftime('%H:%M')}"
    except Exception:
        return "—"


def format_reset_compact(iso_str: str, lang: str = "nl") -> str:
    """Compact countdown for the menu bar title, e.g. '2u15m' / '2h15m' or '45m'."""
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
            return t("compact_hm", lang, h=h, m=m)
        return t("compact_m", lang, m=m)
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


MENUBAR_STYLES = ("full", "session", "emoji")


def status_title(session_pct: int, weekly_pct: int, session_reset_compact: str,
                 style: str = "full") -> str:
    """Menu bar text. 'full': 😅 45% / 82% · 2u10m, 'session': 😅 45%, 'emoji': 😅."""
    face = face_icon(session_pct)
    if style == "emoji":
        return face
    if style == "session":
        return f"{face} {session_pct}%"
    return f"{face} {session_pct}% / {weekly_pct}% · {session_reset_compact}"


def title_from_limits(limits: dict, style: str = "full", lang: str = "nl") -> str:
    five_h = limits.get("five_hour") or {}
    seven_d = limits.get("seven_day") or {}
    session_pct = int(five_h.get("utilization", 0) or 0)
    weekly_pct = int(seven_d.get("utilization", 0) or 0)
    reset_compact = format_reset_compact(five_h.get("resets_at", ""), lang)
    return status_title(session_pct, weekly_pct, reset_compact, style)


# ---------------------------------------------------------------------------
# Limits file
# ---------------------------------------------------------------------------

def parse_dt(s: str) -> datetime:
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    return datetime.fromisoformat(s)


def load_limits(path: str = LIMITS_FILE) -> dict:
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def limits_output(parsed: dict) -> dict:
    """Shape a successful fetch result into what gets written to LIMITS_FILE."""
    return {
        "fetched_at": datetime.now(timezone.utc).isoformat(),
        "org_id": parsed["org_id"],
        "account_email": parsed.get("account_email", ""),
        "account_name": parsed.get("account_name", ""),
        "account_plan": plan_label(parsed.get("account_plan")),
        **parsed["data"],
    }


# Capability -> label, only for values actually observed in API responses.
# Evidence: a Pro account returns capabilities ["claude_pro", "chat"] with an
# empty plan_display_label, and claude.ai shows "Pro". Add an entry only after
# seeing real data for that plan — never guess (unknown plans show nothing).
OBSERVED_PLAN_CAPABILITIES = {"claude_pro": "Pro"}


def plan_label(plan) -> str:
    """Plan name for display: the API's own label if present, otherwise an
    observed capability mapping, otherwise ''."""
    if isinstance(plan, str):          # already a label
        return plan.strip()
    if not isinstance(plan, dict):
        return ""
    if (plan.get("label") or "").strip():
        return plan["label"].strip()
    for cap in plan.get("capabilities") or []:
        if cap in OBSERVED_PLAN_CAPABILITIES:
            return OBSERVED_PLAN_CAPABILITIES[cap]
    return ""


def account_label(limits: dict) -> dict:
    """Who the numbers belong to, for the footer: name and plan.
    Falls back to the e-mail address (older caches have no name/plan)."""
    email = limits.get("account_email", "") or ""
    name = (limits.get("account_name", "") or "").strip()
    plan = (limits.get("account_plan", "") or "").strip()
    return {"name": name or email, "plan": plan, "email": email}


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
# Usage history: the API only returns the current state, so we keep our own
# record (source for the trends tab). Raw API values only — no derived data.
# Measured: ~650 bytes per fetch, ~288 fetches/day: ~5.5 MB/month (~65 MB/year).
# ---------------------------------------------------------------------------

HISTORY_DIR = os.path.expanduser("~/.claude/usage-history")


def _pick(block, keys):
    """Copy the given keys from an API block, skipping missing/None values."""
    if not isinstance(block, dict):
        return None
    out = {k: block[k] for k in keys if block.get(k) is not None}
    return out or None


def history_record(limits: dict) -> dict:
    """One history line from a fetched limits dict (as written to LIMITS_FILE)."""
    rec = {
        "ts": limits.get("fetched_at"),
        "account": limits.get("account_email"),
        "org_id": limits.get("org_id"),
        "five_hour": _pick(limits.get("five_hour"), ("utilization", "resets_at")),
        "seven_day": _pick(limits.get("seven_day"), ("utilization", "resets_at")),
    }
    bd = limits.get("seven_day_breakdown")
    if isinstance(bd, dict):
        rows = [_pick(r, ("key", "display_name", "percent"))
                for r in bd.get("rows") or [] if isinstance(r, dict)]
        rec["breakdown"] = _pick({"window_started_at": bd.get("window_started_at"),
                                  "rows": [r for r in rows if r] or None},
                                 ("window_started_at", "rows"))
    extra = limits.get("extra_usage")
    if isinstance(extra, dict) and extra.get("is_enabled"):
        rec["extra_usage"] = _pick(extra, ("used_credits", "monthly_limit", "currency"))
    return {k: v for k, v in rec.items() if v is not None}


def history_path(ts: str, base: str = HISTORY_DIR) -> str:
    """Monthly file (UTC) for a record timestamp: <base>/YYYY-MM.jsonl."""
    month = parse_dt(ts).astimezone(timezone.utc).strftime("%Y-%m")
    return os.path.join(base, f"{month}.jsonl")


def append_history(record: dict, base: str = HISTORY_DIR) -> str:
    """Append one JSON line; returns the file path. Raises on I/O errors —
    the caller logs and carries on."""
    path = history_path(record["ts"], base)
    os.makedirs(base, exist_ok=True)
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")
    return path


# ---------------------------------------------------------------------------
# Weekly window progress (elapsed time, not usage)
# ---------------------------------------------------------------------------

WEEK = timedelta(days=7)


def week_window(limits: dict):
    """(start, end, deviates) of the weekly limit window, or None.
    end = seven_day.resets_at; start = seven_day_breakdown.window_started_at
    when present, else end - 7 days. `deviates` flags a start that isn't
    exactly 7 days before end (never observed so far — worth logging)."""
    try:
        end = parse_dt((limits.get("seven_day") or {}).get("resets_at") or "")
    except Exception:
        return None
    start = None
    raw = (limits.get("seven_day_breakdown") or {}).get("window_started_at")
    if raw:
        try:
            start = parse_dt(raw)
        except Exception:
            start = None
    if start is None or start >= end:
        return end - WEEK, end, False
    return start, end, abs((end - start) - WEEK) > timedelta(minutes=1)


def week_progress(limits: dict, now: datetime):
    """How far the weekly window has run: {'elapsed_pct', 'day', 'days'} or None."""
    win = week_window(limits)
    if win is None:
        return None
    start, end, _ = win
    total = (end - start).total_seconds()
    done = min(max((now - start).total_seconds(), 0.0), total)
    days = max(1, round(total / 86400))
    day = min(days, int(done // 86400) + 1)
    return {"elapsed_pct": round(done / total * 100, 1), "day": day, "days": days}


# ---------------------------------------------------------------------------
# Limit notifications (which thresholds to announce; posting lives in app.py)
# ---------------------------------------------------------------------------

FIVE_HOUR_THRESHOLDS = (80, 95)
WEEKLY_THRESHOLDS = (90,)
NOTIFY_STATE_FILE = os.path.expanduser("~/.claude/usage-tracker-notified.json")


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
                      weekly_thresholds=WEEKLY_THRESHOLDS, lang: str = "nl"):
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
                "title": t("notif_limit_title", lang, limit=t(f"limit_{limit}", lang), pct=pct),
                "body": t("notif_limit_body", lang, when=format_reset_time(block.get("resets_at", ""), lang)),
                "limit": limit,
                "threshold": max(crossed),
                "pct": pct,
            })
            sent = sorted(set(sent) | set(crossed))
        new_state[key] = {"window": wk, "sent": sent}
    return notes, new_state


def load_json(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def save_json(data: dict, path: str):
    """Atomic write: a crash mid-write never leaves a half file behind."""
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, path)


def load_notify_state(path: str = NOTIFY_STATE_FILE) -> dict:
    return load_json(path)


def save_notify_state(state: dict, path: str = NOTIFY_STATE_FILE):
    save_json(state, path)


# ---------------------------------------------------------------------------
# User settings (toggled from the popover)
# ---------------------------------------------------------------------------

SETTINGS_FILE = os.path.expanduser("~/.claude/usage-tracker-settings.json")
DEFAULT_SETTINGS = {"notifications": True, "update_check": True, "menubar_style": "full"}


def load_settings(path: str = SETTINGS_FILE) -> dict:
    settings = dict(DEFAULT_SETTINGS)
    stored = load_json(path)
    settings.update({k: v for k, v in stored.items() if k in DEFAULT_SETTINGS})
    if settings["menubar_style"] not in MENUBAR_STYLES:
        settings["menubar_style"] = DEFAULT_SETTINGS["menubar_style"]
    return settings


def save_settings(settings: dict, path: str = SETTINGS_FILE):
    save_json(settings, path)


# ---------------------------------------------------------------------------
# Updates: GitHub release check and signature verification
# (downloading and installing is glue in app.py)
# ---------------------------------------------------------------------------

UPDATE_REPO = "josbez/claude-usage"
UPDATE_API_URL = f"https://api.github.com/repos/{UPDATE_REPO}/releases/latest"
UPDATE_CHECK_INTERVAL_SEC = 24 * 3600
UPDATE_STATE_FILE = os.path.expanduser("~/.claude/usage-tracker-update.json")
BUNDLE_ID = "com.jos.claude-usage"
DMG_ASSET = "ClaudeUsage.dmg"
SIG_ASSET = DMG_ASSET + ".sig"

# Ed25519 public key for release signatures. The private key lives only on the
# release machine (~/.config/claude-usage/release-signing-key.pem), never in git.
UPDATE_PUBLIC_KEY_HEX = "cd50f6dc348c4c0b3170df3c4204cb6b7adabb92c11a798116127c02d207cc66"


def parse_version(s: str):
    """'v1.10.2' -> (1, 10, 2); anything else (pre-releases, 'dev') -> None."""
    if not isinstance(s, str):
        return None
    s = s.strip()
    if s[:1] in ("v", "V"):
        s = s[1:]
    parts = s.split(".")
    if not parts or not all(p.isdigit() for p in parts):
        return None
    nums = [int(p) for p in parts]
    while len(nums) > 1 and nums[-1] == 0:   # 1.2 == 1.2.0
        nums.pop()
    return tuple(nums)


def is_newer(candidate: str, current: str) -> bool:
    c, cur = parse_version(candidate), parse_version(current)
    return c is not None and cur is not None and c > cur


def parse_release(obj: dict):
    """Pick what we need from a GitHub releases/latest response, or None."""
    if not isinstance(obj, dict) or obj.get("draft") or obj.get("prerelease"):
        return None
    tag = obj.get("tag_name", "")
    if parse_version(tag) is None:
        return None
    assets = {a.get("name"): a.get("browser_download_url")
              for a in obj.get("assets") or [] if isinstance(a, dict)}
    return {
        "version": tag.lstrip("vV"),
        "html_url": obj.get("html_url", ""),
        "dmg_url": assets.get(DMG_ASSET, ""),
        "sig_url": assets.get(SIG_ASSET, ""),
    }


def update_check_due(state: dict, now: datetime,
                     interval_sec: int = UPDATE_CHECK_INTERVAL_SEC) -> bool:
    last = state.get("last_check")
    if not last:
        return True
    try:
        return (now - parse_dt(last)).total_seconds() >= interval_sec
    except Exception:
        return True


def sign_release(data: bytes, private_key) -> str:
    """Base64 Ed25519 signature over the whole file (used by sign-release.py)."""
    from Crypto.Signature import eddsa
    return base64.b64encode(eddsa.new(private_key, "rfc8032").sign(data)).decode()


def verify_release_signature(data: bytes, sig_text: str,
                             public_key_hex: str = UPDATE_PUBLIC_KEY_HEX) -> bool:
    from Crypto.Signature import eddsa
    try:
        key = eddsa.import_public_key(bytes.fromhex(public_key_hex))
        sig = base64.b64decode(sig_text.strip(), validate=True)
        eddsa.new(key, "rfc8032").verify(data, sig)
        return True
    except Exception:
        return False
