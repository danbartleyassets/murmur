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
final class AudioRecorder {
    struct Result {
        var samples: [Float]      // whatever hasn't been handed off as a chunk
        var voicedSeconds: Double // time spent above the speech threshold
        var peak: Float           // loudest buffer RMS, to spot a dead mic
    }

    /// Called off the main thread with each completed chunk.
    var onChunk: (([Float]) -> Void)?

    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                       channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var samples: [Float] = []
    private var voicedSamples = 0
    private var peak: Float = 0
    private var deviceUID = ""
    private var configObserver: NSObjectProtocol?

    // Measured on the original app: 10 s chunks degraded accuracy noticeably,
    // 30–60 s chunks cut at a pause did not.
    private let minChunkSeconds: Double = 30
    private let maxChunkSeconds: Double = 60
    private let pauseSeconds: Double = 0.5
    private let silenceRMS: Float = 0.008
    private let voicedRMS: Float = 0.012
    private var chunkSeconds: Double = 0
    private var silenceRun: Double = 0

    private(set) var isRecording = false

    /// Starts capture from the chosen device (empty = system default).
    func start(deviceUID: String) -> Bool {
        guard !isRecording else { return true }
        self.deviceUID = deviceUID
        lock.lock(); samples.removeAll(keepingCapacity: true); voicedSamples = 0; peak = 0; lock.unlock()
        chunkSeconds = 0; silenceRun = 0
        LevelMeter.shared.reset()
        guard startEngine() else { return false }
        isRecording = true
        // AirPods connecting, a USB mic unplugged: rebuild the graph and keep going.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.restartAfterConfigurationChange() }
        return true
    }

    @discardableResult
    func stop() -> Result {
        guard isRecording else { return Result(samples: [], voicedSeconds: 0, peak: 0) }
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        onChunk = nil
        LevelMeter.shared.reset()
        lock.lock()
        let result = Result(samples: samples, voicedSeconds: Double(voicedSamples) / 16_000, peak: peak)
        samples.removeAll()
        lock.unlock()
        return result
    }

    // MARK: Engine

    private func startEngine() -> Bool {
        engine = AVAudioEngine()
        let input = engine.inputNode
        if !deviceUID.isEmpty, let id = AudioDevices.deviceID(forUID: deviceUID), let unit = input.audioUnit {
            var device = id
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                              kAudioUnitScope_Global, 0, &device,
                                              UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr { Log.audio.error("Couldn't select input device (\(status))") }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            Log.audio.error("No usable input device")
            return false
        }
        converter = AVAudioConverter(from: format, to: target)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.process(buffer, from: format)
        }
        engine.prepare()
        do {
            try engine.start()
            Log.audio.info("Capture started at \(Int(format.sampleRate)) Hz")
            return true
        } catch {
            Log.audio.error("Audio engine failed to start: \(error.localizedDescription)")
            input.removeTap(onBus: 0)
            return false
        }
    }

    private func restartAfterConfigurationChange() {
        guard isRecording else { return }
        Log.audio.info("Audio configuration changed, restarting capture")
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        guard startEngine() else { return }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.restartAfterConfigurationChange() }
    }

    private func process(_ buffer: AVAudioPCMBuffer, from format: AVAudioFormat) {
        guard let converter else { return }
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

        lock.lock()
        samples.append(contentsOf: frame)
        if rms > peak { peak = rms }
        if rms > voicedRMS { voicedSamples += n }
        lock.unlock()

        if onChunk != nil {
            let seconds = Double(n) / target.sampleRate
            chunkSeconds += seconds
            silenceRun = rms < silenceRMS ? silenceRun + seconds : 0
            if (chunkSeconds >= minChunkSeconds && silenceRun >= pauseSeconds) || chunkSeconds >= maxChunkSeconds {
                lock.lock(); let chunk = samples; samples.removeAll(keepingCapacity: true); lock.unlock()
                chunkSeconds = 0; silenceRun = 0
                onChunk?(chunk)
            }
        }

        // Perceptual level: -55 dBFS..-12 dBFS mapped onto 0...1.
        let db = 20 * log10f(max(rms, 1e-6))
        LevelMeter.shared.push(min(1, max(0, (db + 55) / 43)))
    }
}
