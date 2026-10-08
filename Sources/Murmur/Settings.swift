import Foundation
import Combine
import CoreGraphics

enum TriggerKey: String, CaseIterable, Identifiable {
    case shift, control, option, command
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .shift: return "⇧"
        case .control: return "⌃"
        case .option: return "⌥"
        case .command: return "⌘"
        }
    }

    var name: String {
        switch self {
        case .shift: return "Shift"
        case .control: return "Control"
        case .option: return "Option"
        case .command: return "Command"
        }
    }

    var flag: CGEventFlags {
        switch self {
        case .shift: return .maskShift
        case .control: return .maskControl
        case .option: return .maskAlternate
        case .command: return .maskCommand
        }
    }
}

enum InsertionMethod: String, CaseIterable, Identifiable {
    case paste, type
    var id: String { rawValue }
}

struct SpeechModel: Identifiable {
    let id: String
    let name: String
    let detail: String

    static let all: [SpeechModel] = [
        SpeechModel(id: "distil-whisper_distil-large-v3_turbo",
                    name: "Distil Large v3 Turbo", detail: "Fast and accurate, English. About 600 MB."),
        SpeechModel(id: "openai_whisper-large-v3-v20240930_turbo_632MB",
                    name: "Large v3 Turbo, compressed", detail: "Multilingual. About 630 MB."),
        SpeechModel(id: "openai_whisper-large-v3_turbo",
                    name: "Large v3 Turbo", detail: "Most accurate, multilingual. Largest download."),
        SpeechModel(id: "openai_whisper-small.en",
                    name: "Small, English", detail: "Lightest and quickest, less accurate.")
    ]

    static let defaultID = all[0].id

    static func named(_ id: String) -> SpeechModel {
        all.first { $0.id == id } ?? SpeechModel(id: id, name: id, detail: "")
    }
}

/// Persistent preferences, backed by UserDefaults.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    private let d = UserDefaults.standard

    @Published var enabled: Bool { didSet { d.set(enabled, forKey: "enabled") } }
    @Published var trigger: TriggerKey { didSet { d.set(trigger.rawValue, forKey: "trigger") } }
    @Published var askEnabled: Bool { didSet { d.set(askEnabled, forKey: "askEnabled") } }
    @Published var askTrigger: TriggerKey { didSet { d.set(askTrigger.rawValue, forKey: "askTrigger") } }

    @Published var modelName: String { didSet { d.set(modelName, forKey: "modelName") } }
    /// "auto" or an ISO code such as "en".
    @Published var language: String { didSet { d.set(language, forKey: "language") } }
    /// Core Audio device UID; empty means the system default input.
    @Published var inputDeviceUID: String { didSet { d.set(inputDeviceUID, forKey: "inputDeviceUID") } }

    @Published var commandsEnabled: Bool { didSet { d.set(commandsEnabled, forKey: "commandsEnabled") } }
    @Published var insertion: InsertionMethod { didSet { d.set(insertion.rawValue, forKey: "insertion") } }
    @Published var smartSpacing: Bool { didSet { d.set(smartSpacing, forKey: "smartSpacing") } }
    @Published var soundsEnabled: Bool { didSet { d.set(soundsEnabled, forKey: "soundsEnabled") } }
    @Published var keepHistory: Bool { didSet { d.set(keepHistory, forKey: "keepHistory") } }

    private init() {
        enabled = d.object(forKey: "enabled") as? Bool ?? true
        trigger = TriggerKey(rawValue: d.string(forKey: "trigger") ?? "") ?? .shift
        askEnabled = d.object(forKey: "askEnabled") as? Bool ?? true
        askTrigger = TriggerKey(rawValue: d.string(forKey: "askTrigger") ?? "") ?? .control
        modelName = d.string(forKey: "modelName") ?? SpeechModel.defaultID
        language = d.string(forKey: "language") ?? "en"
        inputDeviceUID = d.string(forKey: "inputDeviceUID") ?? ""
        commandsEnabled = d.object(forKey: "commandsEnabled") as? Bool ?? true
        insertion = InsertionMethod(rawValue: d.string(forKey: "insertion") ?? "") ?? .paste
        smartSpacing = d.object(forKey: "smartSpacing") as? Bool ?? true
        soundsEnabled = d.object(forKey: "soundsEnabled") as? Bool ?? true
        keepHistory = d.object(forKey: "keepHistory") as? Bool ?? true
    }

    var resolvedLanguage: String? {
        (language.isEmpty || language == "auto") ? nil : language
    }

    static let languages: [(String, String)] = [
        ("auto", "Detect automatically"), ("en", "English"), ("es", "Spanish"),
        ("fr", "French"), ("de", "German"), ("it", "Italian"), ("pt", "Portuguese"),
        ("nl", "Dutch"), ("ja", "Japanese"), ("zh", "Chinese"), ("mi", "Māori")
    ]
}
