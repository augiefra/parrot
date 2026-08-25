import AVFoundation
import CoreMedia
import Foundation

struct MediaAudio: Sendable {
    let samples: [Float]
    let duration: TimeInterval
    let timelineOffset: TimeInterval
}

/// Decodes the first audio track with AVFoundation and converts it to the same
/// 16 kHz mono Float32 format used by live Parrot dictation.
enum MediaAudioLoader {
    static let sampleRate = 16_000.0

    static func load(
        from url: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> MediaAudio {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = tracks.first else {
            throw MediaAudioError.noAudioTrack(url)
        }

        let assetDuration = try await asset.load(.duration)
        let assetDurationSeconds = seconds(assetDuration).flatMap { $0 > 0 ? $0 : nil }
        progress?(0)
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw MediaAudioError.couldNotCreateReader(error)
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else {
            throw MediaAudioError.unsupportedAudioTrack
        }
        reader.add(output)
        guard reader.startReading() else {
            throw MediaAudioError.readerFailed(reader.error)
        }

        var samples: [Float] = []
        var firstPresentationTime: TimeInterval?
        var lastReportedFraction = 0.0

        while let sampleBuffer = output.copyNextSampleBuffer() {
            let presentationTime = seconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            if firstPresentationTime == nil, let presentationTime {
                firstPresentationTime = presentationTime
            }

            if let presentationTime, let assetDurationSeconds {
                let fraction = min(1, max(0, presentationTime / assetDurationSeconds))
                if fraction - lastReportedFraction >= 0.01 {
                    lastReportedFraction = fraction
                    progress?(fraction)
                }
            }

            guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                throw MediaAudioError.missingSampleData
            }
            let byteCount = CMBlockBufferGetDataLength(dataBuffer)
            guard byteCount.isMultiple(of: MemoryLayout<Float>.size) else {
                throw MediaAudioError.invalidSampleData(byteCount)
            }

            var chunk = [Float](
                repeating: 0,
                count: byteCount / MemoryLayout<Float>.size
            )
            let copyStatus = chunk.withUnsafeMutableBytes { bytes -> OSStatus in
                guard let destination = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
                return CMBlockBufferCopyDataBytes(
                    dataBuffer,
                    atOffset: 0,
                    dataLength: byteCount,
                    destination: destination
                )
            }
            guard copyStatus == kCMBlockBufferNoErr else {
                throw MediaAudioError.couldNotCopySamples(copyStatus)
            }

            append(
                chunk,
                presentedAt: presentationTime,
                firstPresentationTime: firstPresentationTime,
                to: &samples
            )
        }

        guard reader.status == .completed else {
            throw MediaAudioError.readerFailed(reader.error)
        }
        guard !samples.isEmpty else {
            throw MediaAudioError.emptyAudio
        }
        progress?(1)

        let timelineOffset = max(0, firstPresentationTime ?? 0)
        let decodedAudioEnd = timelineOffset + Double(samples.count) / sampleRate
        let loadedDuration = assetDurationSeconds
        let duration = loadedDuration.flatMap { $0 > 0 ? $0 : nil } ?? decodedAudioEnd

        return MediaAudio(
            samples: samples,
            duration: max(duration, timelineOffset),
            timelineOffset: timelineOffset
        )
    }

    /// Preserve gaps and avoid duplicating overlapping buffers so sample
    /// offsets remain aligned with the media timeline after decoding.
    private static func append(
        _ chunk: [Float],
        presentedAt presentationTime: TimeInterval?,
        firstPresentationTime: TimeInterval?,
        to samples: inout [Float]
    ) {
        guard
            let presentationTime,
            let firstPresentationTime,
            presentationTime.isFinite,
            firstPresentationTime.isFinite
        else {
            samples.append(contentsOf: chunk)
            return
        }

        let relativeTime = max(0, presentationTime - firstPresentationTime)
        let expectedStart = Int((relativeTime * sampleRate).rounded())

        if expectedStart > samples.count {
            samples.append(contentsOf: repeatElement(0, count: expectedStart - samples.count))
            samples.append(contentsOf: chunk)
            return
        }

        let overlap = samples.count - expectedStart
        guard overlap < chunk.count else { return }
        samples.append(contentsOf: chunk.dropFirst(overlap))
    }

    private static func seconds(_ time: CMTime) -> TimeInterval? {
        guard time.isNumeric else { return nil }
        let value = CMTimeGetSeconds(time)
        return value.isFinite ? value : nil
    }
}

enum MediaAudioError: LocalizedError {
    case noAudioTrack(URL)
    case couldNotCreateReader(Error)
    case unsupportedAudioTrack
    case readerFailed(Error?)
    case missingSampleData
    case invalidSampleData(Int)
    case couldNotCopySamples(OSStatus)
    case emptyAudio

    var errorDescription: String? {
        switch self {
        case .noAudioTrack(let url):
            return "No audio track found in \(url.path)."
        case .couldNotCreateReader(let error):
            return "Could not open the media with AVFoundation: \(error.localizedDescription)"
        case .unsupportedAudioTrack:
            return "AVFoundation cannot decode this audio track as 16 kHz mono PCM."
        case .readerFailed(let error):
            return "Audio decoding failed: \(error?.localizedDescription ?? "unknown AVFoundation error")"
        case .missingSampleData:
            return "AVFoundation returned an audio sample without PCM data."
        case .invalidSampleData(let byteCount):
            return "AVFoundation returned \(byteCount) bytes that are not valid Float32 PCM."
        case .couldNotCopySamples(let status):
            return "Could not copy decoded PCM samples (CoreMedia status \(status))."
        case .emptyAudio:
            return "The media audio track is empty."
        }
    }
}
