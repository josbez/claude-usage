#!/usr/bin/env python3
"""Sign ClaudeUsage.dmg for in-app updates.

    /usr/bin/python3 scripts/sign-release.py --init   # once: create the signing key
    /usr/bin/python3 scripts/sign-release.py          # sign ClaudeUsage.dmg -> ClaudeUsage.dmg.sig

The private key stays in ~/.config/claude-usage/ and must never be committed.
Back it up (e.g. in a password manager): without it you cannot ship updates
that existing installs will accept. The matching public key is
UPDATE_PUBLIC_KEY_HEX in core.py.
"""

import os
import sys

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, HERE)
import core  # noqa: E402

from Crypto.PublicKey import ECC  # noqa: E402

KEY_DIR = os.path.expanduser("~/.config/claude-usage")
KEY_FILE = os.path.join(KEY_DIR, "release-signing-key.pem")
DMG = os.path.join(HERE, core.DMG_ASSET)
SIG = os.path.join(HERE, core.SIG_ASSET)


def public_hex(key) -> str:
    return key.public_key().export_key(format="raw").hex()


def init():
    if os.path.exists(KEY_FILE):
        sys.exit(f"✗ {KEY_FILE} bestaat al — niet overschreven.")
    os.makedirs(KEY_DIR, mode=0o700, exist_ok=True)
    key = ECC.generate(curve="ed25519")
    fd = os.open(KEY_FILE, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(key.export_key(format="PEM"))
    print(f"✓ Sleutel aangemaakt: {KEY_FILE} (maak een back-up!)")
    print(f"  Publieke sleutel voor core.py UPDATE_PUBLIC_KEY_HEX:\n  {public_hex(key)}")


def sign():
    if not os.path.exists(KEY_FILE):
        sys.exit(f"✗ Geen signing key in {KEY_FILE}. Eenmalig: scripts/sign-release.py --init")
    with open(KEY_FILE) as f:
        key = ECC.import_key(f.read())
    if public_hex(key) != core.UPDATE_PUBLIC_KEY_HEX:
        sys.exit("✗ Signing key hoort niet bij UPDATE_PUBLIC_KEY_HEX in core.py — "
                 "bestaande installaties zouden deze update weigeren.")
    with open(DMG, "rb") as f:
        data = f.read()
    sig = core.sign_release(data, key)
    if not core.verify_release_signature(data, sig):
        sys.exit("✗ Zelfcontrole van de handtekening faalde.")
    with open(SIG, "w") as f:
        f.write(sig + "\n")
    print(f"✓ {os.path.basename(SIG)} aangemaakt en geverifieerd")


if __name__ == "__main__":
    init() if "--init" in sys.argv[1:] else sign()
