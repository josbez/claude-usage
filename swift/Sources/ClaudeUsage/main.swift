import AppKit
import UsageCore

let args = CommandLine.arguments

// Test hooks (no UI): render the notification thumbnail to a file.
//   ClaudeUsage --render-status-image <pct> <out.png>
if args.count == 4, args[1] == "--render-status-image", let pct = Int(args[2]) {
    do {
        try renderStatusImage(pct: pct).write(to: URL(fileURLWithPath: args[3]))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(1)
    }
}

// Render the menu bar ring at 4x on a light or dark menu bar background:
//   ClaudeUsage --render-menubar-ring <pct> <light|dark> <out.png>
if args.count == 5, args[1] == "--render-menubar-ring", let pct = Int(args[2]) {
    let dark = args[3] == "dark"
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
    let icon = menubarRingImage(menubarRing(sessionPct: pct), appearance: appearance)
    let scale: CGFloat = 4, side = 24 * scale
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
    NSRect(x: 0, y: 0, width: side, height: side).fill()
    let r = NSRect(x: 4 * scale, y: 4 * scale, width: 16 * scale, height: 16 * scale)
    if icon.isTemplate {
        // What macOS does with a template image in the menu bar: tint with the label colour
        let tinted = NSImage(size: icon.size, flipped: false) { rect in
            icon.draw(in: rect)
            (dark ? NSColor.white : NSColor.black).set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: r)
    } else {
        icon.draw(in: r)
    }
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[4]))
    exit(0)
}

// Check a release file against its .sig with the release key:
//   ClaudeUsage --verify-release <file> <file.sig>
if args.count == 4, args[1] == "--verify-release",
   let data = FileManager.default.contents(atPath: args[2]),
   let sig = try? String(contentsOfFile: args[3], encoding: .utf8) {
    let ok = verifyReleaseSignature(data, sig)
    print(ok ? "✓ handtekening geldig" : "✗ handtekening ongeldig")
    exit(ok ? 0 : 1)
}

// Probe (taak 48): does claude.ai answer a plain URLSession request with the
// sessionKey cookie, or does Cloudflare block it? Prints statuses and the key
// paths of the usage response (names and types only, no values).
//   ClaudeUsage --probe-native-fetch
if args.count == 2, args[1] == "--probe-native-fetch" {
    guard let key = try? claudeSessionKey(), !key.isEmpty else { print("geen sessionKey"); exit(1) }
    let agents = ["default": nil,
                  "safari": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"]
    func get(_ path: String, _ ua: String?) -> (Int, String, Any?) {
        var req = URLRequest(url: URL(string: "https://claude.ai" + path)!, timeoutInterval: 20)
        req.setValue("sessionKey=\(key)", forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let ua { req.setValue(ua, forHTTPHeaderField: "User-Agent") }
        req.httpShouldHandleCookies = false
        let sem = DispatchSemaphore(value: 0)
        var out: (Int, String, Any?) = (0, "", nil)
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let http = resp as? HTTPURLResponse
            let cf = http?.value(forHTTPHeaderField: "cf-mitigated") ?? ""
            out = (http?.statusCode ?? -1, cf.isEmpty ? (err.map { "\($0.localizedDescription)" } ?? "") : "cf-mitigated=\(cf)",
                   data.flatMap { try? JSONSerialization.jsonObject(with: $0) })
            sem.signal()
        }.resume()
        sem.wait()
        return out
    }
    func keyPaths(_ v: Any?, _ prefix: String = "") -> Set<String> {
        switch v {
        case let d as [String: Any]:
            return d.reduce(into: Set<String>()) { acc, kv in
                acc.formUnion(keyPaths(kv.value, prefix.isEmpty ? kv.key : "\(prefix).\(kv.key)"))
            }
        case let a as [Any]:
            return a.isEmpty ? ["\(prefix)[] (leeg)"] : a.reduce(into: Set<String>()) { $0.formUnion(keyPaths($1, "\(prefix)[]")) }
        case is NSNull: return ["\(prefix): null"]
        case is String: return ["\(prefix): string"]
        case let n as NSNumber: return ["\(prefix): \(CFGetTypeID(n) == CFBooleanGetTypeID() ? "bool" : "number")"]
        default: return ["\(prefix): ?"]
        }
    }
    var usageShape = Set<String>()
    for (name, ua) in agents.sorted(by: { $0.key < $1.key }) {
        let (st, note, json) = get("/api/bootstrap", ua)
        print("[\(name)] bootstrap: HTTP \(st) json=\(json != nil) \(note)")
        let orgs = (((json as? [String: Any])?["account"] as? [String: Any])?["memberships"] as? [[String: Any]] ?? [])
            .compactMap { ($0["organization"] as? [String: Any])?["uuid"] as? String }
        for (i, org) in orgs.enumerated() {
            let (st, note, json) = get("/api/organizations/\(org)/usage?cedar_ember=1", ua)
            let has = (json as? [String: Any])?["five_hour"] != nil
            print("[\(name)]   org \(i + 1) usage: HTTP \(st) five_hour=\(has) \(note)")
            if name == "default", has {
                usageShape.formUnion(keyPaths(json))
                // limits[]: only the server's own labels and percentages, no account data
                for l in (json as? [String: Any])?["limits"] as? [[String: Any]] ?? [] {
                    print("    limits: kind=\(l["kind"] ?? "-") group=\(l["group"] ?? "-") "
                          + "severity=\(l["severity"] ?? "-") percent=\(l["percent"] ?? "-") active=\(l["is_active"] ?? "-")")
                }
            }
        }
    }
    // Key paths and value types of the usage response, never the values themselves
    print("usage-sleutels:")
    usageShape.sorted().forEach { print("  \($0)") }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
let delegate = AppDelegate()
// --test-notification: post one sample limit notification after launch.
delegate.postTestNotification = args.contains("--test-notification")
app.delegate = delegate
app.run()
