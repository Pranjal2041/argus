import AppKit
import PDFKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// A deliberately small library: panel-backed captures, the artifacts for one
/// panel, and the artifact itself. Opening files elsewhere in Argus never feeds
/// this view; only explicit Render PDFs, opted-in foreground screenshots, and
/// files explicitly added from Files do.
struct ArtifactsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var artifacts: ArtifactStore
    @AppStorage("ut.uiScale") private var uiScale = 1.0

    private func cf(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * uiScale, weight: weight)
    }

    var body: some View {
        Group {
            if let artifact = artifacts.selectedArtifact {
                ArtifactDocumentView(record: artifact)
                    .id(artifact.id)
            } else if let panel = artifacts.selectedPanelContext {
                panelView(panel)
            } else {
                libraryView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.appBackground)
        .alert("Artifacts", isPresented: Binding(
            get: { artifacts.errorMessage != nil },
            set: { if !$0 { artifacts.errorMessage = nil } }
        )) {
            Button("OK") { artifacts.errorMessage = nil }
        } message: {
            Text(artifacts.errorMessage ?? "The operation could not be completed.")
        }
    }

    private var libraryView: some View {
        VStack(spacing: 0) {
            libraryHeader
            Divider().overlay(Theme.border)
            if artifacts.isLoading && artifacts.records.isEmpty {
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            } else if artifacts.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                panelList
            } else {
                searchResults
            }
        }
    }

    private var libraryHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "archivebox")
                .font(cf(19, .semibold))
                .foregroundStyle(Theme.textSecondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Artifacts").font(cf(20, .bold)).foregroundStyle(Theme.textPrimary)
                Text("Renders, screenshots, and saved files, grouped by panel")
                    .font(cf(11.5)).foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 12)
            if !artifacts.loadIssues.isEmpty {
                Button {
                    artifacts.errorMessage = "\(artifacts.loadIssues.count) saved artifact\(artifacts.loadIssues.count == 1 ? "" : "s") could not be loaded. The affected files remain untouched on disk."
                } label: {
                    Label("\(artifacts.loadIssues.count) unavailable", systemImage: "exclamationmark.triangle.fill")
                        .font(cf(11.5, .medium))
                        .foregroundStyle(Theme.waiting)
                }
                .buttonStyle(.plain)
            }
            searchField("Search filenames")
            sortMenu
            Button { state.showArtifacts = false } label: {
                Image(systemName: "xmark").font(cf(14, .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
            .help("Close Artifacts")
        }
        .padding(.horizontal, 20)
        .padding(.top, 30)
        .padding(.bottom, 13)
    }

    private var panelList: some View {
        let panels = ArtifactLibraryQuery.panels(artifacts.records, sort: artifacts.sortOrder)
        return ScrollView {
            LazyVGrid(columns: galleryColumns, alignment: .leading, spacing: 16) {
                if panels.isEmpty {
                    emptyState(
                        icon: "doc.badge.plus",
                        title: "No artifacts yet",
                        detail: "Save a render, screenshot, or explicit file snapshot from a panel."
                    )
                    .gridCellColumns(3)
                }
                if !panels.isEmpty {
                    artifactSectionHeader("PANEL CAPTURES", count: panels.count, icon: "rectangle.stack")
                    ForEach(panels) { panel in
                        Button {
                            artifacts.open(panel: panel.context)
                        } label: {
                            panelCard(panel)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
    }

    private var searchResults: some View {
        let records = ArtifactLibraryQuery.records(
            artifacts.records,
            filenameQuery: artifacts.query,
            sort: artifacts.sortOrder
        )
        return ScrollView {
            LazyVGrid(columns: galleryColumns, alignment: .leading, spacing: 16) {
                if records.isEmpty {
                    emptyState(
                        icon: "magnifyingglass",
                        title: "No matching artifacts",
                        detail: "Search uses the saved filename."
                    )
                    .gridCellColumns(3)
                }
                if !records.isEmpty {
                    artifactSectionHeader("SAVED FILES", count: records.count, icon: "doc")
                    ForEach(records) { record in
                        artifactCard(record, showsPanel: true)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
    }

    private func panelView(_ context: ArtifactPanelContext) -> some View {
        let records = ArtifactLibraryQuery.records(
            artifacts.records,
            panel: context,
            filenameQuery: artifacts.query,
            sort: artifacts.sortOrder
        )
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { artifacts.openLibrary() } label: {
                    Image(systemName: "chevron.left").font(cf(13, .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
                .help("All panels")
                VStack(alignment: .leading, spacing: 1) {
                    Text(context.sessionName)
                        .font(cf(20, .bold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text(panelSubtitle(context, count: artifacts.count(for: context)))
                        .font(cf(11.5)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                .frame(maxWidth: 230, alignment: .leading)
                Spacer(minLength: 10)
                searchField("Search this panel")
                sortMenu
                Button { state.showArtifacts = false } label: {
                    Image(systemName: "xmark").font(cf(14, .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
                .help("Close Artifacts")
            }
            .padding(.horizontal, 20)
            .padding(.top, 30)
            .padding(.bottom, 13)
            Divider().overlay(Theme.border)
            ScrollView {
                LazyVGrid(columns: galleryColumns, alignment: .leading, spacing: 16) {
                    if records.isEmpty {
                        emptyState(
                            icon: artifacts.query.isEmpty ? "doc.badge.plus" : "magnifyingglass",
                            title: artifacts.query.isEmpty ? "No artifacts for this panel" : "No matching artifacts",
                            detail: artifacts.query.isEmpty
                                ? "Save a render, screenshot, or explicit file snapshot here."
                                : "Try a different filename."
                    )
                        .gridCellColumns(3)
                    }
                    if !records.isEmpty {
                        artifactSectionHeader("SAVED FILES", count: records.count, icon: "doc")
                        ForEach(records) { record in
                            artifactCard(record, showsPanel: false)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 24)
            }
        }
    }

    private var galleryColumns: [GridItem] {
        [GridItem(.adaptive(
            minimum: max(176, 206 * uiScale),
            maximum: max(250, 310 * uiScale)
        ), spacing: 16)]
    }

    private func panelCard(_ panel: ArtifactPanelSummary) -> some View {
        let previews = Array(ArtifactLibraryQuery.records(
            artifacts.records,
            panel: panel.context,
            sort: .newest
        ).prefix(3))
        return VStack(alignment: .leading, spacing: 0) {
            ArtifactPanelContactSheet(records: previews, store: artifacts)
                .frame(maxWidth: .infinity)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipped()
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(panel.context.sessionName)
                        .font(cf(14, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(panel.count)")
                        .font(cf(10.5, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Theme.surface))
                }
                Text(panelLocation(panel.context))
                    .font(cf(10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Updated " + relativeTime(panel.lastSavedAt))
                    .font(cf(10))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(12)
        }
        .contentShape(Rectangle())
        .modifier(ArtifactGalleryCardSurface())
        .help("Open artifacts for \(panel.context.sessionName)")
    }

    private func artifactCard(_ record: ArtifactRecord, showsPanel: Bool) -> some View {
        Button { artifacts.open(artifact: record) } label: {
            VStack(alignment: .leading, spacing: 0) {
                ArtifactThumbnailView(record: record, url: artifacts.fileURL(for: record))
                    .frame(maxWidth: .infinity)
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .clipped()
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.filename)
                        .font(cf(12.5, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if showsPanel {
                        Text(record.panel.sessionName)
                            .font(cf(10.5, .medium))
                            .foregroundStyle(Theme.accent)
                            .lineLimit(1)
                    }
                    Text(record.createdAt.formatted(date: .abbreviated, time: .shortened)
                         + " · " + byteLabel(record.byteCount))
                        .font(cf(10))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(11)
            }
            .contentShape(Rectangle())
            .modifier(ArtifactGalleryCardSurface())
        }
        .buttonStyle(.plain)
        .help("Open \(record.filename)")
    }

    private func artifactSectionHeader(_ title: String, count: Int, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(cf(10.5, .semibold))
                .foregroundStyle(Theme.accent)
            Text(title)
                .font(cf(10.5, .bold))
                .tracking(1.2)
                .foregroundStyle(Theme.textSecondary)
            Text("\(count)")
                .font(cf(10, .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.textTertiary)
            Rectangle().fill(Theme.border).frame(height: 1)
        }
        .padding(.top, 4)
        .gridCellColumns(3)
    }

    private func searchField(_ prompt: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(cf(10.5)).foregroundStyle(Theme.textTertiary)
            TextField(prompt, text: $artifacts.query)
                .textFieldStyle(.plain)
                .font(cf(12.5))
                .foregroundStyle(Theme.textPrimary)
            if !artifacts.query.isEmpty {
                Button { artifacts.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(cf(10.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 9)
        .frame(minWidth: 150, idealWidth: 220, maxWidth: 260, minHeight: 29, maxHeight: 29)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border, lineWidth: 1))
        )
    }

    private var sortMenu: some View {
        Menu {
            ForEach(ArtifactSortOrder.allCases) { order in
                Button {
                    artifacts.sortOrder = order
                } label: {
                    if artifacts.sortOrder == order {
                        Label(order.title, systemImage: "checkmark")
                    } else {
                        Text(order.title)
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(cf(11, .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.surface))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(artifacts.sortOrder.title)
    }

    private func emptyState(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 9) {
            Image(systemName: icon).font(cf(25)).foregroundStyle(Theme.textTertiary)
            Text(title).font(cf(15, .semibold)).foregroundStyle(Theme.textSecondary)
            Text(detail).font(cf(12)).foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90)
    }

    private func panelSubtitle(_ panel: ArtifactPanelContext?, count: Int) -> String {
        guard let panel else { return "\(count) saved artifact\(count == 1 ? "" : "s")" }
        return panelLocation(panel) + " · \(count) saved artifact\(count == 1 ? "" : "s")"
    }

    private func panelLocation(_ panel: ArtifactPanelContext) -> String {
        let folder = panel.folder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folder.isEmpty else { return panel.machineName }
        return panel.machineName + " · " + folder
    }

    private func artifactIcon(_ record: ArtifactRecord) -> String {
        if record.isImage { return "photo" }
        if record.isPDF { return "doc.richtext" }
        return iconForFile(record.filename)
    }

    private func relativeTime(_ date: Date) -> String {
        if abs(date.timeIntervalSinceNow) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func byteLabel(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

/// A restrained contact-sheet surface: visual enough to scan, but still part
/// of Argus rather than a second file manager. Hover only lifts the card; it
/// never moves the surrounding grid.
private struct ArtifactGalleryCardSurface: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        hovering ? Theme.accent.opacity(0.62) : Theme.border,
                        lineWidth: hovering ? 1.25 : 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(
                color: Color.black.opacity(hovering ? 0.20 : 0.07),
                radius: hovering ? 12 : 4,
                x: 0,
                y: hovering ? 5 : 2
            )
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.14), value: hovering)
    }
}

private struct ArtifactPanelContactSheet: View {
    let records: [ArtifactRecord]
    let store: ArtifactStore

    var body: some View {
        GeometryReader { proxy in
            if records.isEmpty {
                ZStack {
                    Theme.surface
                    Image(systemName: "terminal")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
            } else {
                HStack(spacing: 2) {
                    ForEach(records) { record in
                        ArtifactThumbnailView(
                            record: record,
                            url: store.fileURL(for: record),
                            showsTypeBadge: false
                        )
                        .frame(
                            width: max(1, (proxy.size.width - CGFloat(records.count - 1) * 2)
                                / CGFloat(records.count)),
                            height: proxy.size.height
                        )
                    }
                }
            }
        }
        .background(Theme.surface)
    }
}

private struct ArtifactThumbnailView: View {
    let record: ArtifactRecord
    let url: URL
    var showsTypeBadge = true
    @State private var image: NSImage?
    @State private var finished = false

    private var loadKey: String {
        url.path + "|" + String(Int(record.byteCount))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Theme.surface
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(record.isPDF ? 9 : 0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if finished {
                VStack(spacing: 7) {
                    Image(systemName: fallbackIcon)
                        .font(.system(size: 24, weight: .light))
                    Text(record.fileExtension.uppercased())
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(0.7)
                }
                .foregroundStyle(Theme.textTertiary)
            } else {
                ProgressView().controlSize(.mini)
            }

            if showsTypeBadge {
                Text(typeLabel)
                    .font(.system(size: 8.5, weight: .bold))
                    .tracking(0.55)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(8)
            }
        }
        .task(id: loadKey) {
            image = await ArtifactThumbnailLoader.shared.image(for: url)
            finished = true
        }
    }

    private var typeLabel: String {
        let ext = record.fileExtension.uppercased()
        if !ext.isEmpty { return ext }
        return record.isImage ? "IMAGE" : record.isPDF ? "PDF" : "FILE"
    }

    private var fallbackIcon: String {
        if record.isImage { return "photo" }
        if record.isPDF { return "doc.richtext" }
        return iconForFile(record.filename)
    }
}

private actor ArtifactThumbnailLoader {
    static let shared = ArtifactThumbnailLoader()
    private let cache: NSCache<NSString, NSImage>

    private init() {
        cache = NSCache<NSString, NSImage>()
        cache.countLimit = 180
        cache.totalCostLimit = 128 * 1024 * 1024
    }

    func image(for url: URL) async -> NSImage? {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 520, height: 390),
            scale: 2,
            representationTypes: .thumbnail
        )
        let image: NSImage? = await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation?.nsImage)
            }
        }
        if let image {
            let cost = max(1, Int(image.size.width * image.size.height * 4))
            cache.setObject(image, forKey: key, cost: cost)
        }
        return image
    }
}

private struct ArtifactDocumentView: View {
    let record: ArtifactRecord
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var artifacts: ArtifactStore
    @AppStorage("ut.uiScale") private var uiScale = 1.0
    @State private var zoom: CGFloat = 1
    @State private var renameShown = false
    @State private var renameText = ""
    @State private var deleteShown = false
    @State private var markdownMode = ArtifactMarkdownMode.read
    @State private var markdownPDFData: Data?
    @State private var markdownPDFError: String?
    @State private var generatingMarkdownPDF = false
    @State private var exportingMarkdown = false
    @StateObject private var markdownPreview = MarkdownPreviewProxy()

    private func cf(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * uiScale, weight: weight)
    }

    private var liveRef: SessionRef? { state.liveRef(for: record.panel) }
    private var viewerKind: ArtifactViewerKind { ArtifactViewerKind(record) }
    private var galleryRecords: [ArtifactRecord] {
        ArtifactLibraryQuery.records(
            artifacts.records,
            panel: record.panel,
            sort: artifacts.sortOrder
        )
    }
    private var galleryIndex: Int? { galleryRecords.firstIndex { $0.id == record.id } }
    private var previousRecord: ArtifactRecord? {
        guard let galleryIndex, galleryIndex > 0 else { return nil }
        return galleryRecords[galleryIndex - 1]
    }
    private var nextRecord: ArtifactRecord? {
        guard let galleryIndex, galleryIndex + 1 < galleryRecords.count else { return nil }
        return galleryRecords[galleryIndex + 1]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.border)
            ZStack {
                Group {
                    switch viewerKind {
                    case .image:
                        ArtifactImageView(url: artifacts.fileURL(for: record), zoom: zoom)
                    case .pdf:
                        ArtifactPDFView(url: artifacts.fileURL(for: record), zoom: zoom)
                    case .markdown:
                        ArtifactTextView(
                            record: record,
                            url: artifacts.fileURL(for: record),
                            zoom: zoom,
                            markdownMode: markdownMode,
                            markdownProxy: markdownPreview,
                            markdownPDFData: markdownPDFData,
                            markdownPDFError: markdownPDFError,
                            generatingMarkdownPDF: generatingMarkdownPDF,
                            onRetryPDF: generateMarkdownPDFIfPossible
                        )
                    case .text:
                        ArtifactTextView(record: record, url: artifacts.fileURL(for: record), zoom: zoom)
                    case .quickLook:
                        QuickLookFileView(url: artifacts.fileURL(for: record))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.surface.opacity(0.25))

                if galleryRecords.count > 1 {
                    HStack {
                        edgeNavigationButton(
                            systemImage: "chevron.left",
                            record: previousRecord,
                            help: "Previous artifact",
                            shortcut: .leftArrow
                        )
                        Spacer()
                        edgeNavigationButton(
                            systemImage: "chevron.right",
                            record: nextRecord,
                            help: "Next artifact",
                            shortcut: .rightArrow
                        )
                    }
                    .padding(.horizontal, 16)
                    .allowsHitTesting(true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if galleryRecords.count > 1 {
                Divider().overlay(Theme.border)
                filmstrip
            }
        }
        .background(Theme.appBackground)
        .alert("Rename Artifact", isPresented: $renameShown) {
            TextField("Filename", text: $renameText)
            Button("Rename") { rename() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This changes the name shown in Artifacts; the saved file stays intact.")
        }
        .confirmationDialog(
            "Delete “\(record.filename)”?",
            isPresented: $deleteShown,
            titleVisibility: .visible
        ) {
            Button("Delete Artifact", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the file from the local artifact library.")
        }
        .onChange(of: markdownPreview.isReady) { ready in
            if ready && markdownMode == .pages {
                generateMarkdownPDFIfPossible()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                artifacts.selectedArtifactID = nil
            } label: {
                Image(systemName: "chevron.left").font(cf(13, .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
            .help("Back to \(record.panel.sessionName)")
            VStack(alignment: .leading, spacing: 1) {
                Text(record.filename)
                    .font(cf(15, .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(documentSubtitle)
                    .font(cf(10.5)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                if let sourcePath = record.sourcePath {
                    Text(sourcePath)
                        .font(cf(9.5)).monospaced()
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(sourcePath)
                }
            }
            .frame(minWidth: 100, idealWidth: 230, maxWidth: 340, alignment: .leading)
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                if viewerKind == .markdown {
                    markdownModeControl
                    markdownExportMenu
                    if exportingMarkdown || generatingMarkdownPDF {
                        ProgressView().controlSize(.mini)
                            .help(generatingMarkdownPDF ? "Preparing pages" : "Saving a copy")
                    }
                }
                if viewerKind.supportsZoom {
                    HStack(spacing: 2) {
                        compactButton("minus", help: "Zoom out") { zoom = max(0.45, zoom - 0.1) }
                        Text("\(Int((zoom * 100).rounded()))%")
                            .font(cf(10.5, .medium)).monospacedDigit()
                            .foregroundStyle(Theme.textSecondary).frame(width: 40)
                        compactButton("plus", help: "Zoom in") { zoom = min(3, zoom + 0.1) }
                    }
                }
                if let liveRef {
                    Button("Open Panel") {
                        state.selection = liveRef
                        state.showArtifacts = false
                    }
                    .font(cf(11.5, .medium))
                    .buttonStyle(.borderless)
                }
                Menu {
                    Button("Rename…") {
                        renameText = record.filename
                        renameShown = true
                    }
                    if viewerKind != .markdown {
                        Button("Export…") { exportOriginal() }
                    }
                    Divider()
                    Button("Delete Artifact", role: .destructive) { deleteShown = true }
                } label: {
                    Image(systemName: "ellipsis.circle").font(cf(12.5))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Artifact actions")
                Button { state.showArtifacts = false } label: {
                    Image(systemName: "xmark").font(cf(14, .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
                .help("Close Artifacts")
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(2)
        }
        .padding(.horizontal, 18)
        .padding(.top, 30)
        .padding(.bottom, 10)
    }

    private var documentSubtitle: String {
        let mode: String
        if record.presentation == "file-draft" {
            mode = "Draft snapshot"
        } else if record.isFileSnapshot {
            mode = "File snapshot"
        } else if record.isImage {
            mode = "Screenshot"
        } else {
            mode = record.presentation == "terminal" ? "Terminal" : "Rendered"
        }
        let position = galleryIndex.map { " · \($0 + 1) of \(galleryRecords.count)" } ?? ""
        return record.panel.sessionName + " · " + record.panel.machineName + " · "
            + record.createdAt.formatted(date: .abbreviated, time: .shortened) + " · " + mode + position
    }

    private func edgeNavigationButton(
        systemImage: String,
        record target: ArtifactRecord?,
        help: String,
        shortcut: KeyEquivalent
    ) -> some View {
        Button {
            if let target { artifacts.open(artifact: target) }
        } label: {
            Image(systemName: systemImage)
                .font(cf(13, .bold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 36, height: 48)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Theme.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(target == nil)
        .opacity(target == nil ? 0 : 0.92)
        .keyboardShortcut(shortcut, modifiers: [])
        .help(help + " (←/→)")
    }

    private var filmstrip: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(galleryRecords) { item in
                        Button { artifacts.open(artifact: item) } label: {
                            ArtifactThumbnailView(
                                record: item,
                                url: artifacts.fileURL(for: item),
                                showsTypeBadge: false
                            )
                            .frame(width: 68, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(
                                        item.id == record.id ? Theme.accent : Theme.border,
                                        lineWidth: item.id == record.id ? 2 : 1
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .id(item.id)
                        .help(item.filename)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }
            .frame(height: 66)
            .background(Theme.appBackground)
            .onAppear {
                reader.scrollTo(record.id, anchor: .center)
            }
            .onChange(of: record.id) { id in
                withAnimation(.easeOut(duration: 0.16)) {
                    reader.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    private func compactButton(_ system: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system).font(cf(9.5, .bold))
                .foregroundStyle(Theme.textSecondary).frame(width: 21, height: 21)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var markdownExportMenu: some View {
        Menu {
            Button("Save PDF…") { exportMarkdownPDF() }
                .disabled(exportingMarkdown || generatingMarkdownPDF || !markdownPreview.isReady)
            Button("Save EPUB…") { exportMarkdownEPUB() }
                .disabled(exportingMarkdown)
            Divider()
            Button("Save original Markdown…") { exportOriginal() }
                .disabled(exportingMarkdown)
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(cf(12, .medium))
                .frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Save a copy outside Argus")
    }

    private var markdownModeControl: some View {
        HStack(spacing: 0) {
            ForEach(ArtifactMarkdownMode.allCases, id: \.self) { mode in
                Button {
                    selectMarkdownMode(mode)
                } label: {
                    Text(mode.title)
                        .font(cf(10.5, markdownMode == mode ? .semibold : .regular))
                        .foregroundStyle(markdownMode == mode ? Theme.accent : Theme.textSecondary)
                        .frame(width: 61, height: 23)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(markdownMode == mode ? Theme.accent.opacity(0.14) : .clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.surface))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
        .help("Reader reflows like EPUB; Pages opens the generated PDF directly in Argus")
    }

    private func selectMarkdownMode(_ mode: ArtifactMarkdownMode) {
        markdownMode = mode
        if mode == .pages {
            generateMarkdownPDFIfPossible()
        }
    }

    private func generateMarkdownPDFIfPossible() {
        guard markdownPDFData == nil,
              !generatingMarkdownPDF,
              markdownPreview.isReady
        else { return }
        generatingMarkdownPDF = true
        markdownPDFError = nil
        markdownPreview.createPDF { result in
            switch result {
            case .success(let data):
                markdownPDFData = data
            case .failure(let error):
                markdownPDFError = error.localizedDescription
            }
            generatingMarkdownPDF = false
        }
    }

    private func rename() {
        Task {
            do {
                _ = try await artifacts.rename(record, to: renameText)
            } catch {
                artifacts.errorMessage = error.localizedDescription
            }
        }
    }

    private func delete() {
        Task {
            do {
                try await artifacts.delete(record)
            } catch {
                artifacts.errorMessage = error.localizedDescription
            }
        }
    }

    private func exportOriginal() {
        let source = artifacts.fileURL(for: record)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = record.filename
        if let type = UTType(filenameExtension: record.fileExtension), !record.fileExtension.isEmpty {
            panel.allowedContentTypes = [type]
        } else {
            panel.allowedContentTypes = [.data]
        }
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            Task.detached(priority: .utility) {
                do {
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    try FileManager.default.copyItem(at: source, to: destination)
                } catch {
                    await MainActor.run { artifacts.errorMessage = error.localizedDescription }
                }
            }
        }
    }

    private func exportMarkdownPDF() {
        let panel = exportPanel(fileExtension: "pdf")
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            exportingMarkdown = true
            if let markdownPDFData {
                savePDFData(markdownPDFData, to: destination)
                return
            }
            markdownPreview.createPDF { result in
                switch result {
                case .failure(let error):
                    artifacts.errorMessage = error.localizedDescription
                    exportingMarkdown = false
                case .success(let data):
                    savePDFData(data, to: destination)
                }
            }
        }
    }

    private func savePDFData(_ data: Data, to destination: URL) {
        Task {
            do {
                try await Task.detached(priority: .utility) {
                    try data.write(to: destination, options: .atomic)
                }.value
            } catch {
                artifacts.errorMessage = error.localizedDescription
            }
            exportingMarkdown = false
        }
    }

    private func exportMarkdownEPUB() {
        let panel = exportPanel(fileExtension: "epub")
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            exportingMarkdown = true
            Task {
                do {
                    try await MarkdownEPUBExporter.export(
                        sourceURL: artifacts.fileURL(for: record),
                        destinationURL: destination,
                        title: MarkdownEPUBExporter.suggestedTitle(for: record.filename)
                    )
                } catch {
                    artifacts.errorMessage = error.localizedDescription
                }
                exportingMarkdown = false
            }
        }
    }

    private func exportPanel(fileExtension: String) -> NSSavePanel {
        let panel = NSSavePanel()
        let base = (record.filename as NSString).deletingPathExtension
        panel.nameFieldStringValue = ArtifactFilename.normalized(base, fileExtension: fileExtension)
        panel.allowedContentTypes = [UTType(filenameExtension: fileExtension) ?? .data]
        panel.canCreateDirectories = true
        return panel
    }
}

private enum ArtifactMarkdownMode: String, CaseIterable, Hashable {
    case read
    case pages
    case source

    var title: String {
        switch self {
        case .read: return "Reader"
        case .pages: return "Pages"
        case .source: return "Source"
        }
    }
}

private enum ArtifactViewerKind: Equatable {
    case image
    case pdf
    case markdown
    case text
    case quickLook

    init(_ record: ArtifactRecord) {
        if record.isImage {
            self = .image
        } else if record.isPDF {
            self = .pdf
        } else if record.isMarkdown {
            self = .markdown
        } else if record.contentType?.lowercased().hasPrefix("text/") == true
                    || Self.textExtensions.contains(record.fileExtension)
                    || UTType(filenameExtension: record.fileExtension)?.conforms(to: .text) == true {
            self = .text
        } else {
            self = .quickLook
        }
    }

    var supportsZoom: Bool { self != .quickLook }

    private static let textExtensions: Set<String> = [
        "c", "cc", "cpp", "css", "csv", "go", "h", "hpp", "html", "ini", "java", "js", "json",
        "jsx", "kt", "log", "lua", "md", "mjs", "plist", "properties", "py", "rb", "rs", "sh",
        "sql", "swift", "toml", "ts", "tsx", "txt", "xml", "yaml", "yml"
    ]
}

private struct ArtifactTextView: View {
    let record: ArtifactRecord
    let url: URL
    let zoom: CGFloat
    var markdownMode: ArtifactMarkdownMode? = nil
    var markdownProxy: MarkdownPreviewProxy? = nil
    var markdownPDFData: Data? = nil
    var markdownPDFError: String? = nil
    var generatingMarkdownPDF = false
    var onRetryPDF: () -> Void = {}
    @State private var text: String?
    @State private var error: String?

    var body: some View {
        Group {
            if let text {
                if let markdownMode {
                    ZStack {
                        MarkdownPreviewView(
                            markdown: text,
                            fontSize: 13 * zoom,
                            proxy: markdownProxy,
                            layout: .artifact
                        )
                        .opacity(markdownMode == .read ? 1 : 0)
                        .allowsHitTesting(markdownMode == .read)
                        .accessibilityHidden(markdownMode != .read)
                        if markdownMode == .pages {
                            markdownPages
                                .background(Theme.appBackground)
                        } else if markdownMode == .source {
                            sourceView(text)
                                .background(Theme.appBackground)
                        }
                    }
                } else {
                    sourceView(text)
                }
            } else if let error {
                VStack(spacing: 10) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 25, weight: .light))
                    Text(error).font(.system(size: 12)).multilineTextAlignment(.center)
                }
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: url) {
            do {
                guard record.byteCount <= 20 * 1024 * 1024 else {
                    error = "This text file is too large to preview. Use Export to open the saved copy elsewhere."
                    return
                }
                let loaded = try await Task.detached(priority: .utility) {
                    let data = try Data(contentsOf: url)
                    guard let string = String(data: data, encoding: .utf8) else {
                        throw CocoaError(.fileReadInapplicableStringEncoding)
                    }
                    return string
                }.value
                text = loaded
            } catch {
                self.error = "This saved file could not be displayed as text. Use Export to open it elsewhere."
            }
        }
    }

    private func sourceView(_ text: String) -> some View {
        CodeMirrorView(
            text: text,
            filename: record.filename,
            path: url.path,
            fontSize: 13 * zoom,
            editable: false,
            scrollToLine: nil,
            onChange: { _ in }
        )
    }

    @ViewBuilder private var markdownPages: some View {
        if let markdownPDFData {
            ArtifactPDFDataView(data: markdownPDFData, zoom: zoom)
        } else if let markdownPDFError {
            VStack(spacing: 12) {
                Image(systemName: "doc.richtext")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(Theme.textTertiary)
                Text("The PDF view could not be prepared")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Text(markdownPDFError)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button("Try Again", action: onRetryPDF)
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(generatingMarkdownPDF ? "Preparing PDF view…" : "Waiting for the reader…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ArtifactImageView: View {
    let url: URL
    let zoom: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let inset: CGFloat = 24
            let fittedWidth = max(1, proxy.size.width - inset * 2)
            let fittedHeight = max(1, proxy.size.height - inset * 2)
            let scaledWidth = fittedWidth * zoom
            let scaledHeight = fittedHeight * zoom
            ScrollView([.horizontal, .vertical]) {
                ZStack {
                    ArtifactImageContent(url: url)
                        .frame(width: scaledWidth, height: scaledHeight)
                }
                .frame(
                    width: max(proxy.size.width, scaledWidth + inset * 2),
                    height: max(proxy.size.height, scaledHeight + inset * 2)
                )
            }
        }
    }
}

private struct ArtifactImageContent: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.imageAlignment = .alignCenter
        view.animates = false
        update(view, context: context)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        update(view, context: context)
    }

    private func update(_ view: NSImageView, context: Context) {
        guard context.coordinator.loadedURL != url else { return }
        context.coordinator.loadedURL = url
        view.image = NSImage(contentsOf: url)
    }

    final class Coordinator { var loadedURL: URL? }
}

private struct ArtifactPDFDataView: NSViewRepresentable {
    let data: Data
    let zoom: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.backgroundColor = Theme.nsAppBackground
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.autoScales = true
        view.document = PDFDocument(data: data)
        context.coordinator.data = data
        DispatchQueue.main.async {
            view.autoScales = false
            view.scaleFactor = context.coordinator.widthFit(for: view) * zoom
        }
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if context.coordinator.data != data {
            context.coordinator.data = data
            view.document = PDFDocument(data: data)
            context.coordinator.fit = 0
        }
        view.scaleFactor = context.coordinator.widthFit(for: view) * zoom
    }

    final class Coordinator {
        var fit: CGFloat = 0
        var fittedViewWidth: CGFloat = 0
        var data: Data?

        func widthFit(for view: PDFView) -> CGFloat {
            let viewWidth = max(1, view.bounds.width - 40)
            if fit == 0 || abs(viewWidth - fittedViewWidth) > 1 {
                let pageWidth = view.document?.page(at: 0)?.bounds(for: .mediaBox).width ?? viewWidth
                fit = max(0.1, viewWidth / max(1, pageWidth))
                fittedViewWidth = viewWidth
            }
            return fit
        }
    }
}

private struct ArtifactPDFView: NSViewRepresentable {
    let url: URL
    let zoom: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.backgroundColor = Theme.nsAppBackground
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.autoScales = true
        view.document = PDFDocument(url: url)
        DispatchQueue.main.async {
            context.coordinator.fit = view.scaleFactorForSizeToFit
            view.autoScales = false
            view.scaleFactor = context.coordinator.fit * zoom
        }
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        let fit = context.coordinator.fit > 0 ? context.coordinator.fit : view.scaleFactorForSizeToFit
        view.scaleFactor = fit * zoom
    }

    final class Coordinator { var fit: CGFloat = 0 }
}
