import Foundation

// MARK: - Index

public struct FileEntry: Sendable, Equatable {
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let modified: Date
    public let size: UInt64
    public let kind: DownloadItem.Kind
    /// Lowercased, accent-folded name, and its word tokens (split on punctuation and camelCase).
    let folded: String
    let tokens: [String]

    public init(path: String, isDirectory: Bool, modified: Date, size: UInt64) {
        self.path = path
        self.name = (path as NSString).lastPathComponent
        self.isDirectory = isDirectory
        self.modified = modified
        self.size = size
        self.kind = isDirectory ? .folder : DownloadsReader.kind(for: URL(fileURLWithPath: path))
        self.folded = Fuzzy.fold(name)
        self.tokens = Fuzzy.tokens(name)
    }

    /// The containing folder, abbreviated with ~.
    public var displayFolder: String {
        let parent = (path as NSString).deletingLastPathComponent
        let home = NSHomeDirectory()
        return parent.hasPrefix(home) ? "~" + parent.dropFirst(home.count) : parent
    }
}

public enum FileIndexer {
    /// Folders that are generated, huge, or private and never what you're looking for.
    public static let skippedFolderNames: Set<String> = [
        "node_modules", "build", "dist", "DerivedData", "Pods", "venv", "target", "__pycache__", "vendor",
        "Library", "Caches", "bower_components", "coverage",
    ]

    public static func defaultRoots(home: String = NSHomeDirectory()) -> [String] {
        ["Documents", "Desktop", "Downloads", "Developer", "Projects", "Pictures/Screenshots"]
            .map { "\(home)/\($0)" }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// Walks `roots`, skipping hidden items, packages' insides and generated folders.
    public static func index(roots: [String], limit: Int = 400_000,
                             isCancelled: @Sendable () -> Bool = { false }) -> [FileEntry] {
        var entries: [FileEntry] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .contentModificationDateKey, .fileSizeKey]
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }
            ) else { continue }
            for case let url as URL in enumerator {
                if entries.count >= limit || (entries.count % 2_000 == 0 && isCancelled()) { return entries }
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                let isDir = values.isDirectory == true && values.isPackage != true
                if isDir, skippedFolderNames.contains(url.lastPathComponent) || url.lastPathComponent.hasSuffix(".build") {
                    enumerator.skipDescendants()
                    continue
                }
                entries.append(FileEntry(path: url.path, isDirectory: isDir,
                                         modified: values.contentModificationDate ?? .distantPast,
                                         size: UInt64(values.fileSize ?? 0)))
            }
        }
        return entries
    }
}

// MARK: - Query parsing (deterministic: dates and kinds)

public struct ParsedQuery: Sendable, Equatable {
    /// Each group must match; any word within a group may match (synonyms).
    public var terms: [[String]]
    public var kind: DownloadItem.Kind?
    public var dateRange: ClosedRange<Date>?
    /// Human-readable description of what was understood, e.g. "PDFs · modified Mar–May 2026".
    public var understood: [String]

    public init(terms: [[String]], kind: DownloadItem.Kind? = nil, dateRange: ClosedRange<Date>? = nil,
                understood: [String] = []) {
        self.terms = terms
        self.kind = kind
        self.dateRange = dateRange
        self.understood = understood
    }

    public var isEmpty: Bool { terms.isEmpty && kind == nil && dateRange == nil }

    /// Adds alternative words (from the language model) to the matching term groups.
    public func adding(synonyms: [String: [String]]) -> ParsedQuery {
        var copy = self
        copy.terms = terms.map { group in
            var g = group
            for word in group { g += (synonyms[word] ?? []).map(Fuzzy.fold).filter { !$0.isEmpty && !g.contains($0) } }
            return g
        }
        return copy
    }
}

public enum QueryParser {
    static let stopWords: Set<String> = [
        "the", "a", "an", "that", "this", "my", "from", "of", "in", "on", "at", "for", "with", "about", "to",
        "file", "files", "one", "thing", "i", "me", "some", "find", "where", "is", "was", "it", "and", "or",
        "had", "have", "got", "saved", "downloaded", "made", "wrote", "created", "edited", "modified",
        "el", "la", "los", "las", "de", "del", "un", "una",
    ]

    static let kindWords: [String: DownloadItem.Kind] = [
        "pdf": .pdf, "pdfs": .pdf,
        "image": .image, "images": .image, "photo": .image, "photos": .image, "picture": .image, "pictures": .image,
        "screenshot": .image, "screenshots": .image, "png": .image, "jpg": .image, "jpeg": .image,
        "video": .video, "videos": .video, "movie": .video, "recording": .video, "mp4": .video,
        "song": .audio, "audio": .audio, "mp3": .audio,
        "spreadsheet": .spreadsheet, "spreadsheets": .spreadsheet, "excel": .spreadsheet, "csv": .spreadsheet,
        "xlsx": .spreadsheet,
        "presentation": .presentation, "slides": .presentation, "deck": .presentation, "powerpoint": .presentation,
        "doc": .document, "docx": .document, "document": .document, "documents": .document, "word": .document,
        "zip": .archive, "archive": .archive,
        "folder": .folder, "folders": .folder, "directory": .folder,
        "installer": .installer, "dmg": .installer,
        "code": .code, "script": .code,
    ]

    static let kindLabels: [DownloadItem.Kind: String] = [
        .pdf: "PDFs", .image: "Images", .video: "Videos", .audio: "Audio", .spreadsheet: "Spreadsheets",
        .presentation: "Presentations", .document: "Documents", .archive: "Archives", .folder: "Folders",
        .installer: "Installers", .code: "Code",
    ]

    static let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september",
                         "october", "november", "december"]

    public static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> ParsedQuery {
        var words = Fuzzy.fold(text)
            .replacingOccurrences(of: "?", with: " ")
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map(String.init)
        var understood: [String] = []

        // Date phrases first (they consume words like "last" and "spring").
        let (range, label, consumed) = parseDate(words, now: now, calendar: calendar)
        if !consumed.isEmpty {
            words = words.enumerated().filter { !consumed.contains($0.offset) }.map(\.element)
        }

        // Kind words, but only when there's something else to search for or it's clearly a filter.
        var kind: DownloadItem.Kind?
        if let index = words.firstIndex(where: { kindWords[$0] != nil }), words.count > 1 || range != nil {
            kind = kindWords[words[index]]
            words.remove(at: index)
        }
        if let kind, let label = kindLabels[kind] { understood.append(label) }
        if let label { understood.append(label) }

        // Stop words only matter in sentence-like queries; "the office" as a 2-word name search keeps "the".
        let sentenceLike = words.count >= 3 || range != nil || kind != nil
        let terms = words
            .filter { !sentenceLike || !stopWords.contains($0) }
            .filter { !$0.isEmpty }
            .map { [$0] }
        return ParsedQuery(terms: terms, kind: kind, dateRange: range, understood: understood)
    }

    /// Recognises: today, yesterday, this/last week|month|year, last spring/summer/autumn/fall/winter,
    /// month names ("in march", "march 2025"), "N days|weeks|months ago", "recently", a 4-digit year.
    static func parseDate(_ words: [String], now: Date, calendar: Calendar)
        -> (ClosedRange<Date>?, String?, Set<Int>) {
        func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
            calendar.date(from: DateComponents(year: y, month: m, day: d)) ?? now
        }
        func endOf(_ start: Date, adding component: Calendar.Component, _ value: Int) -> Date {
            (calendar.date(byAdding: component, value: value, to: start) ?? now).addingTimeInterval(-1)
        }
        let year = calendar.component(.year, from: now)
        let month = calendar.component(.month, from: now)
        let startOfToday = calendar.startOfDay(for: now)
        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "MMM yyyy"

        for (i, word) in words.enumerated() {
            let next = i + 1 < words.count ? words[i + 1] : nil
            let next2 = i + 2 < words.count ? words[i + 2] : nil

            switch word {
            case "today":
                return (startOfToday...now, "today", [i])
            case "yesterday":
                let start = calendar.date(byAdding: .day, value: -1, to: startOfToday)!
                return (start...startOfToday.addingTimeInterval(-1), "yesterday", [i])
            case "recently", "recent", "lately":
                return (calendar.date(byAdding: .day, value: -14, to: now)!...now, "last 2 weeks", [i])
            case "this", "last":
                guard let next else { break }
                let back = word == "last" ? 1 : 0
                switch next {
                case "week":
                    let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)!.start
                    let start = calendar.date(byAdding: .weekOfYear, value: -back, to: thisWeek)!
                    let end = back == 0 ? now : endOf(start, adding: .weekOfYear, 1)
                    return (start...end, word == "last" ? "last week" : "this week", [i, i + 1])
                case "month":
                    let thisMonth = day(year, month, 1)
                    let start = calendar.date(byAdding: .month, value: -back, to: thisMonth)!
                    let end = back == 0 ? now : endOf(start, adding: .month, 1)
                    return (start...end, monthFormatter.string(from: start), [i, i + 1])
                case "year":
                    let start = day(year - back, 1, 1)
                    let end = back == 0 ? now : endOf(start, adding: .year, 1)
                    return (start...end, String(year - back), [i, i + 1])
                case "spring", "summer", "autumn", "fall", "winter":
                    // Northern-hemisphere meteorological seasons. "last X" = the most recent one that has ended.
                    let startMonth = ["spring": 3, "summer": 6, "autumn": 9, "fall": 9, "winter": 12][next]!
                    var y = year
                    func seasonEnd(_ y: Int) -> Date { endOf(day(y, startMonth, 1), adding: .month, 3) }
                    if back == 1 {
                        while seasonEnd(y) > now { y -= 1 }
                    } else if startMonth == 12, month < 3 {
                        y -= 1
                    }
                    let start = day(y, startMonth, 1)
                    let label = "\(next) \(startMonth == 12 ? "\(y)–\(y + 1 - 2000)" : String(y))"
                    return (start...min(seasonEnd(y), now), label, [i, i + 1])
                default:
                    break
                }
            default:
                break
            }

            // "3 weeks ago", "two months ago"
            if let n = Int(word) ?? ["a": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6][word],
               let unit = next, next2 == "ago" {
                let component: Calendar.Component? = unit.hasPrefix("day") ? .day : unit.hasPrefix("week") ? .weekOfYear
                    : unit.hasPrefix("month") ? .month : unit.hasPrefix("year") ? .year : nil
                if let component, let center = calendar.date(byAdding: component, value: -n, to: now) {
                    // Fuzzy window around the point in time: ±half a unit (at least a day).
                    let span = max(86_400, (now.timeIntervalSince(calendar.date(byAdding: component, value: -1, to: now)!)) / 2)
                    return (center.addingTimeInterval(-span)...min(now, center.addingTimeInterval(span)),
                            "around \(n) \(unit) ago", [i, i + 1, i + 2])
                }
            }

            // Month names: "march", "in march", "march 2025"
            if let m = months.firstIndex(where: { $0 == word || ($0.prefix(3) == word && word.count == 3) }) {
                var y = year
                var consumed: Set<Int> = [i]
                if let next, let explicit = Int(next), (1990...2100).contains(explicit) {
                    y = explicit
                    consumed.insert(i + 1)
                } else if m + 1 > month {
                    y -= 1   // "march" in November means this year; "december" in November means last year
                }
                if i > 0, words[i - 1] == "in" { consumed.insert(i - 1) }
                let start = day(y, m + 1, 1)
                return (start...min(endOf(start, adding: .month, 1), now), monthFormatter.string(from: start), consumed)
            }

            // A bare year: "2024"
            if let y = Int(word), (1990...year).contains(y), word.count == 4 {
                var consumed: Set<Int> = [i]
                if i > 0, words[i - 1] == "in" || words[i - 1] == "from" { consumed.insert(i - 1) }
                let start = day(y, 1, 1)
                return (start...min(endOf(start, adding: .year, 1), now), String(y), consumed)
            }
        }
        return (nil, nil, [])
    }
}

// MARK: - Fuzzy matching

public enum Fuzzy {
    public static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
    }

    /// "PDFReport-1903 final_v2.pdf" → ["pdfreport", "pdf", "report", "1903", "final", "v2", "pdf"].
    public static func tokens(_ name: String) -> [String] {
        var result: [String] = []
        for chunk in name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let word = String(chunk)
            result.append(fold(word))
            // camelCase / PascalCase / ACRONYMWord splits
            var parts: [String] = []
            var current = ""
            let chars = Array(word)
            for (i, c) in chars.enumerated() {
                let prev = i > 0 ? chars[i - 1] : nil
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                let boundary = c.isUppercase && prev != nil
                    && (prev!.isLowercase || (prev!.isUppercase && next?.isLowercase == true))
                let digitBoundary = prev != nil && (c.isNumber != prev!.isNumber)
                if (boundary || digitBoundary), !current.isEmpty {
                    parts.append(current)
                    current = ""
                }
                current.append(c)
            }
            if !current.isEmpty { parts.append(current) }
            if parts.count > 1 { result += parts.map(fold) }
        }
        return result
    }

    /// Optimal string alignment distance (Damerau–Levenshtein with adjacent transpositions).
    public static func distance(_ a: String, _ b: String, limit: Int = .max) -> Int {
        let a = Array(a), b = Array(b)
        if abs(a.count - b.count) > limit { return limit + 1 }
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev2 = [Int](repeating: 0, count: b.count + 1)
        var prev = Array(0...b.count)
        var curr = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            curr[0] = i
            var rowMin = curr[0]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    curr[j] = min(curr[j], prev2[j - 2] + 1)
                }
                rowMin = min(rowMin, curr[j])
            }
            if rowMin > limit { return limit + 1 }
            (prev2, prev, curr) = (prev, curr, prev2)
        }
        return prev[b.count]
    }

    static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var it = haystack.makeIterator()
        outer: for c in needle {
            while let h = it.next() { if h == c { continue outer } }
            return false
        }
        return true
    }

    static func allowedTypos(_ term: String) -> Int {
        term.count >= 8 ? 2 : term.count >= 4 ? 1 : 0
    }

    /// Score for one search word against one file; nil if it doesn't match at all.
    static func score(term: String, entry: FileEntry) -> Double? {
        if entry.folded.hasPrefix(term) { return 20 }
        if entry.tokens.contains(where: { $0.hasPrefix(term) }) { return 15 }
        if entry.folded.contains(term) { return 10 }
        let typos = allowedTypos(term)
        if typos > 0 {
            for token in entry.tokens {
                // Whole-word typo ("stava" → "strava") or typo while still typing ("analyser" vs "analyzer…").
                if distance(term, token, limit: typos) <= typos { return 8 }
                if token.count > term.count,
                   distance(term, String(token.prefix(term.count)), limit: typos) <= typos { return 6 }
            }
        }
        // Initials ("sfa" → "strava-footy-analyzer") or a skipped-letters abbreviation within one word
        // ("stv" → "strava"). Never across the whole name: long names contain almost any letter sequence.
        if term.count >= 3 {
            let initials = String(entry.tokens.compactMap(\.first))
            if initials.contains(term) { return 7 }
            if entry.tokens.contains(where: { $0.count <= term.count + 3 && isSubsequence(term, of: $0) }) { return 3 }
        }
        // The folder it lives in mentions the word.
        let folderPath = fold((entry.path as NSString).deletingLastPathComponent)
        if term.count >= 3, folderPath.contains(term) { return 2 }
        return nil
    }
}

// MARK: - Searching

public struct SearchHit: Sendable, Equatable {
    public let entry: FileEntry
    public let score: Double
}

public enum FileSearcher {
    /// - Parameter allowMissing: how many search words may go unmatched. Descriptive queries often include
    ///   words that aren't in the file name ("train ticket" for "RailTicket.pdf"), so callers retry with 1.
    public static func search(_ query: ParsedQuery, in entries: [FileEntry], limit: Int = 60,
                              allowMissing: Int = 0, now: Date = Date()) -> [SearchHit] {
        guard !query.isEmpty else { return [] }
        let required = max(query.terms.isEmpty ? 0 : 1, query.terms.count - allowMissing)
        let candidates = entries.filter { entry in
            (query.kind.map { entry.kind == $0 } ?? true) && (query.dateRange.map { $0.contains(entry.modified) } ?? true)
        }
        // When some words may go unmatched, rare words should count for more than common ones:
        // in "gym workout plan", matching "workout" says far more than matching "plan".
        let weights = allowMissing > 0 && query.terms.count >= 2
            ? rarityWeights(query.terms, in: candidates)
            : Array(repeating: 1.0, count: query.terms.count)
        var hits: [SearchHit] = []
        hits.reserveCapacity(256)
        for entry in candidates {
            var total = 0.0
            var matched = 0
            var missed = 0
            for (g, group) in query.terms.enumerated() {
                if let best = group.compactMap({ Fuzzy.score(term: $0, entry: entry) }).max() {
                    total += best * weights[g]
                    matched += 1
                } else {
                    missed += 1
                    if missed > allowMissing { break }
                }
            }
            guard matched >= required, missed <= allowMissing else { continue }
            total -= Double(missed) * 12
            // Prefer recently modified, shorter names, and files over folders when tied.
            let days = max(0, now.timeIntervalSince(entry.modified) / 86_400)
            total += max(0, 4 - log2(days + 1) / 2)
            total -= Double(entry.name.count) * 0.02
            total -= Double(entry.path.split(separator: "/").count) * 0.05
            hits.append(SearchHit(entry: entry, score: total))
        }
        hits.sort { $0.score > $1.score }
        return Array(hits.prefix(limit))
    }

    /// Inverse document frequency per term group, normalised to average 1.
    static func rarityWeights(_ groups: [[String]], in entries: [FileEntry]) -> [Double] {
        let n = Double(entries.count)
        let raw = groups.map { group -> Double in
            let df = entries.reduce(0) { count, entry in
                count + (group.contains { Fuzzy.score(term: $0, entry: entry) != nil } ? 1 : 0)
            }
            return log((n + 1) / (Double(df) + 1)) + 0.1
        }
        let mean = raw.reduce(0, +) / Double(max(1, raw.count))
        return raw.map { mean > 0 ? $0 / mean : 1 }
    }
}
