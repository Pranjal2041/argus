import SwiftUI
import UIKit

// Weekly Progress: the Mac's weekly research reviews (slides, report, PPTX),
// browsed and started from the phone. The Mac app is the provider; any broker
// that answers `/weekly-progress/catalog` can relay it (in practice the Mac's).

@MainActor
final class WeeklyProgressStore: ObservableObject {
    static let hostKey = "argus.weeklyProgress.host"

    @Published private(set) var catalog: WeeklyProgressCatalog
    /// The last catalog request reached a provider.
    @Published private(set) var providerAvailable = false
    @Published private(set) var refreshing = false
    /// At least one refresh has finished this launch (distinguishes "loading" from "empty").
    @Published private(set) var loadedOnce = false
    @Published private(set) var actionBusy = false
    /// Connectivity state; replaced by every refresh.
    @Published private(set) var connectionMessage: String?
    /// The outcome of the last generate/resume; stays until dismissed.
    @Published var actionMessage: String?

    // Screen selection survives navigating away and back.
    @Published var selectedProjectID: String?
    @Published var selectedWeek = WeeklyProgressWeek.currentKey()
    @Published var calendarMode = false

    let cache: WeeklyProgressCache
    private let defaults: UserDefaults
    private var requestIDs: WeeklyProgressRequestIDs { WeeklyProgressRequestIDs(defaults: defaults) }
    private weak var fleet: FleetStore?
    private var loop: Task<Void, Never>?
    private var visibleCount = 0
    private var refreshInFlight = false
    private var forceQueued = false
    private var lastRefreshAt: Date?
    private var lastCatalogSaveAt: Date?
    private var lastPruneAt: Date?
    private var hostID: String?
    private let images = NSCache<NSString, UIImage>()
    private var imageLoads: [String: Task<UIImage?, Never>] = [:]

    init(cache: WeeklyProgressCache = .standard, defaults: UserDefaults = .standard) {
        self.cache = cache
        self.defaults = defaults
        hostID = defaults.string(forKey: Self.hostKey)
        catalog = cache.loadCatalog() ?? WeeklyProgressCatalog()
        images.totalCostLimit = 96 * 1024 * 1024
    }

    func start(fleet: FleetStore) {
        guard loop == nil else { return }
        self.fleet = fleet
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    /// Poll only while someone is looking, or while a review is running (so
    /// the banner and cards are current the moment the screen opens).
    private func tick() async {
        guard UIApplication.shared.applicationState != .background else { return }
        if visibleCount > 0 || catalog.activeOperation != nil { await refresh() }
    }

    func setVisible(_ visible: Bool) {
        visibleCount = max(0, visibleCount + (visible ? 1 : -1))
    }

    // MARK: Provider

    /// The broker that last served the catalog, else the Mac sync host.
    var host: Machine? {
        guard let fleet else { return nil }
        return fleet.machines.first { $0.id == hostID } ?? fleet.syncHost
    }

    /// Macs, plus the last proven provider even before its OS is known; the
    /// preferred host first.
    private var candidates: [Machine] {
        guard let fleet else { return [] }
        let preferred = host?.id
        return fleet.machines
            .filter { $0.os == "darwin" || $0.id == hostID }
            .sorted { ($0.id == preferred ? 0 : 1) < ($1.id == preferred ? 0 : 1) }
    }

    // MARK: Catalog

    /// Throttled to 15 s when idle and 2 s while a review runs, unless forced.
    func refresh(force: Bool = false) async {
        if refreshInFlight {
            if force { forceQueued = true }
            return
        }
        let interval: TimeInterval = catalog.activeOperation == nil ? 15 : 2
        if !force, let last = lastRefreshAt, Date().timeIntervalSince(last) < interval { return }
        let candidates = self.candidates
        guard !candidates.isEmpty else {
            providerAvailable = false
            if catalog.projects.isEmpty { connectionMessage = WeeklyProgressMessages.brokerUnavailable }
            loadedOnce = fleet?.machines.isEmpty == false
            return
        }
        refreshInFlight = true
        refreshing = true
        lastRefreshAt = Date()
        var answer: (Machine, WeeklyProgressCatalog, Data)?
        for m in candidates {
            if case let (catalog, raw)? = await WeeklyProgressAPI.catalog(m) { answer = (m, catalog, raw); break }
        }
        if case let (m, fresh, raw)? = answer {
            if hostID != m.id { hostID = m.id; defaults.set(m.id, forKey: Self.hostKey) }
            if fresh != catalog { catalog = fresh }
            providerAvailable = true
            connectionMessage = nil
            if selectedProjectID.map({ id in !fresh.projects.contains { $0.id == id } }) == true {
                selectedProjectID = nil
                calendarMode = false
            }
            persist(raw)
        } else {
            providerAvailable = false
            connectionMessage = catalog.projects.isEmpty ? WeeklyProgressMessages.providerMissing : WeeklyProgressMessages.showingSaved
        }
        refreshInFlight = false
        refreshing = false
        loadedOnce = true
        if forceQueued {
            forceQueued = false
            await refresh(force: true)
        }
    }

    /// At most every 30 s; pruning at most every 12 h.
    private func persist(_ raw: Data) {
        let now = Date()
        if let last = lastCatalogSaveAt, now.timeIntervalSince(last) < 30 { return }
        lastCatalogSaveAt = now
        let prune = lastPruneAt.map { now.timeIntervalSince($0) > 12 * 3600 } ?? true
        if prune { lastPruneAt = now }
        let cache = self.cache
        Task.detached(priority: .utility) {
            cache.saveCatalog(raw)
            if prune { cache.prune(now: now) }
        }
    }

    // MARK: Commands

    func generate(projectID: String, week: String) async {
        await run(.generate(projectID: projectID, week: week), resume: false) { host, id in
            await WeeklyProgressAPI.generate(host, projectID: projectID, week: week, requestID: id)
        }
    }

    func resume(_ generation: WeeklyProgressGeneration) async {
        await run(.resume(generationID: generation.id), resume: true) { host, id in
            await WeeklyProgressAPI.resume(host, generationID: generation.id, requestID: id)
        }
    }

    private func run(_ action: WeeklyProgressRequestIDs.Action, resume: Bool,
                     send: (Machine, String) async -> WeeklyProgressAPI.Reply) async {
        guard !actionBusy else { return }
        guard let host else {
            actionMessage = WeeklyProgressMessages.brokerUnavailable
            return
        }
        let requestID = requestIDs.id(for: action)
        actionBusy = true
        actionMessage = nil
        let reply = await send(host, requestID)
        actionBusy = false
        requestIDs.settle(action, status: reply.status)
        if reply.ok {
            try? await Task.sleep(nanoseconds: 250_000_000)
        } else {
            actionMessage = WeeklyProgressMessages.commandFailure(resume: resume, status: reply.status, serverError: reply.error)
        }
        await refresh(force: true)
    }

    var canStartWork: Bool { providerAvailable && !actionBusy && catalog.activeOperation == nil }

    // MARK: Assets

    /// Slide `number` (1-based): memory, then disk, then the provider.
    /// Thumbnails are downsampled for the card grid.
    func slide(_ generation: WeeklyProgressGeneration, _ number: Int, thumbnail: Bool = false) async -> UIImage? {
        let key = "\(generation.id)/\(generation.assetRevision)/\(number)/\(thumbnail ? "t" : "f")"
        if let image = images.object(forKey: key as NSString) { return image }
        if let pending = imageLoads[key] { return await pending.value }
        let file = cache.slideFile(generation, number)
        let cache = self.cache
        let host = self.host
        let task = Task<UIImage?, Never> {
            var data = await Task.detached(priority: .userInitiated) { cache.read(file) }.value
            if data == nil, let host, let fetched = try? await WeeklyProgressAPI.slide(host, generationID: generation.id, number: number) {
                data = fetched
                Task.detached(priority: .utility) { cache.write(fetched, to: file, replacingSiblingRevisions: true) }
            }
            guard let data else { return nil }
            return await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let image = UIImage(data: data) else { return nil }
                if thumbnail { return await image.byPreparingThumbnail(ofSize: CGSize(width: 960, height: 540)) ?? image }
                return await image.byPreparingForDisplay() ?? image
            }.value
        }
        imageLoads[key] = task
        let image = await task.value
        imageLoads[key] = nil
        if let image {
            images.setObject(image, forKey: key as NSString,
                             cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4))
        }
        return image
    }

    /// The research report, network first; `cached` is true when the Mac
    /// could not be reached and a saved copy is shown.
    func report(_ generation: WeeklyProgressGeneration) async -> (text: String, cached: Bool)? {
        let file = cache.reportFile(generation.id)
        let cache = self.cache
        if let host, let text = try? await WeeklyProgressAPI.report(host, generationID: generation.id) {
            Task.detached(priority: .utility) { cache.write(Data(text.utf8), to: file) }
            return (text, false)
        }
        let saved = await Task.detached { cache.read(file) }.value
        return saved.map { (String(decoding: $0, as: UTF8.self), true) }
    }

    /// The deck as a local `.pptx` (cached per revision), for QuickLook/sharing.
    func deck(_ generation: WeeklyProgressGeneration, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let target = cache.deckFile(generation)
        if FileManager.default.fileExists(atPath: target.path) { return target }
        guard let host else { throw BrokerError.http("The Mac must be reachable to download this PowerPoint.") }
        let temporary = try await WeeklyProgressAPI.downloadDeck(host, generationID: generation.id, progress: progress)
        try cache.move(temporary, to: target)
        return target
    }
}

// MARK: Screen

struct WeeklyProgressView: View {
    @EnvironmentObject var fleet: FleetStore
    @EnvironmentObject var store: WeeklyProgressStore
    @State private var confirmGenerate = false
    @State private var reading: WeeklyProgressGeneration?
    @State private var reportFor: WeeklyProgressGeneration?
    @State private var deckPreview: ShareItem?
    @State private var deckProgress: Double?
    @State private var localMessage: String?

    private var catalog: WeeklyProgressCatalog { store.catalog }
    private var project: WeeklyProgressProject? { catalog.projects.first { $0.id == store.selectedProjectID } }

    var body: some View {
        VStack(spacing: 0) {
            controls
            banners
            content
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Weekly Progress")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await store.refresh(force: true) } } label: {
                    if store.refreshing { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }
                .accessibilityLabel("Refresh")
            }
        }
        .onAppear {
            store.setVisible(true)
            Task { await store.refresh(force: true) }
        }
        .onDisappear { store.setVisible(false) }
        .confirmationDialog("Create another version?", isPresented: $confirmGenerate, titleVisibility: .visible) {
            Button("Generate version") { generate() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This week already has a review. The existing version will remain available.")
        }
        .fullScreenCover(item: $reading) { g in
            WeeklyProgressSlideReader(generation: g).environmentObject(store)
        }
        .sheet(item: $reportFor) { g in WeeklyProgressReportReader(generation: g).environmentObject(store) }
        .sheet(item: $deckPreview) { item in WeeklyProgressDeckPreview(url: item.url) }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                projectPicker
                if project != nil {
                    Picker("View", selection: $store.calendarMode) {
                        Image(systemName: "calendar").tag(false).accessibilityLabel("Selected week")
                        Image(systemName: "clock.arrow.circlepath").tag(true).accessibilityLabel("Calendar")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 104)
                }
            }
            if !store.calendarMode || project == nil { weekSelector }
            HStack {
                if let project {
                    Text(store.calendarMode ? "Every week, newest first" : project.sourceSummary)
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(catalog.projects.count == 1 ? "1 project" : "\(catalog.projects.count) projects")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if project != nil && !store.calendarMode { generateButton }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var projectPicker: some View {
        Menu {
            Button { store.selectedProjectID = nil; store.calendarMode = false } label: {
                Label { Text("All projects"); Text("One shelf for the selected week") } icon: { check(store.selectedProjectID == nil) }
            }
            Divider()
            ForEach(catalog.projects) { p in
                Button { store.selectedProjectID = p.id } label: {
                    Label { Text(p.name); Text(p.sourceSummary) } icon: { check(store.selectedProjectID == p.id) }
                }
            }
        } label: {
            HStack {
                Text(project?.name ?? "All projects").font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
        }
        .accessibilityLabel("Project")
    }

    @ViewBuilder private func check(_ on: Bool) -> some View {
        if on { Image(systemName: "checkmark") }
    }

    private var weekSelector: some View {
        let current = WeeklyProgressWeek.currentKey()
        return HStack {
            Button { store.selectedWeek = WeeklyProgressWeek.shift(store.selectedWeek, by: -1) } label: {
                Image(systemName: "chevron.left").frame(width: 34, height: 30)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Previous week")
            VStack(spacing: 1) {
                Text(WeeklyProgressWeek.rangeTitle(store.selectedWeek)).font(.subheadline.weight(.semibold))
                if store.selectedWeek == current {
                    Text("This week · Monday through Sunday").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Button("Jump to this week") { store.selectedWeek = current }.font(.caption2)
                }
            }
            .frame(maxWidth: .infinity)
            Button { store.selectedWeek = WeeklyProgressWeek.shift(store.selectedWeek, by: 1) } label: {
                Image(systemName: "chevron.right").frame(width: 34, height: 30)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Next week")
        }
    }

    private var generateButton: some View {
        Button {
            let existing = WeeklyProgressShelf.project(catalog.generations, projectID: store.selectedProjectID ?? "", week: store.selectedWeek)
            if existing.isEmpty { generate() } else { confirmGenerate = true }
        } label: {
            HStack(spacing: 5) {
                if store.actionBusy { ProgressView().controlSize(.mini) } else { Image(systemName: "play.fill") }
                Text("Generate")
            }
            .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.borderedProminent)
        .disabled(!store.canStartWork)
    }

    private func generate() {
        guard let id = store.selectedProjectID else { return }
        let week = store.selectedWeek
        Task { await store.generate(projectID: id, week: week) }
    }

    // MARK: Banners

    @ViewBuilder private var banners: some View {
        if let message = localMessage ?? store.actionMessage ?? store.connectionMessage {
            let dismissable = localMessage != nil || store.actionMessage != nil
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: store.providerAvailable ? "info.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(store.providerAvailable ? Color.accentColor : .orange)
                Text(message).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                if dismissable {
                    Button("Dismiss") { localMessage = nil; store.actionMessage = nil }.font(.footnote)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(store.providerAvailable ? Color(.secondarySystemGroupedBackground) : Color.orange.opacity(0.12))
        }
        if let deckProgress {
            VStack(alignment: .leading, spacing: 4) {
                Text("Downloading PowerPoint…").font(.caption).foregroundStyle(.secondary)
                if deckProgress >= 0 { ProgressView(value: deckProgress) } else { ProgressView().progressViewStyle(.linear) }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
        if let op = catalog.activeOperation { WeeklyProgressActiveBanner(operation: op) }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if catalog.projects.isEmpty {
            if !store.loadedOnce || (store.refreshing && !store.providerAvailable) {
                VStack(spacing: 10) { ProgressView(); Text("Loading reviews from your Mac").font(.footnote).foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                scroll {
                    empty("No Weekly Progress projects", "Create a project in Argus on your Mac. It will appear here automatically.")
                }
            }
        } else if let project, store.calendarMode {
            let sections = WeeklyProgressShelf.calendar(catalog.generations, projectID: project.id)
            scroll {
                if sections.isEmpty {
                    empty("No reviews yet", "Generate the first review from the selected week.")
                }
                ForEach(sections) { section in
                    Button {
                        store.selectedWeek = section.week
                        store.calendarMode = false
                    } label: {
                        HStack(alignment: .lastTextBaseline) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(WeeklyProgressWeek.rangeTitle(section.week)).font(.headline).foregroundStyle(.primary)
                                Text("Week of \(section.week)").font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(WeeklyProgressShelf.versionLabel(section.versions.count)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 6)
                    ForEach(section.versions) { g in card(g, versions: section.versions.count) }
                }
            }
        } else {
            let entries = project.map { WeeklyProgressShelf.project(catalog.generations, projectID: $0.id, week: store.selectedWeek) }
                ?? WeeklyProgressShelf.allProjects(catalog.generations, week: store.selectedWeek)
            scroll {
                if entries.isEmpty {
                    if project == nil {
                        empty("No reviews this week", "Choose a project to create its review.")
                    } else {
                        empty("Nothing generated for this week", "Generate a research review when you are ready.")
                    }
                }
                ForEach(entries) { g in
                    card(g, versions: catalog.generations.filter { $0.projectID == g.projectID && $0.weekStart == g.weekStart }.count)
                }
            }
        }
    }

    private func scroll<C: View>(@ViewBuilder _ body: () -> C) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) { body() }
                .padding(16)
        }
        .refreshable { await store.refresh(force: true) }
    }

    private func empty(_ title: String, _ body: String) -> some View {
        ContentUnavailableView(title, systemImage: "rectangle.on.rectangle.angled", description: Text(body))
            .padding(.top, 40)
    }

    private func card(_ g: WeeklyProgressGeneration, versions: Int) -> some View {
        WeeklyProgressCard(
            generation: g, versions: versions, canResume: store.canStartWork,
            onRead: { reading = g }, onReport: { reportFor = g }, onDeck: { openDeck(g) },
            onResume: { Task { await store.resume(g) } }
        )
    }

    private func openDeck(_ g: WeeklyProgressGeneration) {
        guard deckProgress == nil else { return }
        deckProgress = -1
        Task {
            do {
                let url = try await store.deck(g) { value in Task { @MainActor in deckProgress = value } }
                deckProgress = nil
                deckPreview = ShareItem(url: url)
            } catch {
                deckProgress = nil
                localMessage = error.localizedDescription
            }
        }
    }
}

// MARK: Pieces

private struct WeeklyProgressActiveBanner: View {
    let operation: WeeklyProgressActiveOperation

    var body: some View {
        let index = WeeklyProgressStage.index(operation.stage)
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(operation.projectName).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                Text(WeeklyProgressStage.title(operation.stage)).font(.caption).foregroundStyle(Color.accentColor)
            }
            HStack(spacing: 5) {
                ForEach(0..<WeeklyProgressStage.steps.count, id: \.self) { i in
                    Capsule().fill(i <= index ? Color.accentColor : Color(.tertiarySystemFill)).frame(height: 3)
                }
            }
            HStack(spacing: 4) {
                Text("Week of \(operation.weekStart)")
                if let started = WeeklyProgressTime.parse(operation.startedAt) {
                    Text("· started"); Text(started, style: .relative); Text("ago")
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.09))
        .accessibilityElement(children: .combine)
    }
}

private struct WeeklyProgressCard: View {
    @EnvironmentObject var store: WeeklyProgressStore
    let generation: WeeklyProgressGeneration
    let versions: Int
    let canResume: Bool
    let onRead: () -> Void
    let onReport: () -> Void
    let onDeck: () -> Void
    let onResume: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onRead) { cover }
                .buttonStyle(.plain)
                .disabled(generation.slideCount == 0)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(generation.projectName).font(.headline).lineLimit(2)
                        Text("\(WeeklyProgressWeek.rangeTitle(generation.weekStart)) · \(WeeklyProgressShelf.versionLabel(versions))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if generation.slideCount > 0 {
                        Text("\(generation.slideCount) slides").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error = generation.error {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
                }
                HStack(spacing: 14) {
                    if generation.slideCount > 0 { Button(action: onRead) { Label("Read", systemImage: "play.rectangle") } }
                    if generation.hasReport { Button(action: onReport) { Label("Report", systemImage: "book") } }
                    if generation.hasDeck { Button(action: onDeck) { Label("PPTX", systemImage: "arrow.down.doc") } }
                    Spacer()
                    if generation.canResume {
                        Button("Resume", action: onResume).buttonStyle(.bordered).disabled(!canResume)
                    }
                }
                .font(.subheadline)
            }
            .padding(12)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(.separator).opacity(0.5), lineWidth: 0.5))
        .contextMenu {
            if generation.slideCount > 0 { Button(action: onRead) { Label("Read slides", systemImage: "play.rectangle") } }
            if generation.hasReport { Button(action: onReport) { Label("Research report", systemImage: "book") } }
            if generation.hasDeck { Button(action: onDeck) { Label("PowerPoint", systemImage: "arrow.down.doc") } }
            Button { UIPasteboard.general.string = generation.id } label: { Label("Copy review ID", systemImage: "doc.on.doc") }
        }
    }

    private var cover: some View {
        ZStack(alignment: .topTrailing) {
            Color(.tertiarySystemFill)
            if generation.slideCount > 0 {
                WeeklyProgressSlideImage(generation: generation, number: 1, thumbnail: true)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "rectangle.on.rectangle.angled").font(.title2).foregroundStyle(.tertiary)
                    Text(WeeklyProgressStage.title(generation.stage)).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text(WeeklyProgressStage.stateTitle(generation.state))
                .font(.caption2.weight(.bold)).foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(stateColor.opacity(0.92), in: UnevenRoundedRectangle(bottomLeadingRadius: 8))
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipped()
        .accessibilityLabel("\(generation.projectName) cover slide")
    }

    private var stateColor: Color {
        switch generation.state {
        case "active": return .blue
        case "complete": return .green
        case "failed": return .red
        case "interrupted": return .orange
        default: return .gray
        }
    }
}

/// A slide from the store's cache; reloads when the generation's revision changes.
struct WeeklyProgressSlideImage: View {
    @EnvironmentObject var store: WeeklyProgressStore
    let generation: WeeklyProgressGeneration
    let number: Int
    var thumbnail = false
    var onLoad: ((UIImage) -> Void)?
    @State private var image: UIImage?
    @State private var attempted = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else if !attempted {
                ProgressView()
            } else {
                Image(systemName: "photo").foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(generation.id)/\(generation.assetRevision)/\(number)/\(store.providerAvailable)") {
            if image != nil && !store.providerAvailable { return }
            if let loaded = await store.slide(generation, number, thumbnail: thumbnail) {
                image = loaded
                onLoad?(loaded)
            }
            attempted = true
        }
    }
}
