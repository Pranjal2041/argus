import SwiftUI

// A small "glassy & vibrant" design kit: a gradient backdrop, frosted-glass
// surfaces with hairline edges and optional accent glow, a pulsing live dot,
// and accent/ghost buttons. Reused across the app for a consistent look.
//
// Everything sizes off the shared "ut.uiScale" interface-scale (Settings ▸
// Interface), so the whole kit grows/shrinks with the rest of the app chrome.
enum Glass {
    static let base       = Color(red: 0.047, green: 0.051, blue: 0.078)
    static let accent     = Color(red: 0.478, green: 0.624, blue: 0.984)   // periwinkle
    static let accent2    = Color(red: 0.737, green: 0.604, blue: 0.969)   // violet
    static let live       = Color(red: 0.380, green: 0.851, blue: 0.667)   // teal-green
    static let danger     = Color(red: 0.96, green: 0.49, blue: 0.50)
    static let warn       = Color(red: 0.98, green: 0.74, blue: 0.42)

    static let textPrimary   = Color.white.opacity(0.93)
    static let textSecondary = Color.white.opacity(0.52)
    static let textTertiary  = Color.white.opacity(0.32)

    static let accentGradient = LinearGradient(colors: [accent, accent2], startPoint: .leading, endPoint: .trailing)

    /// The current interface scale (Settings ▸ Interface). Read it where a plain
    /// value (not a font) is needed, e.g. paddings/frames.
    static var scale: CGFloat { CGFloat(UserDefaults.standard.object(forKey: "ut.uiScale") as? Double ?? 1.0) }

    /// A stable accent color for a process/label name (used for chip dots).
    static func tint(for s: String) -> Color {
        let palette = [accent, accent2, live, warn, Color(red: 0.95, green: 0.55, blue: 0.66)]
        if s.isEmpty { return textTertiary }
        var h = 0
        for b in s.utf8 { h = (h &* 31 &+ Int(b)) & 0x7fffffff }
        return palette[h % palette.count]
    }
}

/// Full-window gradient backdrop: a near-black base with two soft accent glows.
struct GlassBackground: View {
    var body: some View {
        ZStack {
            Glass.base
            RadialGradient(colors: [Glass.accent.opacity(0.20), .clear], center: .topLeading, startRadius: 1, endRadius: 560)
            RadialGradient(colors: [Glass.accent2.opacity(0.17), .clear], center: .bottomTrailing, startRadius: 1, endRadius: 620)
        }
        .ignoresSafeArea()
    }
}

/// Frosted-glass surface: material fill, a top-lit hairline edge, soft drop
/// shadow, and an optional colored glow (used to make live forwards "lit up").
struct GlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 16
    var glow: Color? = nil
    var strong: Bool = false
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // All glass decoration is non-interactive: the fills live BELOW the content
        // (in .background) and the strokes opt out of hit-testing, so the card never
        // intercepts clicks meant for the controls inside it.
        return content
            .background(
                shape.fill(.ultraThinMaterial)
                    .overlay(shape.fill(.white.opacity(strong ? 0.04 : 0.02)))
            )
            .overlay(
                shape.stroke(
                    LinearGradient(colors: [.white.opacity(strong ? 0.24 : 0.16), .white.opacity(0.03)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
                    .allowsHitTesting(false)
            )
            .overlay(shape.stroke((glow ?? .clear).opacity(glow == nil ? 0 : 0.55), lineWidth: 1).allowsHitTesting(false))
            .shadow(color: .black.opacity(0.34), radius: 13, x: 0, y: 7)
            .shadow(color: (glow ?? .black).opacity(glow == nil ? 0 : 0.32), radius: 20, x: 0, y: 0)
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 16, glow: Color? = nil, strong: Bool = false) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius, glow: glow, strong: strong))
    }
}

/// A live status dot with a gently expanding halo.
struct PulsingDot: View {
    var color: Color
    var size: CGFloat = 10
    @AppStorage("ut.uiScale") private var uiScale: Double = 1.0
    @State private var animate = false
    var body: some View {
        let d = size * uiScale
        ZStack {
            Circle().fill(color.opacity(0.45))
                .frame(width: d * 2.4, height: d * 2.4)
                .scaleEffect(animate ? 1.0 : 0.4)
                .opacity(animate ? 0 : 0.9)
            Circle().fill(color).frame(width: d, height: d)
                .shadow(color: color.opacity(0.9), radius: 5)
        }
        .frame(width: d * 2.4, height: d * 2.4)
        .onAppear { withAnimation(.easeOut(duration: 1.7).repeatForever(autoreverses: false)) { animate = true } }
    }
}

/// Primary action button — gradient fill with a soft accent shadow.
struct AccentButtonStyle: ButtonStyle {
    var enabled: Bool = true
    var scale: CGFloat = 1
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14 * scale, weight: .semibold))
            .foregroundStyle(.white.opacity(enabled ? 1 : 0.45))
            .padding(.horizontal, 16 * scale).padding(.vertical, 9 * scale)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(enabled ? AnyShapeStyle(Glass.accentGradient) : AnyShapeStyle(Color.white.opacity(0.08)))
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .shadow(color: enabled ? Glass.accent.opacity(0.40) : .clear, radius: 9, y: 3)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Outlined "ghost" button (tinted), for secondary actions like Run.
struct GhostButtonStyle: ButtonStyle {
    var color: Color = Glass.accent
    var scale: CGFloat = 1
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13 * scale, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 13 * scale).padding(.vertical, 7 * scale)
            .background(Capsule().fill(color.opacity(configuration.isPressed ? 0.24 : 0.13)))
            .overlay(Capsule().stroke(color.opacity(0.42), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Borderless icon button with a hover background.
struct GlassIconButton: View {
    var system: String
    var help: String = ""
    var tint: Color = Glass.textSecondary
    var action: () -> Void
    @AppStorage("ut.uiScale") private var uiScale: Double = 1.0
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 14 * uiScale, weight: .medium))
                .foregroundStyle(hover ? Glass.textPrimary : tint)
                .frame(width: 32 * uiScale, height: 32 * uiScale)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(hover ? 0.12 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// Glassy text input (plain field over a translucent rounded surface).
struct GlassField: View {
    var placeholder: String
    @Binding var text: String
    var mono: Bool = false
    var width: CGFloat? = nil
    @AppStorage("ut.uiScale") private var uiScale: Double = 1.0
    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundColor(Glass.textTertiary))
            .textFieldStyle(.plain)
            .font(.system(size: 14 * uiScale, weight: .regular, design: mono ? .monospaced : .default))
            .foregroundStyle(Glass.textPrimary)
            .padding(.horizontal, 13 * uiScale).padding(.vertical, 10 * uiScale)
            .frame(width: width.map { $0 * uiScale })
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(.white.opacity(0.10), lineWidth: 1))
    }
}
