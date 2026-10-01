import SwiftUI

struct CommandCenterView: View {
    @EnvironmentObject var fleet: FleetStore
    @EnvironmentObject var router: AppRouter

    var body: some View {
        List {
            if let e = fleet.hubError { Section { Text(e).font(.footnote).foregroundStyle(.orange) } }
            ForEach(AttentionSection.allCases) { section in
                let cards = fleet.cards.filter { $0.status == section }
                if !cards.isEmpty {
                    Section(section.title + " · \(cards.count)") {
                        ForEach(cards) { card in
                            Button { router.openTerminal(card.machine, card.session) } label: { Text(card.session.name) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Command Center")
        .refreshable { await fleet.refreshNow() }
    }
}
