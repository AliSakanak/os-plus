import AppKit
import Foundation
import Observation
import WorkbenchCore

@MainActor
@Observable
final class SpaceModel {
    private(set) var items: [SpaceItem] = []
    private(set) var nodeModules: [SpaceItem] = []
    private(set) var isScanning = false
    private(set) var scannedAt: Date?
    var message: String?

    /// Where to look for projects' node_modules folders.
    let projectRoots: [String] = {
        let home = NSHomeDirectory()
        return ["\(home)/Documents", "\(home)/Developer", "\(home)/Projects", "\(home)/code"]
            .filter { FileManager.default.fileExists(atPath: $0) }
    }()

    var totalReclaimable: UInt64 {
        (items + nodeModules).filter(\.canTrash).reduce(0) { $0 + $1.bytes }
    }

    func scanIfNeeded() {
        if let scannedAt, Date().timeIntervalSince(scannedAt) < 300 { return }
        scan()
    }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        message = nil
        let roots = projectRoots
        Task.detached(priority: .utility) {
            let locations = CacheScanner.knownLocations()
            var found: [SpaceItem] = []
            for loc in locations {
                guard let bytes = CacheScanner.size(of: loc.path), bytes > 1_000_000 else { continue }
                found.append(SpaceItem(name: loc.name, path: loc.path, bytes: bytes, safety: loc.safety))
            }
            var modules: [SpaceItem] = []
            for root in roots {
                for path in CacheScanner.findNodeModules(under: root) {
                    guard let bytes = CacheScanner.size(of: path), bytes > 5_000_000 else { continue }
                    modules.append(SpaceItem(
                        name: CacheScanner.nodeModulesLabel(path, root: root),
                        path: path, bytes: bytes,
                        safety: .safeToTrash(CacheScanner.installedNote(for: path))
                    ))
                }
            }
            let sortedItems = found.sorted { $0.bytes > $1.bytes }
            let sortedModules = modules.sorted { $0.bytes > $1.bytes }
            await MainActor.run {
                self.items = sortedItems
                self.nodeModules = sortedModules
                self.isScanning = false
                self.scannedAt = Date()
            }
        }
    }

    func reveal(_ item: SpaceItem) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
    }

    func moveToTrash(_ item: SpaceItem) {
        guard item.canTrash else { return }
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil)
            items.removeAll { $0.id == item.id }
            nodeModules.removeAll { $0.id == item.id }
            message = "Moved \(item.name) (\(Format.bytes(item.bytes))) to the Trash. Empty the Trash to free the space."
        } catch {
            message = "Couldn't move \(item.name) to the Trash: \(error.localizedDescription)"
        }
    }
}
