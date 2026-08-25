import Foundation
import XCTest
@testable import parrot

final class SubtitlesCommandTests: XCTestCase {
    func testRootCommandExposesSubtitles() {
        let commandNames = Parrot.configuration.subcommands.map {
            $0.configuration.commandName ?? ""
        }

        XCTAssertTrue(commandNames.contains("subtitles"))
    }

    func testParsesInputAndOptionalOutput() throws {
        let defaultCommand = try Subtitles.parse(["clip.mov"])
        XCTAssertEqual(defaultCommand.input, "clip.mov")
        XCTAssertNil(defaultCommand.output)

        let explicitCommand = try Subtitles.parse([
            "clip.mp4",
            "--output", "captions/final.srt",
        ])
        XCTAssertEqual(explicitCommand.input, "clip.mp4")
        XCTAssertEqual(explicitCommand.output, "captions/final.srt")
    }

    func testResolvesDefaultSRTBesideInputAndExplicitRelativeOutput() {
        let workingDirectory = URL(fileURLWithPath: "/tmp/parrot-tests", isDirectory: true)

        let defaultPaths = SubtitlePaths.resolve(
            input: "media/voice.over.mov",
            output: nil,
            currentDirectory: workingDirectory
        )
        XCTAssertEqual(defaultPaths.input.path, "/tmp/parrot-tests/media/voice.over.mov")
        XCTAssertEqual(defaultPaths.output.path, "/tmp/parrot-tests/media/voice.over.srt")

        let explicitPaths = SubtitlePaths.resolve(
            input: "media/voice.mp4",
            output: "captions/custom.srt",
            currentDirectory: workingDirectory
        )
        XCTAssertEqual(explicitPaths.output.path, "/tmp/parrot-tests/captions/custom.srt")
    }
}
