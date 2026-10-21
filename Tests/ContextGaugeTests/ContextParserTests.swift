import Foundation
import Testing
@testable import ContextGauge

/// Builds Claude Code-shaped log lines with increasing timestamps.
private struct Log {
    private var second = 0
    private(set) var lines: [[String: Any]] = []

    private mutating func stamp() -> String {
        second += 1
        return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_800_000_000 + Double(second)))
    }

    mutating func prompt(_ text: String) {
        lines.append(["type": "user", "timestamp": stamp(), "cwd": "/work/app",
                      "message": ["role": "user", "content": text]])
    }

    mutating func toolResult(_ id: String, _ text: String) {
        lines.append(["type": "user", "timestamp": stamp(),
                      "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": text]]]])
    }

    /// One line of a reply. `context` is everything the request sent.
    mutating func reply(_ request: String, context: Int, output: Int, _ block: [String: Any],
                        model: String = "claude-opus-5-5", sidechain: Bool = false) {
        lines.append(["type": "assistant", "timestamp": stamp(), "requestId": request, "isSidechain": sidechain,
                      "message": ["id": "msg_" + request, "model": model, "content": [block],
                                  "usage": ["input_tokens": 10, "cache_creation_input_tokens": 0,
                                            "cache_read_input_tokens": context - 10, "output_tokens": output]]])
    }

    mutating func compact(before: Int, after: Int, automatic: Bool) {
        lines.append(["type": "system", "subtype": "compact_boundary", "timestamp": stamp(),
                      "compactMetadata": ["trigger": automatic ? "auto" : "manual", "preTokens": before, "postTokens": after]])
        lines.append(["type": "user", "timestamp": stamp(), "isCompactSummary": true,
                      "message": ["role": "user", "content": String(repeating: "s", count: 5_000)]])
    }

    mutating func raw(_ obj: [String: Any]) { lines.append(obj) }

    func data() -> Data {
        lines.map { try! JSONSerialization.data(withJSONObject: $0) + Data("\n".utf8) }.reduce(Data(), +)
    }

    func parse() -> ContextReport? {
        var p = SessionParser(fileID: "test")
        for line in lines { p.consume(line: try! JSONSerialization.data(withJSONObject: line)) }
        return p.report(lastModified: Date())
    }
}

private func text(_ s: String) -> [String: Any] { ["type": "text", "text": s] }
private let thinking: [String: Any] = ["type": "thinking", "thinking": "", "signature": "sig"]
private func use(_ id: String, _ name: String, _ input: [String: Any]) -> [String: Any] {
    ["type": "tool_use", "id": id, "name": name, "input": input]
}

private func tokens(_ r: ContextReport, _ kind: ContextKind) -> Int {
    r.breakdown.first { $0.kind == kind }?.tokens ?? 0
}

/// The parts always add up to the measured total (each kind is rounded separately).
private func addsUp(_ r: ContextReport) -> Bool {
    abs(r.breakdown.reduce(0) { $0 + $1.tokens } - r.tokens) <= r.breakdown.count
}

@Suite struct ParserTests {
    @Test func firstRequestSeparatesTheSystemPrompt() throws {
        var log = Log()
        log.prompt("hello")
        log.reply("r1", context: 20_000, output: 100, text("Hi! What are we building?"))
        let r = try #require(log.parse())

        #expect(r.tokens == 20_100)
        #expect(tokens(r, .system) == 19_998)
        #expect(tokens(r, .prompt) == 2)
        #expect(tokens(r, .reply) == 100)
        #expect(r.project == "app")
        #expect(r.title == "app")
        #expect(addsUp(r))
    }

    @Test func growthGoesToWhatArrivedInBetween() throws {
        var log = Log()
        log.prompt("read the views")
        log.reply("r1", context: 20_000, output: 500, use("t1", "Read", ["file_path": "/work/app/Views.swift"]))
        log.toolResult("t1", String(repeating: "x", count: 10_000))
        log.reply("r2", context: 24_500, output: 200, text("Done."))
        let r = try #require(log.parse())

        #expect(r.tokens == 24_700)
        #expect(tokens(r, .toolResult) == 4_000, "growth minus the previous reply")
        #expect(tokens(r, .toolCall) == 500, "no thinking, so all output goes to the visible blocks")
        #expect(r.biggest.first?.label == "Read · Views.swift")
        #expect(r.biggest.first?.kind == .toolResult)
        #expect(r.tools.first?.name == "Read")
        #expect(r.tools.first?.tokens == 4_500)
        #expect(addsUp(r))
    }

    @Test func hiddenThinkingGetsTheOutputTheVisibleBlocksDoNotExplain() throws {
        var log = Log()
        log.prompt("think hard")
        log.reply("r1", context: 10_000, output: 1, thinking)
        log.reply("r1", context: 10_000, output: 1_000, text(String(repeating: "a", count: 250)))
        let r = try #require(log.parse())

        #expect(tokens(r, .reply) == 100)        // 250 characters at 2.5 per token
        #expect(tokens(r, .thinking) == 900)
        #expect(r.tokens == 11_000, "the last streamed line's output count wins")
        #expect(r.timeline.count == 1, "one request, however many lines")
        #expect(addsUp(r))
    }

    @Test func compactionStartsOverAndIsRecorded() throws {
        var log = Log()
        log.prompt("go")
        log.reply("r1", context: 150_000, output: 1_000, text("…"))
        log.compact(before: 151_000, after: 20_000, automatic: true)
        log.reply("r2", context: 22_000, output: 300, text("Picking up where we left off."))
        let r = try #require(log.parse())

        #expect(r.compactions.count == 1)
        #expect(r.compactions.first?.automatic == true)
        #expect(r.compactions.first?.before == 151_000)
        #expect(r.tokens == 22_300)
        #expect(tokens(r, .summary) == 2_000)    // 5,000 characters
        #expect(r.timeline.map(\.tokens) == [150_000, 20_000, 22_000])
        #expect(r.peak == 150_000)
        #expect(r.growthPerRequest == nil)
        #expect(addsUp(r))
    }

    @Test func compactedWithNothingSentSinceShowsTheSizeAfter() throws {
        var log = Log()
        log.prompt("go")
        log.reply("r1", context: 150_000, output: 1_000, text("…"))
        log.compact(before: 151_000, after: 20_000, automatic: false)
        let r = try #require(log.parse())

        #expect(r.tokens == 20_000)
        #expect(r.breakdown.map(\.kind) == [.summary])
        #expect(r.compactions.first?.automatic == false)
    }

    @Test func subagentsAndLocalMessagesAreIgnored() throws {
        var log = Log()
        log.prompt("go")
        log.reply("r1", context: 20_000, output: 100, text("ok"))
        log.reply("side", context: 90_000, output: 5_000, text("subagent"), sidechain: true)
        log.reply("local", context: 0, output: 0, text("API Error"), model: "<synthetic>")
        let r = try #require(log.parse())

        #expect(r.tokens == 20_100)
        #expect(r.model == "claude-opus-5-5")
        #expect(r.timeline.count == 1)
    }

    @Test func droppedContentScalesThePiecesDown() throws {
        var log = Log()
        log.prompt("go")
        log.reply("r1", context: 20_000, output: 1_000, use("t1", "Bash", ["command": "cat big.log"]))
        log.toolResult("t1", String(repeating: "x", count: 40_000))
        // 7K less than the reply and the output add up to: Claude Code dropped something.
        log.reply("r2", context: 30_000, output: 100, text("ok"))
        let r = try #require(log.parse())

        #expect(r.tokens == 30_100)
        #expect(tokens(r, .system) == 19_999)
        #expect(addsUp(r))
        #expect(tokens(r, .toolResult) > 0)
    }

    @Test func growthRateFollowsRecentRequests() throws {
        var log = Log()
        log.prompt("go")
        for i in 0..<5 {
            log.reply("r\(i)", context: 20_000 + i * 3_000, output: 100, use("t\(i)", "Grep", ["pattern": "foo"]))
            log.toolResult("t\(i)", String(repeating: "x", count: 7_000))
        }
        let r = try #require(log.parse())

        #expect(r.growthPerRequest == 3_000)
        #expect(r.biggest.first?.label == "Grep · foo")
        #expect(r.biggest.first?.count == 4, "the last result hasn't been sent yet")
    }

    @Test func titlePrefersCustomTitles() {
        var log = Log()
        log.prompt("go")
        log.reply("r1", context: 20_000, output: 100, text("ok"))
        log.raw(["type": "last-prompt", "lastPrompt": "fix the login bug\nand more"])
        #expect(log.parse()?.title == "fix the login bug")
        log.raw(["type": "custom-title", "customTitle": "Login fix"])
        log.raw(["type": "last-prompt", "lastPrompt": "now the tests"])
        #expect(log.parse()?.title == "Login fix")
    }

    @Test func noRequestsMeansNoReport() {
        var log = Log()
        log.prompt("hello")
        #expect(log.parse() == nil)
    }
}

@Suite struct LabelTests {
    @Test func toolLabels() {
        #expect(SessionParser.label(tool: "Read", input: ["file_path": "/a/b/Views.swift"]) == "Read · Views.swift")
        #expect(SessionParser.label(tool: "Bash", input: ["command": "swift test", "description": "Run tests"])
            == "Bash · Run tests")
        #expect(SessionParser.label(tool: "Bash", input: ["command": "ls\npwd"]) == "Bash · ls")
        #expect(SessionParser.label(tool: "WebFetch", input: ["url": "https://docs.swift.org/x"]) == "WebFetch · docs.swift.org")
        #expect(SessionParser.label(tool: "TodoWrite", input: [:]) == "TodoWrite")
        let long = SessionParser.label(tool: "Grep", input: ["pattern": String(repeating: "p", count: 100)])
        #expect(long.count == "Grep · ".count + 60)
        #expect(long.hasSuffix("…"))
    }

    @Test func toolNames() {
        #expect(Fmt.tool("Bash") == "Bash")
        #expect(Fmt.tool("mcp__Roblox_Studio__execute_luau") == "execute_luau (Roblox Studio)")
        #expect(Fmt.tool("mcp__1a59c906-04da-521d-bda7-7f71b9f9e01c__guide") == "guide")
        #expect(Fmt.tool("mcp__plugin_ecc_chrome-devtools__take_screenshot") == "take_screenshot (chrome-devtools)")
    }

    @Test func injectedTextIsNotCountedAsYourMessages() {
        #expect(SessionParser.textItem("<system-reminder>x</system-reminder>", meta: false).kind == .reminder)
        #expect(SessionParser.textItem("<command-name>/compact</command-name>", meta: false).label == "Slash command")
        #expect(SessionParser.textItem("Resume where you stopped", meta: true).kind == .reminder)
        #expect(SessionParser.textItem("fix it", meta: false).label == "“fix it”")
    }

    @Test func imagesCountAsAFixedSize() {
        let content: [Any] = [["type": "image", "source": ["data": String(repeating: "A", count: 500_000)]],
                              ["type": "text", "text": "abc"]]
        #expect(SessionParser.length(content) == SessionParser.imageWeight + 3)
    }
}

@Suite struct LimitsTests {
    @Test func windowSizes() {
        #expect(ContextLimits.window(model: "claude-opus-5-5", peak: 0, override: nil) == 1_000_000)
        #expect(ContextLimits.window(model: "claude-haiku-4-5-20251001", peak: 0, override: nil) == 200_000)
        #expect(ContextLimits.window(model: "claude-sonnet-4-5[1m]", peak: 0, override: nil) == 1_000_000)
        #expect(ContextLimits.window(model: "claude-haiku-4-5", peak: 250_000, override: nil) == 1_000_000)
        #expect(ContextLimits.window(model: "claude-opus-5-5", peak: 0, override: 200_000) == 200_000)
        #expect(ContextLimits.window(model: "x", peak: 1_200_000, override: nil) == 1_200_000)
    }

    @Test func autoCompactPoint() {
        let on = ClaudeCodeSettings()
        #expect(ContextLimits(window: 200_000, settings: on, warnPercent: 80).autoCompact == 167_000)
        #expect(ContextLimits(window: 1_000_000, settings: on, warnPercent: 80).autoCompact == 967_000)
        let early = ClaudeCodeSettings(autoCompact: true, compactPercent: 50)
        #expect(ContextLimits(window: 200_000, settings: early, warnPercent: 80).autoCompact == 90_000)
        let off = ContextLimits(window: 200_000, settings: ClaudeCodeSettings(autoCompact: false), warnPercent: 80)
        #expect(off.autoCompact == nil)
        #expect(off.limit == 200_000)
    }

    @Test func levels() {
        let l = ContextLimits(window: 200_000, settings: ClaudeCodeSettings(), warnPercent: 70)
        #expect(l.warn == 140_000)
        #expect(l.level(139_999) == .ok)
        #expect(l.level(140_000) == .warn)
        #expect(l.level(147_000) == .compactSoon)
        #expect(l.left(150_000) == 17_000)
        #expect(l.left(180_000) == 0)
        // A warning set past the "compact soon" point folds into it.
        #expect(ContextLimits(window: 200_000, settings: ClaudeCodeSettings(), warnPercent: 90).warn == 147_000)
    }

    @Test func formatting() {
        #expect(Fmt.tokens(950) == "950")
        #expect(Fmt.tokens(4_200) == "4.2K")
        #expect(Fmt.tokens(412_345) == "412K")
        #expect(Fmt.tokens(1_000_000) == "1M")
        #expect(Fmt.tokens(1_260_000) == "1.3M")
        #expect(Fmt.model("claude-opus-5-5") == "Opus 5.5")
        #expect(Fmt.model("claude-haiku-4-5-20251001") == "Haiku 4.5")
        #expect(Fmt.model("claude-3-5-sonnet-20241022") == "Sonnet 3.5")
        #expect(Fmt.model("claude-sonnet-5") == "Sonnet 5")
        #expect(Fmt.model("") == "Unknown model")
    }

    @Test func readsClaudeCodeSettings() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        #expect(ClaudeCodeSettings.read(home: home) == ClaudeCodeSettings())

        try Data(#"{"env": {"CLAUDE_AUTOCOMPACT_PCT_OVERRIDE": "60"}}"#.utf8)
            .write(to: home.appendingPathComponent(".claude/settings.json"))
        #expect(ClaudeCodeSettings.read(home: home) == ClaudeCodeSettings(autoCompact: true, compactPercent: 60))

        try Data(#"{"autoCompactEnabled": false}"#.utf8).write(to: home.appendingPathComponent(".claude.json"))
        #expect(!ClaudeCodeSettings.read(home: home).autoCompact)
    }
}

@Suite final class ScannerTests {
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("proj/sess/subagents"),
                                                withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private func sampleLog() -> Log {
        var log = Log()
        log.prompt("go")
        log.reply("r1", context: 20_000, output: 500, use("t1", "Read", ["file_path": "/a/Big.swift"]))
        log.toolResult("t1", String(repeating: "x", count: 10_000))
        log.reply("r2", context: 24_500, output: 200, use("t2", "Bash", ["command": "swift build"]))
        log.toolResult("t2", String(repeating: "y", count: 3_000))
        log.reply("r3", context: 26_000, output: 50, text("Built."))
        return log
    }

    @Test func readsAppendedLinesIncrementally() async throws {
        let file = root.appendingPathComponent("proj/sess.jsonl")
        let data = sampleLog().data()
        // Stop partway through a line, the way a log looks while Claude Code is writing it.
        let cut = try #require(data.firstRange(of: Data("\"r2\"".utf8))).lowerBound
        try data[..<cut].write(to: file)

        let scanner = ContextScanner(roots: [root], home: root)
        let first = await scanner.scan()
        #expect(first.changed)
        #expect(first.sessions.first?.tokens == 20_500)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: data[cut...])
        try handle.close()

        let second = await scanner.scan()
        let whole = await ContextScanner(roots: [root], home: root).scan()
        let a = try #require(second.sessions.first)
        let b = try #require(whole.sessions.first)
        #expect(a.tokens == 26_050)
        #expect(a.tokens == b.tokens)
        #expect(a.breakdown.map(\.tokens) == b.breakdown.map(\.tokens))
        #expect(a.timeline.count == 3)
        #expect(second.peaks["claude-opus-5-5"] == 26_000)

        let third = await scanner.scan()
        #expect(!third.changed)
    }

    @Test func skipsSubagentLogsAndOldSessions() async throws {
        try sampleLog().data().write(to: root.appendingPathComponent("proj/sess/subagents/agent-1.jsonl"))
        let old = root.appendingPathComponent("proj/old.jsonl")
        try sampleLog().data().write(to: old)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -10 * 86400)], ofItemAtPath: old.path)

        let result = await ContextScanner(roots: [root], home: root).scan()
        #expect(result.sessions.isEmpty)
    }

    @Test func forgetsDeletedLogs() async throws {
        let file = root.appendingPathComponent("proj/sess.jsonl")
        try sampleLog().data().write(to: file)
        let scanner = ContextScanner(roots: [root], home: root)
        #expect(await scanner.scan().sessions.count == 1)
        try FileManager.default.removeItem(at: file)
        let after = await scanner.scan()
        #expect(after.changed)
        #expect(after.sessions.isEmpty)
    }
}
