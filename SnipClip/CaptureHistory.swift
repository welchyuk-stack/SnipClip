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
    private var pressureSource: DispatchSourceMemoryPressure?

    private init() {
        // Evict cached screenshots under memory pressure so full-resolution
        // NSImages (up to ~40 MB each) don't contribute to an OOM situation.
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in self?.clear() }
        source.resume()
        pressureSource = source
    }

    func record(_ image: NSImage) {
        entries.insert(Entry(image: image, date: Date()), at: 0)
        if entries.count > maxEntries { entries.removeLast(entries.count - maxEntries) }
    }

    func clear() { entries.removeAll() }
}
