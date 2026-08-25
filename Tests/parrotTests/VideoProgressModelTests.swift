import AppKit
import SwiftUI
import XCTest
@testable import parrot

@MainActor
final class VideoProgressModelTests: XCTestCase {
    func testReadyForXReportsRealStagesElapsedTimeAndDelay() throws {
        let model = VideoProgressModel()
        let start = Date(timeIntervalSince1970: 1_000)
        model.begin(
            kind: .readyForX,
            input: URL(fileURLWithPath: "/tmp/voix.mov"),
            now: start
        )

        model.apply(
            .transcribing(fractionCompleted: 0.42),
            now: start.addingTimeInterval(10)
        )

        let snapshot = try XCTUnwrap(model.snapshot)
        XCTAssertEqual(snapshot.stage, .transcribing)
        XCTAssertEqual(snapshot.stageNumber, 2)
        XCTAssertEqual(snapshot.kind.stageCount, 5)
        XCTAssertEqual(try XCTUnwrap(snapshot.fractionCompleted), 0.42, accuracy: 0.001)
        XCTAssertEqual(snapshot.elapsed(at: start.addingTimeInterval(75)), 75)
        XCTAssertFalse(snapshot.isDelayed(at: start.addingTimeInterval(69)))
        XCTAssertTrue(snapshot.isDelayed(at: start.addingTimeInterval(70)))
    }

    func testLateProgressCallbackCannotRegressACompletedStage() throws {
        let model = VideoProgressModel()
        let start = Date(timeIntervalSince1970: 2_000)
        model.begin(
            kind: .readyForX,
            input: URL(fileURLWithPath: "/tmp/voix.mov"),
            now: start
        )
        model.apply(.writingSubtitles, now: start.addingTimeInterval(1))
        model.apply(
            .transcribing(fractionCompleted: 0.9),
            now: start.addingTimeInterval(2)
        )

        XCTAssertEqual(model.snapshot?.stage, .writingSubtitles)

        let video = URL(fileURLWithPath: "/tmp/voix-sous-titree.mp4")
        let srt = URL(fileURLWithPath: "/tmp/voix.srt")
        model.complete(outputs: [video, srt], now: start.addingTimeInterval(3))
        model.apply(.readingAudio(fractionCompleted: 1), now: start.addingTimeInterval(4))

        let completed = try XCTUnwrap(model.snapshot)
        XCTAssertEqual(completed.stage, .completed)
        XCTAssertEqual(completed.outputs, [video, srt])
        XCTAssertFalse(completed.isRunning)
    }

    func testFailureKeepsAPreviouslyWrittenSRTVisible() throws {
        struct RenderError: LocalizedError {
            var errorDescription: String? { "Export vidéo interrompu" }
        }

        let model = VideoProgressModel()
        model.begin(
            kind: .readyForX,
            input: URL(fileURLWithPath: "/tmp/voix.mov")
        )
        let srt = URL(fileURLWithPath: "/tmp/voix.srt")
        model.fail(RenderError(), retainedOutputs: [srt])

        let snapshot = try XCTUnwrap(model.snapshot)
        XCTAssertEqual(snapshot.stage, .failed)
        XCTAssertEqual(snapshot.outputs, [srt])
        XCTAssertTrue(snapshot.detail.contains("SRT déjà créé"))
    }

    func testProgressWindowRendersAtItsFixedNativeSize() throws {
        let model = VideoProgressModel()
        let start = Date(timeIntervalSinceNow: -74)
        model.begin(
            kind: .readyForX,
            input: URL(fileURLWithPath: "/Users/demo/Desktop/Présentation FacilAbo.mov"),
            now: start
        )
        model.apply(
            .transcribing(fractionCompleted: 0.42),
            now: Date(timeIntervalSinceNow: -8)
        )

        let hostingView = NSHostingView(
            rootView: VideoProgressView(model: model, onReveal: {}, onHide: {})
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 470, height: 330)
        hostingView.layoutSubtreeIfNeeded()

        let representation = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 10_000)

        if let previewPath = ProcessInfo.processInfo.environment["PARROT_PROGRESS_PREVIEW_PATH"] {
            try png.write(to: URL(fileURLWithPath: previewPath), options: .atomic)
        }
    }
}
