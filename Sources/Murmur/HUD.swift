import SwiftUI
import AppKit

enum HUDTone: Equatable { case neutral, warning }

enum HUDContent: Equatable {
    case hidden
    case recording(mode: CaptureMode, locked: Bool, started: Date)
    case working(mode: CaptureMode)
    case done(copied: Bool)
    case message(symbol: String, title: String, detail: String?, tone: HUDTone)

    /// Only the locked pill has buttons; otherwise clicks pass straight through.
    var isInteractive: Bool {
        if case .recording(_, true, _) = self { return true }
        return false
    }
}

@MainActor
final class HUDModel: ObservableObject {
    @Published var content: HUDContent = .hidden
    @Published var visible = false
}

/// The floating pill at the bottom of the screen. A borderless, non-activating
/// panel, so it never takes focus from the app you're dictating into.
@MainActor
final class HUDController {
    let model = HUDModel()
    var content: HUDContent { model.content }
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    static let size = NSSize(width: 560, height: 170)

    func show(_ content: HUDContent, autoHide: TimeInterval? = nil) {
        Log.app.info("HUD show \(String(describing: content), privacy: .public)")
        hideWork?.cancel()
        if panel == nil { build() }
        if !model.visible {
            reposition()
            panel?.orderFrontRegardless()
        }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
            model.content = content
            model.visible = true
        }
        panel?.ignoresMouseEvents = !content.isInteractive
        if let autoHide {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + autoHide, execute: work)
        }
    }

    func hide() {
        hideWork?.cancel()
        withAnimation(.easeIn(duration: 0.18)) { model.visible = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            guard let self, !self.model.visible else { return }
            self.panel?.orderOut(nil)
            self.model.content = .hidden
        }
    }

    private func build() {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .screenSaver            // above full-screen apps too
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false               // the pill draws its own
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        let host = NSHostingView(rootView: HUDView(model: model))
        host.frame = NSRect(origin: .zero, size: Self.size)
        panel.contentView = host
        self.panel = panel
    }

    /// Bottom-centre of whichever screen the pointer is on.
    private func reposition() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: frame.midX - Self.size.width / 2, y: frame.minY + 28))
    }
}

// MARK: - Views

struct HUDView: View {
    @ObservedObject var model: HUDModel
    var previewLevel: Float? = nil
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            if model.visible, model.content != .hidden {
                pill
                    .transition(.scale(scale: 0.85, anchor: .bottom).combined(with: .opacity))
                if case .recording(_, true, _) = model.content {
                    hint.transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .padding(.bottom, 26)
        .frame(width: HUDController.size.width, height: HUDController.size.height)
    }

    /// Message mode tints the whole pill teal, so it's obvious at a glance.
    private var isMessage: Bool {
        switch model.content {
        case .recording(.message, _, _), .working(.message): return true
        default: return false
        }
    }

    private var pill: some View {
        content
            .padding(.horizontal, 18)
            .frame(height: 50)
            .frame(minWidth: 50)
            .background(
                Capsule(style: .continuous)
                    .fill((isMessage ? HUDColor.messagePill : HUDColor.pill).opacity(0.97))
                    .overlay(Capsule(style: .continuous)
                        .strokeBorder(isMessage ? HUDColor.messageEdge : HUDColor.edge, lineWidth: isMessage ? 1.5 : 1))
                    .shadow(color: HUDColor.shadow, radius: 18, y: 8)
            )
    }

    @ViewBuilder private var content: some View {
        switch model.content {
        case .hidden:
            EmptyView()
        case .recording(let mode, let locked, let started):
            HStack(spacing: 14) {
                if mode == .message {
                    MessageBadge()
                } else if locked {
                    Image(systemName: "lock.fill").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(HUDColor.accent)
                } else if mode == .ask {
                    Image(systemName: "sparkles").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(LinearGradient(colors: HUDColor.glow,
                                                        startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                VoiceBars(preview: previewLevel)
                ElapsedText(started: started)
                if locked {
                    HStack(spacing: 8) {
                        HUDButton(symbol: "xmark", filled: false, help: "Cancel") {
                            AppState.shared.cancelRecording(quietly: false)
                        }
                        HUDButton(symbol: "checkmark", filled: true, help: "Finish and insert") {
                            AppState.shared.finishRecording()
                        }
                    }
                    .padding(.leading, 2)
                }
            }
        case .working(let mode):
            HStack(spacing: 12) {
                ThinkingDots()
                if mode == .message {
                    Image(systemName: "text.bubble.fill").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(HUDColor.messageAccent)
                }
                Text(mode == .ask ? "Thinking" : mode == .message ? "Tidying your message" : "Transcribing")
                    .font(GoogleSans.font(14, 500))
                    .foregroundStyle(HUDColor.text)
            }
        case .done(let copied):
            HStack(spacing: 10) {
                Image(systemName: copied ? "doc.on.clipboard.fill" : "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(HUDColor.onSuccess)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(HUDColor.success))
                if copied {
                    Text("Copied — no text field. Paste with ⌘V")
                        .font(GoogleSans.font(14, 500))
                        .foregroundStyle(HUDColor.text)
                }
            }
            .padding(.horizontal, copied ? 0 : -5)
        case .message(let symbol, let title, let detail, let tone):
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tone == .warning ? HUDColor.warning : HUDColor.textMuted)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(GoogleSans.font(14, 500)).foregroundStyle(HUDColor.text)
                    if let detail {
                        Text(detail).font(GoogleSans.font(12, 400)).foregroundStyle(HUDColor.textMuted)
                    }
                }
                .lineLimit(1)
            }
        }
    }

    private var hintKey: TriggerKey {
        if case .recording(.ask, _, _) = model.content { return settings.askTrigger }
        return settings.trigger
    }

    private var hint: some View {
        Text(isMessage ? "Message mode   ·   tap \(hintKey.symbol) to finish   ·   esc to cancel"
                       : "Tap \(hintKey.symbol) to finish   ·   esc to cancel")
            .font(GoogleSans.font(12, 500))
            .foregroundStyle(HUDColor.text.opacity(0.85))
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(Capsule().fill(HUDColor.pill.opacity(0.9)))
    }
}

/// "Message" chip at the start of the pill in message mode.
private struct MessageBadge: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.bubble.fill").font(.system(size: 12, weight: .semibold))
            Text("Message").font(GoogleSans.font(13, 600))
        }
        .foregroundStyle(HUDColor.onMessageChip)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Capsule().fill(HUDColor.messageChip))
    }
}

private struct HUDButton: View {
    let symbol: String
    let filled: Bool
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(filled ? HUDColor.onAccent : HUDColor.text)
                .frame(width: 30, height: 30)
                .background(Circle().fill(filled ? HUDColor.accent : HUDColor.text.opacity(hovering ? 0.14 : 0.08)))
                .brightness(filled && hovering ? 0.06 : 0)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct ElapsedText: View {
    let started: Date
    var body: some View {
        TimelineView(.periodic(from: started, by: 1)) { ctx in
            let s = max(0, Int(ctx.date.timeIntervalSince(started)))
            Text(String(format: "%d:%02d", s / 60, s % 60))
                .font(GoogleSans.font(13, 500))
                .monospacedDigit()
                .foregroundStyle(HUDColor.textMuted)
                .frame(minWidth: 32, alignment: .leading)
        }
    }
}

/// Four bars in Bartley's colours that rise with your voice (dots when you're quiet).
struct VoiceBars: View {
    var preview: Float? = nil   // fixed level for design previews
    @State private var motion = BarMotion()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60)) { ctx in
            let heights = preview.map { BarMotion.still(level: $0) }
                ?? motion.step(time: ctx.date.timeIntervalSinceReferenceDate, level: LevelMeter.shared.takePeak())
            HStack(spacing: 5) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule().fill(M3.brand[i]).frame(width: 7, height: heights[i])
                }
            }
            .frame(height: 30)
        }
    }
}

/// Smoothed bar heights, kept across frames.
final class BarMotion {
    private var heights: [CGFloat] = [7, 7, 7, 7]
    private var level: CGFloat = 0
    private let weights: [CGFloat] = [0.72, 1.0, 0.86, 0.62]
    private let phases: [Double] = [0, 1.7, 3.1, 4.4]

    /// A fixed pose, for design previews.
    static func still(level: Float) -> [CGFloat] {
        [0.62, 1.0, 0.78, 0.45].map { 7 + (30 - 7) * CGFloat(level) * $0 }
    }

    func step(time t: Double, level raw: Float) -> [CGFloat] {
        let target = CGFloat(raw)
        level += (target - level) * (target > level ? 0.5 : 0.12)   // quick rise, gentle fall
        for i in 0..<4 {
            let wobble = 0.65 + 0.35 * sin(t * 9 + phases[i])
            let idle = 1.5 * sin(t * 3 + phases[i])                  // breathe while quiet
            let goal = 7 + (30 - 7) * level * weights[i] * CGFloat(wobble) + CGFloat(idle) * (1 - level)
            heights[i] += (max(7, goal) - heights[i]) * 0.35
        }
        return heights
    }
}

/// The "working" state: the four colours bouncing in turn.
struct ThinkingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<4, id: \.self) { i in
                    let bounce = max(0, sin(t * 7 - Double(i) * 0.75))
                    Circle().fill(M3.brand[i]).frame(width: 7, height: 7)
                        .offset(y: -6 * bounce)
                }
            }
            .frame(height: 30)
        }
    }
}

/// The pill's colours: Bartley's rust scheme, light or dark with the app's Appearance setting.
/// Dark is neutral off-black with the rust accent, like the window.
enum HUDColor {
    static let pill      = Color(light: 0xFFFFFF, dark: 0x1E1E1E)
    static let edge      = Color(light: 0xEBDFD9, dark: 0x363636)
    static let shadow    = Color(nsColor: NSColor(name: nil) { a in
        NSColor.black.withAlphaComponent(a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.32 : 0.16)
    })
    static let text      = Color(light: 0x231A16, dark: 0xECECEC)
    static let textMuted = Color(light: 0x53443E, dark: 0xB3B3B3)
    static let accent    = Color(light: 0xA8461F, dark: 0xEF8B63)
    static let onAccent  = Color(light: 0xFFFFFF, dark: 0x200B03)
    static let success   = Color(light: 0xC4EED0, dark: 0x6DD58C)
    static let onSuccess = Color(light: 0x146C2E, dark: 0x0F5223)
    static let warning   = Color(light: 0x8C4F00, dark: 0xFDD663)
    /// Message mode: Bartley's teal scheme.
    static let messagePill   = Color(light: 0xF0FAF9, dark: 0x122423)
    static let messageEdge   = Color(light: 0x80CFCD, dark: 0x2E6766)
    static let messageAccent = Color(light: 0x00696A, dark: 0x80D4D5)
    static let messageChip   = Color(light: 0x9CF1EF, dark: 0x004F50)
    static let onMessageChip = Color(light: 0x002020, dark: 0x9CF1F1)
    /// Ask AI's sparkle: the site's glow pastels on dark, the brand colours at full strength on light.
    static let glow: [Color] = [(0xD1643B, 0xFFB59A), (0xB76E88, 0xF5A3BF), (0x9277BB, 0xC6A9F1), (0x4C8F85, 0x8FD3C7)]
        .map { Color(light: $0.0, dark: $0.1) }
}
