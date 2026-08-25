import AppKit
import SwiftUI

enum VideoProcessingKind: Equatable, Sendable {
    case subtitles
    case readyForX

    var windowTitle: String {
        switch self {
        case .subtitles: "Création des sous-titres"
        case .readyForX: "Préparation de la vidéo"
        }
    }

    var stageCount: Int {
        switch self {
        case .subtitles: 3
        case .readyForX: 5
        }
    }
}

enum VideoProcessingStage: Equatable, Sendable {
    case readingAudio
    case transcribing
    case writingSubtitles
    case renderingVideo
    case finalizing
    case completed
    case failed

    fileprivate var processingOrder: Int {
        switch self {
        case .readingAudio: 0
        case .transcribing: 1
        case .writingSubtitles: 2
        case .renderingVideo: 3
        case .finalizing: 4
        case .completed, .failed: 5
        }
    }
}

struct VideoProcessingSnapshot: Equatable, Sendable {
    static let delayedFeedbackInterval: TimeInterval = 60

    let kind: VideoProcessingKind
    let input: URL
    let startedAt: Date
    var stage: VideoProcessingStage
    var fractionCompleted: Double?
    var lastActivityAt: Date
    var outputs: [URL] = []
    var errorMessage: String?

    var stageNumber: Int {
        switch stage {
        case .readingAudio: 1
        case .transcribing: 2
        case .writingSubtitles: 3
        case .renderingVideo: kind == .readyForX ? 4 : kind.stageCount
        case .finalizing, .completed, .failed: kind.stageCount
        }
    }

    var stageTitle: String {
        switch stage {
        case .readingAudio: "Lecture de la piste audio"
        case .transcribing: "Transcription locale en français"
        case .writingSubtitles: "Création du fichier SRT"
        case .renderingVideo: "Incrustation des sous-titres"
        case .finalizing: "Finalisation du fichier vidéo"
        case .completed:
            kind == .readyForX ? "Vidéo prête pour X" : "Sous-titres créés"
        case .failed: "Le traitement n’a pas abouti"
        }
    }

    var detail: String {
        switch stage {
        case .readingAudio:
            "Parrot prépare une piste mono 16 kHz pour Whisper."
        case .transcribing:
            "Whisper Large V3 Turbo analyse la voix localement, en français."
        case .writingSubtitles:
            "Les segments et leurs horodatages sont mis en forme."
        case .renderingVideo:
            "La copie MP4 est exportée avec les sous-titres stylés."
        case .finalizing:
            "Parrot installe le fichier terminé à côté de la source."
        case .completed:
            kind == .readyForX
                ? "Le MP4 sous-titré et son SRT sont disponibles."
                : "Le fichier SRT est disponible à côté de la vidéo."
        case .failed:
            if !outputs.isEmpty {
                "\(errorMessage ?? "Une erreur inconnue est survenue.") Le SRT déjà créé a été conservé."
            } else {
                errorMessage ?? "Une erreur inconnue est survenue."
            }
        }
    }

    var isRunning: Bool {
        stage != .completed && stage != .failed
    }

    func isDelayed(at date: Date) -> Bool {
        isRunning && date.timeIntervalSince(lastActivityAt) >= Self.delayedFeedbackInterval
    }

    func elapsed(at date: Date) -> TimeInterval {
        max(0, date.timeIntervalSince(startedAt))
    }
}

@MainActor
final class VideoProgressModel: ObservableObject {
    @Published private(set) var snapshot: VideoProcessingSnapshot?

    func begin(kind: VideoProcessingKind, input: URL, now: Date = Date()) {
        snapshot = VideoProcessingSnapshot(
            kind: kind,
            input: input,
            startedAt: now,
            stage: .readingAudio,
            fractionCompleted: 0,
            lastActivityAt: now
        )
    }

    func apply(_ progress: SubtitleGenerationProgress, now: Date = Date()) {
        guard var snapshot else { return }
        let nextStage: VideoProcessingStage
        switch progress {
        case .readingAudio(let fraction):
            nextStage = .readingAudio
            let fraction = Self.clamp(fraction)
            snapshot.fractionCompleted = snapshot.stage == nextStage
                ? max(snapshot.fractionCompleted ?? 0, fraction)
                : fraction
        case .transcribing(let fraction):
            nextStage = .transcribing
            let clamped = Self.clamp(fraction)
            let previous = snapshot.stage == nextStage ? snapshot.fractionCompleted ?? 0 : 0
            snapshot.fractionCompleted = clamped > 0 ? max(previous, clamped) : nil
        case .writingSubtitles:
            nextStage = .writingSubtitles
            snapshot.fractionCompleted = nil
        }

        guard nextStage.processingOrder >= snapshot.stage.processingOrder else { return }
        snapshot.stage = nextStage
        snapshot.lastActivityAt = now
        self.snapshot = snapshot
    }

    func beginVideoRendering(now: Date = Date()) {
        update(stage: .renderingVideo, fraction: 0, now: now)
    }

    func updateVideoRendering(fraction: Double, now: Date = Date()) {
        update(stage: .renderingVideo, fraction: Self.clamp(fraction), now: now)
    }

    func beginFinalizing(now: Date = Date()) {
        update(stage: .finalizing, fraction: nil, now: now)
    }

    func complete(outputs: [URL], now: Date = Date()) {
        guard var snapshot else { return }
        snapshot.stage = .completed
        snapshot.fractionCompleted = 1
        snapshot.lastActivityAt = now
        snapshot.outputs = outputs
        snapshot.errorMessage = nil
        self.snapshot = snapshot
    }

    func fail(_ error: Error, retainedOutputs: [URL], now: Date = Date()) {
        guard var snapshot else { return }
        snapshot.stage = .failed
        snapshot.fractionCompleted = nil
        snapshot.lastActivityAt = now
        snapshot.outputs = retainedOutputs
        snapshot.errorMessage = error.localizedDescription
        self.snapshot = snapshot
    }

    private func update(
        stage: VideoProcessingStage,
        fraction: Double?,
        now: Date
    ) {
        guard var snapshot else { return }
        snapshot.stage = stage
        snapshot.fractionCompleted = fraction
        snapshot.lastActivityAt = now
        self.snapshot = snapshot
    }

    private static func clamp(_ fraction: Double) -> Double {
        guard fraction.isFinite else { return 0 }
        return min(1, max(0, fraction))
    }
}

@MainActor
final class VideoProgressWindowController {
    let model = VideoProgressModel()

    private let panel: NSPanel
    private var hasPositionedWindow = false

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 330),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.panel = panel

        panel.title = "Parrot"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true

        let view = VideoProgressView(
            model: model,
            onReveal: { [weak model] in
                guard let outputs = model?.snapshot?.outputs, !outputs.isEmpty else { return }
                NSWorkspace.shared.activateFileViewerSelecting(outputs)
            },
            onHide: { [weak panel] in
                panel?.orderOut(nil)
            }
        )
        panel.contentViewController = NSHostingController(rootView: view)
    }

    func begin(kind: VideoProcessingKind, input: URL) {
        model.begin(kind: kind, input: input)
        show()
    }

    func show() {
        if !hasPositionedWindow {
            panel.center()
            hasPositionedWindow = true
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func complete(outputs: [URL]) {
        model.complete(outputs: outputs)
        show()
    }

    func fail(_ error: Error, retainedOutputs: [URL]) {
        model.fail(error, retainedOutputs: retainedOutputs)
        show()
    }
}

struct VideoProgressView: View {
    @ObservedObject var model: VideoProgressModel
    let onReveal: () -> Void
    let onHide: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let snapshot = model.snapshot {
                content(snapshot, now: context.date)
            }
        }
        .frame(width: 470, height: 330)
        .background(.regularMaterial)
    }

    private func content(_ snapshot: VideoProcessingSnapshot, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            header(snapshot)
            Divider()
            status(snapshot, now: now)
            progress(snapshot)

            if snapshot.isDelayed(at: now) {
                Label(
                    "Aucune nouvelle progression depuis plus d’une minute.",
                    systemImage: "clock.badge.exclamationmark"
                )
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.orange)
                .accessibilityHint("Le traitement peut être ralenti ou bloqué.")
            }

            Spacer(minLength: 0)
            footer(snapshot)
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 20)
    }

    private func header(_ snapshot: VideoProcessingSnapshot) -> some View {
        HStack(spacing: 13) {
            Image(systemName: statusSymbol(snapshot.stage))
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(statusColor(snapshot.stage))
                .frame(width: 44, height: 44)
                .background(statusColor(snapshot.stage).opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.kind.windowTitle)
                    .font(.system(size: 17, weight: .semibold))
                Text(snapshot.input.lastPathComponent)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func status(_ snapshot: VideoProcessingSnapshot, now: Date) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                Text(snapshot.stageTitle)
                    .font(.system(size: 15, weight: .semibold))
                Text(snapshot.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 16)

            Text(formatElapsed(snapshot.elapsed(at: now)))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private func progress(_ snapshot: VideoProcessingSnapshot) -> some View {
        if snapshot.isRunning {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Étape \(snapshot.stageNumber) sur \(snapshot.kind.stageCount)")
                    Spacer()
                    if let fraction = snapshot.fractionCompleted {
                        Text("\(Int((fraction * 100).rounded())) %")
                    } else {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("En cours")
                        }
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

                if let fraction = snapshot.fractionCompleted {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                }
            }
        } else if snapshot.stage == .completed {
            ProgressView(value: 1)
                .progressViewStyle(.linear)
                .tint(.green)
        }
    }

    private func footer(_ snapshot: VideoProcessingSnapshot) -> some View {
        HStack {
            Label("100 % local", systemImage: "lock.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            Spacer()

            if !snapshot.outputs.isEmpty {
                Button("Afficher dans le Finder", action: onReveal)
            }
            Button(snapshot.isRunning ? "Masquer" : "Fermer", action: onHide)
                .keyboardShortcut(.cancelAction)
        }
    }

    private func statusSymbol(_ stage: VideoProcessingStage) -> String {
        switch stage {
        case .completed: "checkmark"
        case .failed: "exclamationmark"
        default: "waveform"
        }
    }

    private func statusColor(_ stage: VideoProcessingStage) -> Color {
        switch stage {
        case .completed: .green
        case .failed: .red
        default: .accentColor
        }
    }

    private func formatElapsed(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.down)))
        let hours = seconds / 3_600
        let minutes = (seconds / 60) % 60
        let remainder = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%02d:%02d", minutes, remainder)
    }
}
