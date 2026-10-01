"""Tests for core.py — pure logic, runs without AppKit.

Run: /usr/bin/python3 -m pytest
"""

import hashlib
import os
import sqlite3
import sys
from datetime import datetime, timedelta, timezone

import pytest
from Crypto.Cipher import AES

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import core  # noqa: E402


# ---------------------------------------------------------------------------
# Cookie decryption — fixture DB encrypted with a known test password.
# Never put real cookies in here.
# ---------------------------------------------------------------------------

TEST_PASSWORD = "test-safe-storage-password"


def _encrypt(value: str, host: str, key: bytes, host_prefix: bool = True) -> bytes:
    plain = value.encode()
    if host_prefix:
        plain = hashlib.sha256(host.encode()).digest() + plain
    pad = 16 - len(plain) % 16
    plain += bytes([pad]) * pad
    return b"v10" + AES.new(key, AES.MODE_CBC, IV=b" " * 16).encrypt(plain)


@pytest.fixture
def cookie_db(tmp_path):
    key = core.derive_cookie_key(TEST_PASSWORD)
    path = tmp_path / "Cookies"
    conn = sqlite3.connect(str(path))
    conn.execute(
        "CREATE TABLE cookies (name TEXT, encrypted_value BLOB, host_key TEXT, path TEXT)"
    )
    rows = [
        ("sessionKey", _encrypt("sk-ant-test-123", ".claude.ai", key), ".claude.ai", "/"),
        ("legacy", _encrypt("old-style", ".claude.ai", key, host_prefix=False), ".claude.ai", "/"),
        ("plain", b"not-encrypted", ".claude.ai", "/"),
        ("v11scheme", b"v11" + b"\x00" * 16, ".claude.ai", "/"),
    ]
    conn.executemany("INSERT INTO cookies VALUES (?, ?, ?, ?)", rows)
    conn.commit()
    conn.close()
    return str(path), key


def test_read_cookies_decrypts_host_prefixed_value(cookie_db):
    path, key = cookie_db
    cookies = core.read_cookies(path, key)
    assert cookies["sessionKey"] == {"value": "sk-ant-test-123", "domain": ".claude.ai", "path": "/"}
    assert core.session_key_from(cookies) == "sk-ant-test-123"


def test_read_cookies_handles_pre_v24_values_without_host_prefix(cookie_db):
    path, key = cookie_db
    assert core.read_cookies(path, key)["legacy"]["value"] == "old-style"


def test_read_cookies_skips_unencrypted_and_unknown_schemes(cookie_db):
    path, key = cookie_db
    cookies = core.read_cookies(path, key)
    assert "plain" not in cookies
    assert "v11scheme" not in cookies


def test_wrong_key_yields_no_cookies(cookie_db):
    path, _ = cookie_db
    assert core.read_cookies(path, core.derive_cookie_key("wrong")) == {}


def test_read_cookies_leaves_no_temp_copy(cookie_db, tmp_path, monkeypatch):
    path, key = cookie_db
    monkeypatch.setattr(core.tempfile, "tempdir", str(tmp_path))
    before = set(os.listdir(tmp_path))
    core.read_cookies(path, key)
    assert set(os.listdir(tmp_path)) == before


def test_find_cookie_db_prefers_root_then_network(tmp_path):
    assert core.find_cookie_db(str(tmp_path)) == ""
    (tmp_path / "Network").mkdir()
    (tmp_path / "Network" / "Cookies").write_bytes(b"")
    assert core.find_cookie_db(str(tmp_path)) == str(tmp_path / "Network" / "Cookies")
    (tmp_path / "Cookies").write_bytes(b"")
    assert core.find_cookie_db(str(tmp_path)) == str(tmp_path / "Cookies")


def test_session_key_from_missing():
    assert core.session_key_from({}) == ""


# ---------------------------------------------------------------------------
# Formatting
# ---------------------------------------------------------------------------

def _iso_in(**delta) -> str:
    # +30 s margin so the minute count doesn't tick over while the test runs
    return (datetime.now(timezone.utc) + timedelta(seconds=30, **delta)).isoformat()


def test_format_reset_time_within_a_day():
    assert core.format_reset_time(_iso_in(hours=2, minutes=5)) == "over 2u 5m"
    assert core.format_reset_time(_iso_in(minutes=42)) == "over 42m"


def test_format_reset_time_beyond_a_day_shows_weekday_and_time():
    target = datetime.now(timezone.utc) + timedelta(days=3)
    local = target.astimezone()
    expected = f"{core.DAYS['nl'][local.weekday()]} {local.strftime('%H:%M')}"
    assert core.format_reset_time(target.isoformat()) == expected


def test_format_reset_time_in_past_shows_weekday():
    target = datetime.now(timezone.utc) - timedelta(hours=1)
    assert core.format_reset_time(target.isoformat()).split(" ")[0] in core.DAYS['nl']


@pytest.mark.parametrize("bad", ["", "garbage", "2026-13-45T00:00:00"])
def test_format_reset_time_bad_input(bad):
    assert core.format_reset_time(bad) == "—"


def test_format_reset_time_accepts_z_suffix():
    iso = (datetime.now(timezone.utc) + timedelta(minutes=10, seconds=30)).strftime("%Y-%m-%dT%H:%M:%SZ")
    assert core.format_reset_time(iso) == "over 10m"


def test_format_reset_compact():
    assert core.format_reset_compact(_iso_in(hours=2, minutes=5)) == "2u05m"
    assert core.format_reset_compact(_iso_in(minutes=7)) == "7m"
    assert core.format_reset_compact((datetime.now(timezone.utc) - timedelta(minutes=1)).isoformat()) == "—"
    assert core.format_reset_compact("") == "—"


@pytest.mark.parametrize("pct,icon", [
    (0, "🚀"), (19, "🚀"), (20, "🙂"), (40, "😅"), (60, "😨"),
    (75, "😰"), (90, "😱"), (100, "💀"), (130, "💀"),
])
def test_face_icon_thresholds(pct, icon):
    assert core.face_icon(pct) == icon


def test_title_from_limits_tolerates_nulls():
    assert core.title_from_limits({"five_hour": None, "seven_day": None}) == "🚀 0% / 0% · —"
    title = core.title_from_limits({
        "five_hour": {"utilization": 45.7, "resets_at": _iso_in(minutes=30)},
        "seven_day": {"utilization": 82},
    })
    assert title == "😅 45% / 82% · 30m"


# ---------------------------------------------------------------------------
# Limits file
# ---------------------------------------------------------------------------

def test_limits_are_fresh():
    now = datetime.now(timezone.utc)
    assert core.limits_are_fresh({"fetched_at": (now - timedelta(minutes=2)).isoformat()})
    assert not core.limits_are_fresh({"fetched_at": (now - timedelta(minutes=6)).isoformat()})
    assert not core.limits_are_fresh({})
    assert not core.limits_are_fresh({"fetched_at": "nonsense"})


def test_load_limits_missing_or_corrupt(tmp_path):
    assert core.load_limits(str(tmp_path / "nope.json")) == {}
    bad = tmp_path / "bad.json"
    bad.write_text("{not json")
    assert core.load_limits(str(bad)) == {}


def test_limits_output_shape():
    out = core.limits_output({"ok": True, "org_id": "o1", "account_email": "a@b",
                              "data": {"five_hour": {"utilization": 3}}})
    assert out["org_id"] == "o1" and out["account_email"] == "a@b"
    assert out["five_hour"] == {"utilization": 3}
    assert core.limits_are_fresh(out)


def test_build_fetch_js_substitutes_delivery():
    js = core.build_fetch_js("window.__x = s;")
    assert "DELIVER" not in js
    assert "window.__x = s;" in js


def test_core_does_not_import_pyobjc():
    """core.py must stay importable without AppKit — that's the point of the split."""
    import subprocess
    code = ("import sys; sys.path.insert(0, %r); import core; "
            "bad = [m for m in ('objc', 'Foundation', 'AppKit', 'WebKit') if m in sys.modules]; "
            "print(','.join(bad))") % os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, check=True)
    assert out.stdout.strip() == ""


# ---------------------------------------------------------------------------
# Limit notifications
# ---------------------------------------------------------------------------

def _limits(five=0, week=0, five_reset="2026-09-30T15:50:00.385576+00:00",
            week_reset="2026-10-02T17:00:00.385603+00:00", account="a@b"):
    return {"account_email": account,
            "five_hour": {"utilization": five, "resets_at": five_reset},
            "seven_day": {"utilization": week, "resets_at": week_reset}}


def test_window_key_ignores_microsecond_jitter():
    a = core.window_key("2026-09-30T15:50:00.037633+00:00")
    b = core.window_key("2026-09-30T15:50:00.385576+00:00")
    c = core.window_key("2026-09-30T15:49:59.990000+00:00")
    assert a == b == c == "2026-09-30T15:50:00+00:00"
    assert core.window_key("") == core.window_key("garbage") == ""


def test_below_thresholds_nothing_due():
    notes, state = core.due_notifications(_limits(five=79, week=89), {})
    assert notes == []
    assert state["a@b|five_hour"]["sent"] == []


def test_crossing_threshold_notifies_once_per_window():
    notes, state = core.due_notifications(_limits(five=81), {})
    assert [n["threshold"] for n in notes] == [80]
    assert notes[0]["title"] == "Claude: 5-uurslimiet op 81%"
    # Same window, jittered resets_at, higher but below next threshold: silent
    notes, state = core.due_notifications(
        _limits(five=90, five_reset="2026-09-30T15:50:00.999+00:00"), state)
    assert notes == []
    notes, state = core.due_notifications(_limits(five=96), state)
    assert [n["threshold"] for n in notes] == [95]
    notes, state = core.due_notifications(_limits(five=99), state)
    assert notes == []


def test_jump_over_several_thresholds_sends_only_highest():
    notes, state = core.due_notifications(_limits(five=97), {})
    assert [n["threshold"] for n in notes] == [95]
    assert state["a@b|five_hour"]["sent"] == [80, 95]


def test_new_window_notifies_again():
    _, state = core.due_notifications(_limits(five=85), {})
    notes, _ = core.due_notifications(
        _limits(five=85, five_reset="2026-09-30T20:50:00+00:00"), state)
    assert [n["threshold"] for n in notes] == [80]


def test_weekly_threshold_and_accounts_are_independent():
    notes, state = core.due_notifications(_limits(five=10, week=91), {})
    assert [(n["limit"], n["threshold"]) for n in notes] == [("seven_day", 90)]
    assert notes[0]["title"] == "Claude: Weeklimiet op 91%"
    notes, _ = core.due_notifications(_limits(week=91, account="other@x"), state)
    assert [(n["limit"], n["threshold"]) for n in notes] == [("seven_day", 90)]


def test_missing_or_null_blocks_are_skipped():
    notes, state = core.due_notifications({"five_hour": None, "seven_day": {"utilization": 99}}, {})
    assert notes == [] and state == {}


def test_notify_state_roundtrip(tmp_path):
    path = str(tmp_path / "n.json")
    assert core.load_notify_state(path) == {}
    core.save_notify_state({"k": {"window": "w", "sent": [80]}}, path)
    assert core.load_notify_state(path) == {"k": {"window": "w", "sent": [80]}}


def test_settings_default_and_roundtrip(tmp_path):
    path = str(tmp_path / "s.json")
    assert core.load_settings(path) == core.DEFAULT_SETTINGS
    core.save_settings(dict(core.DEFAULT_SETTINGS, notifications=False, menubar_style="emoji"), path)
    loaded = core.load_settings(path)
    assert loaded["notifications"] is False and loaded["menubar_style"] == "emoji"


def test_settings_ignore_unknown_and_corrupt(tmp_path):
    path = tmp_path / "s.json"
    path.write_text('{"notifications": false, "evil": 1}')
    assert core.load_settings(str(path))["notifications"] is False
    assert "evil" not in core.load_settings(str(path))
    path.write_text("{nope")
    assert core.load_settings(str(path)) == core.DEFAULT_SETTINGS


@pytest.mark.parametrize("pct,rgb", [
    (0, (47, 168, 74)), (50, (255, 149, 0)), (100, (255, 59, 48)),
    (25, (151, 159, 37)), (75, (255, 104, 24)), (-5, (47, 168, 74)), (140, (255, 59, 48)),
])
def test_color_for_pct_matches_dashboard(pct, rgb):
    # Values computed with colorForPct() from dashboard.html (Math.round).
    assert core.color_for_pct(pct) == rgb


def test_notification_carries_pct():
    notes, _ = core.due_notifications(_limits(five=86), {})
    assert notes[0]["pct"] == 86


# ---------------------------------------------------------------------------
# Updates
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("s,parsed", [
    ("1.2", (1, 2)), ("v1.2.0", (1, 2)), ("1.10.3", (1, 10, 3)), ("V2", (2,)),
    ("1.2.0-rc1", None), ("dev", None), ("", None), (None, None), ("1..2", None),
])
def test_parse_version(s, parsed):
    assert core.parse_version(s) == parsed


@pytest.mark.parametrize("cand,cur,newer", [
    ("1.10.0", "1.9.2", True), ("1.2", "1.1.1", True), ("1.2.0", "1.2", False),
    ("1.1.1", "1.2", False), ("1.3", "dev", False), ("1.3-beta", "1.2", False),
])
def test_is_newer(cand, cur, newer):
    assert core.is_newer(cand, cur) is newer


def _release(**over):
    rel = {"tag_name": "v1.2", "html_url": "https://github.com/x/y/releases/tag/v1.2",
           "draft": False, "prerelease": False, "assets": [
               {"name": "ClaudeUsage.dmg", "browser_download_url": "https://dl/dmg"},
               {"name": "ClaudeUsage.dmg.sig", "browser_download_url": "https://dl/sig"},
           ]}
    rel.update(over)
    return rel


def test_parse_release():
    assert core.parse_release(_release()) == {
        "version": "1.2", "html_url": "https://github.com/x/y/releases/tag/v1.2",
        "dmg_url": "https://dl/dmg", "sig_url": "https://dl/sig"}


def test_parse_release_without_signature_has_empty_sig_url():
    rel = core.parse_release(_release(assets=[{"name": "ClaudeUsage.dmg", "browser_download_url": "u"}]))
    assert rel["dmg_url"] == "u" and rel["sig_url"] == ""


@pytest.mark.parametrize("over", [{"draft": True}, {"prerelease": True}, {"tag_name": "nightly"}])
def test_parse_release_rejects_non_final(over):
    assert core.parse_release(_release(**over)) is None
    assert core.parse_release("not a dict") is None


def test_update_check_due():
    now = datetime(2026, 9, 30, 12, 0, tzinfo=timezone.utc)
    assert core.update_check_due({}, now)
    assert not core.update_check_due({"last_check": (now - timedelta(hours=23)).isoformat()}, now)
    assert core.update_check_due({"last_check": (now - timedelta(hours=25)).isoformat()}, now)
    assert core.update_check_due({"last_check": "garbage"}, now)


@pytest.fixture
def signing_key():
    from Crypto.PublicKey import ECC
    key = ECC.generate(curve="ed25519")
    return key, key.public_key().export_key(format="raw").hex()


def test_release_signature_roundtrip(signing_key):
    key, pub = signing_key
    data = b"dmg bytes" * 1000
    sig = core.sign_release(data, key)
    assert core.verify_release_signature(data, sig, pub)
    assert core.verify_release_signature(data, sig + "\n", pub)   # trailing newline in .sig file


def test_release_signature_rejects_tampering(signing_key):
    key, pub = signing_key
    sig = core.sign_release(b"original", key)
    assert not core.verify_release_signature(b"tampered", sig, pub)
    assert not core.verify_release_signature(b"original", "not base64!!", pub)
    assert not core.verify_release_signature(b"original", "", pub)
    from Crypto.PublicKey import ECC
    other = ECC.generate(curve="ed25519").public_key().export_key(format="raw").hex()
    assert not core.verify_release_signature(b"original", sig, other)


def test_embedded_public_key_is_valid():
    from Crypto.Signature import eddsa
    eddsa.import_public_key(bytes.fromhex(core.UPDATE_PUBLIC_KEY_HEX))


def test_json_helpers(tmp_path):
    path = str(tmp_path / "x.json")
    assert core.load_json(path) == {}
    core.save_json({"a": 1}, path)
    assert core.load_json(path) == {"a": 1}
    (tmp_path / "list.json").write_text("[1, 2]")
    assert core.load_json(str(tmp_path / "list.json")) == {}


def test_log_writes_utf8_regardless_of_locale(tmp_path, monkeypatch):
    # Inside the app bundle the locale is ASCII; "—" must still be logged.
    import builtins
    real_open = builtins.open

    def ascii_default_open(file, mode="r", *args, encoding=None, **kw):
        if "b" not in mode and encoding is None:
            encoding = "ascii"
        return real_open(file, mode, *args, encoding=encoding, **kw)

    monkeypatch.setattr(builtins, "open", ascii_default_open)
    log_file = tmp_path / "log.txt"
    monkeypatch.setattr(core, "LOG_FILE", str(log_file))
    core.log("account gewisseld — geïnstalleerd")
    monkeypatch.undo()
    assert "— geïnstalleerd" in log_file.read_text(encoding="utf-8")



@pytest.mark.parametrize("style,expected", [
    ("full", "😅 45% / 82% · 2u10m"),
    ("session", "😅 45%"),
    ("emoji", "😅"),
    ("bogus", "😅 45% / 82% · 2u10m"),
])
def test_status_title_styles(style, expected):
    assert core.status_title(45, 82, "2u10m", style) == expected


def test_title_from_limits_passes_style():
    limits = {"five_hour": {"utilization": 91}, "seven_day": {"utilization": 10}}
    assert core.title_from_limits(limits, "session") == "😱 91%"
    assert core.title_from_limits(limits, "emoji") == "😱"


def test_settings_reject_unknown_menubar_style(tmp_path):
    path = tmp_path / "s.json"
    path.write_text('{"menubar_style": "huge"}')
    assert core.load_settings(str(path))["menubar_style"] == "full"


# ---------------------------------------------------------------------------
# Account label (footer)
# ---------------------------------------------------------------------------

def test_account_label_name_and_plan():
    lbl = core.account_label({"account_email": "j@x.nl", "account_name": " Jos ", "account_plan": "Pro"})
    assert lbl == {"name": "Jos", "plan": "Pro", "email": "j@x.nl"}


def test_account_label_falls_back_to_email():
    assert core.account_label({"account_email": "someone@example.com"}) == {
        "name": "someone@example.com", "plan": "", "email": "someone@example.com"}
    assert core.account_label({}) == {"name": "", "plan": "", "email": ""}


def test_limits_output_carries_name_and_plan():
    out = core.limits_output({"org_id": "o", "account_email": "e", "account_name": "Jos",
                              "account_plan": "Max", "data": {}})
    assert (out["account_name"], out["account_plan"]) == ("Jos", "Max")


def test_fetch_js_sends_only_name_and_plan():
    js = core.build_fetch_js("x(s);")
    assert "account_name: name" in js and "account_plan: best.plan" in js
    assert "JSON.stringify(d)" not in js


@pytest.mark.parametrize("plan,label", [
    ({"label": "", "capabilities": ["claude_pro", "chat"], "tier": "default_claude_ai"}, "Pro"),
    # Not observed yet: must show nothing rather than a guess
    ({"label": "", "capabilities": ["claude_max", "chat"], "tier": "default_claude_max_20x"}, ""),
    ({"label": "Team", "capabilities": ["claude_pro"], "tier": ""}, "Team"),
    ({"label": "", "capabilities": ["api", "api_individual"], "tier": "auto_trust_tier_c"}, ""),
    ({}, ""), (None, ""), ("Pro", "Pro"),
])
def test_plan_label(plan, label):
    assert core.plan_label(plan) == label


def test_limits_output_derives_plan_from_capabilities():
    out = core.limits_output({"org_id": "o", "data": {},
                              "account_plan": {"label": "", "capabilities": ["claude_pro"], "tier": ""}})
    assert out["account_plan"] == "Pro"


# ---------------------------------------------------------------------------
# Weekly window progress
# ---------------------------------------------------------------------------

def _week(start=None, end="2026-10-02T17:00:00.312302+00:00"):
    lim = {"seven_day": {"utilization": 18, "resets_at": end}}
    if start is not None:
        lim["seven_day_breakdown"] = {"window_started_at": start}
    return lim


def test_week_window_uses_api_start():
    start, end, dev = core.week_window(_week(start="2026-09-25T17:00:00.312302+00:00"))
    assert (end - start) == timedelta(days=7) and dev is False


def test_week_window_falls_back_to_seven_days():
    for lim in (_week(), _week(start="garbage"), _week(start="2026-10-03T00:00:00+00:00")):
        start, end, dev = core.week_window(lim)
        assert end - start == timedelta(days=7) and dev is False


def test_week_window_flags_non_seven_day_window():
    _, _, dev = core.week_window(_week(start="2026-09-26T17:00:00+00:00"))
    assert dev is True


def test_week_window_without_reset():
    assert core.week_window({}) is None
    assert core.week_window({"seven_day": {"resets_at": "nope"}}) is None
    assert core.week_progress({}, datetime.now(timezone.utc)) is None


@pytest.mark.parametrize("now,pct,day", [
    ("2026-09-25T17:00:00+00:00", 0.0, 1),     # start of window
    ("2026-09-29T05:00:00+00:00", 50.0, 4),    # halfway
    ("2026-10-01T05:54:00+00:00", 79.1, 6),    # observed 1-10: 79%, day 6 of 7
    ("2026-10-02T17:00:00+00:00", 100.0, 7),   # end
    ("2026-10-05T00:00:00+00:00", 100.0, 7),   # after end: clamped
    ("2026-09-20T00:00:00+00:00", 0.0, 1),     # before start: clamped
])
def test_week_progress(now, pct, day):
    p = core.week_progress(_week(start="2026-09-25T17:00:00+00:00", end="2026-10-02T17:00:00+00:00"),
                           datetime.fromisoformat(now))
    assert (p["elapsed_pct"], p["day"], p["days"]) == (pct, day, 7)


# ---------------------------------------------------------------------------
# Languages
# ---------------------------------------------------------------------------

import re  # noqa: E402
import string  # noqa: E402


def _placeholders(text):
    return {f for _, f, _, _ in string.Formatter().parse(text) if f}


def test_all_languages_have_the_same_keys_and_placeholders():
    nl, en = core.STRINGS["nl"], core.STRINGS["en"]
    assert set(nl) == set(en)
    for key in nl:
        assert _placeholders(nl[key]) == _placeholders(en[key]), key
    assert len(core.DAYS['nl']) == len(core.DAYS["en"]) == 7


@pytest.mark.parametrize("preferred,lang", [
    (["nl-NL", "en-US"], "nl"), (["nl"], "nl"), (["nl_BE"], "nl"),
    (["en-NL", "nl-NL"], "en"),   # only the first language counts
    (["de-DE"], "en"), ([], "en"), (None, "en"),
])
def test_language_from(preferred, lang):
    assert core.language_from(preferred) == lang


def test_t_formats_and_falls_back():
    assert core.t("in_hm", "en", h=2, m=5) == "in 2h 5m"
    assert core.t("compact_hm", "nl", h=2, m=5) == "2u05m"
    assert core.t("status_ok", "fr") == "Connected to Anthropic API"   # unknown lang -> en
    assert core.t("no_such_key", "nl") == "no_such_key"


def test_reset_formats_in_english():
    assert core.format_reset_time(_iso_in(hours=2, minutes=5), "en") == "in 2h 5m"
    assert core.format_reset_compact(_iso_in(hours=2, minutes=5), "en") == "2h05m"
    target = datetime.now(timezone.utc) + timedelta(days=3)
    assert core.format_reset_time(target.isoformat(), "en").split(" ")[0] in core.DAYS["en"]


def test_limit_notification_in_english():
    notes, _ = core.due_notifications(_limits(five=81), {}, lang="en")
    assert notes[0]["title"] == "Claude: 5-hour limit at 81%"
    assert notes[0]["body"].startswith("Resets ")


def test_update_errors_translate():
    import updater
    e = updater.UpdateError("not_newer", new="1.2", current="1.3")
    assert str(e) == "1.2 is niet nieuwer dan 1.3"            # log stays Dutch
    assert e.message("en") == "1.2 is not newer than 1.3"


def test_every_update_error_key_exists():
    import updater
    src = open(updater.__file__, encoding="utf-8").read()
    for key in re.findall(r'UpdateError\("([a-z_]+)"', src):
        assert "err_" + key in core.STRINGS["nl"], key


def _dashboard():
    path = os.path.join(os.path.dirname(core.__file__), "dashboard.html")
    return open(path, encoding="utf-8").read()


def test_dashboard_keys_exist_in_translations():
    html = _dashboard()
    keys = set(re.findall(r'data-i18n(?:-title)?="([a-z_]+)"', html))
    keys |= set(re.findall(r"\bT\('([a-z_]+)'", html))
    assert keys, "no translation keys found"
    missing = keys - set(core.STRINGS["en"])
    assert not missing, missing


def test_dashboard_script_has_no_hardcoded_ui_text():
    """User-facing text in the script must go through T(); catch regressions."""
    script = _dashboard().split("<script>", 1)[1]
    for phrase in ("Bijgewerkt", "Verbonden", "beschikbaar", "Mislukt", "Instellingen",
                   "gebruikt", "van de week", "Reset ", "Up-to-date", "Laden"):
        assert phrase not in script, phrase
