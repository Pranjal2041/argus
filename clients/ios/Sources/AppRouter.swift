import SwiftUI

struct SessionRoute: Hashable {
    let machine: Machine
    let session: SessionInfo
}

/// Cross-screen navigation: any screen can open a terminal, a folder on a
/// machine, or a Lab decision.
@MainActor
final class AppRouter: ObservableObject {
    enum Tab: Hashable { case commandCenter, machines, files, lab, more }

    @Published var tab: Tab = .commandCenter
    @Published var commandCenterPath = NavigationPath()
    @Published var machinesPath = NavigationPath()
    @Published var filesPath = NavigationPath()
    @Published var labPath = NavigationPath()
    @Published var morePath = NavigationPath()

    /// Files tab: open this machine at this path (a folder or a file's folder).
    @Published var filesTarget: FilesTarget?
    /// Lab tab: open this attention item's decision page.
    @Published var labTarget: LabAttentionItem?

    struct FilesTarget: Equatable { let machineID: String; let path: String; let id = UUID() }

    /// Push a terminal onto the visible tab's stack.
    func openTerminal(_ m: Machine, _ s: SessionInfo) {
        let route = SessionRoute(machine: m, session: s)
        switch tab {
        case .commandCenter: commandCenterPath.append(route)
        case .machines: machinesPath.append(route)
        case .files: filesPath.append(route)
        case .lab: labPath.append(route)
        case .more: morePath.append(route)
        }
    }

    func openFiles(_ m: Machine, path: String) {
        filesTarget = FilesTarget(machineID: m.id, path: path)
        filesPath = NavigationPath()
        tab = .files
    }

    func openLab(_ item: LabAttentionItem) {
        labTarget = item
        tab = .lab
    }
}

/// Destinations every stack understands.
struct ArgusDestinations: ViewModifier {
    func body(content: Content) -> some View {
        content.navigationDestination(for: SessionRoute.self) { TerminalScreen(machine: $0.machine, session: $0.session) }
    }
}

extension View {
    func argusDestinations() -> some View { modifier(ArgusDestinations()) }
}
