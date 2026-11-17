import Foundation

public struct Diagnostic: Equatable, Sendable {
    public var file: String
    public var line: Int
    public var column: Int
    public var message: String

    var json: [String: Any] { ["file": file, "line": line, "column": column, "message": message] }
}

public struct CaveError: Error, Sendable {
    public var message: String
    public var hint: String?
    public var diagnostics: [Diagnostic] = []
    public var hostLogTail: String?

    public init(_ message: String, hint: String? = nil, diagnostics: [Diagnostic] = [], hostLogTail: String? = nil) {
        self.message = message
        self.hint = hint
        self.diagnostics = diagnostics
        self.hostLogTail = hostLogTail
    }

    public var json: [String: Any] {
        var report: [String: Any] = [
            "ok": false,
            "errors": diagnostics.isEmpty ? [["message": message]] : diagnostics.map(\.json),
        ]
        if !diagnostics.isEmpty { report["summary"] = message }
        if let hint { report["hint"] = hint }
        if let hostLogTail { report["host_log_tail"] = hostLogTail }
        return report
    }

    public var human: String {
        var lines = diagnostics.map { "\($0.file):\($0.line):\($0.column): error: \($0.message)" }
        lines.insert("cave: \(message)", at: 0)
        if let hint { lines.append("hint: \(hint)") }
        if let hostLogTail { lines.append("host log:\n\(hostLogTail)") }
        return lines.joined(separator: "\n")
    }
}

/// Lines like `/path/File.swift:12:5: error: message`, as swiftc and xcodebuild print them.
public func parseDiagnostics(_ output: String) -> [Diagnostic] {
    var seen = Set<String>()
    return output.split(separator: "\n").compactMap { line in
        let parts = line.split(separator: ":", maxSplits: 4, omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0].hasPrefix("/"), let lineNumber = Int(parts[1]), let column = Int(parts[2]),
              parts[3].trimmingCharacters(in: .whitespaces) == "error", seen.insert(String(line)).inserted else { return nil }
        return Diagnostic(file: String(parts[0]), line: lineNumber, column: column,
                          message: parts[4].trimmingCharacters(in: .whitespaces))
    }
}

public func milliseconds(since start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }

public func humanSummary(_ report: [String: Any]) -> String {
    var lines: [String] = []
    if let guide = report["guide"] as? String { return guide }
    if let running = report["host_running"] as? Bool {
        lines.append(running ? "host: running, built \(report["built_at"] ?? "")" : "host: not running")
    }
    for fixture in report["fixtures"] as? [String] ?? [] { lines.append("fixture: \(fixture)") }
    for render in report["renders"] as? [[String: Any]] ?? [] {
        lines.append("\(render["path"] ?? "") (\(render["ms"] ?? 0) ms)")
    }
    for stale in report["stale_files"] as? [[String: Any]] ?? [] {
        lines.append("stale: \(stale["file"] ?? "") — \(stale["reason"] ?? "")")
    }
    for changed in report["changed_since_reload"] as? [String] ?? [] {
        lines.append("not in host yet: \(changed) (run cave reload)")
    }
    if let removed = report["removed"] as? String { lines.append("removed \(removed) (\(report["freed_bytes"] ?? 0) bytes)") }
    if let next = report["next"] as? String { lines.append("next: \(next)") }
    if let timings = report["timings"] as? [String: Int] {
        lines.append(timings.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
    }
    return lines.isEmpty ? "ok" : lines.joined(separator: "\n")
}
