import AppKit

/// Keeps the last few captures in memory so closing the editor window without
/// saving/copying isn't a dead end — previously, an accidentally-closed
/// capture was just gone.
final class CaptureHistory {
    static let shared = CaptureHistory()

    struct Entry {
        let image: NSImage
        let date: Date
    }

    private(set) var entries: [Entry] = []
    private let maxEntries = 6

    private init() {}

    func record(_ image: NSImage) {
        entries.insert(Entry(image: image, date: Date()), at: 0)
        if entries.count > maxEntries { entries.removeLast(entries.count - maxEntries) }
    }

    func clear() { entries.removeAll() }
}
