import AppKit
import SwiftUI

enum WeeklyProgressReaderMode: String, CaseIterable {
    case slides = "Slides"
    case report = "Research report"
}

struct WeeklyProgressReaderView: View {
    let generation: WeeklyProgressGeneration
    var initialMode: WeeklyProgressReaderMode = .slides
    var initialSlide: Int = 0
    let onClose: () -> Void

    @AppStorage("ut.uiScale") private var uiScale = 1.0
    @State private var mode: WeeklyProgressReaderMode
    @State private var selectedSlide = 0
    @State private var reportText: String?
    @State private var reportError: String?

    init(
        generation: WeeklyProgressGeneration,
        initialMode: WeeklyProgressReaderMode = .slides,
        initialSlide: Int = 0,
        onClose: @escaping () -> Void
    ) {
        self.generation = generation
        self.initialMode = initialMode
        self.initialSlide = initialSlide
        self.onClose = onClose
        _mode = State(initialValue: initialMode)
        _selectedSlide = State(initialValue: max(0, initialSlide))
    }

    private func cf(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * uiScale, weight: weight)
    }

    private var slideURLs: [URL] {
        WeeklyProgressSlideCatalog.urls(for: generation)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.border)
            if mode == .slides {
                slidesReader
            } else {
                reportReader
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.appBackground)
        .task(id: generation.manifest.id) { loadReport() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(cf(12.5, .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
            .help("Back to Weekly Progress")

            VStack(alignment: .leading, spacing: 1) {
                Text(generation.manifest.project.name)
                    .font(cf(16.5, .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(weekRange(generation.manifest.week))
                    .font(cf(10.5))
                    .foregroundStyle(Theme.textTertiary)
            }

            Spacer()

            modeControl

            Menu {
                Button("Open PowerPoint") { openDeck() }
                Button("Show Files in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([generation.directory])
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(cf(14))
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
        }
        .padding(.horizontal, 18)
        .padding(.top, 27)
        .padding(.bottom, 11)
    }

    private var modeControl: some View {
        HStack(spacing: 2) {
            ForEach(WeeklyProgressReaderMode.allCases, id: \.self) { item in
                Button {
                    mode = item
                } label: {
                    Text(item.rawValue)
                        .font(cf(10.5, mode == item ? .semibold : .medium))
                        .foregroundStyle(mode == item ? Theme.textPrimary : Theme.textTertiary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(mode == item ? Theme.selection : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .frame(width: 230)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface.opacity(0.7)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 1))
    }

    @ViewBuilder
    private var slidesReader: some View {
        if slideURLs.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "rectangle.stack.badge.exclamationmark")
                    .font(cf(28, .light))
                    .foregroundStyle(Theme.textTertiary)
                Text("No rendered slides were found")
                    .font(cf(14, .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Button("Show Files in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([generation.directory])
                }
                .buttonStyle(.plain)
                .font(cf(11.5, .medium))
                .foregroundStyle(Theme.accent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 0) {
                filmstrip
                    .frame(width: 178)
                Divider().overlay(Theme.border)
                slideCanvas
            }
        }
    }

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 11) {
                    ForEach(Array(slideURLs.enumerated()), id: \.offset) { index, url in
                        Button {
                            selectedSlide = index
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                WeeklyProgressLocalImage(url: url)
                                    .aspectRatio(16 / 9, contentMode: .fit)
                                    .background(Color.black.opacity(0.12))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4)
                                            .strokeBorder(
                                                selectedSlide == index ? Theme.accent : Theme.border,
                                                lineWidth: selectedSlide == index ? 2 : 1
                                            )
                                    )
                                Text("\(index + 1)")
                                    .font(cf(9.5, .medium))
                                    .foregroundStyle(selectedSlide == index ? Theme.accent : Theme.textTertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        .id(index)
                    }
                }
                .padding(13)
            }
            .background(Theme.sidebarBackground.opacity(0.55))
            .onChange(of: selectedSlide) { value in
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(value, anchor: .center) }
            }
        }
    }

    private var slideCanvas: some View {
        VStack(spacing: 0) {
            ZStack {
                Theme.appBackground
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.black.opacity(Theme.current.isLight ? 0.06 : 0.16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(Theme.border, lineWidth: 1)
                    )
                    .padding(22)
                if slideURLs.indices.contains(selectedSlide) {
                    WeeklyProgressLocalImage(url: slideURLs[selectedSlide])
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .padding(34)
                        .shadow(color: Color.black.opacity(0.18), radius: 14, y: 6)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 12) {
                Button { selectedSlide = max(0, selectedSlide - 1) } label: {
                    Image(systemName: "chevron.left").frame(width: 28, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedSlide > 0 ? Theme.textSecondary : Theme.textTertiary.opacity(0.3))
                .disabled(selectedSlide == 0)

                Text("Slide \(min(selectedSlide + 1, slideURLs.count)) of \(slideURLs.count)")
                    .font(cf(10.8, .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .monospacedDigit()

                Button { selectedSlide = min(slideURLs.count - 1, selectedSlide + 1) } label: {
                    Image(systemName: "chevron.right").frame(width: 28, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedSlide + 1 < slideURLs.count ? Theme.textSecondary : Theme.textTertiary.opacity(0.3))
                .disabled(selectedSlide + 1 >= slideURLs.count)
            }
            .padding(.bottom, 13)
        }
    }

    @ViewBuilder
    private var reportReader: some View {
        if let reportText {
            MarkdownPreviewView(
                markdown: reportText,
                fontSize: 13 * uiScale,
                layout: .artifact
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let reportError {
            VStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(cf(27, .light))
                    .foregroundStyle(Theme.textTertiary)
                Text(reportError)
                    .font(cf(12))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func loadReport() {
        let url = generation.directory.appendingPathComponent("research-report.md")
        do {
            reportText = try String(contentsOf: url, encoding: .utf8)
            reportError = nil
        } catch {
            reportText = nil
            reportError = "The research report could not be read."
        }
    }

    private func openDeck() {
        let url = generation.directory.appendingPathComponent("weekly-progress.pptx")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.open(url)
    }

    private func weekRange(_ week: WeeklyProgressWeek) -> String {
        let end = Calendar.current.date(byAdding: .day, value: -1, to: week.endExclusive)
            ?? week.endExclusive
        let startFormatter = DateFormatter(); startFormatter.dateFormat = "MMM d"
        let endFormatter = DateFormatter(); endFormatter.dateFormat = "MMM d, yyyy"
        return startFormatter.string(from: week.start) + " – " + endFormatter.string(from: end)
    }
}

struct WeeklyProgressLocalImage: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                Rectangle().fill(Theme.surface.opacity(0.45))
                    .overlay(ProgressView().controlSize(.mini))
            }
        }
        .task(id: url) {
            let data = await Task.detached(priority: .utility) {
                try? Data(contentsOf: url, options: [.mappedIfSafe])
            }.value
            image = data.flatMap(NSImage.init(data:))
        }
        .onDisappear { image = nil }
    }
}
