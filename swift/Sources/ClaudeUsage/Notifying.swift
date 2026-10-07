import AppKit
import UsageCore
import UserNotifications

/// Limit notifications and usage history (port of the matching parts of app.py).
/// The dev build puts "β " before each title so its notifications are told
/// apart from the released app's while both run side by side.
extension AppDelegate {
    func setupNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = notifyDelegate
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            DispatchQueue.main.async {
                self?.log("notificatie-toestemming: \(granted ? "ja" : "nee")"
                          + (error.map { " (\($0.localizedDescription))" } ?? ""))
            }
        }
        notifyCenter = center
        state.notificationsAvailable = true
        if postTestNotification {
            let pct = ((loadJSONObject(paths.limits)["five_hour"] as? JSONObject)?["utilization"] as? NSNumber)?.intValue ?? 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.post(id: "test-\(UUID().uuidString)",
                           title: "\(self?.strings.t("limit_five_hour", self?.lang ?? "en") ?? "") — test",
                           body: "\(pct)%", pct: pct)
            }
        }
    }

    func post(id: String, title: String, body: String, pct: Int) {
        guard let center = notifyCenter else { return }
        let content = UNMutableNotificationContent()
        content.title = devMark + title
        content.body = body
        content.sound = .default
        if pct >= 0, let attachment = statusAttachment(pct: pct) {
            content.attachments = [attachment]
        }
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async {
                self?.log("notificatie mislukt (\(id)): \(error.localizedDescription)")
            }
        }
        log("notificatie: \(title)")
    }

    var notificationsEnabled: Bool { truthy(settings["notifications"]) }

    func notifyLimits(_ limits: JSONObject) {
        guard notifyCenter != nil else { return }
        var (notes, newState) = formatter.dueNotifications(limits, state: loadJSONObject(paths.notifyState),
                                                           lang: lang)
        if !notificationsEnabled {
            // Still record crossed thresholds, so switching back on doesn't
            // replay warnings for this window.
            notes.forEach { log("notificatie onderdrukt (meldingen uit): \($0.title)") }
            notes = []
        }
        for note in notes {
            post(id: note.id, title: note.title, body: note.body, pct: note.pct)
        }
        do {
            try saveJSONObject(newState, to: paths.notifyState)
        } catch {
            log("notificatie-check mislukt: \(error)")
        }
    }

    /// Thumbnail with ring/colour/emoji for this limit. The system moves the
    /// file into its own store, so each notification gets a fresh one.
    func statusAttachment(pct: Int) -> UNNotificationAttachment? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudeusage-\(UUID().uuidString).png")
        do {
            try renderStatusImage(pct: pct, theme: formatter.faceTheme(settings)).write(to: url)
            return try UNNotificationAttachment(identifier: "status", url: url)
        } catch {
            log("notificatie-afbeelding mislukt: \(error)")
            return nil
        }
    }

    /// Our own usage history (the API keeps none). Never lets a fetch fail.
    func recordHistory(_ limits: JSONObject) {
        do {
            try appendHistory(historyRecord(limits), base: paths.historyDir)
        } catch {
            log("geschiedenis opslaan mislukt: \(error)")
        }
    }
}

/// The popover's session donut as a PNG: ring filled to pct, stress colour,
/// menu bar emoji in the centre (app.py render_status_image).
func renderStatusImage(pct: Int, theme: FaceTheme? = nil, size: Int = 256) throws -> Data {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: rep)
    else { throw CocoaError(.featureUnsupported) }

    let (r, g, b) = colorForPct(Double(pct))
    func color(_ mixWithWhite: CGFloat = 0) -> NSColor {
        let c = [CGFloat(r), CGFloat(g), CGFloat(b)].map { $0 / 255 + (1 - $0 / 255) * mixWithWhite }
        return NSColor(deviceRed: c[0], green: c[1], blue: c[2], alpha: 1)
    }
    let s = CGFloat(size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    defer { NSGraphicsContext.restoreGraphicsState() }

    // Tinted tile, like .card-session (stress colour 14% over white)
    color(0.86).setFill()
    NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: s, height: s),
                 xRadius: s * 0.22, yRadius: s * 0.22).fill()

    let center = NSPoint(x: s / 2, y: s / 2)
    let ringRadius = s * 0.34, line = s * 0.1

    let track = NSBezierPath()
    track.appendArc(withCenter: center, radius: ringRadius, startAngle: 0, endAngle: 360)
    track.lineWidth = line
    color(0.70).setStroke()
    track.stroke()

    let fill = CGFloat(max(0, min(100, pct)))
    if fill > 0 {
        let arc = NSBezierPath()
        // y-up coordinates: 90° is 12 o'clock, clockwise like the popover
        arc.appendArc(withCenter: center, radius: ringRadius, startAngle: 90,
                      endAngle: 90 - 360 * fill / 100, clockwise: true)
        arc.lineWidth = line
        arc.lineCapStyle = .round
        color().setStroke()
        arc.stroke()
    }

    let face = NSAttributedString(string: faceIcon(pct, theme: theme),
                                  attributes: [.font: NSFont.systemFont(ofSize: s * 0.42)])
    let sz = face.size()
    face.draw(at: NSPoint(x: center.x - sz.width / 2, y: center.y - sz.height / 2))
    ctx.flushGraphics()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return png
}

/// Show banners even while the popover makes us the active app.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void) {
        completion([.banner, .list, .sound])
    }
}
