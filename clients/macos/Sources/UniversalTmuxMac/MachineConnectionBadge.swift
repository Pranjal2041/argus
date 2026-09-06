import SwiftUI

/// A stale snapshot remains usable; it is deliberately not presented as offline.
struct MachineConnectionBadge: View {
    let status: BrokerConnectionStatus
    let sessionCount: Int
    var textScale: Double = 1

    var body: some View {
        Group {
            switch status {
            case .checking:
                Text("checking…").foregroundStyle(Theme.textTertiary)
            case .delayed:
                Text("refresh delayed").foregroundStyle(Theme.waiting)
            case .unreachable:
                Text("offline").foregroundStyle(Theme.unreachable)
            case .reachable:
                Text("\(sessionCount)")
                    .foregroundStyle(Theme.textSecondary)
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Theme.surface))
            }
        }
        .font(.system(size: 10.5 * textScale, weight: .medium))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
}
