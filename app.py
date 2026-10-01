#!/usr/bin/env python3
"""Claude Usage Tracker - macOS Menu Bar App (NSPopover + WKWebView)

Only PyObjC glue lives here; pure logic is in core.py (testable without AppKit).
"""

import objc
import json
import os
import sys
import tempfile
import threading
import time
import hashlib
from datetime import datetime, timezone

from Foundation import (
    NSObject, NSTimer, NSRunLoop, NSRunLoopCommonModes, NSURL, NSMakeRect, NSMakeSize,
    NSURLRequest, NSHTTPCookie, NSProcessInfo, NSBundle, NSLocale,
    NSHTTPCookieDomain, NSHTTPCookieName, NSHTTPCookiePath,
    NSHTTPCookieValue, NSHTTPCookieSecure,
)

# NSProcessInfo.h: disables App Nap for this process without blocking system
# idle sleep. Without this, macOS throttles/suspends our background NSTimer
# (menu bar accessory app, no visible window) after a few minutes.
NS_ACTIVITY_USER_INITIATED_ALLOWING_IDLE_SYSTEM_SLEEP = 0x00FFFFFF
from AppKit import (
    NSBitmapImageRep, NSGraphicsContext, NSBezierPath, NSColor, NSFont,
    NSAttributedString, NSFontAttributeName, NSDeviceRGBColorSpace,
    NSApplication, NSApplicationActivationPolicyAccessory,
    NSStatusBar, NSVariableStatusItemLength, NSMinYEdge,
    NSViewController, NSWorkspace, NSPopover, NSAlert,
    NSApp, NSAppearance, NSAppearanceNameAqua, NSAppearanceNameDarkAqua,
)
from PyObjCTools import AppHelper
from WebKit import (
    WKWebView, WKWebViewConfiguration, WKUserContentController,
    WKWebsiteDataStore,
)

from UserNotifications import (
    UNUserNotificationCenter, UNMutableNotificationContent, UNNotificationRequest,
    UNNotificationAttachment,
    UNNotificationSound, UNAuthorizationOptionAlert, UNAuthorizationOptionSound,
    UNNotificationPresentationOptionBanner, UNNotificationPresentationOptionList,
    UNNotificationPresentationOptionSound,
)

from core import (
    LIMITS_FILE, log, find_cookie_db, decrypt_claude_cookies, session_key_from,
    build_fetch_js, limits_output, format_reset_time, format_reset_compact,
    status_title, title_from_limits, load_limits, limits_are_fresh, MENUBAR_STYLES,
    APPEARANCE_STYLES,
    due_notifications, load_notify_state, save_notify_state, color_for_pct, face_icon,
    account_label, week_window, week_progress, STRINGS, t, language_from,
    history_record, append_history,
    new_block_log_entries, load_block_log_state, save_block_log_state,
    load_settings, save_settings,
    service_status, is_status_url, status_badge_class, STATUS_CHECK_INTERVAL_SEC,
    limit_resets_view, cedar_ember_unrecognised, cedar_ember_stable, RESETS_URL,
    UPDATE_STATE_FILE, load_json, save_json, is_newer, update_check_due,
)
import updater


SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
FETCH_TIMEOUT_SEC = 45.0
POPOVER_MIN_HEIGHT = 296      # main view; fixed
POPOVER_MAX_HEIGHT = 420      # settings view may grow up to this

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
        elif name == "setNotifications":
            if self.delegate:
                self.delegate.set_notifications_enabled(bool(message.body()))
        elif name == "setMenubarStyle":
            if self.delegate:
                self.delegate.set_menubar_style(str(message.body()))
        elif name == "setAppearance":
            if self.delegate:
                self.delegate.set_appearance(str(message.body()))
        elif name == "startUpdate":
            if self.delegate:
                self.delegate.start_update()
        elif name == "resize":
            if self.delegate:
                self.delegate.set_popover_height(message.body())
        elif name == "openResetsPage":
            if self.delegate:
                self.delegate.open_resets_page()
        elif name == "openStatusPage":
            if self.delegate:
                self.delegate.open_status_page(str(message.body()))
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


NS_BITMAP_PNG = 4          # NSBitmapImageFileTypePNG
NS_LINE_CAP_ROUND = 1      # NSLineCapStyleRound


def _ns_rgb(rgb, mix_with_white: float = 0.0):
    r, g, b = (c / 255 for c in rgb)
    w = mix_with_white
    return NSColor.colorWithDeviceRed_green_blue_alpha_(
        r + (1 - r) * w, g + (1 - g) * w, b + (1 - b) * w, 1.0)


def render_status_image(pct: int, path: str, size: int = 256):
    """Draw the popover's session donut as a PNG: ring filled to pct, stress
    colour, menu bar emoji in the centre. Used as notification thumbnail."""
    rep = NSBitmapImageRep.alloc().initWithBitmapDataPlanes_pixelsWide_pixelsHigh_bitsPerSample_samplesPerPixel_hasAlpha_isPlanar_colorSpaceName_bytesPerRow_bitsPerPixel_(
        None, size, size, 8, 4, True, False, NSDeviceRGBColorSpace, 0, 0)
    color = color_for_pct(pct)
    NSGraphicsContext.saveGraphicsState()
    try:
        NSGraphicsContext.setCurrentContext_(
            NSGraphicsContext.graphicsContextWithBitmapImageRep_(rep))

        # Tinted tile, like .card-session (stress colour 14% over white)
        _ns_rgb(color, 0.86).setFill()
        radius = size * 0.22
        NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(
            ((0, 0), (size, size)), radius, radius).fill()

        center = (size / 2, size / 2)
        ring_r = size * 0.34
        line = size * 0.1

        track = NSBezierPath.bezierPath()
        track.appendBezierPathWithArcWithCenter_radius_startAngle_endAngle_(
            center, ring_r, 0, 360)
        track.setLineWidth_(line)
        _ns_rgb(color, 0.70).setStroke()
        track.stroke()

        fill = max(0, min(100, pct))
        if fill > 0:
            arc = NSBezierPath.bezierPath()
            # y-up coordinates: 90° is 12 o'clock, clockwise like the popover
            arc.appendBezierPathWithArcWithCenter_radius_startAngle_endAngle_clockwise_(
                center, ring_r, 90, 90 - 360 * fill / 100, True)
            arc.setLineWidth_(line)
            arc.setLineCapStyle_(NS_LINE_CAP_ROUND)
            _ns_rgb(color).setStroke()
            arc.stroke()

        face = NSAttributedString.alloc().initWithString_attributes_(
            face_icon(pct), {NSFontAttributeName: NSFont.systemFontOfSize_(size * 0.42)})
        w, h = face.size()
        face.drawAtPoint_((center[0] - w / 2, center[1] - h / 2))
    finally:
        NSGraphicsContext.restoreGraphicsState()

    png = rep.representationUsingType_properties_(NS_BITMAP_PNG, {})
    png.writeToFile_atomically_(path, True)


def current_language() -> str:
    return language_from(NSLocale.preferredLanguages())


def app_version():
    """(short version, build) from the bundle's Info.plist; ('dev', '') outside it."""
    if not getattr(sys, "frozen", False):
        return "dev", ""
    info = NSBundle.mainBundle().infoDictionary()
    return (str(info.get("CFBundleShortVersionString", "dev")),
            str(info.get("CFBundleVersion", "")))


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
        self._pending_title = None     # menu bar title held back while popover is open
        self._logged_week_windows = set()
        self._update = None            # latest release dict when newer than us
        self._update_checking = False  # release check running on a thread
        self._update_installing = False
        self._update_error = None
        self._service = None           # service_status() result; {"level": "unreachable"} on network error
        self._service_checking = False
        self._service_checked_at = None   # time.monotonic() of the last status check
        self._logged_unknown_status = set()
        self._version, self._build = app_version()
        self._lang = current_language()
        log(f"app gestart (versie {self._version}, taal {self._lang})")
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
        self._maybe_check_updates()
        self._maybe_check_service_status()
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

    def _status_attachment(self, note: dict):
        """Thumbnail with ring/colour/emoji for this limit. The system moves
        the file into its own store, so each notification gets a fresh one."""
        try:
            fd, path = tempfile.mkstemp(prefix="claudeusage-", suffix=".png")
            os.close(fd)
            render_status_image(note["pct"], path)
            attachment, error = UNNotificationAttachment.attachmentWithIdentifier_URL_options_error_(
                "status", NSURL.fileURLWithPath_(path), None, None)
            if error is not None:
                log(f"notificatie-afbeelding mislukt: {error}")
            return attachment
        except Exception as e:
            log(f"notificatie-afbeelding mislukt: {e}")
            return None

    def _record_history(self, limits: dict):
        """Our own usage history (the API keeps none). Never let it break a fetch."""
        try:
            append_history(history_record(limits))
        except Exception as e:
            log(f"geschiedenis opslaan mislukt: {e}")

    def _log_block_reasons(self, parsed: dict, limits: dict):
        """Log any new block reasons (locked_reason and bootstrap fields).
        Never let it break a fetch."""
        try:
            bootstrap_fields = parsed.get("bootstrap_fields") or {}
            account = limits.get("account_email", "")
            if not account:
                return
            seen = load_block_log_state()
            entries, seen = new_block_log_entries(limits, bootstrap_fields, account, seen)
            for entry in entries:
                log(entry)
            if entries:
                save_block_log_state(seen)
        except Exception as e:
            log(f"blokkadevelden loggen mislukt: {e}")

    def _post_notification(self, ident: str, title: str, body: str):
        if self._notify_center is None or not load_settings()["notifications"]:
            return
        content = UNMutableNotificationContent.new()
        content.setTitle_(title)
        content.setBody_(body)
        content.setSound_(UNNotificationSound.defaultSound())
        request = UNNotificationRequest.requestWithIdentifier_content_trigger_(ident, content, None)
        self._notify_center.addNotificationRequest_withCompletionHandler_(
            request, _log_notify_error(ident))

    def _notify_limits(self, limits: dict):
        if self._notify_center is None:
            return
        try:
            notes, state = due_notifications(limits, load_notify_state(), lang=self._lang)
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
                attachment = self._status_attachment(note)
                if attachment is not None:
                    content.setAttachments_([attachment])
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
    # Updates (network/disk work on a thread, UI back on the main thread)
    # ------------------------------------------------------------------

    def _maybe_check_updates(self, force: bool = False):
        if not getattr(sys, "frozen", False) or self._update_checking or self._update_installing:
            return
        if not load_settings()["update_check"]:
            return
        state = load_json(UPDATE_STATE_FILE)
        latest = state.get("latest")
        if self._update is None and latest and is_newer(latest.get("version", ""), self._version):
            self._update = latest   # remembered from an earlier check, no network needed
        if not force and not update_check_due(state, datetime.now(timezone.utc)):
            return
        self._update_checking = True

        def work():
            try:
                AppHelper.callAfter(self._on_update_checked, updater.fetch_latest_release(), None)
            except Exception as e:
                AppHelper.callAfter(self._on_update_checked, None, str(e))

        threading.Thread(target=work, daemon=True).start()

    # ------------------------------------------------------------------
    # Claude service status (separate from the usage fetch, so an outage
    # at Claude never blocks it)
    # ------------------------------------------------------------------

    def _maybe_check_service_status(self):
        if self._service_checking:
            return
        last = self._service_checked_at
        if last is not None and time.monotonic() - last < STATUS_CHECK_INTERVAL_SEC:
            return
        self._service_checking = True
        self._service_checked_at = time.monotonic()

        def work():
            try:
                summary = updater.fetch_status_summary()
                AppHelper.callAfter(self._on_service_status, summary, None)
            except Exception as e:
                AppHelper.callAfter(self._on_service_status, None, str(e))

        threading.Thread(target=work, daemon=True).start()

    def _on_service_status(self, summary, error):
        self._service_checking = False
        if error:
            log(f"claude-status ophalen mislukt: {error}")
            self._service = {"level": "unreachable"}
        else:
            parsed = service_status(summary)
            if parsed is None:
                log("claude-status: onbruikbare respons")
                self._service = {"level": "unreachable"}
            else:
                for value in parsed["unknown"]:
                    if value not in self._logged_unknown_status:
                        self._logged_unknown_status.add(value)
                        log(f"claude-status: onbekende waarde {value}")
                self._service = parsed
        self._push_data()

    def set_popover_height(self, height):
        """The settings view asks for more room than the 296 px main view."""
        try:
            h = max(POPOVER_MIN_HEIGHT, min(POPOVER_MAX_HEIGHT, int(height)))
        except (TypeError, ValueError):
            return
        size = self.popover.contentSize()
        if int(size.height) != h:
            self.popover.setContentSize_(NSMakeSize(360, h))

    def open_resets_page(self):
        # Fixed URL, no argument from the page: opening is all the app ever does here.
        NSWorkspace.sharedWorkspace().openURL_(NSURL.URLWithString_(RESETS_URL))

    def _log_cedar_ember(self, limits: dict):
        """Log the real cedar_ember shape once per change, and any shape we don't know."""
        try:
            account = limits.get("account_email", "")
            state = load_block_log_state()
            if cedar_ember_unrecognised(limits):
                key = f"{account}|cedar_ember_shape"
                digest = hashlib.sha1(json.dumps(limits.get("cedar_ember"), sort_keys=True,
                                                 default=str).encode("utf-8")).hexdigest()
                if state.get(key) != digest:
                    state[key] = digest
                    log(f"cedar_ember: onbekende vorm: {str(limits.get('cedar_ember'))[:300]}")
                    save_block_log_state(state)
                return
            stable = cedar_ember_stable(limits)
            if stable is None:
                return
            key = f"{account}|cedar_ember"
            raw = json.dumps(stable, sort_keys=True, ensure_ascii=False)
            digest = hashlib.sha1(raw.encode("utf-8")).hexdigest()
            if state.get(key) != digest:
                state[key] = digest
                log(f"cedar_ember: {raw}")
                save_block_log_state(state)
        except Exception as e:
            log(f"cedar_ember loggen mislukt: {e}")

    def open_status_page(self, url: str):
        if not is_status_url(url):
            log(f"claude-status: link geweigerd: {url[:80]}")
            return
        NSWorkspace.sharedWorkspace().openURL_(NSURL.URLWithString_(url))

    def _on_update_checked(self, release, error):
        self._update_checking = False
        state = load_json(UPDATE_STATE_FILE)
        state["last_check"] = datetime.now(timezone.utc).isoformat()
        if error:
            log(f"update-check mislukt: {error}")
        else:
            state["latest"] = release
            if release and is_newer(release["version"], self._version):
                self._update = release
                if state.get("notified_version") != release["version"]:
                    state["notified_version"] = release["version"]
                    log(f"update beschikbaar: {release['version']}")
                    self._post_notification(
                        f"update-{release['version']}",
                        t("notif_update_title", self._lang, version=release["version"]),
                        t("notif_update_body", self._lang),
                    )
            else:
                self._update = None
        try:
            save_json(state, UPDATE_STATE_FILE)
        except Exception as e:
            log(f"update-status opslaan mislukt: {e}")
        self._push_data()

    def _update_view(self):
        if self._update is None:
            return None
        if self._update_installing:
            state = "working"
        elif self._update_error:
            state = "error"
        else:
            state = "available"
        return {"version": self._update["version"], "state": state,
                "message": self._update_error or ""}

    def start_update(self):
        release = self._update
        if release is None or self._update_installing:
            return
        NSApp.activateIgnoringOtherApps_(True)
        alert = NSAlert.new()
        lang = self._lang
        alert.setMessageText_(t("alert_install_title", lang, version=release["version"]))
        alert.setInformativeText_(t("alert_install_body", lang, current=self._version))
        alert.addButtonWithTitle_(t("btn_update", lang))
        alert.addButtonWithTitle_(t("btn_later", lang))
        if release.get("html_url"):
            alert.addButtonWithTitle_(t("btn_whats_new", lang))
        choice = alert.runModal()
        if choice == 1002:   # NSAlertThirdButtonReturn
            NSWorkspace.sharedWorkspace().openURL_(NSURL.URLWithString_(release["html_url"]))
            return
        if choice != 1000:   # NSAlertFirstButtonReturn
            return

        log(f"update naar {release['version']} gestart")
        self._update_installing = True
        self._update_error = None
        self._push_data()
        current = self._version

        def work():
            try:
                AppHelper.callAfter(self._on_update_staged,
                                    updater.download_and_stage(release, current), None)
            except updater.UpdateError as e:
                AppHelper.callAfter(self._on_update_staged, None, e)
            except Exception as e:
                AppHelper.callAfter(self._on_update_staged, None,
                                    updater.UpdateError("unexpected", detail=e))

        threading.Thread(target=work, daemon=True).start()

    def _on_update_staged(self, staged, error):
        """error is an updater.UpdateError (translated for the user, Dutch in the log)."""
        if error:
            message = error.message(self._lang)
            self._update_installing = False
            self._update_error = message
            log(f"update mislukt: {error}")
            self._push_data()
            NSApp.activateIgnoringOtherApps_(True)
            alert = NSAlert.new()
            alert.setMessageText_(t("alert_failed_title", self._lang))
            alert.setInformativeText_(t("alert_failed_body", self._lang, error=message))
            alert.runModal()
            return
        target = str(NSBundle.mainBundle().bundlePath())
        log(f"update klaargezet, vervangen van {target} en herstarten")
        try:
            updater.launch_swap(staged, target, os.getpid())
        except Exception as e:
            self._on_update_staged(None, updater.UpdateError("install", detail=e))
            return
        NSApp.terminate_(None)

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

    def _menubar_style(self) -> str:
        return load_settings()["menubar_style"]

    def set_menubar_style(self, style: str):
        if style not in MENUBAR_STYLES:
            return
        settings = load_settings()
        settings["menubar_style"] = style
        try:
            save_settings(settings)
            log(f"menubalkweergave: {style}")
        except Exception as e:
            log(f"instelling opslaan mislukt: {e}")
        if not self._fetching:
            self._show_cached_pct()
        self._push_data()

    def _appearance(self) -> str:
        return load_settings()["appearance"]

    def set_appearance(self, appearance: str):
        if appearance not in APPEARANCE_STYLES:
            return
        settings = load_settings()
        settings["appearance"] = appearance
        try:
            save_settings(settings)
            log(f"weergave: {appearance}")
        except Exception as e:
            log(f"instelling opslaan mislukt: {e}")
        self._apply_appearance()
        self._push_data()

    def _apply_appearance(self):
        """Set the popover's appearance based on the current setting."""
        appearance_name = self._appearance()
        if appearance_name == "light":
            app_appearance = NSAppearance.appearanceNamed_(NSAppearanceNameAqua)
        elif appearance_name == "dark":
            app_appearance = NSAppearance.appearanceNamed_(NSAppearanceNameDarkAqua)
        else:
            app_appearance = None
        if self.popover:
            self.popover.setAppearance_(app_appearance)

    def _set_status_title(self, text: str):
        # The popover hangs off the middle of the status item: changing the
        # title width while it's open makes it jump. Hold the new title until
        # the popover closes (the popover itself shows live data meanwhile).
        popover = getattr(self, "popover", None)
        if popover is not None and popover.isShown():
            self._pending_title = text
            return
        self.statusItem.button().setTitle_(text)

    def popoverDidClose_(self, notification):
        # The next open starts on the main view: back to its fixed height now,
        # so the popover doesn't appear tall and then shrink.
        self.set_popover_height(POPOVER_MIN_HEIGHT)
        if self._pending_title is not None:
            self.statusItem.button().setTitle_(self._pending_title)
            self._pending_title = None

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
        self.popover.setDelegate_(self)  # popoverDidClose_ applies a held-back title

        config = WKWebViewConfiguration.new()
        ucc = WKUserContentController.new()
        config.setUserContentController_(ucc)

        handler = MessageHandler.new()
        handler.delegate = self
        ucc.addScriptMessageHandler_name_(handler, "refresh")
        ucc.addScriptMessageHandler_name_(handler, "quit")
        ucc.addScriptMessageHandler_name_(handler, "setNotifications")
        ucc.addScriptMessageHandler_name_(handler, "startUpdate")
        ucc.addScriptMessageHandler_name_(handler, "setMenubarStyle")
        ucc.addScriptMessageHandler_name_(handler, "setAppearance")
        ucc.addScriptMessageHandler_name_(handler, "openStatusPage")
        ucc.addScriptMessageHandler_name_(handler, "openResetsPage")
        ucc.addScriptMessageHandler_name_(handler, "resize")

        self.webView = WKWebView.alloc().initWithFrame_configuration_(
            NSMakeRect(0, 0, 360, 296), config
        )

        # Bundle: Resources/dashboard.html (setup.py flattens it); source run: dev/.
        html_path = os.path.join(SCRIPT_DIR, "dashboard.html")
        if not os.path.exists(html_path):
            html_path = os.path.join(SCRIPT_DIR, "dev", "dashboard.html")
        url = NSURL.fileURLWithPath_(html_path)
        self.webView.loadFileURL_allowingReadAccessToURL_(
            url, NSURL.fileURLWithPath_(SCRIPT_DIR)
        )

        vc = NSViewController.new()
        vc.setView_(self.webView)
        self.popover.setContentViewController_(vc)
        self._apply_appearance()

    def togglePopover_(self, sender):
        if self.popover.isShown():
            self.popover.performClose_(sender)
        else:
            btn = self.statusItem.button()
            self.popover.showRelativeToRect_ofView_preferredEdge_(
                btn.bounds(), btn, NSMinYEdge
            )
            self._lang = current_language()
            self._check_account_switch()
            self._maybe_check_updates()
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
        # Emoji-only style stays emoji-only while fetching; others show "…"
        self._set_status_title(icon if self._menubar_style() == "emoji" else f"{icon} …")
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
            self._set_status_title(
                title_from_limits(load_limits(), self._menubar_style(), self._lang))
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
                with open(LIMITS_FILE, "w", encoding="utf-8") as f:
                    json.dump(output, f, indent=2)
                self._last_fetch_error = None
                self._record_history(output)
                self._log_block_reasons(parsed, output)
                self._log_cedar_ember(output)
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
            self._set_status_title(
                status_title(session_pct, weekly_pct, reset_compact, self._menubar_style()))
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

        lang = self._lang
        session_reset = format_reset_time(five_h.get("resets_at", ""), lang)
        session_reset_compact = format_reset_compact(five_h.get("resets_at", ""), lang)
        weekly_reset = format_reset_time(seven_d.get("resets_at", ""), lang)

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
                    last_updated = t("ago_now", lang)
                elif diff_m == 1:
                    last_updated = t("ago_one_min", lang)
                else:
                    last_updated = t("ago_min", lang, n=diff_m)
            except Exception:
                last_updated = ""

        status = "ok"
        status_reason = ""
        if not self._logged_in:
            status = "not_logged_in"
            status_reason = t("reason_not_logged_in", lang)
        elif self._last_fetch_error:
            status = "stale"
            status_reason = (t("reason_failed_at", lang, time=fetched_hhmm) if fetched_hhmm
                             else t("reason_failed", lang))
        elif age_minutes is None:
            status = "stale"
            status_reason = t("reason_not_fetched", lang)
        elif age_minutes > 15:
            status = "stale"
            status_reason = (t("reason_data_at", lang, time=fetched_hhmm) if fetched_hhmm
                             else t("reason_stale", lang))

        return {
            "session_pct": int(session_pct),
            "session_reset": session_reset,
            "session_reset_compact": session_reset_compact,
            "weekly_pct": int(weekly_pct),
            "weekly_reset": weekly_reset,
            "account": limits.get("account_email", ""),
            "account_label": account_label(limits),
            "week_progress": self._week_progress(limits),
            "fetching": self._fetching,
            "last_updated": last_updated,
            "status": status,
            "status_reason": status_reason,
            "notifications_enabled": load_settings()["notifications"],
            "notifications_available": self._notify_center is not None,
            "version": self._version,
            "build": self._build,
            "update": self._update_view(),
            "limit_resets": limit_resets_view(limits, datetime.now(timezone.utc), lang),
            "service": self._service,
            "service_badge": status_badge_class(self._service),
            "menubar_style": load_settings()["menubar_style"],
            "appearance": load_settings()["appearance"],
            "lang": lang,
            "i18n": STRINGS[lang],
            "menubar_previews": {
                style: status_title(int(session_pct), int(weekly_pct), session_reset_compact, style)
                for style in MENUBAR_STYLES
            },
        }

    def _week_progress(self, limits: dict):
        win = week_window(limits)
        if win is not None and win[2]:
            key = win[1].isoformat()
            if key not in self._logged_week_windows:
                self._logged_week_windows.add(key)
                log(f"weekvenster wijkt af van 7 dagen: {win[0].isoformat()} → {key}")
        return week_progress(limits, datetime.now(timezone.utc))

    def _push_status(self, status: str):
        js = f"if(window.setStatus) window.setStatus('{status}')"
        self.webView.evaluateJavaScript_completionHandler_(js, None)

    def tickFired_(self, timer):
        self._check_account_switch()
        self._maybe_check_updates()
        self._maybe_check_service_status()
        limits = load_limits()
        if not limits_are_fresh(limits):
            self._start_fetch()
        elif self.popover.isShown():
            self._push_data()
        else:
            try:
                self._set_status_title(
                    title_from_limits(limits, self._menubar_style(), self._lang))
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
