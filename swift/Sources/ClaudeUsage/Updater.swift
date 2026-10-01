import AppKit
import UsageCore

/// In-app updates (port of updater.py + the update part of app.py): check GitHub,
/// download, verify (Ed25519 signature, bundle id, version, code signature),
/// stage, then swap the bundle from a detached script with rollback and restart.
///
/// The expected bundle id is our own: the dev build only ever updates to a dev
/// build, never to the released app. `--update-feed <url>` (dev build only)
/// points the check at a local release JSON for end-to-end tests.
extension AppDelegate {
    static let workPrefix = "claudeusage-update-"

    var updateFeedURL: URL {
        if isDev, let i = CommandLine.arguments.firstIndex(of: "--update-feed"),
           i + 1 < CommandLine.arguments.count, let url = URL(string: CommandLine.arguments[i + 1]) {
            return url
        }
        return updateAPIURL
    }

    var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    func maybeCheckUpdates(force: Bool = false) {
        guard isBundled, !updateChecking, !updateInstalling, truthy(settings["update_check"]) else { return }
        let stored = loadJSONObject(paths.updateState)
        if update == nil, let latest = stored["latest"] as? [String: String],
           isNewer(latest["version"] ?? "", than: state.version) {
            update = latest   // remembered from an earlier check, no network needed
        }
        if !force && !updateCheckDue(stored, now: Date()) { return }
        updateChecking = true
        let feed = updateFeedURL
        let strings = self.strings!
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var release: [String: String]? = nil
            var failure: UpdateError? = nil
            do {
                let data = try Self.curl(feed, timeout: 20, strings: strings)
                guard let obj = try? JSONSerialization.jsonObject(with: data) else {
                    throw UpdateError("bad_response", strings: strings)
                }
                release = parseRelease(obj)
            } catch let e as UpdateError {
                failure = e
            } catch {
                failure = UpdateError("unexpected", ["detail": "\(error)"], strings: strings)
            }
            DispatchQueue.main.async { self?.onUpdateChecked(release, failure) }
        }
    }

    func onUpdateChecked(_ release: [String: String]?, _ error: UpdateError?) {
        updateChecking = false
        var stored = loadJSONObject(paths.updateState)
        stored["last_check"] = pyIsoformatUTC(Date())
        if let error {
            log("update-check mislukt: \(error)")
        } else {
            stored["latest"] = release ?? NSNull()
            if let release, let version = release["version"], isNewer(version, than: state.version) {
                update = release
                if stored["notified_version"] as? String != version {
                    stored["notified_version"] = version
                    log("update beschikbaar: \(version)")
                    if notificationsEnabled {
                        post(id: "update-\(version)",
                             title: strings.t("notif_update_title", lang, ["version": version]),
                             body: strings.t("notif_update_body", lang), pct: -1)
                    }
                }
            } else {
                update = nil
            }
        }
        do {
            try saveJSONObject(stored, to: paths.updateState)
        } catch {
            log("update-status opslaan mislukt: \(error)")
        }
        pushData()
    }

    /// What the settings view shows (app.py _update_view).
    func updateView() -> JSONObject? {
        guard let update else { return nil }
        let s = updateInstalling ? "working" : (updateError != nil ? "error" : "available")
        return ["version": update["version"] ?? "", "state": s, "message": updateError ?? ""]
    }

    func startUpdate() {
        guard let release = update, !updateInstalling, let version = release["version"] else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = strings.t("alert_install_title", lang, ["version": version])
        alert.informativeText = strings.t("alert_install_body", lang, ["current": state.version])
        alert.addButton(withTitle: strings.t("btn_update", lang))
        alert.addButton(withTitle: strings.t("btn_later", lang))
        let htmlURL = release["html_url"].flatMap { $0.isEmpty ? nil : URL(string: $0) }
        if htmlURL != nil { alert.addButton(withTitle: strings.t("btn_whats_new", lang)) }
        let choice = alert.runModal()
        if choice == .alertThirdButtonReturn, let url = htmlURL {
            NSWorkspace.shared.open(url)
            return
        }
        guard choice == .alertFirstButtonReturn else { return }

        log("update naar \(version) gestart")
        updateInstalling = true
        updateError = nil
        pushData()
        let current = state.version
        let expectedID = Bundle.main.bundleIdentifier ?? ""
        let strings = self.strings!
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let staged = try Self.downloadAndStage(release, current: current, bundleID: expectedID,
                                                       strings: strings)
                DispatchQueue.main.async { self?.onUpdateStaged(staged, nil) }
            } catch let e as UpdateError {
                DispatchQueue.main.async { self?.onUpdateStaged(nil, e) }
            } catch {
                let e = UpdateError("unexpected", ["detail": "\(error)"], strings: strings)
                DispatchQueue.main.async { self?.onUpdateStaged(nil, e) }
            }
        }
    }

    func onUpdateStaged(_ staged: URL?, _ error: UpdateError?) {
        guard let staged, error == nil else {
            let e = error ?? UpdateError("unexpected", ["detail": "?"], strings: strings)
            let message = e.message(lang)
            updateInstalling = false
            updateError = message
            log("update mislukt: \(e)")
            pushData()
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = strings.t("alert_failed_title", lang)
            alert.informativeText = strings.t("alert_failed_body", lang, ["error": message])
            alert.runModal()
            return
        }
        let target = Bundle.main.bundleURL
        log("update klaargezet, vervangen van \(target.path) en herstarten")
        do {
            try Self.launchSwap(staged: staged, target: target, pid: getpid(),
                                label: Bundle.main.bundleIdentifier ?? "", logFile: paths.log)
        } catch {
            onUpdateStaged(nil, UpdateError("install", ["detail": "\(error)"], strings: strings))
            return
        }
        NSApp.terminate(nil)
    }

    // MARK: - Work off the main thread (updater.py)

    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> (status: Int32, out: Data, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        guard (try? p.run()) != nil else { return (-1, Data(), "kan \(tool) niet starten") }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, o, String(decoding: e, as: UTF8.self))
    }

    static func curl(_ url: URL, to out: URL? = nil, timeout: Int, strings: Strings) throws -> Data {
        var args = ["-fsSL", "--max-time", String(timeout),
                    "-H", "Accept: application/vnd.github+json", "-H", "User-Agent: ClaudeUsage-updater"]
        if let out { args += ["-o", out.path] }
        let r = run("/usr/bin/curl", args + [url.absoluteString])
        guard r.status == 0 else {
            let detail = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdateError("download", ["detail": detail.isEmpty ? "\(r.status)" : detail], strings: strings)
        }
        return r.out
    }

    static func detach(_ mnt: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: mnt.path, isDirectory: &isDir) else { return }
        if run("/usr/bin/hdiutil", ["detach", "-quiet", mnt.path]).status != 0 {
            run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mnt.path])
        }
    }

    /// Remove work dirs (and mounts) left behind by earlier failed updates.
    static func cleanupStale() {
        let tmp = FileManager.default.temporaryDirectory
        for name in (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        where name.hasPrefix(workPrefix) {
            let dir = tmp.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("swap.sh").path) {
                continue   // a swap may still be running from this dir
            }
            detach(dir.appendingPathComponent("mnt"))
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// Download the release DMG, verify its signature and contents, and copy the
    /// new app to a private temp dir. Never touches the installed app.
    static func downloadAndStage(_ release: [String: String], current: String, bundleID: String,
                                 strings: Strings) throws -> URL {
        func fail(_ key: String, _ values: [String: Any] = [:]) -> UpdateError {
            UpdateError(key, values, strings: strings)
        }
        guard let dmgURL = release["dmg_url"].flatMap({ $0.isEmpty ? nil : URL(string: $0) }) else { throw fail("no_dmg") }
        guard let sigURL = release["sig_url"].flatMap({ $0.isEmpty ? nil : URL(string: $0) }) else { throw fail("unsigned") }
        let version = release["version"] ?? ""
        guard isNewer(version, than: current) else { throw fail("not_newer", ["new": version, "current": current]) }

        cleanupStale()
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent(workPrefix + UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        do {
            let dmg = work.appendingPathComponent(dmgAsset)
            let sig = String(decoding: try curl(sigURL, timeout: 30, strings: strings), as: UTF8.self)
            try curl(dmgURL, to: dmg, timeout: 600, strings: strings)
            guard verifyReleaseSignature(try Data(contentsOf: dmg), sig) else { throw fail("sig_invalid") }

            let mnt = work.appendingPathComponent("mnt")
            try FileManager.default.createDirectory(at: mnt, withIntermediateDirectories: false)
            let appName = Bundle.main.bundleURL.lastPathComponent
            let staged = work.appendingPathComponent(appName)
            do {
                defer { detach(mnt) }   // never leave the DMG mounted
                guard run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen",
                                               "-mountpoint", mnt.path, dmg.path]).status == 0
                else { throw fail("dmg_open") }
                let src = mnt.appendingPathComponent(appName)
                guard FileManager.default.fileExists(atPath: src.path) else { throw fail("no_app") }
                guard run("/usr/bin/ditto", [src.path, staged.path]).status == 0 else { throw fail("copy") }
            }

            let info = NSDictionary(contentsOf: staged.appendingPathComponent("Contents/Info.plist")) ?? [:]
            guard info["CFBundleIdentifier"] as? String == bundleID else { throw fail("other_app") }
            let got = info["CFBundleShortVersionString"] as? String ?? ""
            // The signature covers the DMG, this pins it to the advertised version:
            // an old signed DMG can't be replayed as a "new" release (downgrade).
            guard parseVersion(got) == parseVersion(version) else {
                throw fail("version_mismatch", ["got": got, "expected": version])
            }
            guard run("/usr/bin/codesign", ["--verify", "--deep", staged.path]).status == 0 else {
                throw fail("codesign")
            }
            try? FileManager.default.removeItem(at: dmg)
            return staged
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
    }

    // Waits for the running app to exit, swaps the bundle (with rollback), restarts.
    static let swapScript = #"""
    #!/bin/bash
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
    """#

    /// Start the swap script in its own session (so launchd doesn't kill it along
    /// with our LaunchAgent job); the caller must quit right after.
    static func launchSwap(staged: URL, target: URL, pid: pid_t, label: String, logFile: URL) throws {
        let script = staged.deletingLastPathComponent().appendingPathComponent("swap.sh")
        try swapScript.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd: Int32 in 0...2 {
            posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0)
        }
        let argv = ["/bin/bash", script.path, String(pid), target.path, staged.path, label, logFile.path]
        var cargs = argv.map { strdup($0) } + [nil]
        defer { cargs.forEach { free($0) } }
        var child: pid_t = 0
        let rc = posix_spawn(&child, "/bin/bash", &actions, &attr, &cargs, environ)
        guard rc == 0 else { throw POSIXError(POSIXErrorCode(rawValue: rc) ?? .EIO) }
    }
}
