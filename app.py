#!/usr/bin/env python3
"""Claude Usage Tracker - macOS Menu Bar App (NSPopover + WKWebView)"""

import objc
import json
import os
import glob
import sqlite3
import shutil
import tempfile
import hashlib
from datetime import datetime, timezone, timedelta, date
from collections import defaultdict

from Crypto.Cipher import AES
from Foundation import (
    NSObject, NSTimer, NSRunLoop, NSRunLoopCommonModes, NSURL, NSMakeRect, NSMakeSize,
    NSURLRequest, NSHTTPCookie, NSProcessInfo,
    NSHTTPCookieDomain, NSHTTPCookieName, NSHTTPCookiePath,
    NSHTTPCookieValue, NSHTTPCookieSecure,
)

# NSProcessInfo.h: disables App Nap for this process without blocking system
# idle sleep. Without this, macOS throttles/suspends our background NSTimer
# (menu bar accessory app, no visible window) after a few minutes.
NS_ACTIVITY_USER_INITIATED_ALLOWING_IDLE_SYSTEM_SLEEP = 0x00FFFFFF
from AppKit import (
    NSApplication, NSApplicationActivationPolicyAccessory,
    NSStatusBar, NSVariableStatusItemLength, NSMinYEdge,
    NSViewController, NSWorkspace, NSPopover,
    NSApp,
)
from WebKit import (
    WKWebView, WKWebViewConfiguration, WKUserContentController,
    WKWebsiteDataStore,
)


STATS_CACHE = os.path.expanduser("~/.claude/stats-cache.json")
PROJECTS_DIR = os.path.expanduser("~/.claude/projects")
LIMITS_FILE = os.path.expanduser("~/.claude/usage-limits.json")
LOG_FILE = os.path.expanduser("~/Library/Logs/ClaudeUsage.log")
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
FETCH_TIMEOUT_SEC = 45.0
DAYS_NL = ["ma", "di", "wo", "do", "vr", "za", "zo"]
DAYS_NL_FULL = ["maandag", "dinsdag", "woensdag", "donderdag", "vrijdag", "zaterdag", "zondag"]

# JS that fetches usage from all orgs and posts the best result via message handler
FETCH_JS = """
(function() {
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
        window.webkit.messageHandlers.fetchResult.postMessage(
            JSON.stringify({ok: true, org_id: best.org_id,
                            account_email: best.account_email, data: best.data}));
    } else {
        window.webkit.messageHandlers.fetchResult.postMessage(
            JSON.stringify({ok: false, error: 'no org with usage data'}));
    }
})
.catch(e => {
    window.webkit.messageHandlers.fetchResult.postMessage(
        JSON.stringify({ok: false, error: e.message}));
});
})();
"""


# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

def log(msg: str):
    try:
        with open(LOG_FILE, "a") as f:
            f.write(f"{datetime.now().strftime('%Y-%m-%d %H:%M:%S')} {msg}\n")
    except Exception:
        pass


def find_cookie_db() -> str:
    """Return path to the Claude desktop app's cookie database, or ''.
    Newer Electron/Chromium versions moved Cookies into a Network subdir."""
    base = os.path.expanduser("~/Library/Application Support/Claude")
    for candidate in (os.path.join(base, "Cookies"),
                      os.path.join(base, "Network", "Cookies")):
        if os.path.exists(candidate):
            return candidate
    return ""


def decrypt_claude_cookies() -> dict:
    """Decrypt cookies from the Claude desktop app's Chromium cookie store."""
    import subprocess as _sp
    key_str = _sp.run(
        ["security", "find-generic-password", "-s", "Claude Safe Storage", "-w"],
        capture_output=True, text=True,
    ).stdout.strip()
    if not key_str:
        log("cookie decrypt: geen 'Claude Safe Storage' sleutel in keychain")
        return {}

    key = hashlib.pbkdf2_hmac("sha1", key_str.encode(), b"saltysalt", 1003, dklen=16)
    src = find_cookie_db()
    if not src:
        log("cookie decrypt: cookie-database niet gevonden")
        return {}

    dst = tempfile.mktemp(suffix=".db")
    shutil.copy2(src, dst)
    try:
        conn = sqlite3.connect(dst)
        cur = conn.cursor()
        cur.execute("SELECT name, encrypted_value, host_key, path FROM cookies")
        rows = cur.fetchall()
        conn.close()
    finally:
        os.unlink(dst)

    def decrypt(enc_bytes, host):
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

    return {
        name: {"value": val, "domain": host, "path": path}
        for name, enc, host, path in rows
        if (val := decrypt(bytes(enc), host))
    }


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
        dt = datetime.fromisoformat(iso_str).astimezone()
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
        dt = datetime.fromisoformat(iso_str).astimezone()
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


def load_limits() -> dict:
    try:
        with open(LIMITS_FILE) as f:
            return json.load(f)
    except Exception:
        return {}


def limits_are_fresh(limits: dict, max_age_minutes: int = 5) -> bool:
    fetched = limits.get("fetched_at")
    if not fetched:
        return False
    try:
        dt = datetime.fromisoformat(fetched)
        age = datetime.now(timezone.utc) - dt
        return age.total_seconds() < max_age_minutes * 60
    except Exception:
        return False


def parse_dt(s: str) -> datetime:
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    return datetime.fromisoformat(s)


def load_stats_cache() -> dict:
    try:
        with open(STATS_CACHE) as f:
            return json.load(f)
    except Exception:
        return {}


def scan_jsonl_files() -> dict:
    daily: dict = defaultdict(lambda: {
        "msgs": 0, "input_tokens": 0, "output_tokens": 0, "cache_read": 0,
        "models": defaultdict(int),
    })
    for jsonl_path in glob.glob(os.path.join(PROJECTS_DIR, "*", "*.jsonl")):
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
    import time as _time
    now = _time.monotonic()
    if _scan_cache["data"] is None or now - _scan_cache["ts"] > max_age_sec:
        _scan_cache["data"] = scan_jsonl_files()
        _scan_cache["ts"] = now
    return _scan_cache["data"]


def build_stats() -> dict:
    cache = load_stats_cache()
    jsonl_daily = scan_jsonl_files_cached()

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


# ---------------------------------------------------------------------------
# PyObjC classes
# ---------------------------------------------------------------------------

class MessageHandler(NSObject):
    """Receives postMessage calls from JavaScript (both dashboard and fetch webviews)."""

    def userContentController_didReceiveScriptMessage_(self, controller, message):
        name = str(message.name())
        if name == "refresh":
            if self.delegate:
                self.delegate.trigger_refresh()
        elif name == "openSettings":
            NSWorkspace.sharedWorkspace().openURL_(
                NSURL.URLWithString_("https://claude.ai/settings")
            )
        elif name == "quit":
            NSApp.terminate_(None)
        elif name == "fetchResult":
            if self.delegate:
                self.delegate._on_fetch_result(str(message.body()))


class FetchNavDelegate(NSObject):
    """WKNavigationDelegate for the hidden fetch WebView."""

    def webView_didFinishNavigation_(self, webview, navigation):
        if self.delegate:
            self.delegate._on_fetch_page_loaded()

    def webView_didFailNavigation_withError_(self, webview, navigation, error):
        if self.delegate:
            self.delegate._on_fetch_failed()

    def webView_didFailProvisionalNavigation_withError_(self, webview, navigation, error):
        if self.delegate:
            self.delegate._on_fetch_failed()


class AppDelegate(NSObject):

    def applicationDidFinishLaunching_(self, notification):
        self._fetching = False
        self._fetch_webview = None
        self._fetch_nav_delegate = None
        self._watchdog = None
        self._logged_in = True
        self._last_fetch_error = None
        self._last_cookie_mtime = None
        self._last_session_hash = None
        log("app gestart")
        # Keep the process out of App Nap so the periodic timer below actually
        # keeps firing while backgrounded — without this, macOS throttles it
        # to a near-standstill after a few minutes since there's no visible window.
        self._activity = NSProcessInfo.processInfo().beginActivityWithOptions_reason_(
            NS_ACTIVITY_USER_INITIATED_ALLOWING_IDLE_SYSTEM_SLEEP,
            "periodieke Claude-usage-refresh",
        )
        self._setup_status_item()
        self._setup_popover()
        self._setup_fetch_webview()
        self._start_fetch()
        # Periodic timer every minute
        self._timer = self._schedule_timer(
            60.0, objc.selector(self.tickFired_, signature=b"v@:@"), True
        )

    # ------------------------------------------------------------------
    # Status item
    # ------------------------------------------------------------------

    def _setup_status_item(self):
        self.statusItem = NSStatusBar.systemStatusBar().statusItemWithLength_(
            NSVariableStatusItemLength
        )
        btn = self.statusItem.button()
        btn.setTitle_("🚀")
        btn.setTarget_(self)
        btn.setAction_(objc.selector(self.togglePopover_, signature=b"v@:@"))

    def _set_status_title(self, text: str):
        self.statusItem.button().setTitle_(text)

    def _schedule_timer(self, interval, selector, repeats):
        """Schedule on NSRunLoopCommonModes, not just the default mode — otherwise
        this timer pauses whenever the popover is open (event-tracking run loop mode),
        which can leave a fetch stuck _fetching=True forever with no error logged."""
        timer = NSTimer.timerWithTimeInterval_target_selector_userInfo_repeats_(
            interval, self, selector, None, repeats
        )
        NSRunLoop.currentRunLoop().addTimer_forMode_(timer, NSRunLoopCommonModes)
        return timer

    # ------------------------------------------------------------------
    # Dashboard popover
    # ------------------------------------------------------------------

    def _setup_popover(self):
        self.popover = NSPopover.new()
        self.popover.setContentSize_(NSMakeSize(360, 296))
        self.popover.setBehavior_(1)  # NSPopoverBehaviorTransient

        config = WKWebViewConfiguration.new()
        ucc = WKUserContentController.new()
        config.setUserContentController_(ucc)

        handler = MessageHandler.new()
        handler.delegate = self
        ucc.addScriptMessageHandler_name_(handler, "refresh")
        ucc.addScriptMessageHandler_name_(handler, "openSettings")
        ucc.addScriptMessageHandler_name_(handler, "quit")

        self.webView = WKWebView.alloc().initWithFrame_configuration_(
            NSMakeRect(0, 0, 360, 296), config
        )

        html_path = os.path.join(SCRIPT_DIR, "dashboard.html")
        url = NSURL.fileURLWithPath_(html_path)
        self.webView.loadFileURL_allowingReadAccessToURL_(
            url, NSURL.fileURLWithPath_(SCRIPT_DIR)
        )

        vc = NSViewController.new()
        vc.setView_(self.webView)
        self.popover.setContentViewController_(vc)

    def togglePopover_(self, sender):
        if self.popover.isShown():
            self.popover.performClose_(sender)
        else:
            btn = self.statusItem.button()
            self.popover.showRelativeToRect_ofView_preferredEdge_(
                btn.bounds(), btn, NSMinYEdge
            )
            self._check_account_switch()
            self._push_data(animated=True)

    # ------------------------------------------------------------------
    # Hidden fetch WebView (replaces subprocess)
    # ------------------------------------------------------------------

    def _setup_fetch_webview(self):
        """Create a hidden WKWebView with the Claude session cookie for API fetching."""
        try:
            cookies = decrypt_claude_cookies()
        except Exception as e:
            log(f"cookie decrypt mislukt: {e}")
            return

        session_key = cookies.get("sessionKey", {}).get("value", "")
        if not session_key:
            log("geen sessionKey gevonden — is de Claude desktop-app ingelogd?")
            self._logged_in = False
            return

        self._logged_in = True
        self._last_session_hash = hashlib.sha256(session_key.encode()).hexdigest()
        cookie_db = find_cookie_db()
        if cookie_db:
            try:
                self._last_cookie_mtime = os.path.getmtime(cookie_db)
            except OSError:
                pass

        config = WKWebViewConfiguration.new()
        config.setWebsiteDataStore_(WKWebsiteDataStore.nonPersistentDataStore())

        ucc = WKUserContentController.new()
        config.setUserContentController_(ucc)

        handler = MessageHandler.new()
        handler.delegate = self
        ucc.addScriptMessageHandler_name_(handler, "fetchResult")

        cookie_store = config.websiteDataStore().httpCookieStore()
        cookie = NSHTTPCookie.cookieWithProperties_({
            NSHTTPCookieDomain: ".claude.ai",
            NSHTTPCookieName: "sessionKey",
            NSHTTPCookiePath: "/",
            NSHTTPCookieValue: session_key,
            NSHTTPCookieSecure: "TRUE",
        })
        if cookie:
            cookie_store.setCookie_completionHandler_(cookie, None)

        nav_delegate = FetchNavDelegate.new()
        nav_delegate.delegate = self
        self._fetch_nav_delegate = nav_delegate  # keep strong reference

        self._fetch_webview = WKWebView.alloc().initWithFrame_configuration_(
            NSMakeRect(0, 0, 1, 1), config
        )
        self._fetch_webview.setNavigationDelegate_(nav_delegate)

    def _refresh_session_cookie(self):
        """Re-read the sessionKey (it rotates) and update the webview's cookie store."""
        try:
            cookies = decrypt_claude_cookies()
        except Exception as e:
            log(f"cookie refresh mislukt: {e}")
            return
        session_key = cookies.get("sessionKey", {}).get("value", "")
        if not session_key:
            self._logged_in = False
            return
        self._logged_in = True
        if self._fetch_webview is None:
            return
        cookie = NSHTTPCookie.cookieWithProperties_({
            NSHTTPCookieDomain: ".claude.ai",
            NSHTTPCookieName: "sessionKey",
            NSHTTPCookiePath: "/",
            NSHTTPCookieValue: session_key,
            NSHTTPCookieSecure: "TRUE",
        })
        if cookie:
            store = self._fetch_webview.configuration().websiteDataStore().httpCookieStore()
            store.setCookie_completionHandler_(cookie, None)

    def _check_account_switch(self):
        """Detect a sessionKey change (account switch in the desktop app) and
        refetch immediately instead of waiting for the 5-minute staleness window.
        Cookie-db mtime is a cheap first filter so we only decrypt when it moved."""
        cookie_db = find_cookie_db()
        if not cookie_db:
            return
        try:
            mtime = os.path.getmtime(cookie_db)
        except OSError:
            return
        if self._last_cookie_mtime is not None and mtime == self._last_cookie_mtime:
            return
        self._last_cookie_mtime = mtime

        try:
            cookies = decrypt_claude_cookies()
        except Exception as e:
            log(f"account-check: cookie decrypt mislukt: {e}")
            return

        session_key = cookies.get("sessionKey", {}).get("value", "")
        if not session_key:
            self._logged_in = False
            return
        self._logged_in = True

        session_hash = hashlib.sha256(session_key.encode()).hexdigest()
        if self._last_session_hash is not None and session_hash != self._last_session_hash:
            log("account gewisseld (sessionKey gewijzigd) — direct verversen")
            self._last_session_hash = session_hash
            self._start_fetch()
            return
        self._last_session_hash = session_hash

    def _start_fetch(self):
        if self._fetching:
            return
        if self._fetch_webview is None:
            # Try to set up (e.g. if cookie wasn't available at startup)
            self._setup_fetch_webview()
            if self._fetch_webview is None:
                return
        else:
            self._refresh_session_cookie()

        self._fetching = True
        cur_title = self.statusItem.button().title() or ""
        icon = cur_title.split(" ")[0] if cur_title else "🚀"
        self._set_status_title(f"{icon} …")
        self._push_status("fetching")

        # Watchdog: without this a fetch that never calls back leaves
        # _fetching True forever and blocks every future refresh.
        if self._watchdog:
            self._watchdog.invalidate()
        self._watchdog = self._schedule_timer(
            FETCH_TIMEOUT_SEC,
            objc.selector(self.fetchWatchdogFired_, signature=b"v@:@"),
            False,
        )

        url = NSURL.URLWithString_("https://claude.ai/")
        self._fetch_webview.loadRequest_(NSURLRequest.requestWithURL_(url))

    def fetchWatchdogFired_(self, timer):
        self._watchdog = None
        if self._fetching:
            log(f"fetch watchdog: geen resultaat binnen {int(FETCH_TIMEOUT_SEC)}s, reset")
            self._last_fetch_error = "time-out"
            self._fetching = False
            self._push_status("ready")
            self._show_cached_pct()

    def _cancel_watchdog(self):
        if self._watchdog:
            self._watchdog.invalidate()
            self._watchdog = None

    def _show_cached_pct(self):
        try:
            limits = load_limits()
            five_h = limits.get("five_hour") or {}
            seven_d = limits.get("seven_day") or {}
            session_pct = int(five_h.get("utilization", 0) or 0)
            weekly_pct = int(seven_d.get("utilization", 0) or 0)
            reset_compact = format_reset_compact(five_h.get("resets_at", ""))
            self._set_status_title(status_title(session_pct, weekly_pct, reset_compact))
        except Exception:
            self._set_status_title("🚀")

    def _on_fetch_page_loaded(self):
        """Navigation delegate callback: page loaded, inject fetch JS after short delay."""
        self._schedule_timer(
            1.5, objc.selector(self.injectFetchJs_, signature=b"v@:@"), False
        )

    def injectFetchJs_(self, timer):
        if self._fetch_webview:
            self._fetch_webview.evaluateJavaScript_completionHandler_(FETCH_JS, None)

    def _on_fetch_failed(self):
        self._cancel_watchdog()
        self._fetching = False
        log("fetch: pagina laden mislukt (navigatiefout)")
        self._last_fetch_error = "pagina laden mislukt"
        self._push_status("ready")
        self._show_cached_pct()

    def _on_fetch_result(self, raw):
        """Called when JS posts the fetch result via fetchResult message handler."""
        self._cancel_watchdog()
        try:
            parsed = json.loads(raw)
            if parsed.get("ok"):
                output = {
                    "fetched_at": datetime.now(timezone.utc).isoformat(),
                    "org_id": parsed["org_id"],
                    "account_email": parsed.get("account_email", ""),
                    **parsed["data"],
                }
                with open(LIMITS_FILE, "w") as f:
                    json.dump(output, f, indent=2)
                self._last_fetch_error = None
            else:
                error = parsed.get("error", "onbekende fout")
                log(f"fetch mislukt: {error}")
                self._last_fetch_error = error
        except Exception as e:
            log(f"fetch resultaat onleesbaar: {e}")
            self._last_fetch_error = "resultaat onleesbaar"

        self._fetching = False
        try:
            data = self._build_data()
            session_pct = data.get("session_pct", 0)
            weekly_pct = data.get("weekly_pct", 0)
            reset_compact = data.get("session_reset_compact", "—")
            self._set_status_title(status_title(session_pct, weekly_pct, reset_compact))
            js = f"if(window.updateData) window.updateData({json.dumps(data, ensure_ascii=False)})"
            self.webView.evaluateJavaScript_completionHandler_(js, None)
        except Exception as e:
            log(f"UI update mislukt: {e}")
            self._set_status_title("🚀")

    # ------------------------------------------------------------------
    # Data / UI
    # ------------------------------------------------------------------

    def trigger_refresh(self):
        self._start_fetch()

    def _push_data(self, animated: bool = False):
        try:
            data = self._build_data()
            fn = "openWithAnimation" if animated else "updateData"
            js = f"if(window.{fn}) window.{fn}({json.dumps(data, ensure_ascii=False)})"
            self.webView.evaluateJavaScript_completionHandler_(js, None)
        except Exception:
            pass

    def _build_data(self) -> dict:
        limits = load_limits()

        five_h = limits.get("five_hour") or {}
        seven_d = limits.get("seven_day") or {}

        session_pct = five_h.get("utilization", 0) or 0
        weekly_pct = seven_d.get("utilization", 0) or 0

        session_reset = format_reset_time(five_h.get("resets_at", ""))
        session_reset_compact = format_reset_compact(five_h.get("resets_at", ""))
        weekly_reset = format_reset_time(seven_d.get("resets_at", ""))

        fetched = limits.get("fetched_at", "")
        last_updated = ""
        age_minutes = None
        fetched_hhmm = ""
        if fetched:
            try:
                ft = datetime.fromisoformat(fetched).astimezone()
                now = datetime.now(ft.tzinfo)
                age_minutes = (now - ft).total_seconds() / 60
                fetched_hhmm = ft.strftime("%H:%M")
                diff_m = int(age_minutes)
                if diff_m < 1:
                    last_updated = "zojuist"
                elif diff_m == 1:
                    last_updated = "1 min geleden"
                else:
                    last_updated = f"{diff_m} min geleden"
            except Exception:
                last_updated = ""

        status = "ok"
        status_reason = ""
        if not self._logged_in:
            status = "not_logged_in"
            status_reason = "log in in de Claude desktop-app"
        elif self._last_fetch_error:
            status = "stale"
            status_reason = f"kon niet vernieuwen, data van {fetched_hhmm}" if fetched_hhmm else "kon niet vernieuwen"
        elif age_minutes is None:
            status = "stale"
            status_reason = "nog niet opgehaald"
        elif age_minutes > 15:
            status = "stale"
            status_reason = f"data van {fetched_hhmm}" if fetched_hhmm else "data verouderd"

        return {
            "session_pct": int(session_pct),
            "session_reset": session_reset,
            "session_reset_compact": session_reset_compact,
            "weekly_pct": int(weekly_pct),
            "weekly_reset": weekly_reset,
            "account": limits.get("account_email", ""),
            "fetching": self._fetching,
            "last_updated": last_updated,
            "status": status,
            "status_reason": status_reason,
        }

    def _push_status(self, status: str):
        js = f"if(window.setStatus) window.setStatus('{status}')"
        self.webView.evaluateJavaScript_completionHandler_(js, None)

    def tickFired_(self, timer):
        self._check_account_switch()
        limits = load_limits()
        if not limits_are_fresh(limits):
            self._start_fetch()
        elif self.popover.isShown():
            self._push_data()
        else:
            try:
                five_h = limits.get("five_hour") or {}
                seven_d = limits.get("seven_day") or {}
                session_pct = int(five_h.get("utilization", 0) or 0)
                weekly_pct = int(seven_d.get("utilization", 0) or 0)
                reset_compact = format_reset_compact(five_h.get("resets_at", ""))
                self._set_status_title(status_title(session_pct, weekly_pct, reset_compact))
            except Exception:
                pass


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    app = NSApplication.sharedApplication()
    app.setActivationPolicy_(NSApplicationActivationPolicyAccessory)
    delegate = AppDelegate.new()
    app.setDelegate_(delegate)
    app.run()


if __name__ == "__main__":
    main()
