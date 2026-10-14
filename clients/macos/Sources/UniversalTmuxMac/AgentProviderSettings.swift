import SwiftUI

struct WeeklyProgressProviderBadge: View {
    let scale: Double
    @AppStorage private var provider: String

    init(scale: Double, defaults: UserDefaults = .standard) {
        self.scale = scale
        _provider = AppStorage(wrappedValue: "", AgentTaskPurpose.weeklyProgress.preferenceKey, store: defaults)
    }

    var body: some View {
        let selected = AgentProvider(rawValue: provider).flatMap {
            AgentTaskPurpose.weeklyProgress.supportedProviders.contains($0) ? $0 : nil
        } ?? AgentTaskPurpose.weeklyProgress.defaultProvider
        Text(WeeklyProgressModelPresentation.label(provider: selected))
            .font(.system(size: 9.5 * scale, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Capsule().fill(Theme.surface.opacity(0.75)))
            .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
    }
}

extension AgentProvider {
    var tint: Color {
        switch self { case .claude: return Theme.waiting; case .codex: return Theme.running; case .devin: return Theme.accent }
    }
}

struct AgentProviderSettingsSection: View {
    var defaults: UserDefaults = .standard
    var body: some View {
        Section {
            ForEach(AgentTaskPurpose.allCases) { purpose in
                AgentProviderPicker(purpose: purpose, defaults: defaults)
            }
        } header: {
            Text("AI providers")
        } footer: {
            Text("Uses each CLI's existing login on this Mac. Saved weekly reports keep their original provider.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct AgentProviderPicker: View {
    let purpose: AgentTaskPurpose
    @AppStorage private var selection: String

    init(purpose: AgentTaskPurpose, defaults: UserDefaults) {
        self.purpose = purpose
        _selection = AppStorage(wrappedValue: "", purpose.preferenceKey, store: defaults)
    }

    var body: some View {
        Picker(purpose.displayName, selection: $selection) {
            Text("Default (\(purpose.defaultProvider.displayName))").tag("")
            ForEach(purpose.supportedProviders) { provider in
                Text(provider.displayName).tag(provider.rawValue)
            }
        }
        .accessibilityIdentifier("agent-provider-" + purpose.rawValue)
    }
}
