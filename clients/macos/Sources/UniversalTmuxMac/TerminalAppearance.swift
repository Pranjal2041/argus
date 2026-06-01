import AppKit
import SwiftTerm
import SwiftUI

/// Terminal-appearance preferences: font family, cursor style, and bell mode.
///
/// These are user-tunable cluster settings persisted via `@AppStorage`. The
/// keys are read directly by `TerminalController` (font family + cursor) and by
/// `PaneConn.bell` (bell mode), so this enum is the single source of truth for
/// the raw default values and the storage keys.
enum TermPrefs {
    static let fontFamilyKey = "ut.term.fontFamily"
    static let cursorStyleKey = "ut.term.cursorStyle"
    static let bellModeKey = "ut.term.bell"

    /// Default font family. "MesloLGS NF" matches the controller's historical
    /// default; resolution falls back gracefully if it isn't installed.
    static let defaultFontFamily = "MesloLGS NF"
    static let defaultCursorStyle = CursorPref.block.rawValue
    static let defaultBellMode = BellMode.audible.rawValue
}

/// Cursor shapes the user can pick. We use the *steady* SwiftTerm variants so
/// the caret doesn't blink (matches Warp/Ghostty defaults); the in-band DECSCUSR
/// escape can still override at runtime.
enum CursorPref: String, CaseIterable, Identifiable {
    case block, underline, bar
    var id: String { rawValue }
    var label: String {
        switch self {
        case .block: return "Block"
        case .underline: return "Underline"
        case .bar: return "Bar"
        }
    }
    var swiftTerm: SwiftTerm.CursorStyle {
        switch self {
        case .block: return .steadyBlock
        case .underline: return .steadyUnderline
        case .bar: return .steadyBar
        }
    }
}

/// What happens when a session rings the bell.
enum BellMode: String, CaseIterable, Identifiable {
    case audible, visual, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .audible: return "Audible"
        case .visual: return "Visual flash"
        case .off: return "Off"
        }
    }
}

/// Resolves curated + installed monospaced font families to those that actually
/// exist on this machine, so the picker never offers an unloadable family.
enum TerminalFonts {
    /// Families we explicitly want at the top when present, in this order.
    private static let curated = [
        "MesloLGS NF",      // bundled-with-many-dotfiles powerline patched
        "SF Mono",          // Apple's developer mono (loadable by PostScript name)
        "Menlo",
        "Monaco",
        "JetBrains Mono",
        "Fira Code",
        "Cascadia Code",
        "Cascadia Mono",
        "Hack",
        "Source Code Pro",
        "IBM Plex Mono",
        "Roboto Mono",
        "Inconsolata",
    ]

    /// Curated families that resolve to a real font, in curated order, followed
    /// by any *other* installed fixed-pitch family (alphabetical). Guaranteed
    /// non-empty (system monospaced is the floor).
    static func available() -> [String] {
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        var out: [String] = []
        var seen = Set<String>()
        for fam in curated where resolves(fam, installed: installed) {
            out.append(fam); seen.insert(fam)
        }
        // Append remaining installed fixed-pitch families not already listed.
        let extras = installed
            .filter { !seen.contains($0) && isFixedPitchFamily($0) }
            .sorted()
        out.append(contentsOf: extras)
        if out.isEmpty { out = ["Menlo"] }
        return out
    }

    /// True if `family` is installed *or* loadable by its PostScript-ish name
    /// (SF Mono ships as "SF Mono" / "SFMono-Regular" but isn't in the family
    /// list on every OS version).
    private static func resolves(_ family: String, installed: Set<String>) -> Bool {
        if installed.contains(family) { return true }
        return font(named: family, size: 13) != nil
    }

    private static func isFixedPitchFamily(_ family: String) -> Bool {
        guard let f = NSFont(name: family, size: 13) else { return false }
        return f.isFixedPitch
    }

    /// Builds an `NSFont` for a family name, trying the family then a couple of
    /// common PostScript spellings (notably SF Mono / MesloLGS NF).
    static func font(named family: String, size: CGFloat) -> NSFont? {
        if let f = NSFont(name: family, size: size) { return f }
        // NSFontManager can build a family's regular face even when the family
        // name isn't a valid PostScript name.
        if let f = NSFontManager.shared.font(withFamily: family,
                                             traits: [], weight: 5, size: size) {
            return f
        }
        // PostScript fallbacks for the two families that need them.
        let candidates: [String]
        switch family {
        case "SF Mono": candidates = ["SFMono-Regular", "SF Mono Regular"]
        case "MesloLGS NF": candidates = ["MesloLGSNF-Regular", "MesloLGS-NF"]
        default: candidates = []
        }
        for c in candidates { if let f = NSFont(name: c, size: size) { return f } }
        return nil
    }
}

/// The "Terminal Appearance" preferences group, embedded in the Settings form.
/// Edits persist to `@AppStorage`; `TerminalController` observes the same keys
/// (via its `applyAppearance` reload) so changes apply live to every pane.
struct TerminalAppearanceSection: View {
    @ObservedObject var terminals: TerminalController
    @AppStorage(TermPrefs.fontFamilyKey) private var fontFamily = TermPrefs.defaultFontFamily
    @AppStorage(TermPrefs.cursorStyleKey) private var cursorRaw = TermPrefs.defaultCursorStyle
    @AppStorage(TermPrefs.bellModeKey) private var bellRaw = TermPrefs.defaultBellMode

    private let families = TerminalFonts.available()

    var body: some View {
        Section {
            Picker("Font family", selection: $fontFamily) {
                ForEach(families, id: \.self) { fam in
                    Text(fam).font(.custom(fam, size: 12)).tag(fam)
                }
            }
            .onChange(of: fontFamily) { _ in terminals.applyAppearance() }

            Picker("Cursor", selection: $cursorRaw) {
                ForEach(CursorPref.allCases) { c in Text(c.label).tag(c.rawValue) }
            }
            .pickerStyle(.segmented)
            .onChange(of: cursorRaw) { _ in terminals.applyAppearance() }

            Picker("Bell", selection: $bellRaw) {
                ForEach(BellMode.allCases) { b in Text(b.label).tag(b.rawValue) }
            }
            .pickerStyle(.segmented)
            // bell is read live by PaneConn.bell(); no controller reload needed.
        } header: {
            Text("Terminal Appearance")
        } footer: {
            Text("Font, cursor shape, and what a session's bell does. Applies to every pane.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
