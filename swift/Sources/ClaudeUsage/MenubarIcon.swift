import AppKit
import UsageCore

/// The ring icon in the menu bar (taak 49), drawn in code at 16 pt so it stays
/// sharp. Below 75% a template image (macOS tints it like the other menu bar
/// icons); from 75% on the popover's stress colour, with a track that follows
/// the menu bar's appearance.
func menubarRingImage(_ ring: MenubarRing, appearance: NSAppearance) -> NSImage {
    let size = NSSize(width: 16, height: 16)
    let line: CGFloat = 2
    let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    let image = NSImage(size: size, flipped: false) { rect in
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = (min(rect.width, rect.height) - line) / 2 - 0.5
        let fg: NSColor = ring.rgb == nil ? .black : (dark ? .white : .black)

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = line
        fg.withAlphaComponent(0.35).setStroke()
        track.stroke()

        guard ring.fraction > 0 else { return true }
        let arc = NSBezierPath()
        // From 12 o'clock, clockwise
        arc.appendArc(withCenter: center, radius: radius, startAngle: 90,
                      endAngle: 90 - 360 * CGFloat(ring.fraction), clockwise: true)
        arc.lineWidth = line
        arc.lineCapStyle = ring.fraction < 1 ? .round : .butt
        if let (r, g, b) = ring.rgb {
            NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1).setStroke()
        } else {
            NSColor.black.setStroke()
        }
        arc.stroke()
        return true
    }
    image.isTemplate = ring.rgb == nil
    return image
}

extension AppDelegate {
    var menubarIcon: String { settings["menubar_icon"] as? String ?? "ring" }

    /// Existing installs keep the emoji (no silent change); new ones get the ring.
    /// An install counts as existing when it has written usage data before.
    func migrateMenubarIcon() {
        guard loadJSONObject(paths.settings)["menubar_icon"] == nil else { return }
        if FileManager.default.fileExists(atPath: paths.limits.path) {
            updateSetting("menubar_icon", "emoji")
        }
    }

    /// Puts a status title ("😅 45% / 82% · 2u10m") in the menu bar, as text or
    /// as ring + text. Only call when the popover is closed (popover anchor).
    func applyStatusTitle(_ text: String) {
        guard let button = statusItem.button else { return }
        appliedTitle = text
        if menubarIcon == "ring" {
            let rest = titleWithoutFace(text)
            button.image = menubarRingImage(menubarRing(sessionPct: menubarPct),
                                            appearance: button.effectiveAppearance)
            button.imagePosition = rest.isEmpty && devMark.isEmpty ? .imageOnly : .imageLeading
            button.title = (devMark + rest).trimmingCharacters(in: .whitespaces)
        } else {
            button.image = nil
            button.title = devMark + text
        }
    }

    /// The coloured ring's track follows light/dark: redraw when it changes.
    func observeMenubarAppearance() {
        appearanceObservation = statusItem.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self, self.menubarIcon == "ring", let text = self.appliedTitle else { return }
                // Same width, so safe while the popover is open.
                self.applyStatusTitle(text)
            }
        }
    }
}
