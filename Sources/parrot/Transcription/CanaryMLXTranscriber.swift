import Foundation

/// French-only local transcription through CogniSoftOrg's Apple-Silicon MLX
/// conversion of NVIDIA Canary 1B v2.
///
/// MLX is hosted in a small persistent Python worker rather than spawning a
/// process on every Fn release. The worker loads the model once, then receives
/// a temporary WAV path for each serial transcription request.
actor CanaryMLXTranscriber: Transcriber {
    nonisolated let modelID = "canary-1b-v2-mlx-bf16"

    private let configuration: Configuration
    private var worker: CanaryWorker?

    init(configuration: Configuration = .localDefault) {
        self.configuration = configuration
    }

    func warmUp() async throws {
        _ = try await activeWorker()
    }

    func transcribe(_ audio: [Float]) async throws -> String {
        guard !audio.isEmpty else { return "" }

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-canary-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        try WAVWriter.write(
            samples: audio,
            sampleRate: Int(AudioCapture.targetSampleRate),
            to: temporaryURL.path
        )

        do {
            let rawText = try await activeWorker().transcribe(audioURL: temporaryURL)
            return LocalDictionary.loadOrCreateDefault().apply(to: rawText)
        } catch {
            // A terminated worker is recoverable once. Keeping recovery here
            // avoids an intermittent Python failure taking down Fn dictation.
            worker = nil
            let rawText = try await activeWorker().transcribe(audioURL: temporaryURL)
            return LocalDictionary.loadOrCreateDefault().apply(to: rawText)
        }
    }

    private func activeWorker() async throws -> CanaryWorker {
        if let worker { return worker }
        let newWorker = CanaryWorker(configuration: configuration)
        try await newWorker.start()
        worker = newWorker
        return newWorker
    }
}

extension CanaryMLXTranscriber {
    struct Configuration: Sendable {
        let pythonURL: URL
        let workerURL: URL
        let modelURL: URL

        static var localDefault: Self {
            let support = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/parrot/canary-mlx")
            let workerCandidates = [
                Bundle.main.resourceURL?.appendingPathComponent("CanaryWorker.py"),
                URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent("Packaging/CanaryWorker.py"),
            ].compactMap { $0 }

            return Self(
                pythonURL: support.appendingPathComponent("venv/bin/python"),
                workerURL: workerCandidates.first ?? support.appendingPathComponent("CanaryWorker.py"),
                modelURL: support.appendingPathComponent("model")
            )
        }
    }
}

private actor CanaryWorker {
    private let configuration: CanaryMLXTranscriber.Configuration
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?

    init(configuration: CanaryMLXTranscriber.Configuration) {
        self.configuration = configuration
    }

    deinit {
        process?.terminate()
    }

    func start() async throws {
        guard process == nil else { return }
        guard FileManager.default.isExecutableFile(atPath: configuration.pythonURL.path) else {
            throw CanaryError.missingRuntime(configuration.pythonURL.path)
        }
        guard FileManager.default.fileExists(atPath: configuration.workerURL.path) else {
            throw CanaryError.missingWorker(configuration.workerURL.path)
        }
        guard FileManager.default.fileExists(atPath: configuration.modelURL.path) else {
            throw CanaryError.missingModel(configuration.modelURL.path)
        }

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let task = Process()
        task.executableURL = configuration.pythonURL
        task.arguments = [configuration.workerURL.path, "--model", configuration.modelURL.path]
        task.standardInput = inputPipe
        task.standardOutput = outputPipe
        task.standardError = FileHandle.standardError
        try task.run()

        process = task
        input = inputPipe.fileHandleForWriting
        output = outputPipe.fileHandleForReading

        let ready: WorkerResponse = try await readResponse()
        guard ready.event == "ready" else {
            stop()
            throw CanaryError.workerFailed(ready.error ?? "worker did not become ready")
        }
        let seconds = ready.seconds.map { String(format: "%.2f", $0) } ?? "?"
        FileHandle.standardError.write(Data("✓ Canary MLX ready · \(seconds)s · language: fr\n".utf8))
    }

    func transcribe(audioURL: URL) async throws -> String {
        guard let process, process.isRunning, let input else {
            throw CanaryError.workerFailed("worker is not running")
        }

        let identifier = UUID().uuidString
        let request = WorkerRequest(id: identifier, audioPath: audioURL.path)
        let data = try JSONEncoder().encode(request) + Data("\n".utf8)
        input.write(data)

        let response: WorkerResponse = try await readResponse()
        guard response.id == identifier else {
            throw CanaryError.workerFailed("worker response did not match its request")
        }
        if let error = response.error { throw CanaryError.workerFailed(error) }
        return response.text ?? ""
    }

    private func readResponse() async throws -> WorkerResponse {
        guard let output else { throw CanaryError.workerFailed("worker output is unavailable") }
        let line = try await readLine(from: output)
        do {
            return try JSONDecoder().decode(WorkerResponse.self, from: line)
        } catch {
            throw CanaryError.workerFailed("invalid worker response: \(error)")
        }
    }

    private func stop() {
        input?.closeFile()
        output?.closeFile()
        process?.terminate()
        input = nil
        output = nil
        process = nil
    }

    private func readLine(from handle: FileHandle) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    var result = Data()
                    while true {
                        guard let byte = try handle.read(upToCount: 1), !byte.isEmpty else {
                            throw CanaryError.workerFailed("worker closed its output")
                        }
                        if byte[byte.startIndex] == 0x0A { break }
                        result.append(byte)
                    }
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private struct WorkerRequest: Encodable {
    let id: String
    let audioPath: String
}

private struct WorkerResponse: Decodable {
    let id: String?
    let event: String?
    let text: String?
    let error: String?
    let seconds: Double?
}

private enum CanaryError: LocalizedError {
    case missingRuntime(String)
    case missingWorker(String)
    case missingModel(String)
    case workerFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingRuntime(let path): "Canary MLX runtime absent: \(path)"
        case .missingWorker(let path): "Canary MLX worker absent: \(path)"
        case .missingModel(let path): "Canary MLX model absent: \(path)"
        case .workerFailed(let detail): "Canary MLX worker failed: \(detail)"
        }
    }
}
