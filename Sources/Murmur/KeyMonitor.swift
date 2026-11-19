import AppKit
import os
import MurmurCore

enum CaptureMode: Equatable {
    case dictate   // type what I say
    case ask       // send what I say to the on-device model, type its answer
    case message   // four taps: tidy a rambling dictation into a clean chat message
}

/// Watches the keyboard from any app through a Core Graphics event tap and feeds
/// the trigger key into a `TapGesture` per mode. An event tap (rather than an
/// NSEvent monitor) lets Esc be swallowed while recording, so cancelling doesn't
/// also close the dialog you're typing into.
///
/// The tap runs on its own thread. Every keystroke on the Mac passes through it,
/// so it must answer instantly whatever the main thread is doing: gesture state
/// lives behind `state`, and actions are posted to the main thread, never run here.
final class KeyMonitor: @unchecked Sendable {
    /// Called on the main thread.
    var onAction: ((CaptureMode, TapGesture.Action) -> Void)?
    /// Esc was swallowed because `swallowEscape` was set. Called on the main thread.
    var onEscape: (() -> Void)?
    /// The trigger key (any mode) went down or up, for the UI. Called on the main thread.
    var onTriggerChange: ((CaptureMode, Bool) -> Void)?

    private struct Binding {
        var mode: CaptureMode
        var key: TriggerKey
        var gesture = TapGesture()
        var held = false
        var othersHeld = false
    }

    private struct State {
        var bindings: [Binding] = []
        var swallowEscape = false
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    /// The tap itself, readable from the tap thread to re-enable it.
    private let tapRef = OSAllocatedUnfairLock<CFMachPort?>(uncheckedState: nil)
    private let tickQueue = DispatchQueue(label: "com.danbartley.murmur.gesture-tick", qos: .userInteractive)
    private var tickWork: DispatchWorkItem?   // tickQueue only

    // Main thread only.
    private var tap: CFMachPort?
    private var thread: Thread?
    private var runLoop: CFRunLoop?

    var isRunning: Bool { tap != nil }

    /// Set while recording or working, so Esc cancels Murmur instead of reaching the app.
    var swallowEscape: Bool {
        get { state.withLock { $0.swallowEscape } }
        set { state.withLock { $0.swallowEscape = newValue } }
    }

    func configure(dictate: TriggerKey, ask: TriggerKey?) {
        var next = [Binding(mode: .dictate, key: dictate)]
        if let ask, ask != dictate { next.append(Binding(mode: .ask, key: ask)) }
        state.withLock { [next] in $0.bindings = next }
    }

    /// Fails until Accessibility has been granted. Main thread.
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
        self.tap = tap
        tapRef.withLockUnchecked { $0 = tap }
        let ready = DispatchSemaphore(value: 0)
        var loop: CFRunLoop?
        let thread = Thread {
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "Murmur keyboard tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        self.thread = thread
        self.runLoop = loop
        Log.app.info("Keyboard monitor started")
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        tapRef.withLockUnchecked { $0 = nil }
        if let runLoop { CFRunLoopStop(runLoop) }
        tap = nil
        runLoop = nil
        thread = nil
        reset()
    }

    /// The recording ended some other way; forget any half-finished gesture.
    func reset() {
        state.withLock { s in for i in s.bindings.indices { s.bindings[i].gesture.reset() } }
        tickQueue.async { [weak self] in self?.tickWork?.cancel() }
    }

    func forceLock(_ mode: CaptureMode) {
        state.withLock { s in
            guard let i = s.bindings.firstIndex(where: { $0.mode == mode }) else { return }
            s.bindings[i].gesture.forceLock(triggerHeld: s.bindings[i].held)
        }
    }

    // MARK: Event handling (tap thread)

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let now = ProcessInfo.processInfo.systemUptime
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = tapRef.withLockUnchecked({ $0 }) { CGEvent.tapEnable(tap: tap, enable: true) }
            Log.app.notice("Keyboard tap was disabled by the system; re-enabled")
        case .flagsChanged:
            flagsChanged(event.flags, at: now)
        case .keyDown:
            if event.getIntegerValueField(.keyboardEventKeycode) == 53, swallowEscape {
                post { $0.onEscape?() }
                return nil // Esc cancels Murmur; don't pass it on
            }
            let actions = state.withLock { s in
                s.bindings.indices.map { (s.bindings[$0].mode, s.bindings[$0].gesture.otherKey(at: now)) }
            }
            deliver(actions)
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    private func flagsChanged(_ flags: CGEventFlags, at now: TimeInterval) {
        let primary: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]
        let current = flags.intersection(primary)
        let (actions, changes) = state.withLockUnchecked { s in
            var actions: [(CaptureMode, TapGesture.Action)] = []
            var changes: [(CaptureMode, Bool)] = []
            for i in s.bindings.indices {
                let key = s.bindings[i].key.flag
                let held = current.contains(key)
                let others = !current.subtracting(key).isEmpty
                if held != s.bindings[i].held {
                    s.bindings[i].held = held
                    changes.append((s.bindings[i].mode, held && !others))
                    if held {
                        // Pressed while another modifier is down: a shortcut, not our gesture.
                        let action = others ? s.bindings[i].gesture.otherKey(at: now) : s.bindings[i].gesture.triggerDown(at: now)
                        actions.append((s.bindings[i].mode, action))
                    } else {
                        actions.append((s.bindings[i].mode, s.bindings[i].gesture.triggerUp(at: now)))
                    }
                } else if held, others, !s.bindings[i].othersHeld {
                    actions.append((s.bindings[i].mode, s.bindings[i].gesture.otherKey(at: now)))
                }
                s.bindings[i].othersHeld = others
            }
            return (actions, changes)
        }
        if !changes.isEmpty { post { m in for (mode, down) in changes { m.onTriggerChange?(mode, down) } } }
        deliver(actions)
    }

    /// Hands real actions to the main thread and re-arms the gesture timeout.
    private func deliver(_ actions: [(CaptureMode, TapGesture.Action)]) {
        let real = actions.filter { $0.1 != .none }
        for (mode, action) in real {
            Log.keys.info("Gesture \(String(describing: mode), privacy: .public) → \(String(describing: action), privacy: .public)")
        }
        if !real.isEmpty { post { m in for (mode, action) in real { m.onAction?(mode, action) } } }
        tickQueue.async { [weak self] in self?.scheduleTick() }
    }

    private func post(_ body: @escaping (KeyMonitor) -> Void) {
        DispatchQueue.main.async { [weak self] in if let self { body(self) } }
    }

    // MARK: Gesture timeouts (tickQueue)

    private func scheduleTick() {
        tickWork?.cancel()
        guard let next = state.withLock({ $0.bindings.compactMap(\.gesture.deadline).min() }) else { return }
        let delay = max(0, next - ProcessInfo.processInfo.systemUptime) + 0.005
        let work = DispatchWorkItem { [weak self] in self?.tick() }
        tickWork = work
        tickQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let actions = state.withLock { s in
            s.bindings.indices.map { (s.bindings[$0].mode, s.bindings[$0].gesture.tick(at: now)) }
        }
        let real = actions.filter { $0.1 != .none }
        for (mode, action) in real {
            Log.keys.info("Gesture \(String(describing: mode), privacy: .public) → \(String(describing: action), privacy: .public) (timeout)")
        }
        if !real.isEmpty { post { m in for (mode, action) in real { m.onAction?(mode, action) } } }
        scheduleTick()
    }
}

/// C callback for the event tap, on the tap's own thread.
private let keyTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<KeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
    return monitor.handle(type, event)
}
