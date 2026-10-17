import AppKit

/// Persists a user-chosen output folder (one for recordings, one for
/// screenshots). Sandboxed apps only get access to folders a user explicitly
/// picked through a panel, and only for that run — a security-scoped
/// bookmark is what lets that access survive relaunches.
final class RecordingFolderManager {
    static let shared = RecordingFolderManager(defaultsKey: "snipclip_recording_folder_bookmark",
                                               panelTitle: "Choose Recordings Folder")
    static let screenshots = RecordingFolderManager(defaultsKey: "snipclip_screenshot_folder_bookmark",
                                                    panelTitle: "Choose Screenshots Folder")

    private let defaultsKey: String
    private let panelTitle: String

    private init(defaultsKey: String, panelTitle: String) {
        self.defaultsKey = defaultsKey
        self.panelTitle = panelTitle
    }

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
        guard let path = folderURL?.path else { return "Not set — choose a folder" }
        // NSHomeDirectory() is the sandbox container, so resolve the real home.
        guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else { return path }
        let home = String(cString: dir)
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// Presents a folder picker. Calls back with the chosen URL, or nil if the
    /// user cancelled.
    func choose(completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.title = panelTitle
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if let current = folderURL { panel.directoryURL = current }

        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { completion(nil); return }
            if !self.saveBookmark(for: url) {
                AppAlert.show(title: "Couldn't Remember This Folder",
                              message: "SnipClip can use \(url.lastPathComponent) for now, but won't be able to access it after you quit. Try choosing the folder again, or pick a different one.")
            }
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
