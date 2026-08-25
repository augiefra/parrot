import Foundation

struct SRTCue: Equatable, Sendable {
    let index: Int
    let startMilliseconds: Int64
    let endMilliseconds: Int64
    let text: String
}

enum SRTFormatter {
    /// X controls the visual rendering of an uploaded SRT. Keep the authored
    /// lines deliberately narrower than broadcast/cinema captions so they
    /// remain comfortable in the mobile timeline.
    static let preferredLineLength = 32
    static let maximumLineCount = 2

    static func makeCues(
        from segments: [TimedTranscriptSegment],
        timelineOffset: TimeInterval = 0,
        mediaDuration: TimeInterval
    ) -> [SRTCue] {
        guard mediaDuration.isFinite, mediaDuration > 0 else { return [] }

        let durationMilliseconds = milliseconds(mediaDuration, rounding: .down)
        let sortedSegments = segments.sorted {
            if $0.start == $1.start { return $0.end < $1.end }
            return $0.start < $1.start
        }

        var cues: [SRTCue] = []
        var previousEnd: Int64 = 0
        for segment in sortedSegments {
            let normalizedText = normalize(segment.text)
            guard !normalizedText.isEmpty else { continue }

            let shiftedStart = max(0, timelineOffset + segment.start)
            let shiftedEnd = min(mediaDuration, timelineOffset + segment.end)
            let start = max(
                previousEnd,
                min(
                    durationMilliseconds,
                    milliseconds(shiftedStart, rounding: .toNearestOrAwayFromZero)
                )
            )
            let end = min(
                durationMilliseconds,
                milliseconds(shiftedEnd, rounding: .toNearestOrAwayFromZero)
            )
            guard end > start else { continue }

            let splitCueTexts = splitIntoCueTexts(normalizedText)
            // A positive SRT cue needs at least one millisecond. This is only
            // relevant to pathological sub-millisecond Whisper segments, but
            // preserve every word instead of dropping overflow cues.
            let cueTexts = end - start >= Int64(splitCueTexts.count)
                ? splitCueTexts
                : [wrap(normalizedText)]
            let ranges = distribute(start: start, end: end, across: cueTexts)

            for (text, range) in zip(cueTexts, ranges) where range.end > range.start {
                cues.append(
                    SRTCue(
                        index: cues.count + 1,
                        startMilliseconds: range.start,
                        endMilliseconds: range.end,
                        text: text
                    )
                )
                previousEnd = range.end
            }
        }
        return cues
    }

    static func render(_ cues: [SRTCue]) -> String {
        guard !cues.isEmpty else { return "" }
        return cues.map { cue in
            """
            \(cue.index)
            \(timestamp(cue.startMilliseconds)) --> \(timestamp(cue.endMilliseconds))
            \(cue.text)
            """
        }
        .joined(separator: "\n\n") + "\n"
    }

    static func timestamp(_ milliseconds: Int64) -> String {
        let clamped = max(0, milliseconds)
        let hours = clamped / 3_600_000
        let minutes = (clamped / 60_000) % 60
        let seconds = (clamped / 1_000) % 60
        let remainder = clamped % 1_000
        return String(
            format: "%02lld:%02lld:%02lld,%03lld",
            hours,
            minutes,
            seconds,
            remainder
        )
    }

    static func wrap(_ text: String, maxLineLength: Int = preferredLineLength) -> String {
        guard maxLineLength > 0 else { return text }

        if let balanced = balancedLines(text, maxLineLength: maxLineLength) {
            return balanced.joined(separator: "\n")
        }

        var lines: [String] = []
        var currentLine = ""
        for word in text.split(separator: " ").map(String.init) {
            let candidate = currentLine.isEmpty ? word : "\(currentLine) \(word)"
            if candidate.count <= maxLineLength || currentLine.isEmpty {
                currentLine = candidate
            } else {
                lines.append(currentLine)
                currentLine = word
            }
        }
        if !currentLine.isEmpty { lines.append(currentLine) }
        return lines.joined(separator: "\n")
    }

    /// Split one Whisper segment into SRT events that each fit in at most two
    /// authored lines. X preserves these line breaks even though it chooses the
    /// font, size, color, and background itself.
    static func splitIntoCueTexts(
        _ text: String,
        maxLineLength: Int = preferredLineLength
    ) -> [String] {
        guard maxLineLength > 0 else { return [text] }

        let words = text.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }

        var cues: [String] = []
        var start = 0
        while start < words.count {
            var end = start
            var bestEnd = start
            var preferredPunctuationEnd: Int?

            while end < words.count {
                let candidate = words[start...end].joined(separator: " ")
                guard balancedLines(candidate, maxLineLength: maxLineLength) != nil else {
                    break
                }

                bestEnd = end + 1
                if isNaturalCueEnding(words[end]), candidate.count >= maxLineLength {
                    preferredPunctuationEnd = bestEnd
                }
                end += 1
            }

            // An unbreakable word (a URL, for example) may exceed the target;
            // retain it intact rather than corrupting the transcript.
            if bestEnd == start {
                bestEnd = start + 1
            } else if bestEnd < words.count, let punctuationEnd = preferredPunctuationEnd {
                bestEnd = punctuationEnd
            }

            let cue = words[start..<bestEnd].joined(separator: " ")
            cues.append(wrap(cue, maxLineLength: maxLineLength))
            start = bestEnd
        }
        return cues
    }

    private static func balancedLines(
        _ text: String,
        maxLineLength: Int
    ) -> [String]? {
        guard maxLineLength > 0 else { return nil }

        let words = text.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        if text.count <= maxLineLength { return [text] }
        guard words.count > 1 else { return nil }

        var best: (lines: [String], score: Int)?
        for breakIndex in 1..<words.count {
            let first = words[..<breakIndex].joined(separator: " ")
            let second = words[breakIndex...].joined(separator: " ")
            guard first.count <= maxLineLength, second.count <= maxLineLength else {
                continue
            }

            var score = abs(first.count - second.count) * 2
            if first.count > second.count { score += 8 }
            if breakIndex == 1 || breakIndex == words.count - 1 { score += 6 }
            if isNaturalCueEnding(words[breakIndex - 1]) { score -= 4 }

            if best == nil || score < best!.score {
                best = ([first, second], score)
            }
        }
        return best?.lines
    }

    private static func distribute(
        start: Int64,
        end: Int64,
        across texts: [String]
    ) -> [(start: Int64, end: Int64)] {
        guard !texts.isEmpty, end > start else { return [] }
        guard texts.count > 1 else { return [(start, end)] }

        let weights = texts.map {
            max(1, $0.replacingOccurrences(of: "\n", with: " ").count)
        }
        let totalWeight = weights.reduce(0, +)
        let duration = end - start

        var boundaries = [start]
        var cumulativeWeight = 0
        for index in 0..<(texts.count - 1) {
            cumulativeWeight += weights[index]
            let proportional = start + Int64(
                (Double(duration) * Double(cumulativeWeight) / Double(totalWeight)).rounded()
            )
            let earliest = boundaries.last! + 1
            let remainingCueCount = Int64(texts.count - index - 1)
            let latest = end - remainingCueCount
            boundaries.append(min(max(proportional, earliest), latest))
        }
        boundaries.append(end)

        return zip(boundaries, boundaries.dropFirst()).map { ($0, $1) }
    }

    private static func isNaturalCueEnding(_ word: String) -> Bool {
        word.last.map { ".!?…;:".contains($0) } ?? false
    }

    private static func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func milliseconds(
        _ seconds: TimeInterval,
        rounding rule: FloatingPointRoundingRule
    ) -> Int64 {
        guard seconds.isFinite else { return 0 }
        return max(0, Int64((seconds * 1_000).rounded(rule)))
    }
}
