// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "parrot",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "parrot",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            exclude: [
                "Subtitles",
                "Transcription/TimedTranscriber.swift",
                "Transcription/WhisperKitTranscriber.swift",
                "UI/VideoProgressWindow.swift",
            ]
        ),
        .testTarget(
            name: "parrotTests",
            dependencies: ["parrot"],
            exclude: [
                "CaptionedVideoRendererTests.swift",
                "SRTFormatterTests.swift",
                "SubtitlesCommandTests.swift",
                "VideoProgressModelTests.swift",
                "WhisperKitTranscriberTests.swift",
            ]
        ),
    ]
)
