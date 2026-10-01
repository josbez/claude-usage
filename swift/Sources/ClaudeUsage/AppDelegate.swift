import AppKit
import UsageCore
import UserNotifications
import WebKit

/// Native port of app.py: menu bar + popover with dashboard.html (fase 1) and
/// the usage fetch through a hidden WKWebView (fase 2, Fetching.swift),
/// notifications and history (fase 3, Notifying.swift). Updates follow in fase 4.
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    static let popoverWidth: CGFloat = 360
    static let popoverMinHeight: CGFloat = 296   // main view; fixed
    static let popoverMaxHeight: CGFloat = 420   // settings view may grow up to this

    let isDev = Bundle.main.bundleIdentifier?.hasSuffix(".dev") ?? true
    lazy var paths = Paths(isDev: isDev)
    var strings: Strings!
    var lang = "en"
    var state = AppState()

    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var webView: WKWebView!
    var pendingTitle: String?
    var timer: Timer?
    var activity: NSObjectProtocol?

    // Fetching (Fetching.swift)
    var fetchJSTemplate = ""
    var fetchWebView: WKWebView?
    var fetchNavDelegate: FetchNavDelegate?
    var watchdog: Timer?
    var lastCookieMtime: Date?
    var lastSessionHash: String?
    var serviceChecking = false
    var serviceCheckedAt: Date?
    var loggedUnknownStatus = Set<String>()
    var loggedWeekWindows = Set<String>()

    // Notifications (Notifying.swift)
    var notifyCenter: UNUserNotificationCenter?
    let notifyDelegate = NotificationDelegate()
    var postTestNotification = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let url = Bundle.main.url(forResource: "strings", withExtension: "json"),
              let strings = try? Strings(contentsOf: url)
        else {
            log("strings.json ontbreekt in de bundle")
            NSApp.terminate(nil)
            return
        }
        self.strings = strings
        if let js = Bundle.main.url(forResource: "fetch", withExtension: "js"),
           let template = try? String(contentsOf: js, encoding: .utf8) {
            fetchJSTemplate = template
        } else {
            log("fetch.js ontbreekt in de bundle")
        }
        lang = languageFrom(Locale.preferredLanguages, defaultLang: strings.defaultLang)
        let info = Bundle.main.infoDictionary ?? [:]
        state.version = info["CFBundleShortVersionString"] as? String ?? "dev"
        state.build = info["CFBundleVersion"] as? String ?? ""
        log("app gestart (versie \(state.version), taal \(lang)\(isDev ? ", dev" : ""))")

        // Keep the periodic timer firing while in the background (no App Nap).
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "periodieke Claude-usage-refresh")

        setupNotifications()
        setupStatusItem()
        setupPopover()
        setupFetchWebView()
        startFetch()
        maybeCheckServiceStatus()
        // Every minute, also while the popover is open (common run loop modes).
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.current.add(t, forMode: .common)
        timer = t
    }

    // MARK: - Files

    func log(_ msg: String) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        let line = "\(f.string(from: Date())) \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: paths.log) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: paths.log)
        }
    }

    var settings: JSONObject { loadSettings(paths.settings) }

    func updateSetting(_ key: String, _ value: Any) {
        var s = settings
        s[key] = value
        do {
            try saveSettings(s, paths.settings)
            log("instelling \(key): \(value)")
        } catch {
            log("instelling opslaan mislukt: \(error)")
        }
    }

    var formatter: UsageFormatter { UsageFormatter(strings: strings) }

    // MARK: - Menu bar

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = devMark + "🚀"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))
    }

    /// Tells the dev build apart from the released app in the menu bar.
    var devMark: String { isDev ? "β " : "" }

    func setStatusTitle(_ text: String) {
        // The popover hangs off the middle of the status item: changing the title
        // width while it's open makes it jump. Hold it until the popover closes.
        if popover?.isShown == true {
            pendingTitle = text
            return
        }
        statusItem.button?.title = devMark + text
    }

    func showCachedTitle() {
        let limits = loadJSONObject(paths.limits)
        let style = settings["menubar_style"] as? String ?? "full"
        setStatusTitle(formatter.titleFromLimits(limits, style: style, lang: lang))
    }

    func tick() {
        checkAccountSwitch()
        maybeCheckServiceStatus()
        if !limitsAreFresh(loadJSONObject(paths.limits), now: Date()) {
            startFetch()
        } else if popover.isShown {
            pushData()
        } else {
            showCachedTitle()
        }
    }

    // MARK: - Popover

    func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: Self.popoverWidth, height: Self.popoverMinHeight)
        popover.behavior = .transient
        popover.delegate = self

        let config = WKWebViewConfiguration()
        let handler = ScriptHandler(owner: self)
        for name in ["refresh", "quit", "setNotifications", "startUpdate", "setMenubarStyle",
                     "setAppearance", "openStatusPage", "openResetsPage", "resize"] {
            config.userContentController.add(handler, name: name)
        }
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: Self.popoverWidth,
                                          height: Self.popoverMinHeight), configuration: config)
        if let html = Bundle.main.url(forResource: "dashboard", withExtension: "html") {
            webView.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        } else {
            log("dashboard.html ontbreekt in de bundle")
        }
        let vc = NSViewController()
        vc.view = webView
        popover.contentViewController = vc
        applyAppearance()
    }

    @objc func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            lang = languageFrom(Locale.preferredLanguages, defaultLang: strings.defaultLang)
            checkAccountSwitch()
            pushData(animated: true)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        // The next open starts on the main view: back to its fixed height now.
        setPopoverHeight(Self.popoverMinHeight)
        if let title = pendingTitle {
            statusItem.button?.title = devMark + title
            pendingTitle = nil
        }
    }

    func pushData(animated: Bool = false) {
        let limits = loadJSONObject(paths.limits)
        if let win = weekWindow(limits), win.deviates {
            let key = pyIsoformatUTC(win.end)
            if !loggedWeekWindows.contains(key) {
                loggedWeekWindows.insert(key)
                log("weekvenster wijkt af van 7 dagen: \(pyIsoformatUTC(win.start)) → \(key)")
            }
        }
        let data = formatter.dashboardData(limits: limits, settings: settings,
                                           state: state, lang: lang)
        guard let json = try? JSONSerialization.data(withJSONObject: data),
              let text = String(data: json, encoding: .utf8) else { return }
        let fn = animated ? "openWithAnimation" : "updateData"
        webView.evaluateJavaScript("if(window.\(fn)) window.\(fn)(\(text))")
    }

    func setPopoverHeight(_ height: CGFloat) {
        let h = max(Self.popoverMinHeight, min(Self.popoverMaxHeight, height.rounded(.towardZero)))
        if popover.contentSize.height != h {
            popover.contentSize = NSSize(width: Self.popoverWidth, height: h)
        }
    }

    func applyAppearance() {
        switch settings["appearance"] as? String {
        case "light": popover.appearance = NSAppearance(named: .aqua)
        case "dark": popover.appearance = NSAppearance(named: .darkAqua)
        default: popover.appearance = nil
        }
    }

    // MARK: - Messages from dashboard.html

    func handle(_ name: String, _ body: Any) {
        switch name {
        case "refresh":
            startFetch()
        case "quit":
            NSApp.terminate(nil)
        case "setNotifications":
            let enabled = (body as? Bool) ?? ((body as? NSNumber)?.boolValue ?? false)
            updateSetting("notifications", enabled)
            log("meldingen \(enabled ? "aan" : "uit")")
            pushData()
        case "setMenubarStyle":
            guard let style = body as? String, menubarStyles.contains(style) else { return }
            updateSetting("menubar_style", style)
            showCachedTitle()
            pushData()
        case "setAppearance":
            guard let appearance = body as? String, appearanceStyles.contains(appearance) else { return }
            updateSetting("appearance", appearance)
            applyAppearance()
            pushData()
        case "startUpdate":
            log("bijwerken: nog niet in de Swift-versie (fase 4)")
        case "resize":
            if let n = body as? NSNumber { setPopoverHeight(CGFloat(n.doubleValue)) }
        case "openResetsPage":
            // Fixed URL, no argument from the page.
            NSWorkspace.shared.open(URL(string: resetsURL)!)
        case "openStatusPage":
            if let s = body as? String, isStatusURL(s), let url = URL(string: s) {
                NSWorkspace.shared.open(url)
            }
        case "fetchResult":
            onFetchResult(body as? String ?? "")
        default:
            break
        }
    }
}

/// WKUserContentController retains its handlers: keep the delegate weak.
final class ScriptHandler: NSObject, WKScriptMessageHandler {
    weak var owner: AppDelegate?
    init(owner: AppDelegate) { self.owner = owner }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        owner?.handle(message.name, message.body)
    }
}
