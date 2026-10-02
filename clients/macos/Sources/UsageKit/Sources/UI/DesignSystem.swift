import SwiftUI

@available(macOS 14.0, *)
enum Palette {
    static let blue = Color(light: 0x287AF5, dark: 0x6BA5FF)
    static let background = Color(light: 0xF6F7F9, dark: 0x17191E)
    static let surface = Color(light: 0xFFFFFF, dark: 0x202329)
    static let inset = Color(light: 0xF5F7FA, dark: 0x282C34)
    static let text = Color(light: 0x1C2330, dark: 0xF0F2F6)
    static let secondary = Color(light: 0x6C7789, dark: 0xA2ADBF)
    static let tertiary = Color(light: 0x929CAD, dark: 0x7B879B)
    static let border = Color(light: 0xE2E6ED, dark: 0x353A44)
    static let track = Color(light: 0xEBEEF3, dark: 0x353B47)
    static let green = Color(light: 0x27A16E, dark: 0x65C597)
}

@available(macOS 14.0, *)
extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, alpha: 1)
        })
    }
}

@available(macOS 14.0, *)
struct AppMark: View {
    var size: CGFloat = 24
    var body: some View {
        HStack(alignment: .bottom, spacing: size * 0.12) {
            RoundedRectangle(cornerRadius: 1.5).fill(Palette.blue).frame(width: size * 0.22, height: size * 0.52)
            RoundedRectangle(cornerRadius: 1.5).fill(Palette.blue).frame(width: size * 0.22, height: size)
            RoundedRectangle(cornerRadius: 1.5).fill(Palette.blue.opacity(0.4)).frame(width: size * 0.22, height: size * 0.76)
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

@available(macOS 14.0, *)
struct SourceIcon: View {
    var integration: IntegrationID
    var size: CGFloat = 25
    var body: some View {
        Image(systemName: integration.symbol)
            .font(.system(size: size, weight: .medium))
            .frame(width: size + 8, height: size + 8)
            .foregroundStyle(Palette.text)
            .accessibilityHidden(true)
    }
}

@available(macOS 14.0, *)
struct UsageMeter: View {
    var percent: Double
    var height: CGFloat = 7
    var meaning = "used"
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule().fill(Palette.blue)
                    .frame(width: geometry.size.width * CGFloat(min(100, max(0, percent))) / 100)
            }
        }
        .frame(height: height)
        .accessibilityLabel("\(UsageFormat.percent(percent)) \(meaning)")
    }
}

@available(macOS 14.0, *)
struct SourceCard<Content: View>: View {
    var selected = false
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Palette.blue : Palette.border, lineWidth: selected ? 1.5 : 1))
            .shadow(color: .black.opacity(0.018), radius: 3, y: 2)
            .accessibilityElement(children: .contain)
    }
}

@available(macOS 14.0, *)
struct CardHeading: View {
    var integration: IntegrationID?
    var title: String
    var subtitle: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let integration { SourceIcon(integration: integration) }
                else { Image(systemName: "externaldrive").font(.system(size: 27, weight: .regular)).frame(width: 33).foregroundStyle(Palette.text) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.text)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.tertiary)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("Open \(title) details")
    }
}

@available(macOS 14.0, *)
struct Hairline: View {
    var body: some View { Rectangle().fill(Palette.border).frame(height: 1) }
}

@available(macOS 14.0, *)
struct SoftBadge: View {
    var text: String
    var symbol: String? = nil
    var warning = false
    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .medium)) }
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(Palette.secondary)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Palette.inset)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

@available(macOS 14.0, *)
struct IconButton: View {
    var symbol: String
    var label: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .regular))
                .foregroundStyle(Palette.secondary).frame(width: 32, height: 32).contentShape(RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}

@available(macOS 14.0, *)
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 15).frame(height: 35)
            .background(Color(hex: 0x287AF5).opacity(configuration.isPressed ? 0.8 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

@available(macOS 14.0, *)
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 12).frame(height: 32)
            .background(configuration.isPressed ? Palette.track : Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.border))
    }
}

@available(macOS 14.0, *)
struct SmallMetric: View {
    var label: String
    var value: String
    var suffix: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.system(size: 11)).foregroundStyle(Palette.secondary)
            (Text(value).font(.system(size: 23, weight: .semibold)) + Text(suffix).font(.system(size: 14, weight: .medium)))
                .monospacedDigit().foregroundStyle(Palette.text)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

@available(macOS 14.0, *)
struct MiniBars: View {
    var values: [Double]
    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Palette.blue.opacity(index == values.count - 1 ? 0.85 : 0.32))
                        .frame(height: max(3, geometry.size.height * value / max(1, values.max() ?? 1)))
                }
            }.frame(maxHeight: .infinity, alignment: .bottom)
        }.accessibilityHidden(true)
    }
}
