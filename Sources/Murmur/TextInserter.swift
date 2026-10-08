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

    static func insert(_ text: String, method: InsertionMethod, smartSpacing: Bool) -> Outcome {
        let context = FocusContext.current()
        let final = smartSpacing ? Spacing.join(previous: context.previousCharacter, text: text) : text
        guard !final.isEmpty else { return .inserted }

        // Nothing that takes text has focus: leave it on the clipboard instead of
        // pasting into the void.
        if context.isClearlyNotText {
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

    private static func paste(_ text: String) {
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        setClipboard(text, transient: true)
        let ours = pb.changeCount
        postCommandV()
        // Slow apps (Electron) read the pasteboard late, so give them time. Only
        // restore if nobody has copied anything new in the meantime.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard pb.changeCount == ours else { return }
            restore(saved, to: pb)
        }
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

    private static func snapshot(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { entry[type] = data } }
            return entry
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

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let v: CGKeyCode = 0x09
        let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    // MARK: Type (for apps that block paste)

    private static func type(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            let end = min(index + 16, units.count)
            var chunk = Array(units[index..<end])
            for keyDown in [true, false] {
                if let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) {
                    event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                    event.post(tap: .cghidEventTap)
                }
            }
            index = end
        }
    }
}
