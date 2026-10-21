import AppKit
import Charts
import SwiftUI

@main
struct ContextGaugeApp: App {
    @StateObject private var model = AppModel(live: DevSnapshot.directory == nil)

    init() {
        if let dir = DevSnapshot.directory {
            Task { @MainActor in
                await DevSnapshot.run(into: dir)
                exit(0)
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView().environmentObject(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: model.menuBarSymbol)
            if let text = model.menuBarText { Text(text) }
        }
    }
}

// MARK: - Shell

struct PopoverView: View {
    @EnvironmentObject var model: AppModel
    @State private var pinnedID: String?
    @State private var showSettings: Bool

    private let height: CGFloat

    init(showSettings: Bool = false, pinnedID: String? = nil, height: CGFloat = 640) {
        self.height = height
        _showSettings = State(initialValue: showSettings)
        _pinnedID = State(initialValue: pinnedID)
    }

    /// A session picked from the list, or else the one the menu bar follows.
    private var shown: ContextReport? {
        if let pinnedID, let s = model.sessions.first(where: { $0.id == pinnedID }) { return s }
        return model.featured
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                Group {
                    if showSettings {
                        SettingsView()
                    } else if !model.loaded {
                        ProgressView("Reading Claude Code logs…")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    } else if let s = shown {
                        SessionDetail(session: s, pinnedID: $pinnedID)
                    } else {
                        EmptyNote(icon: "text.bubble",
                                  text: "No Claude Code sessions in the last 3 days.\nStart one and its context shows up here.")
                    }
                }
                .padding(14)
            }
        }
        .frame(width: 420, height: height)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(showSettings ? "Settings" : "Context Gauge").font(.headline)
            Spacer()
            if pinnedID != nil, !showSettings {
                Button { pinnedID = nil } label: {
                    Label("Back", systemImage: "arrow.uturn.backward").font(.caption)
                }
                .help("Back to the session the menu bar follows")
            }
            Button { showSettings.toggle() } label: {
                Image(systemName: showSettings ? "xmark" : "gearshape")
            }
            .help(showSettings ? "Close settings" : "Settings")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .frame(height: 44)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct EmptyNote: View {
    let icon: String
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.title2).foregroundStyle(.secondary)
            Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }
}

/// How full the context is, with ticks where the warning starts and where auto-compact kicks in.
struct ContextBar: View {
    let limits: ContextLimits
    let tokens: Int
    var height: CGFloat = 10
    var markers = true

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(Theme.color(limits.level(tokens)))
                    .frame(width: max(height, w * min(1, Double(tokens) / Double(limits.window))))
                if markers {
                    tick(at: limits.warn, width: w, opacity: 0.3)
                    if let at = limits.autoCompact { tick(at: at, width: w, opacity: 0.75) }
                }
            }
        }
        .frame(height: height)
    }

    private func tick(at value: Int, width: CGFloat, opacity: Double) -> some View {
        Rectangle().fill(Color.primary.opacity(opacity))
            .frame(width: 2, height: height + 6)
            .offset(x: width * min(1, Double(value) / Double(limits.window)) - 1)
    }
}

// MARK: - Session

struct SessionDetail: View {
    @EnvironmentObject var model: AppModel
    let session: ContextReport
    @Binding var pinnedID: String?

    var body: some View {
        let limits = model.limits(for: session)
        VStack(alignment: .leading, spacing: 12) {
            GaugeCard(session: session, limits: limits)
            if session.timeline.count >= 2 { GrowthCard(session: session, limits: limits) }
            BreakdownCard(session: session)
            BiggestCard(session: session)
            SessionList(shownID: session.id, pinnedID: $pinnedID)
            Text("Read from Claude Code's logs on this Mac. Totals come from each request's token counts; how they split between items is estimated.")
                .font(.caption).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct GaugeCard: View {
    let session: ContextReport
    let limits: ContextLimits

    var body: some View {
        let level = limits.level(session.tokens)
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text("\(session.project) · \(Fmt.model(session.model))")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    ActivityBadge(date: session.lastActivity)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(Int(limits.percent(session.tokens).rounded()))%")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.color(level))
                    Text("full").foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Fmt.tokens(session.tokens)) of \(Fmt.tokens(limits.window))")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                ContextBar(limits: limits, tokens: session.tokens)
                    .help("Ticks: where the warning starts, and the estimated auto-compact point")
                HStack {
                    Text(leftText)
                    Spacer()
                    if let pace = paceText { Text(pace) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let c = compactionText {
                    Label(c, systemImage: "archivebox").font(.caption).foregroundStyle(.secondary)
                }
                if level != .ok { tip(level) }
            }
        }
    }

    private var leftText: String {
        let left = limits.left(session.tokens)
        if limits.autoCompact == nil { return "\(Fmt.tokens(left)) left · auto-compact is off" }
        if left == 0 { return "Past the estimated auto-compact point" }
        return "≈ \(Fmt.tokens(left)) until auto-compact"
    }

    private var paceText: String? {
        guard let g = session.growthPerRequest, g >= 1 else { return nil }
        let left = limits.left(session.tokens)
        let requests = Int((Double(left) / g).rounded(.up))
        return left > 0 && requests < 10_000
            ? "≈ \(requests) requests at +\(Fmt.tokens(Int(g))) each"
            : "+\(Fmt.tokens(Int(g))) per request"
    }

    private var compactionText: String? {
        guard let last = session.compactions.last else { return nil }
        let n = session.compactions.count
        let how = "\(last.automatic ? "automatically" : "by hand") \(Fmt.ago(last.date))"
        var text = n == 1 ? "Compacted \(how)" : "Compacted \(n)× · last \(how)"
        if let before = last.before, let after = last.after {
            text += " (\(Fmt.tokens(before)) → \(Fmt.tokens(after)))"
        }
        return text
    }

    private func tip(_ level: ContextLevel) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: level == .compactSoon ? "exclamationmark.triangle.fill" : "lightbulb")
                .foregroundStyle(Theme.color(level))
            Text(level == .compactSoon
                 ? (limits.autoCompact == nil
                    ? "The context window is nearly full. Run /compact to summarize it, or /clear to start fresh."
                    : "Claude Code will compact this session on its own soon. Run /compact now to choose what's kept (add instructions, like /compact keep the API notes), or /clear to start fresh.")
                 : "Getting full. /compact summarizes the conversation to free space; /clear starts fresh.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.color(level).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ActivityBadge: View {
    let date: Date

    var body: some View {
        if Date().timeIntervalSince(date) < 120 {
            HStack(spacing: 4) {
                Circle().fill(.green).frame(width: 6, height: 6)
                Text("Live")
            }
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.green.opacity(0.15), in: Capsule())
        } else {
            Text(Fmt.ago(date)).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct GrowthCard: View {
    let session: ContextReport
    let limits: ContextLimits

    /// Scaled to the session rather than the window, so growth is visible in a mostly empty 1M
    /// window. The gauge above already shows how far there is to go.
    private var top: Int {
        let highest = session.timeline.map(\.tokens).max() ?? 0
        let wanted = max(Double(highest) * 1.4, Double(limits.window) / 4)
        let step = wanted > 500_000 ? 100_000.0 : 50_000.0
        return min(limits.window, Int((wanted / step).rounded(.up) * step))
    }

    var body: some View {
        let top = top
        let dates = session.timeline.map(\.date)
        let span = (dates.max() ?? .now).timeIntervalSince(dates.min() ?? .now)
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Context over time").font(.subheadline.weight(.semibold))
                Chart {
                    ForEach(Array(session.timeline.enumerated()), id: \.offset) { _, p in
                        // Steps, so a compaction drops when it happened rather than sloping down to it.
                        AreaMark(x: .value("Time", p.date), y: .value("Tokens", p.tokens))
                            .interpolationMethod(.stepEnd)
                            .foregroundStyle(Theme.accent.opacity(0.18))
                        LineMark(x: .value("Time", p.date), y: .value("Tokens", p.tokens))
                            .interpolationMethod(.stepEnd)
                            .foregroundStyle(Theme.accent)
                    }
                    if let at = limits.autoCompact, at <= top {
                        RuleMark(y: .value("Auto-compact", at))
                            .foregroundStyle(Color.red.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .annotation(position: .bottom, alignment: .leading) {
                                Text("auto-compact").font(.caption2).foregroundStyle(.secondary)
                            }
                    }
                }
                .chartYScale(domain: 0...top)
                .chartYAxis {
                    AxisMarks(values: [0, top / 2, top]) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let n = value.as(Int.self) { Text(Fmt.tokens(n)) }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: span > 20 * 3600
                                       ? .dateTime.month(.abbreviated).day()
                                       : .dateTime.hour().minute())
                    }
                }
                .frame(height: 110)
            }
        }
    }
}

struct BreakdownCard: View {
    let session: ContextReport

    var body: some View {
        let total = Double(max(1, session.tokens))
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("What's using the space").font(.subheadline.weight(.semibold))
                GeometryReader { geo in
                    let gaps = CGFloat(max(0, session.breakdown.count - 1)) * 2
                    HStack(spacing: 2) {
                        ForEach(session.breakdown, id: \.kind) { part in
                            Rectangle().fill(Theme.color(part.kind))
                                .frame(width: max(2, (geo.size.width - gaps) * Double(part.tokens) / total))
                        }
                    }
                }
                .frame(height: 12)
                .clipShape(Capsule())

                ForEach(session.breakdown, id: \.kind) { part in
                    HStack(spacing: 8) {
                        Circle().fill(Theme.color(part.kind)).frame(width: 8, height: 8)
                        Text(part.kind.label)
                        Spacer()
                        Text(Fmt.tokens(part.tokens)).monospacedDigit()
                        Text("\(Int((Double(part.tokens) / total * 100).rounded()))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                    }
                    .font(.caption)
                }

                if !session.tools.isEmpty {
                    Divider()
                    Text("By tool").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    let top = Double(session.tools[0].tokens)
                    ForEach(Array(session.tools.prefix(6)), id: \.name) { t in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(Fmt.tool(t.name)).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(Fmt.tokens(t.tokens)).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .font(.caption)
                            GeometryReader { geo in
                                Capsule().fill(Theme.color(.toolResult).opacity(0.7))
                                    .frame(width: max(3, geo.size.width * Double(t.tokens) / top))
                            }
                            .frame(height: 4)
                        }
                    }
                }
            }
        }
    }
}

struct BiggestCard: View {
    let session: ContextReport

    var body: some View {
        let items = Array(session.biggest.prefix(8))
        if !items.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Biggest items").font(.subheadline.weight(.semibold))
                    ForEach(items) { item in
                        HStack(spacing: 8) {
                            Image(systemName: Theme.icon(item))
                                .foregroundStyle(Theme.color(item.kind))
                                .frame(width: 16)
                            Text(item.label).lineLimit(1).truncationMode(.middle)
                            if item.count > 1 {
                                Text("×\(item.count)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Text(Fmt.tokens(Int(item.tokens.rounded()))).monospacedDigit()
                        }
                        .font(.caption)
                        .help("\(item.kind.label): \(item.label)")
                    }
                }
            }
        }
    }
}

struct SessionList: View {
    @EnvironmentObject var model: AppModel
    let shownID: String
    @Binding var pinnedID: String?

    var body: some View {
        let sessions = Array(model.sessions.prefix(12))
        if sessions.count > 1 {
            VStack(alignment: .leading, spacing: 6) {
                Text("Recent sessions").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(sessions) { s in
                    let limits = model.limits(for: s)
                    Button {
                        pinnedID = s.id == model.featured?.id ? nil : s.id
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.title).font(.callout).lineLimit(1)
                                Text("\(s.project) · \(Fmt.ago(s.lastActivity))")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Text("\(Int(limits.percent(s.tokens).rounded()))%")
                                    .font(.callout.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(Theme.color(limits.level(s.tokens)))
                                ContextBar(limits: limits, tokens: s.tokens, height: 4, markers: false)
                                    .frame(width: 60)
                            }
                        }
                        .padding(10)
                        .background(s.id == shownID ? Theme.accent.opacity(0.16) : Color.primary.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Preferences").font(.subheadline.weight(.semibold))
            Picker("Menu bar shows", selection: $model.menuBarMode) {
                ForEach(MenuBarMode.allCases) { Text($0.label).tag($0) }
            }
            Picker("Warn at", selection: $model.warnPercent) {
                ForEach([50, 60, 70, 80, 90], id: \.self) { Text("\($0)% full").tag($0) }
            }
            Toggle("Notify when a live session gets full", isOn: $model.notify)
            Text("The menu bar follows whichever session active in the last 10 minutes is closest to running out.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Launch at login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }))

            Divider()

            Text("Context window").font(.subheadline.weight(.semibold))
            Picker("Window size", selection: $model.windowOverride) {
                Text("Automatic").tag(0)
                Text("200K").tag(200_000)
                Text("1M").tag(1_000_000)
            }
            Text("Automatic assumes 1M for Claude 5 models and 200K for older ones, and switches to 1M once a session goes past 200K.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(autoCompactNote)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            AboutSection()

            Divider()

            HStack {
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
    }

    private var autoCompactNote: String {
        let s = model.claudeSettings
        guard s.autoCompact else {
            return "Auto-compact is off in your Claude Code settings, so the gauge measures against the full window."
        }
        let override = s.compactPercent.map { " Your CLAUDE_AUTOCOMPACT_PCT_OVERRIDE of \(Int($0))% is applied." } ?? ""
        return "The auto-compact point is an estimate: the window, minus room for a reply and a 13K buffer.\(override)"
    }
}

struct AboutSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("About").font(.subheadline.weight(.semibold))
                Text("Version \(AppInfo.version)").font(.caption).foregroundStyle(.secondary)
            }
            Text("Context Gauge is free and open source. It's an unofficial tool, not affiliated with or endorsed by Anthropic. It only reads Claude Code's logs on this Mac: no network, no analytics.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let tip = AppInfo.tipJarURL {
                Card {
                    HStack(spacing: 10) {
                        Image(systemName: "heart.fill").foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Enjoying the app?").font(.callout.weight(.semibold))
                            Text("A tip helps keep it maintained. Entirely optional.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Link("Leave a tip", destination: tip)
                            .buttonStyle(.borderedProminent).tint(Theme.accent)
                    }
                }
            }
            if let source = AppInfo.sourceURL {
                HStack(spacing: 14) {
                    Link(destination: source) { Label("Source code", systemImage: "chevron.left.forwardslash.chevron.right") }
                    Link(destination: source.appending(path: "issues")) { Label("Report an issue", systemImage: "exclamationmark.bubble") }
                }
                .font(.caption)
            }
        }
    }
}
