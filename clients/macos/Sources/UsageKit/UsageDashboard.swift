import SwiftUI

@available(macOS 14.0, *)
public struct UsageDashboard: View {
    @ObservedObject var controller: UsageController
    public init(controller: UsageController) { self.controller = controller }
    public var body: some View {
        RootView(store: controller.store)
            .preferredColorScheme(controller.store.appearance == .system ? nil : (controller.store.appearance == .dark ? .dark : .light))
            .environment(\.openURL, OpenURLAction { url in
                UsageBrowser.open(url) ? .handled : .discarded
            })
    }
}

@available(macOS 14.0, *)
public struct UsageWarningSettings: View {
    @ObservedObject var controller: UsageController
    public init(controller: UsageController) { self.controller = controller }
    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Usage warnings").font(.title2.bold())
                    Text("Account limits, monthly budgets, and drive space.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { controller.showSettings = false }.keyboardShortcut(.defaultAction).buttonStyle(PrimaryButtonStyle())
            }
            ScrollView {
              VStack(alignment: .leading, spacing: 16) {
                    Toggle("Show warnings in Command Center", isOn: $controller.policy.enabled)
                        .toggleStyle(.checkbox)
                    Hairline()
                    threshold("Quota remaining", enabled: $controller.policy.quotaEnabled, value: $controller.policy.quotaRemaining)
                    threshold("Monthly budget remaining", enabled: $controller.policy.budgetEnabled, value: $controller.policy.budgetRemaining)
                    threshold("Drive space remaining", enabled: $controller.policy.storageEnabled, value: $controller.policy.storageRemaining)
                    Toggle("Include model-specific quota windows", isOn: $controller.policy.includeModelLimits)
                        .toggleStyle(.checkbox)
                    Picker("Snooze duration", selection: $controller.policy.snoozeHours) {
                        Text("1 hour").tag(1.0); Text("4 hours").tag(4.0); Text("24 hours").tag(24.0)
                    }
                    Picker("Refresh interval", selection: $controller.refreshSeconds) {
                        Text("1 minute").tag(60.0); Text("2 minutes").tag(120.0)
                        Text("5 minutes").tag(300.0); Text("15 minutes").tag(900.0)
                    }
                    Hairline()
                    Text("ACCOUNTS & DEVICES").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(Palette.secondary)
                    ForEach(controller.store.sources) { source in
                        Toggle("\(source.name) · \(source.account)", isOn: Binding(
                            get: { !controller.policy.mutedSources.contains(source.id) },
                            set: { enabled in
                                if enabled { controller.policy.mutedSources.remove(source.id) }
                                else { controller.policy.mutedSources.insert(source.id) }
                            })).toggleStyle(.checkbox)
                    }
              }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }.background(Palette.inset).clipShape(RoundedRectangle(cornerRadius: 10))
            Text("Dismiss hides a warning until its limit resets or a fresh reading recovers. A drop to critically low remaining usage can alert again. Cached readings never trigger warnings.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Restore dismissed warnings") { controller.restoreDismissed() }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("usage-restore-warnings")
        }.padding(24).frame(width: 560, height: 660).background(Palette.surface).foregroundStyle(Palette.text)
    }

    private func threshold(_ title: String, enabled: Binding<Bool>, value: Binding<Double>) -> some View {
        HStack {
            Toggle(title, isOn: enabled).toggleStyle(.checkbox).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Stepper(value: value, in: 0...100, step: 5) { Text("≤ \(Int(value.wrappedValue))%").monospacedDigit() }
                .frame(width: 96).disabled(!enabled.wrappedValue)
        }
    }
}
