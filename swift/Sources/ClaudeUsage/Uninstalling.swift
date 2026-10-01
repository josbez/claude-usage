import AppKit
import UsageCore

/// "Uninstall…" in settings (taak 38): own files, the app to the Trash, the
/// LaunchAgent, and as the very last step booting the agent out (that stops us).
extension AppDelegate {
    func confirmUninstall() {
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = strings.t("alert_uninstall_title", lang)
        alert.informativeText = strings.t("alert_uninstall_body", lang)
        let confirm = alert.addButton(withTitle: strings.t("btn_uninstall", lang))
        if #available(macOS 11.0, *) { confirm.hasDestructiveAction = true }
        alert.addButton(withTitle: strings.t("btn_cancel", lang))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = strings.t("alert_uninstall_keep_history", lang)
        alert.suppressionButton?.state = .on
        guard alert.runModal() == .alertFirstButtonReturn else {
            log("verwijderen geannuleerd")
            return
        }
        uninstall(keepHistory: alert.suppressionButton?.state == .on)
    }

    private func uninstall(keepHistory: Bool) {
        log("verwijderen gestart (geschiedenis \(keepHistory ? "bewaard" : "weg"))")
        timer?.invalidate()
        let fm = FileManager.default
        for url in paths.uninstallTargets(keepHistory: keepHistory) where fm.fileExists(atPath: url.path) {
            do { try fm.removeItem(at: url) } catch { log("verwijderen \(url.lastPathComponent) mislukt: \(error)") }
        }
        // From here on log() would recreate the log file: stay quiet unless it fails.
        NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let error = error {
                    self.log("app naar de Prullenbak mislukt: \(error)")
                    let alert = NSAlert()
                    alert.messageText = self.strings.t("alert_uninstall_failed_title", self.lang)
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                    return
                }
                if let plist = self.paths.launchAgent, fm.fileExists(atPath: plist.path) {
                    try? fm.removeItem(at: plist)
                }
                if !self.isDev {
                    // KeepAlive is false: bootout stops this process and launchd won't restart it.
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                    p.arguments = ["bootout", "gui/\(getuid())/\(Paths.launchAgentLabel)"]
                    try? p.run()
                    p.waitUntilExit()
                }
                NSApp.terminate(nil)   // not started by launchd, or bootout didn't stop us
            }
        }
    }
}
