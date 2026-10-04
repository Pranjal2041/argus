import SwiftUI

// Lab detail pages: the two decision dossiers, the set page, the run page, and
// run comparison. Human actions go through LabStore (one at a time, refresh on
// success); offline (mirrored) sets are read-only.

struct LabRouteView: View {
    @EnvironmentObject var lab: LabStore
    let route: LabRoute

    var body: some View {
        Group {
            switch route {
            case .key(let id):
                if let item = lab.pendingKey(id: id) { LabAccessDossier(item: item) } else { LabResolvedView() }
            case .proposal(let id):
                if let item = lab.pendingRun(id: id) { LabProposalDossier(pending: item) } else { LabResolvedView() }
            case .set(let id):
                if let card = lab.card(id: id) { LabSetPage(card: card) } else { LabMissingView(what: "set") }
            case .run(let cardID, let runID):
                if let card = lab.card(id: cardID), let run = card.brief.runs.first(where: { $0.id == runID }) {
                    LabRunPage(card: card, run: run)
                } else { LabMissingView(what: "run") }
            case .compare(let cardID, let a, let b):
                if let card = lab.card(id: cardID),
                   let runA = card.brief.runs.first(where: { $0.id == a }), let runB = card.brief.runs.first(where: { $0.id == b }) {
                    LabComparePage(card: card, runA: runA, runB: runB)
                } else { LabMissingView(what: "comparison") }
            }
        }
        .safeAreaInset(edge: .top) {
            if lab.error != nil { LabErrorBanner().padding(.horizontal, 16).padding(.vertical, 6).background(.bar) }
        }
    }
}

struct LabResolvedView: View {
    @EnvironmentObject var lab: LabStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Group {
            if lab.loaded {
                ContentUnavailableView {
                    Label("No longer pending", systemImage: "checkmark.circle")
                } description: {
                    Text("This decision was already made, or its store is unreachable.")
                } actions: {
                    Button("Back to queue") { dismiss() }
                }
            } else {
                ProgressView("Reading Lab stores…")
            }
        }
        .navigationTitle("Decision")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct LabMissingView: View {
    @EnvironmentObject var lab: LabStore
    let what: String
    var body: some View {
        Group {
            if lab.loaded {
                ContentUnavailableView("This \(what) is not reachable", systemImage: "questionmark.folder",
                                       description: Text("Its broker may be offline. Pull to refresh the Lab list."))
            } else {
                ProgressView("Reading Lab stores…")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: Access dossier

struct LabAccessDossier: View {
    @EnvironmentObject var lab: LabStore
    @EnvironmentObject var router: AppRouter
    @Environment(\.dismiss) private var dismiss
    let item: LabPendingKey
    @State private var project: String
    @State private var denial = ""
    @State private var policy = ""

    init(item: LabPendingKey) {
        self.item = item
        _project = State(initialValue: item.key.project)
    }

    var body: some View {
        let terminal = lab.terminalTarget(machineName: item.key.machine, fallback: item.broker, session: item.key.session)
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("An agent wants a research set.").font(.title2.bold())
                    Text("Approval creates one store-bound key and one isolated set. Any machine mounting this Lab store may use it; another store or set cannot.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            Section("Request") {
                LabFactsView(facts: [
                    ("REQUESTED FROM", item.machineName),
                    ("ACCESS SCOPE", LabFormat.storeLabel(item.storeID)),
                    ("FOLDER", item.key.cwd),
                    ("SESSION", item.key.session ?? "not reported"),
                    ("REQUESTED", LabTime.ago(item.key.created)),
                ])
            }
            Section {
                TextField("Project label", text: $project)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Picker("Approval policy", selection: $policy) {
                    Text("full-only (default)").tag("")
                    Text("all").tag("all")
                    Text("none").tag("none")
                }
                TextField("Optional note if denied", text: $denial, axis: .vertical).lineLimit(1...5)
            } header: {
                Text("Decision")
            } footer: {
                Text("full-only gates full experiments; all gates every run; none records runs without approval.")
            }
            if let session = item.key.session, !session.isEmpty {
                Section {
                    if case let (m, s)? = terminal {
                        Button { router.openTerminal(m, s) } label: { Label("Open agent terminal", systemImage: "terminal") }
                    } else {
                        Label("Session “\(session)” is not running on a reachable machine.", systemImage: "terminal")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Access request")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            LabDecisionDock(busy: lab.actionBusy, rejectLabel: "Deny",
                            onReject: { decide(approve: false) }, onApprove: { decide(approve: true) })
        }
    }

    private func decide(approve: Bool) {
        Task {
            let ok = await lab.decide(item, approve: approve, project: project, note: approve ? "" : denial,
                                      policy: approve ? policy : "")
            LabHaptics.decided(approve: approve, ok: ok)
            if ok { dismiss() }
        }
    }
}

// MARK: Proposal dossier

struct LabProposalDossier: View {
    @EnvironmentObject var lab: LabStore
    @EnvironmentObject var router: AppRouter
    @Environment(\.dismiss) private var dismiss
    let pending: LabPendingRun
    @State private var note = ""

    var body: some View {
        let p = pending.proposal
        let detail = lab.detail(pending)
        let env = detail?.envelope
        let card = lab.card(for: pending)
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(p.intent.isEmpty ? "Proposed experiment" : p.intent).font(.title3.bold())
                    LabMetaLine(project: p.project, machine: env?.machine ?? p.machine, set: p.set, tier: p.tier, group: p.group)
                    if card == nil {
                        Text("The owning set's brief is not reachable; evidence is read from the proposing store.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                if let detail {
                    LabEnvelopeFacts(env: env, proposal: p)
                    let argv = (env?.argv.isEmpty == false ? env?.argv : nil) ?? p.argv
                    if !argv.isEmpty { LabCodeBlock(text: argv.joined(separator: " "), maxHeight: 140) }
                    ForEach(detail.textByName.keys.filter { $0.hasPrefix("files/") && $0 != "files/env.txt" }.sorted(), id: \.self) { name in
                        LabEvidence(title: name, text: detail.textByName[name] ?? "", expanded: true)
                    }
                    if let diff = detail.textByName["snapshot/diff.patch"] { LabEvidence(title: "Uncommitted code", text: diff) }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            } header: {
                Text("Approval envelope · bound to exact evidence")
            }
            if let session = env?.tmuxSession {
                Section {
                    if case let (m, s)? = lab.terminalTarget(machineName: env?.machine ?? p.machine, fallback: card?.broker ?? pending.broker, session: session) {
                        Button { router.openTerminal(m, s) } label: { Label("Open source terminal", systemImage: "terminal") }
                    } else {
                        Label("Session “\(session)” is not running on a reachable machine.", systemImage: "terminal")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Message to the agent") {
                TextField("Optional — the agent receives it in its brief", text: $note, axis: .vertical).lineLimit(1...6)
            }
        }
        .navigationTitle(p.run)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            LabDecisionDock(busy: lab.actionBusy, rejectLabel: "Reject",
                            onReject: { decide(approve: false) }, onApprove: { decide(approve: true) })
        }
        .onAppear { lab.loadDetail(pending, force: true) }
        .refreshable { lab.loadDetail(pending, force: true); await lab.refresh() }
    }

    private func decide(approve: Bool) {
        Task {
            let ok = await lab.decide(pending, approve: approve, note: note)
            LabHaptics.decided(approve: approve, ok: ok)
            if ok { dismiss() }
        }
    }
}

struct LabEnvelopeFacts: View {
    let env: LabEventData?
    let proposal: LabProposal
    var body: some View {
        let snapshot = env?.snapshot
        let code: String = {
            if snapshot?.noGit == true { return "no repository" }
            if let sha = snapshot?.baseSha, !sha.isEmpty { return String(sha.prefix(10)) }
            return "not captured"
        }()
        LabFactsView(facts: [
            ("COMMAND", env?.argv.first ?? proposal.argv.first ?? "missing"),
            ("CODE", code),
            ("CHANGES", (snapshot?.patchBytes ?? 0) > 0 ? "\(snapshot!.patchBytes) B diff" : "clean tree"),
            ("PARAMETERS", "\(env?.params.count ?? 0) files"),
            ("DECLARED DATA", "\(env?.dataFiles.count ?? 0) fingerprints"),
        ])
    }
}

struct LabMetaLine: View {
    let project: String
    let machine: String
    let set: String
    var tier: String?
    var group: String?
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text("\(project) · \(machine) · \(set)").font(.caption.monospaced()).foregroundStyle(.secondary)
                if let tier { LabTag(text: tier.uppercased(), color: .secondary) }
                if let group { LabTag(text: group, color: .secondary) }
            }
        }
    }
}

// MARK: Set page

struct LabSetPage: View {
    @EnvironmentObject var lab: LabStore
    let card: LabSetCard
    @State private var note = ""
    @State private var compareA = ""
    @State private var compareB = ""
    @State private var confirmRevoke = false

    private var orderedRuns: [LabRunSummary] {
        card.brief.runs.sorted {
            let a = $0.activityAt(fallback: card.brief.set.created), b = $1.activityAt(fallback: card.brief.set.created)
            return a != b ? a > b : $0.number > $1.number
        }
    }

    var body: some View {
        let set = card.brief.set
        let runs = orderedRuns
        let keyActive = lab.activeKeyBySet[card.id] != nil
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(set.project.isEmpty ? set.id : set.project).font(.title2.bold())
                    Text("\(LabFormat.storeLabel(card.storeID)) · via \(card.machineName)")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(set.cwd).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    if card.offline {
                        Label("Read-only mirror · last copied \(LabTime.ago(card.mirroredAt)) ago", systemImage: "icloud.slash")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                .padding(.vertical, 4)
            }
            if !card.offline {
                Section {
                    Picker("Approval policy", selection: Binding(
                        get: { card.brief.policy },
                        set: { p in Task { await lab.setPolicy(card, p) } })) {
                        ForEach(["all", "full-only", "none"], id: \.self) { Text($0).tag($0) }
                    }
                    .disabled(lab.actionBusy)
                    Button { Task { await lab.setArchived(card, on: !card.brief.archived) } } label: {
                        Label(card.brief.archived ? "Restore set" : "Archive set",
                              systemImage: card.brief.archived ? "tray.and.arrow.up" : "archivebox")
                    }
                    .disabled(lab.actionBusy)
                    if keyActive {
                        Button(role: .destructive) { confirmRevoke = true } label: { Label("Revoke key", systemImage: "key.slash") }
                            .disabled(lab.actionBusy)
                    }
                } header: {
                    Text("Set control · \(keyActive ? "key active" : "access closed")")
                }
            }
            Section("Set guidance · human ground truth") {
                let notes = LabEvents.humanNotes(card.brief.setEvents)
                if notes.isEmpty { Text("No direct guidance for this set.").font(.footnote).foregroundStyle(.secondary) }
                ForEach(notes) { e in
                    LabNoteRow(text: e.text ?? "", time: e.time, hidden: LabEvents.isHidden(e, in: card.brief.setEvents))
                }
                if !card.offline {
                    TextField("Guidance for this experiment set", text: $note, axis: .vertical).lineLimit(1...6)
                    Button {
                        let text = note
                        Task { if await lab.postSetNote(card, text) { note = "" } }
                    } label: { Label("Publish to set", systemImage: "paperplane") }
                        .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || lab.actionBusy)
                }
            }
            if runs.count > 1 {
                Section("Compare runs · literal recorded evidence") {
                    Picker("Run A", selection: $compareA) { ForEach(runs) { Text($0.id).tag($0.id) } }
                    Picker("Run B", selection: $compareB) { ForEach(runs) { Text($0.id).tag($0.id) } }
                    NavigationLink(value: LabRoute.compare(card.id, compareA, compareB)) {
                        Label("Compare recorded runs", systemImage: "arrow.left.arrow.right")
                    }
                    .disabled(compareA.isEmpty || compareB.isEmpty || compareA == compareB)
                }
            }
            Section("Run ledger · \(runs.count) recorded") {
                if runs.isEmpty { Text("No runs recorded.").font(.footnote).foregroundStyle(.secondary) }
                ForEach(runs) { run in
                    NavigationLink(value: LabRoute.run(card.id, run.id)) { LabRunRow(run: run) }
                        .swipeActions(edge: .trailing) {
                            if !card.offline {
                                Button { Task { await lab.setArchived(card, run: run.id, on: !run.archived) } } label: {
                                    Label(run.archived ? "Restore" : "Archive", systemImage: run.archived ? "tray.and.arrow.up" : "archivebox")
                                }
                                .tint(.indigo)
                            }
                        }
                }
            }
        }
        .navigationTitle(set.id)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await lab.refresh() }
        .onAppear {
            if compareB.isEmpty || !runs.contains(where: { $0.id == compareB }) { compareB = runs.first?.id ?? "" }
            if compareA.isEmpty || !runs.contains(where: { $0.id == compareA }) { compareA = (runs.count > 1 ? runs[1] : runs.first)?.id ?? "" }
        }
        .confirmationDialog("Revoke this set's key?", isPresented: $confirmRevoke, titleVisibility: .visible) {
            Button("Revoke key", role: .destructive) { Task { await lab.revokeKey(card) } }
        } message: {
            Text("The agent holding it loses access to \(set.id). The record is kept.")
        }
    }
}

struct LabRunRow: View {
    let run: LabRunSummary
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(run.phase.color).frame(width: 8, height: 8)
                Text(run.id).font(.subheadline.monospaced().bold())
                if let tier = run.tier { LabTag(text: tier.uppercased(), color: .secondary) }
                if let group = run.group { LabTag(text: group, color: .secondary) }
                if run.archived { LabTag(text: "ARCHIVED", color: .secondary) }
                Spacer()
                Text(run.phase.rawValue.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(run.phase.color)
            }
            if let latest = run.latest, !latest.isEmpty {
                Text(LabMarkdown.plainText(latest)).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                    .padding(.leading, 14)
            }
        }
    }
}

// MARK: Run page

struct LabRunPage: View {
    @EnvironmentObject var lab: LabStore
    @EnvironmentObject var router: AppRouter
    let card: LabSetCard
    let run: LabRunSummary
    @State private var note = ""
    @State private var message = ""
    @State private var openArtifacts: Set<String> = []
    @State private var showStop = false

    var body: some View {
        let key = lab.detailKey(card, run.id)
        let detail = lab.details[key]
        let pending = lab.pendingRun(in: card, run: run.id)
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(run.id).font(.title.monospaced().bold())
                        LabTag(text: run.phase.rawValue.uppercased(), color: run.phase.color)
                        if run.archived { LabTag(text: "ARCHIVED", color: .secondary) }
                    }
                    LabMetaLine(project: card.brief.set.project, machine: machine(detail), set: card.brief.set.id,
                                tier: run.tier, group: run.group)
                    if run.phase == .stopped {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("WHY THIS RECORD WAS CLOSED").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                            Text(run.stopReason ?? "The run was manually marked stopped after its underlying process was verified absent.")
                                .font(.footnote)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if let latest = run.latest, !latest.isEmpty { LabMarkdownView(text: latest).padding(.top, 4) }
                }
                .padding(.vertical, 4)
            }
            if let d = detail {
                resultLog(d)
                recordedWorld(d)
                artifacts(d, key: key)
                if let refs = d.end?.wandb, !refs.isEmpty {
                    Section("Weights & Biases · external record") {
                        ForEach(refs, id: \.self) { ref in
                            if let url = LabFormat.wandbURL(ref) {
                                Link(destination: url) { Label(ref, systemImage: "chart.xyaxis.line").font(.caption.monospaced()) }
                            }
                        }
                    }
                }
            } else {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
            if let pending, !card.offline {
                Section("Decision required · \(run.id)") {
                    TextField("Optional message", text: $message, axis: .vertical).lineLimit(1...5)
                    HStack {
                        Button("Reject", role: .destructive) { decide(pending, approve: false) }.buttonStyle(.bordered)
                        Spacer()
                        Button("Approve") { decide(pending, approve: true) }.buttonStyle(.borderedProminent).tint(.green)
                    }
                    .disabled(lab.actionBusy)
                }
            }
            if !card.offline {
                Section {
                    if run.phase == .running {
                        Button { showStop = true } label: { Label("Mark stopped…", systemImage: "stop.circle") }
                    }
                    Button { Task { await lab.setArchived(card, run: run.id, on: !run.archived) } } label: {
                        Label(run.archived ? "Restore run" : "Archive run", systemImage: run.archived ? "tray.and.arrow.up" : "archivebox")
                    }
                } footer: {
                    Text("Archive only changes what normal views show; it does not stop anything or change the lifecycle.")
                }
                .disabled(lab.actionBusy)
            }
        }
        .navigationTitle(run.id)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { lab.loadDetail(card, run: run.id, force: true); await lab.refresh() }
        .onAppear {
            lab.watch(card, run: run.id)
            lab.loadDetail(card, run: run.id, force: true)
        }
        .onDisappear { lab.unwatch(card, run: run.id) }
        .sheet(isPresented: $showStop) { LabMarkStoppedSheet(card: card, runID: run.id) }
    }

    private func machine(_ detail: LabRunDetail?) -> String { detail?.envelope?.machine ?? run.machine ?? card.machineName }

    private func decide(_ pending: LabPendingRun, approve: Bool) {
        Task {
            let ok = await lab.decide(pending, approve: approve, note: message)
            LabHaptics.decided(approve: approve, ok: ok)
            if ok { message = "" }
        }
    }

    @ViewBuilder
    private func resultLog(_ d: LabRunDetail) -> some View {
        let visible = LabEvents.visibleResults(d.events)
        Section("Result log · newest first · append-only") {
            if visible.isEmpty { Text("No result has been reported yet.").font(.footnote).foregroundStyle(.secondary) }
            ForEach(visible) { e in
                let hideable = !card.offline && e.author == "agent"
                LabNoteRow(text: e.text ?? "", time: e.time, author: e.author)
                    .swipeActions(edge: .trailing) {
                        if hideable { Button("Hide") { Task { await lab.hideSetEvent(card, target: e.id) } }.tint(.gray) }
                    }
                    .contextMenu {
                        if hideable {
                            Button { Task { await lab.hideSetEvent(card, target: e.id) } } label: { Label("Hide claim", systemImage: "eye.slash") }
                        }
                    }
            }
            if !card.offline {
                TextField("Add a human note to this run", text: $note, axis: .vertical).lineLimit(1...6)
                Button {
                    let text = note
                    Task { if await lab.postRunNote(card, run: run.id, text) { note = "" } }
                } label: { Label("Add note", systemImage: "square.and.pencil") }
                    .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || lab.actionBusy)
            }
        }
    }

    @ViewBuilder
    private func recordedWorld(_ d: LabRunDetail) -> some View {
        let env = d.envelope
        let end = d.end
        Section("Recorded world · mechanical provenance") {
            LabFactsView(facts: [
                ("COMMAND", env.map { $0.argv.joined(separator: " ") }.flatMap { $0.isEmpty ? nil : $0 } ?? "not captured"),
                ("MACHINE", machine(d)),
                ("WORKING DIR", env?.cwd ?? card.brief.set.cwd),
                ("BASE COMMIT", env?.snapshot?.baseSha ?? (env?.snapshot?.noGit == true ? "no repository" : "not captured")),
                ("ENVIRONMENT", LabEnvFacts.summary(env?.env) ?? "not captured"),
                ("DURATION", LabFormat.duration(end?.durationSec)),
                ("EXIT", end?.exitCode.map(String.init) ?? "not finished"),
            ])
            if let session = env?.tmuxSession,
               case let (m, s)? = lab.terminalTarget(machineName: machine(d), fallback: card.offline ? nil : card.broker, session: session) {
                Button { router.openTerminal(m, s) } label: { Label("Open terminal", systemImage: "terminal") }
            }
            ForEach(d.textByName.keys.filter { $0.hasPrefix("files/") && $0 != "files/env.txt" }.sorted(), id: \.self) { name in
                LabEvidence(title: name, text: d.textByName[name] ?? "")
            }
            if let diff = d.textByName["snapshot/diff.patch"] { LabEvidence(title: "Code diff", text: diff) }
            if let freeze = d.textByName["files/env.txt"] { LabEvidence(title: "Environment freeze", text: freeze) }
            if let log = d.textByName["log.txt"] { LabEvidence(title: "Log tail", text: log, expanded: run.phase == .running) }
            if let data = env?.dataFiles, !data.isEmpty {
                let drift = Set(end?.drift ?? [])
                VStack(alignment: .leading, spacing: 8) {
                    Text("DECLARED DATA").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                    ForEach(data, id: \.self) { ref in
                        let changed = drift.contains(ref.path)
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(ref.path).font(.caption.monospaced())
                                Text(ref.sha256 ?? "").font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .textSelection(.enabled)
                            Spacer()
                            LabTag(text: changed ? "CHANGED" : end != nil ? "UNCHANGED" : "PENDING",
                                   color: changed ? .red : end != nil ? .green : .orange)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func artifacts(_ d: LabRunDetail, key: String) -> some View {
        if !d.files.isEmpty {
            Section("Stored artifacts · tap to inspect") {
                ForEach(d.files) { file in
                    DisclosureGroup(isExpanded: Binding(
                        get: { openArtifacts.contains(file.name) },
                        set: { open in
                            if open { openArtifacts.insert(file.name); lab.loadArtifact(card, run: run.id, file: file) }
                            else { openArtifacts.remove(file.name) }
                        })) {
                        if let text = lab.details[key]?.textByName[file.name] {
                            LabCodeBlock(text: text)
                        } else {
                            ProgressView().frame(maxWidth: .infinity)
                        }
                    } label: {
                        HStack {
                            Text(file.name).font(.caption.monospaced()).lineLimit(2)
                            Spacer()
                            Text(LabFormat.bytes(file.size)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

/// Manual lifecycle correction: requires a reason and an explicit check that the
/// process is already gone. Never sends a signal.
struct LabMarkStoppedSheet: View {
    @EnvironmentObject var lab: LabStore
    @Environment(\.dismiss) private var dismiss
    let card: LabSetCard
    let runID: String
    @State private var reason = ""
    @State private var confirmed = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Use this only when the process or remote job has already stopped but its Lab wrapper never recorded an ending.")
                        .font(.subheadline)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("This changes the Lab record only.").font(.subheadline.weight(.semibold))
                        Text("Argus will not send a signal or report success or failure.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    TextField("Reason for the missing automatic ending", text: $reason, axis: .vertical)
                        .lineLimit(3...8)
                        .onChange(of: reason) { _, v in if v.count > 1000 { reason = String(v.prefix(1000)) } }
                } header: {
                    Text("Reason")
                } footer: {
                    Text("\(reason.count)/1000")
                }
                Section {
                    Toggle("I confirmed that the underlying process or job is no longer running.", isOn: $confirmed)
                }
            }
            .disabled(lab.actionBusy)
            .navigationTitle("Mark \(runID) stopped")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(lab.actionBusy) }
                ToolbarItem(placement: .confirmationAction) {
                    if lab.actionBusy { ProgressView() } else {
                        Button("Mark stopped") {
                            Task { if await lab.markStopped(card, run: runID, reason: reason) { dismiss() } }
                        }
                        .disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !confirmed)
                    }
                }
            }
        }
        .interactiveDismissDisabled(lab.actionBusy)
    }
}

// MARK: Compare

struct LabComparePage: View {
    @EnvironmentObject var lab: LabStore
    let card: LabSetCard
    let runA: LabRunSummary
    let runB: LabRunSummary

    var body: some View {
        let a = lab.details[lab.detailKey(card, runA.id)]
        let b = lab.details[lab.detailKey(card, runB.id)]
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recorded difference").font(.title2.bold())
                    Text("Literal evidence only — no semantic configuration assumptions.").font(.footnote).foregroundStyle(.secondary)
                    HStack(spacing: 8) { head(runA); head(runB) }.padding(.top, 6)
                }
                .padding(.vertical, 4)
            }
            if let a, let b {
                let envA = a.envelope, envB = b.envelope
                Section {
                    row("PHASE", runA.phase.rawValue, runB.phase.rawValue)
                    row("LATEST RESULT", a.latestResult(fallback: runA.latest), b.latestResult(fallback: runB.latest))
                    row("DURATION", LabFormat.duration(a.end?.durationSec), LabFormat.duration(b.end?.durationSec))
                    row("EXIT", exit(a, runA), exit(b, runB))
                    row("COMMAND", argv(envA), argv(envB), mono: true)
                    row("CODE", LabFormat.codeState(envA?.snapshot), LabFormat.codeState(envB?.snapshot), mono: true)
                    row("PARAMETERS", "\(envA?.params.count ?? 0) captured", "\(envB?.params.count ?? 0) captured")
                    row("DECLARED DATA", "\(envA?.dataFiles.count ?? 0) fingerprints", "\(envB?.dataFiles.count ?? 0) fingerprints")
                    row("ENVIRONMENT", LabEnvFacts.summary(envA?.env) ?? "—", LabEnvFacts.summary(envB?.env) ?? "—", mono: true)
                }
                Section("Parameter delta · exact non-empty lines") {
                    if let pa = a.firstParameterText, let pb = b.firstParameterText {
                        let delta = LabParameterDelta(pa, pb)
                        if delta.identical {
                            Label("Captured parameter lines are identical.", systemImage: "equal.circle").foregroundStyle(.green)
                        } else {
                            Text("ONLY IN \(runA.id)").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                            LabCodeBlock(text: delta.onlyA.isEmpty ? "nothing" : delta.onlyA.joined(separator: "\n"))
                            Text("ONLY IN \(runB.id)").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                            LabCodeBlock(text: delta.onlyB.isEmpty ? "nothing" : delta.onlyB.joined(separator: "\n"))
                        }
                    } else {
                        Text("Both runs need a captured parameter file for a literal delta.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } else {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        .navigationTitle("\(runA.id) ↔ \(runB.id)")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            lab.loadDetail(card, run: runA.id, force: true)
            lab.loadDetail(card, run: runB.id, force: true)
        }
    }

    private func head(_ run: LabRunSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(run.id).font(.headline.monospaced())
            Text(run.phase.rawValue.uppercased()).font(.system(size: 9, weight: .bold)).foregroundStyle(run.phase.color)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
    }

    private func row(_ label: String, _ a: String, _ b: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(.system(size: 10, weight: .bold)).tracking(0.6).foregroundStyle(.secondary)
                if a != b { LabTag(text: "DIFFERS", color: .orange) }
            }
            HStack(alignment: .top, spacing: 10) {
                Text(a).frame(maxWidth: .infinity, alignment: .leading)
                Text(b).frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(mono ? .caption.monospaced() : .caption)
            .textSelection(.enabled)
        }
    }

    private func argv(_ env: LabEventData?) -> String {
        let s = env?.argv.joined(separator: " ") ?? ""
        return s.isEmpty ? "—" : s
    }

    private func exit(_ d: LabRunDetail, _ run: LabRunSummary) -> String {
        if let code = d.end?.exitCode { return String(code) }
        return run.exitCode >= 0 ? String(run.exitCode) : "—"
    }
}
