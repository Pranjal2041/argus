import SwiftUI

@available(macOS 14.0, *)
struct SearchSourcesView: View {
    @Bindable var store: UsageStore
    @State private var query = ""
    @FocusState private var focused: Bool
    private var results: [SearchResult] { DashboardLogic.search(query, in: store.sources) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.secondary)
                TextField("Search accounts, services, or drives…", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 15)).focused($focused)
                    .onSubmit { if let result = results.first { select(result) } }
                    .accessibilityIdentifier("source-search-field")
                IconButton(symbol: "xmark", label: "Close search") { store.showSearch = false }
            }.padding(20)
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    Text(query.isEmpty ? "YOUR SOURCES" : "\(results.count) RESULTS")
                        .font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(Palette.tertiary).padding(.horizontal, 10).padding(.vertical, 10)
                    ForEach(results) { result in
                        Button { select(result) } label: {
                            HStack(spacing: 13) {
                                SourceIcon(integration: result.integration, size: 21)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(result.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.text)
                                    Text(result.subtitle).font(.system(size: 11)).foregroundStyle(Palette.secondary)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.left").font(.system(size: 10)).foregroundStyle(Palette.tertiary)
                            }.padding(11).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("search-result-\(result.id)")
                    }
                    if results.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "magnifyingglass").font(.system(size: 24)).foregroundStyle(Palette.tertiary)
                            Text("No matching sources").font(.system(size: 14, weight: .medium))
                            Text("Try an account name, a service, or a drive.").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 50)
                    }
                }.padding(10)
            }.frame(height: 370)
            Hairline()
            HStack {
                Text("↵ Open first result")
                Spacer()
                Text("esc Close")
            }.font(.system(size: 10)).foregroundStyle(Palette.tertiary).padding(.horizontal, 21).padding(.vertical, 13)
        }
        .frame(width: 560).background(Palette.surface).foregroundStyle(Palette.text)
        .onAppear { focused = true }
        .onExitCommand { store.showSearch = false }
    }

    private func select(_ result: SearchResult) {
        store.page = "Overview"
        store.selectedCategory = nil
        store.selection = result.selection
        store.showSearch = false
    }
}

@available(macOS 14.0, *)
struct AddSourceView: View {
    @Bindable var store: UsageStore
    @State private var provider: IntegrationID?
    @State private var label = ""
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(provider == nil ? "Add a source" : "Add \(provider!.name)").font(.system(size: 23, weight: .semibold)).tracking(-0.4)
                    Text(provider == nil ? "Your next service, all in the same place." : "Give this account a name you'll recognize.")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
                Spacer()
                IconButton(symbol: "xmark", label: "Cancel adding source") { store.showAddSource = false }
            }
            if let provider {
                HStack(spacing: 13) {
                    SourceIcon(integration: provider)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(provider.name).font(.system(size: 14, weight: .semibold))
                        Text(provider.detail).font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    }
                    Spacer()
                    SoftBadge(text: "Demo")
                }.padding(16).background(Palette.inset).clipShape(RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 9) {
                    Text(provider.category == .devices ? "Device name" : "Account name").font(.system(size: 12, weight: .medium))
                    TextField("e.g. Research", text: $label).textFieldStyle(.roundedBorder).controlSize(.large)
                        .focused($nameFocused).onSubmit(add).accessibilityIdentifier("new-source-name")
                    if let error { Text(error).font(.system(size: 11)).foregroundStyle(Palette.secondary) }
                }
                Text("This source will use sample data. No account or credentials are needed yet.")
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button { self.provider = nil; error = nil } label: { Label("Back", systemImage: "chevron.left") }.buttonStyle(SecondaryButtonStyle())
                    Spacer()
                    Button("Add demo source", action: add).buttonStyle(PrimaryButtonStyle())
                        .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("confirm-add-source")
                }
            } else {
                VStack(spacing: 9) {
                    ForEach(IntegrationID.allCases) { integration in
                        Button {
                            provider = integration
                            let count = store.sources.filter { $0.integration == integration }.count
                            label = integration.category == .devices ? "\(integration == .macStorage ? "Mac" : "Windows PC") \(count + 1)" : "Account \(count + 1)"
                            nameFocused = true
                        } label: {
                            HStack(spacing: 13) {
                                SourceIcon(integration: integration, size: 22)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(integration.name).font(.system(size: 13, weight: .semibold))
                                    Text(integration.detail).font(.system(size: 11)).foregroundStyle(Palette.secondary)
                                }
                                Spacer()
                                Image(systemName: "plus").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Palette.inset.opacity(0.65)).clipShape(RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("choose-\(integration.rawValue)")
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: "circle.dotted")
                    Text("Explore with sample data. Real connections come next.")
                }.font(.system(size: 11)).foregroundStyle(Palette.secondary)
            }
        }
        .padding(27).frame(width: 500).background(Palette.surface).foregroundStyle(Palette.text)
        .onExitCommand { store.showAddSource = false }
    }

    private func add() {
        guard let provider else { return }
        if store.addSource(provider, label: label) { store.showAddSource = false }
        else { error = "This source isn't ready. Refresh the overview and try again." }
    }
}

@available(macOS 14.0, *)
struct ActivityView: View {
    var store: UsageStore
    var body: some View {
        SourceCard {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Recent activity").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Text(store.isDemo ? "Sample events" : "This session").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                }.padding(.bottom, 13)
                ForEach(Array(store.filteredEvents.enumerated()), id: \.element.id) { index, event in
                    if index > 0 { Hairline() }
                    Button {
                        if let selection = event.selection { store.selection = selection }
                    } label: {
                        HStack(alignment: .center, spacing: 15) {
                            Image(systemName: event.symbol).font(.system(size: 16))
                                .foregroundStyle(Palette.blue)
                                .frame(width: 36, height: 36)
                                .background(Palette.inset).clipShape(RoundedRectangle(cornerRadius: 9))
                            VStack(alignment: .leading, spacing: 6) {
                                Text(event.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.text)
                                Text(event.detail).font(.system(size: 11)).foregroundStyle(Palette.secondary)
                            }
                            Spacer()
                            Text(UsageFormat.freshness(event.date, now: store.now)).font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Palette.tertiary).opacity(event.selection == nil ? 0 : 1)
                        }.padding(.vertical, 15).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(event.selection == nil)
                }
                if store.filteredEvents.isEmpty {
                    Text("No activity for these sources yet.").font(.system(size: 13)).foregroundStyle(Palette.secondary).padding(.vertical, 50)
                }
            }
        }.accessibilityIdentifier("activity-list")
    }
}

@available(macOS 14.0, *)
struct PreferencesView: View {
    @Bindable var store: UsageStore
    var body: some View {
        VStack(alignment: .leading, spacing: 25) {
            HStack(spacing: 12) {
                AppMark(size: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Usage").font(.system(size: 20, weight: .semibold))
                    Text("A little clarity for your workspace.").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
            }
            Hairline()
            VStack(alignment: .leading, spacing: 12) {
                Text("Appearance").font(.system(size: 13, weight: .semibold))
                Picker("Appearance", selection: $store.appearance) {
                    ForEach(Appearance.allCases) { appearance in Label(appearance.title, systemImage: appearance.symbol).tag(appearance) }
                }.labelsHidden().pickerStyle(.segmented)
                Text("System follows the appearance set in macOS.").font(.system(size: 11)).foregroundStyle(Palette.secondary)
            }
            Hairline()
            HStack {
                Text("Version 0.2.0").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                Spacer()
                SoftBadge(text: store.isDemo ? "Demo data" : "Live mode", symbol: "circle.dotted")
            }
        }.padding(28).frame(width: 400).background(Palette.surface).foregroundStyle(Palette.text)
    }
}
