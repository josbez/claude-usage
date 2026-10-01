import AppKit

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

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
let delegate = AppDelegate()
// --test-notification: post one sample limit notification after launch.
delegate.postTestNotification = args.contains("--test-notification")
app.delegate = delegate
app.run()
