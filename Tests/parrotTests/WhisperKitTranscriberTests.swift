import XCTest
@testable import parrot

final class WhisperKitTranscriberTests: XCTestCase {
    func testFrenchDecodingContractDisablesLanguageDetectionAndTranslation() {
        let options = WhisperKitTranscriber.frenchDecodingOptions

        XCTAssertEqual(options.language, "fr")
        XCTAssertEqual(options.task.description, "transcribe")
        XCTAssertTrue(options.usePrefillPrompt)
        XCTAssertFalse(options.detectLanguage)
        XCTAssertFalse(options.withoutTimestamps)
    }

    func testFrenchFileDecodingKeepsContractAndUsesSequentialVADChunks() {
        let options = WhisperKitTranscriber.frenchFileDecodingOptions

        XCTAssertEqual(options.language, "fr")
        XCTAssertEqual(options.task.description, "transcribe")
        XCTAssertTrue(options.usePrefillPrompt)
        XCTAssertFalse(options.detectLanguage)
        XCTAssertFalse(options.withoutTimestamps)
        XCTAssertEqual(options.concurrentWorkerCount, 1)
        XCTAssertEqual(options.chunkingStrategy?.rawValue, "vad")
    }
}
