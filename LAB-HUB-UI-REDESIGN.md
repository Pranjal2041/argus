# Argus Lab Hub UI Overhaul

Status: implemented and verified on 2026-07-10  
Branch: `lab-hub-ui-overhaul`  
Scope: macOS Lab hub presentation, its Swift/WebKit bridge, and read-only access to already-mirrored events; Lab storage semantics are unchanged

## Product thesis

The Lab hub is the human's research desk for agent-run experiments. It has three jobs, in this order:

1. Put decisions that require the human in front of them immediately.
2. Turn a run into an intelligible research record: what was attempted, what happened, and whether the result is trustworthy.
3. Preserve and distribute human guidance without letting agent-authored claims silently become shared truth.

The interface should therefore feel like a scientific instrument and a field notebook, not a generic operations dashboard. The primary unit is evidence, not a card. The primary action is judgment, not navigation.

## Diagnosis of the current hub

The existing hub is functionally broad, but its presentation obscures what makes Lab special.

- It uses a by-the-book Material dark theme: uniform gray surfaces, rounded cards, pills, and stat tiles. Nearly every piece of information has the same visual weight.
- The 1.5x nested rail lists every project and every run. It consumes too much of the already-narrow main pane and becomes unscannable as the experiment count grows.
- The home page leads with three aggregate counts. Those numbers are less useful than the actual decision queue, active runs, recent failures, and recent findings.
- A pending approval and the evidence required to make that decision live in one long scrolling document. The decision controls can become spatially separated from the code, parameters, command, and data fingerprints being approved.
- Project pages call a set a project. Two isolated sets with the same project label can therefore look like duplicate or conflicting projects instead of separate assignments.
- A completed run reads as a pile of equal cards. Its conclusion, failure, provenance, log, parameters, and event history do not form a research narrative.
- Status is represented repeatedly as outlined pills with tiny colored dots. The page looks busy without making attention priorities clearer.
- Notes, archive controls, policy, key status, and run comparison are present, but their placement reflects implementation order more than the user's mental model.
- Five-second data pushes rebuild most of the page. Draft preservation is partially patched in, but tabs, disclosure state, sub-scroll positions, and running-run details are not robust live state.
- Narrow layouts hide the rail but do not replace it with a complete navigation model.
- Several controls only appear on hover, which is poor for discoverability, keyboard use, and accessibility.

## North-star direction: Instrument Ledger

The visual concept is a midnight scientific ledger: part lab notebook, part precision instrument, part mission log.

It is dark by default, but not "dark Material." The canvas is a restrained derivative of the selected Argus theme, preserving the neutral instrument surface instead of flooding the page with the theme hue. Hairlines and a very faint graph-paper texture establish measured space. Color is semantic: orange for work awaiting judgment or launch, blue for live execution, green for verified completion, and red/coral for failure or drift.

The interface's memorable element is the **evidence spine**. Every run shows its lifecycle as one continuous line:

```text
PROPOSED ─── APPROVED ─── STARTED ─── ENDED
   intent      bind          host        result
```

The spine is compact on a table row and expands on the run page. It makes the append-only event model visible without exposing event-log mechanics everywhere.

### Tone

- Precise, editorial, calm, and serious.
- Dense enough for research work, never cramped.
- Human judgment is warm and prominent; machine metadata is cool and restrained.
- No decorative science clichés, fake gauges, glowing green terminal tropes, glass cards, or gradient spectacle.

### Visual tokens

The fallback palette below is used by static fixtures. In the app, the Theme Picker is the source of truth: Lab derives its surfaces from the selected palette and maps the theme's status colors consistently.

| Token | Value | Use |
|---|---:|---|
| Canvas | `#111319` | Main background |
| Canvas grid | `rgba(167, 176, 192, .025)` | 24px graph-paper texture |
| Surface | `#181b22` | Navigation and grouped regions |
| Raised surface | `#20242c` | Decision dossier and active selection |
| Hairline | `#333943` | Structure, tables, separators |
| Primary text | `#f0ede6` | Warm reading color |
| Secondary text | `#adb3bc` | Metadata and explanations |
| Quiet text | `#747d89` | Inactive and archived state |
| Accent | `#8fb8e8` | Selection, focus, navigation, links |
| Decision | `#e8ad4c` | Needs-human-attention |
| Queued | `#d88b5b` | Approved and awaiting launch |
| Live | `#64bfd2` | Running and streaming |
| Verified | `#72c98c` | Successful and unchanged evidence |
| Danger | `#e7736a` | Failure, rejection, drift, revoke |
| Link | `#8fb8e8` | Navigation to Terminal, Files, W&B |

The runtime mapping is `accent → navigation`, `attached → verified`, `running → live`, `waiting → needs approval`, `unseen → queued`, and `unreachable → failure`. Status color is never the only carrier of meaning: table rows retain explicit labels, lifecycle nodes retain text, and set rows show an ordered multi-signal cluster with accessible descriptions.

### Typography

- Titles, intent, conclusions, and body copy: SF Pro Display/Text with controlled weight rather than an editorial serif.
- Interface and tables: SF Pro/SF Compact, with deliberate use of condensed uppercase labels for structure.
- Commands, paths, hashes, run IDs, and parameters: bundled `MesloLGS NF`.
- No network font dependency. The entire Lab pane remains offline-capable.
- The default type scale is approximately 1.25–1.35× and adapts to both pane width and height.
- `A−`/`A+`, `⌘−`/`⌘+`, and reset controls provide a persistent 0.8–1.4× personal adjustment on top of the adaptive scale.
- Responsive breakpoints use effective width after scaling, so increasing text triggers reflow instead of horizontal clipping.

### Shape and depth

- Primarily flat regions separated by hairlines and space.
- 6-8px corner radii only where a bounded interactive object benefits from one.
- Cards are reserved for decision dossiers, warnings, and empty states—not every section.
- Status appears as a short word, a tick on the evidence spine, or a narrow row marker—not as a pill repeated throughout the page.

## Information architecture

The current recursive project/run rail is replaced by three persistent Lab destinations:

1. **Inbox** — access requests and experiment proposals requiring a decision.
2. **Research** — projects, isolated sets, runs, comparisons, and archive.
3. **Guidance** — human-authored notes by audience.

At launch:

- Open Inbox when anything needs a decision.
- Otherwise return to the user's last Lab destination and selection.

Archive is a Research filter, not a fourth primary destination. Global Lab navigation lives in a compact top masthead so the pane does not create a second oversized sidebar beside Argus's existing 272px application sidebar.

### Wide layout

```text
┌ LAB / ARGUS ───── Inbox 3 ─ Research ─ Guidance ───────── synced 8s ┐
├──────────────────────────┬───────────────────────────────────────────┤
│ destination-specific     │                                           │
│ index / queue            │ selected dossier, project, run, or notes │
│ 220-280px                │                                           │
└──────────────────────────┴───────────────────────────────────────────┘
```

The left column changes meaning with the destination:

- Inbox: pending decision queue.
- Research: project labels with explicit set/machine children, plus filters.
- Guidance: audience/scope navigator.

It never contains every run in the fleet.

### Compact layout

Below roughly 800 effective CSS pixels of Lab-pane width:

- Keep the masthead and primary destinations.
- Replace the contextual left column with a toolbar button and an overlay drawer.
- Use a single content column.
- Keep approval actions in a sticky bottom decision dock.

The actual minimum case is a 980px Argus window with its 272px application sidebar visible, leaving approximately 708px for Lab. This is a first-class target, not an edge case.

## Screen specifications

## 1. Inbox

Inbox is a split queue and review dossier.

### Queue

Pending items are grouped into:

- Experiment approvals
- Access requests

Each row shows only what differentiates it:

- Intent or request type
- Project
- Machine
- Run ID when applicable
- Age

The selected row uses a solid inset marker rather than a filled pill. Keyboard `J`/`K` moves through the queue and Return opens the item. Approve/reject shortcuts may focus the decision controls but must not execute a decision immediately.

### Experiment approval dossier

The first screenful contains:

1. The proposed intent as a large serif statement.
2. Run, project, set, machine, tier/group, folder, and terminal link.
3. A compact trust matrix:
   - exact command
   - base commit and uncommitted-change status
   - parameter files
   - declared data fingerprints
   - captured environment
4. Expandable code and parameter evidence.
5. A sticky decision dock with optional message, Reject, and Approve.

The dock remains visible while evidence scrolls. Approve is the dominant action only on this screen. After a decision, show a brief confirmation and advance to the next pending item.

### Access request dossier

It explains the isolation boundary in one short paragraph, then shows:

- Agent session
- Machine
- Folder
- Suggested project label, editable before approval
- Resulting guarantee: one key, one isolated set, machine-bound

Open Terminal is secondary. Approve and Deny use the same decision dock pattern.

## 2. Research

Research is a scalable index, not a card gallery.

### Research navigator

- Search projects, machines, folders, run IDs, groups, and latest result text.
- Group by project label.
- Show each isolated set explicitly beneath its project as `machine / set-id`.
- Mark offline mirrored sets honestly with their mirror age.
- Offer filters for Active, Needs review, Failed, Finished, and Archived.

The same project on two machines should read as one research topic with two isolated assignments, not as accidental duplicate project cards.

### Project/set page

The masthead shows:

- Project name in editorial type
- Machine, folder, set ID, online/offline state
- Active key state
- Approval policy

Policy, key revocation, and archive belong in an **Access & policy** menu near the masthead. Revocation remains confirmed and visually dangerous.

Human guidance appears as a slim context strip with an Edit Guidance action, not as the first large card on every project.

Runs appear in a dense ledger with columns:

- Run
- Phase/status
- Tier and group
- Latest reported result
- Started
- Duration/exit when known

Filtering and sorting remain visible. Comparison selection is an explicit `Compare` mode rather than permanently showing checkboxes in every row.

## 3. Run record

The run page is organized around research meaning.

### Header

- Project / set / run breadcrumbs
- Run ID and plain-language phase
- Evidence spine
- Intent, when present
- Command in monospace
- Actions: Terminal, Files, W&B, Compare, Archive

### Result first

For completed runs, the latest reported result is the largest content after the title. For failed runs, the failure and log tail take precedence. For running runs, elapsed time, latest result, and live log tail take precedence.

### Evidence tabs

Use tabs rather than a long stack of equal cards:

1. **Summary** — result, duration/exit, W&B, dataset integrity, machine/environment facts.
2. **Parameters** — every captured parameter file, with paths and selectable contents.
3. **Code** — base commit, clean/dirty statement, colored diff.
4. **Log** — tail by default, with clear truncation/storage language.
5. **Provenance** — complete event timeline, environment freeze, fingerprints, bind hash.

The chosen tab persists through polling. Code/log regions have their own stable scroll positions.

Stored artifact rows in Provenance are controls, not passive labels. Selecting a log, diff, event record, environment freeze, or captured parameter file opens an inline text preview; binary archives clearly explain why they cannot be rendered in place.

### Human curation

- Add a human note directly to a run using the already-supported run note scope.
- Agent results can be hidden with an always-discoverable overflow action; hiding remains reversible in the record and never says delete.
- Archived state is visible but does not dim content to unreadability.

### Live behavior

- Pending and running run details re-fetch while visible.
- A polling update must not reset selected tab, text drafts, disclosures, selection, or scroll position.
- Running transitions to finished/failed in place, with a restrained one-time state animation.

### Offline record

An offline mirrored record is visibly read-only. The masthead says when it was last mirrored. Actions requiring the source machine are disabled with an explanation, not silently removed.

## 4. Compare

Comparison is a research-difference view, not merely two generic columns.

- Fixed headers for run A and run B.
- First section: result, status, duration, exit, code state, and command.
- Parameter delta grouped by file; unchanged sections collapse.
- Declared data and drift differences.
- Code base/diff differences when available.
- Links back to either complete run.

The existing exact-line set comparison can remain as a first implementation, but its UI must label it honestly rather than implying semantic config understanding.

## 5. Guidance

Guidance treats notes as instructions with an audience.

### Audience navigator

- Everywhere
- One machine/store
- One project on a machine
- One writable experiment set, with an inheritance trail back through project, machine, and network guidance

Run-specific human notes remain on the run record. Group scope stays out of the UI until the broker implements the group audience promised by `LAB-DESIGN.md`; the interface must not offer a selector that silently writes at a broader scope.

The composer always states in plain language exactly who will read the note before it is submitted.

### Notes ledger

Each row shows:

- Note text
- Audience
- Machine/store
- Author
- Timestamp
- Active or hidden state

Hidden notes remain visible to the human in an Archive filter. Hide is an explicit row action, not hover-only. Agent-authored set notes are visually distinct from human ground truth and never share the same authority treatment.

## Component language

### Masthead

Compact, fixed-height, and stable. Contains the LAB mark, destination tabs, pending count, refresh/sync state, and contextual drawer button on compact layouts.

### Evidence spine

Four lifecycle nodes derived from existing events. Nodes can be complete, current, rejected, failed, or absent. Each has a text label and timestamp; color supplements state.

### Ledger row

Flat row with strong alignment, hairline separators, and a narrow semantic marker. Hover may enhance it but cannot reveal the only route to an action.

### Decision dock

Sticky bottom region within the dossier. Optional human message on the left; secondary Reject and primary Approve on the right. Focus and keyboard behavior are explicit.

### Evidence block

Selectable monospace content with a labelled header, copy affordance, byte/truncation disclosure, and stable internal scroll.

### Status words

Use stable product vocabulary:

- Needs approval
- Approved · awaiting launch
- Running
- Finished
- Failed · exit N
- Rejected
- Recorded
- Offline copy

Do not expose backend status strings directly in presentation code.

## Motion

Motion is restrained and functional.

- One 160-220ms content transition when the selected queue/run changes.
- Evidence-spine current node may breathe slowly for Running.
- A completed decision collapses from the queue and advances selection.
- No repeating shimmer after initial load, no animated gradients, and no page-wide entry animation on every five-second refresh.
- Honor `prefers-reduced-motion` and reduce all state changes to instant opacity swaps.

## Accessibility and input

- Semantic `nav`, `main`, tables, headings, buttons, forms, and status text.
- Visible `:focus-visible` treatment in the decision color.
- Every icon has text or an accessible label.
- No hover-only action.
- Minimum 4.5:1 body-text contrast and 3:1 large/status contrast.
- Status is always encoded by text and shape in addition to color.
- Keyboard order follows the visible reading order.
- `J`/`K` queue navigation, Return to open, `/` to search; action shortcuts only focus controls.
- Escape closes drawers, menus, and Compare mode before leaving the Lab pane.
- Text selection remains enabled for results, commands, paths, parameters, diffs, and logs.

## Responsive and scaling behavior

Replace CSS `zoom` with a root font-scale custom property and rem-based sizing. `zoom` currently forces JavaScript-specific breakpoint math and makes the nested rail disproportionately large.

Test all screens at:

- Full default window: 1440x900, approximately 1168px Lab width with Argus sidebar.
- Minimum window: 980x600, approximately 708px Lab width with Argus sidebar.
- Detail-only Argus layout at 980x600.
- UI scale: 80%, 100%, 150%, and 200%.

At high UI scale, collapse contextual navigation earlier; never shrink text or controls below their intended size to preserve a multi-column layout.

## Data and bridge changes

The backend already supplies almost everything required. The overhaul should keep the existing `window.UTLab` entry points and Swift message names where possible.

Extend the Swift-to-page model with data that already exists but is currently omitted:

- Pending proposal tier, group, command, and cwd.
- Run exit code.
- Set creation time and explicit set identity.
- Mirror timestamp for offline sets.
- Note timestamps and kinds in project/set summaries.
- Run-file manifest from `/lab/files` where useful.

Add UI-only bridge behavior:

- Run-scoped human notes.
- Set-scoped guidance, including hidden-state folding from set event logs.
- Refresh visible pending/running details.
- Open W&B in the in-app W&B view when possible.
- Coalesce the four independent published-value pushes into one visual update.
- Return action success/failure to the page so it can show confirmation or an inline error instead of guessing after a timed refresh.

No storage-format or broker API redesign should be required.

## Frontend structure

Replace the 1,262-line single document with offline, dependency-free files:

```text
Resources/lab/
  index.html       semantic shell only
  style.css        tokens, layout, components, responsive states
  app.js           state, rendering, bridge, interactions
  fixtures.js      deterministic fixture catalog for every important state
```

If `app.js` becomes unwieldy, split it further without adding a bundler. The app already copies the whole resource directory.

Implementation rules:

- No CDN, framework, web font, or runtime network dependency.
- No inline style attributes in generated markup except values that are genuinely data-driven.
- Escape all broker-provided text before insertion.
- Centralize status parsing and presentation.
- Preserve drafts, selection, tabs, disclosure state, and scroll state independently from polled data.
- Avoid rebuilding the entire shell when equivalent data arrives.
- Keep the fixture harness usable outside the native app.

## Fixture and QA matrix

Add deterministic fixture destinations for:

- Inbox with several mixed decisions
- Access-request review
- Pending-run review with code and parameters
- Research with many projects/sets/runs
- Project with active, failed, completed, archived, and grouped runs
- Running run
- Successful run
- Failed run
- Offline mirrored run
- Two-run comparison
- Guidance with global/machine/project/set notes, inherited notes, and hidden notes
- Empty Lab
- Loading, partial-data, and request-error states

For every fixture:

- Capture default and minimum-size screenshots.
- Verify 80%, 100%, 150%, and 200% UI scale where layout changes.
- Check keyboard traversal and focus visibility.
- Check long paths, long commands, long intent, long result, and 50+ run rows.
- Verify every page action emits the expected Swift bridge message.
- Verify a five-second model refresh does not move the user's scroll position or erase state.

Native integration gates:

- `swift build` succeeds.
- The app opens Lab at the default and minimum window sizes without overflow.
- Terminal, Files, W&B, approve/reject, policy, archive, hide, note, compare, and revoke flows work against a real local broker.
- Offline mirrored sets are readable and all unavailable actions are explained.
- Existing Go tests remain green.

## Implementation sequence

### Phase 0 — baseline and contract

- Capture current fixture states before replacement.
- Freeze the current Swift/WebKit message contract in a small checklist or test harness.
- Add missing fixture data for failure, running, offline, large-scale, and long-content cases.

### Phase 1 — data model and shell

- Extend the pushed model with already-available fields.
- Split the frontend files.
- Implement tokens, masthead, destination routing, responsive contextual drawer, and stable client-side state.
- Do not wire every detail screen yet.

Visual approval gate: Inbox queue, Research index, pending dossier, and completed-run shell at 1440x900 and 980x600.

### Phase 2 — Inbox

- Build mixed decision queue.
- Build access and proposal dossiers.
- Add trust matrix, evidence previews, sticky decision dock, keyboard navigation, confirmation/error handling, and advance-to-next behavior.

### Phase 3 — Research and run record

- Build explicit project/set navigator and filters.
- Replace project cards with run ledger.
- Build evidence spine and status vocabulary.
- Implement Summary, Parameters, Code, Log, and Provenance tabs.
- Add running/pending detail refresh and state preservation.

### Phase 4 — Guidance and comparison

- Build audience navigator, composer, and notes ledger.
- Add contextual set/run human notes.
- Build honest two-run difference view and Compare mode.

### Phase 5 — polish and integration

- Empty/loading/error/offline states.
- Reduced motion, accessibility, focus, copy affordances, truncation language.
- Real-broker action verification.
- Native build and full screenshot matrix.
- Remove obsolete Material styles and legacy rendering paths.

## Acceptance criteria

The overhaul is complete when:

1. A pending decision is reachable in one click and its intent, command, code state, parameters, data, machine, and decision controls form one coherent dossier.
2. The default screen prioritizes decisions, active runs, failures, and recent findings rather than aggregate vanity counts.
3. The interface remains legible with at least 50 sets and 500 runs; the global navigation never lists every run.
4. Project labels and isolated sets are visibly different concepts.
5. A completed run communicates its result first and its reproducibility envelope through a stable evidence structure.
6. A five-second refresh never erases a draft, changes the selected evidence tab, collapses a disclosure, or jumps scroll position.
7. Every action is discoverable without hover and operable by keyboard.
8. Minimum-window and 200% scale layouts contain no clipped controls or unusable tables.
9. Offline data is unmistakably read-only and says when it was mirrored.
10. The pane has a distinctive Instrument Ledger identity and does not resemble a generic Material/SaaS dashboard.
11. All existing Lab behavior remains available, native integration builds, and Go tests remain green.

## Deliberate non-goals

- Changing the Lab event/storage model.
- Adding training charts that duplicate W&B.
- Inventing semantic parameter parsing in this pass.
- Adding a framework or build pipeline to the embedded page.
- Redesigning the rest of the Argus application.
- Building Android Lab UI as part of this macOS overhaul.

## Implementation outcome

- The former 1,262-line Material-style monolith is now a small semantic shell plus independent `style.css`, `app.js`, and `fixtures.js` resources.
- Inbox, Research, and Guidance implement the Instrument Ledger hierarchy, including decision dossiers, a sticky decision dock, cross-set run ledgers, the evidence spine, result-first records, failure-first logs, exact comparison, and audience-aware guidance.
- Client state preserves location, selection, drafts, tabs, disclosures, filters, and scroll positions across broker pushes. Running, approved, and pending records refresh their detail independently every five seconds.
- Broker mutations now return explicit success or failure to the page. Run notes carry both set and run IDs, complete note/run metadata crosses the bridge, stored-file manifests appear in Provenance, and W&B uses Argus's authenticated in-app surface when a session binding exists.
- Offline records are explicitly read-only. The bridge reads the append-only events already held by the permanent mirror; artifacts that are not mirrored remain labeled unavailable rather than being inferred.
- Deterministic fixtures cover approval, access, overview, set, completed, pending, running, failed, comparison, guidance, offline-detail, offline-summary, archive, and empty states.
- Visual QA used an isolated WebKit harness at default and minimum pane widths and at 200% UI scale. No running Argus instance was used for the final review.
- Verification completed with JavaScript syntax checks, bridge-payload smoke tests, debug and release Swift builds, `go test ./...`, `go vet ./...`, and `git diff --check`.
