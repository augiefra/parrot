import Foundation

/// A transcription segment whose timestamps are relative to the beginning of
/// the supplied 16 kHz audio buffer.
struct TimedTranscriptSegment: Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

struct TimedTranscriptionProgress: Equatable, Sendable {
    let fractionCompleted: Double

    init(fractionCompleted: Double) {
        guard fractionCompleted.isFinite else {
            self.fractionCompleted = 0
            return
        }
        self.fractionCompleted = min(1, max(0, fractionCompleted))
    }
}

typealias TimedTranscriptionProgressHandler = @Sendable (TimedTranscriptionProgress) -> Void

/// Separate from `Transcriber` so the push-to-talk path keeps its existing,
/// text-only contract while file transcription can retain Whisper timestamps.
protocol TimedTranscriber: Sendable {
    func transcribeSegments(
        _ audio: [Float],
        progress: TimedTranscriptionProgressHandler?
    ) async throws -> [TimedTranscriptSegment]
}

extension TimedTranscriber {
    func transcribeSegments(_ audio: [Float]) async throws -> [TimedTranscriptSegment] {
        try await transcribeSegments(audio, progress: nil)
    }
}
