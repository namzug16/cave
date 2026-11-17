import Foundation

public func execute(_ command: Command) throws -> [String: Any] {
    let started = Date()
    if command == .guide { return ["ok": true, "guide": agentGuide] }
    let workspace = try Workspace.find()
    // Read-only, so it never waits behind a build another command holds the lock for.
    if command == .status { return try workspace.status().merging(["ok": true]) { $1 } }
    try workspace.lock()
    var report: [String: Any]
    switch command {
    case .up:
        report = try workspace.up()
    case .render(let options):
        let relaunched = try workspace.ensureHost()
        report = try workspace.render(options)
        report["host_relaunched"] = relaunched
    case .reload(let options, let full):
        report = full ? try workspace.up() : try workspace.reload()
        if let options {
            let rendered = try workspace.render(options)
            report["renders"] = rendered["renders"]
            report["changed_since_reload"] = rendered["changed_since_reload"]
            report.merge(timings: rendered["timings"])
        }
    case .down:
        workspace.stopHost()
        unlink(workspace.socketPath)
        report = [:]
    case .list:
        let relaunched = try workspace.ensureHost()
        report = ["fixtures": try workspace.send(["op": "list"])["fixtures"] ?? [], "host_relaunched": relaunched]
    case .status, .guide:
        preconditionFailure("handled before taking the lock")
    }
    report["ok"] = true
    report.merge(timings: ["total_ms": milliseconds(since: started)])
    return report
}

extension Dictionary where Key == String, Value == Any {
    mutating func merge(timings: Any?) {
        let current = self["timings"] as? [String: Int] ?? [:]
        self["timings"] = current.merging(timings as? [String: Int] ?? [:]) { $1 }
    }
}

extension Workspace {
    /// Builds the Debug app, then swaps the running host for one on the new build.
    /// A failed build leaves the previous host running.
    func up() throws -> [String: Any] {
        let buildStartedAt = Date()
        let projectPath = root.appendingPathComponent(config.project).path
        #if arch(arm64)
        let destination = "platform=macOS,arch=arm64"
        #else
        let destination = "platform=macOS,arch=x86_64"
        #endif
        let common = ["-project", projectPath, "-scheme", config.scheme, "-configuration", "Debug",
                      "-destination", destination, "-derivedDataPath", derivedData.path]
        let build = try run(["xcodebuild", "build", "-quiet"] + common)
        guard build.status == 0 else {
            let diagnostics = parseDiagnostics(build.output)
            throw CaveError(diagnostics.isEmpty ? "xcodebuild failed:\n\(build.output.suffix(3000))" : "xcodebuild failed",
                            hint: "fix the build errors and run cave up again; the previous host keeps running",
                            diagnostics: diagnostics)
        }
        let buildMilliseconds = milliseconds(since: buildStartedAt)

        let settingsStarted = Date()
        // stderr carries xcodebuild's own log lines, which would break the JSON.
        let settingsOutput = try run(["xcodebuild", "-showBuildSettings", "-json"] + common, discardingStandardError: true)
        guard settingsOutput.status == 0,
              let targets = try? JSONSerialization.jsonObject(with: Data(settingsOutput.output.utf8)) as? [[String: Any]],
              let buildSettings = targets.first?["buildSettings"] as? [String: String] else {
            throw CaveError("cannot read build settings (xcodebuild -showBuildSettings exited \(settingsOutput.status))",
                            hint: "run xcodebuild -showBuildSettings -json -scheme \(config.scheme) by hand to see why")
        }
        let settingsMilliseconds = milliseconds(since: settingsStarted)

        let launchStarted = Date()
        stopHost()
        let productName = buildSettings["FULL_PRODUCT_NAME"] ?? ""
        let builtApp = URL(fileURLWithPath: buildSettings["BUILT_PRODUCTS_DIR"] ?? "").appendingPathComponent(productName)
        let hostApp = hostDirectory.appendingPathComponent(productName)
        try? FileManager.default.removeItem(at: hostDirectory)
        try FileManager.default.createDirectory(at: hostDirectory, withIntermediateDirectories: true)
        // An APFS clone, re-signed ad hoc without entitlements: the host runs outside the app
        // sandbox so it can reach its socket and load patches from .cave without prompts.
        for step in [["cp", "-cR", builtApp.path, hostApp.path],
                     ["codesign", "--force", "--sign", "-", "--timestamp=none", hostApp.path]] {
            let result = try run(step)
            guard result.status == 0 else { throw CaveError("\(step.joined(separator: " ")) failed:\n\(result.output)") }
        }
        let hostExecutable = hostDirectory.appendingPathComponent(buildSettings["EXECUTABLE_PATH"] ?? "").path
        // Saved before launching: if the new host fails to start, the next command must not
        // relaunch it with the old build's patch.
        var state = State(buildStartedAt: buildStartedAt, buildSettings: buildSettings, hostExecutable: hostExecutable)
        state.patchCount = loadState()?.patchCount ?? 0
        try save(state)
        let pid = try launchHost(hostExecutable)
        state.hostPid = pid
        try save(state)
        return ["host_pid": Int(pid), "timings": ["build_ms": buildMilliseconds, "settings_ms": settingsMilliseconds,
                                                  "launch_ms": milliseconds(since: launchStarted)]]
    }

    func reload() throws -> [String: Any] {
        let relaunched = try ensureHost()
        guard var state = loadState() else { throw CaveError("no build to patch yet", hint: "run cave up") }
        let addedOrRemoved = try sourcesAddedOrRemoved(state)
        guard addedOrRemoved.isEmpty else {
            throw CaveError("Swift files were added or removed since the last build: \(addedOrRemoved.joined(separator: ", "))",
                            hint: "a patch can't add or remove files; run cave reload --full")
        }
        guard try !sourcesChanged(since: state.hostCodeDate, state).isEmpty else {
            return ["host_relaunched": relaunched, "patched_files": [String](), "stale_files": [[String: Any]]()]
        }
        let compileStarted = Date()
        let patch = try compilePatch(&state)
        let compileMilliseconds = milliseconds(since: compileStarted)
        let applyStarted = Date()
        _ = try send(["op": "load", "path": patch.dylib])
        try save(state)
        return [
            "host_relaunched": relaunched,
            "patched_files": patch.files,
            "stale_files": patch.stale.map { ["file": $0.file, "reason": $0.reason] },
            "timings": ["compile_ms": compileMilliseconds, "apply_ms": milliseconds(since: applyStarted)],
        ]
    }

    func status() throws -> [String: Any] {
        guard let state = loadState() else {
            return ["host_running": false, "next": nextCommand(hasBuild: false, needsFullBuild: false, changed: [], fixture: nil)]
        }
        let running = hostIsRunning()
        let changed = try sourcesChanged(since: state.hostCodeDate, state)
        let needsFullBuild = try sourcesChanged(since: state.buildStartedAt, state).contains { $0.hasSuffix("/CaveKit.swift") }
            || !(try sourcesAddedOrRemoved(state)).isEmpty
        let fixtures = running ? (try? send(["op": "list"]))?["fixtures"] as? [String] : nil
        var report: [String: Any] = [
            "host_running": running,
            "built_at": ISO8601DateFormatter().string(from: state.buildStartedAt),
            "changed_since_reload": changed,
            "next": nextCommand(hasBuild: true, needsFullBuild: needsFullBuild, changed: changed, fixture: fixtures?.first),
        ]
        if let fixtures { report["fixtures"] = fixtures }
        if let pid = state.hostPid, running { report["host_pid"] = Int(pid) }
        return report
    }

    func render(_ options: RenderOptions) throws -> [String: Any] {
        let started = Date()
        let response = try send(["op": "render", "fixture": options.fixture, "sizes": options.sizes,
                                 "appearances": options.appearances,
                                 "out": renders.appendingPathComponent(options.fixture).path])
        var report: [String: Any] = ["renders": response["renders"] ?? [], "timings": ["render_ms": milliseconds(since: started)]]
        if let state = loadState() {
            let changed = try sourcesChanged(since: state.hostCodeDate, state)
            if !changed.isEmpty { report["changed_since_reload"] = changed }
        }
        return report
    }
}

/// The one command an agent should run next, given what `cave status` found.
public func nextCommand(hasBuild: Bool, needsFullBuild: Bool, changed: [String], fixture: String?) -> String {
    let fixture = fixture ?? "<fixture>"
    if !hasBuild { return "cave up --json" }
    if needsFullBuild { return "cave reload --full --render \(fixture) --json" }
    if !changed.isEmpty { return "cave reload --render \(fixture) --json" }
    return "cave render \(fixture) --json"
}
