import SwiftUI

extension Notification.Name {
    /// Posted after the active theme changes, so AppKit views (terminals, window) can
    /// recolor in place without a SwiftUI rebuild.
    static let utThemeChanged = Notification.Name("ut.themeChanged")
}

/// Owns the selected theme. Updates `Theme.current` (what every `Theme.X` reads),
/// persists the choice, and notifies so chrome + terminals recolor live.
@MainActor
final class ThemeStore: ObservableObject {
    @Published private(set) var palette: ThemePalette

    init() {
        let id = UserDefaults.standard.string(forKey: "ut.themeID") ?? "argus"
        let p = ThemePalette.byID(id)
        palette = p
        Theme.current = p
    }

    /// Drives SwiftUI rebuilds via `.id(themeID)` on the root content.
    var themeID: String { palette.id }

    func select(_ p: ThemePalette) {
        guard p.id != palette.id else { return }
        UserDefaults.standard.set(p.id, forKey: "ut.themeID")
        Theme.current = p
        palette = p
        NotificationCenter.default.post(name: .utThemeChanged, object: nil)
    }
}
