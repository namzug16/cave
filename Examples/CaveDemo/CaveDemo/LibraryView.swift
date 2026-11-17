import SwiftUI

struct Book: Identifiable, Hashable {
    let id: Int
    var title: String
    var author: String
    var rating: Int
    var isFavorite: Bool
}

extension [Book] {
    static let samples: [Book] = [
        Book(id: 0, title: "The Republic", author: "Plato", rating: 5, isFavorite: true),
        Book(id: 1, title: "Meditations", author: "Marcus Aurelius", rating: 4, isFavorite: false),
        Book(id: 2, title: "Nicomachean Ethics", author: "Aristotle", rating: 3, isFavorite: false),
    ]
}

struct LibraryView: View {
    @State var books: [Book]
    @State var selection: Book.ID?

    var body: some View {
        HStack(spacing: 0) {
            List(books, selection: $selection) { book in
                VStack(alignment: .leading, spacing: 2) {
                    Text(book.title).font(.headline)
                    Text(book.author).font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            .listStyle(.sidebar)
            .frame(width: 220)

            Divider()

            if let index = books.firstIndex(where: { $0.id == selection }) {
                BookDetail(book: $books[index])
            } else {
                ContentUnavailableView("No Book Selected", systemImage: "books.vertical")
            }
        }
    }
}

struct BookDetail: View {
    @Binding var book: Book

    var body: some View {
        Form {
            Section {
                LabeledContent("Title", value: book.title)
                LabeledContent("Author", value: book.author)
                LabeledContent("Rating") {
                    HStack(spacing: 2) {
                        ForEach(1...5, id: \.self) { star in
                            Image(systemName: star <= book.rating ? "star.fill" : "star")
                                .foregroundStyle(star <= book.rating ? .yellow : .secondary)
                        }
                    }
                }
                Toggle("Favorite", isOn: $book.isFavorite)
            }
            Section {
                Button("Mark as Read") {}
                    .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomTrailing) { ReadingActions().padding() }
    }
}

struct ReadingActions: View {
    var body: some View {
        if #available(macOS 26, *) {
            HStack(spacing: 8) {
                Button {} label: { Image(systemName: "square.and.arrow.up").frame(width: 32, height: 32) }
                    .buttonStyle(.plain)
                    .glassEffect(in: RoundedRectangle(cornerRadius: 12))
                Text("Reading")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .glassEffect(.regular.tint(.blue), in: Capsule())
            }
        }
    }
}
