import SwiftUI

struct MachinesView: View {
    @EnvironmentObject var fleet: FleetStore
    @EnvironmentObject var router: AppRouter

    var body: some View {
        List {
            ForEach(fleet.machines) { m in
                Section(m.name) {
                    ForEach(fleet.sessions(on: m)) { s in
                        Button(s.name) { router.openTerminal(m, s) }
                    }
                }
            }
        }
        .navigationTitle("Machines")
        .refreshable { await fleet.refreshNow() }
    }
}
