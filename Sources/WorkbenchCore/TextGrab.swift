import CoreGraphics
import Foundation
import Vision

/// What came out of one screen grab.
public struct GrabResult: Sendable, Equatable {
    public var lines: [String]
    /// QR codes / barcodes found in the selection (their decoded contents).
    public var codes: [String]

    public init(lines: [String], codes: [String] = []) {
        self.lines = lines
        self.codes = codes
    }

    /// What goes on the clipboard: recognised text, or the code's payload if that's all there is.
    public var clipboardText: String {
        let text = lines.joined(separator: "\n")
        if !text.isEmpty, !codes.isEmpty { return text + "\n" + codes.joined(separator: "\n") }
        return text.isEmpty ? codes.joined(separator: "\n") : text
    }

    public var isEmpty: Bool { lines.isEmpty && codes.isEmpty }

    public var wordCount: Int {
        clipboardText.split(whereSeparator: \.isWhitespace).count
    }

    /// "Copied 42 words", "Copied QR code link".
    public var summary: String {
        if lines.isEmpty, let code = codes.first {
            return code.hasPrefix("http") ? "Copied QR code link" : "Copied QR code"
        }
        return wordCount == 1 ? "Copied 1 word" : "Copied \(wordCount) words"
    }
}

public enum TextRecognizer {
    /// Recognises text (English + Spanish) and any QR/barcodes in an image file.
    public static func recognize(imageAt url: URL) async throws -> GrabResult {
        var textRequest = RecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true
        textRequest.recognitionLanguages = [Locale.Language(identifier: "en-GB"), Locale.Language(identifier: "es-ES")]

        let barcodeRequest = DetectBarcodesRequest()

        async let textObservations = textRequest.perform(on: url)
        async let barcodeObservations = barcodeRequest.perform(on: url)

        let observations = try await textObservations
        let codes = (try? await barcodeObservations)?.compactMap(\.payloadString) ?? []
        let lines = orderedLines(observations.compactMap { obs -> (CGRect, String)? in
            guard let text = obs.topCandidates(1).first?.string, !text.isEmpty else { return nil }
            return (obs.boundingBox.cgRect, text)
        })
        return GrabResult(lines: lines, codes: Array(NSOrderedSet(array: codes)) as? [String] ?? codes)
    }

    /// Sorts boxes into reading order: top to bottom, then left to right for boxes on the same line.
    /// Vision's coordinates are normalised with the origin at the bottom-left.
    static func orderedLines(_ boxes: [(CGRect, String)]) -> [String] {
        let sorted = boxes.sorted { a, b in
            let sameLine = abs(a.0.midY - b.0.midY) < min(a.0.height, b.0.height) * 0.5
            return sameLine ? a.0.minX < b.0.minX : a.0.midY > b.0.midY
        }
        // Merge boxes that sit on the same line into one line of text.
        var lines: [(rect: CGRect, text: String)] = []
        for (rect, text) in sorted {
            if let last = lines.last, abs(last.rect.midY - rect.midY) < min(last.rect.height, rect.height) * 0.5 {
                lines[lines.count - 1] = (last.rect.union(rect), last.text + " " + text)
            } else {
                lines.append((rect, text))
            }
        }
        return lines.map(\.text)
    }
}

/// One saved grab in the history list.
public struct GrabRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var date: Date
    public var text: String

    public init(id: UUID = UUID(), date: Date = Date(), text: String) {
        self.id = id
        self.date = date
        self.text = text
    }
}

/// The last few grabs, newest first, saved to Application Support.
public struct GrabHistory: Codable, Sendable, Equatable {
    public private(set) var records: [GrabRecord] = []
    public var limit = 30

    public init(records: [GrabRecord] = [], limit: Int = 30) {
        self.records = records
        self.limit = limit
    }

    public mutating func add(_ text: String, date: Date = Date()) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Grabbing the same thing twice just bumps it to the top.
        records.removeAll { $0.text == trimmed }
        records.insert(GrabRecord(date: date, text: trimmed), at: 0)
        if records.count > limit { records.removeLast(records.count - limit) }
    }

    public mutating func remove(id: UUID) {
        records.removeAll { $0.id == id }
    }

    public mutating func removeAll() {
        records.removeAll()
    }

    public static func defaultURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Workbench/grabs.json")
    }

    public static func load(from url: URL = defaultURL()) -> GrabHistory {
        guard let data = try? Data(contentsOf: url),
              let history = try? JSONDecoder().decode(GrabHistory.self, from: data)
        else { return GrabHistory() }
        return history
    }

    public func save(to url: URL = defaultURL()) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
