import AppKit
import SwiftUI

/// Minimal / Raycast palette for the Files window (flat, sharp — not glass).
enum Flat {
    // Themed (were hardcoded near-black + periwinkle, which ignored the active theme).
    static var bg: Color       { Theme.appBackground }
    static var sidebar: Color  { Theme.sidebarBackground }
    static var hairline: Color { Theme.border }
    static var sel: Color      { Theme.accent.opacity(0.30) }
    static var accent: Color   { Theme.accent }
    static var text: Color     { Theme.textPrimary }
    static var dim: Color      { Theme.textSecondary }
    static var faint: Color    { Theme.textTertiary }
}

struct FilesView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var model: FilesModel
    @AppStorage("ut.uiScale") private var uiScale: Double = 1.0

    private var machines: [Machine] { state.machines }
    private func s(_ v: CGFloat) -> CGFloat { v * uiScale }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider().overlay(Flat.hairline)
            if let tab = model.active {
                TabPane(tab: tab).id(tab.id)
            } else {
                emptyState
            }
        }
        .background(Flat.bg)
        .frame(minWidth: 760, minHeight: 480)
        .background(quickOpenShortcut)
        .overlay { quickOpenOverlay }
        .onAppear { if model.tabs.isEmpty, let m = (machines.first { $0.isLocal } ?? machines.first) { model.addTab(m) } }
    }

    private var quickOpenShortcut: some View {
        Button("") { model.active?.openQuickOpen() }
            .keyboardShortcut("p", modifiers: .command).opacity(0).frame(width: 0, height: 0)
    }

    @ViewBuilder private var quickOpenOverlay: some View {
        if let tab = model.active, tab.showQuickOpen {
            ZStack(alignment: .top) {
                Color.black.opacity(0.18).ignoresSafeArea().onTapGesture { tab.closeQuickOpen() }
                QuickOpenView(tab: tab).padding(.top, 70)
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 64)   // clear traffic lights (hidden title bar)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) { ForEach(model.tabs) { tabChip($0) } }
            }
            addMenu
        }
        .padding(.horizontal, 10)
        .frame(height: s(42))
    }

    private func tabChip(_ t: FileTab) -> some View {
        let active = t.id == model.activeID
        return HStack(spacing: 6) {
            Image(systemName: t.isLocal ? "desktopcomputer" : "server.rack")
                .font(.system(size: s(10))).foregroundStyle(active ? Flat.accent : Flat.dim)
            Text(t.title).font(.system(size: s(12), weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Flat.text : Flat.dim).lineLimit(1)
            Button { model.closeTab(t.id) } label: {
                Image(systemName: "xmark").font(.system(size: s(8), weight: .bold))
            }.buttonStyle(.plain).foregroundStyle(Flat.faint)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(active ? Color.white.opacity(0.08) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(active ? Flat.hairline : .clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { model.activeID = t.id }
    }

    private var addMenu: some View {
        Menu {
            if machines.isEmpty { Text("No hosts discovered") }
            ForEach(machines) { m in Button(m.name) { model.addTab(m) } }
        } label: {
            Image(systemName: "plus").font(.system(size: s(12), weight: .semibold))
                .foregroundStyle(Flat.dim).frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 32)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder").font(.system(size: 30, weight: .light)).foregroundStyle(Flat.faint)
            Text("No tabs open").foregroundStyle(Flat.dim)
            if machines.isEmpty { Text("No hosts discovered.").font(.system(size: 11)).foregroundStyle(Flat.faint) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - one tab: path/breadcrumb bar + tree | content (+ op dialogs)

private struct TabPane: View {
    @ObservedObject var tab: FileTab
    @AppStorage("ut.uiScale") private var uiScale: Double = 1.0
    @State private var renameText = ""
    @State private var newName = ""
    @State private var search = ""
    private func s(_ v: CGFloat) -> CGFloat { v * uiScale }

    private var filteredRoots: [FileNode] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? tab.roots : tab.roots.filter { $0.entry.name.lowercased().contains(q) }
    }

    /// One flat row of the tree: a node at an indent depth, or a "loading…" stub shown
    /// under a directory whose children are still being fetched.
    private struct FlatRow: Identifiable {
        let node: FileNode
        let depth: Int
        let isLoading: Bool
        var id: String { isLoading ? node.entry.path + "\u{1}loading" : node.entry.path }
    }

    /// The tree flattened to exactly the rows that should be visible — a pre-order walk
    /// that descends into a directory only when it's expanded. Rendering this single list
    /// in a LazyVStack virtualizes the whole tree (only on-screen rows are built) instead
    /// of eagerly nesting every expanded subtree as one monolithic, animated view — the
    /// cause of the beachball hang on large folders.
    private var visibleRows: [FlatRow] {
        _ = tab.treeRevision   // dependency: recompute when a node expands/collapses/loads
        _ = tab.sortBy; _ = tab.sortAsc   // …and when the sort order changes
        var rows: [FlatRow] = []
        func walk(_ nodes: [FileNode], _ depth: Int) {
            for n in tab.sortNodes(nodes) {
                rows.append(FlatRow(node: n, depth: depth, isLoading: false))
                guard n.entry.isDir, n.expanded else { continue }
                if let kids = n.children {
                    walk(kids, depth + 1)
                } else if n.loading {
                    rows.append(FlatRow(node: n, depth: depth + 1, isLoading: true))
                }
            }
        }
        walk(filteredRoots, 0)
        return rows
    }

    private func loadingRow(depth: Int) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini).scaleEffect(0.6)
            Text("loading…").font(.system(size: s(10))).foregroundStyle(Flat.faint)
        }
        .padding(.leading, CGFloat(depth) * s(14) + 14).padding(.vertical, 2)
    }

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            Divider().overlay(Flat.hairline)
            if let up = tab.uploading { transferBanner("Uploading", up) }
            if let down = tab.downloading { transferBanner("Downloading", down) }
            HSplitView {
                sidebar
                FileContentView(tab: tab)
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                    .background(Flat.bg)
            }
        }
        // The op dialogs (rename/new/delete) + Get-Info sheet live in their own
        // modifiers, split in two so each stays cheap to type-check.
        .modifier(FileNameDialogs(tab: tab, renameText: $renameText, newName: $newName))
        .modifier(FileMiscDialogs(tab: tab, search: $search))
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            filterBox
            Divider().overlay(Flat.hairline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleRows) { row in
                        if row.isLoading {
                            loadingRow(depth: row.depth)
                        } else {
                            FileRow(node: row.node, tab: tab, depth: row.depth)
                        }
                    }
                }
                .padding(.vertical, 4)
                // Expand/collapse must never animate a placement pass over the list —
                // that animated nested layout was the hang on large folders.
                .transaction { $0.animation = nil }
            }
        }
        .background(Flat.sidebar)
        .frame(minWidth: 220, idealWidth: 320, maxWidth: 520)
        .contextMenu {
            Button("New Folder…") { tab.creating = NewItem(parent: tab.rootPath, isDir: true) }
            Button("New File…") { tab.creating = NewItem(parent: tab.rootPath, isDir: false) }
            Button("Upload File…") { pickAndUpload(tab, into: tab.rootPath) }
            Button("Refresh") { tab.refreshDir(tab.rootPath) }
        }
    }

    private var filterBox: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: s(11))).foregroundStyle(Flat.faint)
            TextField("Filter this folder", text: $search)
                .textFieldStyle(.plain).font(.system(size: s(12))).foregroundStyle(Flat.text)
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: s(11))).foregroundStyle(Flat.faint) }
                    .buttonStyle(.plain)
            }
            sortMenu
        }.padding(.horizontal, 10).padding(.vertical, 6)
    }

    private var sortMenu: some View {
        Menu {
            ForEach(FileSort.allCases, id: \.self) { opt in
                Button {
                    // Re-picking a key flips direction; a new key defaults to the most
                    // useful direction (name/kind A→Z, date/size large→small).
                    if tab.sortBy == opt { tab.sortAsc.toggle() }
                    else { tab.sortBy = opt; tab.sortAsc = (opt == .name || opt == .kind) }
                } label: {
                    if tab.sortBy == opt {
                        Label(opt.rawValue, systemImage: tab.sortAsc ? "chevron.up" : "chevron.down")
                    } else {
                        Text(opt.rawValue)
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down").font(.system(size: s(11), weight: .medium)).foregroundStyle(Flat.faint)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Sort: \(tab.sortBy.rawValue) \(tab.sortAsc ? "↑" : "↓")")
    }

    private func transferBanner(_ verb: String, _ t: UploadState) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("\(verb) \(t.name)").font(.system(size: s(11))).foregroundStyle(Flat.dim).lineLimit(1)
                ProgressView(value: t.progress).frame(width: 90)
                Text("\(Int(t.progress * 100))%").font(.system(size: s(10), design: .monospaced)).foregroundStyle(Flat.faint)
                Spacer()
            }.padding(.horizontal, 12).padding(.vertical, 5)
            Divider().overlay(Flat.hairline)
        }
    }

    private var pathBar: some View {
        HStack(spacing: 8) {
            Button { tab.goHome() } label: { Image(systemName: "house") }.buttonStyle(.plain).foregroundStyle(Flat.dim).help("Home")
            Button { tab.goUp() } label: { Image(systemName: "arrow.up") }.buttonStyle(.plain).foregroundStyle(Flat.dim).help("Up")
            Button { tab.refreshDir(tab.rootPath) } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).foregroundStyle(Flat.dim).help("Refresh")
            breadcrumb
            Spacer(minLength: 0)
            Button { pickAndUpload(tab, into: tab.rootPath) } label: { Image(systemName: "square.and.arrow.up") }
                .buttonStyle(.plain).foregroundStyle(Flat.dim).help("Upload a file to this folder")
        }
        .padding(.horizontal, 12).frame(height: s(34))
    }

    private var breadcrumb: some View {
        let segs = crumbs()
        let last = segs.count - 1
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                if segs.isEmpty {
                    Text("Computer").font(.system(size: s(11.5), design: .monospaced)).foregroundStyle(Flat.dim)
                }
                ForEach(Array(segs.enumerated()), id: \.offset) { idx, c in
                    if idx > 0 { Image(systemName: "chevron.right").font(.system(size: s(8))).foregroundStyle(Flat.faint) }
                    Button { tab.setRootPath(c.path) } label: {
                        Text(c.name)
                            .font(.system(size: s(11.5), weight: idx == last ? .semibold : .regular, design: .monospaced))
                            .foregroundStyle(idx == last ? Flat.text : Flat.dim)
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private func crumbs() -> [(name: String, path: String)] {
        let sep = tab.sep, p = tab.rootPath
        guard !p.isEmpty else { return [] }
        var segs: [(String, String)] = []
        var acc = ""
        for part in p.components(separatedBy: sep) {
            if part.isEmpty {
                if acc.isEmpty { acc = sep; segs.append(("/", sep)) }   // unix root
                continue
            }
            if acc.isEmpty { acc = part.hasSuffix(":") ? part + sep : part }  // windows drive
            else if acc.hasSuffix(sep) { acc += part }
            else { acc += sep + part }
            segs.append((part, acc))
        }
        return segs
    }
}

/// Rename + new-folder/file dialogs, split from the delete/info ones so each
/// modifier body stays small enough to type-check fast.
private struct FileNameDialogs: ViewModifier {
    @ObservedObject var tab: FileTab
    @Binding var renameText: String
    @Binding var newName: String

    func body(content: Content) -> some View {
        content
            .alert("Rename", isPresented: Binding(get: { tab.renaming != nil }, set: { if !$0 { tab.renaming = nil } })) {
                TextField("Name", text: $renameText)
                Button("Rename") { if let n = tab.renaming, !renameText.isEmpty { tab.rename(n, to: renameText) }; tab.renaming = nil }
                Button("Cancel", role: .cancel) { tab.renaming = nil }
            }
            .onChange(of: tab.renaming?.id) { _ in renameText = tab.renaming?.entry.name ?? "" }
            .alert(tab.creating?.isDir == true ? "New Folder" : "New File",
                   isPresented: Binding(get: { tab.creating != nil }, set: { if !$0 { tab.creating = nil } })) {
                TextField("Name", text: $newName)
                Button("Create") {
                    if let c = tab.creating, !newName.isEmpty {
                        if c.isDir { tab.mkdir(in: c.parent, name: newName) } else { tab.createFile(in: c.parent, name: newName) }
                    }
                    tab.creating = nil
                }
                Button("Cancel", role: .cancel) { tab.creating = nil }
            }
            .onChange(of: tab.creating?.id) { _ in newName = "" }
    }
}

/// Delete confirmation + the Get-Info sheet + the folder-change filter reset.
private struct FileMiscDialogs: ViewModifier {
    @ObservedObject var tab: FileTab
    @Binding var search: String

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Delete “\(tab.deleting?.entry.name ?? "")”?",
                                isPresented: Binding(get: { tab.deleting != nil }, set: { if !$0 { tab.deleting = nil } }),
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) { if let n = tab.deleting { tab.delete(n) }; tab.deleting = nil }
                Button("Cancel", role: .cancel) { tab.deleting = nil }
            } message: {
                Text(tab.deleting?.entry.isDir == true ? "This folder and everything in it will be permanently deleted." : "This file will be permanently deleted.")
            }
            .onChange(of: tab.rootPath) { _ in search = "" }   // filter is depth-1: reset it when the folder changes
            .sheet(item: $tab.inspecting) { entry in
                FileInfoView(entry: entry, isLocal: tab.isLocal) { tab.inspecting = nil }
            }
    }
}

// MARK: - recursive tree row (with context menu + double-click navigation)

private struct FileRow: View {
    @ObservedObject var node: FileNode
    @ObservedObject var tab: FileTab
    let depth: Int
    @EnvironmentObject private var model: FilesModel
    @EnvironmentObject private var appState: AppState
    @AppStorage("ut.uiScale") private var uiScale: Double = 1.0
    private func s(_ v: CGFloat) -> CGFloat { v * uiScale }

    var body: some View {
        let sel = tab.selection == node.entry.path
        // Only this row's own label — children are flattened into the parent LazyVStack
        // (TabPane.visibleRows), so the tree never nests eager subviews.
        rowLabel(sel: sel)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                if node.entry.isDir { tab.setRootPath(node.entry.path) } else { tab.open(node) }
            }
            .onTapGesture(count: 1) { tapped() }
            .contextMenu { menu }
    }

    private func rowLabel(sel: Bool) -> some View {
        HStack(spacing: 5) {
            if node.entry.isDir {
                Image(systemName: node.expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: s(9), weight: .semibold)).foregroundStyle(Flat.faint).frame(width: s(12))
            } else {
                Color.clear.frame(width: s(12))
            }
            Image(systemName: icon).font(.system(size: s(12))).foregroundStyle(iconColor).frame(width: s(16))
            Text(node.entry.name).font(.system(size: s(12.5)))
                .foregroundStyle(sel ? Flat.text : Flat.text.opacity(0.82)).lineLimit(1)
            Spacer(minLength: 6)
            if !node.entry.isDir {
                Text(byteSize(node.entry.size)).font(.system(size: s(10), design: .monospaced)).foregroundStyle(Flat.faint)
            }
        }
        .padding(.leading, CGFloat(depth) * s(14) + 8)
        .padding(.trailing, 8).padding(.vertical, s(4))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(sel ? Flat.sel : Color.clear)
    }

    @ViewBuilder private var menu: some View {
        if node.entry.isDir {
            Button("Open as Root") { tab.setRootPath(node.entry.path) }
            Button("Open in New Tab") { openInNewTab() }
            Button("New Folder…") { tab.creating = NewItem(parent: node.entry.path, isDir: true) }
            Button("New File…") { tab.creating = NewItem(parent: node.entry.path, isDir: false) }
            Button("Upload File…") { pickAndUpload(tab, into: node.entry.path) }
            Divider()
        } else {
            Button("Open") { tab.open(node) }
            Button("Download…") { download() }
            Divider()
        }
        if tab.isLocal {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.entry.path)]) }
        }
        Button("Get Info") { tab.inspecting = node.entry }
        Button("Copy Path") { copy(node.entry.path) }
        Button("Copy Name") { copy(node.entry.name) }
        Button("Rename…") { tab.renaming = node }
        Button("Refresh") { node.entry.isDir ? tab.refreshDir(node.entry.path) : tab.refreshDir(tab.parentOf(node.entry.path)) }
        Divider()
        Button("Delete", role: .destructive) { tab.deleting = node }
    }

    private func tapped() {
        if node.entry.isDir { tab.toggleExpand(node) } else { tab.open(node) }
    }

    private func openInNewTab() {
        if let m = appState.machines.first(where: { $0.id == tab.machineID }) {
            model.addTab(m, startPath: node.entry.path)
        }
    }

    private func download() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = node.entry.name
        panel.begin { resp in
            guard resp == .OK, let dest = panel.url else { return }
            tab.download(node.entry, to: dest)
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private var icon: String { node.entry.isDir ? (node.expanded ? "folder.fill" : "folder") : iconForFile(node.entry.name) }
    private var iconColor: Color { node.entry.isDir ? Flat.accent.opacity(0.9) : Flat.dim }
}

/// Pick local file(s) and upload them into `dir` on the tab's host.
private func pickAndUpload(_ tab: FileTab, into dir: String) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = true
    panel.begin { resp in
        guard resp == .OK else { return }
        for url in panel.urls {
            if let data = try? Data(contentsOf: url) { tab.upload(into: dir, name: url.lastPathComponent, data: data) }
        }
    }
}

// MARK: - ⌘P quick-open (fuzzy file finder over the current root)

/// Fuzzy subsequence score: nil if `query`'s chars don't all appear in order in
/// `text`, else a score (higher = better) that rewards contiguous runs and matches
/// at word boundaries (after / _ - . or at the start).
func fuzzyScore(_ query: String, _ text: String) -> Int? {
    if query.isEmpty { return 0 }
    let q = Array(query.lowercased())
    let t = Array(text.lowercased())
    var qi = 0, score = 0, lastMatch = -2
    for ti in t.indices {
        guard qi < q.count else { break }
        if t[ti] == q[qi] {
            var bonus = 1
            if ti == lastMatch + 1 { bonus += 5 }
            if ti == 0 || t[ti - 1] == "/" || t[ti - 1] == "\\" || t[ti - 1] == "_" || t[ti - 1] == "-" || t[ti - 1] == "." { bonus += 8 }
            score += bonus
            lastMatch = ti
            qi += 1
        }
    }
    return qi == q.count ? score : nil
}

struct QuickOpenView: View {
    @ObservedObject var tab: FileTab
    @State private var query = ""
    @State private var sel = 0
    @FocusState private var focused: Bool
    @State private var keyMonitor: Any?

    private struct Match: Identifiable { let entry: FileEntry; let rel: String; let score: Int; var id: String { entry.path } }

    private func relative(_ p: String) -> String {
        let root = tab.rootPath
        guard p.hasPrefix(root) else { return p }
        var r = String(p.dropFirst(root.count))
        if r.hasPrefix(tab.sep) { r.removeFirst() }
        return r.isEmpty ? p : r
    }

    private var matches: [Match] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            return tab.quickOpenFiles.prefix(60).map { Match(entry: $0, rel: relative($0.path), score: 0) }
        }
        var out: [Match] = []
        for e in tab.quickOpenFiles {
            let r = relative(e.path)
            guard let pathScore = fuzzyScore(q, r) else { continue }
            let nameBonus = fuzzyScore(q, e.name).map { $0 * 2 } ?? 0   // prefer basename matches
            out.append(Match(entry: e, rel: r, score: pathScore + nameBonus))
        }
        out.sort { $0.score != $1.score ? $0.score > $1.score : $0.entry.name.count < $1.entry.name.count }
        return Array(out.prefix(60))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(Theme.textTertiary)
                TextField("Go to file…", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 15)).foregroundStyle(Theme.textPrimary)
                    .focused($focused).onSubmit(open)
                if tab.quickOpenLoading { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 14).frame(height: 46)
            Rectangle().fill(Theme.border).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(matches.enumerated()), id: \.element.id) { i, m in
                            HStack(spacing: 8) {
                                Image(systemName: iconForFile(m.entry.name)).font(.system(size: 12))
                                    .foregroundStyle(i == sel ? Theme.accent : Theme.textTertiary).frame(width: 16)
                                Text(m.entry.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                                Text(parentDir(m.rel)).font(.system(size: 11)).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.head)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12).frame(height: 32)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(i == sel ? Theme.accent.opacity(0.16) : .clear))
                            .contentShape(Rectangle()).id(i)
                            .onTapGesture { sel = i; open() }
                        }
                        if matches.isEmpty {
                            Text(tab.quickOpenLoading ? "Indexing…" : "No files match")
                                .font(.system(size: 12)).foregroundStyle(Theme.textTertiary).padding(.vertical, 18)
                        }
                    }
                    .padding(8)
                }
                .frame(height: 380)
                .onChange(of: sel) { i in withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(i) } }
            }
        }
        .frame(width: 600)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.sidebarBackground))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
        .onAppear { sel = 0; installKeys(); focusSoon() }
        .onDisappear { removeKeys() }
        .onChange(of: query) { _ in sel = 0 }
        .onExitCommand { tab.closeQuickOpen() }
    }

    private func parentDir(_ rel: String) -> String {
        guard let r = rel.range(of: tab.sep, options: .backwards) else { return "" }
        return String(rel[..<r.lowerBound])
    }

    private func open() {
        guard matches.indices.contains(sel) else { return }
        tab.openEntry(matches[sel].entry, line: nil)
        tab.closeQuickOpen()
    }
    private func focusSoon() {
        focused = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true }
    }
    private func installKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let n = matches.count
            switch e.keyCode {
            case 125: if n > 0 { sel = (sel + 1) % n }; return nil          // ↓
            case 126: if n > 0 { sel = (sel - 1 + n) % n }; return nil      // ↑
            case 36, 76: open(); return nil                                 // ↩
            case 53: tab.closeQuickOpen(); return nil                       // Esc
            default: return e
            }
        }
    }
    private func removeKeys() { if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil } }
}

func iconForFile(_ name: String) -> String {
    switch (name as NSString).pathExtension.lowercased() {
    case "png","jpg","jpeg","gif","bmp","tiff","tif","webp","heic","heif","svg","ico","icns": return "photo"
    case "mp4","mov","m4v","avi","mkv","webm": return "film"
    case "mp3","wav","m4a","flac","aac","ogg","aiff": return "music.note"
    case "pdf": return "doc.richtext"
    case "zip","tar","gz","tgz","bz2","xz","7z","rar","dmg": return "doc.zipper"
    case "json","yaml","yml","toml","xml","ini","cfg","conf","plist": return "curlybraces"
    case "md","markdown","txt","rtf","log": return "doc.text"
    case "sh","bash","zsh","fish","ps1","bat","cmd": return "terminal"
    case "js","ts","jsx","tsx","py","go","rs","c","cpp","cc","h","hpp","java","rb","php","swift","kt","lua","r","jl","scala","cs","dart","hs","pl","m","mm":
        return "chevron.left.forwardslash.chevron.right"
    default: return "doc"
    }
}
