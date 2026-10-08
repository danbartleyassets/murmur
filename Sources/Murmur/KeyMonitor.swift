import AppKit
import MurmurCore

enum CaptureMode: Equatable {
    case dictate   // type what I say
    case ask       // send what I say to the on-device model, type its answer
}

/// Watches the keyboard from any app through a Core Graphics event tap and feeds
/// the trigger key into a `TapGesture` per mode. An event tap (rather than an
/// NSEvent monitor) lets Esc be swallowed while recording, so cancelling doesn't
/// also close the dialog you're typing into.
@MainActor
final class KeyMonitor {
    var onAction: ((CaptureMode, TapGesture.Action) -> Void)?
    /// Return true to swallow the Esc key.
    var onEscape: (() -> Bool)?

    private struct Binding {
        var mode: CaptureMode
        var key: TriggerKey
        var gesture = TapGesture()
        var held = false
        var othersHeld = false
    }

    private var bindings: [Binding] = []
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var tickWork: DispatchWorkItem?

    var isRunning: Bool { tap != nil }

    func configure(dictate: TriggerKey, ask: TriggerKey?) {
        var next = [Binding(mode: .dictate, key: dictate)]
        if let ask, ask != dictate { next.append(Binding(mode: .ask, key: ask)) }
        bindings = next
    }

    /// Fails until Accessibility has been granted.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                          callback: keyTapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        Log.app.info("Keyboard monitor started")
        return true
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil
        source = nil
        reset()
    }

    /// The recording ended some other way; forget any half-finished gesture.
    func reset() {
        for i in bindings.indices { bindings[i].gesture.reset() }
        tickWork?.cancel()
    }

    func forceLock(_ mode: CaptureMode) {
        guard let i = bindings.firstIndex(where: { $0.mode == mode }) else { return }
        bindings[i].gesture.forceLock(triggerHeld: bindings[i].held)
    }

    // MARK: Event handling

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let now = ProcessInfo.processInfo.systemUptime
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .flagsChanged:
            flagsChanged(event.flags, at: now)
        case .keyDown:
            if event.getIntegerValueField(.keyboardEventKeycode) == 53, onEscape?() == true {
                return nil // Esc cancelled a recording; don't pass it on
            }
            for i in bindings.indices { apply(i, bindings[i].gesture.otherKey(at: now)) }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    private func flagsChanged(_ flags: CGEventFlags, at now: TimeInterval) {
        let primary: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]
        let current = flags.intersection(primary)
        for i in bindings.indices {
            let key = bindings[i].key.flag
            let held = current.contains(key)
            let others = !current.subtracting(key).isEmpty
            if held != bindings[i].held {
                bindings[i].held = held
                if held {
                    // Pressed while another modifier is down: a shortcut, not our gesture.
                    apply(i, others ? bindings[i].gesture.otherKey(at: now) : bindings[i].gesture.triggerDown(at: now))
                } else {
                    apply(i, bindings[i].gesture.triggerUp(at: now))
                }
            } else if held, others, !bindings[i].othersHeld {
                apply(i, bindings[i].gesture.otherKey(at: now))
            }
            bindings[i].othersHeld = others
        }
    }

    private func apply(_ index: Int, _ action: TapGesture.Action) {
        if action != .none { onAction?(bindings[index].mode, action) }
        scheduleTick()
    }

    private func scheduleTick() {
        tickWork?.cancel()
        guard let next = bindings.compactMap(\.gesture.deadline).min() else { return }
        let delay = max(0, next - ProcessInfo.processInfo.systemUptime) + 0.005
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.tick() }
        }
        tickWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        for i in bindings.indices {
            let action = bindings[i].gesture.tick(at: now)
            if action != .none { onAction?(bindings[i].mode, action) }
        }
        scheduleTick()
    }
}

/// C callback for the event tap. The tap's run-loop source is on the main run
/// loop, so this always runs on the main thread.
private let keyTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<KeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
    return MainActor.assumeIsolated { monitor.handle(type, event) }
}
