import Foundation
import Testing
@testable import CaveCore

@Test func parsesRenderWithSizesAndAppearances() throws {
    let command = try parseCommand(["render", "library.populated", "--size", "900x600", "--size", "1280x800", "--appearance", "light,dark", "--json"])
    #expect(command == .render(RenderOptions(fixture: "library.populated", sizes: [[900, 600], [1280, 800]], appearances: ["light", "dark"])))
}

@Test func parsesReloadWithRenderDefaults() throws {
    #expect(try parseCommand(["reload", "--render", "library.populated"]) == .reload(render: RenderOptions(fixture: "library.populated"), full: false))
}

@Test func rejectsBadInput() {
    #expect(throws: CaveError.self) { try parseSize("900") }
    #expect(throws: CaveError.self) { try parseSize("0x600") }
    #expect(throws: CaveError.self) { try parseAppearances("light,sepia") }
    #expect(throws: CaveError.self) { try parseCommand(["render"]) }
    #expect(throws: CaveError.self) { try parseCommand(["reload", "--size", "900x600"]) }
    #expect(throws: CaveError.self) { try parseCommand(["render", "a", "b"]) }
}

@Test func parsesCompilerErrorsOnly() {
    let output = """
        /src/LibraryView.swift:12:5: error: cannot find 'Foo' in scope
        /src/LibraryView.swift:14:1: warning: unused
        /src/LibraryView.swift:12:5: error: cannot find 'Foo' in scope
        note: something
        """
    #expect(parseDiagnostics(output) == [Diagnostic(file: "/src/LibraryView.swift", line: 12, column: 5, message: "cannot find 'Foo' in scope")])
}

@Test func findsDeclaredTypes() {
    let source = """
        struct Book {}
        @MainActor final class Store {}
        extension Book {}
            enum Nested {}
        private struct Hidden: View {}
        """
    #expect(declaredTypes(in: source) == ["Book", "Store", "Nested", "Hidden"])
}

@Test func flagsEditsOnlyReachedThroughUneditedViews() {
    let fixtures = #"registry.add("x") { LibraryView() }"#
    let edited = [
        "/LibraryView.swift": "struct LibraryView: View { var body: some View { BookDetail() } }",
        "/BookDetail.swift": "struct BookDetail: View {}",
        "/Settings.swift": "struct SettingsView: View {}",
        "/Helpers.swift": "extension View { func card() -> some View { self } }",
    ]
    #expect(unreachedFiles(edited: edited, fixturesSource: fixtures) == ["/Helpers.swift", "/Settings.swift"])
}

@Test func namesUpcomingFeatures() {
    let settings = ["SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY": "YES", "SWIFT_UPCOMING_FEATURE_EXISTENTIAL_ANY": "NO"]
    #expect(upcomingFeatures(settings) == ["MemberImportVisibility"])
}

@Test func parsesAgentCommands() throws {
    #expect(try parseCommand(["status", "--json"]) == .status)
    #expect(try parseCommand(["list"]) == .list)
    #expect(try parseCommand(["guide"]) == .guide)
}

@Test func suggestsTheNextCommand() {
    #expect(nextCommand(hasBuild: false, needsFullBuild: false, changed: [], fixture: nil) == "cave up --json")
    #expect(nextCommand(hasBuild: true, needsFullBuild: true, changed: ["/CaveKit.swift"], fixture: "a") == "cave reload --full --render a --json")
    #expect(nextCommand(hasBuild: true, needsFullBuild: false, changed: ["/View.swift"], fixture: "a") == "cave reload --render a --json")
    #expect(nextCommand(hasBuild: true, needsFullBuild: false, changed: [], fixture: nil) == "cave render <fixture> --json")
}

@Test func findsSwiftFilesAddedOrRemovedSinceTheBuild() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let buildStartedAt = Date()
    func file(_ name: String, modified: Date) throws -> String {
        let path = directory.appendingPathComponent(name).path
        try "".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path)
        return path
    }
    let kept = try file("Kept.swift", modified: buildStartedAt - 60)
    _ = try file("ExcludedOnPurpose.swift", modified: buildStartedAt - 60)
    let added = try file("Added.swift", modified: buildStartedAt + 60)
    let removed = directory.appendingPathComponent("Removed.swift").path
    let list = directory.appendingPathComponent("files.list").path
    try [kept, removed].joined(separator: "\n").write(toFile: list, atomically: true, encoding: .utf8)
    let state = State(buildStartedAt: buildStartedAt,
                      buildSettings: ["NATIVE_ARCH_ACTUAL": "arm64", "SWIFT_RESPONSE_FILE_PATH_normal_arm64": list],
                      hostExecutable: "")
    let workspace = Workspace(root: directory, config: Config(project: "", scheme: "", fixtures: ""))
    #expect(try workspace.sourcesAddedOrRemoved(state) == [removed, added])
}

@Test func mapsPatchErrorsBackToTheUsersFiles() {
    let copies = ["/patches/CavePatch3/0_LibraryView.swift": "/app/LibraryView.swift"]
    let errors = [
        Diagnostic(file: "/patches/CavePatch3/0_LibraryView.swift", line: 1, column: 30, message: "first line"),
        Diagnostic(file: "/patches/CavePatch3/0_LibraryView.swift", line: 12, column: 5, message: "later line"),
        Diagnostic(file: "/patches/CavePatch3/cave_entry.swift", line: 4, column: 9, message: "generated file"),
    ]
    #expect(mapDiagnostics(errors, copies: copies, prefixLength: 26) == [
        Diagnostic(file: "/app/LibraryView.swift", line: 1, column: 4, message: "first line"),
        Diagnostic(file: "/app/LibraryView.swift", line: 12, column: 5, message: "later line"),
        Diagnostic(file: "/patches/CavePatch3/cave_entry.swift", line: 4, column: 9, message: "generated file"),
    ])
}
