import AppKit
import Combine
import MurmurCore

enum Phase: Equatable {
    case idle, listening, transcribing, thinking
}

/// Central coordinator: keyboard gesture → recorder → transcriber → insertion,
/// with the HUD and menu bar reflecting each step.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var mode: CaptureMode = .dictate
    @Published private(set) var locked = false
    @Published private(set) var model: ModelStatus = .idle
    @Published private(set) var micGranted = false
    /// The microphone that would be used right now, or nil if none is connected.
    @Published private(set) var inputDeviceName: String?
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var lastText = ""
    /// Which shortcut key is physically held right now (lights up the keycaps).
    @Published private(set) var heldKey: CaptureMode?

    let settings = SettingsStore.shared
    let hud = HUDController()
    private let keys = KeyMonitor()
    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()

    private var stream: AsyncStream<[Float]>.Continuation?
    private var streamTask: Task<String, Never>?
    private var workTask: Task<Void, Never>?
    private var safetyTimer: Timer?
    private var permissionTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    /// Long hands-free sessions are cut off here (and inserted) in case you forgot.
    private let maxRecordingSeconds: TimeInterval = 20 * 60

    private init() {}

    var setupComplete: Bool { micGranted && inputDeviceName != nil && accessibilityGranted && model.isReady }

    // MARK: Lifecycle

    func start() {
        keys.onAction = { [weak self] mode, action in self?.handle(action, mode: mode) }
        keys.onEscape = { [weak self] in self?.escapePressed() ?? false }
        keys.onTriggerChange = { [weak self] mode, down in
            guard let self else { return }
            if down { self.heldKey = mode } else if self.heldKey == mode { self.heldKey = nil }
        }
        applyShortcuts()

        // Re-apply when the shortcut settings change.
        settings.$trigger.combineLatest(settings.$askTrigger, settings.$askEnabled)
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyShortcuts() }
            .store(in: &cancellables)
        settings.$modelName.dropFirst().removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reloadModel() }
            .store(in: &cancellables)

        refreshPermissions()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }
        reloadModel()
    }

    func stop() {
        keys.stop()
        _ = recorder.stop()
        hud.hide()
    }

    func refreshPermissions() {
        micGranted = Permissions.microphoneGranted
        let device = AudioDevices.resolve(uid: settings.inputDeviceUID)?.name
        if device != inputDeviceName { inputDeviceName = device }
        let ax = Permissions.accessibilityGranted
        if ax != accessibilityGranted { accessibilityGranted = ax }
        if ax, !keys.isRunning { keys.start() }
    }

    func requestMicrophone() {
        Permissions.requestMicrophone { [weak self] granted in self?.micGranted = granted }
    }

    func requestAccessibility() { Permissions.requestAccessibility() }

    private func applyShortcuts() {
        keys.configure(dictate: settings.trigger, ask: settings.askEnabled ? settings.askTrigger : nil)
    }

    // MARK: Model

    func reloadModel() {
        let name = settings.modelName
        Task {
            await transcriber.load(model: name) { [weak self] status in self?.model = status }
        }
    }

    // MARK: Gesture → actions

    private func handle(_ action: TapGesture.Action, mode: CaptureMode) {
        switch action {
        case .startRecording: beginRecording(mode)
        case .lock: lock()
        case .finish: finishRecording()
        case .discard: cancelRecording(quietly: true)
        case .none: break
        }
    }

    private func escapePressed() -> Bool {
        switch phase {
        case .listening:
            cancelRecording(quietly: false)
            return true
        case .transcribing, .thinking:
            workTask?.cancel()
            workTask = nil
            phase = .idle
            hud.show(.message(symbol: "xmark", title: "Cancelled", detail: nil, tone: .neutral), autoHide: 1.0)
            return true
        case .idle:
            return false
        }
    }

    // MARK: Recording

    private func beginRecording(_ mode: CaptureMode) {
        Log.app.info("Start requested: enabled=\(self.settings.enabled) phase=\(String(describing: self.phase), privacy: .public) model=\(String(describing: self.model), privacy: .public) mic=\(self.micGranted)")
        guard settings.enabled, phase == .idle else { keys.reset(); return }
        guard model.isReady else {
            keys.reset()
            hud.show(.message(symbol: "hourglass", title: modelWaitTitle, detail: modelWaitDetail, tone: .warning), autoHide: 3.5)
            return
        }
        guard micGranted else {
            keys.reset()
            hud.show(.message(symbol: "mic.slash", title: "Microphone access needed",
                              detail: "Open Murmur to allow it", tone: .warning), autoHide: 3.5)
            WindowManager.shared.showMain()
            return
        }
        if mode == .ask, !AskAI.isAvailable {
            keys.reset()
            hud.show(.message(symbol: "sparkles", title: "Ask AI unavailable", detail: AskAI.unavailableReason, tone: .warning), autoHide: 4)
            return
        }

        let language = settings.resolvedLanguage
        let (chunks, continuation) = AsyncStream<[Float]>.makeStream()
        stream = continuation
        streamTask = Task { [transcriber] in
            var parts: [String] = []
            for await chunk in chunks {
                guard chunk.count >= 16_000 / 4 else { continue }
                let text = await transcriber.transcribe(chunk, language: language)
                if !text.isEmpty { parts.append(text) }
            }
            return parts.joined(separator: " ")
        }
        recorder.onChunk = { chunk in continuation.yield(chunk) }

        guard recorder.start(deviceUID: settings.inputDeviceUID) else {
            Log.app.error("Recorder failed to start (no input device?)")
            continuation.finish(); stream = nil; streamTask = nil
            keys.reset()
            hud.show(.message(symbol: "mic.slash", title: "No microphone connected",
                              detail: "Connect AirPods, a headset or a USB mic", tone: .warning), autoHide: 4)
            return
        }

        self.mode = mode
        locked = false
        phase = .listening
        hud.show(.recording(mode: mode, locked: false, started: Date()))
        Sounds.play(.start)
        safetyTimer = Timer.scheduledTimer(withTimeInterval: maxRecordingSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishRecording() }
        }
    }

    private func lock() {
        guard phase == .listening, !locked else { return }
        locked = true
        if case .recording(let mode, _, let started) = hud.content {
            hud.show(.recording(mode: mode, locked: true, started: started))
        }
        Sounds.play(.lock)
    }

    /// The HUD's lock button.
    func lockFromHUD() {
        guard phase == .listening else { return }
        keys.forceLock(mode)
        lock()
    }

    func finishRecording() {
        guard phase == .listening else { return }
        safetyTimer?.invalidate(); safetyTimer = nil
        keys.reset()
        let captured = recorder.stop()
        locked = false

        // Essentially silence the whole time: likely the wrong (or a muted) mic.
        if captured.peak < 0.003 {
            stream?.finish(); stream = nil; streamTask?.cancel(); streamTask = nil
            phase = .idle
            hud.show(.message(symbol: "mic.slash", title: "Didn't hear anything",
                              detail: "Check the microphone in Settings", tone: .warning), autoHide: 3)
            return
        }

        phase = .transcribing
        hud.show(.working(mode: mode))
        stream?.yield(captured.samples)
        stream?.finish()
        stream = nil

        let mode = self.mode
        let task = streamTask
        streamTask = nil
        workTask = Task { [weak self] in
            let raw = (await task?.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !Task.isCancelled else { return }
            await self?.deliver(raw, mode: mode, voicedSeconds: captured.voicedSeconds)
        }
    }

    func cancelRecording(quietly: Bool) {
        guard phase == .listening else { return }
        safetyTimer?.invalidate(); safetyTimer = nil
        keys.reset()
        _ = recorder.stop()
        stream?.finish(); stream = nil
        streamTask?.cancel(); streamTask = nil
        locked = false
        phase = .idle
        if quietly {
            hud.hide()
        } else {
            Sounds.play(.cancel)
            hud.show(.message(symbol: "xmark", title: "Cancelled", detail: nil, tone: .neutral), autoHide: 1.0)
        }
    }

    // MARK: Output

    private func deliver(_ raw: String, mode: CaptureMode, voicedSeconds: Double) async {
        if raw.isEmpty || Hallucination.isLikely(raw, voicedSeconds: voicedSeconds) {
            phase = .idle
            hud.show(.message(symbol: "waveform", title: "Didn't catch that", detail: nil, tone: .neutral), autoHide: 1.6)
            return
        }
        if settings.commandsEnabled, Commands.isAbort(raw) {
            phase = .idle
            hud.show(.message(symbol: "xmark", title: "Scratched", detail: nil, tone: .neutral), autoHide: 1.0)
            return
        }

        let vocab = VocabularyStore.shared
        let corrected = SoundsLike.correct(Replacements.apply(vocab.corrections, to: raw), terms: vocab.terms)
        var text: String
        if mode == .ask {
            phase = .thinking
            hud.show(.working(mode: .ask))
            text = await AskAI.respond(to: corrected)
            guard !Task.isCancelled else { return }
            if text.isEmpty {
                phase = .idle
                hud.show(.message(symbol: "sparkles", title: "No answer", detail: "Apple Intelligence didn't respond", tone: .warning), autoHide: 2.5)
                return
            }
        } else {
            text = settings.commandsEnabled ? Commands.applyInline(corrected) : corrected
        }

        let outcome = TextInserter.insert(text, method: settings.insertion, smartSpacing: settings.smartSpacing)
        lastText = text
        History.shared.add(text)
        phase = .idle
        hud.show(.done(copied: outcome == .copiedOnly), autoHide: outcome == .copiedOnly ? 2.4 : 0.7)
    }

    // MARK: Text for the UI

    var modelWaitTitle: String {
        switch model {
        case .downloading: return "Downloading the speech model"
        case .preparing(let first): return first ? "Preparing the speech model" : "Loading the speech model"
        case .failed: return "Speech model didn't load"
        default: return "Speech model not ready"
        }
    }

    var modelWaitDetail: String? {
        switch model {
        case .downloading(let f): return "\(Int(f * 100))% — first run only"
        case .preparing(let first): return first ? "One-time setup, about 2 minutes" : "A few seconds"
        case .failed: return "Open Murmur to retry"
        default: return nil
        }
    }

    /// Used only by the design-render dev hook.
    func previewOverride(model: ModelStatus, mic: Bool, accessibility: Bool) {
        self.model = model
        micGranted = mic
        accessibilityGranted = accessibility
    }

    func copyLastDictation() {
        guard !lastText.isEmpty || !History.shared.items.isEmpty else { return }
        let text = lastText.isEmpty ? History.shared.items[0].text : lastText
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
