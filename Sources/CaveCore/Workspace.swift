import CryptoKit
import Foundation

struct Config: Decodable {
    var project: String
    var scheme: String
    var fixtures: String
}

/// What `cave up` learned about the last good build, kept in `.cave/state.json`.
struct State: Codable {
    var buildStartedAt: Date
    var buildSettings: [String: String]
    var hostExecutable: String
    var hostPid: pid_t?
    var patchCount = 0
    var lastPatch: String?
    var lastPatchStartedAt: Date?

    func setting(_ key: String) throws -> String {
        guard let value = buildSettings[key], !value.isEmpty else { throw CaveError("build setting \(key) is missing", hint: "run cave up") }
        return value
    }

    /// Code in the host is current up to this moment: the last build or patch, whichever came later.
    var hostCodeDate: Date { max(buildStartedAt, lastPatchStartedAt ?? .distantPast) }
}

struct Workspace {
    let root: URL
    let config: Config

    var dotCave: URL { root.appendingPathComponent(".cave") }
    var derivedData: URL { dotCave.appendingPathComponent("DerivedData") }
    var hostDirectory: URL { dotCave.appendingPathComponent("host") }
    var hostHome: URL { dotCave.appendingPathComponent("home") }
    var hostLog: String { dotCave.appendingPathComponent("host.log").path }
    var patches: URL { dotCave.appendingPathComponent("patches") }
    var renders: URL { dotCave.appendingPathComponent("renders") }
    var moduleCache: URL { dotCave.appendingPathComponent("ModuleCache") }
    var statePath: URL { dotCave.appendingPathComponent("state.json") }
    var fixturesFile: String { root.appendingPathComponent(config.fixtures).standardizedFileURL.path }

    /// In the temporary directory because a socket path must fit in 104 bytes, and repositories nest deep.
    var socketPath: String {
        let digest = SHA256.hash(data: Data(root.path.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return (NSTemporaryDirectory() as NSString).appendingPathComponent("cave-\(digest).sock")
    }

    static func find(from directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) throws -> Workspace {
        var candidate = directory.standardizedFileURL
        while true {
            let configURL = candidate.appendingPathComponent("cave.json")
            if FileManager.default.fileExists(atPath: configURL.path) {
                do {
                    let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: configURL))
                    return Workspace(root: candidate, config: config)
                } catch {
                    throw CaveError("cannot read \(configURL.path): \(error)",
                                    hint: #"cave.json needs "project", "scheme" and "fixtures" paths relative to it"#)
                }
            }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else {
                throw CaveError("no cave.json in \(directory.path) or any parent",
                                hint: "run cave guide for how to set cave up in this app")
            }
            candidate = parent
        }
    }

    func loadState() -> State? {
        guard let data = try? Data(contentsOf: statePath) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    func save(_ state: State) throws {
        try FileManager.default.createDirectory(at: dotCave, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: statePath, options: .atomic)
    }

    /// Serializes cave commands per worktree; released when the process exits.
    func lock() throws {
        try FileManager.default.createDirectory(at: dotCave, withIntermediateDirectories: true)
        let descriptor = open(dotCave.appendingPathComponent("lock").path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0, flock(descriptor, LOCK_EX) == 0 else {
            throw CaveError("cannot lock \(dotCave.path): \(String(cString: strerror(errno)))")
        }
    }

    /// The app's Swift sources, as the last build compiled them.
    func appSources(_ state: State) throws -> [String] {
        let listPath = try state.setting("SWIFT_RESPONSE_FILE_PATH_normal_\(try state.setting("NATIVE_ARCH_ACTUAL"))")
        guard let list = try? String(contentsOfFile: listPath, encoding: .utf8) else {
            throw CaveError("cannot read the build's source list at \(listPath)", hint: "run cave up")
        }
        return list.split(separator: "\n").map(String.init)
    }

    /// Swift files deleted since the last build, or added next to its sources since then: a patch
    /// can't add or remove files, so these need a full build. Older unlisted files are left out of
    /// the target on purpose.
    func sourcesAddedOrRemoved(_ state: State) throws -> [String] {
        let sources = try appSources(state)
        let listed = Set(sources)
        let removed = sources.filter { !FileManager.default.fileExists(atPath: $0) }
        let directories = Set(sources.map { ($0 as NSString).deletingLastPathComponent })
        let added = directories.sorted().flatMap { directory in
            ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
                .filter { $0.hasSuffix(".swift") }
                .map { "\(directory)/\($0)" }
                .filter { !listed.contains($0) && (modificationDate($0) ?? .distantPast) > state.buildStartedAt }
        }
        return removed + added
    }

    func sourcesChanged(since date: Date, _ state: State) throws -> [String] {
        try appSources(state).filter { (modificationDate($0) ?? .distantFuture) > date }
    }
}
