import SwiftUI

// MARK: - Agent state

/// The agent-state classification a broker reports per session in `/sessions`.
/// The current detector emits only `working` (the agent's "esc to interrupt" footer is
/// on screen) and `idle`. `waiting` is reserved/vestigial — still decoded so an older
/// broker that sends it doesn't break, but never emitted now. Unknown → `.idle`.
enum AgentState: String {
    case working
    case waiting
    case idle

    init(raw: String) { self = AgentState(rawValue: raw.lowercased()) ?? .idle }
}

/// How a session's indicator should render. Two states only: the broker reports
/// `working` (its agent shows "esc to interrupt") → a pulsing BLUE dot; anything else
/// → a solid GREEN dot. (`attached` is no longer used here.)
struct AgentIndicatorStyle {
    let color: SwiftUI.Color
    let filled: Bool   // false = hollow ring (idle)
    let pulses: Bool   // animated breathing dot
    let help: String   // tooltip / accessibility label

    static func resolve(state: AgentState, attached: Bool, unseen: Bool = false) -> AgentIndicatorStyle {
        switch state {
        case .working:
            // Agent is actively running (its "esc to interrupt" footer is on screen).
            return AgentIndicatorStyle(
                color: Theme.running, filled: true, pulses: true,
                help: "Running")
        case .waiting, .idle:
            // A turn that just finished while you weren't looking at this pane reads
            // ORANGE ("done, unseen") until you open it; otherwise a solid green dot.
            if unseen {
                return AgentIndicatorStyle(
                    color: Theme.unseen, filled: true, pulses: false,
                    help: "Done — not yet viewed")
            }
            return AgentIndicatorStyle(
                color: Theme.attached, filled: true, pulses: false,
                help: "Idle")
        }
    }
}

// MARK: - Indicator view

/// A small agent-state dot: a soft outer glow + a solid (or hollow) core that
/// breathes when `pulses` is true. Sized to sit at the leading edge of a row.
/// Animation only runs while the view is on screen, so off-screen LazyVStack
/// rows stay cheap.
struct AgentIndicator: View {
    let style: AgentIndicatorStyle
    var diameter: CGFloat = 9

    @State private var pulse = false
    @Environment(\.controlActiveState) private var controlActive

    private var isKey: Bool { controlActive != .inactive }

    var body: some View {
        ZStack {
            // Outer glow halo — only for pulsing (attention) states.
            if style.pulses {
                Circle()
                    .fill(style.color.opacity(0.30))
                    .frame(width: diameter + 7, height: diameter + 7)
                    .scaleEffect(pulse ? 1.0 : 0.55)
                    .opacity(pulse ? 0.0 : 0.55)
            }
            // Core: solid dot or hollow ring.
            Group {
                if style.filled {
                    Circle().fill(style.color)
                } else {
                    Circle().strokeBorder(style.color, lineWidth: 1.5)
                }
            }
            .frame(width: diameter, height: diameter)
            .opacity(style.pulses && pulse ? 0.55 : 1.0)
            .shadow(color: style.pulses ? style.color.opacity(0.55) : .clear,
                    radius: style.pulses ? 3 : 0)
        }
        .frame(width: diameter + 7, height: diameter + 7)
        .opacity(isKey ? 1 : 0.7)
        .help(style.help)
        .onAppear { restart() }
        .onChange(of: style.pulses) { _ in restart() }
        .onChange(of: style.color) { _ in restart() }
    }

    private func restart() {
        pulse = false
        guard style.pulses else { return }
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }
}

// MARK: - Session row (Warp-style, two-line)

/// A two-line Warp-style sidebar row:
///   line 1 — agent-state indicator + session name (medium weight)
///   line 2 — dimmed cwd path (head-truncated), like Warp's path/branch sub-label
/// Selection is a soft gray fill (#45464E) + a leading accent capsule that
/// desaturates (not disappears) when the window isn't key. Tap to select; the
/// context menu keeps rename / copy / reveal / kill.
struct SessionRow: View {
    let session: SessionInfo
    var unseen: Bool = false       // agent finished a turn you haven't opened yet → orange dot
    let folderText: String        // pre-resolved cwd label (state.folderDisplay)
    let selected: Bool
    let onTap: () -> Void
    var onRename: () -> Void = {}
    var onKill: () -> Void = {}
    var onCopyName: () -> Void = {}
    var onHide: () -> Void = {}
    var wandbRunsProvider: () -> [WandbRun] = { [] }   // evaluated when the menu opens (no row invalidation)
    var onOpenWandb: (WandbRun?) -> Void = { _ in }
    var onReveal: (() -> Void)? = nil
    var onRevealFiles: (() -> Void)? = nil

    @State private var hover = false
    @Environment(\.controlActiveState) private var controlActive
    @AppStorage("ut.uiScale") private var uiScale: Double = 1.0

    private func cf(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * uiScale, weight: weight)
    }

    private var isKey: Bool { controlActive != .inactive }

    private var indicator: AgentIndicatorStyle {
        .resolve(state: AgentState(raw: session.state), attached: session.attached, unseen: unseen)
    }

    var body: some View {
        HStack(spacing: 9) {
            AgentIndicator(style: indicator)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.name)
                        .font(cf(13, .medium)) // constant weight — no reflow on select
                        .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 6)
                    Text(relativeShort(session.activity))
                        .font(cf(10.5, .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize()
                }
                Text(folderText)
                    .font(cf(11))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .background(rowBackground)
        .overlay(alignment: .leading) {
            if selected {
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: 2.5, height: 22)
                    .opacity(isKey ? 1 : 0.5)
                    .padding(.leading, 1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .contextMenu {
            let runs = wandbRunsProvider()
            if runs.count == 1 {
                Button("Open W&B") { onOpenWandb(runs.last) }
                Divider()
            } else if runs.count > 1 {
                Menu("Open W&B") {
                    ForEach(runs.reversed()) { r in Button(r.label) { onOpenWandb(r) } }
                }
                Divider()
            }
            Button("Hide Panel") { onHide() }
            Button("Rename…") { onRename() }
            Button("Copy Name") { onCopyName() }
            if let onRevealFiles { Button("Reveal in Files") { onRevealFiles() } }
            if let onReveal { Button("Reveal Folder in Finder") { onReveal() } }
            Divider()
            Button("Kill Session", role: .destructive) { onKill() }
        }
    }

    @ViewBuilder private var rowBackground: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
        if selected {
            shape.fill(isKey ? Theme.selection : Theme.selection.opacity(0.5))
        } else if hover {
            shape.fill(SwiftUI.Color.white.opacity(0.05))
        } else {
            shape.fill(SwiftUI.Color.clear)
        }
    }
}
