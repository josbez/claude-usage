#!/usr/bin/env python3
"""Claude Usage Tracker - macOS Menu Bar App (NSPopover + WKWebView)

Only PyObjC glue lives here; pure logic is in core.py (testable without AppKit).
"""

import objc
import json
import os
import sys
import hashlib
from datetime import datetime

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

from UserNotifications import (
    UNUserNotificationCenter, UNMutableNotificationContent, UNNotificationRequest,
    UNNotificationSound, UNAuthorizationOptionAlert, UNAuthorizationOptionSound,
    UNNotificationPresentationOptionBanner, UNNotificationPresentationOptionList,
    UNNotificationPresentationOptionSound,
)

from core import (
    LIMITS_FILE, log, find_cookie_db, decrypt_claude_cookies, session_key_from,
    build_fetch_js, limits_output, format_reset_time, format_reset_compact,
    status_title, title_from_limits, load_limits, limits_are_fresh,
    due_notifications, load_notify_state, save_notify_state,
    load_settings, save_settings,
)


SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
FETCH_TIMEOUT_SEC = 45.0

FETCH_JS = build_fetch_js("window.webkit.messageHandlers.fetchResult.postMessage(s);")

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
        elif name == "setNotifications":
            if self.delegate:
                self.delegate.set_notifications_enabled(bool(message.body()))
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


def _log_notify_error(note_id: str):
    def on_added(error):
        if error:
            log(f"notificatie mislukt ({note_id}): {error}")
    return on_added


class NotificationDelegate(NSObject, protocols=[objc.protocolNamed("UNUserNotificationCenterDelegate")]):
    """Show banners even while the popover makes us the active app."""

    def userNotificationCenter_willPresentNotification_withCompletionHandler_(
        self, center, notification, handler
    ):
        handler(
            UNNotificationPresentationOptionBanner
            | UNNotificationPresentationOptionList
            | UNNotificationPresentationOptionSound
        )


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
        self._setup_notifications()
        self._setup_status_item()
        self._setup_popover()
        self._setup_fetch_webview()
        self._start_fetch()
        # Periodic timer every minute
        self._timer = self._schedule_timer(
            60.0, objc.selector(self.tickFired_, signature=b"v@:@"), True
        )

    # ------------------------------------------------------------------
    # Limit notifications
    # ------------------------------------------------------------------

    def _setup_notifications(self):
        """UNUserNotificationCenter needs a real bundle id; from a bare
        interpreter it raises, so notifications only work in the deployed app."""
        self._notify_center = None
        if not getattr(sys, "frozen", False):
            log("notificaties uit: niet als app-bundle gestart")
            return
        try:
            center = UNUserNotificationCenter.currentNotificationCenter()
            self._notify_delegate = NotificationDelegate.new()  # keep strong reference
            center.setDelegate_(self._notify_delegate)

            def on_auth(granted, error):
                log(f"notificatie-toestemming: {'ja' if granted else 'nee'}"
                    + (f" ({error})" if error else ""))

            center.requestAuthorizationWithOptions_completionHandler_(
                UNAuthorizationOptionAlert | UNAuthorizationOptionSound, on_auth
            )
            self._notify_center = center
        except Exception as e:
            log(f"notificaties setup mislukt: {e}")

    def set_notifications_enabled(self, enabled: bool):
        settings = load_settings()
        settings["notifications"] = enabled
        try:
            save_settings(settings)
            log(f"meldingen {'aan' if enabled else 'uit'}")
        except Exception as e:
            log(f"instelling opslaan mislukt: {e}")
        self._push_data()

    def _notify_limits(self, limits: dict):
        if self._notify_center is None:
            return
        try:
            notes, state = due_notifications(limits, load_notify_state())
            if not load_settings()["notifications"]:
                # Still record crossed thresholds, so switching back on
                # doesn't replay warnings for this window.
                for note in notes:
                    log(f"notificatie onderdrukt (meldingen uit): {note['title']}")
                notes = []
            for note in notes:
                content = UNMutableNotificationContent.new()
                content.setTitle_(note["title"])
                content.setBody_(note["body"])
                content.setSound_(UNNotificationSound.defaultSound())
                request = UNNotificationRequest.requestWithIdentifier_content_trigger_(
                    note["id"], content, None
                )

                self._notify_center.addNotificationRequest_withCompletionHandler_(
                    request, _log_notify_error(note["id"])
                )
                log(f"notificatie: {note['title']}")
            save_notify_state(state)
        except Exception as e:
            log(f"notificatie-check mislukt: {e}")

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
        ucc.addScriptMessageHandler_name_(handler, "setNotifications")

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

        session_key = session_key_from(cookies)
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
        session_key = session_key_from(cookies)
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

        session_key = session_key_from(cookies)
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
            self._set_status_title(title_from_limits(load_limits()))
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
                output = limits_output(parsed)
                with open(LIMITS_FILE, "w") as f:
                    json.dump(output, f, indent=2)
                self._last_fetch_error = None
                self._notify_limits(output)
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
            "notifications_enabled": load_settings()["notifications"],
            "notifications_available": self._notify_center is not None,
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
                self._set_status_title(title_from_limits(limits))
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
