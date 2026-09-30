"""In-app updates: check GitHub, download, verify, stage and swap the app bundle.

No PyObjC here, so it runs (and can be tested) outside the app. Everything
blocking is meant to run on a background thread; app.py hops back to the main
thread for UI. Only system binaries are spawned (curl, hdiutil, ditto,
codesign, bash) — never a Python interpreter, which is broken inside the
py2app bundle.
"""

import json
import os
import plistlib
import shutil
import subprocess
import tempfile

import core

CURL = "/usr/bin/curl"
HDIUTIL = "/usr/bin/hdiutil"
DITTO = "/usr/bin/ditto"
CODESIGN = "/usr/bin/codesign"
APP_NAME = "ClaudeUsage.app"


WORK_PREFIX = "claudeusage-update-"


class UpdateError(Exception):
    """Message is shown to the user as-is (Dutch)."""


def _run(args, timeout=120, **kw):
    # Explicit UTF-8: inside the bundle (started by launchd) the locale is ASCII,
    # and tool output with "…" or "—" would crash a text=True decode.
    return subprocess.run(args, capture_output=True, encoding="utf-8", errors="replace",
                          timeout=timeout, **kw)


def _curl(url: str, out_path: str = None, timeout: int = 30) -> str:
    args = [CURL, "-fsSL", "--max-time", str(timeout),
            "-H", "Accept: application/vnd.github+json",
            "-H", "User-Agent: ClaudeUsage-updater"]
    if out_path:
        args += ["-o", out_path]
    r = _run(args + [url], timeout=timeout + 10)
    if r.returncode != 0:
        raise UpdateError(f"downloaden mislukt ({r.stderr.strip() or r.returncode})")
    return r.stdout


def _detach(mnt: str):
    if os.path.ismount(mnt):
        r = _run([HDIUTIL, "detach", "-quiet", mnt])
        if r.returncode != 0:
            _run([HDIUTIL, "detach", "-quiet", "-force", mnt])


def cleanup_stale():
    """Remove work dirs (and mounts) left behind by earlier failed updates."""
    tmp = tempfile.gettempdir()
    for name in os.listdir(tmp):
        if name.startswith(WORK_PREFIX):
            path = os.path.join(tmp, name)
            if os.path.exists(os.path.join(path, "swap.sh")):
                continue   # a swap may still be running from this dir
            _detach(os.path.join(path, "mnt"))
            shutil.rmtree(path, ignore_errors=True)


def fetch_latest_release(url: str = core.UPDATE_API_URL):
    """Return parse_release() of the latest release, or None if there is none."""
    try:
        obj = json.loads(_curl(url, timeout=20))
    except ValueError:
        raise UpdateError("onleesbaar antwoord van GitHub")
    return core.parse_release(obj)


def _bundle_info(app_path: str) -> dict:
    with open(os.path.join(app_path, "Contents", "Info.plist"), "rb") as f:
        return plistlib.load(f)


def download_and_stage(release: dict, current_version: str) -> str:
    """Download the release DMG, verify its signature and contents, and copy
    the new app to a private temp dir. Returns the staged .app path.
    Raises UpdateError; never touches the installed app."""
    if not release.get("dmg_url"):
        raise UpdateError("deze release heeft geen DMG")
    if not release.get("sig_url"):
        raise UpdateError("deze release is niet ondertekend")
    if not core.is_newer(release["version"], current_version):
        raise UpdateError(f"{release['version']} is niet nieuwer dan {current_version}")

    cleanup_stale()
    work = tempfile.mkdtemp(prefix=WORK_PREFIX)
    try:
        dmg = os.path.join(work, core.DMG_ASSET)
        sig = _curl(release["sig_url"], timeout=30)
        _curl(release["dmg_url"], out_path=dmg, timeout=600)

        with open(dmg, "rb") as f:
            data = f.read()
        if not core.verify_release_signature(data, sig):
            raise UpdateError("handtekening klopt niet — update geweigerd")

        mnt = os.path.join(work, "mnt")
        os.mkdir(mnt)
        staged = os.path.join(work, APP_NAME)
        try:
            r = _run([HDIUTIL, "attach", "-nobrowse", "-readonly", "-noautoopen",
                      "-mountpoint", mnt, dmg])
            if r.returncode != 0:
                raise UpdateError("DMG openen mislukt")
            src = os.path.join(mnt, APP_NAME)
            if not os.path.isdir(src):
                raise UpdateError("geen ClaudeUsage.app in de DMG")
            if _run([DITTO, src, staged]).returncode != 0:
                raise UpdateError("app kopiëren mislukt")
        finally:
            # Also when attach itself raised half-way: never leave the DMG mounted.
            _detach(mnt)

        info = _bundle_info(staged)
        if info.get("CFBundleIdentifier") != core.BUNDLE_ID:
            raise UpdateError("DMG bevat een andere app")
        got = info.get("CFBundleShortVersionString", "")
        # The signature covers the DMG, this pins it to the advertised version:
        # an old signed DMG can't be replayed as a "new" release (downgrade).
        if core.parse_version(got) != core.parse_version(release["version"]):
            raise UpdateError(f"versie in DMG ({got}) klopt niet met release ({release['version']})")
        if _run([CODESIGN, "--verify", "--deep", staged]).returncode != 0:
            raise UpdateError("code-signature van de nieuwe app ongeldig")
        os.unlink(dmg)
        return staged
    except UpdateError:
        shutil.rmtree(work, ignore_errors=True)
        raise
    except Exception as e:
        shutil.rmtree(work, ignore_errors=True)
        raise UpdateError(f"onverwachte fout: {e}")


# Waits for the running app to exit, swaps the bundle (with rollback), restarts.
_SWAP_SCRIPT = r"""#!/bin/bash
PID="$1"; TARGET="$2"; NEW="$3"; LABEL="$4"; LOG="$5"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') update: $*" >> "$LOG"; }
for _ in $(seq 1 60); do kill -0 "$PID" 2>/dev/null || break; sleep 0.5; done
BACKUP="$TARGET.previous"
rm -rf "$BACKUP"
if mv "$TARGET" "$BACKUP" && /usr/bin/ditto "$NEW" "$TARGET"; then
    /usr/bin/xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null
    rm -rf "$BACKUP"
    log "nieuwe versie geïnstalleerd"
else
    rm -rf "$TARGET"
    mv "$BACKUP" "$TARGET"
    log "vervangen mislukt, oude versie teruggezet"
fi
if /bin/launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    /bin/launchctl kickstart -k "gui/$(id -u)/$LABEL"
else
    /usr/bin/open "$TARGET"
fi
rm -rf "$(dirname "$NEW")"
"""


def launch_swap(staged_app: str, target_app: str, pid: int, label: str = core.BUNDLE_ID):
    """Start the detached swap script; the caller must quit right after."""
    script = os.path.join(os.path.dirname(staged_app), "swap.sh")
    with open(script, "w", encoding="utf-8") as f:
        f.write(_SWAP_SCRIPT)
    os.chmod(script, 0o700)
    subprocess.Popen(
        ["/bin/bash", script, str(pid), target_app, staged_app, label, core.LOG_FILE],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
