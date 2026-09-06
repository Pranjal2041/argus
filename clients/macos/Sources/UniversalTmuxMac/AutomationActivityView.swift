import SwiftUI
import ArgusProtocol

struct AutomationActivityView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var control: ArgusControlService
    @State private var review: WorkspaceSyncConflict?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Local automation").font(.title2.bold())
                Text("Actions from the Argus CLI. Actor names are attribution, not authentication.")
                    .foregroundStyle(.secondary)
                if let issue = state.workspaceStorageError { Text(issue).foregroundStyle(.orange) }
                ForEach(state.workspaceSync.issues.keys.sorted(), id: \.self) { key in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading) {
                            Text("\(key.capitalized) sync").font(.headline)
                            Text(state.workspaceSync.issues[key] ?? "").foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let conflict = state.workspaceSync.state.conflicts[key] {
                            Button("Review…") { review = conflict }
                        }
                    }.padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                }
                Divider()
                ForEach(control.recentActivity, id: \.id) { row in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.entry.method.replacingOccurrences(of: ".", with: " ")).font(.headline)
                            Text(row.entry.actor).foregroundStyle(.secondary)
                            Text(row.id).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(row.entry.response == nil ? "Unconfirmed" : (row.entry.response!.ok ? "Completed" : "Failed"))
                            Text(row.entry.date, style: .relative).font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 6)
                    Divider()
                }
                if control.recentActivity.isEmpty { Text("No CLI actions yet.").foregroundStyle(.secondary) }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $review) { conflict in WorkspaceConflictReview(conflict: conflict).environmentObject(state) }
    }
}

struct WorkspaceConflictReview: View {
    let conflict: WorkspaceSyncConflict
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var document = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review \(conflict.key) edits").font(.title2.bold())
            Text("Both copies are preserved. Edit the merged JSON below or choose a starting copy. Newer edits are checked again when you apply.")
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 16) {
                copy("Mac copy", conflict.local)
                copy("Sync-host copy", conflict.remote)
            }.frame(maxHeight: 200)
            HStack {
                Button("Start with Mac copy") { document = pretty(conflict.local) }
                Button("Start with sync-host copy") { document = pretty(conflict.remote) }
            }
            Text("Merged result").font(.headline)
            TextEditor(text: $document).font(.system(.body, design: .monospaced))
            if let error { Text(error).foregroundStyle(.orange) }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Apply reviewed merge") { apply() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(minWidth: 720, idealWidth: 960, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { document = pretty(conflict.local) }
    }
    private func copy(_ title: String, _ value: ArgusJSON) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.headline)
            ScrollView { Text(pretty(value)).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        }.frame(maxWidth: .infinity)
    }
    private func pretty(_ value: ArgusJSON) -> String {
        String(data: (try? ArgusWire.encoder(pretty: true).encode(value)) ?? Data(), encoding: .utf8) ?? ""
    }
    private func apply() {
        do {
            let value = try JSONDecoder().decode(ArgusJSON.self, from: Data(document.utf8))
            try state.workspaceSync.resolve(key: conflict.key, expectedRevision: ArgusJSON.encode(conflict).revision,
                current: state.workspaceCollections()[conflict.key] ?? .null, merged: value,
                validate: { try state.applyWorkspaceCollection(conflict.key, $0, validateOnly: true) }) { try state.applyWorkspaceCollection(conflict.key, $0) }
            state.syncUserData(); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
