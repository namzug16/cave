import SwiftUI

@main
struct CaveDemoApp: App {
    var body: some Scene {
        WindowGroup {
            LibraryView(books: .samples, selection: 0)
        }
    }
}
