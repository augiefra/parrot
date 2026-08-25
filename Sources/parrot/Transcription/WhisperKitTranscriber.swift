import Foundation
import WhisperKit

actor WhisperKitTranscriber: Transcriber, TimedTranscriber {
    /// This installation is intentionally French-only. Being explicit also
    /// prevents WhisperKit's default language prefill from falling back to
    /// English for short or ambiguous utterances.
    static let frenchDecodingOptions = DecodingOptions(
        task: .transcribe,
        language: "fr",
        usePrefillPrompt: true,
        detectLanguage: false,
        withoutTimestamps: false
    )

    /// File transcription uses WhisperKit's own VAD chunker with a single
    /// worker. Keeping the live decoding contract separate avoids changing Fn
    /// dictation while preventing long media from monopolising several Core ML
    /// workers at once on the shared, already-warmed pipeline.
    static let frenchFileDecodingOptions = DecodingOptions(
        task: .transcribe,
        language: "fr",
        usePrefillPrompt: true,
        detectLanguage: false,
        withoutTimestamps: false,
        concurrentWorkerCount: 1,
        chunkingStrategy: .vad
    )

    /// Keep model weights out of Documents, where iCloud File Provider can
    /// upload or evict them. Application Support is stable across login and is
    /// not treated as user-authored content.
    private static let modelStore = URL.applicationSupportDirectory
        .appending(path: "parrot/huggingface")

    /// Older builds used WhisperKit's default under ~/Documents. Report a
    /// leftover store so it can be reclaimed after the new one is validated.
    private static let legacyModelStore = URL.documentsDirectory
        .appending(path: "huggingface")

    let modelID: String
    private let model: TranscriptionModel
    private var pipeline: WhisperKit?

    init(model: TranscriptionModel) {
        self.modelID = model.id
        self.model = model
        _ = LocalDictionary.loadOrCreateDefault()
    }

    /// Loads the model into memory; downloads first if not already on disk.
    /// Call once at startup so the first hotkey press isn't blocked on model
    /// download/load.
    func warmUp() async throws {
        if pipeline != nil { return }
        guard let whisperKitID = model.whisperKitID else {
            throw TranscriberError.missingEngineID
        }
        Self.noteLegacyStore()
        FileHandle.standardError.write(Data("loading \(model.id)...\n".utf8))
        let config = WhisperKitConfig(
            model: whisperKitID,
            downloadBase: Self.modelStore,
            verbose: false,
            prewarm: true,
            load: true
        )
        pipeline = try await WhisperKit(config)
        FileHandle.standardError.write(Data("✓ \(model.id) ready · language: fr\n".utf8))
    }

    private static func noteLegacyStore() {
        let legacyPath = legacyModelStore.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: legacyPath) else { return }

        let currentPath = modelStore.path(percentEncoded: false)
        FileHandle.standardError.write(Data(
            "legacy model cache detected at \(legacyPath); models now use \(currentPath)\n".utf8
        ))
    }

    func transcribe(_ audio: [Float]) async throws -> String {
        let results = try await decode(
            audio,
            options: Self.frenchDecodingOptions,
            progress: nil
        )
        let raw = results.map(\.text).joined(separator: " ")
        // This file is tiny; reloading it lets a saved edit take effect for the
        // very next dictation without restarting the daemon.
        return LocalDictionary.loadOrCreateDefault().apply(to: Self.sanitize(raw))
    }

    func transcribeSegments(
        _ audio: [Float],
        progress: TimedTranscriptionProgressHandler?
    ) async throws -> [TimedTranscriptSegment] {
        let results = try await decode(
            audio,
            options: Self.frenchFileDecodingOptions,
            progress: progress
        )
        let dictionary = LocalDictionary.loadOrCreateDefault()

        return results.flatMap { result in
            result.segments.map { segment in
                TimedTranscriptSegment(
                    start: TimeInterval(segment.start),
                    end: TimeInterval(segment.end),
                    text: dictionary.apply(to: Self.sanitize(segment.text))
                )
            }
        }
    }

    private func decode(
        _ audio: [Float],
        options: DecodingOptions,
        progress reportProgress: TimedTranscriptionProgressHandler?
    ) async throws -> [TranscriptionResult] {
        if pipeline == nil { try await warmUp() }
        guard let pipeline else { throw TranscriberError.notLoaded }

        let whisperProgress = pipeline.progress
        reportProgress?(TimedTranscriptionProgress(fractionCompleted: 0))
        let callback: TranscriptionCallback?
        if let reportProgress {
            callback = { _ in
                reportProgress(
                    TimedTranscriptionProgress(
                        fractionCompleted: whisperProgress.fractionCompleted
                    )
                )
                return true
            }
        } else {
            callback = nil
        }

        let results = try await pipeline.transcribe(
            audioArray: audio,
            decodeOptions: options,
            callback: callback
        )
        reportProgress?(TimedTranscriptionProgress(fractionCompleted: 1))
        return results
    }

    /// Strip Whisper's non-speech bracket tokens ([BLANK_AUDIO], [MUSIC],
    /// (silence), <|nospeech|>, etc.) and collapse whitespace. When the model
    /// hears silence it emits these literally; we don't want to paste them.
    static func sanitize(_ text: String) -> String {
        let patterns = [
            #"\[[^\]]*\]"#,        // [BLANK_AUDIO], [MUSIC], [Applause]
            #"\([^)]*\)"#,          // (silence), (music playing)
            #"<\|[^|]*\|>"#,        // <|nospeech|>, <|endoftext|>
            #"\*[^*]*\*"#,          // *background noise*
        ]
        var out = text
        for p in patterns {
            out = out.replacingOccurrences(of: p, with: " ", options: .regularExpression)
        }
        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum TranscriberError: Error {
    case missingEngineID
    case notLoaded
}
