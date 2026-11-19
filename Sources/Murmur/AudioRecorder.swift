import AVFoundation
import AudioToolbox
import os

/// Thread-safe live input level, written by the audio thread and sampled by the
/// HUD. Deliberately not an ObservableObject: publishing at audio rate would
/// re-render every view that watches app state.
final class LevelMeter: @unchecked Sendable {
    static let shared = LevelMeter()
    private let lock = OSAllocatedUnfairLock(initialState: (current: Float(0), peak: Float(0)))

    func push(_ level: Float) {
        lock.withLock { $0.current = level; $0.peak = max($0.peak, level) }
    }
    /// Highest level since the last call, so short syllables still register.
    func takePeak() -> Float {
        lock.withLock { s in let p = s.peak; s.peak = s.current; return p }
    }
    var current: Float { lock.withLock { $0.current } }
    func reset() { lock.withLock { $0 = (0, 0) } }
}

/// Captures the microphone as 16 kHz mono floats. For long sessions it hands off
/// chunks at natural pauses so they're transcribed while you keep talking.
///
/// Threading: the main thread never touches AVAudioEngine. One serial queue owns
/// the engine (start, stop, restart), because a misbehaving device can leave any
/// engine call stuck inside Core Audio. Captured audio and its counters live under
/// `lock`, and every engine session has a generation number, so buffers from an
/// engine that came back late are ignored.
final class AudioRecorder: @unchecked Sendable {
    struct Result {
        var samples: [Float]      // whatever hasn't been handed off as a chunk
        var voicedSeconds: Double // time spent above the speech threshold
        var peak: Float           // loudest buffer RMS, to spot a dead mic
    }

    /// Why the last `start` failed, so the HUD can say something useful.
    enum Failure { case noDevice, notResponding, failed }
    private(set) var lastFailure: Failure?

    /// The microphone died mid-recording and couldn't be restarted. Called on main.
    var onCaptureLost: (() -> Void)?
    /// The engine failed or timed out after `start` returned true. Called on main.
    var onStartFailed: ((Failure) -> Void)?

    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                       channels: 1, interleaved: false)!

    // Guarded by `lock`, touched from main and the audio thread.
    private let lock = NSLock()
    private var samples: [Float] = []
    private var voicedSamples = 0
    private var peak: Float = 0
    private var chunkSeconds: Double = 0
    private var silenceRun: Double = 0
    private var generation = 0
    private var capturing = false
    private var onChunk: (([Float]) -> Void)?

    // Owned by `engineQueue`.
    private var engine: AVAudioEngine?
    private var engineQueue = DispatchQueue(label: "com.danbartley.murmur.audio-engine", qos: .userInitiated)

    // Main thread only.
    private var deviceUID = ""
    private var configObserver: NSObjectProtocol?
    private var restartWork: DispatchWorkItem?
    /// Engine workers that haven't returned yet. Past this many, Core Audio is wedged.
    private var inFlight = 0
    private let maxInFlight = 2

    // Measured on the original app: 10 s chunks degraded accuracy noticeably,
    // 30–60 s chunks cut at a pause did not.
    private let minChunkSeconds: Double = 30
    private let maxChunkSeconds: Double = 60
    private let pauseSeconds: Double = 0.5
    private let silenceRMS: Float = 0.008
    private let voicedRMS: Float = 0.012

    /// Some devices (an iPhone mic dropping off Continuity, a monitor's audio
    /// interface) leave Core Audio spinning when AVAudioEngine asks for their
    /// format. Never wait on that from the main thread for longer than this.
    private let startTimeout: TimeInterval = 5

    private(set) var isRecording = false

    /// Starts capture from the chosen device (empty = system default). Main thread.
    /// Returns false only for failures known up front; the engine itself starts in
    /// the background and reports a late failure through `onStartFailed`.
    /// `onChunk` is called off the main thread with each completed chunk.
    func start(deviceUID: String, onChunk: (([Float]) -> Void)?) -> Bool {
        guard !isRecording else { return true }
        lastFailure = nil
        guard inFlight < maxInFlight else {
            Log.audio.error("Not starting: earlier capture attempts are still stuck in Core Audio")
            lastFailure = .notResponding
            return false
        }
        self.deviceUID = deviceUID
        let cache = AudioDeviceCache.shared
        let device = cache.resolve(uid: deviceUID)
        // An empty cache just means the first device scan hasn't landed yet.
        if device == nil, cache.hasScanned {
            Log.audio.error("No input device connected")
            lastFailure = .noDevice
            return false
        }
        let gen: Int = lock.withLock {
            generation += 1
            samples.removeAll(keepingCapacity: true)
            voicedSamples = 0; peak = 0; chunkSeconds = 0; silenceRun = 0
            self.onChunk = onChunk
            capturing = true
            return generation
        }
        LevelMeter.shared.reset()
        isRecording = true
        launch(device: deviceUID.isEmpty ? nil : device?.id, generation: gen, isRestart: false)
        return true
    }

    /// Runs `runEngine` on the engine queue and reports back on main, giving up after
    /// `startTimeout`. A worker that gives up isn't necessarily stuck (a cold Core
    /// Audio can take a few seconds), so it's only counted while it hasn't returned.
    private func launch(device pinned: AudioDeviceID?, generation gen: Int, isRestart: Bool) {
        let settled = OSAllocatedUnfairLock(initialState: false)
        inFlight += 1
        engineQueue.async { [weak self] in
            let rate = self?.runEngine(device: pinned, generation: gen)
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight -= 1
                guard settled.withLock({ s -> Bool in defer { s = true }; return !s }) else { return }
                self.engineSettled(rate: rate, generation: gen, isRestart: isRestart)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + startTimeout) { [weak self] in
            guard let self, settled.withLock({ s -> Bool in defer { s = true }; return !s }) else { return }
            // Later attempts get a fresh queue rather than waiting behind this one.
            self.engineQueue = DispatchQueue(label: "com.danbartley.murmur.audio-engine", qos: .userInitiated)
            Log.audio.error("Microphone didn't respond within \(self.startTimeout, format: .fixed(precision: 0))s")
            self.engineSettled(rate: nil, generation: gen, isRestart: isRestart, timedOut: true)
        }
    }

    private func engineSettled(rate: Double?, generation gen: Int, isRestart: Bool, timedOut: Bool = false) {
        guard isRecording, lock.withLock({ generation == gen }) else { return }
        if let rate {
            Log.audio.info("Capture \(isRestart ? "restarted" : "started", privacy: .public) at \(Int(rate)) Hz")
            observeConfigurationChanges()
            return
        }
        if isRestart {
            Log.audio.error("Capture couldn't restart after a device change")
            onCaptureLost?()
        } else {
            lastFailure = timedOut ? .notResponding : .failed
            _ = stop()
            onStartFailed?(lastFailure ?? .failed)
        }
    }

    /// Main thread. Returns what was captured at once; the engine is torn down on its
    /// own queue so a wedged device can't hold up the app.
    @discardableResult
    func stop() -> Result {
        guard isRecording else { return Result(samples: [], voicedSeconds: 0, peak: 0) }
        isRecording = false
        restartWork?.cancel(); restartWork = nil
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        let result: Result = lock.withLock {
            capturing = false
            generation += 1
            onChunk = nil
            let r = Result(samples: samples, voicedSeconds: Double(voicedSamples) / 16_000, peak: peak)
            samples.removeAll()
            return r
        }
        LevelMeter.shared.reset()
        engineQueue.async { [weak self] in self?.tearDownEngine() }
        return result
    }

    // MARK: Engine (engineQueue only)

    /// Builds and starts a fresh engine for `generation`. Returns the input sample
    /// rate, or nil on failure.
    private func runEngine(device pinned: AudioDeviceID?, generation gen: Int) -> Double? {
        tearDownEngine()
        let fresh = AVAudioEngine()
        let input = fresh.inputNode
        if let pinned, let unit = input.audioUnit {
            var device = pinned
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                              kAudioUnitScope_Global, 0, &device,
                                              UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr { Log.audio.error("Couldn't select input device (\(status))") }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let converter = AVAudioConverter(from: format, to: target) else {
            Log.audio.error("No usable input device")
            return nil
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.process(buffer, from: format, converter: converter, generation: gen)
        }
        fresh.prepare()
        do {
            try fresh.start()
        } catch {
            Log.audio.error("Audio engine failed to start: \(error.localizedDescription)")
            input.removeTap(onBus: 0)
            return nil
        }
        // Came back too late (the caller gave up) or the recording already ended.
        guard lock.withLock({ capturing && generation == gen }) else {
            input.removeTap(onBus: 0)
            fresh.stop()
            return nil
        }
        engine = fresh
        return format.sampleRate
    }

    private func tearDownEngine() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    // MARK: Device changes

    /// AirPods connecting, a USB mic unplugged: rebuild the graph and keep going.
    /// Main thread.
    private func observeConfigurationChanges() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] note in
            // Only our own engine's changes; engines are swapped on restart.
            guard let self, note.object is AVAudioEngine else { return }
            self.scheduleRestart()
        }
    }

    /// A flapping device fires several changes in a row; restart once they settle.
    private func scheduleRestart() {
        guard isRecording else { return }
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.restart() }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func restart() {
        guard isRecording else { return }
        Log.audio.info("Audio configuration changed, restarting capture")
        let pinned: AudioDeviceID? = deviceUID.isEmpty ? nil : AudioDeviceCache.shared.resolve(uid: deviceUID)?.id
        let gen: Int = lock.withLock { generation += 1; return generation }
        launch(device: pinned, generation: gen, isRestart: true)
    }

    // MARK: Processing (audio thread)

    private func process(_ buffer: AVAudioPCMBuffer, from format: AVAudioFormat, converter: AVAudioConverter,
                         generation gen: Int) {
        guard lock.withLock({ capturing && generation == gen }) else { return }
        let ratio = target.sampleRate / format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        var error: NSError?
        var supplied = false
        converter.convert(to: out, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil else { return }
        let n = Int(out.frameLength)
        guard n > 0, let ch = out.floatChannelData?[0] else { return }

        let frame = Array(UnsafeBufferPointer(start: ch, count: n))
        var sum: Float = 0
        for s in frame { sum += s * s }
        let rms = sqrtf(sum / Float(n))
        let seconds = Double(n) / target.sampleRate

        var chunk: [Float]?
        var deliver: (([Float]) -> Void)?
        lock.lock()
        if capturing && generation == gen {
            samples.append(contentsOf: frame)
            if rms > peak { peak = rms }
            if rms > voicedRMS { voicedSamples += n }
            if let onChunk {
                chunkSeconds += seconds
                silenceRun = rms < silenceRMS ? silenceRun + seconds : 0
                if (chunkSeconds >= minChunkSeconds && silenceRun >= pauseSeconds) || chunkSeconds >= maxChunkSeconds {
                    chunk = samples
                    samples.removeAll(keepingCapacity: true)
                    chunkSeconds = 0; silenceRun = 0
                    deliver = onChunk
                }
            }
        }
        lock.unlock()
        if let chunk, let deliver { deliver(chunk) }

        // Perceptual level: -55 dBFS..-12 dBFS mapped onto 0...1.
        let db = 20 * log10f(max(rms, 1e-6))
        LevelMeter.shared.push(min(1, max(0, (db + 55) / 43)))
    }
}
