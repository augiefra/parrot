import ArgumentParser
import Foundation

struct Subtitles: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "subtitles",
        abstract: "Transcribe a local audio or video file to an SRT subtitle file."
    )

    @Argument(help: "Path to a local audio or video file (for example .mov or .mp4).")
    var input: String

    @Option(name: .long, help: "SRT destination. Defaults to the source path with a .srt extension.")
    var output: String?

    mutating func run() async throws {
        let paths = SubtitlePaths.resolve(input: input, output: output)

        guard let model = ModelRegistry.recommended() else {
            throw ValidationError("No recommended transcription model is registered.")
        }
        let transcriber = WhisperKitTranscriber(model: model)
        try await transcriber.warmUp()

        log("generating subtitles locally in French...")
        let result = try await SubtitleGenerator(transcriber: transcriber).generate(
            input: paths.input,
            output: paths.output
        )
        log(String(
            format: "✓ %.2fs of audio · %d cues",
            result.decodedAudioDuration,
            result.cueCount
        ))
        print(result.output.path)
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}
