import Foundation

enum HostConnectionError: Error {
    case notRunning
    /// The host accepted the request and died before answering: it crashed on it.
    case closedWithoutAnswer
}

/// Opens a connection to the render host's socket, or returns nil if nothing listens there.
func connectToHost(_ socketPath: String) -> Int32? {
    let connection = socket(AF_UNIX, SOCK_STREAM, 0)
    guard connection >= 0 else { return nil }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        let bytes = Array(socketPath.utf8.prefix(buffer.count - 1))
        buffer.copyBytes(from: bytes)
        buffer[bytes.count] = 0
    }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(connection, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else {
        close(connection)
        return nil
    }
    return connection
}

/// Sends one JSON request to the render host and returns its JSON answer.
func requestHost(_ socketPath: String, _ request: [String: Any], timeoutSeconds: Int = 60) throws -> [String: Any] {
    guard let connection = connectToHost(socketPath) else { throw HostConnectionError.notRunning }
    defer { close(connection) }
    var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
    setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    let line = try JSONSerialization.data(withJSONObject: request) + Data("\n".utf8)
    _ = line.withUnsafeBytes { write(connection, $0.baseAddress, line.count) }
    var answer = Data()
    var buffer = [UInt8](repeating: 0, count: 65536)
    while !answer.contains(UInt8(ascii: "\n")) {
        let count = read(connection, &buffer, buffer.count)
        if count < 0, errno == EINTR { continue }
        if count < 0, errno == EAGAIN {
            throw CaveError("the render host did not answer within \(timeoutSeconds) s",
                            hint: "the view may be stuck in a loop; cave up restarts the host")
        }
        guard count > 0 else { throw HostConnectionError.closedWithoutAnswer }
        answer.append(buffer, count: count)
    }
    guard let response = try JSONSerialization.jsonObject(with: answer) as? [String: Any] else {
        throw CaveError("the render host sent something that is not a JSON object")
    }
    guard response["ok"] as? Bool == true else {
        throw CaveError(response["error"] as? String ?? "the render host failed")
    }
    return response
}

extension Workspace {
    /// Sends a request, turning a crash of the host into an error that carries its log.
    func send(_ request: [String: Any]) throws -> [String: Any] {
        do {
            return try requestHost(socketPath, request)
        } catch HostConnectionError.closedWithoutAnswer {
            throw CaveError("the render host crashed while handling \(request["op"] ?? "a request")",
                            hint: "read host_log_tail; the next cave command starts the host again",
                            hostLogTail: tail(ofFile: hostLog))
        } catch HostConnectionError.notRunning {
            throw CaveError("the render host is not running", hint: "run cave up")
        }
    }

    /// A host busy with a long render still accepts connections, so this doesn't wait on it.
    func hostIsRunning() -> Bool {
        guard let connection = connectToHost(socketPath) else { return false }
        close(connection)
        return true
    }

    /// Starts the host if it isn't running (after a crash, say) and re-applies the newest patch.
    /// Returns whether it had to start it.
    func ensureHost() throws -> Bool {
        if hostIsRunning() { return false }
        guard var state = loadState() else { throw CaveError("no build to run yet", hint: "run cave up") }
        state.hostPid = try launchHost(state.hostExecutable)
        try save(state)
        if let patch = state.lastPatch { _ = try send(["op": "load", "path": patch]) }
        return true
    }

    func launchHost(_ executable: String) throws -> pid_t {
        try FileManager.default.createDirectory(at: hostHome, withIntermediateDirectories: true)
        unlink(socketPath)
        var environment = ProcessInfo.processInfo.environment
        // The host runs unsandboxed: keep its preferences and files out of the user's real home.
        environment["CFFIXED_USER_HOME"] = hostHome.path
        let pid = try spawnDetached(executable, arguments: ["--cave-socket", socketPath], environment: environment, log: hostLog)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if hostIsRunning() { return pid }
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == pid {
                throw CaveError("the render host exited during startup",
                                hint: "check that App.init() calls CaveHost.runIfRequested(caveFixtures)",
                                hostLogTail: tail(ofFile: hostLog))
            }
            usleep(50_000)
        }
        kill(pid, SIGKILL)
        throw CaveError("the render host did not start listening within 30 s",
                        hint: "check that App.init() calls CaveHost.runIfRequested(caveFixtures)",
                        hostLogTail: tail(ofFile: hostLog))
    }

    func stopHost() {
        _ = try? requestHost(socketPath, ["op": "quit"], timeoutSeconds: 5)
        guard let pid = loadState()?.hostPid else { return }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, isHost(pid) { usleep(50_000) }
        if isHost(pid) { kill(pid, SIGKILL) }
    }

    /// Guards against signalling an unrelated process that reused the pid.
    private func isHost(_ pid: pid_t) -> Bool {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).hasPrefix(hostDirectory.resolvingSymlinksInPath().path)
    }
}
