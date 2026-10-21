import Foundation

struct ScanResult {
    var sessions: [ContextReport]
    /// The largest context seen per model, which shows when a model's window is bigger than assumed.
    var peaks: [String: Int]
    var settings: ClaudeCodeSettings
    /// Whether any log changed since the previous scan.
    var changed: Bool
}

/// Follows Claude Code's session logs (`~/.claude/projects/<project>/<session>.jsonl`), reading only
/// what's been appended since the last scan. Read-only.
actor ContextScanner {
    private struct Tracked {
        var mtime: Date
        var size: Int
        var offset: Int
        var parser: SessionParser
        var report: ContextReport?
    }

    private let roots: [URL]
    private let home: URL
    private let maxAge: TimeInterval
    private var files: [String: Tracked] = [:]
    private var settings: (stamp: [Date], value: ClaudeCodeSettings)?

    /// - Parameters:
    ///   - roots: folders holding one subfolder of logs per project.
    ///   - maxAge: logs untouched for longer than this are left out.
    init(roots: [URL]? = nil, home: URL? = nil, maxAge: TimeInterval = 3 * 86400) {
        let home = home ?? FileManager.default.homeDirectoryForCurrentUser
        self.home = home
        self.roots = roots ?? [
            home.appendingPathComponent(".claude/projects"),
            home.appendingPathComponent(".config/claude/projects"),
        ]
        self.maxAge = maxAge
    }

    func scan(now: Date = Date()) -> ScanResult {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        var seen = Set<String>()
        var changed = false
        for root in roots {
            for project in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                // Subagents log into subfolders; they have contexts of their own, so only the top level counts.
                let logs = (try? fm.contentsOfDirectory(at: project, includingPropertiesForKeys: Array(keys))) ?? []
                for url in logs where url.pathExtension == "jsonl" {
                    guard let v = try? url.resourceValues(forKeys: keys),
                          let mtime = v.contentModificationDate, let size = v.fileSize,
                          now.timeIntervalSince(mtime) < maxAge else { continue }
                    seen.insert(url.path)
                    if read(url, mtime: mtime, size: size) { changed = true }
                }
            }
        }
        for path in files.keys where !seen.contains(path) {
            files[path] = nil
            changed = true
        }

        var peaks: [String: Int] = [:]
        var sessions: [ContextReport] = []
        for t in files.values {
            if !t.parser.model.isEmpty { peaks[t.parser.model] = max(peaks[t.parser.model] ?? 0, t.parser.peak) }
            if let r = t.report { sessions.append(r) }
        }
        sessions.sort { $0.lastActivity > $1.lastActivity }
        return ScanResult(sessions: sessions, peaks: peaks, settings: readSettings(), changed: changed)
    }

    /// Reads whatever is new in one log. Returns whether anything changed.
    private func read(_ url: URL, mtime: Date, size: Int) -> Bool {
        let fresh = Tracked(mtime: .distantPast, size: -1, offset: 0,
                            parser: SessionParser(fileID: url.deletingPathExtension().lastPathComponent))
        var t = files[url.path] ?? fresh
        if t.mtime == mtime, t.size == size { return false }
        if size < t.offset { t = fresh }     // rewritten rather than appended to

        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            try? handle.seek(toOffset: UInt64(t.offset))
            if let data = try? handle.readToEnd(), let end = data.lastIndex(of: 0x0A) {
                // Whole lines only; one still being written is picked up next time.
                for line in data[data.startIndex..<end].split(separator: 0x0A) {
                    t.parser.consume(line: line)
                }
                t.offset += end - data.startIndex + 1
            }
        }
        t.mtime = mtime
        t.size = size
        t.report = t.parser.report(lastModified: mtime)
        files[url.path] = t
        return true
    }

    private func readSettings() -> ClaudeCodeSettings {
        let paths = [".claude/settings.json", ".claude.json"].map { home.appendingPathComponent($0) }
        let stamp = paths.map {
            (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        }
        if let settings, settings.stamp == stamp { return settings.value }
        let value = ClaudeCodeSettings.read(home: home)
        settings = (stamp, value)
        return value
    }
}
