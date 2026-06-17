import SwiftTerm
import SwiftUI

/// A panel of theme rows with live color swatches. Each row previews THAT theme's own
/// colors (background + accent + the status dots + a few ANSI); clicking applies it
/// immediately so you can flip through and see each one. Default is Argus.
struct ThemePickerView: View {
    @EnvironmentObject var themeStore: ThemeStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("ut.uiScale") private var uiScale: Double = 1.0
    private func cf(_ s: CGFloat, _ w: Font.Weight = .regular) -> Font { .system(size: s * uiScale, weight: w) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Theme").font(cf(17, .bold)).foregroundStyle(Theme.textPrimary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(ThemePalette.all, id: \.id) { p in
                        row(p)
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 14)
            }
        }
        .frame(width: 360, height: 460)
        .background(Theme.appBackground)
    }

    private func row(_ p: ThemePalette) -> some View {
        let selected = p.id == themeStore.themeID
        return Button {
            themeStore.select(p)
        } label: {
            HStack(spacing: 12) {
                swatch(p)
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.name).font(cf(13.5, .medium)).foregroundStyle(Theme.textPrimary)
                    if p.id == "argus" {
                        Text("default").font(cf(10.5)).foregroundStyle(Theme.textTertiary)
                    } else if p.isLight {
                        Text("light").font(cf(10.5)).foregroundStyle(Theme.textTertiary)
                    }
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent).font(cf(15))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Theme.accent.opacity(0.14) : Theme.surface.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? Theme.accent.opacity(0.7) : SwiftUI.Color.clear, lineWidth: 1.4))
        }
        .buttonStyle(.plain)
    }

    /// A mini "window" in the theme's own background, with its accent + status dots and
    /// a strip of its ANSI colors — rendered in THAT theme's palette, not the active one.
    private func swatch(_ p: ThemePalette) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                ForEach([p.accent, p.attached, p.running, p.waiting, p.unseen, p.unreachable], id: \.self) { c in
                    Circle().fill(c).frame(width: 7, height: 7)
                }
            }
            HStack(spacing: 2) {
                ForEach(Array(p.ansi16.prefix(8).enumerated()), id: \.offset) { _, c in
                    RoundedRectangle(cornerRadius: 1).fill(c.swiftUI).frame(width: 7, height: 6)
                }
            }
        }
        .padding(7)
        .frame(width: 96, height: 46)
        .background(RoundedRectangle(cornerRadius: 7).fill(p.appBackground))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(p.textTertiary.opacity(0.4), lineWidth: 1))
    }
}

private extension SwiftTerm.Color {
    /// The ANSI color as a SwiftUI Color (16-bit channels → 0...1), for swatches.
    var swiftUI: SwiftUI.Color {
        SwiftUI.Color(.sRGB, red: Double(red) / 65535, green: Double(green) / 65535, blue: Double(blue) / 65535)
    }
}
