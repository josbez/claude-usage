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

// Check a release file against its .sig with the release key:
//   ClaudeUsage --verify-release <file> <file.sig>
if args.count == 4, args[1] == "--verify-release",
   let data = FileManager.default.contents(atPath: args[2]),
   let sig = try? String(contentsOfFile: args[3], encoding: .utf8) {
    let ok = verifyReleaseSignature(data, sig)
    print(ok ? "✓ handtekening geldig" : "✗ handtekening ongeldig")
    exit(ok ? 0 : 1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
let delegate = AppDelegate()
// --test-notification: post one sample limit notification after launch.
delegate.postTestNotification = args.contains("--test-notification")
app.delegate = delegate
app.run()
