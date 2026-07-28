#!/usr/bin/env python3
"""
Fetches Claude plan usage limits via WKWebView (bypasses Cloudflare).
Saves result to ~/.claude/usage-limits.json
Run as: python3 fetch_limits.py
"""

import sqlite3, subprocess, base64, hashlib, json, time, os, shutil, tempfile, sys
from Crypto.Cipher import AES
from Foundation import (
    NSRunLoop, NSDate, NSURL, NSURLRequest, NSHTTPCookie,
    NSHTTPCookieDomain, NSHTTPCookieName, NSHTTPCookiePath,
    NSHTTPCookieValue, NSHTTPCookieSecure,
)
from AppKit import NSApplication, NSApp
from WebKit import WKWebView, WKWebViewConfiguration, WKWebsiteDataStore

OUTPUT_FILE = os.path.expanduser("~/.claude/usage-limits.json")


def decrypt_claude_cookies():
    key_str = subprocess.run(
        ["security", "find-generic-password", "-s", "Claude Safe Storage", "-w"],
        capture_output=True, text=True,
    ).stdout.strip()
    if not key_str:
        return {}

    key = hashlib.pbkdf2_hmac("sha1", key_str.encode(), b"saltysalt", 1003, dklen=16)
    base = os.path.expanduser("~/Library/Application Support/Claude")
    src = next((p for p in (os.path.join(base, "Cookies"),
                            os.path.join(base, "Network", "Cookies"))
                if os.path.exists(p)), None)
    if not src:
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

    session_key = cookies.get("sessionKey", {}).get("value", "")
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
    js = """
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
            window.__usage_result = JSON.stringify({ok: true, org_id: best.org_id, account_email: best.account_email, data: best.data});
        } else {
            window.__usage_result = JSON.stringify({ok: false, error: 'no org with usage data'});
        }
    })
    .catch(e => { window.__usage_result = JSON.stringify({ok: false, error: e.message}); });
    'fired';
    """

    eval_js(webview, js)

    raw = poll_window_var(webview, "__usage_result", timeout=35)
    if raw is None or str(raw) == "<null>":
        print("ERROR: timeout waiting for usage data", file=sys.stderr)
        sys.exit(1)

    parsed = json.loads(str(raw))
    if not parsed.get("ok"):
        print(f"ERROR: {parsed.get('error')}", file=sys.stderr)
        sys.exit(1)

    import datetime
    output = {
        "fetched_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "org_id": parsed["org_id"],
        "account_email": parsed.get("account_email", ""),
        **parsed["data"],
    }

    with open(OUTPUT_FILE, "w") as f:
        json.dump(output, f, indent=2)

    print(json.dumps(output, indent=2))


if __name__ == "__main__":
    main()
