public struct RenderOptions: Equatable, Sendable {
    public var fixture: String
    public var sizes: [[Int]] = [[1024, 768]]
    public var appearances: [String] = ["light"]
}

public enum Command: Equatable, Sendable {
    case up
    case render(RenderOptions)
    case reload(render: RenderOptions?, full: Bool)
    case down
    case status
    case list
    case guide
}

public struct Invocation: Equatable, Sendable {
    public var command: Command
    public var json: Bool
}

public let usage = """
    usage:
      cave status                               what the host runs, what changed, and the next command to run
      cave list                                 the fixtures you can render
      cave guide                                how to work with cave, for agents
      cave up                                   build the Debug app and start the render host
      cave render <fixture> [render options]    render a fixture with the code the host runs
      cave reload [--render <fixture> [render options]] [--full]
                                                patch edited Swift files into the host, then render
      cave down                                 stop the render host

    render options:
      --size WxH            window content size in points, repeatable (default 1024x768)
      --appearance LIST     light, dark or light,dark (default light)

    every command takes --json for machine-readable output
    """

public func parseInvocation(_ arguments: [String]) throws -> Invocation {
    guard let name = arguments.first else { throw CaveError("no command given", hint: usage) }
    var fixture: String?
    var sizes: [[Int]] = []
    var appearances: [String] = []
    var full = false
    var json = false
    var rest = arguments.dropFirst().makeIterator()
    func value(for flag: String) throws -> String {
        guard let value = rest.next() else { throw CaveError("\(flag) needs a value", hint: usage) }
        return value
    }
    while let argument = rest.next() {
        switch argument {
        case "--json": json = true
        case "--full": full = true
        case "--size": sizes.append(try parseSize(try value(for: "--size")))
        case "--appearance": appearances += try parseAppearances(try value(for: "--appearance"))
        case "--render": fixture = try value(for: "--render")
        case _ where argument.hasPrefix("-"): throw CaveError("unknown option \(argument)", hint: usage)
        case _ where name == "render" && fixture == nil: fixture = argument
        default: throw CaveError("unexpected argument \(argument)", hint: usage)
        }
    }
    var options = fixture.map { RenderOptions(fixture: $0) }
    if !sizes.isEmpty { options?.sizes = sizes }
    if !appearances.isEmpty { options?.appearances = appearances }
    if options == nil, !sizes.isEmpty || !appearances.isEmpty {
        throw CaveError("--size and --appearance need a fixture to render", hint: usage)
    }
    switch name {
    case "up": return Invocation(command: .up, json: json)
    case "down": return Invocation(command: .down, json: json)
    case "status": return Invocation(command: .status, json: json)
    case "list": return Invocation(command: .list, json: json)
    case "guide": return Invocation(command: .guide, json: json)
    case "reload": return Invocation(command: .reload(render: options, full: full), json: json)
    case "render":
        guard let options else { throw CaveError("render needs a fixture name", hint: usage) }
        return Invocation(command: .render(options), json: json)
    default: throw CaveError("unknown command \(name)", hint: usage)
    }
}

public func parseSize(_ text: String) throws -> [Int] {
    let parts = text.lowercased().split(separator: "x", omittingEmptySubsequences: false)
    guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]),
          (1...8192).contains(width), (1...8192).contains(height) else {
        throw CaveError("invalid size \(text)", hint: "use WIDTHxHEIGHT in points, e.g. --size 900x600")
    }
    return [width, height]
}

public func parseAppearances(_ text: String) throws -> [String] {
    let appearances = text.split(separator: ",").map(String.init)
    guard !appearances.isEmpty, appearances.allSatisfy(["light", "dark"].contains) else {
        throw CaveError("invalid appearance \(text)", hint: "use light, dark or light,dark")
    }
    return appearances
}
