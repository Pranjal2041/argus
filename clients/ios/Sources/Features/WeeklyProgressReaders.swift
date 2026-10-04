import SwiftUI
import UIKit

// Full-screen slide reader, research-report reader and PowerPoint preview.

struct WeeklyProgressSlideReader: View {
    @EnvironmentObject var store: WeeklyProgressStore
    @Environment(\.dismiss) private var dismiss
    let generation: WeeklyProgressGeneration
    @State private var page = 1
    @State private var images: [Int: UIImage] = [:]
    @State private var showReport = false
    @State private var deck: ShareItem?
    @State private var downloading = false
    @State private var message: String?

    private var count: Int { max(generation.slideCount, 1) }

    var body: some View {
        NavigationStack {
            TabView(selection: $page) {
                ForEach(1...count, id: \.self) { n in
                    WeeklyProgressSlidePage(generation: generation, number: n) { images[n] = $0 }.tag(n)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .background(Color.black.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) { pager }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar { toolbar }
            .onChange(of: page) { _, n in prefetch(around: n) }
            .onAppear { prefetch(around: page) }
            .alert("PowerPoint", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(message ?? "") }
            .sheet(isPresented: $showReport) { WeeklyProgressReportReader(generation: generation) }
            .sheet(item: $deck) { WeeklyProgressDeckPreview(url: $0.url) }
        }
        .preferredColorScheme(.dark)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("Close")
        }
        ToolbarItem(placement: .principal) {
            VStack(spacing: 0) {
                Text(generation.projectName).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("\(page) of \(count)").font(.caption2).foregroundStyle(.secondary)
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if let image = images[page] {
                ShareLink(item: Image(uiImage: image),
                          preview: SharePreview("\(generation.projectName) — slide \(page)", image: Image(uiImage: image))) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share slide")
            }
            if generation.hasReport || generation.hasDeck {
                Menu {
                    if generation.hasReport {
                        Button { showReport = true } label: { Label("Research report", systemImage: "book") }
                    }
                    if generation.hasDeck {
                        Button { openDeck() } label: { Label("PowerPoint", systemImage: "arrow.down.doc") }
                    }
                } label: {
                    if downloading { ProgressView() } else { Image(systemName: "ellipsis.circle") }
                }
            }
        }
    }

    private var pager: some View {
        HStack {
            Button { withAnimation { page = max(1, page - 1) } } label: {
                Label("Previous", systemImage: "chevron.left").labelStyle(.iconOnly).frame(width: 44, height: 32)
            }
            .disabled(page <= 1)
            Spacer()
            VStack(spacing: 1) {
                Text("\(page) / \(count)").font(.footnote.weight(.semibold).monospacedDigit())
                Text("Swipe · pinch or double-tap to zoom").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button { withAnimation { page = min(count, page + 1) } } label: {
                Label("Next", systemImage: "chevron.right").labelStyle(.iconOnly).frame(width: 44, height: 32)
            }
            .disabled(page >= count)
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.bar)
    }

    private func prefetch(around n: Int) {
        for neighbor in [n + 1, n - 1] where (1...count).contains(neighbor) {
            Task { _ = await store.slide(generation, neighbor) }
        }
    }

    private func openDeck() {
        guard !downloading else { return }
        downloading = true
        Task {
            defer { downloading = false }
            do { deck = ShareItem(url: try await store.deck(generation) { _ in }) } catch { message = error.localizedDescription }
        }
    }
}

private struct WeeklyProgressSlidePage: View {
    @EnvironmentObject var store: WeeklyProgressStore
    let generation: WeeklyProgressGeneration
    let number: Int
    let onLoad: (UIImage) -> Void
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                WeeklyProgressZoomableImage(image: image).accessibilityLabel("Slide \(number)")
            } else if failed {
                ContentUnavailableView("Slide unavailable", systemImage: "photo",
                                       description: Text("Reconnect to the Mac and try again."))
            } else {
                ProgressView()
            }
        }
        .task(id: "\(generation.id)/\(generation.assetRevision)/\(number)") {
            if let loaded = await store.slide(generation, number) {
                image = loaded
                onLoad(loaded)
            } else {
                failed = true
            }
        }
    }
}

/// Pinch/double-tap zoom with UIScrollView, so a fitted slide leaves
/// one-finger horizontal swipes to the surrounding pager.
struct WeeklyProgressZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> SlideScrollView {
        let view = SlideScrollView()
        view.delegate = context.coordinator
        view.minimumZoomScale = 1
        view.maximumZoomScale = 5
        view.showsVerticalScrollIndicator = false
        view.showsHorizontalScrollIndicator = false
        view.contentInsetAdjustmentBehavior = .never
        view.imageView.image = image
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)
        return view
    }

    func updateUIView(_ view: SlideScrollView, context: Context) {
        if view.imageView.image !== image { view.imageView.image = image }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class SlideScrollView: UIScrollView {
        let imageView: UIImageView = {
            let v = UIImageView()
            v.contentMode = .scaleAspectFit
            return v
        }()

        override init(frame: CGRect) {
            super.init(frame: frame)
            addSubview(imageView)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func layoutSubviews() {
            super.layoutSubviews()
            if zoomScale == 1, imageView.frame.size != bounds.size {
                imageView.frame = CGRect(origin: .zero, size: bounds.size)
                contentSize = bounds.size
            }
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { (scrollView as? SlideScrollView)?.imageView }

        @objc func doubleTapped(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? SlideScrollView else { return }
            if view.zoomScale > 1 {
                view.setZoomScale(1, animated: true)
            } else {
                let point = gesture.location(in: view.imageView)
                let scale: CGFloat = 2.5
                let size = CGSize(width: view.bounds.width / scale, height: view.bounds.height / scale)
                view.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                     width: size.width, height: size.height), animated: true)
            }
        }
    }
}

// MARK: Report

struct WeeklyProgressReportReader: View {
    @EnvironmentObject var store: WeeklyProgressStore
    @Environment(\.dismiss) private var dismiss
    let generation: WeeklyProgressGeneration
    @State private var loaded = false
    @State private var text: String?
    @State private var cached = false

    var body: some View {
        NavigationStack {
            Group {
                if !loaded {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let text {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if cached {
                                Label("Offline copy — the Mac could not be reached.", systemImage: "icloud.slash")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                            WeeklyProgressMarkdownView(text: text)
                        }
                        .padding(.horizontal, 18).padding(.vertical, 16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .refreshable { await load() }
                } else {
                    ContentUnavailableView("Report unavailable", systemImage: "book.closed",
                                           description: Text("Reconnect to the Mac and try again."))
                }
            }
            .navigationTitle(generation.projectName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(generation.projectName).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text("Research report · week of \(generation.weekStart)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    if let text { ShareLink(item: text) { Image(systemName: "square.and.arrow.up") } }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        let result = await store.report(generation)
        text = result?.text
        cached = result?.cached ?? false
        loaded = true
    }
}

// MARK: Markdown

/// A small block-level Markdown reader for research reports: headings,
/// paragraphs, lists, quotes, fenced code, tables and rules. Inline syntax
/// (emphasis, code, links) is rendered by Foundation's AttributedString.
enum WeeklyProgressMarkdown {
    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet(indent: Int, text: String)
        case numbered(indent: Int, marker: String, text: String)
        case quote(String)
        case code(String)
        case table([[String]])
        case rule
    }

    static func blocks(_ source: String) -> [Block] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
        }
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let fence = String(trimmed.prefix(3))
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    body.append(lines[i]); i += 1
                }
                blocks.append(.code(body.joined(separator: "\n")))
                i += 1
                continue
            }
            if trimmed.isEmpty { flush(); i += 1; continue }
            if let heading = heading(trimmed) { flush(); blocks.append(heading); i += 1; continue }
            if isRule(trimmed) { flush(); blocks.append(.rule); i += 1; continue }
            if trimmed.hasPrefix(">") {
                flush()
                var quoted: [String] = []
                while i < lines.count, case let t = lines[i].trimmingCharacters(in: .whitespaces), t.hasPrefix(">") {
                    quoted.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces)); i += 1
                }
                blocks.append(.quote(quoted.joined(separator: " ")))
                continue
            }
            if trimmed.hasPrefix("|") {
                flush()
                var rows: [[String]] = []
                while i < lines.count, case let t = lines[i].trimmingCharacters(in: .whitespaces), t.hasPrefix("|") {
                    let cells = cellsOf(t)
                    if !cells.allSatisfy(isAlignmentCell) { rows.append(cells) }
                    i += 1
                }
                blocks.append(.table(rows))
                continue
            }
            if let item = listItem(trimmed, indent: indent) { flush(); blocks.append(item); i += 1; continue }
            // A lazy continuation of the previous list item.
            if paragraph.isEmpty, indent >= 2, let last = blocks.last {
                switch last {
                case let .bullet(level, text):
                    blocks[blocks.count - 1] = .bullet(indent: level, text: text + " " + trimmed); i += 1; continue
                case let .numbered(level, marker, text):
                    blocks[blocks.count - 1] = .numbered(indent: level, marker: marker, text: text + " " + trimmed); i += 1; continue
                default: break
                }
            }
            paragraph.append(trimmed)
            i += 1
        }
        flush()
        return blocks
    }

    private static func heading(_ s: String) -> Block? {
        let hashes = s.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = s.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return .heading(level: hashes, text: text.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ s: String) -> Bool {
        let compact = s.filter { $0 != " " }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func listItem(_ s: String, indent: Int) -> Block? {
        let level = indent / 2
        if let first = s.first, "-*+".contains(first), s.dropFirst().first == " " {
            return .bullet(indent: level, text: String(s.dropFirst(2)).trimmingCharacters(in: .whitespaces))
        }
        let digits = s.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let after = s.dropFirst(digits.count)
        guard let delimiter = after.first, delimiter == "." || delimiter == ")", after.dropFirst().first == " " else { return nil }
        return .numbered(indent: level, marker: String(digits) + ".", text: String(after.dropFirst(2)).trimmingCharacters(in: .whitespaces))
    }

    private static func cellsOf(_ row: String) -> [String] {
        var body = Substring(row)
        if body.hasPrefix("|") { body = body.dropFirst() }
        if body.hasSuffix("|") { body = body.dropLast() }
        return body.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isAlignmentCell(_ cell: String) -> Bool {
        !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" } && cell.contains("-")
    }

    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

struct WeeklyProgressMarkdownView: View {
    let text: String

    var body: some View {
        let blocks = WeeklyProgressMarkdown.blocks(text)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in view(for: block) }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder private func view(for block: WeeklyProgressMarkdown.Block) -> some View {
        switch block {
        case let .heading(level, text):
            Text(WeeklyProgressMarkdown.inline(text))
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : level == 3 ? .headline : .subheadline.bold())
                .padding(.top, level <= 2 ? 8 : 4)
        case let .paragraph(text):
            Text(WeeklyProgressMarkdown.inline(text)).font(.body)
        case let .bullet(indent, text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(indent == 0 ? "•" : "◦").foregroundStyle(.secondary)
                Text(WeeklyProgressMarkdown.inline(text))
            }
            .padding(.leading, CGFloat(indent) * 16)
        case let .numbered(indent, marker, text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).monospacedDigit().foregroundStyle(.secondary)
                Text(WeeklyProgressMarkdown.inline(text))
            }
            .padding(.leading, CGFloat(indent) * 16)
        case let .quote(text):
            Text(WeeklyProgressMarkdown.inline(text)).italic().foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(Color(.separator)).frame(width: 3) }
        case let .code(text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text).font(.system(.footnote, design: .monospaced)).padding(10)
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        case let .table(rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(WeeklyProgressMarkdown.inline(cell))
                                    .font(index == 0 ? .footnote.bold() : .footnote)
                                    .frame(maxWidth: 260, alignment: .leading)
                            }
                        }
                        if index == 0 { Divider() }
                    }
                }
                .padding(10)
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }
}

// MARK: PowerPoint

/// QuickLook renders .pptx natively; Share saves to Files, Keynote, PowerPoint, AirDrop…
struct WeeklyProgressDeckPreview: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL

    var body: some View {
        NavigationStack {
            QuickLookView(url: url)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(url.lastPathComponent)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                    }
                }
        }
    }
}
