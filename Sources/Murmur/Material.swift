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

/// One Material 3 scheme, light and dark. The light values are bartleystudio.com's own
/// (src/colour.css). The dark ones (10 Nov 2026) are neutral off-black surfaces with no
/// tint, shared by every scheme, so dark never reads as brown. Colour lives in the accent:
/// the primary, and the light accent ink on the neutral selected and busy fills.
struct Palette {
    let background, surface, container, containerHigh, containerHighest: Color
    let onSurface, onSurfaceVariant, outline, outlineVariant: Color
    let primary, onPrimary, primaryContainer, onPrimaryContainer: Color
    let secondaryContainer, onSecondaryContainer: Color

    /// Hex pairs in the order above: (light, dark).
    init(_ c: [(UInt32, UInt32)]) {
        let k = c.map { Color(light: $0.0, dark: $0.1) }
        (background, surface, container, containerHigh, containerHighest) = (k[0], k[1], k[2], k[3], k[4])
        (onSurface, onSurfaceVariant, outline, outlineVariant) = (k[5], k[6], k[7], k[8])
        (primary, onPrimary, primaryContainer, onPrimaryContainer) = (k[9], k[10], k[11], k[12])
        (secondaryContainer, onSecondaryContainer) = (k[13], k[14])
    }
}

/// The site's four schemes, each seeded from a product in Bartley's work.
enum SchemeName: String, CaseIterable {
    case rust, sage, teal, marigold

    var palette: Palette {
        switch self {
        case .rust: return Palette([
            (0xF7EBE5, 0x121212), (0xFFFFFF, 0x1A1A1A), (0xF7EBE5, 0x1E1E1E), (0xF1E5DF, 0x262626), (0xEBDFD9, 0x2F2F2F),
            (0x231A16, 0xECECEC), (0x53443E, 0xB3B3B3), (0x85736C, 0x8F8F8F), (0xD8C2BA, 0x363636),
            (0xA8461F, 0xEF8B63), (0xFFFFFF, 0x200B03), (0xFFDBCD, 0x2F2F2F), (0x380D00, 0xFFB79C),
            (0xFFDBCF, 0x2F2F2F), (0x2C160D, 0xFFB79C)])
        case .sage: return Palette([
            (0xECEFE4, 0x121212), (0xFFFFFF, 0x1A1A1A), (0xECEFE4, 0x1E1E1E), (0xE6E9DE, 0x262626), (0xE1E4D9, 0x2F2F2F),
            (0x1A1C17, 0xECECEC), (0x43483F, 0xB3B3B3), (0x73796E, 0x8F8F8F), (0xC3C8BB, 0x363636),
            (0x4A6741, 0xB0D1A2), (0xFFFFFF, 0x1D3716), (0xCBEDBC, 0x2F2F2F), (0x072106, 0xCBEDBC),
            (0xD6E8CD, 0x2F2F2F), (0x111F0E, 0xCBEDBC)])
        case .teal: return Palette([
            (0xE9EFEE, 0x121212), (0xFFFFFF, 0x1A1A1A), (0xE9EFEE, 0x1E1E1E), (0xE3E9E9, 0x262626), (0xDDE4E3, 0x2F2F2F),
            (0x161D1D, 0xECECEC), (0x3F4948, 0xB3B3B3), (0x6F7979, 0x8F8F8F), (0xBEC9C8, 0x363636),
            (0x00696A, 0x80D4D4), (0xFFFFFF, 0x003737), (0x9CF1EF, 0x2F2F2F), (0x002020, 0x9CF1EF),
            (0xCCE8E7, 0x2F2F2F), (0x051F1F, 0x9CF1EF)])
        case .marigold: return Palette([
            (0xF6ECE4, 0x121212), (0xFFFFFF, 0x1A1A1A), (0xF6ECE4, 0x1E1E1E), (0xF1E7DE, 0x262626), (0xEBE1D9, 0x2F2F2F),
            (0x201B16, 0xECECEC), (0x51453A, 0xB3B3B3), (0x827568, 0x8F8F8F), (0xD5C4B5, 0x363636),
            (0x875200, 0xFFB86A), (0xFFFFFF, 0x4A2800), (0xFFDCBC, 0x2F2F2F), (0x2C1700, 0xFFDCBC),
            (0xFEDCBE, 0x2F2F2F), (0x291806, 0xFFDCBC)])
        }
    }
}

/// The scheme on screen. Like the site, which takes the scheme of the section in view,
/// the window takes the scheme of the page that's open, and every colour blends across.
final class Theme: ObservableObject {
    static let shared = Theme()
    private static let palettes = Dictionary(uniqueKeysWithValues: SchemeName.allCases.map { ($0, $0.palette) })

    @Published private(set) var scheme: SchemeName = .rust
    private(set) var palette = SchemeName.rust.palette

    func show(_ next: SchemeName, animated: Bool = true) {
        guard next != scheme else { return }
        let change = { self.palette = Self.palettes[next]!; self.scheme = next }
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            withAnimation(.timingCurve(0.2, 0, 0, 1, duration: 1), change)
        } else {
            change()
        }
    }
}

enum M3 {
    private static var p: Palette { Theme.shared.palette }

    // Surfaces
    static var background: Color { p.background }
    static var surface: Color { p.surface }
    static var container: Color { p.container }
    static var containerHigh: Color { p.containerHigh }
    static var containerHighest: Color { p.containerHighest }

    // Content
    static var onSurface: Color { p.onSurface }
    static var onSurfaceVariant: Color { p.onSurfaceVariant }
    static var outline: Color { p.outline }
    static var outlineVariant: Color { p.outlineVariant }

    // Accent
    static var primary: Color { p.primary }
    static var onPrimary: Color { p.onPrimary }
    static var primaryContainer: Color { p.primaryContainer }
    static var onPrimaryContainer: Color { p.onPrimaryContainer }
    static var secondaryContainer: Color { p.secondaryContainer }
    static var onSecondaryContainer: Color { p.onSecondaryContainer }

    // Status
    static let success            = Color(light: 0x146C2E, dark: 0x6DD58C)
    static let successContainer   = Color(light: 0xC4EED0, dark: 0x243028)
    static let warning            = Color(light: 0x8C4F00, dark: 0xFDD663)
    static let warningContainer   = Color(light: 0xFFEFC3, dark: 0x353123)
    static let error              = Color(light: 0xB3261E, dark: 0xF2B8B5)

    // Bartley brand: the four colours of the site's gradient, at mark strength
    static let rust  = Color(hex: 0xD1643B)
    static let rose  = Color(hex: 0xB76E88)
    static let lilac = Color(hex: 0x9277BB)
    static let teal  = Color(hex: 0x4C8F85)
    static let brand: [Color] = [rust, rose, lilac, teal]
}

extension AppearanceMode {
    /// Light by default, as on bartleystudio.com; dark and "match the Mac" are options.
    @MainActor func apply() {
        switch self {
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .system: NSApp.appearance = nil
        }
    }
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

    @ObservedObject private var theme = Theme.shared
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

    @ObservedObject private var theme = Theme.shared
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

    @ObservedObject private var theme = Theme.shared
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

    @ObservedObject private var theme = Theme.shared
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
    @ObservedObject private var theme = Theme.shared
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

    @ObservedObject private var theme = Theme.shared
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

    @ObservedObject private var theme = Theme.shared
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
    @ObservedObject private var theme = Theme.shared
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

    @ObservedObject private var theme = Theme.shared
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

    @ObservedObject private var theme = Theme.shared
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

    @ObservedObject private var theme = Theme.shared
    let text: String
    var body: some View {
        Text(text).font(GoogleSans.title).foregroundStyle(M3.onSurface)
    }
}

/// A settings row: tonal icon, title, supporting text, trailing control.
struct ListRow<Trailing: View>: View {
    @ObservedObject private var theme = Theme.shared
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

    @ObservedObject private var theme = Theme.shared
    var inset: CGFloat = 52
    var body: some View {
        Rectangle().fill(M3.outlineVariant.opacity(0.6)).frame(height: 1).padding(.leading, inset)
    }
}

struct StatusChip: View {

    @ObservedObject private var theme = Theme.shared
    enum Tone { case good, busy, warning, neutral, live }
    let text: String
    let tone: Tone

    private var colors: (Color, Color) {
        switch tone {
        case .good: return (M3.successContainer, M3.success)
        case .busy: return (M3.primaryContainer, M3.onPrimaryContainer)
        case .warning: return (M3.warningContainer, M3.warning)
        case .neutral: return (M3.containerHigh, M3.onSurfaceVariant)
        case .live: return (M3.rust.opacity(0.14), M3.rust)
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
    @ObservedObject private var theme = Theme.shared
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
    @ObservedObject private var theme = Theme.shared
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

/// Bartley's four colours as a small mark.
struct BrandMark: View {
    @ObservedObject private var theme = Theme.shared
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
