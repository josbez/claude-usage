import AppKit
import UsageCore
import UserNotifications
import WebKit

/// Native port of app.py: menu bar + popover with dashboard.html (fase 1) and
/// the usage fetch through a hidden WKWebView (fase 2, Fetching.swift),
/// notifications and history (fase 3, Notifying.swift) and in-app updates
/// (fase 4, Updater.swift).
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    static let popoverWidth: CGFloat = 360
    static let popoverMinHeight: CGFloat = 296   // main view; fixed
    static let popoverMaxHeight: CGFloat = 680   // settings view may grow up to this (667 with a seasonal theme; fits a 13" screen)

    let isDev = Bundle.main.bundleIdentifier?.hasSuffix(".dev") ?? true
    lazy var paths = Paths(isDev: isDev)
    var strings: Strings!
    var lang = "en"
    var state = AppState()

    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var webView: WKWebView!
    var pendingTitle: String?
    var appliedTitle: String?
    var menubarPct = 0
    var appearanceObservation: NSKeyValueObservation?
    var timer: Timer?
    var activity: NSObjectProtocol?
    var cachedSettings: JSONObject?

    // Fetching (Fetching.swift)
    var fetchJSTemplate = ""
    var fetchWebView: WKWebView?
    var fetchNavDelegate: FetchNavDelegate?
    var fetchGeneration = 0   // a late callback from an earlier fetch must not touch this one
    var fetchMode = FetchMode.native   // first mode to try; sticks to what worked this session
    var attemptMode = FetchMode.native
    var watchdog: Timer?
    var lastCookieMtime: Date?
    var lastSessionHash: String?
    /// Cookie key in memory: one Keychain request per app start (taak 54).
    lazy var cookieKeys = CookieKeyCache(onRead: { [weak self] reason in
        self?.log("keychain: wachtwoord opgevraagd (reden: \(reason.rawValue))")
    })
    var serviceChecking = false
    var serviceCheckedAt: Date?
    var loggedUnknownStatus = Set<String>()
    var loggedWeekWindows = Set<String>()

    // Notifications (Notifying.swift)
    var notifyCenter: UNUserNotificationCenter?
    let notifyDelegate = NotificationDelegate()
    var postTestNotification = false

    // Updates (Updater.swift)
    var update: [String: String]?
    var updateChecking = false
    var updateInstalling = false
    var updateError: String?

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

        // No App Nap (deliberate, Jos 1-10-2026): the menu bar title must stay current
        // at a glance, without opening the popover. With App Nap allowed, refreshes
        // stretched to 9 minutes. Costs a few wake-ups, no memory.
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "periodieke Claude-usage-refresh")

        setupNotifications()
        migrateMenubarIcon()
        setupStatusItem()
        setupPopover()
        setupFetchWebView()
        startFetch()
        maybeCheckUpdates()
        maybeCheckServiceStatus()
        // Every minute, also while the popover is open (common run loop modes).
        // A little tolerance lets macOS batch wake-ups.
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 10
        RunLoop.current.add(t, forMode: .common)
        timer = t
    }

    // MARK: - Files

    static let logDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    static let logMaxBytes = 1_000_000

    func log(_ msg: String) {
        let line = "\(Self.logDateFormatter.string(from: Date())) \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        // One older generation (.1) is enough to look back a while.
        if let size = (try? FileManager.default.attributesOfItem(atPath: paths.log.path))?[.size] as? Int,
           size > Self.logMaxBytes {
            let old = paths.log.appendingPathExtension("1")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: paths.log, to: old)
        }
        if let h = try? FileHandle(forWritingTo: paths.log) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: paths.log)
        }
    }

    /// Read once, then from memory; only updateSetting writes the file.
    var settings: JSONObject {
        if let s = cachedSettings { return s }
        let s = loadSettings(paths.settings)
        cachedSettings = s
        return s
    }

    func updateSetting(_ key: String, _ value: Any) {
        var s = settings
        s[key] = value
        cachedSettings = nil
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
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))
        applyStatusTitle("🚀")
        observeMenubarAppearance()
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
        applyStatusTitle(text)
    }

    func showCachedTitle() {
        let limits = loadJSONObject(paths.limits)
        let style = settings["menubar_style"] as? String ?? "full"
        menubarPct = sessionPct(limits)
        let f = formatter
        setStatusTitle(f.titleFromLimits(limits, style: style, lang: lang, theme: f.faceTheme(settings)))
    }

    func tick() {
        checkAccountSwitch()
        maybeCheckUpdates()
        maybeCheckServiceStatus()
        if !limitsAreFresh(loadJSONObject(paths.limits), now: Date(), maxAgeMinutes: refreshMinutes(settings)) {
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
        for name in ["refresh", "close", "quit", "uninstall", "setNotifications", "startUpdate",
                     "setMenubarStyle", "setMenubarIcon", "setSeasonalFaces", "setAppearance", "setRefresh", "openStatusPage", "openResetsPage", "resize"] {
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
            maybeCheckUpdates()
            pushData(animated: true)
            // Never show stale numbers on open (e.g. right after waking from sleep).
            if !limitsAreFresh(loadJSONObject(paths.limits), now: Date(), maxAgeMinutes: refreshMinutes(settings)) {
                startFetch()
            }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        // The next open starts on the main view: back to its fixed height now.
        setPopoverHeight(Self.popoverMinHeight)
        if let title = pendingTitle {
            applyStatusTitle(title)
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
        state.update = updateView()
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
            cookieKeys.allowRetry()   // a Keychain prompt the user denied may come back now
            startFetch()
            maybeCheckUpdates(manual: true)
        case "close":
            popover.performClose(nil)
        case "quit":
            NSApp.terminate(nil)
        case "uninstall":
            // After the message handler returns: runModal inside it would block WebKit.
            DispatchQueue.main.async { self.confirmUninstall() }
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
        case "setMenubarIcon":
            guard let icon = body as? String, menubarIcons.contains(icon) else { return }
            updateSetting("menubar_icon", icon)
            showCachedTitle()   // held until the popover closes (anchor)
            pushData()
        case "setSeasonalFaces":
            let enabled = (body as? Bool) ?? ((body as? NSNumber)?.boolValue ?? true)
            updateSetting("seasonal_faces", enabled)
            showCachedTitle()   // held until the popover closes (anchor)
            pushData()
        case "setAppearance":
            guard let appearance = body as? String, appearanceStyles.contains(appearance) else { return }
            updateSetting("appearance", appearance)
            applyAppearance()
            pushData()
        case "setRefresh":
            guard let n = (body as? NSNumber)?.intValue, refreshChoices.contains(n) else { return }
            updateSetting("refresh_minutes", n)
            // Shorter than the data's age: fetch now instead of at the next tick.
            if !limitsAreFresh(loadJSONObject(paths.limits), now: Date(), maxAgeMinutes: n) { startFetch() }
            pushData()
        case "startUpdate":
            startUpdate()
        case "resize":
            if let n = body as? NSNumber { setPopoverHeight(CGFloat(n.doubleValue)) }
        case "openResetsPage":
            // Fixed URL, no argument from the page.
            NSWorkspace.shared.open(URL(string: resetsURL)!)
        case "openStatusPage":
            guard let s = body as? String, isStatusURL(s), let url = URL(string: s) else {
                log("claude-status: link geweigerd: \(String(String(describing: body).prefix(80)))")
                return
            }
            NSWorkspace.shared.open(url)
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
