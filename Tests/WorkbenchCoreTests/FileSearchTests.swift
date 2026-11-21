import Foundation
import Testing
@testable import WorkbenchCore

private let calendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Europe/London")!
    return c
}()

/// 20 Nov 2026, 22:00 London, which is "today" for these tests.
private let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 22))!

private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
    calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
}

private func entry(_ path: String, _ modified: Date = date(2026, 11, 1), dir: Bool = false) -> FileEntry {
    FileEntry(path: path, isDirectory: dir, modified: modified, size: 100)
}

@Suite("Query parsing")
struct QueryParsingTests {
    @Test func lastSpringIsMarchToMayThisYear() throws {
        // The on-device model got this wrong (2023–2026), so dates are parsed deterministically.
        let q = QueryParser.parse("that lease pdf from last spring", now: now, calendar: calendar)
        #expect(q.terms == [["lease"]])
        #expect(q.kind == .pdf)
        let range = try #require(q.dateRange)
        #expect(range.contains(date(2026, 3, 1)))
        #expect(range.contains(date(2026, 5, 31)))
        #expect(!range.contains(date(2026, 6, 2)))
        #expect(!range.contains(date(2026, 2, 27)))
        #expect(q.understood == ["PDFs", "spring 2026"])
    }

    @Test func lastWinterSpansNewYear() throws {
        let q = QueryParser.parse("budget last winter", now: now, calendar: calendar)
        let range = try #require(q.dateRange)
        #expect(range.contains(date(2025, 12, 15)))
        #expect(range.contains(date(2026, 2, 20)))
        #expect(!range.contains(date(2026, 3, 5)))
    }

    @Test func relativePhrases() throws {
        let yesterday = try #require(QueryParser.parse("notes yesterday", now: now, calendar: calendar).dateRange)
        #expect(yesterday.contains(date(2026, 11, 19)))
        #expect(!yesterday.contains(date(2026, 11, 20)))

        let lastMonth = try #require(QueryParser.parse("invoice last month", now: now, calendar: calendar).dateRange)
        #expect(lastMonth.contains(date(2026, 10, 15)))
        #expect(!lastMonth.contains(date(2026, 11, 2)))

        let ago = QueryParser.parse("photos 3 weeks ago", now: now, calendar: calendar)
        #expect(ago.kind == .image)
        #expect(ago.dateRange!.contains(date(2026, 10, 30)))
        #expect(ago.terms.isEmpty)
    }

    @Test func monthNamesAndYears() throws {
        let march = try #require(QueryParser.parse("receipt in march", now: now, calendar: calendar).dateRange)
        #expect(march.contains(date(2026, 3, 10)))
        let december = try #require(QueryParser.parse("receipt december", now: now, calendar: calendar).dateRange)
        #expect(december.contains(date(2025, 12, 10)))   // December hasn't happened yet this year
        let explicit = QueryParser.parse("tax march 2024", now: now, calendar: calendar)
        #expect(explicit.dateRange!.contains(date(2024, 3, 10)))
        #expect(explicit.terms == [["tax"]])
        let year = QueryParser.parse("cv from 2024", now: now, calendar: calendar)
        #expect(year.dateRange!.contains(date(2024, 7, 1)))
        #expect(year.terms == [["cv"]])
    }

    @Test func plainSearchesStayPlain() {
        let q = QueryParser.parse("strava", now: now, calendar: calendar)
        #expect(q.terms == [["strava"]])
        #expect(q.kind == nil && q.dateRange == nil)
        // A lone kind word is a name search, not a filter.
        #expect(QueryParser.parse("pdf", now: now, calendar: calendar).terms == [["pdf"]])
        // Short queries keep stop words: "the office" is a name.
        #expect(QueryParser.parse("the office", now: now, calendar: calendar).terms == [["the"], ["office"]])
        // Accents fold so "estación" matches "estacion".
        #expect(QueryParser.parse("Estación", now: now, calendar: calendar).terms == [["estacion"]])
    }

    @Test func synonymsJoinTheirGroup() {
        let q = QueryParser.parse("rental contract", now: now, calendar: calendar)
            .adding(synonyms: ["rental": ["lease", "tenancy"], "contract": ["agreement"]])
        #expect(q.terms == [["rental", "lease", "tenancy"], ["contract", "agreement"]])
    }
}

@Suite("Fuzzy matching")
struct FuzzyTests {
    @Test func tokens() {
        #expect(Fuzzy.tokens("PDFReport-1903 final_v2.pdf")
            == ["pdfreport", "pdf", "report", "1903", "final", "v2", "v", "2", "pdf"])
        #expect(Fuzzy.tokens("strava-footy-analyzer") == ["strava", "footy", "analyzer"])
    }

    @Test func distances() {
        #expect(Fuzzy.distance("stava", "strava") == 1)
        #expect(Fuzzy.distance("analyser", "analyzer") == 1)
        #expect(Fuzzy.distance("teh", "the") == 1)          // transposition counts as one
        #expect(Fuzzy.distance("kitten", "sitting") == 3)
        #expect(Fuzzy.distance("abc", "xyzxyz", limit: 1) == 2)
    }

    @Test func findsWithTyposInitialsAndFolders() {
        let files = [
            entry("/Users/me/Documents/git_repos/strava-footy-analyzer", dir: true),
            entry("/Users/me/Documents/git_repos/strava-footy-analyzer/README.md"),
            entry("/Users/me/Downloads/RailTicket-48213.pdf"),
            entry("/Users/me/Documents/Leases/2026 flat agreement.pdf", date(2026, 4, 10)),
            entry("/Users/me/Desktop/holiday.jpg"),
        ]
        func top(_ text: String) -> String? {
            FileSearcher.search(QueryParser.parse(text, now: now, calendar: calendar), in: files, now: now)
                .first?.entry.name
        }
        #expect(top("strava") == "strava-footy-analyzer")
        #expect(top("stava footy") == "strava-footy-analyzer")        // typo
        #expect(top("footy analyser") == "strava-footy-analyzer")     // British spelling vs. American
        #expect(top("sfa") == "strava-footy-analyzer")                // initials
        #expect(top("ticket") == "RailTicket-48213.pdf")              // camelCase part
        #expect(top("lease pdf from last spring") == "2026 flat agreement.pdf")  // folder name + kind + date
        #expect(top("zzzz") == nil)
    }

    @Test func noScatteredLetterMatches() {
        // Real-world regression: "train" used to match names like these via letters spread across the whole name.
        let noise = [entry("/Users/me/Downloads/Team_Retreat_Agenda_Final.pdf"),
                     entry("/Users/me/Downloads/doc_translation.pdf")]
        #expect(FileSearcher.search(QueryParser.parse("train", now: now, calendar: calendar), in: noise, now: now).isEmpty)
        // Abbreviations within one word still work.
        let strava = [entry("/Users/me/strava.txt")]
        #expect(!FileSearcher.search(QueryParser.parse("stva", now: now, calendar: calendar), in: strava, now: now).isEmpty)
    }

    @Test func kindAndDateFiltersExclude() {
        let files = [
            entry("/Users/me/a/report.pdf", date(2026, 4, 1)),
            entry("/Users/me/a/report.docx", date(2026, 4, 1)),
            entry("/Users/me/a/report old.pdf", date(2024, 4, 1)),
        ]
        let hits = FileSearcher.search(QueryParser.parse("report pdf last spring", now: now, calendar: calendar),
                                       in: files, now: now)
        #expect(hits.map(\.entry.name) == ["report.pdf"])
    }

    @Test func partialMatchesWhenAWordIsMissing() {
        let files = [entry("/Users/me/Downloads/RailTicket-48213.pdf"), entry("/Users/me/Downloads/menu.pdf")]
        let q = QueryParser.parse("train ticket", now: now, calendar: calendar)
        #expect(FileSearcher.search(q, in: files, now: now).isEmpty)          // strict: "train" isn't in any name
        let partial = FileSearcher.search(q, in: files, allowMissing: 1, now: now)
        #expect(partial.map(\.entry.name) == ["RailTicket-48213.pdf"])         // but never matches nothing at all
        let single = QueryParser.parse("zzz", now: now, calendar: calendar)
        #expect(FileSearcher.search(single, in: files, allowMissing: 1, now: now).isEmpty)
    }

    @Test func rareWordsOutweighCommonOnesInLooseMatches() {
        var files = (1...20).map { entry("/Users/me/notes/plan-\($0).md") }
        files.append(entry("/Users/me/Documents/workout schedule.pdf", date(2025, 1, 1)))
        let q = QueryParser.parse("gym workout plan", now: now, calendar: calendar)
        let hits = FileSearcher.search(q, in: files, allowMissing: 2, now: now)
        #expect(hits.first?.entry.name == "workout schedule.pdf")
    }

    @Test func prefersRecentWhenEqual() {
        let files = [entry("/Users/me/a/notes.txt", date(2024, 1, 1)), entry("/Users/me/b/notes.txt", date(2026, 11, 19))]
        let hits = FileSearcher.search(QueryParser.parse("notes", now: now, calendar: calendar), in: files, now: now)
        #expect(hits.first?.entry.path == "/Users/me/b/notes.txt")
    }
}

@Suite("Indexing")
struct IndexingTests {
    @Test func skipsGeneratedAndHiddenFolders() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("wb-index-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        for dir in ["proj/src", "proj/node_modules/pkg", "proj/.git/objects", "proj/build/out", "Notes"] {
            try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        for file in ["proj/src/main.swift", "proj/node_modules/pkg/index.js", "proj/.git/objects/x",
                     "proj/build/out/app", "Notes/plan.md", ".hidden"] {
            try Data("x".utf8).write(to: root.appendingPathComponent(file))
        }
        let names = Set(FileIndexer.index(roots: [root.path]).map(\.name))
        #expect(names == ["proj", "src", "main.swift", "Notes", "plan.md"])
    }
}
