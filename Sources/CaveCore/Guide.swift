import Foundation

/// Where `make install`, Homebrew and install.sh put CaveKit.swift: `share/cave` next to the `bin` holding cave.
var installedKit: String {
    let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
    let path = executable.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("share/cave/CaveKit.swift").path
    return FileManager.default.fileExists(atPath: path) ? "Installed copy: \(path)" : "Not installed: brew install namzug16/tap/cave, or run make install in the cave repository"
}

public var agentGuide: String {
    """
    cave renders a macOS app's real SwiftUI screens to PNG, with fixture data, through a hidden render
    host: the app's own Debug build. Pass --json to every command and read the PNGs it lists.

    START HERE
      cave status --json      says whether the host runs, which files it doesn't have yet, the
                              fixtures, and in "next" the exact command to run now.

    THE LOOP
      1. cave up --json                       build the app and start the host (several seconds)
      2. cave list --json                     fixtures you can render
      3. cave render <fixture> --size 900x600 --appearance light,dark --json
                                              then read every renders[].path PNG
      4. edit the Swift view
      5. cave reload --render <fixture> --size 900x600 --appearance light,dark --json
                                              patches the edit into the host and renders (~2 s)
      Repeat 4-5. Add more --size flags to check several window sizes in one call.

    FIXTURES
      Fixtures live in the file cave.json names under "fixtures":
        func caveFixtures(_ registry: CaveRegistry) {
            registry.add("library.empty") { LibraryView(books: [], selection: nil) }
        }
      To check a new screen or state, add a registry.add line there, then cave reload.

    READING RESULTS
      ok: false             errors[] (file/line/column for compile errors) plus a hint: follow it.
      stale_files           edits the render does not show, because no fixture or patched view names
                            their types: also edit the parent view that embeds them, or use --full.
      changed_since_reload  files newer than the code in the host: run cave reload.
      host_log_tail         the host crashed (fatalError, failed precondition in a view). Fix the
                            code and reload; the host restarts on its own.
      A patch that fails to compile while the code builds in Xcode (e.g. new stored properties)
      needs cave reload --full. So does any edit to CaveKit.swift.

    SETTING UP A NEW APP
      1. Add CaveKit.swift to the macOS app target unchanged. \(installedKit)
      2. Add a fixtures file defining caveFixtures(_:) as above.
      3. In the App struct: init() { CaveHost.runIfRequested(caveFixtures) }
      4. At the repository root, cave.json:
         {"project": "App.xcodeproj", "scheme": "App", "fixtures": "App/CaveFixtures.swift"}
      Then: cave up --json

    LIMITS
      Content only: no titlebar or toolbar. Glass renders, but tinted glass looks gray, as in a
      background window. The host runs outside the app sandbox, with its home
      folder in .cave/home. Add .cave/ to the app repository's .gitignore.
    """
}
