import AppKit
@preconcurrency import AVFoundation
import Foundation
import QuartzCore

struct CaptionedVideoResult: Sendable {
    let output: URL
    let cueCount: Int
}

enum CaptionedVideoProgress: Equatable, Sendable {
    case exporting(fractionCompleted: Double)
    case finalizing
}

/// Renders Parrot's timed cues into a separate, upload-ready MP4. The source
/// media is never modified, and the SRT remains available as an accessible
/// sidecar that viewers can enable or disable on platforms such as X.
@MainActor
enum CaptionedVideoRenderer {
    static let maximumWidthRatio = 0.78
    static let bottomSafeAreaRatio = 0.10

    static func defaultOutput(for input: URL) -> URL {
        let base = input.standardizedFileURL.deletingPathExtension()
        return base.deletingLastPathComponent()
            .appendingPathComponent("\(base.lastPathComponent)-sous-titree.mp4")
    }

    static func render(
        input: URL,
        cues: [SRTCue],
        output: URL? = nil,
        progress: ((CaptionedVideoProgress) -> Void)? = nil
    ) async throws -> CaptionedVideoResult {
        let input = input.standardizedFileURL
        let output = (output ?? defaultOutput(for: input)).standardizedFileURL
        try validate(input: input, output: output, cues: cues)
        progress?(.exporting(fractionCompleted: 0))

        let asset = AVURLAsset(url: input)
        let duration = try await asset.load(.duration)
        guard duration.isNumeric, CMTimeGetSeconds(duration) > 0 else {
            throw CaptionedVideoError.invalidDuration
        }
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw CaptionedVideoError.noVideoTrack(input)
        }

        let composition = try await makeVideoComposition(
            videoTrack: videoTrack,
            duration: duration
        )
        guard composition.renderSize.width > 0, composition.renderSize.height > 0 else {
            throw CaptionedVideoError.invalidRenderSize
        }
        composition.animationTool = try animationTool(
            cues: cues,
            renderSize: composition.renderSize
        )

        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw CaptionedVideoError.couldNotCreateExporter
        }
        guard exporter.supportedFileTypes.contains(.mp4) else {
            throw CaptionedVideoError.mp4ExportUnsupported
        }

        exporter.videoComposition = composition
        exporter.shouldOptimizeForNetworkUse = true

        let temporaryOutput = output
            .deletingLastPathComponent()
            .appendingPathComponent(".parrot-captioned-\(UUID().uuidString).mp4")

        do {
            try await export(exporter, to: temporaryOutput) { fraction in
                progress?(.exporting(fractionCompleted: fraction))
            }
            progress?(.finalizing)
            try install(temporaryOutput, at: output)
        } catch {
            try? FileManager.default.removeItem(at: temporaryOutput)
            if let error = error as? CaptionedVideoError { throw error }
            throw CaptionedVideoError.exportFailed(error)
        }

        return CaptionedVideoResult(output: output, cueCount: cues.count)
    }

    private static func validate(input: URL, output: URL, cues: [SRTCue]) throws {
        guard !cues.isEmpty else { throw CaptionedVideoError.noCues }
        guard input != output else { throw CaptionedVideoError.outputMatchesInput }
        guard output.pathExtension.lowercased() == "mp4" else {
            throw CaptionedVideoError.outputMustBeMP4(output)
        }

        var outputDirectoryIsDirectory: ObjCBool = false
        let outputDirectory = output.deletingLastPathComponent()
        guard FileManager.default.fileExists(
            atPath: outputDirectory.path,
            isDirectory: &outputDirectoryIsDirectory
        ), outputDirectoryIsDirectory.boolValue else {
            throw CaptionedVideoError.outputDirectoryDoesNotExist(outputDirectory)
        }

        var outputIsDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: output.path, isDirectory: &outputIsDirectory),
           outputIsDirectory.boolValue {
            throw CaptionedVideoError.outputIsDirectory(output)
        }
    }

    private static func makeVideoComposition(
        videoTrack: AVAssetTrack,
        duration: CMTime
    ) async throws -> AVMutableVideoComposition {
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        let transformedBounds = CGRect(origin: .zero, size: naturalSize)
            .applying(preferredTransform)
        let renderSize = CGSize(
            width: abs(transformedBounds.width),
            height: abs(transformedBounds.height)
        )
        guard renderSize.width > 0, renderSize.height > 0 else {
            throw CaptionedVideoError.invalidRenderSize
        }

        // Build an explicit instruction instead of a passthrough composition:
        // passthrough video can legally skip Core Animation post-processing,
        // which would export a valid MP4 without the captions.
        let normalizedTransform = preferredTransform.concatenating(
            CGAffineTransform(
                translationX: -transformedBounds.minX,
                y: -transformedBounds.minY
            )
        )
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(
            assetTrack: videoTrack
        )
        layerInstruction.setTransform(normalizedTransform, at: .zero)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.enablePostProcessing = true
        instruction.layerInstructions = [layerInstruction]

        let composition = AVMutableVideoComposition()
        composition.renderSize = renderSize
        // Core Animation post-processing is unreliable below 30 fps on some
        // macOS/AVFoundation combinations. Keep high-frame-rate sources intact
        // while using a stable 30 fps floor for lower-rate media.
        let frameRate = nominalFrameRate.isFinite && nominalFrameRate > 0
            ? min(120, max(30, Int32(nominalFrameRate.rounded())))
            : 30
        composition.frameDuration = CMTime(value: 1, timescale: frameRate)
        composition.instructions = [instruction]
        return composition
    }

    private static func animationTool(
        cues: [SRTCue],
        renderSize: CGSize
    ) throws -> AVVideoCompositionCoreAnimationTool {
        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: renderSize)
        parentLayer.isGeometryFlipped = false

        let videoLayer = CALayer()
        videoLayer.frame = parentLayer.bounds
        parentLayer.addSublayer(videoLayer)

        let captionsLayer = CALayer()
        captionsLayer.frame = parentLayer.bounds
        parentLayer.addSublayer(captionsLayer)

        for cue in cues {
            captionsLayer.addSublayer(
                try captionLayer(for: cue, renderSize: renderSize)
            )
        }

        return AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer
        )
    }

    private static func captionLayer(
        for cue: SRTCue,
        renderSize: CGSize
    ) throws -> CALayer {
        let shortestEdge = min(renderSize.width, renderSize.height)
        let fontSize = max(24, shortestEdge * 0.052)
        let font = roundedSystemFont(size: fontSize)
        let horizontalPadding = fontSize * 0.52
        let verticalPadding = fontSize * 0.30
        let maximumTextWidth = renderSize.width * maximumWidthRatio - horizontalPadding * 2

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = fontSize * 0.05

        let attributedText = NSAttributedString(
            string: cue.text,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraph,
                .kern: fontSize * 0.005,
            ]
        )
        let measured = attributedText.boundingRect(
            with: CGSize(width: maximumTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).integral.size

        let containerWidth = min(
            renderSize.width * maximumWidthRatio,
            ceil(measured.width) + horizontalPadding * 2
        )
        let containerHeight = ceil(measured.height) + verticalPadding * 2
        let container = CALayer()
        container.frame = CGRect(
            x: (renderSize.width - containerWidth) / 2,
            y: renderSize.height * bottomSafeAreaRatio,
            width: containerWidth,
            height: containerHeight
        )
        container.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        container.cornerRadius = min(fontSize * 0.42, containerHeight * 0.24)
        container.shadowColor = NSColor.black.cgColor
        container.shadowOpacity = 0.34
        container.shadowRadius = fontSize * 0.14
        container.shadowOffset = CGSize(width: 0, height: -fontSize * 0.04)
        container.opacity = 0

        let textSize = CGSize(
            width: containerWidth - horizontalPadding * 2,
            height: containerHeight - verticalPadding * 2
        )
        let textLayer = CALayer()
        textLayer.frame = CGRect(
            x: horizontalPadding,
            y: verticalPadding,
            width: textSize.width,
            height: textSize.height
        )
        let rasterScale = min(2, max(1, 2_160 / shortestEdge))
        guard let textImage = rasterizedText(
            attributedText,
            size: textSize,
            scale: rasterScale
        ) else {
            throw CaptionedVideoError.couldNotRenderCaptionText(cue.index)
        }
        textLayer.contentsScale = rasterScale
        textLayer.contentsGravity = .resize
        textLayer.contents = textImage
        container.addSublayer(textLayer)

        let start = Double(cue.startMilliseconds) / 1_000
        let duration = max(0.001, Double(cue.endMilliseconds - cue.startMilliseconds) / 1_000)
        let fadeDuration = min(0.12, duration * 0.20)
        let fadeFraction = fadeDuration / duration
        let visibility = CAKeyframeAnimation(keyPath: "opacity")
        visibility.values = [0, 1, 1, 0]
        visibility.keyTimes = [0, NSNumber(value: fadeFraction), NSNumber(value: 1 - fadeFraction), 1]
        visibility.beginTime = AVCoreAnimationBeginTimeAtZero + start
        visibility.duration = duration
        visibility.fillMode = .both
        visibility.isRemovedOnCompletion = false
        container.add(visibility, forKey: "captionVisibility")

        return container
    }

    /// CATextLayer is not reliably rendered by AVFoundation's offline Core
    /// Animation compositor on every macOS release. Rasterizing just the text
    /// keeps the typography deterministic while the surrounding pill remains
    /// resolution-independent Core Animation geometry.
    private static func rasterizedText(
        _ attributedText: NSAttributedString,
        size: CGSize,
        scale: CGFloat
    ) -> CGImage? {
        guard scale > 0, size.width > 0, size.height > 0,
              let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: max(1, Int(ceil(size.width * scale))),
                pixelsHigh: max(1, Int(ceil(size.height * scale))),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
              ),
              let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else { return nil }

        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        let bounds = CGRect(origin: .zero, size: size)
        NSColor.clear.setFill()
        bounds.fill(using: .copy)
        attributedText.draw(
            with: bounds,
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.cgImage
    }

    private static func roundedSystemFont(size: CGFloat) -> NSFont {
        let system = NSFont.systemFont(ofSize: size, weight: .semibold)
        guard let descriptor = system.fontDescriptor.withDesign(.rounded) else {
            return system
        }
        return NSFont(descriptor: descriptor, size: size) ?? system
    }

    private static func export(
        _ exporter: AVAssetExportSession,
        to output: URL,
        progress: ((Double) -> Void)?
    ) async throws {
        let progressTask = Task { @MainActor in
            var lastReportedProgress = -1.0
            while !Task.isCancelled {
                let currentProgress = Double(exporter.progress)
                if currentProgress - lastReportedProgress >= 0.002 {
                    lastReportedProgress = currentProgress
                    progress?(currentProgress)
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { progressTask.cancel() }

        if #available(macOS 15.0, *) {
            try await exporter.export(to: output, as: .mp4)
            return
        }

        exporter.outputURL = output
        exporter.outputFileType = .mp4
        let exporterBox = SendableExporter(exporter)
        try await withCheckedThrowingContinuation { continuation in
            exporterBox.value.exportAsynchronously {
                switch exporterBox.value.status {
                case .completed:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                default:
                    continuation.resume(
                        throwing: exporterBox.value.error
                            ?? CaptionedVideoError.unknownExportFailure
                    )
                }
            }
        }
    }

    private static func install(_ temporaryOutput: URL, at output: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: output.path) {
            _ = try fileManager.replaceItemAt(output, withItemAt: temporaryOutput)
        } else {
            try fileManager.moveItem(at: temporaryOutput, to: output)
        }
    }
}

private final class SendableExporter: @unchecked Sendable {
    let value: AVAssetExportSession

    init(_ value: AVAssetExportSession) {
        self.value = value
    }
}

enum CaptionedVideoError: LocalizedError {
    case noCues
    case noVideoTrack(URL)
    case invalidDuration
    case invalidRenderSize
    case couldNotRenderCaptionText(Int)
    case outputMatchesInput
    case outputMustBeMP4(URL)
    case outputDirectoryDoesNotExist(URL)
    case outputIsDirectory(URL)
    case couldNotCreateVideoComposition(Error?)
    case couldNotCreateExporter
    case mp4ExportUnsupported
    case exportFailed(Error)
    case unknownExportFailure

    var errorDescription: String? {
        switch self {
        case .noCues:
            return "No subtitle cue is available to render."
        case .noVideoTrack(let url):
            return "No video track was found in \(url.path)."
        case .invalidDuration:
            return "The source video has no valid duration."
        case .invalidRenderSize:
            return "AVFoundation could not determine a valid video size."
        case .couldNotRenderCaptionText(let index):
            return "Could not render the styled text for subtitle cue \(index)."
        case .outputMatchesInput:
            return "The captioned video must not replace the source video."
        case .outputMustBeMP4(let url):
            return "The captioned video output must use the .mp4 extension: \(url.path)"
        case .outputDirectoryDoesNotExist(let url):
            return "Output directory does not exist: \(url.path)"
        case .outputIsDirectory(let url):
            return "The captioned video output is a directory: \(url.path)"
        case .couldNotCreateVideoComposition(let error):
            return "Could not prepare the video composition: \(error?.localizedDescription ?? "unknown AVFoundation error")"
        case .couldNotCreateExporter:
            return "AVFoundation could not create a video exporter."
        case .mp4ExportUnsupported:
            return "AVFoundation cannot export this source video as MP4."
        case .exportFailed(let error):
            return "Captioned video export failed: \(error.localizedDescription)"
        case .unknownExportFailure:
            return "Captioned video export failed for an unknown reason."
        }
    }
}
