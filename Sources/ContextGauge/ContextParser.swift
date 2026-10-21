import Foundation

// MARK: - Results

/// One kind of content in a session's context window.
enum ContextKind: Int, CaseIterable, Identifiable {
    case system, summary, prompt, toolResult, toolCall, thinking, reply, reminder

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .system: return "System prompt & tools"
        case .summary: return "Compaction summary"
        case .prompt: return "Your messages"
        case .toolResult: return "Tool output"
        case .toolCall: return "Tool calls"
        case .thinking: return "Thinking"
        case .reply: return "Claude's replies"
        case .reminder: return "Reminders & attachments"
        }
    }
}

/// One piece of the conversation. `weight` is its size in characters (an image counts as a fixed
/// amount); `tokens` is filled in once a later request's usage shows how much the context grew.
struct ContextItem {
    let kind: ContextKind
    let tool: String?
    let label: String
    let weight: Double
    var tokens = 0.0
}

/// Pieces that share a label, merged: a file read three times is one row.
struct BigItem: Identifiable {
    let kind: ContextKind
    let tool: String?
    let label: String
    var tokens: Double
    var count: Int

    var id: String { "\(kind.rawValue)|\(label)" }
}

struct Compaction {
    let date: Date
    let automatic: Bool
    let before: Int?
    let after: Int?
}

struct ContextPoint {
    let date: Date
    let tokens: Int
}

struct ContextReport: Identifiable {
    /// The log file's name, which is unique even when a resumed session reuses a session id.
    let id: String
    let title: String
    let project: String
    let model: String
    let lastActivity: Date
    /// Context size as of the latest request, counting the reply it produced.
    let tokens: Int
    /// The largest context any request in this session sent.
    let peak: Int
    /// Sums to `tokens`, largest first.
    let breakdown: [(kind: ContextKind, tokens: Int)]
    /// Tool calls and their output together, by tool, largest first.
    let tools: [(name: String, tokens: Int)]
    let biggest: [BigItem]
    let timeline: [ContextPoint]
    let compactions: [Compaction]
    /// Average growth per request over the last few requests, when it's growing.
    let growthPerRequest: Double?
}

// MARK: - Parser

/// Follows one Claude Code session log line by line and works out what its context holds.
///
/// Every request's usage says exactly how big the context was. The growth from one request to the
/// next is the previous reply (its output tokens, hidden thinking included) plus whatever arrived in
/// between: tool output, your messages, reminders. That growth is split across those pieces by
/// size, so totals match what the API reported and only the split within a single step is estimated.
struct SessionParser {
    /// Characters per token, used only where the logs don't say: splitting a reply between its
    /// visible text and hidden thinking, and the first request after a start or compaction.
    static let charsPerToken = 2.5
    /// What an image counts as, in characters (about 1,600 tokens).
    static let imageWeight = 4_000.0
    /// Attachments Claude Code logs for itself and doesn't send to the model.
    private static let unsentAttachments: Set<String> = [
        "hook_success", "async_hook_response", "hook_non_blocking_error", "hook_cancelled",
        "deferred_tools_record", "prompt_snapshot", "environment", "thinking_drop",
    ]

    private struct Request {
        let id: String
        let context: Int
        var output: Int
    }

    let fileID: String
    private(set) var model = ""
    private(set) var peak = 0
    private var cwd = ""
    private var title: (rank: Int, text: String)?
    private var lastActivity: Date?
    private var compactions: [Compaction] = []
    private var timeline: [ContextPoint] = []

    // The current stretch since the session started or last compacted.
    private var settled: [ContextItem] = []
    private var incoming: [ContextItem] = []
    private var reply: [ContextItem] = []
    private var request: Request?
    private var system = 0.0
    private var recent: [Int] = []
    private var toolUses: [String: (name: String, label: String)] = [:]

    init(fileID: String) {
        self.fileID = fileID
    }

    mutating func consume(line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        consume(obj)
    }

    mutating func consume(_ obj: [String: Any]) {
        guard let type = obj["type"] as? String else { return }
        // Subagents run in contexts of their own.
        if obj["isSidechain"] as? Bool == true { return }
        let date = (obj["timestamp"] as? String).flatMap(Self.date)
        if let date { lastActivity = max(lastActivity ?? date, date) }
        if let c = obj["cwd"] as? String, !c.isEmpty { cwd = c }

        switch type {
        case "assistant": assistant(obj, at: date)
        case "user": user(obj)
        case "attachment": attachment(obj)
        case "system" where obj["subtype"] as? String == "compact_boundary": compact(obj, at: date)
        case "custom-title": setTitle(obj["customTitle"], rank: 3)
        case "agent-name": setTitle(obj["agentName"], rank: 2)
        case "last-prompt": setTitle(obj["lastPrompt"], rank: 1)
        default: break
        }
    }

    // MARK: Entries

    private mutating func assistant(_ obj: [String: Any], at date: Date?) {
        guard let msg = obj["message"] as? [String: Any],
              let usage = msg["usage"] as? [String: Any] else { return }
        let m = msg["model"] as? String ?? ""
        guard m != "<synthetic>" else { return }     // written locally, never sent
        let id = obj["requestId"] as? String ?? msg["id"] as? String ?? UUID().uuidString
        let output = Self.int(usage, "output_tokens")
        if let current = request, current.id == id {
            // Streaming writes one line per block; the last carries the final output count.
            request?.output = max(current.output, output)
        } else {
            let context = Self.int(usage, "input_tokens") + Self.int(usage, "cache_creation_input_tokens")
                + Self.int(usage, "cache_read_input_tokens")
            begin(Request(id: id, context: context, output: output), at: date)
        }
        if m.hasPrefix("claude") { model = m }

        for block in msg["content"] as? [[String: Any]] ?? [] {
            switch block["type"] as? String {
            case "text":
                reply.append(ContextItem(kind: .reply, tool: nil, label: "Reply", weight: Self.length(block["text"])))
            case "thinking", "redacted_thinking":
                // Usually logged without its text; it gets whatever output the visible blocks don't explain.
                reply.append(ContextItem(kind: .thinking, tool: nil, label: "Thinking", weight: 0))
            case "tool_use":
                let name = block["name"] as? String ?? "Tool"
                let input = block["input"] as? [String: Any] ?? [:]
                let label = Self.label(tool: name, input: input)
                if let id = block["id"] as? String { toolUses[id] = (name, label) }
                let size = JSONSerialization.isValidJSONObject(input)
                    ? (try? JSONSerialization.data(withJSONObject: input).count) ?? 0 : 0
                reply.append(ContextItem(kind: .toolCall, tool: name, label: label, weight: Double(size)))
            default:
                break
            }
        }
    }

    private mutating func user(_ obj: [String: Any]) {
        guard let msg = obj["message"] as? [String: Any] else { return }
        if obj["isCompactSummary"] as? Bool == true {
            incoming.append(ContextItem(kind: .summary, tool: nil, label: "Compaction summary",
                                        weight: Self.length(msg["content"])))
            return
        }
        let meta = obj["isMeta"] as? Bool == true
        if let text = msg["content"] as? String {
            incoming.append(Self.textItem(text, meta: meta))
            return
        }
        for case let block as [String: Any] in msg["content"] as? [Any] ?? [] {
            switch block["type"] as? String {
            case "tool_result":
                let use = (block["tool_use_id"] as? String).flatMap { toolUses[$0] }
                incoming.append(ContextItem(kind: .toolResult, tool: use?.name, label: use?.label ?? "Tool output",
                                            weight: Self.length(block["content"])))
            case "text":
                incoming.append(Self.textItem(block["text"] as? String ?? "", meta: meta))
            case "image":
                incoming.append(ContextItem(kind: meta ? .reminder : .prompt, tool: nil, label: "Image", weight: Self.imageWeight))
            default:
                incoming.append(ContextItem(kind: .reminder, tool: nil, label: "Other", weight: Self.length([block])))
            }
        }
    }

    private mutating func attachment(_ obj: [String: Any]) {
        guard let a = obj["attachment"] as? [String: Any], let type = a["type"] as? String,
              !Self.unsentAttachments.contains(type) else { return }
        var weight = ["content", "text", "snippet", "prompt", "context"].reduce(0) { $0 + Self.length(a[$1]) }
        if type == "file", let file = (a["content"] as? [String: Any])?["file"] as? [String: Any] {
            weight += Self.length(file["content"])
        }
        guard weight > 0 else { return }
        incoming.append(ContextItem(kind: .reminder, tool: nil, label: Self.attachmentLabel(type, a), weight: weight))
    }

    private mutating func compact(_ obj: [String: Any], at date: Date?) {
        let meta = obj["compactMetadata"] as? [String: Any] ?? [:]
        let after = (meta["postTokens"] as? NSNumber)?.intValue
        let when = date ?? lastActivity ?? Date(timeIntervalSince1970: 0)
        compactions.append(Compaction(date: when, automatic: meta["trigger"] as? String == "auto",
                                      before: (meta["preTokens"] as? NSNumber)?.intValue, after: after))
        if let after { timeline.append(ContextPoint(date: when, tokens: after)) }
        settled = []
        incoming = []
        reply = []
        request = nil
        system = 0
        recent = []
    }

    private mutating func setTitle(_ value: Any?, rank: Int) {
        guard let t = value as? String, !t.isEmpty else { return }
        // Later, higher-ranked titles win; "lastPrompt" keeps the latest prompt.
        if (title?.rank ?? -1) <= rank { title = (rank, t) }
    }

    // MARK: Attribution

    private mutating func begin(_ next: Request, at date: Date?) {
        if let prev = request {
            settled += Self.split(reply, output: prev.output)
            // Growth beyond the previous reply is whatever arrived in between.
            let rest = Double(next.context - prev.context - prev.output)
            let weight = incoming.reduce(0) { $0 + $1.weight }
            for var piece in incoming {
                piece.tokens = rest > 0 && weight > 0 ? rest * piece.weight / weight : piece.weight / Self.charsPerToken
                settled.append(piece)
            }
            // Growth no logged piece explains, such as tools loaded mid-session.
            if rest > 0 && weight == 0 { system += rest }
        } else {
            // First request since the start or a compaction: whatever the logged pieces don't
            // account for is the system prompt, tool definitions and memory files.
            let estimate = incoming.reduce(0) { $0 + $1.weight } / Self.charsPerToken
            let scale = estimate > Double(next.context) ? Double(next.context) / estimate : 1
            for var piece in incoming {
                piece.tokens = piece.weight / Self.charsPerToken * scale
                settled.append(piece)
            }
            system = max(0, Double(next.context) - estimate)
        }
        incoming = []
        reply = []
        request = next
        peak = max(peak, next.context)
        if let date { timeline.append(ContextPoint(date: date, tokens: next.context)) }
        recent.append(next.context)
        if recent.count > 11 { recent.removeFirst() }
    }

    /// Shares a reply's output tokens among its blocks. Thinking is rarely logged in full, so it
    /// gets what the visible text and tool calls don't account for.
    static func split(_ blocks: [ContextItem], output: Int) -> [ContextItem] {
        guard !blocks.isEmpty else { return [] }
        let out = Double(output)
        let thinkingCount = blocks.filter { $0.kind == .thinking }.count
        let visible = blocks.filter { $0.kind != .thinking }
        let visibleWeight = visible.reduce(0) { $0 + $1.weight }
        let visibleTokens = thinkingCount == 0 ? out : min(out, visibleWeight / charsPerToken)
        return blocks.map { block in
            var b = block
            if b.kind == .thinking {
                b.tokens = (out - visibleTokens) / Double(thinkingCount)
            } else {
                b.tokens = visibleWeight > 0 ? visibleTokens * b.weight / visibleWeight : visibleTokens / Double(visible.count)
            }
            return b
        }
    }

    // MARK: Report

    func report(lastModified: Date) -> ContextReport? {
        guard request != nil || !compactions.isEmpty else { return nil }

        var pieces: [ContextItem]
        var system = self.system
        let total: Int
        if let request {
            pieces = settled + Self.split(reply, output: request.output)
            total = request.context + request.output
        } else {
            // Compacted, and nothing sent since: all that's known is the size afterwards.
            total = compactions.last?.after ?? 0
            pieces = [ContextItem(kind: .summary, tool: nil, label: "Compaction summary", weight: 0, tokens: Double(total))]
            system = 0
        }

        // Make the parts add up to the measured total. Pieces can overshoot when Claude Code drops
        // something from the context (old thinking, cleared tool output) between requests.
        system = min(system, Double(total))
        let room = Double(total) - system
        let sum = pieces.reduce(0) { $0 + $1.tokens }
        if sum > room, sum > 0 {
            let scale = room / sum
            for i in pieces.indices { pieces[i].tokens *= scale }
        } else {
            system += room - sum
        }

        var byKind: [ContextKind: Double] = [.system: system]
        var byTool: [String: Double] = [:]
        var merged: [String: BigItem] = [:]
        for p in pieces {
            byKind[p.kind, default: 0] += p.tokens
            if let tool = p.tool { byTool[tool, default: 0] += p.tokens }
            guard p.kind != .thinking, p.kind != .reply else { continue }
            let key = "\(p.kind.rawValue)|\(p.label)"
            var big = merged[key] ?? BigItem(kind: p.kind, tool: p.tool, label: p.label, tokens: 0, count: 0)
            big.tokens += p.tokens
            big.count += 1
            merged[key] = big
        }

        let project = cwd.isEmpty ? "Unknown project" : URL(fileURLWithPath: cwd).lastPathComponent
        let firstLine = title?.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix { $0 != "\n" } ?? ""
        let growth = recent.count >= 3 ? Double(recent.last! - recent.first!) / Double(recent.count - 1) : nil

        return ContextReport(
            id: fileID,
            title: firstLine.isEmpty ? project : String(firstLine.prefix(80)),
            project: project,
            model: model,
            lastActivity: lastActivity ?? lastModified,
            tokens: total,
            peak: peak,
            breakdown: byKind.map { (kind: $0.key, tokens: Int($0.value.rounded())) }
                .filter { $0.tokens > 0 }.sorted { $0.tokens > $1.tokens },
            tools: byTool.map { (name: $0.key, tokens: Int($0.value.rounded())) }
                .filter { $0.tokens > 0 }.sorted { $0.tokens > $1.tokens },
            biggest: Array(merged.values.filter { $0.tokens >= 1 }.sorted { $0.tokens > $1.tokens }.prefix(12)),
            timeline: Self.thin(timeline),
            compactions: compactions,
            growthPerRequest: growth.flatMap { $0 > 0 ? $0 : nil })
    }

    /// Keeps a long timeline chartable: about 400 points, never dropping a compaction's fall.
    private static func thin(_ points: [ContextPoint]) -> [ContextPoint] {
        let step = max(1, points.count / 400)
        guard step > 1 else { return points }
        return points.indices.filter { i in
            i % step == 0 || i == points.count - 1 || (i > 0 && points[i].tokens < points[i - 1].tokens)
        }.map { points[$0] }
    }

    // MARK: Helpers

    static func label(tool: String, input: [String: Any]) -> String {
        func field(_ keys: String...) -> String? {
            for k in keys {
                if let s = input[k] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
            }
            return nil
        }
        let detail: String?
        switch tool {
        case "Read", "Write", "Edit", "MultiEdit", "NotebookEdit": detail = field("file_path", "notebook_path")
        case "Bash": detail = field("description", "command")
        case "Grep", "Glob": detail = field("pattern")
        case "WebFetch": detail = field("url").map { URL(string: $0)?.host ?? $0 }
        case "WebSearch": detail = field("query")
        case "Agent", "Task": detail = field("description", "subagent_type")
        default: detail = field("file_path", "path", "url", "description", "query", "command", "name")
        }
        let name = Fmt.tool(tool)
        guard var d = detail?.trimmingCharacters(in: .whitespacesAndNewlines) else { return name }
        if d.hasPrefix("/"), !d.contains(" ") { d = URL(fileURLWithPath: d).lastPathComponent }
        let line = d.prefix { $0 != "\n" }
        return "\(name) · " + (line.count > 60 ? String(line.prefix(59)) + "…" : String(line))
    }

    static func textItem(_ text: String, meta: Bool) -> ContextItem {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let weight = Double(text.utf8.count)
        guard !meta, !trimmed.hasPrefix("<") else {
            let label: String
            if trimmed.hasPrefix("<system-reminder>") { label = "System reminder" }
            else if trimmed.hasPrefix("<command-") || trimmed.hasPrefix("<local-command") { label = "Slash command" }
            else if trimmed.hasPrefix("<bash-") { label = "Shell command" }
            else { label = "Injected context" }
            return ContextItem(kind: .reminder, tool: nil, label: label, weight: weight)
        }
        let line = trimmed.prefix { $0 != "\n" }
        let short = line.count > 50 ? String(line.prefix(49)) + "…" : String(line)
        return ContextItem(kind: .prompt, tool: nil, label: "“\(short)”", weight: weight)
    }

    static func attachmentLabel(_ type: String, _ a: [String: Any]) -> String {
        let file = (a["filename"] as? String).map { " · " + URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        switch type {
        case "file": return "Attached file" + file
        case "edited_text_file": return "Changed file" + file
        case "hook_additional_context": return "Hook context"
        case "skill_listing": return "Skill list"
        case "task_reminder": return "Task list"
        case "queued_command": return "Queued message"
        default:
            let words = type.replacingOccurrences(of: "_", with: " ")
            return words.prefix(1).uppercased() + words.dropFirst()
        }
    }

    /// Size in characters of message content: a string, or blocks of text and images.
    static func length(_ value: Any?) -> Double {
        switch value {
        case let s as String:
            return Double(s.utf8.count)
        case let blocks as [Any]:
            return blocks.reduce(0) { sum, block in
                guard let b = block as? [String: Any] else { return sum + length(block) }
                if b["type"] as? String == "image" { return sum + imageWeight }
                return sum + length(b["text"] ?? b["content"])
            }
        case let dict as [String: Any]:
            return length(dict["text"] ?? dict["content"])
        default:
            return 0
        }
    }

    private static func int(_ d: [String: Any], _ key: String) -> Int { (d[key] as? NSNumber)?.intValue ?? 0 }

    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let whole = ISO8601DateFormatter()

    static func date(_ s: String) -> Date? { fractional.date(from: s) ?? whole.date(from: s) }
}
