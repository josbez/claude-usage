"""Tests for core.py — pure logic, runs without AppKit.

Run: /usr/bin/python3 -m pytest
"""

import hashlib
import json
import os
import sqlite3
import sys
import time
from datetime import datetime, timedelta, timezone, date

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

@pytest.mark.parametrize("n,expected", [
    (0, "0"), (999, "999"), (1_000, "1.0k"), (12_345, "12.3k"),
    (1_000_000, "1.0M"), (2_550_000, "2.5M"),
])
def test_format_tokens(n, expected):
    assert core.format_tokens(n) == expected


def _iso_in(**delta) -> str:
    # +30 s margin so the minute count doesn't tick over while the test runs
    return (datetime.now(timezone.utc) + timedelta(seconds=30, **delta)).isoformat()


def test_format_reset_time_within_a_day():
    assert core.format_reset_time(_iso_in(hours=2, minutes=5)) == "over 2u 5m"
    assert core.format_reset_time(_iso_in(minutes=42)) == "over 42m"


def test_format_reset_time_beyond_a_day_shows_weekday_and_time():
    target = datetime.now(timezone.utc) + timedelta(days=3)
    local = target.astimezone()
    expected = f"{core.DAYS_NL[local.weekday()]} {local.strftime('%H:%M')}"
    assert core.format_reset_time(target.isoformat()) == expected


def test_format_reset_time_in_past_shows_weekday():
    target = datetime.now(timezone.utc) - timedelta(hours=1)
    assert core.format_reset_time(target.isoformat()).split(" ")[0] in core.DAYS_NL


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


# ---------------------------------------------------------------------------
# JSONL scan — grouping by local calendar day
# ---------------------------------------------------------------------------

@pytest.fixture
def amsterdam_tz():
    old = os.environ.get("TZ")
    os.environ["TZ"] = "Europe/Amsterdam"
    time.tzset()
    yield
    if old is None:
        del os.environ["TZ"]
    else:
        os.environ["TZ"] = old
    time.tzset()


def _write_session(projects_dir, lines):
    proj = projects_dir / "-Users-test-proj"
    proj.mkdir(parents=True, exist_ok=True)
    with open(proj / "session.jsonl", "w") as f:
        for obj in lines:
            f.write((obj if isinstance(obj, str) else json.dumps(obj)) + "\n")


def _assistant(ts, model="claude-x", i=10, o=5, c=100):
    return {"type": "assistant", "timestamp": ts, "message": {
        "model": model,
        "usage": {"input_tokens": i, "output_tokens": o, "cache_read_input_tokens": c},
    }}


def _user(ts):
    return {"type": "user", "timestamp": ts, "message": {"role": "user"}}


def test_scan_groups_by_local_day_around_midnight(tmp_path, amsterdam_tz):
    _write_session(tmp_path, [
        _user("2026-09-29T21:59:00Z"),        # 23:59 CEST -> 29th
        _assistant("2026-09-29T22:01:00Z"),   # 00:01 CEST -> 30th
        _user("2026-09-29T22:30:00.123Z"),
    ])
    daily = core.scan_jsonl_files(str(tmp_path))
    assert daily["2026-09-29"]["msgs"] == 1
    assert daily["2026-09-29"]["input_tokens"] == 0
    assert daily["2026-09-30"]["msgs"] == 1
    assert daily["2026-09-30"]["input_tokens"] == 10
    assert daily["2026-09-30"]["models"]["claude-x"] == 115


def test_scan_winter_time_offset(tmp_path, amsterdam_tz):
    # CET is +1 in January: 23:30Z is already the next local day
    _write_session(tmp_path, [_user("2026-01-14T23:30:00Z")])
    assert core.scan_jsonl_files(str(tmp_path))["2026-01-15"]["msgs"] == 1


def test_scan_skips_junk_lines(tmp_path, amsterdam_tz):
    _write_session(tmp_path, [
        "", "{broken", {"type": "user"}, {"type": "user", "timestamp": "nope"},
        {"type": "summary", "timestamp": "2026-09-30T10:00:00Z"},
        _assistant("2026-09-30T10:00:00Z"),
    ])
    daily = core.scan_jsonl_files(str(tmp_path))
    assert list(daily) == ["2026-09-30"]
    assert daily["2026-09-30"]["output_tokens"] == 5


def test_build_stats_windows():
    now = datetime(2026, 9, 30, 12, 0)
    day = lambda msgs, i: {"msgs": msgs, "input_tokens": i, "output_tokens": 0,
                           "cache_read": 0, "models": {"m": i}}
    daily = {
        "2026-09-30": day(1, 100),
        "2026-09-23": day(2, 20),   # exactly 7 days back: in week window
        "2026-09-22": day(4, 3),    # outside week, inside month
        "2026-08-01": day(8, 1),    # outside month
        "bogus": day(99, 99),
    }
    s = core.build_stats(jsonl_daily=daily, stats_cache={"totalSessions": 7}, now=now)
    assert (s["today_msgs"], s["today_tokens"]) == (1, 100)
    assert (s["week_msgs"], s["week_tokens"]) == (3, 120)
    assert (s["month_msgs"], s["month_tokens"]) == (7, 123)
    assert s["total_sessions"] == 7
    assert "bogus" in s["jsonl_daily"]


def test_compute_weekly_tokens():
    daily = {"2026-09-30": {"input_tokens": 5, "output_tokens": 1},
             "2026-09-24": {"input_tokens": 2, "output_tokens": 0},
             "2026-09-23": {"input_tokens": 99, "output_tokens": 0}}
    assert core.compute_weekly_tokens(daily, date(2026, 9, 30)) == [2, 0, 0, 0, 0, 0, 6]


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
