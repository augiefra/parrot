import AppKit
@preconcurrency import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import XCTest
@testable import parrot

@MainActor
final class CaptionedVideoRendererTests: XCTestCase {
    func testDefaultOutputKeepsSourceAndAddsCaptionedSuffix() {
        let input = URL(fileURLWithPath: "/tmp/demo.final.mov")

        XCTAssertEqual(
            CaptionedVideoRenderer.defaultOutput(for: input).path,
            "/tmp/demo.final-sous-titree.mp4"
        )
    }

    func testRendersVisibleStyledCaptionsIntoASeparateMP4() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-caption-renderer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let input = directory.appendingPathComponent("source.mov")
        let output = directory.appendingPathComponent("source-sous-titree.mp4")
        try await makeSyntheticVideo(at: input)
        let sourceSizeBeforeRender = try fileSize(input)

        var progressEvents: [CaptionedVideoProgress] = []
        let result = try await CaptionedVideoRenderer.render(
            input: input,
            cues: [
                SRTCue(
                    index: 1,
                    startMilliseconds: 100,
                    endMilliseconds: 1_800,
                    text: "FacilAbo reste lisible\nsur une vidéo mobile"
                ),
            ],
            output: output,
            progress: { progressEvents.append($0) }
        )

        XCTAssertEqual(result.output, output)
        XCTAssertEqual(result.cueCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: input.path))
        XCTAssertEqual(try fileSize(input), sourceSizeBeforeRender)
        XCTAssertGreaterThan(try fileSize(output), 0)
        XCTAssertEqual(progressEvents.first, .exporting(fractionCompleted: 0))
        XCTAssertTrue(progressEvents.contains(.finalizing))

        let outputAsset = AVURLAsset(url: output)
        let videoTracks = try await outputAsset.loadTracks(withMediaType: .video)
        XCTAssertFalse(videoTracks.isEmpty)
        let duration = try await outputAsset.load(.duration)
        XCTAssertGreaterThan(CMTimeGetSeconds(duration), 1.5)

        let generator = AVAssetImageGenerator(asset: outputAsset)
        generator.appliesPreferredTrackTransform = true
        let (captionedFrame, _) = try await generator.image(
            at: CMTime(seconds: 1, preferredTimescale: 600)
        )
        let luminance = try luminanceRange(of: captionedFrame)
        XCTAssertLessThan(luminance.minimum, 20)
        XCTAssertGreaterThan(luminance.maximum, 220)

        let (frameAfterCue, _) = try await generator.image(
            at: CMTime(seconds: 1.9, preferredTimescale: 600)
        )
        let afterCueLuminance = try luminanceRange(of: frameAfterCue)
        XCTAssertLessThan(
            Int(afterCueLuminance.maximum) - Int(afterCueLuminance.minimum),
            12
        )

        if let previewPath = ProcessInfo.processInfo.environment["PARROT_CAPTION_PREVIEW_PATH"] {
            try writePNG(captionedFrame, to: URL(fileURLWithPath: previewPath))
        }
    }

    func testConfiguredRealMediaExport() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let inputPath = environment["PARROT_REAL_MEDIA_PATH"] else {
            throw XCTSkip("Set PARROT_REAL_MEDIA_PATH to run the opt-in real-media smoke test.")
        }

        let input = URL(fileURLWithPath: inputPath).standardizedFileURL
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-real-media-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("real-sous-titree.mp4")

        let sourceAsset = AVURLAsset(url: input)
        let sourceDuration = try await sourceAsset.load(.duration)
        let sourceDurationSeconds = CMTimeGetSeconds(sourceDuration)
        guard sourceDurationSeconds > 2 else { throw TestVideoError.mediaTooShort }
        let cueEnd = min(Int64((sourceDurationSeconds * 1_000).rounded()) - 100, 4_000)

        _ = try await CaptionedVideoRenderer.render(
            input: input,
            cues: [
                SRTCue(
                    index: 1,
                    startMilliseconds: 500,
                    endMilliseconds: cueEnd,
                    text: "Aperçu des sous-titres Parrot\nprêts pour X"
                ),
            ],
            output: output
        )

        let outputAsset = AVURLAsset(url: output)
        let outputDuration = try await outputAsset.load(.duration)
        XCTAssertEqual(
            CMTimeGetSeconds(outputDuration),
            sourceDurationSeconds,
            accuracy: 0.1
        )
        let sourceAudioTracks = try await sourceAsset.loadTracks(withMediaType: .audio)
        let outputAudioTracks = try await outputAsset.loadTracks(withMediaType: .audio)
        if !sourceAudioTracks.isEmpty { XCTAssertFalse(outputAudioTracks.isEmpty) }

        let sourceGenerator = AVAssetImageGenerator(asset: sourceAsset)
        sourceGenerator.appliesPreferredTrackTransform = true
        let outputGenerator = AVAssetImageGenerator(asset: outputAsset)
        outputGenerator.appliesPreferredTrackTransform = true
        let inspectionTime = CMTime(seconds: 2, preferredTimescale: 600)
        let (sourceFrame, _) = try await sourceGenerator.image(at: inspectionTime)
        let (outputFrame, _) = try await outputGenerator.image(at: inspectionTime)
        let sourceAspectRatio = Double(sourceFrame.width) / Double(sourceFrame.height)
        let outputAspectRatio = Double(outputFrame.width) / Double(outputFrame.height)
        XCTAssertEqual(outputAspectRatio, sourceAspectRatio, accuracy: 0.002)

        // AVAssetExportPresetHighestQuality can normalize captures slightly
        // wider than 4K to 3840 px. Require a uniform, modest scale rather than
        // pixel identity while still catching rotation or accidental resizing.
        let widthScale = Double(outputFrame.width) / Double(sourceFrame.width)
        let heightScale = Double(outputFrame.height) / Double(sourceFrame.height)
        XCTAssertEqual(widthScale, heightScale, accuracy: 0.002)
        XCTAssertGreaterThanOrEqual(widthScale, 0.90)
        XCTAssertLessThanOrEqual(widthScale, 1.01)

        if let previewPath = environment["PARROT_REAL_PREVIEW_PATH"] {
            try writePNG(outputFrame, to: URL(fileURLWithPath: previewPath))
        }
    }

    private func makeSyntheticVideo(at output: URL) async throws {
        let width = 640
        let height = 360
        let frameRate: Int32 = 15
        let frameCount = 30
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ]
        )
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )

        guard writer.canAdd(input) else { throw TestVideoError.couldNotAddInput }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? TestVideoError.couldNotStartWriter
        }
        writer.startSession(atSourceTime: .zero)

        guard let pixelBufferPool = adaptor.pixelBufferPool else {
            throw TestVideoError.missingPixelBufferPool
        }
        for frameIndex in 0..<frameCount {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            var pixelBuffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &pixelBuffer) == kCVReturnSuccess,
                  let pixelBuffer
            else {
                throw TestVideoError.couldNotCreatePixelBuffer
            }
            fill(pixelBuffer, withBGRA: 0xFF_4A_32_24)
            let presentationTime = CMTime(value: Int64(frameIndex), timescale: frameRate)
            guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                throw writer.error ?? TestVideoError.couldNotAppendFrame
            }
        }

        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw writer.error ?? TestVideoError.couldNotFinishWriter
        }
    }

    private func fill(_ pixelBuffer: CVPixelBuffer, withBGRA color: UInt32) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let address = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }

        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixelsPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer) / MemoryLayout<UInt32>.size
        address.assumingMemoryBound(to: UInt32.self)
            .initialize(repeating: color, count: pixelsPerRow * height)
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func luminanceRange(of image: CGImage) throws -> (minimum: UInt8, maximum: UInt8) {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw TestVideoError.couldNotReadFrame
        }

        let rendered = pixels.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(
                data: storage.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { throw TestVideoError.couldNotReadFrame }

        var minimum = UInt8.max
        var maximum = UInt8.min
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let red = Double(pixels[offset])
            let green = Double(pixels[offset + 1])
            let blue = Double(pixels[offset + 2])
            let value = UInt8(clamping: Int((0.2126 * red + 0.7152 * green + 0.0722 * blue).rounded()))
            minimum = min(minimum, value)
            maximum = max(maximum, value)
        }
        return (minimum, maximum)
    }

    private func writePNG(_ image: CGImage, to output: URL) throws {
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw TestVideoError.couldNotReadFrame
        }
        try png.write(to: output, options: .atomic)
    }
}

private enum TestVideoError: Error {
    case couldNotAddInput
    case couldNotStartWriter
    case missingPixelBufferPool
    case couldNotCreatePixelBuffer
    case couldNotAppendFrame
    case couldNotFinishWriter
    case couldNotReadFrame
    case mediaTooShort
}
