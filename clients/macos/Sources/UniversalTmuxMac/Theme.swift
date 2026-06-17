import AppKit
import SwiftTerm
import SwiftUI

/// A full color scheme: chrome (SwiftUI) + terminal (AppKit + the 16 ANSI colors).
/// Colors are parsed once at construction (from hex) so reads are cheap. Themes are
/// selectable at runtime via `Theme.current`; the DEFAULT is `.argus`, which holds the
/// exact original palette so nothing changes unless the user picks another theme.
struct ThemePalette: Equatable {
    let id: String
    let name: String
    let isLight: Bool

    // Chrome (SwiftUI)
    let appBackground, sidebarBackground, surface, border, accent, selection: SwiftUI.Color
    let textPrimary, textSecondary, textTertiary: SwiftUI.Color
    let attached, running, waiting, unseen, unreachable: SwiftUI.Color

    // Window + terminal (AppKit). nsAppBackground mirrors appBackground.
    let nsAppBackground, nsForeground, nsCursor, nsCursorText, nsSelection, nsBellFlash: NSColor

    // The 16 ANSI terminal colors (normal black..white, then bright black..white).
    let ansi16: [SwiftTerm.Color]

    static func == (a: ThemePalette, b: ThemePalette) -> Bool { a.id == b.id }

    init(id: String, name: String, isLight: Bool = false,
         appBackground: String, sidebarBackground: String, surface: String, border: String,
         accent: String, selection: String,
         textPrimary: String, textSecondary: String, textTertiary: String,
         attached: String, running: String, waiting: String, unseen: String, unreachable: String,
         foreground: String, cursor: String, cursorText: String, termSelection: String, bellFlash: String,
         ansi16: [String]) {
        self.id = id; self.name = name; self.isLight = isLight
        self.appBackground = Color(hex: appBackground)
        self.sidebarBackground = Color(hex: sidebarBackground)
        self.surface = Color(hex: surface)
        self.border = Color(hex: border)
        self.accent = Color(hex: accent)
        self.selection = Color(hex: selection)
        self.textPrimary = Color(hex: textPrimary)
        self.textSecondary = Color(hex: textSecondary)
        self.textTertiary = Color(hex: textTertiary)
        self.attached = Color(hex: attached)
        self.running = Color(hex: running)
        self.waiting = Color(hex: waiting)
        self.unseen = Color(hex: unseen)
        self.unreachable = Color(hex: unreachable)
        self.nsAppBackground = NSColor(hex: appBackground)
        self.nsForeground = NSColor(hex: foreground)
        self.nsCursor = NSColor(hex: cursor)
        self.nsCursorText = NSColor(hex: cursorText)
        self.nsSelection = NSColor(hex: termSelection)
        self.nsBellFlash = NSColor(hex: bellFlash)
        self.ansi16 = ansi16.map(SwiftTerm.Color.from)
    }
}

// MARK: - The themes (official palettes; Argus = the exact original)

extension ThemePalette {
    /// THE DEFAULT — byte-for-byte the original Argus palette. Do not change these.
    static let argus = ThemePalette(
        id: "argus", name: "Argus",
        appBackground: "#24252F", sidebarBackground: "#2C2E37", surface: "#383A44", border: "#3C3E47",
        accent: "#56B6CE", selection: "#45464E",
        textPrimary: "#F2F2EC", textSecondary: "#A8AAB2", textTertiary: "#777983",
        attached: "#5FD07A", running: "#4F9BFF", waiting: "#E0A36B", unseen: "#FF9F40", unreachable: "#D36C4D",
        foreground: "#E6E6DF", cursor: "#F2F2EC", cursorText: "#24252F", termSelection: "#3F4654", bellFlash: "#3C5560",
        ansi16: ["#1A1D27", "#F7768E", "#9ECE6A", "#E0AF68", "#7AA2F7", "#BB9AF7", "#7DCFFF", "#C8CCD6",
                 "#3B4048", "#FF8DA3", "#B5E08A", "#F0C485", "#9CB8FF", "#D0B6FF", "#A0DEFF", "#E6E8EE"])

    static let tokyoNight = ThemePalette(
        id: "tokyonight", name: "Tokyo Night",
        appBackground: "#24283b", sidebarBackground: "#292e42", surface: "#343a52", border: "#3b4261",
        accent: "#7aa2f7", selection: "#2e3c64",
        textPrimary: "#c0caf5", textSecondary: "#a9b1d6", textTertiary: "#565f89",
        attached: "#9ece6a", running: "#7aa2f7", waiting: "#e0af68", unseen: "#ff9e64", unreachable: "#f7768e",
        foreground: "#c0caf5", cursor: "#c0caf5", cursorText: "#24283b", termSelection: "#2e3c64", bellFlash: "#3b4261",
        ansi16: ["#1d202f", "#f7768e", "#9ece6a", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff", "#a9b1d6",
                 "#414868", "#f7768e", "#9ece6a", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff", "#c0caf5"])

    static let dracula = ThemePalette(
        id: "dracula", name: "Dracula",
        appBackground: "#282A36", sidebarBackground: "#21222C", surface: "#343746", border: "#44475A",
        accent: "#BD93F9", selection: "#44475A",
        textPrimary: "#F8F8F2", textSecondary: "#C8C8DC", textTertiary: "#6272A4",
        attached: "#50FA7B", running: "#8BE9FD", waiting: "#F1FA8C", unseen: "#FFB86C", unreachable: "#FF5555",
        foreground: "#F8F8F2", cursor: "#F8F8F2", cursorText: "#282A36", termSelection: "#44475A", bellFlash: "#44475A",
        ansi16: ["#21222C", "#FF5555", "#50FA7B", "#F1FA8C", "#BD93F9", "#FF79C6", "#8BE9FD", "#F8F8F2",
                 "#6272A4", "#FF6E6E", "#69FF94", "#FFFFA5", "#D6ACFF", "#FF92DF", "#A4FFFF", "#FFFFFF"])

    static let catppuccin = ThemePalette(
        id: "catppuccin-mocha", name: "Catppuccin Mocha",
        appBackground: "#1e1e2e", sidebarBackground: "#181825", surface: "#313244", border: "#45475a",
        accent: "#cba6f7", selection: "#45475a",
        textPrimary: "#cdd6f4", textSecondary: "#a6adc8", textTertiary: "#6c7086",
        attached: "#a6e3a1", running: "#89b4fa", waiting: "#f9e2af", unseen: "#fab387", unreachable: "#f38ba8",
        foreground: "#cdd6f4", cursor: "#f5e0dc", cursorText: "#1e1e2e", termSelection: "#45475a", bellFlash: "#585b70",
        ansi16: ["#45475a", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#bac2de",
                 "#585b70", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#a6adc8"])

    static let nord = ThemePalette(
        id: "nord", name: "Nord",
        appBackground: "#2e3440", sidebarBackground: "#272c36", surface: "#3b4252", border: "#434c5e",
        accent: "#88c0d0", selection: "#434c5e",
        textPrimary: "#d8dee9", textSecondary: "#abb2c0", textTertiary: "#4c566a",
        attached: "#a3be8c", running: "#81a1c1", waiting: "#ebcb8b", unseen: "#d08770", unreachable: "#bf616a",
        foreground: "#d8dee9", cursor: "#d8dee9", cursorText: "#2e3440", termSelection: "#434c5e", bellFlash: "#4c566a",
        ansi16: ["#3b4252", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#88c0d0", "#e5e9f0",
                 "#4c566a", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#8fbcbb", "#eceff4"])

    static let gruvbox = ThemePalette(
        id: "gruvbox", name: "Gruvbox Dark",
        appBackground: "#282828", sidebarBackground: "#1d2021", surface: "#3c3836", border: "#504945",
        accent: "#8ec07c", selection: "#504945",
        textPrimary: "#ebdbb2", textSecondary: "#d5c4a1", textTertiary: "#928374",
        attached: "#b8bb26", running: "#83a598", waiting: "#fabd2f", unseen: "#fe8019", unreachable: "#fb4934",
        foreground: "#ebdbb2", cursor: "#ebdbb2", cursorText: "#282828", termSelection: "#504945", bellFlash: "#665c54",
        ansi16: ["#282828", "#cc241d", "#98971a", "#d79921", "#458588", "#b16286", "#689d6a", "#a89984",
                 "#928374", "#fb4934", "#b8bb26", "#fabd2f", "#83a598", "#d3869b", "#8ec07c", "#ebdbb2"])

    static let oneDark = ThemePalette(
        id: "one-dark", name: "One Dark",
        appBackground: "#282c34", sidebarBackground: "#21252b", surface: "#2c313a", border: "#3b4048",
        accent: "#61afef", selection: "#3e4451",
        textPrimary: "#abb2bf", textSecondary: "#9da5b4", textTertiary: "#5c6370",
        attached: "#98c379", running: "#61afef", waiting: "#e5c07b", unseen: "#d19a66", unreachable: "#e06c75",
        foreground: "#abb2bf", cursor: "#61afef", cursorText: "#282c34", termSelection: "#3e4451", bellFlash: "#3b4048",
        ansi16: ["#282c34", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#abb2bf",
                 "#5c6370", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#ffffff"])

    static let solarizedDark = ThemePalette(
        id: "solarized-dark", name: "Solarized Dark",
        appBackground: "#002b36", sidebarBackground: "#073642", surface: "#073642", border: "#586e75",
        accent: "#2aa198", selection: "#073642",
        textPrimary: "#839496", textSecondary: "#93a1a1", textTertiary: "#586e75",
        attached: "#859900", running: "#268bd2", waiting: "#b58900", unseen: "#cb4b16", unreachable: "#dc322f",
        foreground: "#839496", cursor: "#93a1a1", cursorText: "#002b36", termSelection: "#073642", bellFlash: "#586e75",
        ansi16: ["#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#eee8d5",
                 "#002b36", "#cb4b16", "#586e75", "#657b83", "#839496", "#6c71c4", "#93a1a1", "#fdf6e3"])

    static let solarizedLight = ThemePalette(
        id: "solarized-light", name: "Solarized Light", isLight: true,
        appBackground: "#fdf6e3", sidebarBackground: "#eee8d5", surface: "#eee8d5", border: "#93a1a1",
        accent: "#2aa198", selection: "#eee8d5",
        textPrimary: "#657b83", textSecondary: "#586e75", textTertiary: "#93a1a1",
        attached: "#859900", running: "#268bd2", waiting: "#b58900", unseen: "#cb4b16", unreachable: "#dc322f",
        foreground: "#657b83", cursor: "#586e75", cursorText: "#fdf6e3", termSelection: "#eee8d5", bellFlash: "#d8d2c0",
        ansi16: ["#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#eee8d5",
                 "#002b36", "#cb4b16", "#586e75", "#657b83", "#839496", "#6c71c4", "#93a1a1", "#fdf6e3"])

    static let monokai = ThemePalette(
        id: "monokai", name: "Monokai",
        appBackground: "#272822", sidebarBackground: "#1e1f1a", surface: "#3e3d32", border: "#49483e",
        accent: "#66d9ef", selection: "#49483e",
        textPrimary: "#f8f8f2", textSecondary: "#cfcfc2", textTertiary: "#75715e",
        attached: "#a6e22e", running: "#66d9ef", waiting: "#e6db74", unseen: "#fd971f", unreachable: "#f92672",
        foreground: "#f8f8f2", cursor: "#f8f8f0", cursorText: "#272822", termSelection: "#49483e", bellFlash: "#5a5a4e",
        ansi16: ["#272822", "#f92672", "#a6e22e", "#f4bf75", "#66d9ef", "#ae81ff", "#a1efe4", "#f8f8f2",
                 "#75715e", "#f92672", "#a6e22e", "#e6db74", "#66d9ef", "#ae81ff", "#a1efe4", "#f9f8f5"])

    static let githubDark = ThemePalette(
        id: "github-dark", name: "GitHub Dark",
        appBackground: "#0d1117", sidebarBackground: "#010409", surface: "#161b22", border: "#30363d",
        accent: "#58a6ff", selection: "#21262d",
        textPrimary: "#c9d1d9", textSecondary: "#b1bac4", textTertiary: "#8b949e",
        attached: "#3fb950", running: "#58a6ff", waiting: "#d29922", unseen: "#db6d28", unreachable: "#ff7b72",
        foreground: "#c9d1d9", cursor: "#58a6ff", cursorText: "#0d1117", termSelection: "#21262d", bellFlash: "#1f6feb",
        ansi16: ["#484f58", "#ff7b72", "#3fb950", "#d29922", "#58a6ff", "#bc8cff", "#39c5cf", "#b1bac4",
                 "#6e7681", "#ffa198", "#56d364", "#e3b341", "#79c0ff", "#d2a8ff", "#56d4dd", "#f0f6fc"])

    static let githubLight = ThemePalette(
        id: "github-light", name: "GitHub Light", isLight: true,
        appBackground: "#ffffff", sidebarBackground: "#f6f8fa", surface: "#f6f8fa", border: "#d0d7de",
        accent: "#0969da", selection: "#ddf4ff",
        textPrimary: "#24292f", textSecondary: "#57606a", textTertiary: "#6e7781",
        attached: "#1a7f37", running: "#0969da", waiting: "#9a6700", unseen: "#bc4c00", unreachable: "#cf222e",
        foreground: "#24292f", cursor: "#0969da", cursorText: "#ffffff", termSelection: "#ddf4ff", bellFlash: "#b6e3ff",
        ansi16: ["#24292f", "#cf222e", "#116329", "#4d2d00", "#0969da", "#8250df", "#1b7c83", "#6e7781",
                 "#57606a", "#a40e26", "#1a7f37", "#633c01", "#218bff", "#a475f9", "#3192aa", "#8c959f"])

    static let rosePine = ThemePalette(
        id: "rose-pine", name: "Rosé Pine",
        appBackground: "#191724", sidebarBackground: "#1f1d2e", surface: "#26233a", border: "#403d52",
        accent: "#c4a7e7", selection: "#403d52",
        textPrimary: "#e0def4", textSecondary: "#908caa", textTertiary: "#6e6a86",
        attached: "#9ccfd8", running: "#31748f", waiting: "#f6c177", unseen: "#ebbcba", unreachable: "#eb6f92",
        foreground: "#e0def4", cursor: "#e0def4", cursorText: "#191724", termSelection: "#403d52", bellFlash: "#524f67",
        ansi16: ["#26233a", "#eb6f92", "#31748f", "#f6c177", "#9ccfd8", "#c4a7e7", "#ebbcba", "#e0def4",
                 "#6e6a86", "#eb6f92", "#31748f", "#f6c177", "#9ccfd8", "#c4a7e7", "#ebbcba", "#e0def4"])

    /// All selectable themes, Argus first.
    static let all: [ThemePalette] = [
        argus, tokyoNight, dracula, catppuccin, nord, gruvbox, oneDark,
        solarizedDark, solarizedLight, monokai, githubDark, githubLight, rosePine,
    ]

    static func byID(_ id: String) -> ThemePalette { all.first { $0.id == id } ?? argus }
}

/// The single source of truth for chrome and terminal color. Every member resolves
/// against the currently-selected `current` palette (default `.argus`). Call sites
/// (`Theme.appBackground`, …) are unchanged — switching themes just swaps `current`.
enum Theme {
    /// The active palette. Initialized from the saved choice; updated by ThemeStore.
    static var current: ThemePalette = ThemePalette.byID(UserDefaults.standard.string(forKey: "ut.themeID") ?? "argus")

    // Chrome (SwiftUI)
    static var appBackground: SwiftUI.Color     { current.appBackground }
    static var sidebarBackground: SwiftUI.Color { current.sidebarBackground }
    static var surface: SwiftUI.Color           { current.surface }
    static var border: SwiftUI.Color            { current.border }
    static var accent: SwiftUI.Color            { current.accent }
    static var selection: SwiftUI.Color         { current.selection }
    static var textPrimary: SwiftUI.Color       { current.textPrimary }
    static var textSecondary: SwiftUI.Color     { current.textSecondary }
    static var textTertiary: SwiftUI.Color      { current.textTertiary }
    static var attached: SwiftUI.Color          { current.attached }
    static var running: SwiftUI.Color           { current.running }
    static var waiting: SwiftUI.Color           { current.waiting }
    static var unseen: SwiftUI.Color            { current.unseen }
    static var unreachable: SwiftUI.Color       { current.unreachable }

    // Window + terminal (AppKit)
    static var nsAppBackground: NSColor { current.nsAppBackground }
    static var nsForeground: NSColor    { current.nsForeground }
    static var nsCursor: NSColor        { current.nsCursor }
    static var nsCursorText: NSColor    { current.nsCursorText }
    static var nsSelection: NSColor     { current.nsSelection }
    static var nsBellFlash: NSColor     { current.nsBellFlash }

    // Metrics (single source so chrome + terminal align)
    static let contentInset: CGFloat = 16 // horizontal gutter shared by header + terminal grid
    static let radius: CGFloat = 7         // corner radius for pills, fields, rows

    /// The 16 ANSI colors fed to `TerminalView.installColors`.
    static var ansi16: [SwiftTerm.Color] { current.ansi16 }
}

// MARK: - Hex helpers

/// Parses "#RRGGBB" or "#RRGGBBAA" into 8-bit components (alpha defaults to 255).
private func hexComponents(_ hex: String) -> (r: Double, g: Double, b: Double, a: Double) {
    var s = Substring(hex)
    if s.hasPrefix("#") { s = s.dropFirst() }
    var v: UInt64 = 0
    Scanner(string: String(s)).scanHexInt64(&v)
    let r, g, b, a: UInt64
    if s.count == 8 {
        r = (v >> 24) & 0xff; g = (v >> 16) & 0xff; b = (v >> 8) & 0xff; a = v & 0xff
    } else {
        r = (v >> 16) & 0xff; g = (v >> 8) & 0xff; b = v & 0xff; a = 0xff
    }
    return (Double(r) / 255, Double(g) / 255, Double(b) / 255, Double(a) / 255)
}

extension SwiftUI.Color {
    init(hex: String) {
        let c = hexComponents(hex)
        self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
    }
}

extension NSColor {
    convenience init(hex: String) {
        let c = hexComponents(hex)
        self.init(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
    }
}

extension SwiftTerm.Color {
    /// Builds a SwiftTerm color from an "#RRGGBB" string (8-bit -> 16-bit * 257).
    static func from(_ hex: String) -> SwiftTerm.Color {
        let c = hexComponents(hex)
        return SwiftTerm.Color(red: UInt16(c.r * 255) * 257,
                               green: UInt16(c.g * 255) * 257,
                               blue: UInt16(c.b * 255) * 257)
    }
}
