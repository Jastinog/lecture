import SwiftUI

/// A pinned lecturer, kept on the phone so the listener can jump straight back
/// to the people they follow. Newest first.
struct PinnedLecturer: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    var photoURL: URL?
    /// Epoch seconds, stamped by `PinStore.pin`.
    var pinnedAt: Double = 0

    init(_ lecturer: Lecturer) {
        id = lecturer.id
        name = lecturer.name
        photoURL = lecturer.photoURL
    }

    var ref: LecturerRef { LecturerRef(id: id, name: name) }
}

/// Local store of pinned lecturers.
@MainActor
final class PinStore: ObservableObject {
    static let shared = PinStore()
    private let file = "pins.json"
    private let version = 1

    @Published private(set) var items: [PinnedLecturer] = [] {
        didSet { ids = Set(items.map(\.id)) }
    }
    private var ids: Set<Int> = []

    private init() {
        let loaded = Store.load([PinnedLecturer].self, from: file) ?? []
        items = loaded
        ids = Set(loaded.map(\.id))
    }

    func isPinned(_ id: Int) -> Bool { ids.contains(id) }

    /// Pins the lecturer (or refreshes the pin) and moves it to the top.
    func pin(_ lecturer: Lecturer) {
        var pin = PinnedLecturer(lecturer)
        pin.pinnedAt = Date().timeIntervalSince1970
        items.removeAll { $0.id == pin.id }
        items.insert(pin, at: 0)
        persist()
    }

    func unpin(id: Int) {
        items.removeAll { $0.id == id }
        persist()
    }

    func toggle(_ lecturer: Lecturer) {
        if isPinned(lecturer.id) { unpin(id: lecturer.id) } else { pin(lecturer) }
    }

    private func persist() { Store.save(items, version: version, to: file) }
}
