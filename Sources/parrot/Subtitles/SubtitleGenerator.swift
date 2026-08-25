import Foundation

struct SubtitlePaths: Equatable, Sendable {
    let input: URL
    let output: URL

    static func resolve(
        input inputPath: String,
        output outputPath: String?,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) -> SubtitlePaths {
        let input = resolve(inputPath, relativeTo: currentDirectory)
        let output = outputPath.map { resolve($0, relativeTo: currentDirectory) }
            ?? defaultOutput(for: input)
        return SubtitlePaths(input: input, output: output)
    }

    static func defaultOutput(for input: URL) -> URL {
        input.standardizedFileURL
            .deletingPathExtension()
            .appendingPathExtension("srt")
    }

    private static func resolve(_ path: String, relativeTo directory: URL) -> URL {
        let expanded = NSString(string: path).expandingTildeInPath
        return URL(fileURLWithPath: expanded, relativeTo: directory).standardizedFileURL
    }
}

struct SubtitleGenerationResult: Sendable {
    let output: URL
    let cueCount: Int
    let cues: [SRTCue]
    let mediaDuration: TimeInterval
    let decodedAudioDuration: TimeInterval
}

enum SubtitleGenerationProgress: Equatable, Sendable {
    case readingAudio(fractionCompleted: Double)
    case transcribing(fractionCompleted: Double)
    case writingSubtitles
}

typealias SubtitleGenerationProgressHandler = @Sendable (SubtitleGenerationProgress) -> Void

/// Shared local pipeline used by both the CLI and the menu-bar action.
struct SubtitleGenerator: Sendable {
    let transcriber: any TimedTranscriber

    func generate(
        input: URL,
        output: URL? = nil,
        progress: SubtitleGenerationProgressHandler? = nil
    ) async throws -> SubtitleGenerationResult {
        let paths = SubtitlePaths(
            input: input.standardizedFileURL,
            output: (output ?? SubtitlePaths.defaultOutput(for: input)).standardizedFileURL
        )
        try validate(paths)

        let media = try await MediaAudioLoader.load(from: paths.input) { fraction in
            progress?(.readingAudio(fractionCompleted: fraction))
        }
        progress?(.transcribing(fractionCompleted: 0))
        let segments = try await transcriber.transcribeSegments(media.samples) { update in
            progress?(.transcribing(fractionCompleted: update.fractionCompleted))
        }
        let cues = SRTFormatter.makeCues(
            from: segments,
            timelineOffset: media.timelineOffset,
            mediaDuration: media.duration
        )
        guard !cues.isEmpty else {
            throw SubtitleGenerationError.noTimedSpeech
        }

        progress?(.writingSubtitles)
        do {
            try Data(SRTFormatter.render(cues).utf8).write(to: paths.output, options: .atomic)
        } catch {
            throw SubtitleGenerationError.couldNotWrite(paths.output, error)
        }

        return SubtitleGenerationResult(
            output: paths.output,
            cueCount: cues.count,
            cues: cues,
            mediaDuration: media.duration,
            decodedAudioDuration: Double(media.samples.count) / MediaAudioLoader.sampleRate
        )
    }

    private func validate(_ paths: SubtitlePaths) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: paths.input.path, isDirectory: &isDirectory) else {
            throw SubtitleGenerationError.inputDoesNotExist(paths.input)
        }
        guard !isDirectory.boolValue else {
            throw SubtitleGenerationError.inputIsDirectory(paths.input)
        }
        guard paths.input != paths.output else {
            throw SubtitleGenerationError.outputMatchesInput
        }

        var outputDirectoryIsDirectory: ObjCBool = false
        let outputDirectory = paths.output.deletingLastPathComponent()
        guard FileManager.default.fileExists(
            atPath: outputDirectory.path,
            isDirectory: &outputDirectoryIsDirectory
        ), outputDirectoryIsDirectory.boolValue else {
            throw SubtitleGenerationError.outputDirectoryDoesNotExist(outputDirectory)
        }

        var outputIsDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: paths.output.path, isDirectory: &outputIsDirectory),
           outputIsDirectory.boolValue {
            throw SubtitleGenerationError.outputIsDirectory(paths.output)
        }
    }
}

enum SubtitleGenerationError: LocalizedError {
    case inputDoesNotExist(URL)
    case inputIsDirectory(URL)
    case outputMatchesInput
    case outputDirectoryDoesNotExist(URL)
    case outputIsDirectory(URL)
    case noTimedSpeech
    case couldNotWrite(URL, Error)

    var errorDescription: String? {
        switch self {
        case .inputDoesNotExist(let url):
            return "Input media does not exist: \(url.path)"
        case .inputIsDirectory(let url):
            return "Input path is a directory, not a media file: \(url.path)"
        case .outputMatchesInput:
            return "The SRT output path must differ from the input media path."
        case .outputDirectoryDoesNotExist(let url):
            return "Output directory does not exist: \(url.path)"
        case .outputIsDirectory(let url):
            return "The SRT output path is a directory: \(url.path)"
        case .noTimedSpeech:
            return "No timed speech segment was found; no SRT file was written."
        case .couldNotWrite(let url, let error):
            return "Could not write \(url.path): \(error.localizedDescription)"
        }
    }
}
