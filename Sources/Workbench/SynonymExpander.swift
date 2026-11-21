import Foundation
import FoundationModels

/// One word's alternatives. Separate named fields work far better with the small on-device model than
/// "a list of alternatives": asked for a list, it just repeated the word back ("gym → gym, gym, gym").
@Generable
struct WordAlternatives {
    @Guide(description: "A different word with a similar meaning, lowercase")
    var synonym1: String
    @Guide(description: "Another different word with a similar meaning, lowercase")
    var synonym2: String
    @Guide(description: "The Spanish translation, lowercase")
    var spanish: String
}

/// Asks Apple's on-device model for other words a file name might use ("lease" → rent, tenancy, alquiler).
/// Dates and file types are handled by `QueryParser` instead: the small model is unreliable at date arithmetic.
actor SynonymExpander {
    init() {}
    private var cache: [String: [String]] = [:]

    private static let instructions = """
        You suggest other words a file name might use, to help find files. \
        Examples: "rental" → lease, tenancy, alquiler. "cv" → resume, curriculum, cv. \
        "workout" → exercise, training, entrenamiento. "invoice" → bill, receipt, factura.
        """

    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.appleIntelligenceNotEnabled): "Turn on Apple Intelligence for smarter matching."
        case .unavailable(.modelNotReady): "Apple's on-device model is still downloading."
        case .unavailable(.deviceNotEligible): "This Mac doesn't support Apple Intelligence."
        case .unavailable: "Apple's on-device model isn't available."
        }
    }

    func alternatives(for words: [String]) async -> [String: [String]] {
        let missing = Array(words.filter { cache[$0] == nil && $0.count >= 3 && Int($0) == nil }.prefix(4))
        if !missing.isEmpty, Self.isAvailable {
            let found = await withTaskGroup(of: (String, [String]?).self) { group in
                for word in missing {
                    group.addTask { (word, await Self.ask(word)) }
                }
                var result: [String: [String]] = [:]
                for await (word, alts) in group { if let alts { result[word] = alts } }
                return result
            }
            // Only successful answers are cached: a cancelled or failed call must be retried next time.
            for (word, alts) in found { cache[word] = alts }
        }
        return words.reduce(into: [:]) { $0[$1] = cache[$1] ?? [] }
    }

    /// nil means the call failed or was cancelled (as opposed to "no alternatives").
    private static func ask(_ word: String) async -> [String]? {
        let session = LanguageModelSession(instructions: instructions)
        let response: LanguageModelSession.Response<WordAlternatives>
        do {
            response = try await session.respond(to: "Word: \(word)", generating: WordAlternatives.self,
                                                 options: GenerationOptions(temperature: 0.3))
        } catch {
            return nil
        }
        let c = response.content
        var seen: Set<String> = [word]
        return [c.synonym1, c.synonym2, c.spanish]
            .map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.contains(" ") && seen.insert($0).inserted }
    }
}
