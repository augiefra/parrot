import XCTest
@testable import parrot

final class DictationFormatterTests: XCTestCase {
    func testEmptyTranscriptRemainsEmpty() async {
        let formatter = DictationFormatter()

        let result = await formatter.format("")

        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.source, .faithful)
        XCTAssertFalse(result.usedSmartNotes)
        XCTAssertNil(result.fallbackReason)
    }

    func testFreeFormDictationIsNeverEditoriallyRewritten() async {
        let source = "Bonjour, je voudrais juste dicter ce texte pour préparer un mail plus tard."

        let result = await DictationFormatter().format(source)

        XCTAssertEqual(result.text, source)
        XCTAssertEqual(result.source, .faithful)
    }

    func testExplicitSpokenNumberingBecomesARealNumberedList() {
        let source = """
        Ok donc on va faire un test pour savoir si la description marche bien et si tu es capable
        de mieux mettre en page tout ce que je dis, comme mettre petit 1 des paragraphes
        parfaitement ciblés petit 2 une application parfaitement menée.
        """

        let formatted = SpokenStructureFormatter.formatExplicitNumbering(in: source)

        XCTAssertNotNil(formatted)
        XCTAssertTrue(formatted!.contains("1. Des paragraphes parfaitement ciblés"))
        XCTAssertTrue(formatted!.hasSuffix("2. Une application parfaitement menée."))
    }

    func testExplicitSpokenNumberingHandlesTheCommasProducedByDictation() {
        let formatted = SpokenStructureFormatter.formatExplicitNumbering(
            in: "Petit 1, ça marche bien. Petit 2, ça marche pas complètement bien. Petit 3, ça marche correctement."
        )

        XCTAssertEqual(
            formatted,
            "1. Ça marche bien.\n\n2. Ça marche pas complètement bien.\n\n3. Ça marche correctement."
        )
    }

    func testNaturalSpokenListDropsOrphanPunctuationAndConnectors() {
        let formatted = SpokenStructureFormatter.formatExplicitNumbering(
            in: "Ok donc là j'essaye de faire une transcription avec le nouveau Parrot. Donc ce que j'aimerais qu'il fasse c'est: petit 1, qu'il soit capable de mettre à la ligne, petit 2, qu'il ait le modèle local le plus intelligent possible et petit 3, qu'il puisse parfaitement envoyer des commandes complètes à Codex."
        )

        XCTAssertEqual(
            formatted,
            """
            Ok donc là j'essaye de faire une transcription avec le nouveau Parrot. Donc ce que j'aimerais qu'il fasse c'est:

            1. Qu'il soit capable de mettre à la ligne.

            2. Qu'il ait le modèle local le plus intelligent possible.

            3. Qu'il puisse parfaitement envoyer des commandes complètes à Codex.
            """
        )
    }

    func testOneSpokenNumberDoesNotInventAList() {
        XCTAssertNil(SpokenStructureFormatter.formatExplicitNumbering(
            in: "Je voudrais savoir si le petit 1 marche bien."
        ))
    }

    func testNonSequentialSpokenPointsStayFaithful() {
        XCTAssertNil(SpokenStructureFormatter.formatExplicitNumbering(
            in: "Je veux revoir le point 12 puis le point 15 demain."
        ))
    }

}
