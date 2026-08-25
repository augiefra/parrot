import XCTest
@testable import parrot

final class CanaryConfigurationTests: XCTestCase {
    func testCanaryIsTheOnlyRegisteredActiveModel() {
        XCTAssertEqual(ModelRegistry.shared.map(\.id), ["canary-1b-v2-mlx-bf16"])
        XCTAssertEqual(ModelRegistry.recommended()?.engine, .canaryMLX)
        XCTAssertEqual(ModelRegistry.recommended()?.languages, ["fr"])
    }

    func testRootCommandDoesNotExposeVideoOrWhisperCommands() {
        let names = Parrot.configuration.subcommands.map { $0.configuration.commandName ?? "" }
        XCTAssertFalse(names.contains("subtitles"))
        XCTAssertEqual(Models.configuration.subcommands.count, 1)
    }
}
