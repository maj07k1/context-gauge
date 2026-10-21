import AppKit
import SwiftUI

/// Developer self-check, never used in normal runs.
///
/// `CONTEXT_GAUGE_SNAPSHOT=<dir>` reads the real Claude Code logs (last 30 days), renders the
/// popover to PNGs, prints a short summary of the newest sessions, and exits.
@MainActor
enum DevSnapshot {
    static var directory: String? { ProcessInfo.processInfo.environment["CONTEXT_GAUGE_SNAPSHOT"] }

    static func run(into dir: String) async {
        let suite = "ContextGauge.DevSnapshot"
        let store = UserDefaults(suiteName: suite)!
        let model = AppModel(scanner: ContextScanner(maxAge: 30 * 86400), defaults: store, live: false)
        await model.refresh()

        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        await render(PopoverView().environmentObject(model), to: "\(dir)/latest.png")
        await render(PopoverView(height: 1600).environmentObject(model), to: "\(dir)/latest-full.png", height: 1600)
        if let fullest = model.sessions.max(by: { $0.tokens < $1.tokens }) {
            await render(PopoverView(pinnedID: fullest.id, height: 1600).environmentObject(model),
                         to: "\(dir)/fullest-full.png", height: 1600)
        }
        if let compacted = model.sessions.first(where: { !$0.compactions.isEmpty }) {
            await render(PopoverView(pinnedID: compacted.id, height: 1600).environmentObject(model),
                         to: "\(dir)/compacted-full.png", height: 1600)
        }
        await render(PopoverView(showSettings: true).environmentObject(model), to: "\(dir)/settings.png")
        let empty = AppModel(scanner: ContextScanner(roots: []), defaults: store, live: false)
        await empty.refresh()
        await render(PopoverView().environmentObject(empty), to: "\(dir)/empty.png")
        UserDefaults.standard.removePersistentDomain(forName: suite)

        for s in model.sessions.prefix(6) {
            let l = model.limits(for: s)
            let parts = s.breakdown.map { "\($0.kind.label) \(Fmt.tokens($0.tokens))" }.joined(separator: ", ")
            print("\(s.project) · \(Fmt.model(s.model)) · \(Fmt.tokens(s.tokens))/\(Fmt.tokens(l.window)) "
                  + "(\(Int(l.percent(s.tokens).rounded()))%) · \(parts)")
        }
    }

    private static func render<V: View>(_ view: V, to path: String, height: CGFloat = 640) async {
        let host = NSHostingView(rootView: view
            .background(Color(red: 0.13, green: 0.13, blue: 0.14))
            .environment(\.colorScheme, .dark))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderBack(nil)
        try? await Task.sleep(for: .seconds(1))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        window.orderOut(nil)
    }
}
