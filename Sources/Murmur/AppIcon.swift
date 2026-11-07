import AppKit

/// Applies the user's icon choice to the Dock and app switcher.
@MainActor
enum AppIconManager {
    static func apply(_ mode: AppIconMode) {
        let resource = mode == .dark ? "AppIconDark" : "AppIcon"
        guard let url = Bundle.main.url(forResource: resource, withExtension: "icns"),
              let image = NSImage(contentsOf: url) else { return }

        NSApp.applicationIconImage = image
    }
}
