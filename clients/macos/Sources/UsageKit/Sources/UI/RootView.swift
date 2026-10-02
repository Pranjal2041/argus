import SwiftUI

@available(macOS 14.0, *)
struct RootView: View {
    @Bindable var store: UsageStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 900 || geometry.size.height < 700
            VStack(spacing: 0) {
                if compact { compactAppBar } else { appBar }
                Hairline()
                ZStack(alignment: .trailing) {
                    ScrollViewReader { scroll in
                      ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if !compact || store.page != "Overview" { pageHeading }
                            if store.page == "Connections" {
                                ConnectionsView(store: store)
                            } else {
                              if !compact { filters }
                              if !store.failures.isEmpty && store.isDemo { failureBanner }
                              if store.page == "Overview" {
                                if !store.didLoad && store.sources.isEmpty {
                                    loadingState
                                } else {
                                    if compact {
                                        CompactDashboard(store: store)
                                    } else {
                                        dashboard(width: geometry.size.width - 64)
                                        footer
                                    }
                                }
                              } else {
                                ActivityView(store: store)
                              }
                            }
                        }
                        .padding(.horizontal, compact ? 16 : 32)
                        .padding(.top, 12)
                        .padding(.bottom, 16)
                        .id("page-content-top")
                      }.accessibilityIdentifier("overview-scroll")
                        .onChange(of: store.connectionDraft?.id) { _, id in
                            if id != nil { withAnimation { scroll.scrollTo("page-content-top", anchor: .top) } }
                        }
                    }
                    if let source = store.selectedSource {
                        DetailPanel(source: source, store: store)
                            .frame(width: compact ? geometry.size.width : min(580, geometry.size.width * 0.53))
                            .background(Palette.surface)
                            .overlay(alignment: .leading) { Rectangle().fill(Palette.border).frame(width: 1) }
                            .shadow(color: .black.opacity(colorScheme == .dark ? 0.25 : 0.08), radius: 18, x: -6, y: 0)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                            .accessibilityIdentifier("detail-panel")
                    }
                }
            }
            .background(Palette.background)
            .foregroundStyle(Palette.text)
            .animation(.easeInOut(duration: 0.22), value: store.selection?.sourceID)
            .animation(.easeInOut(duration: 0.16), value: store.selectedCategory)
        }
        .onExitCommand { store.selection = nil }
        .sheet(isPresented: $store.showSearch) { SearchSourcesView(store: store) }
        .sheet(isPresented: $store.showAddSource) { AddSourceView(store: store) }
    }

    private var compactAppBar: some View {
        HStack(spacing: 9) {
            AppMark(size: 17)
            Text("Usage").font(.system(size: 14, weight: .semibold)).tracking(-0.3)
            Spacer()
            if store.page == "Overview" {
                if store.isDemo { Text("Demo data").font(.system(size: 10)).foregroundStyle(Palette.tertiary) }
                else if let refreshed = store.lastRefresh {
                    Text("Checked \(UsageFormat.freshness(refreshed, now: store.now))")
                        .font(.system(size: 10)).foregroundStyle(Palette.tertiary)
                }
            }
            if store.page != "Overview" {
                Button("Overview") { store.page = "Overview"; store.selection = nil }
                    .buttonStyle(.plain).font(.system(size: 11)).accessibilityIdentifier("nav-overview")
            }
            Button { Task { await store.refresh() } } label: {
                if store.refreshing { ProgressView().controlSize(.mini).frame(width: 28, height: 28) }
                else { Image(systemName: "arrow.clockwise").font(.system(size: 12)).frame(width: 28, height: 28) }
            }.buttonStyle(.plain).disabled(store.refreshing).help("Refresh sources")
                .accessibilityLabel("Refresh sources").accessibilityIdentifier("refresh-sources")
            Menu {
                Button("Overview") { store.page = "Overview"; store.selection = nil }
                Button("Activity") { store.page = "Activity"; store.selection = nil }
                if !store.isDemo { Button("Connections") { store.page = "Connections"; store.selection = nil } }
                Button("Search sources…") { store.showSearch = true }
                Divider()
                ForEach(Appearance.allCases) { appearance in
                    Button(appearance.title + (store.appearance == appearance ? " ✓" : "")) { store.appearance = appearance }
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 15, weight: .medium)).frame(width: 28, height: 28)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Dashboard options").accessibilityIdentifier("compact-options")
        }.foregroundStyle(Palette.secondary).padding(.leading, 20).padding(.trailing, 12)
            .frame(height: 46).background(Palette.surface.opacity(0.78))
    }

    private var appBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                AppMark(size: 22)
                Text("Usage").font(.system(size: 18, weight: .semibold)).tracking(-0.4)
            }.padding(.leading, 24).frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 24) {
                ForEach(store.isDemo ? ["Overview", "Activity"] : ["Overview", "Activity", "Connections"], id: \.self) { page in
                    Button {
                        store.page = page
                        store.selection = nil
                    } label: {
                        Text(page).font(.system(size: 12, weight: store.page == page ? .semibold : .regular))
                            .foregroundStyle(store.page == page ? Palette.text : Palette.secondary)
                            .frame(height: 58)
                            .overlay(alignment: .bottom) {
                                if store.page == page { RoundedRectangle(cornerRadius: 2).fill(Palette.blue).frame(height: 2).padding(.horizontal, -9) }
                            }
                    }.buttonStyle(.plain).accessibilityIdentifier("nav-\(page.lowercased())")
                }
            }

            HStack(spacing: 12) {
                Button { store.showSearch = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.system(size: 12))
                        Text("Search").font(.system(size: 11))
                        Text("⌘K").font(.system(size: 10)).padding(.horizontal, 4).padding(.vertical, 2).background(Palette.track.opacity(0.65)).clipShape(RoundedRectangle(cornerRadius: 3))
                    }.foregroundStyle(Palette.secondary).padding(.horizontal, 10).frame(height: 29)
                        .background(Palette.inset).clipShape(RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain).accessibilityLabel("Search sources").accessibilityIdentifier("search-sources")
                Menu {
                    ForEach(Appearance.allCases) { appearance in
                        Button { store.appearance = appearance } label: {
                            Label(appearance.title + (store.appearance == appearance ? " ✓" : ""), systemImage: appearance.symbol)
                        }.accessibilityIdentifier("theme-\(appearance.rawValue)")
                    }
                } label: {
                    Image(systemName: colorScheme == .dark ? "moon" : "sun.max").font(.system(size: 15)).foregroundStyle(Palette.secondary).frame(width: 28, height: 30)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Appearance").accessibilityLabel("Appearance").accessibilityIdentifier("appearance-menu")
            }.frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 26)
        }
        .frame(height: 58)
        .background(Palette.surface.opacity(0.78))
    }

    private var pageHeading: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 7) {
                Text(store.page).font(.system(size: 26, weight: .semibold)).tracking(-0.65)
                Text(store.page == "Overview" ? "All your accounts and machines." : (store.page == "Connections" ? "Independent accounts. Read-only usage." : "The latest across your workspace."))
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary)
            }
            Spacer()
            HStack(spacing: 12) {
                if store.page == "Connections" && !store.isDemo && !store.failures.isEmpty {
                    Button { store.page = "Connections"; store.selection = nil } label: {
                        SoftBadge(text: "\(store.failures.count) unavailable", symbol: "exclamationmark.circle", warning: true)
                    }.buttonStyle(.plain)
                } else if store.isDemo { SoftBadge(text: "Demo data", symbol: "circle.dotted") }
                Button {
                    if store.isDemo { store.showAddSource = true }
                    else if store.page == "Connections" { store.showNewConnection() }
                    else { store.page = "Connections"; store.selection = nil }
                } label: {
                    Label(store.isDemo ? "Add source" : (store.page == "Connections" ? "Add account" : "Connections"), systemImage: "plus")
                }.buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("add-source")
            }
        }
    }

    private var filters: some View {
        HStack {
            HStack(spacing: 7) {
                filterButton(title: "All", category: nil, symbol: "square.grid.2x2")
                ForEach(SourceCategory.allCases) { category in
                    filterButton(title: category.title, category: category, symbol: category.symbol)
                }
            }
            Spacer()
            Button { Task { await store.refresh() } } label: {
                HStack(spacing: 6) {
                    if store.refreshing { ProgressView().controlSize(.mini).frame(width: 12, height: 12) }
                    else { Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .medium)) }
                    Text(store.refreshing ? "Refreshing…" : "\(store.isDemo ? "Updated" : "Checked") \(UsageFormat.freshness(store.lastRefresh ?? .now, now: store.now))")
                        .font(.system(size: 11))
                }.foregroundStyle(Palette.secondary)
            }.buttonStyle(.plain).disabled(store.refreshing).accessibilityLabel("Refresh sources").accessibilityIdentifier("refresh-sources")
        }
    }

    private func filterButton(title: String, category: SourceCategory?, symbol: String) -> some View {
        let active = store.selectedCategory == category
        return Button { store.selectedCategory = category; store.selection = nil } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 10, weight: .medium))
                Text(title).font(.system(size: 12, weight: active ? .medium : .regular))
            }
            .foregroundStyle(active ? .white : Palette.secondary)
            .padding(.horizontal, 13).frame(height: 28)
            .background(active ? Color(hex: 0x287AF5) : Palette.surface)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(active ? .clear : Palette.border))
        }.buttonStyle(.plain).accessibilityIdentifier("filter-\(title.lowercased())")
    }

    @ViewBuilder
    private func dashboard(width: CGFloat) -> some View {
        let visible = store.filteredSources.filter(\.hasOverviewReading)
        let daytona = visible.filter { $0.integration == .daytona }
        let modal = visible.filter { $0.integration == .modal }
        let openai = visible.filter { $0.integration == .openaiAPI }
        let storage = visible.filter { $0.storage != nil }
        ForEach(IntegrationID.allCases.filter { provider in visible.contains { $0.integration == provider && $0.quota != nil } }) { provider in
            CodexCard(sources: visible.filter { $0.integration == provider }, store: store)
        }
        let topCount = [!daytona.isEmpty, !modal.isEmpty, !openai.isEmpty].filter { $0 }.count
        if topCount > 0 {
            let columns = min(topCount, width >= 1060 ? 3 : 2)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: columns), alignment: .leading, spacing: 16) {
                if !daytona.isEmpty { DaytonaCard(sources: daytona, store: store) }
                if !modal.isEmpty { ModalCard(sources: modal, store: store) }
                if !openai.isEmpty { OpenAICard(sources: openai, store: store) }
            }
        }
        if !storage.isEmpty { StorageCard(sources: storage, store: store) }
        if visible.isEmpty {
            ContentUnavailableView("Connect a source", systemImage: "square.grid.2x2", description: Text("Manage your accounts in Connections."))
        }
    }

    private var footer: some View {
        HStack(spacing: 5) {
            Image(systemName: "info.circle").font(.system(size: 10))
            Text("Agent accounts show remaining quota; other meters show usage. Account limits stay separate.")
            Spacer()
            Text("\(store.filteredSources.filter(\.hasOverviewReading).count) sources shown")
            Text("·").padding(.horizontal, 4)
            Text(store.isDemo ? "Sample data" : "Read-only · Auto refresh")
        }.font(.system(size: 10)).foregroundStyle(Palette.tertiary).padding(.top, 1)
    }

    private var failureBanner: some View {
        HStack {
            Label(store.failures.compactMap(\.error).joined(separator: " "), systemImage: "wifi.exclamationmark")
            Spacer()
            Button("Retry") { Task { await store.refresh() } }.buttonStyle(.plain).foregroundStyle(Palette.blue)
        }.font(.system(size: 12)).padding(14).background(Palette.inset).clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.small)
            Text("Gathering your workspace…").font(.system(size: 13)).foregroundStyle(Palette.secondary)
        }.frame(maxWidth: .infinity).frame(height: 450)
    }
}
