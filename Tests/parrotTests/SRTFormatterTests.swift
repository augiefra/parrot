import Foundation
import XCTest
@testable import parrot

final class SRTFormatterTests: XCTestCase {
    func testBuildsOrderedBoundedSubRipCues() {
        let segments = [
            TimedTranscriptSegment(start: 4.25, end: 7.1, text: "  Deuxième   phrase. "),
            TimedTranscriptSegment(start: 0.1254, end: 2.5001, text: "Première phrase."),
            TimedTranscriptSegment(start: 9.0, end: 12.0, text: "Fin bornée."),
            TimedTranscriptSegment(start: 2.0, end: 2.0, text: "Durée nulle"),
            TimedTranscriptSegment(start: 3.0, end: 4.0, text: "   "),
        ]

        let cues = SRTFormatter.makeCues(
            from: segments,
            timelineOffset: 0.5,
            mediaDuration: 10.0
        )

        XCTAssertEqual(cues.map(\.index), [1, 2, 3])
        XCTAssertEqual(cues.map(\.startMilliseconds), [625, 4_750, 9_500])
        XCTAssertEqual(cues.map(\.endMilliseconds), [3_000, 7_600, 10_000])
        XCTAssertEqual(cues.last?.endMilliseconds, 10_000)
        XCTAssertTrue(zip(cues, cues.dropFirst()).allSatisfy {
            $0.endMilliseconds <= $1.startMilliseconds
        })
    }

    func testRendersValidUtf8SRTWithMillisecondTimestamps() throws {
        let cues = [
            SRTCue(
                index: 1,
                startMilliseconds: 3_723_004,
                endMilliseconds: 3_725_610,
                text: "FacilAbo à l’écran"
            ),
            SRTCue(
                index: 2,
                startMilliseconds: 3_725_610,
                endMilliseconds: 3_729_000,
                text: "Codex et TARS"
            ),
        ]

        let rendered = SRTFormatter.render(cues)

        XCTAssertEqual(
            rendered,
            """
            1
            01:02:03,004 --> 01:02:05,610
            FacilAbo à l’écran

            2
            01:02:05,610 --> 01:02:09,000
            Codex et TARS

            """
        )
        XCTAssertEqual(String(data: Data(rendered.utf8), encoding: .utf8), rendered)

        let timestampPattern = #"(?m)^\d{2,}:\d{2}:\d{2},\d{3} --> \d{2,}:\d{2}:\d{2},\d{3}$"#
        let matches = try NSRegularExpression(pattern: timestampPattern).numberOfMatches(
            in: rendered,
            range: NSRange(rendered.startIndex..<rendered.endIndex, in: rendered)
        )
        XCTAssertEqual(matches, 2)
    }

    func testWrapsLongCueTextWithoutChangingItsWords() {
        let text = "Une phrase française assez longue pour vérifier le découpage lisible des sous-titres."

        let wrapped = SRTFormatter.wrap(text, maxLineLength: 24)

        XCTAssertTrue(wrapped.contains("\n"))
        XCTAssertEqual(wrapped.replacingOccurrences(of: "\n", with: " "), text)
        XCTAssertTrue(wrapped.split(separator: "\n").allSatisfy { $0.count <= 24 })
    }

    func testSocialCuesStayWithinTwoLinesOfThirtyTwoCharacters() {
        let text = "Parrot prépare maintenant des sous-titres plus courts pour une lecture confortable sur X, même sur un téléphone tenu verticalement."

        let cues = SRTFormatter.makeCues(
            from: [TimedTranscriptSegment(start: 0, end: 8, text: text)],
            mediaDuration: 8
        )

        XCTAssertGreaterThan(cues.count, 1)
        XCTAssertTrue(cues.allSatisfy { cue in
            let lines = cue.text.split(separator: "\n", omittingEmptySubsequences: false)
            return lines.count <= SRTFormatter.maximumLineCount
                && lines.allSatisfy { $0.count <= SRTFormatter.preferredLineLength }
        })
        XCTAssertEqual(
            cues.map(\.text)
                .joined(separator: " ")
                .replacingOccurrences(of: "\n", with: " "),
            text
        )
        XCTAssertEqual(cues.first?.startMilliseconds, 0)
        XCTAssertEqual(cues.last?.endMilliseconds, 8_000)
        XCTAssertTrue(zip(cues, cues.dropFirst()).allSatisfy {
            $0.endMilliseconds == $1.startMilliseconds
        })
    }

    func testTwoLineCueUsesABalancedBottomHeavyBreak() {
        let text = "Des sous-titres agréables à lire sur toutes les vidéos"

        let lines = SRTFormatter.wrap(text).split(separator: "\n")

        XCTAssertEqual(lines.count, 2)
        XCTAssertLessThanOrEqual(lines[0].count, lines[1].count)
        XCTAssertEqual(lines.joined(separator: " "), text)
    }

    func testSubMillisecondBudgetNeverDropsSplitText() {
        let text = "Un segment pathologique extrêmement bref conserve quand même tous ses mots sans perte."

        let cues = SRTFormatter.makeCues(
            from: [TimedTranscriptSegment(start: 0, end: 0.001, text: text)],
            mediaDuration: 0.001
        )

        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].startMilliseconds, 0)
        XCTAssertEqual(cues[0].endMilliseconds, 1)
        XCTAssertEqual(cues[0].text.replacingOccurrences(of: "\n", with: " "), text)
    }
}
