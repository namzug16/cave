import Foundation

struct ShellResult {
    var status: Int32
    var output: String
}

/// Runs a tool to completion and returns its exit status and output: stdout, plus stderr unless discarded.
func run(_ arguments: [String], discardingStandardError: Bool = false) throws -> ShellResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = discardingStandardError ? FileHandle.nullDevice : pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return ShellResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
}

/// Starts a process in a session of its own, so it outlives cave, with its output in `log`.
/// Adapted from Simless (https://github.com/abacusai/simless, Apache-2.0).
func spawnDetached(_ executable: String, arguments: [String], environment: [String: String], log: String) throws -> pid_t {
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, log, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    posix_spawn_file_actions_adddup2(&actions, 1, 2)
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
    let argv = ([executable] + arguments).map { strdup($0) } + [nil]
    let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
    var pid: pid_t = 0
    let status = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
    guard status == 0 else { throw CaveError("could not start \(executable): \(String(cString: strerror(status)))") }
    return pid
}

func tail(ofFile path: String, lines count: Int = 20) -> String? {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8), !text.isEmpty else { return nil }
    return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(count).joined(separator: "\n")
}

func modificationDate(_ path: String) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
}
