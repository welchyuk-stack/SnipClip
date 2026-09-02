import AppKit

/// Persists the user's chosen output folder for screen recordings.
/// Sandboxed apps only get access to folders a user explicitly picked
/// through a panel, and only for that run — a security-scoped bookmark is
/// what lets that access survive relaunches.
final class RecordingFolderManager {
    static let shared = RecordingFolderManager()

    private let defaultsKey = "snipclip_recording_folder_bookmark"

    private init() {}

    /// Nil until the user has picked a folder at least once.
    var folderURL: URL? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                  relativeTo: nil, bookmarkDataIsStale: &isStale) else { return nil }
        if isStale { saveBookmark(for: url) }
        return url
    }

    var displayPath: String {
        folderURL?.path ?? "Not set — choose a folder"
    }

    /// Presents a folder picker. Calls back with the chosen URL, or nil if the
    /// user cancelled.
    func choose(completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Choose Recordings Folder"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if let current = folderURL { panel.directoryURL = current }

        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { completion(nil); return }
            self.saveBookmark(for: url)
            completion(url)
        }
    }

    @discardableResult
    private func saveBookmark(for url: URL) -> Bool {
        guard let data = try? url.bookmarkData(options: .withSecurityScope,
                                                includingResourceValuesForKeys: nil,
                                                relativeTo: nil) else { return false }
        UserDefaults.standard.set(data, forKey: defaultsKey)
        return true
    }
}
