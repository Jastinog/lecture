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

    init(id: Int, name: String, photoURL: URL?, pinnedAt: Double) {
        self.id = id
        self.name = name
        self.photoURL = photoURL
        self.pinnedAt = pinnedAt
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
        SyncEngine.shared.record(PinRecord(pin), in: \.pins)
    }

    func unpin(id: Int) {
        items.removeAll { $0.id == id }
        persist()
        SyncEngine.shared.remove([id], in: \.pins, as: PinRecord.init(removing:at:))
    }

    /// Lecturers pinned or unpinned on the listener's other devices; not
    /// synced back.
    func apply(saved: [PinnedLecturer], removed: Set<Int>) {
        guard !saved.isEmpty || !removed.isEmpty else { return }
        let replaced = removed.union(saved.map(\.id))
        items = (items.filter { !replaced.contains($0.id) } + saved).sorted { $0.pinnedAt > $1.pinnedAt }
        persist()
    }

    func toggle(_ lecturer: Lecturer) {
        if isPinned(lecturer.id) { unpin(id: lecturer.id) } else { pin(lecturer) }
    }

    private func persist() { Store.save(items, version: version, to: file) }
}
