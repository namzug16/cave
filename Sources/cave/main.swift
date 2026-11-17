import CaveCore
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
let json = arguments.contains("--json")

func emit(_ report: [String: Any]) {
    let data = (try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    print(String(decoding: data, as: UTF8.self))
}

if arguments.isEmpty || arguments == ["--help"] || arguments == ["-h"] {
    print(usage)
    exit(0)
}

do {
    let report = try execute(try parseCommand(arguments))
    if json { emit(report) } else { print(humanSummary(report)) }
} catch let error as CaveError {
    if json { emit(error.json) } else { FileHandle.standardError.write(Data((error.human + "\n").utf8)) }
    exit(1)
} catch {
    if json { emit(CaveError("\(error)").json) } else { FileHandle.standardError.write(Data("cave: \(error)\n".utf8)) }
    exit(1)
}
