import AppKit
import PDFKit
import QuickLookUI
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
            } else if let panelKey = artifacts.selectedPanelKey {
                panelView(panelKey)
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
            LazyVStack(spacing: 0) {
                if panels.isEmpty {
                    emptyState(
                        icon: "doc.badge.plus",
                        title: "No artifacts yet",
                        detail: "Save a render, screenshot, or explicit file snapshot from a panel."
                    )
                } else {
                    ForEach(panels) { panel in
                        Button {
                            artifacts.open(panel: panel.context)
                        } label: {
                            panelRow(panel)
                        }
                        .buttonStyle(.plain)
                        Divider().overlay(Theme.border).padding(.leading, 58)
                    }
                }
            }
            .padding(.horizontal, 20)
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
            LazyVStack(spacing: 0) {
                if records.isEmpty {
                    emptyState(
                        icon: "magnifyingglass",
                        title: "No matching artifacts",
                        detail: "Search uses the saved filename."
                    )
                } else {
                    ForEach(records) { record in
                        artifactRow(record, showsPanel: true)
                        Divider().overlay(Theme.border).padding(.leading, 58)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
    }

    private func panelView(_ panelKey: String) -> some View {
        let context = artifacts.selectedPanelContext
            ?? artifacts.records.first(where: { $0.panel.key == panelKey })?.panel
        let records = ArtifactLibraryQuery.records(
            artifacts.records,
            panelKey: panelKey,
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
                    Text(context?.sessionName ?? "Panel")
                        .font(cf(20, .bold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text(panelSubtitle(context, count: artifacts.count(for: panelKey)))
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
                LazyVStack(spacing: 0) {
                    if records.isEmpty {
                        emptyState(
                            icon: artifacts.query.isEmpty ? "doc.badge.plus" : "magnifyingglass",
                            title: artifacts.query.isEmpty ? "No artifacts for this panel" : "No matching artifacts",
                            detail: artifacts.query.isEmpty
                                ? "Save a render, screenshot, or explicit file snapshot here."
                                : "Try a different filename."
                        )
                    } else {
                        ForEach(records) { record in
                            artifactRow(record, showsPanel: false)
                            Divider().overlay(Theme.border).padding(.leading, 58)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
    }

    private func panelRow(_ panel: ArtifactPanelSummary) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "terminal")
                .font(cf(14, .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(panel.context.sessionName)
                    .font(cf(14.5, .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(panel.context.machineName)
                    .font(cf(11.5)).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(panel.count) artifact\(panel.count == 1 ? "" : "s")")
                    .font(cf(12.5, .medium)).foregroundStyle(Theme.textSecondary)
                Text(relativeTime(panel.lastSavedAt))
                    .font(cf(10.5)).foregroundStyle(Theme.textTertiary)
            }
            Image(systemName: "chevron.right")
                .font(cf(10, .semibold)).foregroundStyle(Theme.textTertiary)
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 12)
        .frame(minHeight: 64)
    }

    private func artifactRow(_ record: ArtifactRecord, showsPanel: Bool) -> some View {
        Button { artifacts.open(artifact: record) } label: {
            HStack(spacing: 14) {
                Image(systemName: artifactIcon(record))
                    .font(cf(15, .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.filename)
                        .font(cf(14, .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    HStack(spacing: 5) {
                        if showsPanel {
                            Text(record.panel.sessionName).lineLimit(1)
                            Text("·")
                        }
                        Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                        Text("·")
                        Text(byteLabel(record.byteCount))
                    }
                    .font(cf(11)).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(cf(10, .semibold)).foregroundStyle(Theme.textTertiary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .frame(minHeight: 62)
        }
        .buttonStyle(.plain)
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
        return panel.machineName + " · \(count) saved artifact\(count == 1 ? "" : "s")"
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

private struct ArtifactDocumentView: View {
    let record: ArtifactRecord
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var artifacts: ArtifactStore
    @AppStorage("ut.uiScale") private var uiScale = 1.0
    @State private var zoom: CGFloat = 1
    @State private var renameShown = false
    @State private var renameText = ""
    @State private var deleteShown = false

    private func cf(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * uiScale, weight: weight)
    }

    private var liveRef: SessionRef? { state.liveRef(for: record.panel) }
    private var viewerKind: ArtifactViewerKind { ArtifactViewerKind(record) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.border)
            Group {
                switch viewerKind {
                case .image:
                    ArtifactImageView(url: artifacts.fileURL(for: record), zoom: zoom)
                case .pdf:
                    ArtifactPDFView(url: artifacts.fileURL(for: record), zoom: zoom)
                case .text:
                    ArtifactTextView(record: record, url: artifacts.fileURL(for: record), zoom: zoom)
                case .quickLook:
                    ArtifactQuickLookView(url: artifacts.fileURL(for: record))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.surface.opacity(0.25))
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
            Spacer(minLength: 16)
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
                Button("Export…") { export() }
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
        return record.panel.sessionName + " · " + record.panel.machineName + " · "
            + record.createdAt.formatted(date: .abbreviated, time: .shortened) + " · " + mode
    }

    private func compactButton(_ system: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system).font(cf(9.5, .bold))
                .foregroundStyle(Theme.textSecondary).frame(width: 21, height: 21)
        }
        .buttonStyle(.plain)
        .help(help)
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

    private func export() {
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
}

private enum ArtifactViewerKind: Equatable {
    case image
    case pdf
    case text
    case quickLook

    init(_ record: ArtifactRecord) {
        if record.isImage {
            self = .image
        } else if record.isPDF {
            self = .pdf
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
    @State private var text: String?
    @State private var error: String?

    var body: some View {
        Group {
            if let text {
                CodeMirrorView(
                    text: text,
                    filename: record.filename,
                    path: url.path,
                    fontSize: 13 * zoom,
                    editable: false,
                    scrollToLine: nil,
                    onChange: { _ in }
                )
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
}

private struct ArtifactQuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? URL) != url { view.previewItem = url as NSURL }
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
