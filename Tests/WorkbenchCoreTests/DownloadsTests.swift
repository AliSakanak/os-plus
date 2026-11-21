import Foundation
import Testing
@testable import WorkbenchCore

/// A throwaway folder that looks like ~/Downloads.
private struct Sandbox {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("wb-dl-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @discardableResult
    func file(_ name: String, bytes: Int = 10, daysOld: Double = 0, whereFrom: [String]? = nil) throws -> URL {
        let file = url.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: file)
        if daysOld > 0 {
            let date = Date().addingTimeInterval(-daysOld * 86_400)
            try FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: file.path)
        }
        if let whereFrom {
            let data = try PropertyListSerialization.data(fromPropertyList: whereFrom, format: .binary, options: 0)
            _ = data.withUnsafeBytes {
                setxattr(file.path, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, data.count, 0, 0)
            }
        }
        return file
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

@Suite("Downloads")
struct DownloadsTests {
    @Test func readsWhereFromAttribute() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let file = try box.file("report.pdf", whereFrom: [
            "https://objects.githubusercontent.com/abc/report.pdf", "https://www.github.com/someone/repo/releases",
        ])
        let sources = DownloadsReader.whereFrom(path: file.path)
        #expect(sources.count == 2)
        #expect(DownloadsReader.sourceHost(sources) == "github.com")   // the page, not the CDN, minus www.
        #expect(DownloadsReader.whereFrom(path: box.url.appendingPathComponent("missing").path).isEmpty)
    }

    @Test func sourceHostFallsBackToFileURL() {
        #expect(DownloadsReader.sourceHost(["https://cdn.example.com/a.zip"]) == "cdn.example.com")
        #expect(DownloadsReader.sourceHost(["https://cdn.example.com/a.zip", ""]) == "cdn.example.com")
        #expect(DownloadsReader.sourceHost([]) == nil)
        #expect(DownloadsReader.parseWhereFrom(Data("junk".utf8)).isEmpty)
    }

    @Test func listsNewestFirstAndSkipsHidden() throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.file("old.zip", daysOld: 40)
        try box.file("new.png")
        try box.file(".DS_Store")
        try FileManager.default.createDirectory(at: box.url.appendingPathComponent("Some Folder"),
                                                withIntermediateDirectories: true)
        let items = try DownloadsReader.list(folder: box.url)
        #expect(items.count == 3)
        #expect(!items.contains { $0.name == ".DS_Store" })
        #expect(items.last?.name == "old.zip")
        #expect(items.first { $0.name == "Some Folder" }?.kind == .folder)
        #expect(items.first { $0.name == "Some Folder" }?.size == nil)
        #expect(items.first { $0.name == "new.png" }?.kind == .image)
    }

    @Test func kinds() {
        func k(_ name: String) -> DownloadItem.Kind { DownloadsReader.kind(for: URL(fileURLWithPath: "/x/" + name)) }
        #expect(k("Installer.dmg") == .installer)
        #expect(k("thing.pkg") == .installer)
        #expect(k("paper.pdf") == .pdf)
        #expect(k("photo.HEIC") == .image)
        #expect(k("clip.mov") == .video)
        #expect(k("song.mp3") == .audio)
        #expect(k("bundle.zip") == .archive)
        #expect(k("budget.xlsx") == .spreadsheet)
        #expect(k("deck.pptx") == .presentation)
        #expect(k("letter.docx") == .document)
        #expect(k("script.py") == .code)
        #expect(k("mystery.qqq") == .other)
    }

    @Test func copyNames() {
        #expect(DownloadsReader.originalName(ofCopy: "report (1).pdf") == "report.pdf")
        #expect(DownloadsReader.originalName(ofCopy: "my file (12).tar") == "my file.tar")
        #expect(DownloadsReader.originalName(ofCopy: "notes (2)") == "notes")
        #expect(DownloadsReader.originalName(ofCopy: "report.pdf") == nil)
        #expect(DownloadsReader.originalName(ofCopy: "Season (Final).mp4") == nil)
        #expect(DownloadsReader.originalName(ofCopy: "() .pdf") == nil)
    }

    @Test func filters() throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.file("report.pdf", bytes: 100)
        try box.file("report (1).pdf", bytes: 100)        // identical → duplicate
        try box.file("report (2).pdf", bytes: 999)        // different size → not a duplicate
        try box.file("photo.jpg", bytes: 50)
        let sameSize = box.url.appendingPathComponent("photo (1).jpg")
        try Data(repeating: 0x42, count: 50).write(to: sameSize)   // same size, different bytes → not a duplicate
        try box.file("App.dmg")
        try box.file("orphan (1).txt", bytes: 5)          // no original → not a duplicate
        let items = try DownloadsReader.list(folder: box.url)

        #expect(DownloadsReader.filter(items, by: .duplicates).map(\.name) == ["report (1).pdf"])
        #expect(DownloadsReader.filter(items, by: .installers).map(\.name) == ["App.dmg"])
        #expect(DownloadsReader.filter(items, by: .all).count == 7)
    }

    @Test func oldFilterUsesDateAdded() {
        // "Date added" is set by macOS when a file lands in a folder, so build items directly.
        let now = Date()
        func item(_ name: String, days: Double) -> DownloadItem {
            DownloadItem(url: URL(fileURLWithPath: "/x/" + name), name: name, kind: .other, size: 1,
                         dateAdded: now.addingTimeInterval(-days * 86_400), whereFrom: [])
        }
        let items = [item("fresh", days: 2), item("month", days: 29.9), item("stale", days: 31), item("ancient", days: 400)]
        #expect(DownloadsReader.filter(items, by: .old, now: now).map(\.name) == ["stale", "ancient"])
    }

    @Test func renameKeepsExtensionAndRefusesClashes() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let file = try box.file("IMG_4821.pdf")
        try box.file("Taken.pdf")

        let renamed = try DownloadsReader.rename(file, to: "Lease agreement")
        #expect(renamed.lastPathComponent == "Lease agreement.pdf")
        #expect(FileManager.default.fileExists(atPath: renamed.path))

        #expect(throws: DownloadsReader.RenameError.alreadyExists("Taken.pdf")) {
            try DownloadsReader.rename(renamed, to: "Taken")
        }
        #expect(throws: DownloadsReader.RenameError.emptyName) { try DownloadsReader.rename(renamed, to: "  ") }
        #expect(throws: DownloadsReader.RenameError.invalidCharacters) { try DownloadsReader.rename(renamed, to: "a/b") }
        #expect(try DownloadsReader.rename(renamed, to: "Lease agreement.pdf") == renamed)  // no-op
    }

    @Test func moveNeverOverwrites() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let dest = box.url.appendingPathComponent("Dest")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try Data("existing".utf8).write(to: dest.appendingPathComponent("a.txt"))
        let file = try box.file("a.txt")

        let moved = try DownloadsReader.move(file, into: dest)
        #expect(moved.lastPathComponent == "a 2.txt")
        #expect(try String(contentsOf: dest.appendingPathComponent("a.txt"), encoding: .utf8) == "existing")
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
