import AppKit
import SwiftTerm
import SwiftUI

/// The single source of truth for chrome and terminal color.
///
/// One seamless dark surface (Warp's edgeless feel): the terminal background is
/// the window background (#0F1117), so the grid dissolves into the window with
/// no seam. A single periwinkle accent (#5B8CFF) is a deliberate sibling of the
/// terminal's blue (#7AA2F7) so chrome and terminal read as one system.
enum Theme {
    // Chrome (SwiftUI). Palette matched to Warp's default dark theme (sampled from
    // a real Warp window): neutral warm-gray, sidebar LIGHTER than the terminal.
    static let appBackground     = SwiftUI.Color(hex: "#24252F") // terminal + window
    static let sidebarBackground = SwiftUI.Color(hex: "#2C2E37") // lighter than terminal, like Warp
    static let surface           = SwiftUI.Color(hex: "#383A44") // fields, pills, badges
    static let border            = SwiftUI.Color(hex: "#3C3E47")
    static let accent            = SwiftUI.Color(hex: "#56B6CE") // teal (Warp's #0D86A9, brightened for UI)
    static let selection         = SwiftUI.Color(hex: "#45464E") // Warp's gray selected-row fill
    static let textPrimary       = SwiftUI.Color(hex: "#F2F2EC") // warm white
    static let textSecondary     = SwiftUI.Color(hex: "#A8AAB2")
    static let textTertiary      = SwiftUI.Color(hex: "#777983")
    static let attached          = SwiftUI.Color(hex: "#5FD07A") // green status dot — agent idle
    static let running           = SwiftUI.Color(hex: "#4F9BFF") // blue status dot — agent working
    static let waiting           = SwiftUI.Color(hex: "#E0A36B") // amber — agent blocked on the user
    static let unreachable       = SwiftUI.Color(hex: "#D36C4D") // Warp orange-red

    // Window + terminal (AppKit)
    static let nsAppBackground   = NSColor(hex: "#24252F")
    static let nsForeground      = NSColor(hex: "#E6E6DF") // warm white terminal text
    static let nsCursor          = NSColor(hex: "#F2F2EC")
    static let nsCursorText      = NSColor(hex: "#24252F")
    static let nsSelection       = NSColor(hex: "#3F4654")
    static let nsBellFlash       = NSColor(hex: "#3C5560") // brief visual-bell flash (teal-tinted)

    // Metrics (single source so chrome + terminal align)
    static let contentInset: CGFloat = 16 // horizontal gutter shared by header + terminal grid
    static let radius: CGFloat = 7         // corner radius for pills, fields, rows

    /// The 16 ANSI colors fed to `TerminalView.installColors` (Tokyo-Night-ish):
    /// normal black..white, then bright black..white. SwiftTerm channels are
    /// 16-bit (0..65535), so each 8-bit component is scaled by 257.
    static let ansi16: [SwiftTerm.Color] = [
        "#1A1D27", "#F7768E", "#9ECE6A", "#E0AF68", // black  red    green  yellow
        "#7AA2F7", "#BB9AF7", "#7DCFFF", "#C8CCD6", // blue   magenta cyan   white
        "#3B4048", "#FF8DA3", "#B5E08A", "#F0C485", // bright black/red/green/yellow
        "#9CB8FF", "#D0B6FF", "#A0DEFF", "#E6E8EE", // bright blue/magenta/cyan/white
    ].map(SwiftTerm.Color.from)
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
