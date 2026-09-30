#!/usr/bin/env python3
"""
Fetches Claude plan usage limits via WKWebView (bypasses Cloudflare).
Saves result to ~/.claude/usage-limits.json
Run as: python3 fetch_limits.py
"""

import json, time, os, sys
from Foundation import (
    NSRunLoop, NSDate, NSURL, NSURLRequest, NSHTTPCookie,
    NSHTTPCookieDomain, NSHTTPCookieName, NSHTTPCookiePath,
    NSHTTPCookieValue, NSHTTPCookieSecure,
)
from AppKit import NSApplication, NSApp
from WebKit import WKWebView, WKWebViewConfiguration, WKWebsiteDataStore

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from core import (  # noqa: E402
    LIMITS_FILE, decrypt_claude_cookies, session_key_from, build_fetch_js, limits_output,
)


def run_loop(s):
    NSRunLoop.currentRunLoop().runUntilDate_(NSDate.dateWithTimeIntervalSinceNow_(s))


def eval_js(webview, js, timeout=5.0):
    """Evaluate JS that returns a simple value (string/number/None)."""
    result = [None]
    done = [False]

    def cb(r, e):
        result[0] = r
        done[0] = True

    webview.evaluateJavaScript_completionHandler_(js, cb)
    start = time.time()
    while not done[0] and time.time() - start < timeout:
        run_loop(0.1)
    return result[0]


def poll_window_var(webview, var_name, timeout=20.0):
    """Poll window.var_name until it's set (non-null, non-NSNull)."""
    start = time.time()
    while time.time() - start < timeout:
        run_loop(0.5)
        val = eval_js(webview, f"window.{var_name} || null")
        # NSNull comes back as an ObjC object, not Python None
        if val is not None and type(val).__name__ != "NSNull" and str(val) != "<null>":
            return str(val)
    return None


def main():
    NSApplication.sharedApplication()
    NSApp.setActivationPolicy_(1)  # accessory

    cookies = decrypt_claude_cookies()
    if not cookies:
        print("ERROR: Claude app cookies not found", file=sys.stderr)
        sys.exit(1)

    session_key = session_key_from(cookies)
    if not session_key:
        print("ERROR: sessionKey not found", file=sys.stderr)
        sys.exit(1)

    # Use non-persistent (isolated) WebKit store
    config = WKWebViewConfiguration.new()
    config.setWebsiteDataStore_(WKWebsiteDataStore.nonPersistentDataStore())

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

    webview = WKWebView.alloc().initWithFrame_configuration_(((0, 0), (1, 1)), config)
    webview.loadRequest_(
        NSURLRequest.requestWithURL_(NSURL.URLWithString_("https://claude.ai/"))
    )

    # Wait for page load
    start = time.time()
    while time.time() - start < 20:
        run_loop(0.3)
        if not webview.isLoading():
            break

    run_loop(1.5)

    # Fetch account info + all org usage limits, pick org with highest session utilization
    js = build_fetch_js("window.__usage_result = s;")

    eval_js(webview, js)

    raw = poll_window_var(webview, "__usage_result", timeout=35)
    if raw is None or str(raw) == "<null>":
        print("ERROR: timeout waiting for usage data", file=sys.stderr)
        sys.exit(1)

    parsed = json.loads(str(raw))
    if not parsed.get("ok"):
        print(f"ERROR: {parsed.get('error')}", file=sys.stderr)
        sys.exit(1)

    output = limits_output(parsed)

    with open(LIMITS_FILE, "w") as f:
        json.dump(output, f, indent=2)

    print(json.dumps(output, indent=2))


if __name__ == "__main__":
    main()
