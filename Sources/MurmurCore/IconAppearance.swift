import Foundation

/// Resolves macOS's app-icon appearance independently from an individual
/// app's window appearance setting.
public enum IconAppearance {
    public static func usesDarkIcons(iconTheme: String?, interfaceStyle: String?) -> Bool {
        if let iconTheme {
            return iconTheme.localizedCaseInsensitiveContains("dark")
        }
        return interfaceStyle?.localizedCaseInsensitiveContains("dark") == true
    }
}
