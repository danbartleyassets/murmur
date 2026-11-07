import AppKit
import MurmurCore

/// Keeps Murmur's Dock and app-switcher icon aligned with the Mac's icon
/// appearance setting. The source artwork and renderings come from Apple's
/// Icon Composer; Murmur doesn't expose a second, app-specific choice.
@MainActor
final class AppIconManager {
    static let shared = AppIconManager()

    private var lastAppliedDark: Bool?
    private var appearanceTimer: Timer?

    private init() {}

    func start() {
        applyIfNeeded(force: true)

        // UserDefaults notifications aren't guaranteed for changes made in
        // System Settings, so use one stable, low-frequency timer as a fallback.
        // It replaces itself on restart and never accumulates work.
        appearanceTimer?.invalidate()
        appearanceTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in
                AppIconManager.shared.applyIfNeeded()
            }
        }
        appearanceTimer?.tolerance = 0.5
    }

    func stop() {
        appearanceTimer?.invalidate()
        appearanceTimer = nil
    }

    /// Reapply after activation-policy changes create a fresh Dock tile.
    func refreshDockTile() {
        applyIfNeeded(force: true)
    }

    private func applyIfNeeded(force: Bool = false) {
        let dark = Self.systemUsesDarkIcons
        guard force || dark != lastAppliedDark else { return }

        let resource = dark ? "AppIconSystemDark" : "AppIconSystemLight"
        guard let url = Bundle.main.url(forResource: resource, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return }

        NSApp.applicationIconImage = image
        NSApp.dockTile.display()
        lastAppliedDark = dark
    }

    private static var systemUsesDarkIcons: Bool {
        // macOS 26 stores the user's app-icon appearance independently from
        // Murmur's window appearance. Treat future dark variants the same way.
        IconAppearance.usesDarkIcons(
            iconTheme: UserDefaults.standard.string(forKey: "AppleIconAppearanceTheme"),
            // Graceful fallback for macOS versions that don't expose a
            // separate icon theme in the defaults search list.
            interfaceStyle: UserDefaults.standard.string(forKey: "AppleInterfaceStyle")
        )
    }
}
