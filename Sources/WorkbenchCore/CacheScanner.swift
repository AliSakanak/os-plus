import Foundation

/// A folder that's taking space, with whether it's safe to move to the Trash.
public struct SpaceItem: Sendable, Equatable, Identifiable {
    public enum Safety: Sendable, Equatable {
        /// Rebuilt automatically or re-downloaded on demand.
        case safeToTrash(String)
        /// Shown for information only: you decide in Finder.
        case reviewYourself(String)
    }

    public var name: String
    public var path: String
    public var bytes: UInt64
    public var safety: Safety
    public var id: String { path }

    public init(name: String, path: String, bytes: UInt64, safety: Safety) {
        self.name = name
        self.path = path
        self.bytes = bytes
        self.safety = safety
    }

    public var canTrash: Bool {
        if case .safeToTrash = safety { return true }
        return false
    }

    public var note: String {
        switch safety {
        case .safeToTrash(let s), .reviewYourself(let s): s
        }
    }
}

public struct SpaceLocation: Sendable {
    public var name: String
    public var path: String
    public var safety: SpaceItem.Safety

    public init(_ name: String, _ path: String, _ safety: SpaceItem.Safety) {
        self.name = name
        self.path = path
        self.safety = safety
    }
}

public enum CacheScanner {
    public static func knownLocations(home: String = NSHomeDirectory()) -> [SpaceLocation] {
        [
            SpaceLocation("Xcode build files", "\(home)/Library/Developer/Xcode/DerivedData",
                          .safeToTrash("Xcode rebuilds these the next time you build.")),
            SpaceLocation("Xcode device support", "\(home)/Library/Developer/Xcode/iOS DeviceSupport",
                          .safeToTrash("Re-downloaded when you plug in a device.")),
            SpaceLocation("npm cache", "\(home)/.npm/_cacache", .safeToTrash("npm re-downloads packages as needed.")),
            SpaceLocation("pnpm store", "\(home)/Library/pnpm/store", .safeToTrash("pnpm re-downloads packages as needed.")),
            SpaceLocation("Bun cache", "\(home)/.bun/install/cache", .safeToTrash("Bun re-downloads packages as needed.")),
            SpaceLocation("Homebrew downloads", "\(home)/Library/Caches/Homebrew",
                          .safeToTrash("Old installer downloads. Homebrew re-fetches if needed.")),
            SpaceLocation("pip cache", "\(home)/Library/Caches/pip", .safeToTrash("pip re-downloads packages as needed.")),
            SpaceLocation("Yarn cache", "\(home)/Library/Caches/Yarn", .safeToTrash("Yarn re-downloads packages as needed.")),
            SpaceLocation("Gradle cache", "\(home)/.gradle/caches", .safeToTrash("Gradle re-downloads as needed.")),
            SpaceLocation("Downloads", "\(home)/Downloads", .reviewYourself("Your files. Review them in Finder.")),
            SpaceLocation("Trash", "\(home)/.Trash", .reviewYourself("Empty it from the Dock when you're sure.")),
        ]
    }

    /// Total allocated size of a folder. Unreadable entries are skipped. Returns nil if the folder doesn't exist.
    public static func size(of path: String, isCancelled: @Sendable () -> Bool = { false }) -> UInt64? {
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard isDir.boolValue else {
            return (try? url.resourceValues(forKeys: Set(keys)))?.totalFileAllocatedSize.map(UInt64.init)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }
        ) else { return nil }

        var total: UInt64 = 0
        var counter = 0
        for case let file as URL in enumerator {
            counter += 1
            if counter % 5_000 == 0, isCancelled() { break }
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += UInt64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Finds `node_modules` folders under `root` (not nested inside other node_modules), up to `maxDepth` levels deep.
    public static func findNodeModules(under root: String, maxDepth: Int = 5) -> [String] {
        var found: [String] = []
        let skip: Set<String> = [".git", "build", "dist", ".next", "Pods", ".venv", "venv", "target", "Library"]
        func walk(_ path: String, depth: Int) {
            guard depth <= maxDepth,
                  let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else { return }
            for entry in entries {
                let child = path + "/" + entry
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: child, isDirectory: &isDir), isDir.boolValue else { continue }
                // Don't follow symlinks.
                if let attrs = try? FileManager.default.attributesOfItem(atPath: child),
                   attrs[.type] as? FileAttributeType == .typeSymbolicLink { continue }
                if entry == "node_modules" {
                    found.append(child)
                } else if !skip.contains(entry), !entry.hasPrefix(".") {
                    walk(child, depth: depth + 1)
                }
            }
        }
        walk(root, depth: 0)
        return found
    }

    /// "Installed 8 months ago", from the node_modules folder's modification date.
    public static func installedNote(for path: String, now: Date = Date()) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attrs[.modificationDate] as? Date else { return "Reinstall to get it back." }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let relative = formatter.localizedString(for: modified, relativeTo: now)
        let stale = now.timeIntervalSince(modified) > 90 * 86_400
        return "Installed \(relative)" + (stale ? ". Probably not in use." : ".")
    }

    /// The label for a node_modules folder: the project folder that holds it.
    public static func nodeModulesLabel(_ path: String, root: String) -> String {
        let project = (path as NSString).deletingLastPathComponent
        var relative = project.hasPrefix(root) ? String(project.dropFirst(root.count)) : project
        if relative.hasPrefix("/") { relative.removeFirst() }
        return relative.isEmpty ? (project as NSString).lastPathComponent : relative
    }
}
