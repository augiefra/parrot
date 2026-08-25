import AppKit
import CoreGraphics
import Foundation

/// Inserts dictation as one paste operation rather than a stream of synthetic
/// Unicode key events. Rich editors regularly corrupt multi-line Unicode event
/// streams; their normal paste path preserves the text exactly.
@MainActor
enum TextInjector {
    private static let restoreDelay: TimeInterval = 0.35

    static func inject(_ text: String) {
        guard !text.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(items: pasteboard.pasteboardItems)

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        guard pasteboard.writeObjects([item]) else {
            snapshot.restore(to: pasteboard)
            return
        }

        let parrotChangeCount = pasteboard.changeCount
        postPasteShortcut()

        // The target application reads the pasteboard asynchronously after the
        // Command-V event. Restore after that short window, but never overwrite
        // a clipboard change the person made in the meantime.
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
            guard pasteboard.changeCount == parrotChangeCount else { return }
            snapshot.restore(to: pasteboard)
        }
    }

    private static func postPasteShortcut() {
        let keyCode = CGKeyCode(9) // ANSI V
        let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)
        down?.flags = .maskCommand
        down?.post(tap: .cgSessionEventTap)

        let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        up?.flags = .maskCommand
        up?.post(tap: .cgSessionEventTap)
    }
}

/// A data copy of every immediately readable pasteboard representation. It
/// intentionally has no reference to the live pasteboard, so restoring it
/// cannot revive Parrot's temporary string by accident.
struct PasteboardSnapshot {
    let items: [NSPasteboardItem]

    init(items: [NSPasteboardItem]?) {
        self.items = (items ?? []).map(Self.copy)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        pasteboard.writeObjects(items)
    }

    private static func copy(_ source: NSPasteboardItem) -> NSPasteboardItem {
        let destination = NSPasteboardItem()
        for type in source.types {
            if let data = source.data(forType: type) {
                destination.setData(data, forType: type)
            }
        }
        return destination
    }
}
