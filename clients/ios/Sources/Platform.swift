import SwiftUI

// FIRST PASS — fleshed out in the Command Center / terminal / notifications work.

struct ThemePalette: Identifiable, Equatable {
    let id: String
    let name: String
    let accent: Color
    let isLight: Bool
    static let argus = ThemePalette(id: "argus", name: "Argus", accent: .blue, isLight: false)
    static let all: [ThemePalette] = [.argus]
}

@MainActor
final class ThemeStore: ObservableObject {
    @Published var palette: ThemePalette = .argus
}

@MainActor
final class AttentionNotifications {
    static let shared = AttentionNotifications()
    func attach(fleet: FleetStore, lab: LabStore, router: AppRouter) {}
    func clearBadgeIfNeeded() {}
}

@MainActor
final class JournalCapture {
    static let shared = JournalCapture()
    func attach(fleet: FleetStore) {}
}

enum BackgroundRefresh {
    static let identifier = "dev.universaltmux.ios.refresh"
    static func schedule() {}
    static func run() async {}
}
