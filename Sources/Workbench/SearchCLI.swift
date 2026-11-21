import Foundation
import WorkbenchCore

/// Terminal version of the finder, for checking results without any UI.
enum SearchCLI {
    static func run(_ text: String) async {
        let started = Date()
        let entries = FileIndexer.index(roots: FileIndexer.defaultRoots())
        print("Indexed \(entries.count) files in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")

        let parsed = QueryParser.parse(text)
        print("Understood: terms=\(parsed.terms) \(parsed.understood)")
        let quick = FinderModel.searchLoosening(parsed, in: entries)
        report("Instant", quick.hits, quick.note)

        let words = parsed.terms.compactMap(\.first)
        guard SynonymExpander.isAvailable, !words.isEmpty else { return }
        let t = Date()
        let synonyms = await SynonymExpander().alternatives(for: words)
        print("Model suggested \(synonyms) in \(String(format: "%.2f", Date().timeIntervalSince(t)))s")
        let expanded = FinderModel.searchLoosening(parsed.adding(synonyms: synonyms), in: entries)
        report("With suggestions", expanded.hits, expanded.note)
    }

    private static func report(_ title: String, _ hits: [SearchHit], _ note: String?) {
        print("\n\(title): \(hits.count) results" + (note.map { " (\($0))" } ?? ""))
        for hit in hits.prefix(8) {
            print(String(format: "  %6.1f  ", hit.score) + hit.entry.name + "  —  " + hit.entry.displayFolder)
        }
    }
}
