import AppKit
import ArgumentParser
import Foundation

@main
struct Parrot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "parrot",
        abstract: "Minimal macOS dictation daemon. Hold Fn, speak, release.",
        subcommands: [
            Run.self, Setup.self, Doctor.self, Models.self, Install.self,
        ],
        defaultSubcommand: Run.self
    )
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the daemon (default)."
    )

    @Flag(name: .long, help: "Skip permission checks at startup.")
    var skipDoctor: Bool = false

    @Flag(name: .long, help: "Print every keyboard event the tap sees (debug).")
    var debugHotkey: Bool = false

    @Flag(name: .long, help: "Write each capture to /tmp/parrot-last.wav for inspection.")
    var dumpWav: Bool = false

    @Flag(name: .long, help: "Disable the on-screen recording overlay.")
    var noOverlay: Bool = false

    func run() throws {
        if !skipDoctor {
            let checks = DoctorReport.run()
            if !DoctorReport.allOK(checks) {
                FileHandle.standardError.write(Data("startup checks failed:\n".utf8))
                DoctorReport.print(checks)
                FileHandle.standardError.write(Data("\nfix the above or pass --skip-doctor\n".utf8))
                throw ExitCode(1)
            }
        }

        let transcriber = CanaryMLXTranscriber()
        let dictationFormatter = DictationFormatter()
        let warmupSemaphore = DispatchSemaphore(value: 0)
        var warmupError: Error?
        Task.detached {
            do {
                try await transcriber.warmUp()
            } catch {
                warmupError = error
            }
            warmupSemaphore.signal()
        }
        warmupSemaphore.wait()
        if let warmupError {
            FileHandle.standardError.write(Data("warmup failed: \(warmupError)\n".utf8))
            throw ExitCode(1)
        }

        // ArgumentParser invokes this synchronous subcommand from a Swift
        // concurrency worker. AppKit, however, must be initialized and run on
        // the main thread. Keep model warm-up off the UI thread, then bridge
        // the complete application lifetime onto the main queue.
        let runApplication: () throws -> Void = {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Self.configureApplicationIcon(app)

            let monitor = HotkeyMonitor(debug: debugHotkey)
            let capture = AudioCapture()
            let outputMute = OutputMuteController()
            let dumpWav = self.dumpWav
            let overlay: RecordingOverlay? =
                noOverlay ? nil : MainActor.assumeIsolated { RecordingOverlay() }
            if let overlay {
                capture.onLevel = { level in overlay.pushLevel(level) }
            }
            let menuBar = MainActor.assumeIsolated {
                MenuBarController(modelID: transcriber.modelID)
            }

            func beginRecording() -> Bool {
                outputMute.mute()
                do {
                    try capture.start()
                    FileHandle.standardError.write(Data("● recording\n".utf8))
                    MainActor.assumeIsolated {
                        overlay?.show(.recording)
                        menuBar.setRecording(true)
                    }
                    return true
                } catch {
                    outputMute.restore()
                    FileHandle.standardError.write(Data("capture failed: \(error)\n".utf8))
                    return false
                }
            }

            func finishRecording() {
                let samples = capture.stop()
                outputMute.restore()
                MainActor.assumeIsolated {
                    overlay?.show(.transcribing)
                    menuBar.setTranscribing()
                }
                let seconds = Double(samples.count) / AudioCapture.targetSampleRate
                let rms = computeRMS(samples)
                FileHandle.standardError.write(
                    Data(
                        String(format: "○ captured %.2fs · rms %.3f\n", seconds, rms).utf8
                    ))
                if dumpWav, !samples.isEmpty {
                    let path = "/tmp/parrot-last.wav"
                    do {
                        try WAVWriter.write(samples: samples, sampleRate: 16_000, to: path)
                        FileHandle.standardError.write(Data("  wrote \(path)\n".utf8))
                    } catch {
                        FileHandle.standardError.write(Data("  wav write failed: \(error)\n".utf8))
                    }
                }
                guard !samples.isEmpty else {
                    MainActor.assumeIsolated {
                        overlay?.hide()
                        menuBar.setRecording(false)
                    }
                    return
                }
                Task {
                    let started = Date()
                    do {
                        let text = try await transcriber.transcribe(samples)
                        let formatted = await dictationFormatter.format(text)
                        if formatted.usedSmartNotes {
                            FileHandle.standardError.write(
                                Data("notes intelligentes : \(formatted.source.rawValue)\n".utf8)
                            )
                        }
                        if let fallbackReason = formatted.fallbackReason {
                            FileHandle.standardError.write(
                                Data("notes intelligentes ignorées : \(fallbackReason)\n".utf8)
                            )
                        }
                        let elapsed = Date().timeIntervalSince(started)
                        FileHandle.standardError.write(
                            Data(
                                String(format: "→ %.2fs · %@\n", elapsed, formatted.text).utf8
                            ))
                        await MainActor.run {
                            TextInjector.inject(formatted.text)
                            overlay?.hide()
                            menuBar.setRecording(false)
                        }
                    } catch {
                        FileHandle.standardError.write(
                            Data("transcription failed: \(error)\n".utf8))
                        await MainActor.run {
                            overlay?.hide()
                            menuBar.setRecording(false)
                        }
                    }
                }
            }

            // Respect the user's macOS double-click preference, while keeping the
            // recognition window short enough to feel immediate for Fn dictation.
            let doubleTapInterval = min(max(NSEvent.doubleClickInterval, 0.30), 0.50)
            let gestureController = MainActor.assumeIsolated {
                FnDictationGestureController(
                    doubleTapInterval: doubleTapInterval,
                    startRecording: beginRecording,
                    stopRecording: finishRecording,
                    showLocked: {
                        FileHandle.standardError.write(
                            Data("🔒 recording locked · tap fn to stop\n".utf8))
                        overlay?.show(.locked)
                        menuBar.setLockedRecording()
                    }
                )
            }

            do {
                try monitor.start { event in
                    MainActor.assumeIsolated {
                        gestureController.handle(event)
                    }
                }
            } catch {
                FileHandle.standardError.write(
                    Data("failed to register hotkey tap: \(error)\n".utf8))
                FileHandle.standardError.write(
                    Data("run `parrot setup` to configure permissions.\n".utf8))
                throw ExitCode(1)
            }

            let cleanUp = {
                MainActor.assumeIsolated {
                    gestureController.cancel()
                }
                _ = capture.stop()
                outputMute.restore()
            }
            let terminationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: app,
                queue: .main
            ) { _ in
                cleanUp()
            }

            let shutDown = {
                FileHandle.standardError.write(Data("\nshutting down\n".utf8))
                monitor.stop()
                cleanUp()
                NSApp.terminate(nil)
            }

            let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            sigint.setEventHandler(handler: shutDown)
            sigint.resume()
            signal(SIGINT, SIG_IGN)

            let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            sigterm.setEventHandler(handler: shutDown)
            sigterm.resume()
            signal(SIGTERM, SIG_IGN)

            FileHandle.standardError.write(
                Data("listening on fn hold · model: \(transcriber.modelID) · language: fr · ^C to quit\n".utf8))
            app.run()
            NotificationCenter.default.removeObserver(terminationObserver)
        }

        if Thread.isMainThread {
            try runApplication()
        } else {
            // Do not wrap NSApplication.run() in DispatchQueue.main.sync: that
            // would occupy the main dispatch queue for the whole daemon lifetime,
            // starving hotkey callbacks and signal handlers dispatched to it.
            // A CFRunLoop block executes on the real main thread while the nested
            // AppKit run loop remains free to service the main dispatch queue.
            let applicationDidExit = DispatchSemaphore(value: 0)
            var applicationError: Error?
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                do {
                    try runApplication()
                } catch {
                    applicationError = error
                }
                applicationDidExit.signal()
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
            applicationDidExit.wait()
            if let applicationError {
                throw applicationError
            }
        }
    }

    /// LaunchAgents execute the binary inside the app bundle directly. In that
    /// launch mode AppKit can keep its generic executable icon even though the
    /// bundle declares CFBundleIconFile, so install the same bundled image on
    /// NSApplication explicitly for alerts and other app-owned windows.
    private static func configureApplicationIcon(_ app: NSApplication) {
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let bundledResourceURL =
            executableURL
            .deletingLastPathComponent()  // MacOS
            .deletingLastPathComponent()  // Contents
            .appendingPathComponent("Resources/Parrot.icns")

        let candidates = [
            Bundle.main.url(forResource: "Parrot", withExtension: "icns"),
            bundledResourceURL,
        ].compactMap { $0 }

        guard let icon = candidates.lazy.compactMap({ NSImage(contentsOf: $0) }).first else {
            return
        }
        app.applicationIconImage = icon
        FileHandle.standardError.write(Data("✓ app icon: Parrot.icns\n".utf8))
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check microphone, accessibility, and Fn key configuration."
    )

    func run() throws {
        let checks = DoctorReport.run()
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
            throw ExitCode(1)
        }
    }
}

struct Models: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage transcription models.",
        subcommands: [List.self]
    )

    struct List: ParsableCommand {
        func run() throws {
            guard let model = ModelRegistry.recommended() else {
                throw ValidationError("Canary model registry is empty")
            }
            let runtime = CanaryMLXTranscriber.Configuration.localDefault
            let marker = FileManager.default.fileExists(atPath: runtime.modelURL.path) ? "installed" : "missing"
            print("★ \(model.id) [fr] \(model.displayName) · \(marker)")
        }
    }
}
