# Argus Lab (`ut lab`) — design

This document describes the research layer of Argus. The design was agreed on 2026-07-08; the core protocol, broker routes, macOS hub, and Android hub are now built. The status section at the end distinguishes shipped behavior from remaining limits. DESIGN.md covers the base system that this layer sits on.

## Purpose and premise

Argus Lab is a protocol layer for ML research carried out by coding agents. It has two parts. The first part is a CLI called `ut lab` that agents use to run and report experiments. The second part is the Lab pane in the Argus app, where the human sees every experiment on every machine, approves experiments before they run, and annotates or hides anything an agent wrote.

The design follows from one premise. Agents cannot be trusted to remember what they did, to report it correctly, or to interpret results correctly. They lose their context on compaction, they skip source control, they speculate about old results instead of looking them up, and they pick timid parameters. So everything that matters is either recorded automatically by tooling at execution time or written by the human. The human owns the policy: they can decide each gate interactively or explicitly pre-authorize Lab gates for a period with Unattended Mode.

## Rules

1. Provenance is captured mechanically by the run wrapper. The system never depends on an agent remembering to report what it ran.
2. Agents can only add information. Commands for editing or deleting do not exist in the agent-facing CLI.
3. Nothing is ever deleted, by anyone. The human can hide content, which removes it from agent-facing reads and from default hub views, but every store keeps everything it has ever stored.
4. Agents cannot write anything that another agent will see. All cross-cutting knowledge is written by the human. Information moves between agents only when the human writes a note.
5. Every agent works inside one experiment set, and access to a set goes through a key that the human approved. Two agents on the same repository get two separate sets, so one agent's mistakes never reach the other.
6. Real experiments require human authorization before they start, under a policy the human sets on each set. Authorization is either an individual decision or the human's explicit, revocable Unattended Mode pre-authorization.
7. The tool promises a complete record of everything that went through the wrapper. The gaps in that promise are listed in the Limits section. It does not promise perfect reruns. It promises that what produced a result is recorded, and that drift since then can be inspected.
8. The tool never writes to a git repository. Every git operation it performs is a read.
9. The guiding rule for what to store is the minimal information needed to reproduce a run. Storage space is not the constraint.
10. The data format is an append-only log of events plus files stored exactly as they were given. There is no rigid schema. Structure can grow later out of real usage.
11. The core is agent-agnostic. Nothing load-bearing depends on Claude Code or on any other specific product. Product-specific conveniences may exist later as optional adapters.

## Hierarchy and access

A project contains experiment sets. A set contains runs, and runs can carry a group label so the agent can organize a sweep separately from an ablation. A group is nothing more than a label, and it exists as soon as the first run uses it. Every set and every run has its own append-only event log.

A set is the isolation boundary and the unit of assignment. The human creates a set when assigning work to an agent. Access works through a key. Either the human creates the set in the hub and hands the key to the agent, or the agent runs `ut lab login`, which files a key request that appears in the hub and on the phone, and every other command fails until the request is authorized. Ordinarily the human approves it individually. When the human has explicitly enabled Unattended Mode, the Mac broker approves it on their behalf and records that fact on the key. One key corresponds to exactly one set. Every `ut lab` command carries the key, through the `UT_LAB_KEY` environment variable or through a `--key` flag. The human can list keys and revoke any key at any time. If an agent loses its key after compaction, it runs login again and the request goes through the same authorization path.

A set belongs to one stable Lab store, and its key is authorized against that store rather than against the hostname that requested it. Any machine mounting the same store can use the key. This is essential on Babel, where `babel-*` nodes change while the NFS home—and therefore the Lab store—stays the same. The request hostname remains provenance only. Every proposal and run records the node that actually executed it, so a set may contain runs from several nodes without losing attribution. A machine using an unrelated store cannot use the key; moving work there requires mounting the original store or requesting a new set.

A project is a label and nothing more. When an agent requests a key, the request suggests a project name taken from the folder it ran in, and the human can keep or change that name during approval. The folder path is recorded as metadata and plays no role in identity. This is how one project checked out in three places still shows up as one project in the hub.

## Data format

Everything is stored as events. An event has a unique id, a time, an author, a kind, free text, and optionally attached files. The author is the human, the agent, or the machine. Event ids are ULIDs, which are unique without coordination and sort by creation time.

Each event is written as its own file, created exclusively and then renamed into place. There are no shared append files, because several cluster nodes can serve one NFS home at the same time and concurrent appends to a single file interleave on NFS. Reading a log means reading a directory of small files in id order. Merging two copies of a log is a union by event id.

Attached files, such as parameter configs, are stored exactly as given, together with a sha256 checksum. They are never parsed into a database structure. The current state of a run or a set is whatever results from reading its events in order. Hiding is an event too, authored by the human, and agent-facing reads and default hub views skip hidden content.

Small artifacts, such as plots and CSV files, are stored in the record directly. Large artifacts, such as checkpoints, stay where the job wrote them, and the record keeps their path, size, and checksum. The Durability section says what that means for their lifetime.

Human-owned settings, such as the set's approval policy and the snapshot size caps, are stored as human events on the set, and the latest one wins. This keeps configuration inside the same format as everything else.

## The run wrapper

The agent starts every execution through the wrapper.

```
ut lab run --tier full --params conf.yaml --data-files /abs/path/train.jsonl -- python train.py ...
```

Before the job starts, the wrapper records the command line, the working directory, the machine, the start time, and, when they exist, the hostname and tmux session name as advisory metadata. It records the code as three read-only pieces. It reads the current commit id with `git rev-parse`, captures all uncommitted tracked changes with `git diff --binary HEAD`, and lists untracked files that are not gitignored with `git status --porcelain --no-optional-locks`, archiving those files itself. No git object is ever written, so the repository is untouched and concurrent git commands are never blocked. Files above a per-file size cap are not archived. The record instead keeps their name, size, and checksum, and states plainly which files were skipped. The default caps are 25 MB per file and 200 MB per snapshot, and the human can change them per set.

The `--data-files` flag takes the full absolute path of every data file the run uses, and the command rejects relative paths. Each listed file is hashed when the run starts and hashed again when it ends. A mismatch produces a flagged event, which turns a file changing mid-run from a silent race into a recorded fact. A file the agent does not declare is invisible to the record, and the Limits section covers that gap.

The wrapper stores the parameter files exactly as given, records the environment, meaning the Python version, the package list from uv or pip, and the GPU and host information, and then starts the job. It tees the job's full stdout and stderr into a log file inside the run directory, capped at 50 MB by default, keeping the beginning and the end when it has to truncate the middle. It scans the output stream for W&B run URLs with the same parser rules the Argus clients use, ported to Go, and links any run it finds. When the job ends it records the end time and the exit code.

The run id prints the moment the run starts. The agent uses that id afterward to append partial results, updated tables, artifacts, and notes, for as long as the experiment lives. The log tail stored in the record is a preview for debugging. The results are what the agent appends plus the artifacts.

A wrapper can disappear before it writes `run-end` even though the underlying process later stops. The human can correct that orphaned lifecycle with `ut lab mark-stopped <set> <run> --reason ...` or the equivalent guarded control in either native client. This appends a human-authored `run-stop` event only after the human confirms that the process or remote job is already absent. It sends no signal, fabricates no exit code, and folds to the neutral status `stopped`, distinct from both a successful `run-end` and a failure. The explanation is required and retained in the event stream. If a delayed machine-authored `run-end` subsequently arrives, its mechanical outcome supersedes the manual correction. Archive remains a separate reversible view flag and never closes a run.

`ut lab diff R12` compares the recorded base commit, parameter files, and declared data hashes with the present, and calls out when the run carried an uncommitted snapshot. The recorded environment remains available through `ut lab show` and the hub. This is the command for the moment, weeks later, when a result no longer makes sense.

## Proposals and approvals

A full experiment does not start on the agent's say-so. When the agent starts a full-tier run, the tool first files a proposal containing a one-line statement of intent, the complete parameters, and the code snapshot, all captured at that moment. The command polls for the decision for ten minutes. If the human approves within that window, the run launches immediately. Otherwise the command exits and prints the proposal id, and after approval the agent launches it with `ut lab run --proposal <id>`. In both paths, the launch step recomputes the code and parameter hashes and refuses to start if they no longer match what was approved, in which case it files a fresh proposal. A denial can carry a note from the human, and the agent sees it. Pending proposals appear in the brief, so an agent that lost its memory finds them again.

The human sets a policy on each set. The policy requires approval for every run, or only for runs declared as full, or for none. When the policy is full-only, the `--tier` flag is required and the command errors without it, so the agent must make a conscious declaration on every run. Every run through the wrapper is logged whatever the policy says, including small data-processing runs. A run that was declared quick but ran for six hours is still fully recorded, and its duration and machine are visible in the hub afterward.

There is no automatic detection of what counts as a real experiment. No reliable mechanism for that exists, so the boundary is the human's policy plus the agent's declaration, with everything logged either way.

Unattended Mode is a durable switch owned by the Mac broker. While it is on, the broker sweeps the distinct online Lab stores and approves pending key requests and run proposals with a fixed audit note. It collapses brokers by reported store identity and treats `babel-*` as one shared NFS store, so a single logical request is not decided once per cluster node. Existing proposal bind hashes are unchanged: launch still recomputes the approved code and parameter identity and refuses drift. The switch can be controlled from macOS or Android, remains effective while the native UI is closed, and is off by default. Its first version does not answer free-form terminal questions.

## Human notes and attribution

The human writes notes at six scopes, which are global, per project, per machine, per set, per group, and per run. Notes hold standing context, such as available compute and credits, environment preferences, instructions about parameter scale, and warnings about specific machines, and the guidance can differ per experiment. Only the human writes notes. Nothing an agent writes ever becomes shared knowledge on its own.

Attribution follows a practical rule with known limits. Writes from the hub or the phone are the human. Writes from the CLI are recorded as the agent. A separate command, `ut lab hnote`, records a human-authored note from a terminal. It is documented here, in the Argus repository, and deliberately kept out of the instruction files agents read in research projects. This does not survive a determined impersonator, and it is not meant to. The threat is sloppiness, not deception.

## The brief

`ut lab brief` prints the record for the key's set. It prints the human notes that apply, in scope order from global to run, then the set's description and policy, then one line per run with the id, the group label, the status, and the most recent appended result, then any pending proposals and recent denials with their notes. Its length is whatever that content adds up to. Detail on one run comes from `ut lab show R12`.

The only thing asked of the agent's own memory is one line in the project's instruction file, which `ut lab init` writes, saying to run the brief at the start of work and whenever unsure. Instruction files are the one thing every agent reads again after losing context.

## Storage, brokers, and sync

The store is a directory that may be local to one machine or mounted by several machines. It has a persistent `store-id` used as the authorization and aggregation boundary, and the following shape.

```
~/.argus/lab/
  store-id                     stable identity shared by every mounting node
  sets/<set-id>/
    events/<ulid>.json         set-level events, one file each
    runs/<run-id>/
      events/<ulid>.json       run-level events
      files/                   params and small attachments, stored verbatim
      snapshot/                base sha, diff patch, untracked archive
      log.txt                  the teed job output, size-capped
  notes/<scope>/events/<ulid>.json    human notes pushed from the Mac
  keys/<key>.json              one file per key, rewritten whole and renamed
                               into place so a status change is atomic on NFS
```

On Babel the home directory is shared across nodes over NFS, so the whole cluster shares one store and one set-bound key works from every node. The one-file-per-event rule is what makes concurrent use safe. A key-request hostname is retained for provenance, while each proposal and run carries its current execution hostname.

The broker gets lab routes in the same style as the file and history services, covering the set list, keys, key decisions, briefs, and raw events. Those routes exist for the hub and the phone. The CLI itself operates on the store files directly, which is safe because every write is an exclusive create or a rename, so it does not matter how many processes write at once. A consequence worth naming is that `ut lab` works even on a machine where no broker is running yet; only remote viewing needs the broker.

The hub reads from every broker that is online, the same way session history works. The permanent mirror is kept by the Mac's broker rather than by the app, so it grows even while the app is closed. A mirror loop, on by default on macOS and forced on or off with UT_LAB_MIRROR, sweeps every five minutes, discovers peers through the mesh, and copies each set's latest brief plus every event it has not seen before, idempotently by event id, under mirror/ in the local store. The same always-on broker owns Unattended Mode and, while enabled, sweeps distinct online Lab stores every five seconds for pending gates. The mirror never expires and, given rule 3, never shrinks. The hub shows an offline machine's sets from this mirror, read-only and labeled as such. Human notes are written from the hub and posted to the broker of the machine they apply to, which therefore must be online at that moment; queuing a note for an offline machine is future work, listed under Limits. As an option, a configured rclone remote gives a second copy of a store in cloud storage. Git is not involved anywhere in this path.

## Durability

Events, parameter files, snapshots, and small artifacts live on the host and in the Mac mirror, and optionally in the cloud copy. They survive the death of any one machine once the Mac has polled it. Large artifacts live only on the host, referenced by path and checksum, and they die with the machine unless the cloud backup is configured to include them. The full output logs live on the host and are mirrored up to the mirror's own size cap per run.

## The hub pane

Most of the hub is composition over things Argus already has. An overview lists projects and sets, with each set showing its store, an online broker route, its status, and a link to the terminal named in its advisory metadata when that session still exists. A table of runs shows parameters, group, status, actual execution machine, and the latest reported result. Opening a run shows the recorded envelope, the code snapshot rendered as a diff in the existing git viewer, artifacts that open in Files, the linked W&B run in the existing W&B view, the capped log, and the full event timeline. An approvals inbox lists pending key requests and run proposals, on the Mac and on the phone, through the same notification path that announces waiting agents today. Everywhere in the hub the human can hide content and attach notes. There is no training-curve viewer, because W&B already does that job and the record links to it.

## Limits

These are properties of the design, stated so nobody discovers them by surprise.

1. Nothing forces an agent to use the wrapper. An agent can run a job directly and bypass the record. The enforcement is the working contract that results only count when they exist in the hub with a run id, plus the instruction file that says so.
2. Append-only and set isolation hold at the CLI surface. The store is plain files owned by the same unix user the agent runs as, so a process can read or edit them directly. The Mac mirror detects tampering with anything it already pulled. Tampering before the first pull is not detectable.
3. Data provenance covers declared files only. A data file missing from `--data-files` leaves no hash in the record. The record shows what was declared, so the gap is at least visible.
4. Attribution of human versus agent on a shared shell follows the practical rule above and cannot prove identity.
5. The terminal link on a set is advisory metadata and can go stale.
6. A human note can only be written to a machine that is online at that moment. There is no queue that delivers it later, so a note meant for an offline machine has to wait until the machine returns.
7. Unattended Mode can only act while the Mac broker is awake and can reach the source broker. Turning it off prevents future automatic decisions but cannot revoke approvals already written; those remain visible and can be handled with the normal revoke and archive controls.
8. Marking a run stopped records a lifecycle correction only. It cannot prove that an external process is absent and deliberately performs no process-management action; the UI requires the human to confirm that check.

## Build order

1. This document.
2. The CLI core, meaning login, brief, show, run, note, hnote, diff, and init, with the wrapper, the local store, and the broker routes, and no UI. Dogfood on the pause-prediction project, which has every problem this design is aimed at.
3. The approval flow, with approval from a local command first.
4. The hub pane, read-only at first, then the approvals inbox and the phone flow.
5. Curation, meaning hide and the scoped notes editor.
6. Optional pieces afterward, such as product-specific adapters and the rclone backup.

The CLI comes before any UI because the CLI alone shows whether the protocol changes how agents behave on a real project.

Status as of 2026-07-15: steps 1 through 5 are built on both macOS and Android. The desktop pane is a master-detail experiment browser: a sidebar of pending decisions, projects, sets, and runs, and a full page per selection. A run's page shows its results, log, parameter file contents, exact commit plus the colored diff of uncommitted changes, declared data files with drift flags, and environment, all served by the `/lab/file` route; it offers approve and reject for pending proposals, jumps to the agent's terminal and to the folder in Files, supports two-run comparison with a parameter diff, and can append a guarded manual stop event for an orphaned lifecycle. The set page has the notes editor, runs table, policy dropdown, and key revocation. Unattended Mode is broker-owned, off by default, auditable, store-deduplicated, and controllable from Lab, Settings, and Command Center on both native clients.

Android has a native, theme-aware phone flow for the same protocol: approval inbox and evidence dossiers, the research/set/run ledger, artifact inspection, two-run comparison, policy and key controls, guarded manual lifecycle correction, archive/restore, offline Mac mirrors, and guidance at network, machine, project, and set scope. Lab gates are merged into the Android Command Center and open exact dossiers from system notifications. Its store reducer uses broker-reported store identity and an explicit `babel-*` shared-store fallback, so an NFS-backed experiment, key, or proposal appears once while terminal actions route to the proposal/run's recorded execution node. Still open: the W&B run opens in the browser rather than an in-app view, rclone backup, and product-specific adapters.
