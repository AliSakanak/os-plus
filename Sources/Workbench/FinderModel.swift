import AppKit
import Carbon.HIToolbox
import Foundation
import Observation
import WorkbenchCore

enum FinderShortcut: String, CaseIterable, Identifiable {
    case commandShiftSpace, optionShiftSpace, controlOptionCommandF

    var id: String { rawValue }

    var label: String {
        switch self {
        case .commandShiftSpace: "⌘⇧Space"
        case .optionShiftSpace: "⌥⇧Space"
        case .controlOptionCommandF: "⌃⌥⌘F"
        }
    }

    var keyCode: UInt32 { self == .controlOptionCommandF ? UInt32(kVK_ANSI_F) : UInt32(kVK_Space) }

    var modifiers: UInt32 {
        switch self {
        case .commandShiftSpace: UInt32(cmdKey | shiftKey)
        case .optionShiftSpace: UInt32(optionKey | shiftKey)
        case .controlOptionCommandF: UInt32(controlKey | optionKey | cmdKey)
        }
    }
}

@MainActor
@Observable
final class FinderModel {
    private(set) var entryCount = 0
    private(set) var indexedAt: Date?
    private(set) var isIndexing = false
    private(set) var hits: [SearchHit] = []
    private(set) var understood: [String] = []
    private(set) var alternativesNote: String?
    private(set) var relaxedNote: String?
    private(set) var isThinking = false
    private(set) var hotKeyRegistered = false
    var selection = 0
    var query = "" {
        didSet { if query != oldValue { scheduleSearch() } }
    }

    var shortcut: FinderShortcut {
        didSet {
            UserDefaults.standard.set(shortcut.rawValue, forKey: "finderShortcut")
            registerHotKey()
        }
    }

    let roots = FileIndexer.defaultRoots()
    let modelNote = SynonymExpander.unavailableReason

    private var entries: [FileEntry] = []
    private let expander = SynonymExpander()
    private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var panelController: FinderPanelController?
    private var panel: FinderPanelController {
        if let panelController { return panelController }
        let created = FinderPanelController(model: self)
        panelController = created
        return created
    }

    init() {
        shortcut = UserDefaults.standard.string(forKey: "finderShortcut").flatMap(FinderShortcut.init) ?? .commandShiftSpace
        registerHotKey()
    }

    private func registerHotKey() {
        hotKeyRegistered = HotKeyCenter.shared.register(id: 2, keyCode: shortcut.keyCode,
                                                        modifiers: shortcut.modifiers) { [weak self] in
            self?.togglePanel()
        }
    }

    // MARK: Panel

    func togglePanel() {
        panel.isVisible ? panel.hide() : showPanel()
    }

    func showPanel() {
        refreshIndexIfStale()
        selection = 0
        panel.show()
    }

    func hidePanel() {
        panel.hide()
    }

    // MARK: Index

    func refreshIndexIfStale() {
        if let indexedAt, Date().timeIntervalSince(indexedAt) < 600 { return }
        reindex()
    }

    func reindex() {
        guard !isIndexing else { return }
        isIndexing = true
        let roots = self.roots
        Task.detached(priority: .userInitiated) {
            let entries = FileIndexer.index(roots: roots)
            await MainActor.run {
                self.entries = entries
                self.entryCount = entries.count
                self.indexedAt = Date()
                self.isIndexing = false
                if !self.query.isEmpty { self.scheduleSearch(debounce: false) }
            }
        }
    }

    // MARK: Search

    private func scheduleSearch(debounce: Bool = true) {
        searchTask?.cancel()
        let text = query
        let entries = self.entries
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            hits = []
            understood = []
            alternativesNote = nil
            relaxedNote = nil
            isThinking = false
            return
        }
        searchTask = Task {
            if debounce { try? await Task.sleep(for: .milliseconds(60)) }
            guard !Task.isCancelled else { return }

            // 1. Instant results from names, kinds and dates.
            let parsed = QueryParser.parse(text)
            let quick = await Task.detached { Self.searchLoosening(parsed, in: entries) }.value
            guard !Task.isCancelled else { return }
            understood = parsed.understood
            alternativesNote = nil
            relaxedNote = quick.note
            hits = quick.hits
            selection = min(selection, max(0, quick.hits.count - 1))

            // 2. If it reads like a description (or found nothing), ask the on-device model for other words.
            let words = parsed.terms.compactMap(\.first)
            let wordCount = text.split(separator: " ").count
            guard SynonymExpander.isAvailable, !words.isEmpty, wordCount >= 2 || quick.hits.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            isThinking = true
            let synonyms = await expander.alternatives(for: words)
            guard !Task.isCancelled else { return }
            isThinking = false
            let added = Array(Set(synonyms.values.flatMap { $0 })).sorted()
            guard !added.isEmpty else { return }
            alternativesNote = "also tried: " + added.prefix(8).joined(separator: ", ")
            let expanded = parsed.adding(synonyms: synonyms)
            let better = await Task.detached { Self.searchLoosening(expanded, in: entries) }.value
            guard !Task.isCancelled, !better.hits.isEmpty else { return }
            // Whichever needed less loosening goes first; the other's new finds follow.
            let (first, second) = better.level < quick.level ? (better, quick) : (quick, better)
            let seen = Set(first.hits.map(\.entry.path))
            hits = first.hits + second.hits.filter { !seen.contains($0.entry.path) }
            relaxedNote = first.note
        }
    }

    /// Strict search first; if nothing matches, loosen step by step (allow one unmatched word, then drop the
    /// date, then both) and say what was loosened. `level` is how much loosening it took (0 = none).
    nonisolated static func searchLoosening(_ parsed: ParsedQuery, in entries: [FileEntry])
        -> (hits: [SearchHit], note: String?, level: Int) {
        let strict = FileSearcher.search(parsed, in: entries)
        if !strict.isEmpty { return (strict, nil, 0) }
        var noDate = parsed
        noDate.dateRange = nil
        let dateLabel = parsed.dateRange != nil ? parsed.understood.last : nil
        let attempts: [(ParsedQuery, Int, String?, Bool)] = [
            (parsed, 1, "Close matches (not every word matched).", parsed.terms.count >= 2),
            (noDate, 0, dateLabel.map { "Nothing from \($0). Showing other dates." }, dateLabel != nil),
            (noDate, 1, dateLabel.map { "Nothing from \($0). Showing close matches from other dates." },
             dateLabel != nil && parsed.terms.count >= 2),
            // Long descriptions: accept files matching any one word, ranked by how many matched.
            (noDate, max(0, parsed.terms.count - 1), "Loose matches: only some of your words matched.",
             parsed.terms.count >= 3),
        ]
        for (level, attempt) in attempts.enumerated() where attempt.3 {
            let hits = FileSearcher.search(attempt.0, in: entries, allowMissing: attempt.1)
            if !hits.isEmpty { return (hits, attempt.2, level + 1) }
        }
        return ([], nil, 99)
    }

    // MARK: Actions

    var selectedHit: SearchHit? { hits.indices.contains(selection) ? hits[selection] : nil }

    func moveSelection(_ delta: Int) {
        guard !hits.isEmpty else { return }
        selection = max(0, min(hits.count - 1, selection + delta))
    }

    func open(_ hit: SearchHit? = nil) {
        guard let hit = hit ?? selectedHit else { return }
        hidePanel()
        NSWorkspace.shared.open(URL(fileURLWithPath: hit.entry.path))
    }

    func reveal(_ hit: SearchHit? = nil) {
        guard let hit = hit ?? selectedHit else { return }
        hidePanel()
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: hit.entry.path)])
    }

    func copyPath(_ hit: SearchHit? = nil) {
        guard let hit = hit ?? selectedHit else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hit.entry.path, forType: .string)
        Toast.shared.show("Copied path", detail: hit.entry.path, symbol: "doc.on.clipboard")
    }
}
