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

    @Environment(\.controlActiveState) private var controlActive
    private var isKey: Bool { controlActive != .inactive }

    var body: some View {
        AgentDotCA(style: style, diameter: diameter)
            .frame(width: diameter + 7, height: diameter + 7)
            .opacity(isKey ? 1 : 0.7)
            .help(style.help)
    }
}

/// The breathing dot as CORE ANIMATION layers. History of this dot, so it never
/// regresses again:
///   1. `.animation`/@State repeatForever — wrote state during the SwiftUI update
///      phase → AttributeGraph cycle → rows' update branches severed (dots stuck,
///      selection stuck). Banned.
///   2. TimelineView(.periodic 30fps) (PR #60) — fine on macOS 15, but macOS 26
///      re-places the WHOLE lazy sidebar on every tick inside a list row: 30
///      full placement passes/sec pinned the main thread at 100% whenever any
///      agent was working and the window was key ("app hanging" storms).
///   3. This: CABasicAnimations on layers. The render server interpolates;
///      the app process does ZERO per-frame work, SwiftUI sees a fixed-size
///      static NSView, layout is never invalidated. updateNSView re-applies
///      only when the style actually changed (and reads no observable state).
private struct AgentDotCA: NSViewRepresentable {
    let style: AgentIndicatorStyle
    let diameter: CGFloat

    func makeNSView(context: Context) -> DotHost { DotHost() }
    func updateNSView(_ v: DotHost, context: Context) { v.apply(style: style, diameter: diameter) }

    final class DotHost: NSView {
        private let halo = CALayer()
        private let core = CALayer()
        private var appliedKey = ""
        private var pulsing = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.addSublayer(halo)
            layer?.addSublayer(core)
        }
        required init?(coder: NSCoder) { nil }

        func apply(style: AgentIndicatorStyle, diameter: CGFloat) {
            let color = NSColor(style.color)
            let key = "\(color.description)|\(style.filled)|\(style.pulses)|\(diameter)"
            guard key != appliedKey else { return }
            appliedKey = key
            pulsing = style.pulses

            let total = diameter + 7
            let inset = (total - diameter) / 2
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            halo.frame = CGRect(x: 0, y: 0, width: total, height: total)
            halo.cornerRadius = total / 2
            halo.backgroundColor = color.withAlphaComponent(0.30).cgColor
            core.frame = CGRect(x: inset, y: inset, width: diameter, height: diameter)
            core.cornerRadius = diameter / 2
            if style.filled {
                core.backgroundColor = color.cgColor
                core.borderWidth = 0
            } else {
                core.backgroundColor = NSColor.clear.cgColor
                core.borderColor = color.cgColor
                core.borderWidth = 1.5
            }
            if style.pulses {
                core.shadowColor = color.cgColor
                core.shadowOpacity = 0.55
                core.shadowRadius = 3
                core.shadowOffset = .zero
            } else {
                core.shadowOpacity = 0
            }
            CATransaction.commit()
            restartAnimations()
        }

        /// The render-server animations: an expanding, fading halo ring and a
        /// gently dimming core, both on a 1.4s cycle (same feel as before).
        private func restartAnimations() {
            halo.removeAllAnimations()
            core.removeAllAnimations()
            halo.opacity = pulsing ? 0.55 : 0
            guard pulsing else { return }

            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.55
            scale.toValue = 1.0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.55
            fade.toValue = 0.0
            let haloGroup = CAAnimationGroup()
            haloGroup.animations = [scale, fade]
            haloGroup.duration = 1.4
            haloGroup.repeatCount = .infinity
            halo.add(haloGroup, forKey: "breathe")

            let dim = CABasicAnimation(keyPath: "opacity")
            dim.fromValue = 1.0
            dim.toValue = 0.55
            dim.duration = 0.7
            dim.autoreverses = true
            dim.repeatCount = .infinity
            dim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            core.add(dim, forKey: "breathe")
        }

        /// CA strips animations from detached layers; lazy rows detach/reattach
        /// constantly, so re-arm whenever we land in a window.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { restartAnimations() }
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
    // Plain value, NOT a closure reading @Published. SwiftUI evaluates .contextMenu
    // content during the update phase, so reading an observable here (the old
    // `wandbRunsProvider` did) subscribed the menu to @Published wandbRuns and
    // formed an AttributeGraph cycle that froze the row. The parent already
    // observes `terminals`, so it recomputes + passes this fresh.
    var wandbRuns: [WandbRun] = []
    var onOpenWandb: (WandbRun?) -> Void = { _ in }
    var onClearWandb: (WandbRun) -> Void = { _ in }
    var onReveal: (() -> Void)? = nil
    var onRevealFiles: (() -> Void)? = nil
    var onGit: (() -> Void)? = nil   // open the Git panel (lazygit) for this session

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
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text(relativeShort(session.activity))
                            .font(cf(10.5, .medium))
                            .monospacedDigit()
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize()
                    }
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
            let runs = wandbRuns   // plain value — no observable read during menu build
            if runs.count == 1 {
                Button("Open W&B") { onOpenWandb(runs.last) }
                if let r = runs.last { Button("Clear W&B Run") { onClearWandb(r) } }
                Divider()
            } else if runs.count > 1 {
                Menu("Open W&B") {
                    ForEach(runs.reversed()) { r in Button(r.label) { onOpenWandb(r) } }
                }
                Menu("Clear W&B Run") {   // per-run — pick exactly which id to forget
                    ForEach(runs.reversed()) { r in Button(r.label) { onClearWandb(r) } }
                }
                Divider()
            }
            if let onGit { Button("Show Git Panel") { onGit() } }
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
