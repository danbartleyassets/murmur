import Foundation
import CoreML
import os
import WhisperKit
import MurmurCore

enum Log {
    static let app = Logger(subsystem: "com.danbartley.murmur", category: "app")
    static let audio = Logger(subsystem: "com.danbartley.murmur", category: "audio")
    static let model = Logger(subsystem: "com.danbartley.murmur", category: "model")
}

/// Where models live: ~/Library/Application Support/Murmur/huggingface.
enum ModelStorage {
    static var support: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var base: URL { support.appendingPathComponent("huggingface", isDirectory: true) }

    static func folder(for model: String) -> URL {
        base.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(model)", isDirectory: true)
    }

    /// The model folder, only if every part finished downloading.
    static func localFolder(for model: String) -> String? {
        let dir = folder(for: model)
        let parts = ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"]
        let complete = parts.allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
        return complete ? dir.path : nil
    }

    /// The first load compiles the model for this Mac's Neural Engine (slow, once).
    static func isPrepared(_ model: String) -> Bool { UserDefaults.standard.bool(forKey: "prepared.\(model)") }
    static func markPrepared(_ model: String) { UserDefaults.standard.set(true, forKey: "prepared.\(model)") }
}

enum ModelStatus: Equatable {
    case idle
    case downloading(Double)
    case preparing(firstTime: Bool)
    case ready
    case failed(String)

    var isReady: Bool { self == .ready }
}

/// Local, on-device transcription with WhisperKit on the Neural Engine.
final class Transcriber {
    private var kit: WhisperKit?
    var isReady: Bool { kit != nil }

    func load(model: String, status: @escaping @MainActor (ModelStatus) -> Void) async {
        kit = nil
        do {
            var folder = ModelStorage.localFolder(for: model)
            if folder == nil {
                await status(.downloading(0))
                let url = try await WhisperKit.download(variant: model, downloadBase: ModelStorage.base) { progress in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor in status(.downloading(fraction)) }
                }
                folder = url.path
            }
            await status(.preparing(firstTime: !ModelStorage.isPrepared(model)))

            // Neural Engine: ~2.5x faster than the GPU for this model.
            let compute = ModelComputeOptions(melCompute: .cpuAndGPU,
                                              audioEncoderCompute: .cpuAndNeuralEngine,
                                              textDecoderCompute: .cpuAndNeuralEngine)
            let config = WhisperKitConfig(model: model, downloadBase: ModelStorage.base, modelFolder: folder,
                                          computeOptions: compute, verbose: false, logLevel: .error,
                                          prewarm: false, load: true, download: false)
            let loaded = try await WhisperKit(config)
            // One throwaway pass so the first real dictation isn't the slow one.
            _ = try? await loaded.transcribe(audioArray: [Float](repeating: 0, count: 16_000),
                                             decodeOptions: DecodingOptions(withoutTimestamps: true))
            kit = loaded
            ModelStorage.markPrepared(model)
            Log.model.info("Model ready: \(model)")
            await status(.ready)
        } catch {
            Log.model.error("Model load failed: \(error.localizedDescription)")
            await status(.failed(error.localizedDescription))
        }
    }

    /// Transcribes 16 kHz mono samples. `vocabulary` nudges spelling of names and jargon.
    func transcribe(_ samples: [Float], language: String?, vocabulary: [String]) async -> String {
        guard let kit, !samples.isEmpty else { return "" }

        var prompt: [Int]?
        if !vocabulary.isEmpty, let tokenizer = kit.tokenizer {
            let text = " " + vocabulary.joined(separator: ", ") + "."
            prompt = tokenizer.encode(text: text).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }
        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            temperature: 0,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            promptTokens: prompt,
            suppressBlank: true,
            // Whisper's window is 30 s; past that, split at silences instead of mid-word.
            chunkingStrategy: samples.count > 16_000 * 30 ? .vad : ChunkingStrategy.none
        )
        do {
            let results: [TranscriptionResult] = try await kit.transcribe(audioArray: samples, decodeOptions: options)
            return NonSpeech.strip(results.map(\.text).joined(separator: " "))
        } catch {
            Log.model.error("Transcription failed: \(error.localizedDescription)")
            return ""
        }
    }

    /// Transcribes a file (used by the self-test hook).
    func transcribe(file path: String, language: String?, vocabulary: [String] = []) async -> String {
        guard let samples = try? AudioProcessor.loadAudioAsFloatArray(fromPath: path) else { return "" }
        return await transcribe(samples, language: language, vocabulary: vocabulary)
    }
}
