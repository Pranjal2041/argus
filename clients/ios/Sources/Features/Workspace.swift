import SwiftUI

// PLACEHOLDER — replaced by Notes / Todo Maps / Workflows with Mac sync.
// Contract: WorkspaceStore (ObservableObject, start(fleet:router:)), NotesView, TodoMapsView, WorkflowsView.

@MainActor
final class WorkspaceStore: ObservableObject {
    func start(fleet: FleetStore, router: AppRouter) {}
}

struct NotesView: View { var body: some View { ContentUnavailableView("Notes", systemImage: "note.text") } }
struct TodoMapsView: View { var body: some View { ContentUnavailableView("Todo Maps", systemImage: "checklist") } }
struct WorkflowsView: View { var body: some View { ContentUnavailableView("Workflows", systemImage: "play.rectangle") } }
