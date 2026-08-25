import Foundation

/// A deliberately small, local-only spelling dictionary.
///
/// Whisper stays responsible for speech recognition. This layer only normalizes
/// known variants after transcription, so a correction is deterministic and
/// survives restarts without sending vocabulary or transcripts anywhere.
struct LocalDictionary: Codable {
    struct Entry: Codable, Equatable {
        let canonical: String
        let variants: [String]
    }

    let entries: [Entry]

    static let defaultURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/parrot/dictionary.json")

    static let starterEntries = [
        Entry(canonical: "FacilAbo", variants: [
            "facilabo", "facile abo", "facile à beau", "facile a beau",
        ]),
        Entry(canonical: "EuroVolt", variants: ["eurovolt", "euro volt"]),
        Entry(canonical: "Supabase", variants: ["supabase", "super base"]),
        Entry(canonical: "Vercel", variants: ["vercel", "versel"]),
        Entry(canonical: "Codex", variants: ["codex", "code x"]),
        Entry(canonical: "ChatGPT", variants: ["chat gpt", "tchad gpt", "tchadgpt", "tchat gpt"]),
        Entry(canonical: "TARS", variants: ["tarse"]),
    ]

    static func loadOrCreateDefault() -> LocalDictionary {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: defaultURL.path) {
            do {
                try fileManager.createDirectory(
                    at: defaultURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let starter = LocalDictionary(entries: starterEntries)
                let data = try JSONEncoder.pretty.encode(starter)
                try data.write(to: defaultURL, options: .atomic)
                log("created local dictionary at \(defaultURL.path)")
                return starter
            } catch {
                log("could not create local dictionary: \(error)")
                return LocalDictionary(entries: [])
            }
        }

        do {
            let data = try Data(contentsOf: defaultURL)
            let saved = try JSONDecoder().decode(LocalDictionary.self, from: data)
            // New built-in terms become available without overwriting a
            // user's canonical spelling or variants in the existing file.
            return saved.includingMissingStarterEntries()
        } catch {
            log("could not load local dictionary at \(defaultURL.path): \(error)")
            return LocalDictionary(entries: [])
        }
    }

    func includingMissingStarterEntries() -> LocalDictionary {
        var updatedEntries = entries
        var claimedSpellings = Set(entries.flatMap { [$0.canonical] + $0.variants }.map(Self.key))

        for starter in Self.starterEntries {
            let canonicalKey = Self.key(starter.canonical)
            if let existingIndex = updatedEntries.firstIndex(where: {
                Self.key($0.canonical) == canonicalKey
            }) {
                let availableVariants = starter.variants.filter {
                    !claimedSpellings.contains(Self.key($0))
                }
                guard !availableVariants.isEmpty else { continue }
                let existing = updatedEntries[existingIndex]
                updatedEntries[existingIndex] = Entry(
                    canonical: existing.canonical,
                    variants: existing.variants + availableVariants
                )
                claimedSpellings.formUnion(availableVariants.map(Self.key))
                continue
            }

            let availableVariants = starter.variants.filter {
                !claimedSpellings.contains(Self.key($0))
            }
            updatedEntries.append(
                Entry(canonical: starter.canonical, variants: availableVariants)
            )
            claimedSpellings.insert(canonicalKey)
            claimedSpellings.formUnion(availableVariants.map(Self.key))
        }
        return LocalDictionary(entries: updatedEntries)
    }

    /// Adds one user-facing correction while keeping the on-disk file valid.
    /// If the same mis-transcription already pointed at another spelling, the
    /// new choice replaces it instead of leaving two competing rules behind.
    static func addCorrection(transcribedAs: String, correctSpelling: String) throws {
        let source = transcribedAs.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonical = correctSpelling.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !canonical.isEmpty else {
            throw DictionaryError.emptyCorrection
        }

        let updated = loadOrCreateDefault().addingCorrection(
            transcribedAs: source,
            correctSpelling: canonical
        )
        let data = try JSONEncoder.pretty.encode(updated)
        try data.write(to: defaultURL, options: .atomic)
    }

    func addingCorrection(transcribedAs: String, correctSpelling: String) -> LocalDictionary {
        let sourceKey = transcribedAs.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        let canonicalKey = correctSpelling.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )

        var updatedEntries = entries.map { entry in
            Entry(
                canonical: entry.canonical,
                variants: entry.variants.filter {
                    $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) != sourceKey
                }
            )
        }

        if let index = updatedEntries.firstIndex(where: {
            $0.canonical.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == canonicalKey
        }) {
            var variants = updatedEntries[index].variants
            if sourceKey != canonicalKey, !variants.contains(where: {
                $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == sourceKey
            }) {
                variants.append(transcribedAs)
            }
            updatedEntries[index] = Entry(canonical: correctSpelling, variants: variants)
        } else {
            updatedEntries.append(
                Entry(
                    canonical: correctSpelling,
                    variants: sourceKey == canonicalKey ? [] : [transcribedAs]
                )
            )
        }

        return LocalDictionary(entries: updatedEntries)
    }

    func apply(to text: String) -> String {
        let replacements = entries.flatMap { entry in
            ([entry.canonical] + entry.variants).map { variant in
                (variant: variant, canonical: entry.canonical)
            }
        }
        .sorted { $0.variant.count > $1.variant.count }

        return replacements.reduce(text) { output, replacement in
            replaceWholeWord(
                replacement.variant,
                with: replacement.canonical,
                in: output
            )
        }
    }

    private func replaceWholeWord(_ source: String, with replacement: String, in text: String) -> String {
        let escapedSource = NSRegularExpression.escapedPattern(for: source)
        let pattern = "(?i)(?<![\\p{L}\\p{N}_])\(escapedSource)(?![\\p{L}\\p{N}_])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }

    private static func key(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("parrot dictionary: \(message)\n".utf8))
    }
}

enum DictionaryError: LocalizedError {
    case emptyCorrection

    var errorDescription: String? {
        switch self {
        case .emptyCorrection:
            return "Both dictionary fields need a value."
        }
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
