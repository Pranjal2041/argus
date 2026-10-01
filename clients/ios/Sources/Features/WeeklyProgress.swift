import SwiftUI

// PLACEHOLDER — replaced by Weekly Progress (catalog, slides, reports, Generate/Resume).
// Contract: WeeklyProgressStore (ObservableObject, start(fleet:)), WeeklyProgressView.

@MainActor
final class WeeklyProgressStore: ObservableObject {
    func start(fleet: FleetStore) {}
}

struct WeeklyProgressView: View { var body: some View { ContentUnavailableView("Weekly Progress", systemImage: "chart.bar.doc.horizontal") } }
