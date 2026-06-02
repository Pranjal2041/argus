import AppKit
import SwiftUI

extension Machine {
    var fwScheme: String { URLComponents(string: httpBase)?.scheme ?? "https" }
    var fwHost: String { URLComponents(string: httpBase)?.host ?? "" }
}

/// The Port hub window (glassy): live forwards lit up as frosted cards, a new
/// forward composer (host → a port picked from the host's /ports or typed → label),
/// and saved forwards for one-click re-run. Local ports open in the browser.
///
/// All sizes multiply by the shared interface scale (Settings ▸ Interface), so the
/// whole window grows/shrinks with the rest of the app.
struct PortsView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var model = PortsModel()
    @AppStorage("ut.uiScale") private var uiScale: Double = 1.0
    @State private var selectedHostId: String = ""
    @State private var portText: String = ""
    @State private var label: String = ""

    private var hosts: [Machine] { state.machines.filter { !$0.isLocal } }
    private var selectedHost: Machine? { hosts.first { $0.id == selectedHostId } }
    private var canForward: Bool { selectedHost != nil && Int(portText.trimmingCharacters(in: .whitespaces)).map { $0 > 0 && $0 < 65536 } == true }

    /// Scale a base point size/padding by the interface scale.
    private func S(_ v: CGFloat) -> CGFloat { v * uiScale }

    var body: some View {
        ZStack {
            GlassBackground()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: S(24)) {
                        activeSection
                        newForwardSection
                        savedSection
                    }
                    .padding(.horizontal, S(20))
                    .padding(.top, S(8))
                    .padding(.bottom, S(28))
                }
            }
        }
        .frame(minWidth: 600, minHeight: 600)
        .onAppear {
            if selectedHostId.isEmpty { selectedHostId = hosts.first?.id ?? "" }
            if let h = selectedHost { model.fetchPorts(host: h.fwHost, base: h.httpBase) }
        }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: S(12)) {
            Image(systemName: "cable.connector.horizontal")
                .font(.system(size: S(19), weight: .semibold))
                .foregroundStyle(Glass.accentGradient)
            Text("Port forwards")
                .font(.system(size: S(20), weight: .bold))
                .foregroundStyle(Glass.textPrimary)
            Spacer()
            statusPill
            GlassIconButton(system: "arrow.clockwise", help: "Refresh") {
                model.refreshActive()
                if let h = selectedHost { model.fetchPorts(host: h.fwHost, base: h.httpBase) }
            }
        }
        .padding(.leading, 80)
        .padding(.trailing, S(16))
        .frame(height: S(56))
    }

    private var statusPill: some View {
        HStack(spacing: S(6)) {
            Circle().fill(hosts.isEmpty ? Glass.warn : Glass.live).frame(width: S(7), height: S(7))
                .shadow(color: (hosts.isEmpty ? Glass.warn : Glass.live).opacity(0.8), radius: 3)
            Text(hosts.isEmpty ? "no hosts" : "\(hosts.count) host\(hosts.count == 1 ? "" : "s")")
                .font(.system(size: S(12.5), weight: .medium))
                .foregroundStyle(Glass.textSecondary)
        }
        .padding(.horizontal, S(11)).padding(.vertical, S(6))
        .background(Capsule().fill(.white.opacity(0.06)))
        .overlay(Capsule().stroke(.white.opacity(0.09), lineWidth: 1))
    }

    // MARK: active

    private var activeSection: some View {
        VStack(alignment: .leading, spacing: S(11)) {
            sectionHeader("ACTIVE", count: model.active.count)
            if model.active.isEmpty {
                emptyActive
            } else {
                ForEach(model.active) { f in
                    HStack(spacing: S(14)) {
                        PulsingDot(color: Glass.live)
                        VStack(alignment: .leading, spacing: S(4)) {
                            Text(f.label.isEmpty ? hostLabel(f.brokerHost, f.brokerName) : f.label)
                                .font(.system(size: S(15.5), weight: .semibold))
                                .foregroundStyle(Glass.textPrimary)
                            HStack(spacing: S(6)) {
                                Text(hostLabel(f.brokerHost, f.brokerName)).foregroundStyle(Glass.accent)
                                Text(":\(String(f.remotePort))").foregroundStyle(Glass.textSecondary)
                                Image(systemName: "arrow.right").font(.system(size: S(10), weight: .bold)).foregroundStyle(Glass.textTertiary)
                                Text("localhost:\(String(f.localPort))").foregroundStyle(Glass.textSecondary)
                            }
                            .font(.system(size: S(12.5), design: .monospaced))
                        }
                        Spacer(minLength: S(8))
                        GlassIconButton(system: "arrow.up.right.square", help: "Open in browser", tint: Glass.accent) { open(f.localPort) }
                        GlassIconButton(system: "stop.circle", help: "Stop forward", tint: Glass.danger) {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { model.stop(f.id) }
                        }
                    }
                    .padding(.horizontal, S(16)).padding(.vertical, S(14))
                    .glassCard(glow: Glass.live)
                    // Plain opacity — a `.scale` transition here could render the row
                    // momentarily mirror-flipped (a SwiftUI/CoreAnimation glitch).
                    .transition(.opacity)
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.active.map(\.id))
    }

    private var emptyActive: some View {
        VStack(spacing: S(10)) {
            Image(systemName: "cable.connector.horizontal")
                .font(.system(size: S(27), weight: .light))
                .foregroundStyle(Glass.textTertiary)
            Text("No active forwards").font(.system(size: S(14), weight: .medium)).foregroundStyle(Glass.textSecondary)
            Text("Pick a host below and forward a port.").font(.system(size: S(12), weight: .regular)).foregroundStyle(Glass.textTertiary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, S(28))
        .glassCard()
    }

    // MARK: new forward

    private var newForwardSection: some View {
        VStack(alignment: .leading, spacing: S(14)) {
            sectionHeader("NEW FORWARD")
            VStack(alignment: .leading, spacing: S(14)) {
                if hosts.isEmpty {
                    Text("No remote hosts discovered yet.").font(.system(size: S(14))).foregroundStyle(Glass.textSecondary)
                } else {
                    hostMenu
                    portChips
                    HStack(spacing: S(11)) {
                        GlassField(placeholder: "port", text: $portText, mono: true, width: 96)
                        GlassField(placeholder: "label (optional)", text: $label)
                        Button {
                            guard let h = selectedHost, let port = Int(portText.trimmingCharacters(in: .whitespaces)) else { return }
                            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                                model.start(host: h.fwHost, name: h.name, scheme: h.fwScheme, remotePort: port, label: label.trimmingCharacters(in: .whitespaces))
                            }
                            portText = ""; label = ""
                        } label: {
                            HStack(spacing: S(6)) { Text("Forward"); Image(systemName: "arrow.right").font(.system(size: S(12), weight: .bold)) }
                        }
                        .buttonStyle(AccentButtonStyle(enabled: canForward, scale: uiScale))
                        .disabled(!canForward)
                        .keyboardShortcut(.return)
                    }
                }
            }
            .padding(S(17))
            .glassCard(strong: true)
        }
    }

    private var hostMenu: some View {
        Menu {
            ForEach(hosts) { m in
                Button {
                    selectedHostId = m.id
                    model.fetchPorts(host: m.fwHost, base: m.httpBase)
                } label: { Text(m.name) }
            }
        } label: {
            HStack(spacing: S(9)) {
                Circle().fill(Glass.accent).frame(width: S(8), height: S(8)).shadow(color: Glass.accent.opacity(0.8), radius: 3)
                Text(selectedHost?.name ?? "Select a host")
                    .font(.system(size: S(14.5), weight: .medium)).foregroundStyle(Glass.textPrimary)
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.system(size: S(11), weight: .semibold)).foregroundStyle(Glass.textSecondary)
            }
            .padding(.horizontal, S(13)).padding(.vertical, S(11))
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white.opacity(0.10), lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    @ViewBuilder private var portChips: some View {
        if let h = selectedHost {
            let ports = model.portsByHost[h.fwHost] ?? []
            if model.loadingPortsFor == h.fwHost && ports.isEmpty {
                HStack(spacing: S(7)) {
                    ProgressView().controlSize(.small).scaleEffect(0.8)
                    Text("scanning ports…").font(.system(size: S(12))).foregroundStyle(Glass.textSecondary)
                }.padding(.vertical, 2)
            } else if ports.isEmpty {
                Text("No listening ports found — type one below.").font(.system(size: S(12))).foregroundStyle(Glass.textTertiary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: S(8)) {
                        ForEach(ports) { p in portChip(p) }
                    }.padding(.vertical, 1)
                }
            }
        }
    }

    private func portChip(_ p: PortInfo) -> some View {
        let selected = portText.trimmingCharacters(in: .whitespaces) == String(p.port)
        return Button { portText = String(p.port) } label: {
            HStack(spacing: S(6)) {
                Circle().fill(Glass.tint(for: p.process)).frame(width: S(7), height: S(7))
                Text("\(String(p.port))").font(.system(size: S(13.5), weight: .semibold, design: .monospaced)).foregroundStyle(Glass.textPrimary)
                if !p.process.isEmpty {
                    Text(p.process).font(.system(size: S(11))).foregroundStyle(Glass.textSecondary).lineLimit(1)
                }
            }
            .padding(.horizontal, S(11)).padding(.vertical, S(8))
            .background(Capsule().fill(.white.opacity(selected ? 0.14 : 0.05)))
            .overlay(Capsule().stroke(selected ? Glass.accent.opacity(0.75) : .white.opacity(0.09), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: saved

    private var savedSection: some View {
        VStack(alignment: .leading, spacing: S(11)) {
            if !model.saved.isEmpty {
                sectionHeader("SAVED", count: model.saved.count)
                ForEach(model.saved) { s in
                    HStack(spacing: S(13)) {
                        Image(systemName: "bookmark.fill").font(.system(size: S(12.5))).foregroundStyle(Glass.accent2.opacity(0.85))
                        VStack(alignment: .leading, spacing: S(2)) {
                            Text(s.label.isEmpty ? hostLabel(s.brokerHost, s.brokerName) : s.label)
                                .font(.system(size: S(15), weight: .medium)).foregroundStyle(Glass.textPrimary)
                            Text("\(hostLabel(s.brokerHost, s.brokerName)):\(String(s.remotePort))")
                                .font(.system(size: S(12), design: .monospaced)).foregroundStyle(Glass.textSecondary)
                        }
                        Spacer(minLength: S(8))
                        if let f = model.activeFor(s) {
                            Button { open(f.localPort) } label: {
                                HStack(spacing: S(5)) { Circle().fill(Glass.live).frame(width: S(5), height: S(5)); Text("localhost:\(String(f.localPort))") }
                            }.buttonStyle(GhostButtonStyle(color: Glass.live, scale: uiScale))
                        } else {
                            Button {
                                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { model.run(s) }
                            } label: { HStack(spacing: S(5)) { Image(systemName: "play.fill").font(.system(size: S(9.5))); Text("Run") } }
                            .buttonStyle(GhostButtonStyle(scale: uiScale))
                        }
                        GlassIconButton(system: "trash", help: "Remove", tint: Glass.textTertiary) {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { model.removeSaved(s) }
                        }
                    }
                    .padding(.horizontal, S(14)).padding(.vertical, S(12))
                    .glassCard(cornerRadius: 13)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: model.saved.map(\.id))
    }

    // MARK: helpers

    private func sectionHeader(_ t: String, count: Int = -1) -> some View {
        HStack(spacing: S(8)) {
            Text(t).font(.system(size: S(12), weight: .bold)).tracking(1.4).foregroundStyle(Glass.textTertiary)
            if count >= 0 {
                Text("\(count)")
                    .font(.system(size: S(11), weight: .bold))
                    .foregroundStyle(Glass.accent)
                    .padding(.horizontal, S(6)).padding(.vertical, S(1.5))
                    .background(Capsule().fill(Glass.accent.opacity(0.16)))
            }
            Spacer()
        }
        .padding(.leading, 2)
    }

    private func hostLabel(_ host: String, _ name: String) -> String { name.isEmpty ? host : name }
    private func open(_ port: Int) { if let u = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(u) } }
}
