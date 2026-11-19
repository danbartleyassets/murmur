import AppKit
import ApplicationServices
import MurmurCore

/// What sits at the cursor in the frontmost app, read through Accessibility.
struct FocusContext {
    var role: String?
    var previousCharacter: Character?

    /// A focused control that plainly can't take text (a list, a button…).
    var isClearlyNotText: Bool {
        guard let role else { return false }
        let nonText: Set<String> = [
            "AXWindow", "AXButton", "AXList", "AXOutline", "AXTable", "AXRow", "AXCell", "AXImage",
            "AXBrowser", "AXRadioButton", "AXCheckBox", "AXPopUpButton", "AXMenuButton", "AXSlider",
            "AXTabGroup", "AXToolbar", "AXDisclosureTriangle"
        ]
        return nonText.contains(role)
    }

    static func current() -> FocusContext {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return FocusContext() }
        let element = ref as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)

        var context = FocusContext()
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success {
            context.role = roleRef as? String
        }

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return context }
        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) else { return context }
        if range.location == 0 { context.previousCharacter = "\n"; return context } // start of the field
        var before = CFRange(location: range.location - 1, length: 1)
        guard let beforeValue = AXValueCreate(.cfRange, &before) else { return context }
        var stringRef: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                      beforeValue, &stringRef) == .success {
            context.previousCharacter = (stringRef as? String)?.last
        }
        return context
    }
}

/// Puts text into whatever app has keyboard focus.
@MainActor
enum TextInserter {
    enum Outcome { case inserted, copiedOnly }

    static func insert(_ text: String, method: InsertionMethod, smartSpacing: Bool) async -> Outcome {
        // Accessibility calls wait on the frontmost app; keep them off the main thread.
        let context = await Task.detached(priority: .userInitiated) { FocusContext.current() }.value
        let final = smartSpacing ? Spacing.join(previous: context.previousCharacter, text: text) : text
        guard !final.isEmpty else { return .inserted }

        // Nothing that takes text has focus: leave it on the clipboard instead of
        // pasting into the void.
        if context.isClearlyNotText {
            Log.app.notice("No text field (focus role \(context.role ?? "none", privacy: .public)); copied only")
            setClipboard(final, transient: false)
            return .copiedOnly
        }
        switch method {
        case .type:
            type(final)
        case .paste:
            paste(final)
        }
        return .inserted
    }

    // MARK: Paste, then put the previous clipboard back

    /// How long the dictation stays on the clipboard, so a paste that didn't land
    /// can still be done by hand with ⌘V.
    private static let holdOnClipboard: TimeInterval = 10
    /// The clipboard from before the first of a run of dictations, waiting to go back.
    private static var pendingRestore: (saved: [[NSPasteboard.PasteboardType: Data]], ours: Int, work: DispatchWorkItem)?

    private static func paste(_ text: String) {
        let pb = NSPasteboard.general
        // A second dictation inside the hold window must put back the user's own
        // clipboard, not the first dictation.
        // ...unless they've copied something themselves since, which is then theirs.
        let saved: [[NSPasteboard.PasteboardType: Data]]
        if let pending = pendingRestore, pb.changeCount == pending.ours {
            pending.work.cancel()
            saved = pending.saved
        } else {
            pendingRestore?.work.cancel()
            saved = snapshot(pb)
        }
        setClipboard(text, transient: true)
        let ours = pb.changeCount
        // Give the pasteboard a moment to settle before the target app reads it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { postCommandV() }
        let work = DispatchWorkItem {
            pendingRestore = nil
            // Only restore if nobody has copied anything new in the meantime.
            guard pb.changeCount == ours else { return }
            restore(saved, to: pb)
        }
        pendingRestore = (saved, ours, work)
        DispatchQueue.main.asyncAfter(deadline: .now() + holdOnClipboard, execute: work)
        Log.app.notice("Pasted \(text.count) characters; clipboard restores in \(Int(holdOnClipboard))s")
    }

    private static func setClipboard(_ text: String, transient: Bool) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        if transient {
            // Tells clipboard managers not to record this temporary paste.
            pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        }
    }

    /// Only everyday types are saved. Asking for every type makes apps like Excel or
    /// Figma render lazily offered data (often tens of MB), and stalls if that app is hung.
    private static let restorable: [NSPasteboard.PasteboardType] = [
        .string, .rtf, .rtfd, .html, .png, .tiff, .pdf, .fileURL, .URL,
        NSPasteboard.PasteboardType("public.jpeg")
    ]
    private static let maxSnapshotBytes = 25 * 1024 * 1024

    private static func snapshot(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        var total = 0
        return (pb.pasteboardItems ?? []).compactMap { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            let available = Set(item.types)
            for type in restorable where available.contains(type) {
                guard let data = item.data(forType: type), total + data.count <= maxSnapshotBytes else { continue }
                entry[type] = data
                total += data.count
            }
            return entry.isEmpty ? nil : entry
        }
    }

    private static func restore(_ saved: [[NSPasteboard.PasteboardType: Data]], to pb: NSPasteboard) {
        pb.clearContents()
        guard !saved.isEmpty else { return }
        let items = saved.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        pb.writeObjects(items)
    }

    /// A full ⌘ down, V down, V up, ⌘ up. Some apps (Chrome, Electron) ignore a bare
    /// V that only carries the Command flag, and a private source keeps any key
    /// still physically held (the Shift trigger) out of the shortcut.
    private static func postCommandV() {
        let source = CGEventSource(stateID: .privateState)
        let command: CGKeyCode = 0x37
        let v: CGKeyCode = 0x09
        let events: [(CGKeyCode, Bool, CGEventFlags)] = [
            (command, true, .maskCommand),
            (v, true, .maskCommand),
            (v, false, .maskCommand),
            (command, false, [])
        ]
        for (key, down, flags) in events {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }

    // MARK: Type (for apps that block paste)

    private static func type(_ text: String) {
        let source = CGEventSource(stateID: .privateState)
        // Up to 16 UTF-16 units per event, never splitting a character (emoji, accents).
        var chunks: [[UniChar]] = [[]]
        for character in text {
            let units = Array(String(character).utf16)
            if chunks[chunks.count - 1].count + units.count > 16 { chunks.append([]) }
            chunks[chunks.count - 1].append(contentsOf: units)
        }
        for var chunk in chunks where !chunk.isEmpty {
            for keyDown in [true, false] {
                if let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) {
                    event.flags = []   // a still-held Shift would otherwise ride along
                    event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                    event.post(tap: .cghidEventTap)
                }
            }
        }
    }
}
