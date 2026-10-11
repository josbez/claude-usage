#!/usr/bin/env python3
"""Keeps the Mac and Windows backlogs in sync (docs/PLATFORMS.md, sync rule 2).

Fails when a paired item (`↔ M3` / `↔ W5.5`) points at an item that doesn't
exist, or when the other side doesn't point back; and when FEATURES.md names a
backlog item that doesn't exist.

    python3 scripts/check-backlogs.py
"""
import re
import sys
from pathlib import Path

DOCS = Path(__file__).resolve().parent.parent / "docs"
BACKLOGS = {"M": DOCS / "MAC-BACKLOG.md", "W": DOCS / "WINDOWS-BACKLOG.md"}

# An item is a section ("## M0 — …") or a bullet ("- **W0.2** …").
ITEM = re.compile(r"^(?:## |- \*\*)([MW]\d+(?:\.\d+)?)\b(.*)$")
REF = re.compile(r"[MW]\d+(?:\.\d+)?")


def read_items(path):
    """{item id: [ids it pairs with]}"""
    items = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        m = ITEM.match(line)
        if not m:
            continue
        item, rest = m.groups()
        pairs = []
        if "↔" in rest:
            # Only the ids right after ↔ (before the description starts).
            head = rest.split("↔", 1)[1]
            head = re.split(r"[^\sMW0-9.,]", head, maxsplit=1)[0]
            pairs = REF.findall(head)
        items[item] = pairs
    return items


def main():
    items = {}
    for prefix, path in BACKLOGS.items():
        for item, pairs in read_items(path).items():
            if not item.startswith(prefix):
                continue
            items[item] = pairs

    errors = []
    for item, pairs in items.items():
        for other in pairs:
            if other not in items:
                errors.append(f"{item} ↔ {other}: {other} doesn't exist")
            elif item not in items[other]:
                errors.append(f"{item} ↔ {other}: {other} doesn't point back at {item}")

    features = (DOCS / "FEATURES.md").read_text(encoding="utf-8")
    for row in features.splitlines():
        if not row.startswith("|"):
            continue
        for ref in REF.findall(row):
            if ref not in items and not any(i.startswith(ref + ".") for i in items):
                errors.append(f"FEATURES.md names {ref}, which doesn't exist")

    for e in errors:
        print(f"✗ {e}", file=sys.stderr)
    if errors:
        sys.exit(1)
    print(f"✓ backlogs in sync ({len(items)} items)")


if __name__ == "__main__":
    main()
