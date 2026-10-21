import Foundation
import SwiftUI

// MARK: - Claude Code settings that move the auto-compact point

struct ClaudeCodeSettings: Equatable {
    var autoCompact = true
    /// `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE`: compact at this percentage of the usable window instead.
    var compactPercent: Double?

    /// Reads `~/.claude/settings.json` (its `env` block) and `~/.claude.json`. Read-only.
    static func read(home: URL) -> ClaudeCodeSettings {
        func json(_ path: String) -> [String: Any]? {
            guard let data = try? Data(contentsOf: home.appendingPathComponent(path)) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        func number(_ v: Any?) -> Double? {
            if let n = v as? NSNumber { return n.doubleValue }
            return (v as? String).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        }

        var s = ClaudeCodeSettings()
        if let env = json(".claude/settings.json")?["env"] as? [String: Any] {
            if let p = number(env["CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"]), p > 0, p < 100 { s.compactPercent = p }
            let off = env["DISABLE_AUTO_COMPACT"]
            if number(off).map({ $0 != 0 }) ?? ((off as? String)?.lowercased() == "true") { s.autoCompact = false }
        }
        if json(".claude.json")?["autoCompactEnabled"] as? Bool == false { s.autoCompact = false }
        return s
    }
}

// MARK: - Limits

enum ContextLevel: Int {
    case ok, warn, compactSoon
}

struct ContextLimits: Equatable {
    let window: Int
    /// Estimated size at which Claude Code compacts on its own; nil when auto-compact is off.
    let autoCompact: Int?
    let warn: Int

    /// "Compact soon" starts this far below the auto-compact point (or the window, when it's off).
    static let soonMargin = 20_000

    /// Logs on this Mac show these models running well past 200K, so they're assumed to have a
    /// 1M window. Anything else starts at 200K until a session proves otherwise.
    static let millionTokenModels = ["claude-opus-5", "claude-sonnet-5", "claude-fable-5", "claude-mythos-5"]

    static func window(model: String, peak: Int, override: Int?) -> Int {
        let assumed = model.hasSuffix("[1m]") || millionTokenModels.contains { model.hasPrefix($0) } ? 1_000_000 : 200_000
        let w = override ?? assumed
        // A request bigger than the assumed window proves the window is bigger.
        guard peak > w else { return w }
        return max(peak, 1_000_000)
    }

    init(window: Int, settings: ClaudeCodeSettings, warnPercent: Int) {
        self.window = window
        if settings.autoCompact {
            // An estimate of Claude Code's trigger: room for a reply (up to 20K) is set aside,
            // then a 13K buffer. CLAUDE_AUTOCOMPACT_PCT_OVERRIDE can only bring it earlier.
            let usable = window - min(20_000, window / 10)
            var at = usable - 13_000
            if let p = settings.compactPercent { at = min(at, Int(Double(usable) * p / 100)) }
            autoCompact = at
        } else {
            autoCompact = nil
        }
        warn = max(0, min(window * warnPercent / 100, (autoCompact ?? window) - Self.soonMargin))
    }

    /// Where the context runs out: the auto-compact point, or the window when that's off.
    var limit: Int { autoCompact ?? window }

    func level(_ tokens: Int) -> ContextLevel {
        if tokens >= limit - Self.soonMargin { return .compactSoon }
        if tokens >= warn { return .warn }
        return .ok
    }

    func percent(_ tokens: Int) -> Double { Double(tokens) / Double(window) * 100 }

    func left(_ tokens: Int) -> Int { max(0, limit - tokens) }
}

// MARK: - App info

/// Release metadata, read from Info.plist so forks and releases can set it without code changes
/// (see build.sh). Links are nil, and hidden in the UI, until configured.
enum AppInfo {
    private static func string(_ key: String) -> String? {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    static var version: String { string("CFBundleShortVersionString") ?? "dev" }
    static var sourceURL: URL? { string("ContextGaugeSourceURL").flatMap(URL.init(string:)) }
    static var tipJarURL: URL? { string("ContextGaugeTipJarURL").flatMap(URL.init(string:)) }
}

// MARK: - Settings

enum MenuBarMode: String, CaseIterable, Identifiable {
    case percent, tokensLeft, iconOnly
    var id: String { rawValue }
    var label: String {
        switch self {
        case .percent: return "Percent full"
        case .tokensLeft: return "Tokens left"
        case .iconOnly: return "Icon only"
        }
    }
}

// MARK: - Theme

enum Theme {
    static let accent = Color(red: 0.42, green: 0.47, blue: 0.98)

    static func color(_ level: ContextLevel) -> Color {
        switch level {
        case .ok: return .green
        case .warn: return .orange
        case .compactSoon: return .red
        }
    }

    static func color(_ kind: ContextKind) -> Color {
        switch kind {
        case .system: return Color(white: 0.55)
        case .summary: return .indigo
        case .prompt: return .blue
        case .toolResult: return Color(red: 0.98, green: 0.45, blue: 0.35)
        case .toolCall: return .orange
        case .thinking: return .purple
        case .reply: return .teal
        case .reminder: return .brown
        }
    }

    static func icon(_ item: BigItem) -> String {
        if item.label == "Image" { return "photo" }
        switch item.tool {
        case "Read": return "doc.text"
        case "Write", "Edit", "MultiEdit", "NotebookEdit": return "square.and.pencil"
        case "Bash": return "terminal"
        case "Grep", "Glob": return "magnifyingglass"
        case "WebFetch", "WebSearch": return "globe"
        case "Agent", "Task": return "person.2"
        case let t? where t.hasPrefix("mcp__"): return "puzzlepiece.extension"
        case .some: return "wrench.and.screwdriver"
        case nil: break
        }
        switch item.kind {
        case .prompt: return "person"
        case .summary: return "archivebox"
        default: return "bell"
        }
    }
}

// MARK: - Formatting

enum Fmt {
    static func tokens(_ n: Int) -> String {
        let d = Double(n)
        func trim(_ s: String) -> String { s.hasSuffix(".0") ? String(s.dropLast(2)) : s }
        if d >= 1e6 { return trim(String(format: "%.1f", d / 1e6)) + "M" }
        if d >= 1e4 { return String(format: "%.0fK", d / 1e3) }
        if d >= 1e3 { return trim(String(format: "%.1f", d / 1e3)) + "K" }
        return "\(n)"
    }

    static func ago(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
    }

    /// "claude-opus-5-5" → "Opus 5.5", "claude-3-5-sonnet-20241022" → "Sonnet 3.5".
    static func model(_ id: String) -> String {
        guard id.hasPrefix("claude-") else { return id.isEmpty ? "Unknown model" : id }
        var parts = id.dropFirst(7).replacingOccurrences(of: "[1m]", with: "").split(separator: "-").map(String.init)
        if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() }     // date stamp
        guard let family = parts.first(where: { Int($0) == nil }) else { return id }
        let version = parts.filter { Int($0) != nil }.joined(separator: ".")
        return family.capitalized + (version.isEmpty ? "" : " " + version)
    }

    /// "mcp__Roblox_Studio__execute_luau" → "execute_luau (Roblox Studio)". Server names that are
    /// only an id are left out.
    static func tool(_ name: String) -> String {
        guard name.hasPrefix("mcp__") else { return name }
        let parts = name.dropFirst(5).components(separatedBy: "__")
        guard parts.count >= 2 else { return String(name.dropFirst(5)) }
        let tool = parts.dropFirst().joined(separator: "__")
        var server = parts[0]
        if server.hasPrefix("plugin_"), let last = server.split(separator: "_").last { server = String(last) }
        if server.isEmpty || UUID(uuidString: server) != nil { return tool }
        return "\(tool) (\(server.replacingOccurrences(of: "_", with: " ")))"
    }
}
