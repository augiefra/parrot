import AppKit
import XCTest
@testable import parrot

final class TextInjectorTests: XCTestCase {
    func testPasteboardSnapshotCopiesEveryReadableRepresentation() {
        let source = NSPasteboardItem()
        let customType = NSPasteboard.PasteboardType("com.ecologni.parrot.test")
        let customData = Data([0xCA, 0xFE, 0xBA, 0xBE])
        source.setString("Texte existant", forType: .string)
        source.setData(customData, forType: customType)

        let snapshot = PasteboardSnapshot(items: [source])

        XCTAssertEqual(snapshot.items.count, 1)
        XCTAssertEqual(snapshot.items[0].string(forType: .string), "Texte existant")
        XCTAssertEqual(snapshot.items[0].data(forType: customType), customData)
    }

    func testEmptySnapshotContainsNoItems() {
        XCTAssertTrue(PasteboardSnapshot(items: nil).items.isEmpty)
    }
}
