import AppKit
import AVFoundation
import ApplicationServices
import Combine
import FoundationModels
import ServiceManagement

// MARK: - Permissions

enum Permissions {
    static var microphoneGranted: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    static var microphoneUndecided: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined }

    static func requestMicrophone(_ done: @escaping @MainActor (Bool) -> Void) {
        if microphoneUndecided {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in done(granted) }
            }
        } else {
            openPane("Privacy_Microphone")
            Task { @MainActor in done(microphoneGranted) }
        }
    }

    /// Needed to hear the shortcut from any app and to paste for you.
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        openPane("Privacy_Accessibility")
    }

    static func openPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Launch at login

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.app.error("Login item: \(error.localizedDescription)")
        }
    }
}

// MARK: - Sounds

enum Sounds {
    enum Cue: String { case start = "Tink", lock = "Pop", cancel = "Bottle" }
    private static var cache: [Cue: NSSound] = [:]

    static func play(_ cue: Cue) {
        guard SettingsStore.shared.soundsEnabled else { return }
        let sound = cache[cue] ?? NSSound(named: NSSound.Name(cue.rawValue))
        guard let sound else { return }
        cache[cue] = sound
        sound.volume = 0.22
        sound.stop()
        sound.play()
    }
}

// MARK: - History

struct Dictation: Identifiable, Codable, Equatable {
    var id = UUID()
    var text: String
    var date: Date
}

@MainActor
final class History: ObservableObject {
    static let shared = History()
    @Published private(set) var items: [Dictation] = []
    private let maxItems = 30
    private let url = ModelStorage.support.appendingPathComponent("history.json")

    private init() {
        if SettingsStore.shared.keepHistory, let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([Dictation].self, from: data) {
            items = decoded
        }
    }

    func add(_ text: String) {
        items.insert(Dictation(text: text, date: Date()), at: 0)
        if items.count > maxItems { items.removeLast(items.count - maxItems) }
        save()
    }

    /// Sample items for the design-render dev hook (not saved).
    func previewFill(_ texts: [String]) {
        items = texts.enumerated().map { Dictation(text: $1, date: Date().addingTimeInterval(-Double($0 + 1) * 1500)) }
    }

    func remove(_ item: Dictation) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func clear() {
        items.removeAll()
        save()
    }

    /// Keeps only the latest dictation in memory when history is off.
    func save() {
        guard SettingsStore.shared.keepHistory else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: url, options: .atomic) }
    }
}

// MARK: - Vocabulary

final class VocabularyStore: ObservableObject {
    static let shared = VocabularyStore()

    /// Names, brands and jargon to bias the speech model towards.
    @Published var terms: [String] { didSet { save() } }
    /// "misheard" → "correct", applied after transcription.
    @Published var corrections: [String: String] { didSet { save() } }

    private let url = ModelStorage.support.appendingPathComponent("vocabulary.json")
    private struct Stored: Codable { var terms: [String]; var corrections: [String: String] }

    private init() {
        if let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(Stored.self, from: data) {
            terms = s.terms
            corrections = s.corrections
        } else {
            terms = []
            corrections = [:]
        }
    }

    private var previewing = false

    /// Sample data for the design-render dev hook (not saved).
    func previewFill(terms: [String], corrections: [String: String]) {
        previewing = true
        self.terms = terms
        self.corrections = corrections
    }

    private func save() {
        guard !previewing else { return }
        if let data = try? JSONEncoder().encode(Stored(terms: terms, corrections: corrections)) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Ask AI (Apple Intelligence, on device)

enum AskAI {
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static var unavailableReason: String {
        switch SystemLanguageModel.default.availability {
        case .available: return ""
        case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in System Settings to use Ask AI."
        case .unavailable(.modelNotReady): return "Apple Intelligence is still downloading. Try again soon."
        case .unavailable(.deviceNotEligible): return "This Mac doesn't support Apple Intelligence."
        default: return "Apple Intelligence isn't available right now."
        }
    }

    static func respond(to request: String) async -> String {
        let req = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !req.isEmpty, isAvailable else { return "" }
        let instructions = """
        You are a capable assistant inside a dictation app. Do exactly what the user asks and \
        produce the finished content they want. Output ONLY that text, ready to paste: no \
        preamble such as "Sure" or "Here is", no sign-off, no quotes, no commentary. Match the \
        length to the task.
        """
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: "Request: \(req)\n\nWrite the finished result now.")
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            Log.app.error("Ask AI failed: \(error.localizedDescription)")
            return ""
        }
    }
}
