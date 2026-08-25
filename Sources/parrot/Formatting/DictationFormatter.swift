import Foundation

struct DictationFormattingResult: Sendable, Equatable {
    enum Source: String, Sendable {
        case faithful
        case explicitStructure
    }

    let text: String
    let source: Source
    let fallbackReason: String?

    static func faithful(_ text: String) -> Self {
        Self(text: text, source: .faithful, fallbackReason: nil)
    }

    var usedSmartNotes: Bool { source == .explicitStructure }
}

/// The formatter is deliberately conservative. Canary owns transcription and
/// punctuation; Parrot only turns a clearly spoken, sequential list into real
/// lines. It never infers a mail, a title, paragraphs, bullets, or any other
/// editorial structure from ordinary free-form dictation.
actor DictationFormatter {
    func format(_ transcript: String) async -> DictationFormattingResult {
        guard !transcript.isEmpty else { return .faithful(transcript) }

        if let structured = SpokenStructureFormatter.formatExplicitNumbering(in: transcript) {
            return DictationFormattingResult(
                text: structured,
                source: .explicitStructure,
                fallbackReason: nil
            )
        }

        return .faithful(transcript)
    }
}

/// Formats explicit spoken list markers without guessing at the meaning of a
/// free-form dictation. This is intentionally local, immediate, and testable.
enum SpokenStructureFormatter {
    private static let markerPattern = #"(?i)\b(?:petit|point|numero|numéro)\s+([1-9][0-9]*)\b"#

    static func formatExplicitNumbering(in text: String) -> String? {
        guard let marker = try? NSRegularExpression(pattern: markerPattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = marker.matches(in: text, range: range)
        guard matches.count >= 2 else { return nil }

        let numbers = matches.compactMap { match -> Int? in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            return Int(text[range])
        }
        // Only turn an explicitly dictated 1, 2, 3… sequence into a list.
        // References such as “point 12 puis point 15” stay faithful text.
        guard numbers == Array(1...numbers.count) else { return nil }

        var sections: [(number: String, text: String)] = []
        for (index, match) in matches.enumerated() {
            let numberRange = match.range(at: 1)
            guard let number = Range(numberRange, in: text).map({ String(text[$0]) }) else { return nil }

            let contentStart = match.range.location + match.range.length
            let contentEnd = index + 1 < matches.count
                ? matches[index + 1].range.location
                : range.length
            guard let contentRange = Range(NSRange(location: contentStart, length: contentEnd - contentStart), in: text)
            else { return nil }

            let content = normalizedSentence(
                String(text[contentRange]),
                followedByAnotherListMarker: index + 1 < matches.count
            )
            guard !content.isEmpty else { return nil }
            sections.append((number, content))
        }

        let prefixRange = NSRange(location: 0, length: matches[0].range.location)
        let prefix = Range(prefixRange, in: text).map { String(text[$0]) } ?? ""
        let introduction = normalizedIntroduction(prefix)
        let numbered = sections.map { "\($0.number). \($0.text)" }.joined(separator: "\n\n")

        return introduction.isEmpty ? numbered : "\(introduction)\n\n\(numbered)"
    }

    private static func normalizedIntroduction(_ prefix: String) -> String {
        var result = collapseWhitespace(prefix)
        result = result.replacingOccurrences(
            of: #"(?i)\b(?:comme\s+)?mettre\s*$"#,
            with: "",
            options: .regularExpression
        )
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return "" }
        return result.hasSuffix(":") ? result : "\(result):"
    }

    private static func normalizedSentence(
        _ value: String,
        followedByAnotherListMarker: Bool
    ) -> String {
        var sentence = collapseWhitespace(value)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: #"^[,;:—–-]+\s*"#,
                with: "",
                options: .regularExpression
            )
        if followedByAnotherListMarker {
            sentence = sentence.replacingOccurrences(
                of: #"(?i)\s*\b(?:et|puis|ensuite|alors)\s*$"#,
                with: "",
                options: .regularExpression
            )
        }
        sentence = sentence
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: #"\s*[,;:]+\s*$"#,
                with: "",
                options: .regularExpression
            )
        guard !sentence.isEmpty else { return "" }
        let first = sentence.prefix(1).uppercased()
        let remainder = sentence.dropFirst()
        let capitalized = "\(first)\(remainder)"
        return capitalized.hasSuffix(".") || capitalized.hasSuffix("!") || capitalized.hasSuffix("?")
            ? capitalized
            : "\(capitalized)."
    }

    private static func collapseWhitespace(_ value: String) -> String {
        value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}
