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
              let image = NSImage(contentsOf: url),
              let dockImage = Self.dockSizedImage(from: image) else { return }

        NSApp.applicationIconImage = dockImage
        NSApp.dockTile.display()
        lastAppliedDark = dark
    }

    /// Icon Composer exports the complete rounded tile edge-to-edge. That is
    /// correct for an asset catalog, but `applicationIconImage` bypasses the
    /// system's normal macOS icon-grid inset. Centre the tile on Apple's
    /// 824-by-824 optical canvas so it matches neighbouring Dock icons.
    private static func dockSizedImage(from source: NSImage) -> NSImage? {
        let canvasPixels = 1024
        let iconPixels = 824
        let inset = (canvasPixels - iconPixels) / 2

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: canvasPixels,
            pixelsHigh: canvasPixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return nil
        }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: canvasPixels, height: canvasPixels).fill()
        source.draw(
            in: NSRect(x: inset, y: inset, width: iconPixels, height: iconPixels),
            from: NSRect(origin: .zero, size: source.size),
            operation: .sourceOver,
            fraction: 1
        )

        let image = NSImage(size: NSSize(width: canvasPixels, height: canvasPixels))
        image.addRepresentation(bitmap)
        return image
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
