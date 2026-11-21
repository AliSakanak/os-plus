import Darwin
import Foundation
import UniformTypeIdentifiers

public struct DownloadItem: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case folder, image, pdf, document, spreadsheet, presentation, archive, installer, video, audio, code, other

        public var symbol: String {
            switch self {
            case .folder: "folder"
            case .image: "photo"
            case .pdf: "doc.richtext"
            case .document: "doc.text"
            case .spreadsheet: "tablecells"
            case .presentation: "rectangle.on.rectangle"
            case .archive: "doc.zipper"
            case .installer: "shippingbox"
            case .video: "film"
            case .audio: "waveform"
            case .code: "chevron.left.forwardslash.chevron.right"
            case .other: "doc"
            }
        }
    }

    public var url: URL
    public var name: String
    public var kind: Kind
    /// Bytes on disk. For folders this is filled in later (it can be slow to measure).
    public var size: UInt64?
    /// When it landed in Downloads (falls back to creation date).
    public var dateAdded: Date
    /// Where it came from: [download URL, page URL] as recorded by the browser.
    public var whereFrom: [String]

    public var id: String { url.path }

    public init(url: URL, name: String, kind: Kind, size: UInt64?, dateAdded: Date, whereFrom: [String]) {
        self.url = url
        self.name = name
        self.kind = kind
        self.size = size
        self.dateAdded = dateAdded
        self.whereFrom = whereFrom
    }

    /// "github.com" — prefers the page you were on over the CDN that served the file.
    public var sourceHost: String? { DownloadsReader.sourceHost(whereFrom) }

    /// The page to reopen to get this file again.
    public var sourceURL: URL? {
        (whereFrom.count > 1 ? whereFrom[1] : whereFrom.first).flatMap(URL.init(string:))
    }

    public func age(now: Date = Date()) -> TimeInterval { now.timeIntervalSince(dateAdded) }
}

public enum DownloadsFilter: String, CaseIterable, Sendable, Identifiable {
    case all = "All"
    case old = "Older than 30 days"
    case installers = "Installers"
    case duplicates = "Duplicates"
    public var id: String { rawValue }

    public var shortLabel: String {
        switch self {
        case .all: "All"
        case .old: "Old"
        case .installers: "Installers"
        case .duplicates: "Duplicates"
        }
    }

    public var explanation: String {
        switch self {
        case .all: "Newest first."
        case .old: "Added more than 30 days ago. Usually safe to bin once you've checked."
        case .installers: "Disk images and packages. Once the app is installed you don't need these."
        case .duplicates: "Files like \"report (1).pdf\" that are the same size as the original, so they're very likely identical copies."
        }
    }
}

public enum DownloadsReader {
    public static func defaultFolder() -> URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    /// Top-level items in the folder, newest first. Hidden files are skipped.
    public static func list(folder: URL = defaultFolder()) throws -> [DownloadItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
                                      .addedToDirectoryDateKey, .creationDateKey, .contentTypeKey]
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                               options: [.skipsHiddenFiles])
        return urls.compactMap { url -> DownloadItem? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let isFolder = values.isDirectory == true && values.isPackage != true
            let size: UInt64? = isFolder ? nil
                : UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            let added = values.addedToDirectoryDate ?? values.creationDate ?? .distantPast
            return DownloadItem(
                url: url, name: url.lastPathComponent,
                kind: isFolder ? .folder : kind(for: url, type: values.contentType),
                size: size, dateAdded: added, whereFrom: whereFrom(path: url.path)
            )
        }
        .sorted { $0.dateAdded > $1.dateAdded }
    }

    // MARK: Metadata

    /// Reads the `com.apple.metadata:kMDItemWhereFroms` extended attribute that browsers set.
    public static func whereFrom(path: String) -> [String] {
        let name = "com.apple.metadata:kMDItemWhereFroms"
        let length = getxattr(path, name, nil, 0, 0, 0)
        guard length > 0 else { return [] }
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, length, 0, 0) }
        guard read == length else { return [] }
        return parseWhereFrom(data)
    }

    /// The attribute is a binary plist holding an array of strings (sometimes with empty entries).
    public static func parseWhereFrom(_ data: Data) -> [String] {
        guard let array = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [Any] else {
            return []
        }
        return array.compactMap { $0 as? String }.filter { !$0.isEmpty }
    }

    public static func sourceHost(_ whereFrom: [String]) -> String? {
        // Prefer the page (second entry) over the file URL, which is often a CDN.
        for candidate in [whereFrom.count > 1 ? whereFrom[1] : nil, whereFrom.first].compactMap({ $0 }) {
            if let host = URL(string: candidate)?.host(), !host.isEmpty {
                return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            }
        }
        return nil
    }

    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "iso", "exe", "msi", "appimage", "deb"]
    static let codeExtensions: Set<String> = ["swift", "py", "js", "ts", "json", "html", "css", "sh", "sql", "yaml",
                                              "yml", "toml", "md", "ipynb", "rb", "go", "rs", "java", "c", "cpp", "h"]

    public static func kind(for url: URL, type: UTType? = nil) -> DownloadItem.Kind {
        let ext = url.pathExtension.lowercased()
        if installerExtensions.contains(ext) { return .installer }
        if codeExtensions.contains(ext) { return .code }
        let type = type ?? UTType(filenameExtension: ext)
        guard let type else { return .other }
        if type.conforms(to: .applicationBundle) { return .installer }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .archive) || ["zip", "rar", "7z", "tar", "gz", "tgz", "xz"].contains(ext) { return .archive }
        if type.conforms(to: .spreadsheet) || ["xlsx", "xls", "csv", "numbers"].contains(ext) { return .spreadsheet }
        if type.conforms(to: .presentation) || ["pptx", "ppt", "key"].contains(ext) { return .presentation }
        if type.conforms(to: .text) || ["docx", "doc", "pages", "rtf", "odt"].contains(ext) { return .document }
        return .other
    }

    // MARK: Filters

    /// "report (1).pdf" → "report.pdf"; nil if the name has no " (n)" suffix.
    public static func originalName(ofCopy name: String) -> String? {
        let ns = name as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        guard let open = stem.range(of: " (", options: .backwards), stem.hasSuffix(")") else { return nil }
        let number = stem[open.upperBound..<stem.index(before: stem.endIndex)]
        guard !number.isEmpty, number.allSatisfy(\.isNumber) else { return nil }
        let base = String(stem[..<open.lowerBound])
        return ext.isEmpty ? base : base + "." + ext
    }

    /// Copies ("report (1).pdf") whose original sits in the same folder with byte-for-byte identical contents.
    /// Reads files, so call it off the main thread.
    public static func duplicates(in items: [DownloadItem], fileManager: FileManager = .default) -> [DownloadItem] {
        let byName = Dictionary(items.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        return items.filter { item in
            guard item.kind != .folder, let original = originalName(ofCopy: item.name),
                  let match = byName[original], match.kind != .folder,
                  let a = logicalSize(item.url), let b = logicalSize(match.url), a == b
            else { return false }
            return fileManager.contentsEqual(atPath: item.url.path, andPath: match.url.path)
        }
    }

    static func logicalSize(_ url: URL) -> UInt64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(UInt64.init)
    }

    public static func filter(_ items: [DownloadItem], by filter: DownloadsFilter, now: Date = Date()) -> [DownloadItem] {
        switch filter {
        case .all: items
        case .old: items.filter { $0.age(now: now) > 30 * 86_400 }
        case .installers: items.filter { $0.kind == .installer }
        case .duplicates: duplicates(in: items)
        }
    }

    // MARK: Actions

    public enum RenameError: Error, LocalizedError, Equatable {
        case emptyName, invalidCharacters, alreadyExists(String)
        public var errorDescription: String? {
            switch self {
            case .emptyName: "The name can't be empty."
            case .invalidCharacters: "Names can't contain \"/\" or start with \".\"."
            case .alreadyExists(let n): "There's already a file called \"\(n)\"."
            }
        }
    }

    /// Renames in place. Keeps the original extension if the new name doesn't include one.
    @discardableResult
    public static func rename(_ url: URL, to newName: String, fileManager: FileManager = .default) throws -> URL {
        var name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw RenameError.emptyName }
        guard !name.contains("/"), !name.hasPrefix(".") else { throw RenameError.invalidCharacters }
        let ext = url.pathExtension
        if !ext.isEmpty, (name as NSString).pathExtension.isEmpty { name += "." + ext }
        let destination = url.deletingLastPathComponent().appendingPathComponent(name)
        if destination.path == url.path { return url }
        guard !fileManager.fileExists(atPath: destination.path) else { throw RenameError.alreadyExists(name) }
        try fileManager.moveItem(at: url, to: destination)
        return destination
    }

    /// Moves into `folder`, adding " 2", " 3"… if the name is taken. Never overwrites.
    @discardableResult
    public static func move(_ url: URL, into folder: URL, fileManager: FileManager = .default) throws -> URL {
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        var destination = folder.appendingPathComponent(url.lastPathComponent)
        var n = 2
        while fileManager.fileExists(atPath: destination.path) {
            let candidate = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            destination = folder.appendingPathComponent(candidate)
            n += 1
        }
        try fileManager.moveItem(at: url, to: destination)
        return destination
    }
}
