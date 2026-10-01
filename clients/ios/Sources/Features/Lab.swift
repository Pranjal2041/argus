import SwiftUI

// PLACEHOLDER — replaced by the full Argus Lab implementation.
// Contract used by the rest of the app (keep these names/shapes):
//   LabAttentionItem, LabStore (ObservableObject: attention, unattended, start(fleet:), setUnattended(_:)), LabView.

struct LabAttentionItem: Identifiable, Hashable {
    enum Kind: String, Hashable { case key = "KEY", proposal = "PROPOSAL" }
    let kind: Kind
    /// Android-compatible target id: "<brokerID>/<fullKey>" or "<brokerID>/<set>/<run>".
    let targetID: String
    let reference: String
    let project: String
    let machineName: String
    let summary: String
    let created: Date?
    var id: String { (kind == .key ? "key/" : "proposal/") + targetID }
}

@MainActor
final class LabStore: ObservableObject {
    @Published var attention: [LabAttentionItem] = []
    /// Unattended Mode on the Mac (nil = unknown).
    @Published var unattended: Bool?
    func start(fleet: FleetStore) {}
    func setUnattended(_ on: Bool) async {}
}

struct LabView: View {
    var body: some View { ContentUnavailableView("Lab", systemImage: "flask") }
}
