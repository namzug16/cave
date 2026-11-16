import SwiftUI

@main
struct CaveDemoApp: App {
    init() {
        CaveHost.runIfRequested(caveFixtures)
    }

    var body: some Scene {
        WindowGroup {
            LibraryView(books: .samples, selection: 0)
        }
    }
}
