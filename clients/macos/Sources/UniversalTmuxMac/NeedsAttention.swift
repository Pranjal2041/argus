import SwiftUI

/// A single session that is blocked on the user (state == "waiting"), paired
/// with the human-readable name of the machine it lives on. Sorted, deep-linkable.
struct WaitingSession: Identifiable, Hashable {
    let ref: SessionRef
    let machineName: String
    let activity: Int64
    var id: String { ref.id }
}

/// The pinned "Needs attention" section at the very top of the sidebar.
///
/// A pure client-side view over `state.sessionsByMachine`: every session across
/// every machine whose broker-classified `state == "waiting"` (blocked on you),
/// each row a deep-link that sets `state.selection`, sorted by most-recent
/// activity. The whole section is hidden when nothing is waiting.
struct NeedsAttentionSection: View {
    let waiting: [WaitingSession]
    @Binding var selection: SessionRef?
    @AppStorage("ut.uiScale") private var uiScale: Double = 1.0

    private func cf(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * uiScale, weight: weight)
    }

    var body: some View {
        if !waiting.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                header
                ForEach(waiting) { w in
                    NeedsAttentionRow(
                        item: w,
                        selected: selection == w.ref,
                        onTap: { selection = w.ref }
                    )
                }
            }
            .padding(.bottom, 10)
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "bell.badge.fill")
                .font(cf(10.5))
                .foregroundStyle(Theme.waiting)
            Text("NEEDS ATTENTION")
                .font(cf(11, .semibold))
                .tracking(0.5)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("\(waiting.count)")
                .font(cf(10.5, .semibold))
                .monospacedDigit()
                .foregroundStyle(SwiftUI.Color(hex: "#24252F"))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Theme.waiting))
        }
        .padding(.horizontal, 6)
        .frame(height: 30)
        .frame(maxWidth: .infinity)
    }
}

/// One row in the inbox: amber waiting dot, session name, trailing machine
/// label + relative activity. Same metrics/affordances as `SessionRow`.
private struct NeedsAttentionRow: View {
    let item: WaitingSession
    let selected: Bool
    let onTap: () -> Void

    @State private var hover = false
    @State private var pulse = false
    @Environment(\.controlActiveState) private var controlActive
    @AppStorage("ut.uiScale") private var uiScale: Double = 1.0

    private var isKey: Bool { controlActive != .inactive }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Theme.waiting)
                .frame(width: 6, height: 6)
                .opacity(pulse ? 0.4 : 1.0)
            Text(item.ref.session)
                .font(.system(size: 13 * uiScale, weight: .medium))
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(item.machineName)
                .font(.system(size: 10.5 * uiScale, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 70, alignment: .trailing)
            Text(relativeShort(item.activity))
                .font(.system(size: 11 * uiScale, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 30, alignment: .trailing)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 30)
        .frame(maxWidth: .infinity)
        .background(rowBackground)
        .overlay(alignment: .leading) {
            if selected {
                Capsule()
                    .fill(Theme.waiting)
                    .frame(width: 2.5, height: 16)
                    .opacity(isKey ? 1 : 0.5)
                    .padding(.leading, 1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    @ViewBuilder private var rowBackground: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
        if selected {
            shape.fill(isKey ? Theme.selection : Theme.selection.opacity(0.5))
        } else if hover {
            shape.fill(SwiftUI.Color.white.opacity(0.05))
        } else {
            shape.fill(Theme.waiting.opacity(hover ? 0.0 : 0.06))
        }
    }
}
