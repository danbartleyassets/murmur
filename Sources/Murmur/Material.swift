import SwiftUI
import AppKit
import CoreText

// Murmur's design system: Material 3, as Google ships it on the web and Android
// (Gemini, Gmail, Google Account settings), set in Google Sans Flex.

// MARK: - Colour

extension Color {
    /// A colour that follows light/dark appearance.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }

    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

enum M3 {
    // Surfaces
    static let background         = Color(light: 0xF0F4F9, dark: 0x131314)
    static let surface            = Color(light: 0xFFFFFF, dark: 0x1E1F20)
    static let container          = Color(light: 0xF0F4F9, dark: 0x282A2C)
    static let containerHigh      = Color(light: 0xE9EEF6, dark: 0x333537)
    static let containerHighest   = Color(light: 0xDDE3EA, dark: 0x3C3F41)

    // Content
    static let onSurface          = Color(light: 0x1F1F1F, dark: 0xE3E3E3)
    static let onSurfaceVariant   = Color(light: 0x444746, dark: 0xC4C7C5)
    static let outline            = Color(light: 0x747775, dark: 0x8E918F)
    static let outlineVariant     = Color(light: 0xC4C7C5, dark: 0x444746)

    // Accent
    static let primary            = Color(light: 0x0B57D0, dark: 0xA8C7FA)
    static let onPrimary          = Color(light: 0xFFFFFF, dark: 0x062E6F)
    static let primaryContainer   = Color(light: 0xD3E3FD, dark: 0x0842A0)
    static let onPrimaryContainer = Color(light: 0x041E49, dark: 0xD3E3FD)
    static let secondaryContainer = Color(light: 0xC2E7FF, dark: 0x004A77)
    static let onSecondaryContainer = Color(light: 0x001D35, dark: 0xC2E7FF)

    // Status
    static let success            = Color(light: 0x146C2E, dark: 0x6DD58C)
    static let successContainer   = Color(light: 0xC4EED0, dark: 0x0F5223)
    static let warning            = Color(light: 0x8C4F00, dark: 0xFDD663)
    static let warningContainer   = Color(light: 0xFFEFC3, dark: 0x4D3800)
    static let error              = Color(light: 0xB3261E, dark: 0xF2B8B5)

    // Google brand
    static let blue   = Color(hex: 0x4285F4)
    static let red    = Color(hex: 0xEA4335)
    static let yellow = Color(hex: 0xFBBC04)
    static let green  = Color(hex: 0x34A853)
    static let brand: [Color] = [blue, red, yellow, green]
}

// MARK: - Type

/// Google Sans Flex, bundled with the app and registered at launch.
enum GoogleSans {
    static let family = "Google Sans Flex"
    private(set) static var isAvailable = false
    private static var cache: [String: Font] = [:]

    static func register() {
        let urls = [Bundle.main.resourceURL?.appendingPathComponent("Fonts/GoogleSansFlex.ttf"),
                    DevPaths.repoRoot?.appendingPathComponent("assets/fonts/GoogleSansFlex.ttf")]
        for case let url? in urls where FileManager.default.fileExists(atPath: url.path) {
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) || isRegistered {
                isAvailable = true
                return
            }
        }
        isAvailable = isRegistered
    }

    private static var isRegistered: Bool {
        NSFontManager.shared.availableFontFamilies.contains(family)
    }

    /// `weight` 100–900, `roundness` 0–100 (the ROND axis Material 3 Expressive uses).
    static func font(_ size: CGFloat, _ weight: CGFloat = 400, roundness: CGFloat = 0) -> Font {
        let key = "\(size)-\(weight)-\(roundness)"
        if let f = cache[key] { return f }
        let font: Font
        if isAvailable {
            let axes: [NSNumber: NSNumber] = [
                NSNumber(value: 0x77676874): NSNumber(value: Double(weight)),       // wght
                NSNumber(value: 0x6F70737A): NSNumber(value: Double(min(144, max(6, size)))), // opsz
                NSNumber(value: 0x524F4E44): NSNumber(value: Double(roundness))     // ROND
            ]
            let attributes: [CFString: Any] = [kCTFontFamilyNameAttribute: family,
                                               kCTFontVariationAttribute: axes]
            let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
            font = Font(CTFontCreateWithFontDescriptor(descriptor, size, nil))
        } else {
            font = .system(size: size, weight: weight >= 600 ? .semibold : weight >= 500 ? .medium : .regular)
        }
        cache[key] = font
        return font
    }

    // Material 3 type scale, tuned for desktop.
    static let display    = font(34, 400)
    static let headline   = font(26, 400)
    static let titleLarge = font(20, 400)
    static let title      = font(16, 500)
    static let titleSmall = font(14, 500)
    static let body       = font(14, 400)
    static let bodySmall  = font(12.5, 400)
    static let label      = font(14, 500)
    static let labelSmall = font(12, 500)
    static let overline   = font(11.5, 600)
}

// MARK: - Buttons

struct FilledButtonStyle: ButtonStyle {
    var tint: Color = M3.primary
    var onTint: Color = M3.onPrimary
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(GoogleSans.label)
            .foregroundStyle(enabled ? onTint : M3.onSurface.opacity(0.38))
            .padding(.horizontal, 20)
            .frame(height: 36)
            .background(Capsule().fill(enabled ? tint : M3.onSurface.opacity(0.12)))
            .overlay(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.14 : 0)))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct TonalButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(GoogleSans.label)
            .foregroundStyle(enabled ? M3.onSecondaryContainer : M3.onSurface.opacity(0.38))
            .padding(.horizontal, 18)
            .frame(height: 36)
            .background(Capsule().fill(enabled ? M3.secondaryContainer : M3.onSurface.opacity(0.12)))
            .overlay(Capsule().fill(M3.onSecondaryContainer.opacity(configuration.isPressed ? 0.12 : hovering ? 0.08 : 0)))
            .contentShape(Capsule())
            .onHover { hovering = $0 }
    }
}

struct TextButtonStyle: ButtonStyle {
    var tint: Color = M3.primary
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(GoogleSans.label)
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Capsule().fill(tint.opacity(configuration.isPressed ? 0.12 : hovering ? 0.08 : 0)))
            .contentShape(Capsule())
            .onHover { hovering = $0 }
    }
}

struct OutlinedButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(GoogleSans.label)
            .foregroundStyle(M3.primary)
            .padding(.horizontal, 18)
            .frame(height: 36)
            .background(Capsule().fill(M3.primary.opacity(configuration.isPressed ? 0.12 : hovering ? 0.06 : 0)))
            .overlay(Capsule().strokeBorder(M3.outline, lineWidth: 1))
            .contentShape(Capsule())
            .onHover { hovering = $0 }
    }
}

/// Round icon-only button (copy, delete…).
struct IconButton: View {
    let symbol: String
    var help: String = ""
    var size: CGFloat = 32
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.44, weight: .medium))
                .foregroundStyle(M3.onSurfaceVariant)
                .frame(width: size, height: size)
                .background(Circle().fill(M3.onSurface.opacity(hovering ? 0.08 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Switch

/// Material 3 switch: a pill track with a thumb that grows and shows a check when on.
struct M3SwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
            Spacer(minLength: 8)
            M3Switch(isOn: configuration.$isOn)
        }
    }
}

struct M3Switch: View {
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? M3.primary : M3.containerHighest)
                .overlay(Capsule().strokeBorder(isOn ? Color.clear : M3.outline, lineWidth: 2))
                .frame(width: 46, height: 28)
            Circle()
                .fill(isOn ? M3.onPrimary : M3.outline)
                .frame(width: isOn ? 20 : 14, height: isOn ? 20 : 14)
                .overlay {
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(M3.primary)
                    }
                }
                .padding(.horizontal, isOn ? 4 : 7)
                .background(
                    Circle().fill((isOn ? M3.primary : M3.onSurface).opacity(hovering ? 0.10 : 0))
                        .frame(width: 34, height: 34)
                        .padding(.horizontal, isOn ? -3 : -3)
                )
        }
        .opacity(enabled ? 1 : 0.38)
        .contentShape(Capsule())
        .onTapGesture { withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) { isOn.toggle() } }
        .onHover { hovering = $0 }
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

// MARK: - Segmented button

struct SegmentedButtons<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                let selected = option.0 == selection
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { selection = option.0 }
                } label: {
                    HStack(spacing: 6) {
                        if selected {
                            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                        }
                        Text(option.1).lineLimit(1)
                    }
                    .font(GoogleSans.label)
                    .foregroundStyle(selected ? M3.onSecondaryContainer : M3.onSurface)
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background(selected ? M3.secondaryContainer : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if index < options.count - 1 {
                    Rectangle().fill(M3.outline).frame(width: 1, height: 36)
                }
            }
        }
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(M3.outline, lineWidth: 1))
    }
}

// MARK: - Dropdown

/// An outlined field that opens a menu, in place of the stock pop-up button.
struct Dropdown<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    var width: CGFloat? = 260

    private var label: String { options.first { $0.0 == selection }?.1 ?? "Choose…" }

    var body: some View {
        Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button {
                    selection = option.0
                } label: {
                    if option.0 == selection { Label(option.1, systemImage: "checkmark") } else { Text(option.1) }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(label).font(GoogleSans.body).foregroundStyle(M3.onSurface).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(M3.onSurfaceVariant)
            }
            .padding(.horizontal, 14)
            .frame(width: width, height: 38)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(M3.surface))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(M3.outlineVariant, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: - Text field

struct M3TextField: View {
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(M3.onSurfaceVariant.opacity(0.7)))
            .textFieldStyle(.plain)
            .font(GoogleSans.body)
            .foregroundStyle(M3.onSurface)
            .focused($focused)
            .onSubmit(onSubmit)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(M3.surface))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(focused ? M3.primary : M3.outlineVariant, lineWidth: focused ? 2 : 1))
    }
}

// MARK: - Layout pieces

struct Card<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(M3.container))
    }
}

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text).font(GoogleSans.title).foregroundStyle(M3.onSurface)
    }
}

/// A settings row: tonal icon, title, supporting text, trailing control.
struct ListRow<Trailing: View>: View {
    var symbol: String?
    let title: String
    var detail: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(M3.onPrimaryContainer)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(M3.primaryContainer))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(GoogleSans.font(15, 450)).foregroundStyle(M3.onSurface)
                if let detail {
                    Text(detail).font(GoogleSans.bodySmall).foregroundStyle(M3.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.vertical, 12)
    }
}

struct RowDivider: View {
    var inset: CGFloat = 52
    var body: some View {
        Rectangle().fill(M3.outlineVariant.opacity(0.6)).frame(height: 1).padding(.leading, inset)
    }
}

struct StatusChip: View {
    enum Tone { case good, busy, warning, neutral, live }
    let text: String
    let tone: Tone

    private var colors: (Color, Color) {
        switch tone {
        case .good: return (M3.successContainer, M3.success)
        case .busy: return (M3.primaryContainer, M3.onPrimaryContainer)
        case .warning: return (M3.warningContainer, M3.warning)
        case .neutral: return (M3.containerHigh, M3.onSurfaceVariant)
        case .live: return (M3.red.opacity(0.14), M3.red)
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(colors.1).frame(width: 7, height: 7)
            Text(text).font(GoogleSans.labelSmall)
        }
        .foregroundStyle(colors.1)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(Capsule().fill(colors.0))
    }
}

/// Material linear progress indicator (determinate, or a sliding bar when nil).
struct LinearProgress: View {
    var value: Double?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(M3.primaryContainer)
                if let value {
                    Capsule().fill(M3.primary)
                        .frame(width: max(4, geo.size.width * value))
                        .animation(.easeOut(duration: 0.3), value: value)
                } else {
                    TimelineView(.animation) { ctx in
                        let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                        Capsule().fill(M3.primary)
                            .frame(width: geo.size.width * 0.35)
                            .offset(x: (geo.size.width * 1.35) * t - geo.size.width * 0.35)
                    }
                    .clipShape(Capsule())
                }
            }
        }
        .frame(height: 4)
    }
}

/// A keyboard key, for showing shortcuts.
struct KeyCap: View {
    let label: String
    var pressed = false

    var body: some View {
        Text(label)
            .font(GoogleSans.font(label.count > 1 ? 12 : 15, 500))
            .foregroundStyle(pressed ? M3.onPrimary : M3.onSurface)
            .frame(minWidth: 30, minHeight: 30)
            .padding(.horizontal, label.count > 1 ? 8 : 0)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(pressed ? M3.primary : M3.surface)
                    .shadow(color: .black.opacity(pressed ? 0 : 0.10), radius: 0, x: 0, y: 1.5)
            )
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(pressed ? Color.clear : M3.outlineVariant, lineWidth: 1))
            .offset(y: pressed ? 1 : 0)
            .animation(.easeOut(duration: 0.08), value: pressed)
    }
}

/// Google's four colours as a small mark.
struct BrandMark: View {
    var size: CGFloat = 40
    var body: some View {
        HStack(spacing: size * 0.08) {
            ForEach(0..<4, id: \.self) { i in
                Capsule().fill(M3.brand[i])
                    .frame(width: size * 0.15, height: size * [0.42, 0.78, 0.56, 0.30][i])
            }
        }
        .frame(width: size, height: size)
    }
}

/// Lets the dev hooks find the repo's assets when running from `swift run`.
enum DevPaths {
    static var repoRoot: URL? {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) ? url : nil
    }
}
