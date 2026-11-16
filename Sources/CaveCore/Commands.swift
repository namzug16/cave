import Foundation

public func execute(_ command: Command) throws -> [String: Any] {
    let started = Date()
    let workspace = try Workspace.find()
    try workspace.lock()
    var report: [String: Any]
    switch command {
    case .up:
        report = try workspace.up()
    case .render(let options):
        let relaunched = try workspace.ensureHost()
        report = try workspace.render(options)
        report["host_relaunched"] = relaunched
    case .down:
        workspace.stopHost()
        unlink(workspace.socketPath)
        report = [:]
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
        let pid = try launchHost(hostExecutable)
        var state = State(buildStartedAt: buildStartedAt, buildSettings: buildSettings, hostExecutable: hostExecutable, hostPid: pid)
        state.patchCount = loadState()?.patchCount ?? 0
        try save(state)
        return ["host_pid": Int(pid), "timings": ["build_ms": buildMilliseconds, "settings_ms": settingsMilliseconds,
                                                  "launch_ms": milliseconds(since: launchStarted)]]
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
