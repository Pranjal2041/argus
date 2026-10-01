import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var fleet: FleetStore
    var body: some View {
        Form { LabeledContent("Hub", value: fleet.hubAddress) }.navigationTitle("Settings")
    }
}
