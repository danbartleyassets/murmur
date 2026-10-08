import SwiftUI
import AppKit

enum Page: String, CaseIterable, Identifiable {
    case home, general, dictation, vocabulary, ask
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .general: return "General"
        case .dictation: return "Dictation"
        case .vocabulary: return "Vocabulary"
        case .ask: return "Ask AI"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .general: return "gearshape"
        case .dictation: return "waveform"
        case .vocabulary: return "character.book.closed"
        case .ask: return "sparkles"
        }
    }

    /// The filled variant for the selected tab, where SF Symbols has one
    /// (there's no "waveform.fill" or "sparkles.fill").
    var selectedSymbol: String {
        let filled = symbol + ".fill"
        return NSImage(systemSymbolName: filled, accessibilityDescription: nil) != nil ? filled : symbol
    }
}

@MainActor
final class Navigation: ObservableObject {
    @Published var page: Page = .home
}

/// The one window: a Google-style navigation drawer and a content sheet.
struct MainView: View {
    @ObservedObject var nav: Navigation
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(nav: nav)
            Group {
                if DevHooks.isRendering {
                    // Window snapshots can't see inside a scroll view.
                    VStack { pageContent; Spacer(minLength: 0) }
                } else {
                    ScrollView { pageContent }.scrollIndicators(.automatic)
                }
            }
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(M3.surface))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(.vertical, 10)
            .padding(.trailing, 10)
        }
        .background(M3.background)
        .ignoresSafeArea()
        .frame(minWidth: 820, minHeight: 600)
        .tint(M3.primary)
    }
}

extension MainView {
    var pageContent: some View {
        Group {
            switch nav.page {
            case .home: HomePage(nav: nav)
            case .general: GeneralPage()
            case .dictation: DictationPage()
            case .vocabulary: VocabularyPage()
            case .ask: AskPage()
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
        .padding(.horizontal, 40)
        .padding(.top, 36)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @ObservedObject var nav: Navigation
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                BrandMark(size: 30)
                Text("Murmur").font(GoogleSans.font(22, 450)).foregroundStyle(M3.onSurface)
            }
            .padding(.leading, 16)
            .padding(.top, 54)
            .padding(.bottom, 22)

            ForEach(Page.allCases) { page in
                NavItem(page: page, selected: nav.page == page) {
                    withAnimation(.easeOut(duration: 0.15)) { nav.page = page }
                }
            }
            Spacer()
            OverallStatus()
                .padding(.leading, 12)
                .padding(.bottom, 20)
        }
        .padding(.horizontal, 12)
        .frame(width: 236)
    }
}

private struct NavItem: View {
    let page: Page
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: selected ? page.selectedSymbol : page.symbol)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 22)
                Text(page.title).font(GoogleSans.font(14, selected ? 600 : 500))
                Spacer()
            }
            .foregroundStyle(selected ? M3.onSecondaryContainer : M3.onSurfaceVariant)
            .padding(.horizontal, 16)
            .frame(height: 40)
            .background(Capsule().fill(selected ? M3.secondaryContainer : M3.onSurface.opacity(hovering ? 0.06 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The status chip shown under the navigation.
struct OverallStatus: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        switch (state.phase, state.model) {
        case (.listening, _): StatusChip(text: state.locked ? "Hands-free" : "Listening", tone: .live)
        case (.transcribing, _), (.thinking, _): StatusChip(text: "Working", tone: .busy)
        case (_, .downloading(let f)): StatusChip(text: "Downloading \(Int(f * 100))%", tone: .busy)
        case (_, .preparing): StatusChip(text: "Preparing model", tone: .busy)
        case (_, .failed): StatusChip(text: "Model error", tone: .warning)
        default:
            if !state.micGranted || !state.accessibilityGranted {
                StatusChip(text: "Setup needed", tone: .warning)
            } else if state.inputDeviceName == nil {
                StatusChip(text: "No microphone", tone: .warning)
            } else if !settings.enabled {
                StatusChip(text: "Paused", tone: .neutral)
            } else {
                StatusChip(text: "Ready", tone: .good)
            }
        }
    }
}

// MARK: - Page scaffolding

struct PageHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(GoogleSans.headline).foregroundStyle(M3.onSurface)
            if let subtitle {
                Text(subtitle).font(GoogleSans.font(15, 400)).foregroundStyle(M3.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 26)
    }
}

// MARK: - Home

private struct HomePage: View {
    @ObservedObject var nav: Navigation
    @EnvironmentObject private var state: AppState
    @ObservedObject private var settings = SettingsStore.shared

    private var headline: String {
        if state.setupComplete { return settings.enabled ? "Ready when you are" : "Dictation is paused" }
        if state.micGranted && state.accessibilityGranted && state.inputDeviceName == nil { return "Connect a microphone" }
        if state.micGranted && state.accessibilityGranted { return "Almost there" }
        return "Let's get you set up"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: headline,
                       subtitle: "Talk instead of typing, in any app. Everything is transcribed on this Mac — nothing leaves it.")
                .padding(.bottom, -6)

            if !state.setupComplete { SetupCard() }
            ShortcutsCard()
            TryItCard()
            RecentCard()
        }
    }
}

private struct SetupCard: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Card {
            SectionTitle(text: "Setup").padding(.bottom, 6)
            SetupStep(number: 1, done: state.micGranted && state.inputDeviceName != nil,
                      title: state.micGranted ? "Connect a microphone" : "Allow the microphone",
                      detail: micDetail) {
                if !state.micGranted {
                    Button("Allow") { state.requestMicrophone() }.buttonStyle(FilledButtonStyle())
                }
            }
            RowDivider(inset: 48)
            SetupStep(number: 2, done: state.accessibilityGranted, title: "Allow Accessibility",
                      detail: state.accessibilityGranted
                        ? "Murmur can hear the shortcut and paste for you."
                        : "Lets Murmur hear the shortcut in any app and paste your words. Switch Murmur on in the list that opens.") {
                Button("Open Settings") { state.requestAccessibility() }.buttonStyle(FilledButtonStyle())
            }
            RowDivider(inset: 48)
            ModelStep()
        }
    }

    private var micDetail: String {
        if !state.micGranted { return "So Murmur can hear you." }
        if let name = state.inputDeviceName { return "Using \(name)." }
        return "Access is allowed, but no microphone is connected. This Mac has none built in — connect AirPods, a headset, a USB mic or a webcam with a mic, or use your iPhone."
    }
}

private struct SetupStep<Action: View>: View {
    let number: Int
    let done: Bool
    let title: String
    let detail: String
    @ViewBuilder var action: Action

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle().fill(done ? M3.successContainer : M3.primaryContainer)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(M3.success)
                } else {
                    Text("\(number)").font(GoogleSans.font(14, 600)).foregroundStyle(M3.onPrimaryContainer)
                }
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(GoogleSans.font(15, 500)).foregroundStyle(M3.onSurface)
                Text(detail).font(GoogleSans.bodySmall).foregroundStyle(M3.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if !done { action }
        }
        .padding(.vertical, 12)
    }
}

private struct ModelStep: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle().fill(state.model.isReady ? M3.successContainer : M3.primaryContainer)
                if state.model.isReady {
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(M3.success)
                } else {
                    Text("3").font(GoogleSans.font(14, 600)).foregroundStyle(M3.onPrimaryContainer)
                }
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 6) {
                Text("Speech model").font(GoogleSans.font(15, 500)).foregroundStyle(M3.onSurface)
                switch state.model {
                case .idle:
                    detail("Starting…")
                case .downloading(let f):
                    detail("Downloading Distil-Whisper (1.4 GB) — \(Int(f * 100))%. First run only.")
                    LinearProgress(value: f).frame(maxWidth: 320)
                case .preparing(let first):
                    detail(first ? "Optimising for this Mac's Neural Engine. One-time, about 2 minutes."
                                 : "Loading…")
                    LinearProgress(value: nil).frame(maxWidth: 320)
                case .ready:
                    detail("\(SpeechModel.named(SettingsStore.shared.modelName).name), running on this Mac.")
                case .failed(let message):
                    detail("Couldn't load: \(message)")
                }
            }
            Spacer(minLength: 12)
            if case .failed = state.model {
                Button("Try again") { state.reloadModel() }.buttonStyle(FilledButtonStyle())
            }
        }
        .padding(.vertical, 12)
    }

    private func detail(_ text: String) -> some View {
        Text(text).font(GoogleSans.bodySmall).foregroundStyle(M3.onSurfaceVariant)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ShortcutsCard: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        Card {
            HStack {
                SectionTitle(text: "How to use it")
                Spacer()
                Text(state.heldKey != nil ? "Key detected" : (state.accessibilityGranted ? "Press \(settings.trigger.symbol) to check" : "Needs Accessibility"))
                    .font(GoogleSans.labelSmall)
                    .foregroundStyle(state.heldKey != nil ? M3.primary : M3.onSurfaceVariant)
            }
            .padding(.bottom, 8)
            ShortcutRow(keys: [settings.trigger.symbol, settings.trigger.symbol], hold: true, pressed: state.heldKey == .dictate,
                        title: "Hold to talk", detail: "Double-tap and keep holding. Let go to paste.")
            RowDivider(inset: 0)
            ShortcutRow(keys: [settings.trigger.symbol, settings.trigger.symbol, settings.trigger.symbol], hold: false,
                        pressed: state.heldKey == .dictate,
                        title: "Hands-free", detail: "Triple-tap, then talk as long as you like. Tap \(settings.trigger.symbol) once to finish.")
            RowDivider(inset: 0)
            ShortcutRow(keys: ["esc"], hold: false, title: "Cancel", detail: "Throws the recording away.")
            if settings.askEnabled {
                RowDivider(inset: 0)
                ShortcutRow(keys: [settings.askTrigger.symbol, settings.askTrigger.symbol], hold: true,
                            pressed: state.heldKey == .ask,
                            title: "Ask AI", detail: "Say a request; the answer is pasted instead of your words.")
            }
        }
    }
}

private struct ShortcutRow: View {
    let keys: [String]
    let hold: Bool
    var pressed = false
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 18) {
            HStack(spacing: 6) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in KeyCap(label: key, pressed: pressed) }
                if hold {
                    Text("hold").font(GoogleSans.labelSmall).foregroundStyle(M3.onSurfaceVariant).padding(.leading, 2)
                }
            }
            .frame(width: 150, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(GoogleSans.font(15, 500)).foregroundStyle(M3.onSurface)
                Text(detail).font(GoogleSans.bodySmall).foregroundStyle(M3.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
    }
}

private struct TryItCard: View {
    @ObservedObject private var settings = SettingsStore.shared
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        Card {
            HStack {
                SectionTitle(text: "Try it here")
                Spacer()
                if !text.isEmpty {
                    Button("Clear") { text = "" }.buttonStyle(TextButtonStyle())
                        .padding(.vertical, -8)
                }
            }
            .padding(.bottom, 12)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(GoogleSans.font(15, 400))
                    .foregroundStyle(M3.onSurface)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 12)
                if text.isEmpty {
                    Text("Click here, double-tap \(settings.trigger.symbol) and hold, then say something.")
                        .font(GoogleSans.font(15, 400))
                        .foregroundStyle(M3.onSurfaceVariant.opacity(0.75))
                        .padding(.horizontal, 15)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 110)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(M3.surface))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(focused ? M3.primary : M3.outlineVariant, lineWidth: focused ? 2 : 1))
        }
    }
}

private struct RecentCard: View {
    @ObservedObject private var history = History.shared
    @State private var expanded = false

    var body: some View {
        if !history.items.isEmpty {
            Card(padding: 20) {
                HStack {
                    SectionTitle(text: "Recent")
                    Spacer()
                    if history.items.count > 4 {
                        Button(expanded ? "Show less" : "Show all") {
                            withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() }
                        }
                        .buttonStyle(TextButtonStyle())
                        .padding(.vertical, -8)
                    }
                }
                .padding(.bottom, 6)
                let shown = expanded ? history.items : Array(history.items.prefix(4))
                ForEach(shown) { item in
                    RecentRow(item: item)
                    if item.id != shown.last?.id { RowDivider(inset: 0) }
                }
            }
        }
    }
}

private struct RecentRow: View {
    let item: Dictation
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.text).font(GoogleSans.body).foregroundStyle(M3.onSurface)
                    .lineLimit(3).textSelection(.enabled)
                Text(item.date, format: .relative(presentation: .named))
                    .font(GoogleSans.bodySmall).foregroundStyle(M3.onSurfaceVariant)
            }
            Spacer(minLength: 8)
            HStack(spacing: 0) {
                IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                }
                IconButton(symbol: "trash", help: "Delete") { History.shared.remove(item) }
            }
            .opacity(hovering || copied ? 1 : 0)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

// MARK: - General

private struct GeneralPage: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var settings = SettingsStore.shared
    @State private var loginItem = LoginItem.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "General")

            Card {
                SectionTitle(text: "Shortcut key").padding(.bottom, 4)
                Text("Double-tap and hold to talk, triple-tap for hands-free.")
                    .font(GoogleSans.bodySmall).foregroundStyle(M3.onSurfaceVariant)
                    .padding(.bottom, 14)
                SegmentedButtons(options: TriggerKey.allCases.map { ($0, "\($0.symbol)  \($0.name)") },
                                 selection: $settings.trigger)
                    .onChange(of: settings.trigger) { _, new in
                        if settings.askTrigger == new {
                            settings.askTrigger = TriggerKey.allCases.first { $0 != new && $0 != .shift } ?? .control
                        }
                    }
            }

            Card(padding: 8) {
                VStack(spacing: 0) {
                    ListRow(symbol: "power", title: "Open at login",
                            detail: LoginItem.needsApproval ? "Approve Murmur in System Settings › Login Items." : "Keeps the model loaded so it's ready instantly.") {
                        M3Switch(isOn: Binding(get: { loginItem }, set: { LoginItem.set($0); loginItem = LoginItem.isEnabled }))
                    }
                    RowDivider(inset: 64)
                    ListRow(symbol: "speaker.wave.2", title: "Sounds", detail: "A soft click when recording starts and locks.") {
                        M3Switch(isOn: $settings.soundsEnabled)
                    }
                    RowDivider(inset: 64)
                    ListRow(symbol: "pause.circle", title: "Pause dictation", detail: "Ignore the shortcut until you switch this off.") {
                        M3Switch(isOn: Binding(get: { !settings.enabled }, set: { settings.enabled = !$0 }))
                    }
                }
                .padding(.horizontal, 12)
            }

            Card(padding: 8) {
                VStack(spacing: 0) {
                    ListRow(symbol: "mic", title: "Microphone",
                            detail: !state.micGranted ? "Access needed to hear you."
                                : (state.inputDeviceName.map { "Allowed · using \($0)" } ?? "Allowed · no microphone connected")) {
                        if !state.micGranted {
                            Button("Allow") { state.requestMicrophone() }.buttonStyle(FilledButtonStyle())
                        } else if state.inputDeviceName == nil {
                            StatusChip(text: "None connected", tone: .warning)
                        } else {
                            StatusChip(text: "Ready", tone: .good)
                        }
                    }
                    RowDivider(inset: 64)
                    ListRow(symbol: "accessibility", title: "Accessibility",
                            detail: state.accessibilityGranted ? "Allowed" : "Needed for the shortcut and pasting.") {
                        permissionTrailing(granted: state.accessibilityGranted) { state.requestAccessibility() }
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .onAppear { loginItem = LoginItem.isEnabled }
    }

    @ViewBuilder
    private func permissionTrailing(granted: Bool, action: @escaping () -> Void) -> some View {
        if granted {
            StatusChip(text: "On", tone: .good)
        } else {
            Button("Allow", action: action).buttonStyle(FilledButtonStyle())
        }
    }
}

// MARK: - Dictation

private struct DictationPage: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var history = History.shared
    @State private var devices: [AudioInputDevice] = []

    private var micOptions: [(String, String)] {
        let systemName = AudioDevices.defaultInput()?.name
        return [("", systemName.map { "System default (\($0))" } ?? "None connected")]
            + devices.map { ($0.uid, $0.name) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "Dictation")

            Card(padding: 8) {
                VStack(spacing: 0) {
                    ListRow(symbol: "mic", title: "Microphone", detail: "Tip: choose your Mac's mic while wearing AirPods to keep their sound quality.") {
                        Dropdown(options: micOptions, selection: $settings.inputDeviceUID, width: 240)
                    }
                    RowDivider(inset: 64)
                    ListRow(symbol: "cpu", title: "Speech model", detail: modelDetail) {
                        Dropdown(options: SpeechModel.all.map { ($0.id, $0.name) }, selection: $settings.modelName, width: 240)
                    }
                    RowDivider(inset: 64)
                    ListRow(symbol: "globe", title: "Language", detail: nil) {
                        Dropdown(options: SettingsStore.languages, selection: $settings.language, width: 240)
                    }
                }
                .padding(.horizontal, 12)
            }

            Card(padding: 8) {
                VStack(spacing: 0) {
                    ListRow(symbol: "text.bubble", title: "Voice commands",
                            detail: "Say “new line”, “new paragraph”, or “scratch that” to discard.") {
                        M3Switch(isOn: $settings.commandsEnabled)
                    }
                    RowDivider(inset: 64)
                    ListRow(symbol: "space", title: "Smart spacing", detail: "Adds a space when you carry on a sentence.") {
                        M3Switch(isOn: $settings.smartSpacing)
                    }
                    RowDivider(inset: 64)
                    ListRow(symbol: "keyboard", title: "Insert text by",
                            detail: settings.insertion == .paste ? "Fast. Your clipboard is put back afterwards." : "Slower, for apps that block pasting.") {
                        SegmentedButtons(options: [(InsertionMethod.paste, "Pasting"), (.type, "Typing")],
                                         selection: $settings.insertion)
                            .frame(width: 220)
                    }
                }
                .padding(.horizontal, 12)
            }

            Card(padding: 8) {
                VStack(spacing: 0) {
                    ListRow(symbol: "clock.arrow.circlepath", title: "Keep history",
                            detail: "Your last 30 dictations, stored only on this Mac.") {
                        M3Switch(isOn: $settings.keepHistory)
                            .onChange(of: settings.keepHistory) { _, _ in history.save() }
                    }
                    if !history.items.isEmpty {
                        RowDivider(inset: 64)
                        ListRow(symbol: "trash", title: "Clear history", detail: "\(history.items.count) saved") {
                            Button("Clear") { history.clear() }.buttonStyle(OutlinedButtonStyle())
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .onAppear { devices = AudioDevices.inputs() }
        .onChange(of: state.inputDeviceName) { _, _ in devices = AudioDevices.inputs() }
    }

    private var modelDetail: String {
        let model = SpeechModel.named(settings.modelName)
        switch state.model {
        case .ready: return "\(model.detail) Loaded."
        case .downloading(let f): return "Downloading — \(Int(f * 100))%"
        case .preparing(let first): return first ? "Optimising for this Mac (one-time)…" : "Loading…"
        case .failed(let m): return "Couldn't load: \(m)"
        case .idle: return model.detail
        }
    }
}

// MARK: - Vocabulary

private struct VocabularyPage: View {
    @ObservedObject private var vocab = VocabularyStore.shared
    @State private var newTerm = ""
    @State private var wrong = ""
    @State private var right = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "Vocabulary",
                       subtitle: "Teach Murmur the names and words you use, so they come out spelled right.")

            Card {
                SectionTitle(text: "Words to recognise").padding(.bottom, 4)
                Text("Names, brands and jargon. Near-misses are fixed automatically — “acupinol” becomes Acupanel, “Casero” becomes Kasaro.")
                    .font(GoogleSans.bodySmall).foregroundStyle(M3.onSurfaceVariant).padding(.bottom, 14)
                HStack(spacing: 10) {
                    M3TextField(placeholder: "Add a word", text: $newTerm, onSubmit: addTerm)
                    Button("Add", action: addTerm).buttonStyle(FilledButtonStyle())
                        .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if !vocab.terms.isEmpty {
                    FlowLayout(spacing: 8) {
                        ForEach(vocab.terms, id: \.self) { term in
                            InputChip(text: term) { vocab.terms.removeAll { $0 == term } }
                        }
                    }
                    .padding(.top, 16)
                }
            }

            Card {
                SectionTitle(text: "Corrections").padding(.bottom, 4)
                Text("For anything that still comes out wrong, swap it for the right word every time.")
                    .font(GoogleSans.bodySmall).foregroundStyle(M3.onSurfaceVariant).padding(.bottom, 14)
                HStack(spacing: 10) {
                    M3TextField(placeholder: "Heard as", text: $wrong, onSubmit: addCorrection)
                    Image(systemName: "arrow.right").foregroundStyle(M3.onSurfaceVariant)
                    M3TextField(placeholder: "Should be", text: $right, onSubmit: addCorrection)
                    Button("Add", action: addCorrection).buttonStyle(FilledButtonStyle())
                        .disabled(wrong.trimmingCharacters(in: .whitespaces).isEmpty || right.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if !vocab.corrections.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(vocab.corrections.sorted(by: { $0.key.lowercased() < $1.key.lowercased() }), id: \.key) { pair in
                            HStack(spacing: 12) {
                                Text(pair.key).font(GoogleSans.body).foregroundStyle(M3.onSurfaceVariant).strikethrough(color: M3.outline)
                                Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(M3.outline)
                                Text(pair.value).font(GoogleSans.font(14, 500)).foregroundStyle(M3.onSurface)
                                Spacer()
                                IconButton(symbol: "xmark", help: "Remove") { vocab.corrections.removeValue(forKey: pair.key) }
                            }
                            .padding(.vertical, 6)
                        }
                    }
                    .padding(.top, 12)
                }
            }
        }
    }

    private func addTerm() {
        let t = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !vocab.terms.contains(t) else { return }
        vocab.terms.append(t)
        newTerm = ""
    }

    private func addCorrection() {
        let w = wrong.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, !r.isEmpty else { return }
        vocab.corrections[w] = r
        wrong = ""; right = ""
    }
}

private struct InputChip: View {
    let text: String
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(text).font(GoogleSans.font(13.5, 500)).foregroundStyle(M3.onSurfaceVariant)
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(M3.onSurfaceVariant)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(M3.onSurface.opacity(hovering ? 0.10 : 0)))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(M3.surface))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(M3.outlineVariant, lineWidth: 1))
    }
}

/// Wraps chips onto as many lines as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Ask AI

private struct AskPage: View {
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "Ask AI",
                       subtitle: "Say what you want written and Murmur pastes the result — a reply, a summary, a list. It runs on Apple Intelligence, on this Mac.")

            Card(padding: 8) {
                VStack(spacing: 0) {
                    ListRow(symbol: "sparkles", title: "Ask AI shortcut",
                            detail: "Double-tap \(settings.askTrigger.name) and hold, say your request, let go.") {
                        M3Switch(isOn: $settings.askEnabled)
                    }
                    if !AskAI.isAvailable {
                        RowDivider(inset: 64)
                        ListRow(symbol: "exclamationmark.triangle", title: "Not available yet", detail: AskAI.unavailableReason) {
                            EmptyView()
                        }
                    }
                }
                .padding(.horizontal, 12)
            }

            if settings.askEnabled {
                Card {
                    SectionTitle(text: "Key").padding(.bottom, 14)
                    SegmentedButtons(options: TriggerKey.allCases.filter { $0 != settings.trigger }
                                        .map { ($0, "\($0.symbol)  \($0.name)") },
                                     selection: $settings.askTrigger)
                }

                Card {
                    SectionTitle(text: "Try saying").padding(.bottom, 12)
                    ForEach(["“Write a friendly reply saying Thursday works for me.”",
                             "“Turn this into three bullet points: …”",
                             "“Draft a short email to Jack about the container arriving on the ninth.”"], id: \.self) { example in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "quote.opening").font(.system(size: 11)).foregroundStyle(M3.primary)
                                .padding(.top, 3)
                            Text(example).font(GoogleSans.body).foregroundStyle(M3.onSurface)
                        }
                        .padding(.vertical, 5)
                    }
                }
            }
        }
    }
}
