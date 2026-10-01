#!/usr/bin/python3
"""Export what the Swift app shares with core.py (taak 35).

- swift/Resources/strings.json: STRINGS, DAYS and MONTHS — one source of truth
  for both stacks (tests/test_core.py checks it is up to date).
- swift/Resources/fetch.js: core._FETCH_JS_TEMPLATE (the usage fetch run inside
  claude.ai), with DELIVER still to be filled in by the app.
- swift/Tests/UsageCoreTests/Fixtures/core.json: inputs and the outputs
  core.py gives for them, at a fixed "now" and time zone. The Swift tests must
  reproduce every output exactly (parity is the acceptance criterion).

Run after changing STRINGS or the pure functions: /usr/bin/python3 scripts/swift-fixtures.py
"""

import hashlib
import json
import os
import sqlite3
import sys
import time
from datetime import datetime, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TZ = "Europe/Amsterdam"
NOW = "2026-10-01T10:00:00+00:00"

os.environ["TZ"] = TZ
time.tzset()
sys.path.insert(0, ROOT)
import core  # noqa: E402

STRINGS_PATH = os.path.join(ROOT, "swift", "Resources", "strings.json")
FETCH_JS_PATH = os.path.join(ROOT, "swift", "Resources", "fetch.js")
FIXTURES_DIR = os.path.join(ROOT, "swift", "Tests", "UsageCoreTests", "Fixtures")
FIXTURES_PATH = os.path.join(FIXTURES_DIR, "core.json")
COOKIE_DB_PATH = os.path.join(FIXTURES_DIR, "Cookies")

# Synthetic values only (same as tests/test_core.py) — never real cookies.
TEST_PASSWORD = "test-safe-storage-password"


def shared_strings() -> dict:
    return {"strings": core.STRINGS, "days": core.DAYS, "months": core.MONTHS,
            "default_lang": core.DEFAULT_LANG}


def write_json(path: str, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")


class _FixedNow(datetime):
    """core.py calls datetime.now(); pin it so fixtures are reproducible."""
    @classmethod
    def now(cls, tz=None):
        fixed = datetime.fromisoformat(NOW)
        return fixed.astimezone(tz) if tz else fixed.astimezone().replace(tzinfo=None)


RESET_INPUTS = [
    "",
    "garbage",
    "2026-10-01T12:30:00Z",               # in 2h30m
    "2026-10-01T10:45:30Z",               # in 45m
    "2026-10-01T10:00:20Z",               # under a minute
    "2026-10-01T14:59:59.871234+00:00",   # microseconds, offset
    "2026-10-02T09:59:00+00:00",          # just under 24h
    "2026-10-03T08:00:00Z",               # > 24h: weekday + time
    "2026-09-30T08:00:00Z",               # in the past
    "2026-10-01T10:00:00Z",               # exactly now
]

LIMITS_CASES = [
    {},
    {"five_hour": {"utilization": 45.7, "resets_at": "2026-10-01T12:10:00Z"},
     "seven_day": {"utilization": 82.0, "resets_at": "2026-10-05T07:00:00Z"}},
    {"five_hour": None, "seven_day": {"utilization": None, "resets_at": None}},
    {"seven_day": {"utilization": 10, "resets_at": "2026-10-05T07:00:00Z"},
     "seven_day_breakdown": {"window_started_at": "2026-09-28T07:00:00Z"}},
    {"seven_day": {"utilization": 10, "resets_at": "2026-10-05T07:00:00Z"},
     "seven_day_breakdown": {"window_started_at": "2026-09-29T07:00:00Z"}},
    {"seven_day": {"utilization": 10, "resets_at": "2026-10-05T07:00:00Z"},
     "seven_day_breakdown": {"window_started_at": "2026-10-06T07:00:00Z"}},
    {"seven_day": {"utilization": 10, "resets_at": "not a date"}},
    {"seven_day": {"utilization": 10, "resets_at": "2026-10-01T10:00:00Z"}},
    {"seven_day": {"utilization": 10, "resets_at": "2026-10-08T10:00:00Z"}},
    {"account_email": "user@example.com"},
    {"account_email": "user@example.com", "account_name": "  Sam  ", "account_plan": " Team ",
     "account_org": "  Example Org  "},
    {"account_email": None, "account_name": None, "account_plan": None, "account_org": None},
    {"fetched_at": "2026-10-01T09:57:00+00:00"},
    {"fetched_at": "2026-10-01T09:50:00+00:00"},
    {"fetched_at": "nonsense"},
]

GRANT = {"id": "g1", "label": "Launch week", "resets_total": 2, "resets_left": 2,
         "starts_at": "2026-09-20T00:00:00Z", "ends_at": "2026-10-22T21:59:00Z",
         "paused": False, "usable_now": True}

RESETS_CASES = [
    {},
    {"cedar_ember": "weird"},
    {"cedar_ember": {"eligible": True, "grants": "nope"}},
    {"cedar_ember": {"eligible": False, "grants": [GRANT]}},
    {"cedar_ember": {"eligible": True, "grants": [GRANT]}},
    {"cedar_ember": {"eligible": True, "grants": [dict(GRANT, resets_left=1, label="")]}},
    {"cedar_ember": {"eligible": True, "grants": [dict(GRANT, paused=True)]}},
    {"cedar_ember": {"eligible": True, "grants": [dict(GRANT, starts_at="2026-10-10T00:00:00Z")]}},
    {"cedar_ember": {"eligible": True, "grants": [dict(GRANT, ends_at="2026-09-30T00:00:00Z")]}},
    {"cedar_ember": {"eligible": True, "grants": [dict(GRANT, ends_at=None), dict(GRANT, id="g2", label="Bonus", resets_left=3, ends_at="2026-10-15T10:00:00Z")]}},
    {"cedar_ember": {"eligible": True, "grants": [dict(GRANT, resets_left=True)]}},
    {"cedar_ember": {"eligible": True, "grants": [dict(GRANT, resets_left=1.0)]}},
    {"cedar_ember": {"eligible": True, "grants": [dict(GRANT, ends_at="bad")]}},
    {"cedar_ember": {"grants": [dict(GRANT, ends_at=None, label="  ")]}},
]

SETTINGS_CASES = [
    {},
    {"notifications": False, "menubar_style": "emoji", "appearance": "dark"},
    {"menubar_style": "bogus", "appearance": "neon", "extra": 1},
    {"update_check": False},
    [],
]

SERVICE_CASES = [None, {}, {"level": "ok"}, {"level": "minor"}, {"level": "major"},
                 {"level": "critical"}, {"level": "unknown"}]

T_CASES = [
    ("app_title", {}),
    ("ago_min", {"n": 7}),
    ("in_hm", {"h": 2, "m": 5}),
    ("compact_hm", {"h": 2, "m": 5}),
    ("compact_hm", {"h": 12, "m": 45}),
    ("resets_until", {"date": "do 22 okt"}),
    ("does_not_exist", {}),
]


def _encrypt(value: str, host: str, key: bytes, host_prefix: bool = True) -> bytes:
    from Crypto.Cipher import AES
    plain = value.encode()
    if host_prefix:
        plain = hashlib.sha256(host.encode()).digest() + plain
    pad = 16 - len(plain) % 16
    plain += bytes([pad]) * pad
    return b"v10" + AES.new(key, AES.MODE_CBC, IV=b" " * 16).encrypt(plain)


COOKIE_ROWS = None


def write_cookie_db(key: bytes):
    """Chromium-style cookie DB for read_cookies(); rebuilt on every run."""
    rows = [
        ("sessionKey", _encrypt("sk-ant-test-123", ".claude.ai", key), ".claude.ai", "/"),
        ("legacy", _encrypt("old-style", ".claude.ai", key, host_prefix=False), ".claude.ai", "/"),
        ("plain", b"not-encrypted", ".claude.ai", "/"),
        ("v11scheme", b"v11" + b"\x00" * 16, ".claude.ai", "/"),
        ("badpad", b"v10" + b"\x01" * 16, ".claude.ai", "/"),
    ]
    if os.path.exists(COOKIE_DB_PATH):
        os.unlink(COOKIE_DB_PATH)
    conn = sqlite3.connect(COOKIE_DB_PATH)
    conn.execute("CREATE TABLE cookies (name TEXT, encrypted_value BLOB, host_key TEXT, path TEXT)")
    conn.executemany("INSERT INTO cookies VALUES (?, ?, ?, ?)", rows)
    conn.commit()
    conn.close()
    return rows


PARSED_FETCH = {"ok": True, "org_id": "org-1", "account_email": "user@example.com",
                "account_name": "Sam", "account_plan": {"label": "", "capabilities": ["claude_pro", "chat"]},
                "account_org": " Example Org ",
                "data": {"five_hour": {"utilization": 12.0, "resets_at": "2026-10-01T12:00:00+00:00"},
                         "seven_day": {"utilization": 40, "resets_at": "2026-10-05T07:00:00+00:00"},
                         "account_email": "from-data@example.com"}}

PLAN_CASES = [None, 5, "  Max  ", {}, {"label": " Team "}, {"label": "", "capabilities": ["chat", "claude_pro"]},
              {"label": None, "capabilities": ["claude_max"]}, {"capabilities": None},
              {"label": "", "capabilities": ["chat", "raven"], "raven": "team"},
              {"label": "", "capabilities": ["chat", "raven"], "raven": "enterprise"},
              {"label": "", "capabilities": ["claude_pro"], "raven": None}]

BLOCK_CASES = [
    ({}, {}, "user@example.com", {}),
    ({"five_hour": {"locked_reason": "rate_limited"}, "seven_day": {"locked_reason": ""}},
     {"access_block": {"reason": "x"}, "billing_issue": None, "api_disabled_until": "2026-11-01"},
     "user@example.com", {}),
    ({"five_hour": {"locked_reason": "rate_limited"}}, {}, "user@example.com",
     {"user@example.com|five_hour__locked_reason|rate_limited": True}),
    ({"seven_day": {"locked_reason": "  "}}, "not a dict", "user@example.com", {}),
    ({"five_hour": {"locked_reason": True}}, {"subscription_pause": 3}, "a@b", {}),
]

STATUS_SUMMARIES = [
    None, [], {"status": "x"}, {"status": {"indicator": 1}},
    {"status": {"indicator": "none", "description": " All Systems Operational "},
     "components": [{"name": "claude.ai", "status": "operational"}]},
    {"status": {"indicator": "minor", "description": "Minor"},
     "components": [{"name": "API", "status": "degraded_performance"},
                    {"name": "Group", "status": "major_outage", "group": True},
                    {"name": "Odd", "status": "melting"}, {"name": 3, "status": "x"}, "junk"],
     "incidents": [{"name": "Errors", "id": "abc123"}, {"name": "No id"},
                   {"name": "Bad id", "id": "../x"}, {"id": "zz"}]},
    {"status": {"indicator": "apocalyptic", "description": None}},
]


A = "user@example.com"
FH = "2026-10-01T12:00:00.123456+00:00"      # current 5-hour window
FH_OLD = "2026-10-01T07:00:00+00:00"         # previous one (3 h ago)
WK = "2026-10-05T07:00:00+00:00"


def _lim(fh_pct, wk_pct=10, fh=FH, wk=WK, account=A):
    return {"account_email": account,
            "five_hour": {"utilization": fh_pct, "resets_at": fh},
            "seven_day": {"utilization": wk_pct, "resets_at": wk}}


NOTIFY_CASES = [
    (_lim(50), {}),
    (_lim(81), {}),
    (_lim(96, 91), {}),
    (_lim(96), {A + "|five_hour": {"window": "2026-10-01T12:00:00+00:00", "sent": [80]}}),
    (_lim(96), {A + "|five_hour": {"window": "2026-10-01T12:00:00+00:00", "sent": [80, 95]}}),
    (_lim(5), {A + "|five_hour": {"window": "2026-10-01T07:00:00+00:00", "sent": [80]}}),
    (_lim(85), {A + "|five_hour": {"window": "2026-10-01T07:00:00+00:00", "sent": [80, 95]}}),
    (_lim(5), {A + "|five_hour": {"window": "2026-09-29T07:00:00+00:00", "sent": [80]}}),
    (_lim(5), {A + "|five_hour": {"window": "2026-10-01T07:00:00+00:00", "sent": []}}),
    (_lim(5, fh=""), {}),
    (_lim(None, None), {}),
    ({"five_hour": {"utilization": 99.9, "resets_at": "bad"}}, {}),
    (_lim(90, 95, account=""), {"other": {"window": "x", "sent": [1]}}),
]

WINDOW_KEYS = ["", "bad", "2026-10-01T12:00:00Z", "2026-10-01T11:59:30.000001+00:00",
               "2026-10-01T11:59:29.999999+00:00", "2026-10-01T14:00:00+02:00", FH]

HISTORY_CASES = [
    {},
    {"fetched_at": "2026-10-01T10:00:00+00:00", "account_email": A, "org_id": "org-1",
     "five_hour": {"utilization": 12.0, "resets_at": FH, "extra": 1},
     "seven_day": {"utilization": None, "resets_at": WK},
     "seven_day_breakdown": {"window_started_at": "2026-09-28T07:00:00Z", "as_of": "x",
                             "rows": [{"key": "chat", "display_name": "Chats", "percent": 1, "x": 2},
                                      {"key": None}, "junk", {}]},
     "extra_usage": {"is_enabled": True, "used_credits": 0, "monthly_limit": 1700, "currency": "EUR",
                     "other": 1},
     "cedar_ember": {"eligible": True, "at_limit": False, "grants": [GRANT]}},
    {"fetched_at": "2026-10-01T10:00:00+00:00", "five_hour": "x",
     "seven_day_breakdown": {"rows": None}, "extra_usage": {"is_enabled": False}},
    {"seven_day_breakdown": {}},
]


VERSIONS = ["1.2", "v1.2.0", "1.10.3", "V2", "1.2.0-rc1", "dev", "", None, "1..2", " 2.0 ", 5, "2.0.0.0"]
NEWER = [("1.10.0", "1.9.2"), ("1.2", "1.1.1"), ("1.2.0", "1.2"), ("1.1.1", "1.2"), ("1.3", "dev"),
         ("1.3-beta", "1.2"), ("2.0", "1.2.7"), ("2.0.1", "2.0")]


def _release(**over):
    rel = {"tag_name": "v1.2", "html_url": "https://github.com/x/y/releases/tag/v1.2",
           "draft": False, "prerelease": False, "assets": [
               {"name": "ClaudeUsage.dmg", "browser_download_url": "https://dl/dmg"},
               {"name": "ClaudeUsage.dmg.sig", "browser_download_url": "https://dl/sig"},
               "junk"]}
    rel.update(over)
    return rel


RELEASES = [_release(), _release(assets=[{"name": "ClaudeUsage.dmg", "browser_download_url": "u"}]),
            _release(draft=True), _release(prerelease=True), _release(tag_name="nightly"),
            _release(assets=None), "not a dict", {}]


def signature_cases():
    """Ed25519 with a fixed TEST key (never the release key)."""
    from Crypto.PublicKey import ECC
    key = ECC.construct(curve="ed25519", seed=bytes(range(32)))
    pub = key.public_key().export_key(format="raw").hex()
    data = b"ClaudeUsage test payload \x00\xff"
    sig = core.sign_release(data, key)
    cases = [(data, sig), (data + b"!", sig), (data, "not base64!"), (data, ""),
             (data, "  " + sig + "\n"), (b"", core.sign_release(b"", key))]
    return {"public_key": pub, "release_public_key": core.UPDATE_PUBLIC_KEY_HEX,
            "cases": [{"data": d.hex(), "sig": sg, "out": core.verify_release_signature(d, sg, pub)}
                      for d, sg in cases]}


def build_fixtures() -> dict:
    core.datetime = _FixedNow
    now = datetime.fromisoformat(NOW)
    langs = list(core.LANGS) + ["fr"]
    fx = {"now": NOW, "tz": TZ, "cases": {}}
    c = fx["cases"]
    c["format_reset_time"] = [{"in": s, "lang": l, "out": core.format_reset_time(s, l)}
                              for s in RESET_INPUTS for l in langs]
    c["format_reset_compact"] = [{"in": s, "lang": l, "out": core.format_reset_compact(s, l)}
                                 for s in RESET_INPUTS for l in langs]
    c["format_short_date"] = [{"in": s, "lang": l, "out": core.format_short_date(s, l)}
                              for s in RESET_INPUTS for l in langs]
    c["face_icon"] = [{"in": p, "out": core.face_icon(p)}
                      for p in (0, 19, 20, 39, 40, 59, 60, 74, 75, 89, 90, 99, 100, 140)]
    c["status_title"] = [{"session": s, "weekly": w, "compact": r, "style": st,
                          "out": core.status_title(s, w, r, st)}
                         for s, w, r in ((45, 82, "2u10m"), (0, 0, "—"), (100, 100, "5m"))
                         for st in core.MENUBAR_STYLES + ("unknown",)]
    c["title_from_limits"] = [{"limits": lim, "style": st, "lang": l,
                               "out": core.title_from_limits(lim, st, l)}
                              for lim in LIMITS_CASES[:3] for st in core.MENUBAR_STYLES
                              for l in core.LANGS]
    c["account_label"] = [{"limits": lim, "out": core.account_label(lim)}
                          for lim in LIMITS_CASES[9:12]]
    c["week_progress"] = [{"limits": lim, "out": core.week_progress(lim, now)}
                          for lim in LIMITS_CASES]
    c["limits_are_fresh"] = [{"limits": lim, "out": core.limits_are_fresh(lim)}
                             for lim in LIMITS_CASES]
    c["limit_resets_view"] = [{"limits": lim, "lang": l, "out": core.limit_resets_view(lim, now, l)}
                              for lim in RESETS_CASES for l in core.LANGS]
    c["load_settings"] = []
    for stored in SETTINGS_CASES:
        path = os.path.join(os.environ.get("TMPDIR", "/tmp"), "swift-fixture-settings.json")
        with open(path, "w", encoding="utf-8") as f:
            json.dump(stored, f)
        c["load_settings"].append({"stored": stored, "out": core.load_settings(path)})
        os.unlink(path)
    c["status_badge_class"] = [{"in": s, "out": core.status_badge_class(s)} for s in SERVICE_CASES]
    key = core.derive_cookie_key(TEST_PASSWORD)
    rows = write_cookie_db(key)
    c["derive_cookie_key"] = [{"password": pw, "out": core.derive_cookie_key(pw).hex()}
                              for pw in (TEST_PASSWORD, "", "pässwörd")]
    c["decrypt_cookie_value"] = [{"enc": bytes(enc).hex(), "host": host, "key": key.hex(),
                                  "out": core.decrypt_cookie_value(bytes(enc), host, key)}
                                 for _, enc, host, _ in rows]
    c["decrypt_cookie_value"].append({"enc": rows[0][1].hex(), "host": ".claude.ai",
                                      "key": core.derive_cookie_key("wrong").hex(),
                                      "out": core.decrypt_cookie_value(rows[0][1], ".claude.ai",
                                                                       core.derive_cookie_key("wrong"))})
    c["read_cookies"] = {"password": TEST_PASSWORD, "out": core.read_cookies(COOKIE_DB_PATH, key)}
    c["plan_label"] = [{"in": p, "out": core.plan_label(p)} for p in PLAN_CASES]
    c["limits_output"] = [{"in": PARSED_FETCH, "out": core.limits_output(PARSED_FETCH)}]
    c["new_block_log_entries"] = [
        {"limits": lim, "bootstrap": bs, "account": acct, "seen": seen,
         "out": list(core.new_block_log_entries(lim, bs, acct, seen))}
        for lim, bs, acct, seen in BLOCK_CASES]
    c["cedar_ember"] = [{"limits": lim, "unrecognised": core.cedar_ember_unrecognised(lim),
                         "stable": core.cedar_ember_stable(lim)} for lim in RESETS_CASES]
    c["service_status"] = [{"in": s, "out": core.service_status(s)} for s in STATUS_SUMMARIES]
    c["color_for_pct"] = [{"in": p, "out": list(core.color_for_pct(p))}
                          for p in (-5, 0, 12.5, 25, 50, 50.5, 75, 99, 100, 130)]
    c["window_key"] = [{"in": w, "out": core.window_key(w)} for w in WINDOW_KEYS]
    c["due_notifications"] = []
    for lim, state in NOTIFY_CASES:
        for l in core.LANGS:
            notes, new_state = core.due_notifications(lim, state, lang=l, now=now)
            c["due_notifications"].append({"limits": lim, "state": state, "lang": l,
                                           "notes": notes, "new_state": new_state})
    c["history_record"] = [{"in": h, "out": core.history_record(h)} for h in HISTORY_CASES]
    c["history_path"] = [{"in": ts, "out": os.path.basename(core.history_path(ts, "/base"))}
                         for ts in ("2026-10-01T10:00:00+00:00", "2026-10-31T23:30:00-02:00",
                                    "2026-12-31T23:59:59Z")]
    c["parse_version"] = [{"in": v, "out": list(core.parse_version(v)) if core.parse_version(v) else None}
                          for v in VERSIONS]
    c["is_newer"] = [{"cand": a, "cur": b, "out": core.is_newer(a, b)} for a, b in NEWER]
    c["parse_release"] = [{"in": r, "out": core.parse_release(r)} for r in RELEASES]
    c["update_check_due"] = [{"state": st, "out": core.update_check_due(st, now)} for st in
                             ({}, {"last_check": "2026-09-30T11:00:00+00:00"},
                              {"last_check": "2026-09-30T09:00:00+00:00"}, {"last_check": "garbage"},
                              {"last_check": None})]
    c["verify_release_signature"] = signature_cases()
    c["t"] = [{"key": k, "lang": l, "kw": kw, "out": core.t(k, l, **kw)}
              for k, kw in T_CASES for l in langs]
    return fx


def main():
    write_json(STRINGS_PATH, shared_strings())
    with open(FETCH_JS_PATH, "w", encoding="utf-8") as f:
        f.write(core._FETCH_JS_TEMPLATE)
    write_json(FIXTURES_PATH, build_fixtures())
    print(f"✓ {os.path.relpath(STRINGS_PATH, ROOT)}")
    print(f"✓ {os.path.relpath(FIXTURES_PATH, ROOT)}")


if __name__ == "__main__":
    main()
