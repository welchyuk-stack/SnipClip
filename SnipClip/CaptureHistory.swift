import AppKit

/// The last few captures, persisted to Application Support so an
/// accidentally-closed capture (or a relaunch) isn't a dead end.
/// Images are PNGs on disk and lazily loaded; annotations are in-memory only.
final class CaptureHistory {
    static let shared = CaptureHistory()

    final class Entry {
        let id: UUID
        let date: Date
        let pixelSize: NSSize
        let pointSize: NSSize
        fileprivate var cachedImage: NSImage?
        fileprivate let fileURL: URL
        var items: [MarkupItem] = []
        var cropRect: NSRect?

        fileprivate init(id: UUID, date: Date, pixelSize: NSSize, pointSize: NSSize, image: NSImage?, fileURL: URL) {
            self.id = id; self.date = date; self.pixelSize = pixelSize
            self.pointSize = pointSize; self.cachedImage = image; self.fileURL = fileURL
        }

        /// Lazily loaded from disk, sized in points (not the PNG's 72-dpi pixel size).
        var image: NSImage? {
            get {
                if let cachedImage { return cachedImage }
                guard let loaded = NSImage(contentsOf: fileURL) else { return nil }
                if pointSize.width > 0, pointSize.height > 0 { loaded.size = pointSize }
                cachedImage = loaded
                return loaded
            }
            set { cachedImage = newValue }
        }
    }

    private struct IndexRecord: Codable {
        let id: UUID
        let date: Date
        let pixelWidth: Double
        let pixelHeight: Double
        let pointWidth: Double
        let pointHeight: Double
    }

    private(set) var entries: [Entry] = []
    private let maxEntries = 10
    private var pressureSource: DispatchSourceMemoryPressure?
    private let ioQueue = DispatchQueue(label: "com.snipclip.history-io", qos: .utility)
    private let directory: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        directory = base.appendingPathComponent("SnipClip/Recent", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()

        // Under memory pressure, drop in-memory images (they reload lazily
        // from disk) rather than discarding the history itself.
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            self?.entries.forEach { $0.cachedImage = nil }
        }
        source.resume()
        pressureSource = source
    }

    /// Drops decoded images (they reload lazily from disk) and returns freed
    /// heap pages to the system. Full-resolution captures can push the heap
    /// to hundreds of MB, and macOS otherwise keeps those pages attributed
    /// to us long after the editor has closed.
    func trimMemory() {
        entries.forEach { $0.cachedImage = nil }
        malloc_zone_pressure_relief(nil, 0)
    }

    private var indexURL: URL { directory.appendingPathComponent("index.json") }
    private func fileURL(for id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).png") }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let records = try? JSONDecoder().decode([IndexRecord].self, from: data) else { return }
        entries = records.compactMap { r in
            let url = fileURL(for: r.id)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return Entry(id: r.id, date: r.date,
                         pixelSize: NSSize(width: r.pixelWidth, height: r.pixelHeight),
                         pointSize: NSSize(width: r.pointWidth, height: r.pointHeight),
                         image: nil, fileURL: url)
        }
        entries = Array(entries.prefix(maxEntries))
    }

    @discardableResult
    func record(_ image: NSImage) -> Entry {
        let id = UUID()
        let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        let pixelSize = cg.map { NSSize(width: $0.width, height: $0.height) } ?? image.size
        let url = fileURL(for: id)
        let entry = Entry(id: id, date: Date(), pixelSize: pixelSize, pointSize: image.size,
                          image: image, fileURL: url)
        entries.insert(entry, at: 0)
        var removed: [Entry] = []
        if entries.count > maxEntries {
            removed = Array(entries[maxEntries...])
            entries.removeLast(entries.count - maxEntries)
        }
        let removedURLs = removed.map { $0.fileURL }
        let index = indexRecords()
        ioQueue.async {
            if let cg {
                let rep = NSBitmapImageRep(cgImage: cg)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: url, options: .atomic)
                }
            }
            removedURLs.forEach { try? FileManager.default.removeItem(at: $0) }
            self.writeIndex(index)
        }
        return entry
    }

    func remove(_ entry: Entry) {
        entries.removeAll { $0 === entry }
        let url = entry.fileURL
        let index = indexRecords()
        ioQueue.async {
            try? FileManager.default.removeItem(at: url)
            self.writeIndex(index)
        }
    }

    func clear() {
        let urls = entries.map { $0.fileURL }
        entries.removeAll()
        ioQueue.async {
            urls.forEach { try? FileManager.default.removeItem(at: $0) }
            self.writeIndex([])
        }
    }

    private func indexRecords() -> [IndexRecord] {
        entries.map {
            IndexRecord(id: $0.id, date: $0.date,
                        pixelWidth: Double($0.pixelSize.width), pixelHeight: Double($0.pixelSize.height),
                        pointWidth: Double($0.pointSize.width), pointHeight: Double($0.pointSize.height))
        }
    }

    private func writeIndex(_ records: [IndexRecord]) {
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }
}
