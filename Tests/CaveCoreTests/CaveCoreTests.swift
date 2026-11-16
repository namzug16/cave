import Testing
@testable import CaveCore

@Test func parsesRenderWithSizesAndAppearances() throws {
    let invocation = try parseInvocation(["render", "library.populated", "--size", "900x600", "--size", "1280x800", "--appearance", "light,dark", "--json"])
    #expect(invocation.json)
    #expect(invocation.command == .render(RenderOptions(fixture: "library.populated", sizes: [[900, 600], [1280, 800]], appearances: ["light", "dark"])))
}

@Test func parsesReloadWithRenderDefaults() throws {
    let invocation = try parseInvocation(["reload", "--render", "library.populated"])
    #expect(invocation.command == .reload(render: RenderOptions(fixture: "library.populated"), full: false))
}

@Test func rejectsBadInput() {
    #expect(throws: CaveError.self) { try parseSize("900") }
    #expect(throws: CaveError.self) { try parseSize("0x600") }
    #expect(throws: CaveError.self) { try parseAppearances("light,sepia") }
    #expect(throws: CaveError.self) { try parseInvocation(["render"]) }
    #expect(throws: CaveError.self) { try parseInvocation(["reload", "--size", "900x600"]) }
    #expect(throws: CaveError.self) { try parseInvocation(["render", "a", "b"]) }
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
