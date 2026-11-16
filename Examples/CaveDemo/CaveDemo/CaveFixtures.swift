import SwiftUI

func caveFixtures(_ registry: CaveRegistry) {
    registry.add("library.populated") { LibraryView(books: .samples, selection: 1) }
}
