import SwiftUI

@available(macOS 14.0, *)
struct SourceAccessView: View {
    var source: UsageSource
    var includeUnavailable = true
    var body: some View {
        if let capabilities = source.capabilities {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(capabilities.filter { includeUnavailable || $0.status == .available }) { capability in
                    DisclosureGroup {
                        Text(capability.message).font(.system(size: 11)).foregroundStyle(Palette.secondary)
                            .fixedSize(horizontal: false, vertical: true).padding(.top, 5)
                    } label: {
                        HStack {
                            Label(capability.label, systemImage: capability.status == .available ? "checkmark.circle" : "exclamationmark.circle")
                            Spacer(minLength: 6)
                            Text(capability.shortStatus)
                        }.font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    }
                }
                if includeUnavailable && source.integration == .daytona && source.hasUnavailableCapabilities {
                    Link("Open Daytona dashboard ↗", destination: URL(string: "https://app.daytona.io")!)
                        .font(.system(size: 11))
                }
            }.accessibilityIdentifier("source-access-\(source.id)")
        }
    }
}
