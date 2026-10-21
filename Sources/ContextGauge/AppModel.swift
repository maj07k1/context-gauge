import AppKit
import Foundation
import ServiceManagement
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var sessions: [ContextReport] = []
    @Published private(set) var loaded = false
    @Published private(set) var claudeSettings = ClaudeCodeSettings()
    @Published var menuBarMode: MenuBarMode { didSet { defaults.set(menuBarMode.rawValue, forKey: "menuBarMode") } }
    @Published var warnPercent: Int { didSet { defaults.set(warnPercent, forKey: "warnPercent") } }
    @Published var notify: Bool {
        didSet {
            defaults.set(notify, forKey: "notify")
            if notify { Notifier.requestPermission() }
        }
    }
    /// 0 means automatic.
    @Published var windowOverride: Int { didSet { defaults.set(windowOverride, forKey: "windowOverride") } }

    private let scanner: ContextScanner
    private let defaults: UserDefaults
    private var peaks: [String: Int] = [:]
    private var timer: Timer?
    private var scanning = false
    private var lastPublish = Date.distantPast
    private var alerted = Set<String>()
    private var primed = false

    init(scanner: ContextScanner = ContextScanner(), defaults: UserDefaults = .standard, live: Bool = true) {
        self.scanner = scanner
        self.defaults = defaults
        menuBarMode = MenuBarMode(rawValue: defaults.string(forKey: "menuBarMode") ?? "") ?? .percent
        warnPercent = defaults.object(forKey: "warnPercent") as? Int ?? 80
        notify = defaults.object(forKey: "notify") as? Bool ?? true
        windowOverride = defaults.integer(forKey: "windowOverride")
        guard live else { return }

        if notify { Notifier.requestPermission() }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        timer?.tolerance = 1      // lets macOS coalesce wake-ups to save power
        Task { await refresh() }
    }

    func refresh() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        let result = await scanner.scan()
        peaks = result.peaks
        if claudeSettings != result.settings { claudeSettings = result.settings }
        // Republish when a log changed, and every half minute so "5m ago" stays current.
        if result.changed || !loaded || Date().timeIntervalSince(lastPublish) > 30 {
            sessions = result.sessions
            loaded = true
            lastPublish = Date()
        }
        checkAlerts(result.sessions)
    }

    func limits(for s: ContextReport) -> ContextLimits {
        let peak = max(s.peak, peaks[s.model] ?? 0)
        let window = ContextLimits.window(model: s.model, peak: peak, override: windowOverride > 0 ? windowOverride : nil)
        return ContextLimits(window: window, settings: claudeSettings, warnPercent: warnPercent)
    }

    // MARK: Menu bar

    /// The session the menu bar follows: of those active in the last 10 minutes, the one closest to
    /// running out. Following the most recent instead would flicker between parallel sessions.
    var current: ContextReport? {
        let now = Date()
        return sessions.filter { now.timeIntervalSince($0.lastActivity) < 600 }.max { a, b in
            Double(a.tokens) / Double(limits(for: a).limit) < Double(b.tokens) / Double(limits(for: b).limit)
        }
    }

    /// What the popover shows until a session is picked from the list.
    var featured: ContextReport? { current ?? sessions.first }

    var menuBarSymbol: String {
        guard let s = current else { return "gauge.with.dots.needle.0percent" }
        let l = limits(for: s)
        if l.level(s.tokens) == .compactSoon { return "exclamationmark.triangle.fill" }
        switch l.percent(s.tokens) {
        case ..<17: return "gauge.with.dots.needle.0percent"
        case ..<42: return "gauge.with.dots.needle.33percent"
        case ..<58: return "gauge.with.dots.needle.50percent"
        case ..<84: return "gauge.with.dots.needle.67percent"
        default: return "gauge.with.dots.needle.100percent"
        }
    }

    var menuBarText: String? {
        guard let s = current else { return nil }
        let l = limits(for: s)
        switch menuBarMode {
        case .percent: return "\(Int(l.percent(s.tokens).rounded()))%"
        case .tokensLeft: return Fmt.tokens(l.left(s.tokens))
        case .iconOnly: return nil
        }
    }

    // MARK: Notifications

    /// Notifies once per session and level, and again after a compaction. Sessions already full
    /// when the app starts don't notify.
    private func checkAlerts(_ sessions: [ContextReport]) {
        let now = Date()
        for s in sessions where now.timeIntervalSince(s.lastActivity) < 600 {
            let l = limits(for: s)
            let level = l.level(s.tokens)
            guard level != .ok else { continue }
            let key = "\(s.id)|\(s.compactions.count)|\(level.rawValue)"
            guard alerted.insert(key).inserted, primed, notify else { continue }

            let left = Fmt.tokens(l.left(s.tokens))
            let pct = Int(l.percent(s.tokens).rounded())
            if level == .compactSoon {
                Notifier.post(
                    id: key,
                    title: l.autoCompact == nil ? "Context almost full" : "Auto-compact is close",
                    body: "\(s.title) (\(s.project)): \(left) left. Run /compact to choose what's kept, or /clear to start fresh.")
            } else {
                Notifier.post(
                    id: key,
                    title: "Context \(pct)% full",
                    body: "\(s.title) (\(s.project)): about \(left) left before "
                        + (l.autoCompact == nil ? "the window is full." : "Claude Code compacts it."))
            }
        }
        primed = true
    }

    // MARK: Launch at login

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("ContextGauge: launch at login failed: %@", String(describing: error))
        }
        objectWillChange.send()
    }
}

enum Notifier {
    /// Notifications need a real app bundle; `swift run` has none.
    static var available: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestPermission() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = Presenter.shared
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(id: String, title: String, body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// Shows notifications even while the popover is open.
    private final class Presenter: NSObject, UNUserNotificationCenterDelegate {
        static let shared = Presenter()

        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
            completionHandler([.banner, .sound])
        }
    }
}
