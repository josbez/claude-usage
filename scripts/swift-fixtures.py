#!/usr/bin/python3
"""Export what the Swift app shares with core.py (taak 35).

- swift/Resources/strings.json: STRINGS, DAYS and MONTHS — one source of truth
  for both stacks (tests/test_core.py checks it is up to date).
- swift/Tests/UsageCoreTests/Fixtures/core.json: inputs and the outputs
  core.py gives for them, at a fixed "now" and time zone. The Swift tests must
  reproduce every output exactly (parity is the acceptance criterion).

Run after changing STRINGS or the pure functions: /usr/bin/python3 scripts/swift-fixtures.py
"""

import json
import os
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
FIXTURES_PATH = os.path.join(ROOT, "swift", "Tests", "UsageCoreTests", "Fixtures", "core.json")


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
    {"account_email": "user@example.com", "account_name": "  Sam  ", "account_plan": " Pro "},
    {"account_email": None, "account_name": None, "account_plan": None},
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
    c["t"] = [{"key": k, "lang": l, "kw": kw, "out": core.t(k, l, **kw)}
              for k, kw in T_CASES for l in langs]
    return fx


def main():
    write_json(STRINGS_PATH, shared_strings())
    write_json(FIXTURES_PATH, build_fixtures())
    print(f"✓ {os.path.relpath(STRINGS_PATH, ROOT)}")
    print(f"✓ {os.path.relpath(FIXTURES_PATH, ROOT)}")


if __name__ == "__main__":
    main()
