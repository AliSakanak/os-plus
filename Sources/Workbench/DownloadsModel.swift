import AppKit
import Foundation
import Observation
import WorkbenchCore

@MainActor
@Observable
final class DownloadsModel {
    private(set) var items: [DownloadItem] = []
    private(set) var duplicateIDs: Set<String> = []
    private(set) var folderSizes: [String: UInt64] = [:]
    private(set) var loadError: String?
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    var filter: DownloadsFilter = .all
    var search = ""
    var message: String?
    /// Items trashed by the last action, for Undo: (where it was, where it is in the Trash).
    private(set) var undoable: [(original: URL, trashed: URL)] = []
    var renamingID: String?

    let folder = DownloadsReader.defaultFolder()
    private var timer: Timer?
    private var isVisible = false

    // MARK: Derived

    var visibleItems: [DownloadItem] {
        var result: [DownloadItem]
        switch filter {
        case .duplicates: result = items.filter { duplicateIDs.contains($0.id) }
        default: result = DownloadsReader.filter(items, by: filter)
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                    || ($0.sourceHost?.localizedCaseInsensitiveContains(query) ?? false)
            }
        }
        return result
    }

    func size(of item: DownloadItem) -> UInt64? { item.size ?? folderSizes[item.id] }

    var visibleTotal: UInt64 { visibleItems.reduce(0) { $0 + (size(of: $1) ?? 0) } }

    func count(for filter: DownloadsFilter) -> Int {
        filter == .duplicates ? duplicateIDs.count : DownloadsReader.filter(items, by: filter).count
    }

    // MARK: Loading

    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        timer?.invalidate()
        timer = nil
        guard visible else { return }
        refresh()
        // New downloads appear within a few seconds while the tab is open.
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard !isLoading, renamingID == nil else { return }
        isLoading = true
        let folder = self.folder
        let knownSizes = folderSizes
        Task.detached(priority: .utility) {
            let result = Result { try DownloadsReader.list(folder: folder) }
            let items = (try? result.get()) ?? []
            let duplicates = Set(DownloadsReader.duplicates(in: items).map(\.id))
            var sizes = knownSizes
            for item in items where item.kind == .folder && sizes[item.id] == nil {
                sizes[item.id] = CacheScanner.size(of: item.url.path)
            }
            let error: String? = {
                if case .failure(let e) = result { return e.localizedDescription }
                return nil
            }()
            await MainActor.run {
                self.items = items
                self.duplicateIDs = duplicates
                self.folderSizes = sizes
                self.loadError = error
                self.isLoading = false
                self.hasLoaded = true
            }
        }
    }

    // MARK: Actions

    func open(_ item: DownloadItem) {
        NSWorkspace.shared.open(item.url)
    }

    func reveal(_ item: DownloadItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func openSource(_ item: DownloadItem) {
        if let url = item.sourceURL { NSWorkspace.shared.open(url) }
    }

    func copySource(_ item: DownloadItem) {
        guard let url = item.sourceURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        message = "Copied the link to where \(item.name) came from."
    }

    func rename(_ item: DownloadItem, to newName: String) {
        renamingID = nil
        do {
            let renamed = try DownloadsReader.rename(item.url, to: newName)
            if renamed != item.url { message = "Renamed to \(renamed.lastPathComponent)." }
        } catch {
            message = error.localizedDescription
        }
        refresh()
    }

    // MARK: Moving

    var quickDestinations: [URL] {
        let fm = FileManager.default
        let standard = [fm.urls(for: .documentDirectory, in: .userDomainMask)[0],
                        fm.urls(for: .desktopDirectory, in: .userDomainMask)[0]]
        let recent = (UserDefaults.standard.stringArray(forKey: "recentMoveDestinations") ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { fm.fileExists(atPath: $0.path) }
        var seen = Set<String>()
        return (recent + standard).filter { seen.insert($0.path).inserted }.prefix(6).map { $0 }
    }

    func move(_ item: DownloadItem, to folder: URL) {
        do {
            let moved = try DownloadsReader.move(item.url, into: folder)
            rememberDestination(folder)
            message = "Moved to \(folder.lastPathComponent): \(moved.lastPathComponent)."
        } catch {
            message = "Couldn't move \(item.name): \(error.localizedDescription)"
        }
        refresh()
    }

    func chooseFolderAndMove(_ item: DownloadItem) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Move Here"
        panel.message = "Choose where to move \"\(item.name)\""
        NSApp.activate()
        panel.begin { [weak self] response in
            guard response == .OK, let folder = panel.url else { return }
            Task { @MainActor in self?.move(item, to: folder) }
        }
    }

    private func rememberDestination(_ folder: URL) {
        var recent = UserDefaults.standard.stringArray(forKey: "recentMoveDestinations") ?? []
        recent.removeAll { $0 == folder.path }
        recent.insert(folder.path, at: 0)
        UserDefaults.standard.set(Array(recent.prefix(4)), forKey: "recentMoveDestinations")
    }

    // MARK: Trash (always undoable)

    func trash(_ items: [DownloadItem]) {
        var done: [(URL, URL)] = []
        var failures: [String] = []
        for item in items {
            var resulting: NSURL?
            do {
                try FileManager.default.trashItem(at: item.url, resultingItemURL: &resulting)
                if let trashed = resulting as URL? { done.append((item.url, trashed)) }
            } catch {
                failures.append(item.name)
            }
        }
        undoable = done
        let bytes = items.filter { i in done.contains { $0.0 == i.url } }.reduce(0) { $0 + (size(of: $1) ?? 0) }
        if done.count == 1, let only = items.first(where: { $0.url == done[0].0 }) {
            message = "Moved \(only.name) to the Trash."
        } else if !done.isEmpty {
            message = "Moved \(done.count) items (\(Format.bytes(bytes))) to the Trash."
        }
        if !failures.isEmpty {
            message = (message.map { $0 + " " } ?? "") + "Couldn't move: \(failures.joined(separator: ", "))."
        }
        refresh()
    }

    func undoTrash() {
        var restored = 0
        for (original, trashed) in undoable {
            guard !FileManager.default.fileExists(atPath: original.path) else { continue }
            if (try? FileManager.default.moveItem(at: trashed, to: original)) != nil { restored += 1 }
        }
        undoable = []
        message = restored == 1 ? "Put back 1 item." : "Put back \(restored) items."
        refresh()
    }

    func dismissMessage() {
        message = nil
        undoable = []
    }
}
