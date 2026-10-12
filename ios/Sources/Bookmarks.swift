import SwiftUI

/// A saved moment in a topic, with an optional note.
struct Bookmark: Codable, Identifiable, Hashable {
    var id = UUID()
    let topicID: Int
    let index: Int            // chapter
    let time: Double          // seconds into the chapter
    let chapterTitle: String
    var note: String = ""
    var createdAt: Double = Date().timeIntervalSince1970

    /// "Lecture 3 · 12:30".
    var positionLabel: String { "Lecture \(index + 1) · \(formatTime(time))" }
}

/// Persisted bookmarks for all topics.
@MainActor
final class BookmarkStore: ObservableObject {
    static let shared = BookmarkStore()
    private let file = "bookmarks.json"
    private let version = 1

    @Published private(set) var items: [Bookmark] = []

    private init() { items = Store.load([Bookmark].self, from: file) ?? [] }

    /// A topic's bookmarks in listening order.
    func bookmarks(for topicID: Int) -> [Bookmark] {
        items.filter { $0.topicID == topicID }
            .sorted { ($0.index, $0.time) < ($1.index, $1.time) }
    }

    func add(_ bookmark: Bookmark) {
        items.append(bookmark)
        persist()
    }

    func updateNote(id: UUID, _ note: String) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].note != note else { return }
        items[i].note = note
        persist()
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        persist()
    }

    private func persist() { Store.save(items, version: version, to: file) }
}

/// The current topic's bookmarks, pushed from Now Playing: a grouped table, one
/// row a bookmark — the chapter, the moment in blue, the note under it. Tapping
/// a row jumps there and returns to the player; the blue detail button opens
/// the note; a swipe deletes.
struct BookmarksView: View {
    @EnvironmentObject private var player: AudioPlayer
    @ObservedObject private var store = BookmarkStore.shared
    let onDone: () -> Void
    let onEdit: (UUID) -> Void

    var body: some View {
        let marks = player.topic.map { store.bookmarks(for: $0.id) } ?? []
        GroupedList {
            if !marks.isEmpty {
                GroupedSection {
                    ForEach(marks) { mark in
                        HStack(spacing: 8) {
                            RowButton(action: {
                                player.jump(index: mark.index, time: mark.time)
                                onDone()
                            }) {
                                BookmarkLabel(mark: mark)
                            }
                            DetailButton { onEdit(mark.id) }
                                .accessibilityLabel("Edit Note")
                        }
                        .classicSwipeButton(id: mark.id) { store.remove(id: mark.id) }
                    }
                }
            }
        }
        .overlay {
            if marks.isEmpty {
                ClassicEmptyState("No Bookmarks",
                                  message: "Tap “Bookmark” in the player to save a moment",
                                  onPinstripe: true)
            }
        }
        .classicSwipeList()
        .navigationTitle("Bookmarks")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A bookmark row's text: the chapter and its moment on one line, the note
/// under them.
private struct BookmarkLabel: View {
    let mark: Bookmark

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(mark.chapterTitle)
                    .font(.groupedLabel)
                    .rowForeground(Palette.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(formatTime(mark.time))
                    .font(.groupedValue.monospacedDigit())
                    .rowForeground(Palette.accent)
            }
            if !mark.note.isEmpty {
                Text(mark.note)
                    .font(.rowDetail)
                    .rowForeground(Palette.secondaryText)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 6)
    }
}

/// UIKit's blue detail-disclosure button, for a row's second action.
struct DetailButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) { EmptyView() }
            .buttonStyle(Style())
    }

    private struct Style: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            Image.classic(configuration.isPressed ? "DetailButtonPressed" : "DetailButton")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
    }
}

/// Note editor for one bookmark. Saves when leaving the screen; "Delete Bookmark" removes
/// the bookmark.
struct BookmarkEditView: View {
    let id: UUID
    @ObservedObject private var store = BookmarkStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @FocusState private var focused: Bool

    var body: some View {
        let mark = store.items.first { $0.id == id }
        GroupedList {
            if let mark {
                GroupedSection("\(mark.positionLabel) — \(mark.chapterTitle)") {
                    TextField("Note", text: $note, axis: .vertical)
                        .font(.groupedValue)
                        .lineLimit(3...10)
                        .focused($focused)
                        .padding(.vertical, 11)
                }
                Button("Delete Bookmark") {
                    store.remove(id: id)
                    dismiss()
                }
                .buttonStyle(ClassicDeleteButtonStyle())
            }
        }
        .navigationTitle("Note")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            note = mark?.note ?? ""
            focused = true
        }
        // One write on the way out, not one per keystroke.
        .onDisappear { store.updateNote(id: id, note) }
    }
}
