import SwiftUI

/// The same preference is available beside the panel list and in Settings.
struct SidebarBacklogToggle: View {
    @Binding var isOn: Bool
    var label = "Hide backlog"

    var body: some View {
        Toggle(label, isOn: $isOn)
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("sidebar-hide-backlog")
            .help("Show only panels outside Command Center’s Backlog. Sessions keep running and remain accessible in Command Center and ⌘P.")
    }
}
