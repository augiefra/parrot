import XCTest
@testable import parrot

final class LocalDictionaryTests: XCTestCase {
    func testCanonicalizesVariantsWithoutChangingLongerWords() {
        let dictionary = LocalDictionary(entries: [
            .init(canonical: "FacilAbo", variants: ["facilabo", "facile abo"]),
            .init(canonical: "Supabase", variants: ["super base"]),
        ])

        XCTAssertEqual(
            dictionary.apply(to: "facile abo et SUPER BASE, mais facilabos reste inchangé."),
            "FacilAbo et Supabase, mais facilabos reste inchangé."
        )
    }

    func testAddingCorrectionReplacesAnExistingConflictingVariant() {
        let dictionary = LocalDictionary(entries: [
            .init(canonical: "Old spelling", variants: ["parrot word"]),
            .init(canonical: "FacilAbo", variants: ["facile abo"]),
        ])

        let updated = dictionary.addingCorrection(
            transcribedAs: "parrot word",
            correctSpelling: "Preferred spelling"
        )

        XCTAssertEqual(
            updated.apply(to: "PARROT WORD puis facile abo"),
            "Preferred spelling puis FacilAbo"
        )
        XCTAssertEqual(
            updated.entries.first(where: { $0.canonical == "Old spelling" })?.variants,
            []
        )
    }

    func testMissingStarterTermsAreAddedWithoutOverwritingUserCorrections() {
        let saved = LocalDictionary(entries: [
            .init(canonical: "My Tarse", variants: ["tarse"]),
            .init(canonical: "FacilAbo", variants: ["facile abonnement"]),
        ])

        let merged = saved.includingMissingStarterEntries()

        XCTAssertEqual(
            merged.apply(to: "tars, tarse, facile abonnement et codex"),
            "TARS, My Tarse, FacilAbo et Codex"
        )
        XCTAssertEqual(
            merged.entries.filter { $0.canonical == "FacilAbo" }.count,
            1
        )
    }

    func testExistingStarterTermReceivesNewBuiltInVariantsWithoutReplacingUserSpelling() {
        let dictionary = LocalDictionary(entries: [
            .init(canonical: "FacilAbo", variants: ["facile abo"]),
        ])

        let updated = dictionary.includingMissingStarterEntries()

        XCTAssertEqual(updated.apply(to: "facile à beau"), "FacilAbo")
        XCTAssertEqual(updated.apply(to: "tchad gpt"), "ChatGPT")
        XCTAssertEqual(updated.entries.first?.canonical, "FacilAbo")
    }
}
