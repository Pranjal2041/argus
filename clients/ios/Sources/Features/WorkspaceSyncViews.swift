import SwiftUI

/// Sync status for one collection, shown as the first list section: a review
/// prompt for preserved conflicts, an error with Retry, or a note that nothing
/// syncs until a Mac is found. Renders nothing when all is well.
struct WorkspaceSyncSection: View {
    let key: WorkspaceKey
    @EnvironmentObject var store: WorkspaceStore
    @EnvironmentObject var fleet: FleetStore
    @State private var reviewing = false

    var body: some View {
        if let text = store.banner(for: key) {
            let conflict = store.conflicts[key] != nil
            Section {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: conflict ? "exclamationmark.triangle.fill" : "exclamationmark.icloud")
                        .foregroundStyle(conflict ? .orange : .red)
                    Text(text).font(.footnote)
                    Spacer(minLength: 8)
                    Button(conflict ? "Review" : "Retry") {
                        if conflict { reviewing = true } else { store.retry(key) }
                    }
                    .buttonStyle(.borderless)
                    .font(.footnote.weight(.semibold))
                }
            }
            .sheet(isPresented: $reviewing) {
                if let c = store.conflicts[key] { WorkspaceReviewSheet(key: key, conflict: c) }
            }
        } else if fleet.isConfigured, fleet.syncHost == nil, !fleet.machines.isEmpty || fleet.lastRefresh != nil {
            Section {
                Label("No Mac found yet. Changes stay on this iPhone and sync when your Mac is reachable.",
                      systemImage: "icloud.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Both preserved copies of a collection as editable JSON. Applying validates
/// the document against the record format, saves it with the reviewed Mac copy
/// as the baseline and syncs again, so newer Mac edits still merge on top.
struct WorkspaceReviewSheet: View {
    let key: WorkspaceKey
    let conflict: WorkspaceConflict
    @EnvironmentObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var document: String
    @State private var source = Source.phone
    @State private var error: String?

    enum Source: Hashable { case phone, mac }

    init(key: WorkspaceKey, conflict: WorkspaceConflict) {
        self.key = key
        self.conflict = conflict
        _document = State(initialValue: WorkspaceCodec.pretty(conflict.local))
    }

    private var paths: [String] { conflict.paths.array?.compactMap(\.string) ?? [] }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Your iPhone and your Mac changed the same \(key.title.lowercased()) records. Both copies are preserved. Start from one, edit the JSON if needed, then apply.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if !paths.isEmpty {
                    Text("Conflicting: " + paths.joined(separator: ", "))
                        .font(.caption.monospaced())
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                }
                Picker("Start from", selection: $source) {
                    Text("iPhone copy").tag(Source.phone)
                    Text("Mac copy").tag(Source.mac)
                }
                .pickerStyle(.segmented)
                .onChange(of: source) { _, s in
                    document = WorkspaceCodec.pretty(s == .phone ? conflict.local : conflict.remote)
                    error = nil
                }
                TextEditor(text: $document)
                    .font(.system(.footnote, design: .monospaced))
                    .autocorrectionDisabled()          // also keeps quotes straight
                    .textInputAutocapitalization(.never)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
            .padding()
            .navigationTitle("Review \(key.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        do { try store.resolveConflict(key, document: document); dismiss() } catch {
                            self.error = error.localizedDescription
                        }
                    }
                }
            }
        }
    }
}
