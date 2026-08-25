import XCTest
@testable import parrot

final class MenuBarControllerTests: XCTestCase {
    func testMenuExposesClassicDictationAndDictionaryOnly() async {
        await MainActor.run {
            let controller = MenuBarController(modelID: "canary-1b-v2-mlx-bf16")
            let titles = controller.menuItemTitles
            let dictionaryIndex = titles.firstIndex(of: "Add dictionary correction…")

            XCTAssertNotNil(dictionaryIndex)
            XCTAssertFalse(titles.contains("Sous-titrage vidéo…"))
            XCTAssertFalse(titles.contains("Vidéo prête pour X…"))
            XCTAssertTrue(titles.contains(where: { $0.contains("canary-1b-v2-mlx-bf16") }))

            controller.setRecording(true)
            XCTAssertTrue(controller.isDictationBusy)

            controller.setRecording(false)
            XCTAssertFalse(controller.isDictationBusy)

            controller.setTranscribing()
            XCTAssertTrue(controller.isDictationBusy)
        }
    }
}
