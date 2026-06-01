import SwiftUI

/// Quick steering actions for an agent that's blocked on you: Yes / No / Continue.
/// Additive — sends input via AppState.sendInput (a one-shot WebSocket), so it
/// works for the selected session or any inbox row without touching the terminal
/// controller or the selection model.
struct SteerButtons: View {
    let ref: SessionRef
    var compact: Bool = false
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 6) {
            steer("Yes", send: "y\n", Theme.attached)
            steer("No", send: "n\n", Theme.unreachable)
            steer(compact ? "↵" : "Continue", send: "\r", Theme.accent)
        }
    }

    private func steer(_ label: String, send text: String, _ color: Color) -> some View {
        Button { state.sendInput(text: text, to: ref) } label: {
            Text(label)
                .font(.system(size: compact ? 10 : 11, weight: .semibold))
                .padding(.horizontal, compact ? 6 : 9).padding(.vertical, 3)
                .background(Capsule().fill(color.opacity(0.18)))
                .foregroundStyle(color)
        }
        .buttonStyle(.plain)
        .help("Send “\(label)” to \(ref.session)")
    }
}
