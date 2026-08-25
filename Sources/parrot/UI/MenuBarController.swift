import AppKit

/// The complete active control surface for Parrot: classic local dictation,
/// its one Canary model, a local spelling dictionary, and quit. Video work is
/// intentionally not compiled into the current dictation-focused product.
@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let modelLabel: NSMenuItem
    private let stateLabel: NSMenuItem
    private var dictationBusy = false

    init(modelID: String) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        let menu = NSMenu()
        menu.autoenablesItems = false

        stateLabel = NSMenuItem(title: "idle · hold fn or double-tap to lock", action: nil, keyEquivalent: "")
        stateLabel.isEnabled = false
        menu.addItem(stateLabel)

        modelLabel = NSMenuItem(title: "model: \(modelID) · local fr", action: nil, keyEquivalent: "")
        modelLabel.isEnabled = false
        menu.addItem(modelLabel)

        let dictionary = NSMenuItem(
            title: "Add dictionary correction…",
            action: #selector(addDictionaryCorrectionClicked),
            keyEquivalent: ""
        )
        dictionary.target = self
        menu.addItem(dictionary)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit parrot", action: #selector(quitClicked), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        configureButton()
    }

    func setRecording(_ recording: Bool) {
        dictationBusy = recording
        stateLabel.title = recording ? "● recording" : "idle · hold fn or double-tap to lock"
    }

    func setTranscribing() {
        dictationBusy = true
        stateLabel.title = "transcribing…"
    }

    func setLockedRecording() {
        dictationBusy = true
        stateLabel.title = "🔒 recording · tap fn to stop"
    }

    var menuItemTitles: [String] {
        statusItem.menu?.items.map(\.title) ?? []
    }

    var isDictationBusy: Bool { dictationBusy }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Parrot")
        image?.isTemplate = true
        button.image = image
        button.title = image == nil ? "P" : ""
        button.toolTip = "Parrot"
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }

    @objc private func addDictionaryCorrectionClicked() {
        let transcribedAs = NSTextField(string: "")
        transcribedAs.placeholderString = "e.g. facile abo"

        let correctSpelling = NSTextField(string: "")
        correctSpelling.placeholderString = "e.g. FacilAbo"

        let alert = NSAlert()
        // Deliberately leave alert.icon nil: this utility dialog must not show
        // the packed application icon.
        alert.messageText = "Add dictionary correction"
        alert.informativeText = "Enter what Parrot wrote, then your preferred spelling."
        alert.addButton(withTitle: "Add correction")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = dictionaryForm(
            transcribedAs: transcribedAs,
            correctSpelling: correctSpelling
        )
        alert.window.initialFirstResponder = transcribedAs

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try LocalDictionary.addCorrection(
                transcribedAs: transcribedAs.stringValue,
                correctSpelling: correctSpelling.stringValue
            )
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func dictionaryForm(transcribedAs: NSTextField, correctSpelling: NSTextField) -> NSView {
        let stack = NSStackView(views: [
            fieldGroup(title: "Parrot wrote", field: transcribedAs),
            fieldGroup(title: "Use this spelling", field: correctSpelling),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.layoutSubtreeIfNeeded()

        let form = NSView(frame: NSRect(origin: .zero, size: stack.fittingSize))
        stack.frame = form.bounds
        stack.autoresizingMask = [.width, .height]
        form.addSubview(stack)
        return form
    }

    private func fieldGroup(title: String, field: NSTextField) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 360).isActive = true

        let group = NSStackView(views: [label, field])
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 4
        return group
    }
}
