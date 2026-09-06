# Argus CLI (Mac-local v1)

`argus` is the structured interface to the **running Argus Mac app**, intended for
a master agent coordinating the same workspace the human sees. It is separate
from `ut`: it does not replace terminal execution, browser tools, or the fleet CLI.

## Install and begin

The signed Mac build bundles `Contents/MacOS/argus-cli` (distinct from the app's
`Argus` executable even on a case-insensitive filesystem). `clients/macos/build-app.sh`
also links it at `~/.local/bin/argus`, without overwriting an unrelated executable.
No shell configuration is changed automatically.

```sh
argus status --json
argus capabilities --json
argus context --json
argus cc list --needs-attention --json
argus app show session '<session-id>'
argus app show notes
```

`cc` aliases `command-center`. Ordinary reads and data mutations do not navigate.
`app show` changes only the Argus view; **only `app activate` brings the app to the
foreground**. `app launch` explicitly launches the app in the background. Nothing
auto-launches when a connection fails. Agent navigation is not a human “seen” or
“acknowledged” event and does not clear attention badges.

The CLI and UI call the same `AppState`/Command Center/Weekly Progress model
actions. The CLI never edits preferences behind the app, simulates keystrokes, or
creates another state-owning daemon.

## Command families

Run `argus --help` for commands and `argus capabilities --json` for machine-readable
schemas, required arguments, positional arguments, flags, limits and supported views.

| Family | Scope |
| --- | --- |
| `status`, `doctor` | App/socket/version, cached machine health, persistence/sync issues; no permission prompts |
| `context` | Bounded cached briefing, attention, note previews, pending todos/plans, weekly job; no new model call |
| `events watch --after CURSOR` | Bounded replayable app changes as newline-delimited JSON |
| `app state/show/activate/launch` | Navigation and explicit activation/launch |
| `sessions list/get` | App-known sessions, stable lifetime IDs where brokers provide them, machine/path/health |
| `cc list/get/refresh/correct/backlog` | Shared Command Center cards, observed vs inferred state, pending Lab decisions |
| `notes list/get/create/update/complete/reopen/archive` | Notes Hub |
| `todos boards list/get/create` | Stable Todo Map IDs and machine/session associations |
| `todos items list/get/create/update/complete/reopen/archive` | Targeted todo edits |
| `planner list/get/create/update/complete/reopen/archive` | Dated commitments |
| `archive list/restore` | Recoverable CLI deletions, never overwrites a live record |
| `weekly-progress projects list/get/create/update` | Shared project definitions |
| `weekly-progress list/get/generate/resume` | Saved generations and app-owned execution |
| `jobs list/get/wait` | Inspect/wait for Weekly Progress work |
| `activity list` | Attributed action receipts, without document bodies |
| `sync conflicts/resolve` | Inspect and deliberately reconcile competing edits |

V1 does not include remote CLI transport, a Jarvis reasoning loop, arbitrary
computer control, workflow execution, full Git/Files panels, or artifact-library
CRUD. Those remain separate follow-up capabilities. Navigating to an existing app
view is not equivalent to exposing every action in that view. Existing credential
approvals are unchanged; this CLI has no vault plaintext retrieval or approval bypass.

## JSON contract, identities and editing

Responses contain `version`, `id` (request ID), `ok`, and either `result` or a
structured `error` with `code`, `message`, and optional `details`. `--json` prints
compact machine-readable JSON. Without it the same envelope is pretty-printed.
Error exit codes: `1` general, `3` edit conflict, `4` a waited job ended failed or
interrupted. Lists are paged (`--limit`, `--offset`, `next_offset`, `total`); they
do not silently present the first 50 as the complete collection.

Read an existing record to obtain its content revision, then pass `--if-revision`
when changing it. The revision reflects UI and sync edits too, not just CLI writes.

```sh
argus notes create --text 'Follow up on the experiment' --actor jarvis --json
argus notes get NOTE_ID --json
argus notes update NOTE_ID --if-revision REVISION --text-file ./updated-note.txt --json
argus todos items complete ITEM_ID --if-revision REVISION --json
argus planner create --title 'Submit report' --project 'Research' --deadline 2026-09-10 --json
```

`--text-file PATH` / `--document-file PATH` read UTF-8 input; `-` reads standard
input, avoiding shell interpolation. No supplied strings are executed as code.
Date-only deadlines use the Mac's local timezone and mean end-of-day. Exact
deadlines require ISO-8601 timestamps with a timezone.

Names are conveniences, not identities. Ambiguous sessions/projects return an
error with candidates. Sessions with a broker lineage ID retain their CLI ID on
rename; older brokers explicitly report `name_alias_legacy_broker`, which cannot
promise identity across a same-name session replacement. Paths belong to the
reported machine, not necessarily the Mac. Offline snapshots remain readable and
are marked with connection state.

Mutations accept `--request-id ID`. Reusing an ID with the same arguments and actor
returns the saved receipt. Reusing it for different input is an error. Supply your
own ID before sending when retry safety matters. A persisted reservation with no
completion receipt returns **`outcome_unknown`**, never blind replay: inspect the
target/job before proceeding. This is not a claim of distributed exactly-once execution.
Receipts retain at most 10,000 requests / 32 MiB; reaching the limit rejects new
mutations rather than silently forgetting retry history.

`complete`/`reopen` set explicit state, unlike UI toggle gestures. Archive restores
require the original ID to be absent and, for todos, the parent board to exist.

## Context and events

Take a context snapshot and use **its** `cursor`:

```sh
argus context --limit 20 --json
argus events watch --after CURSOR --json
```

Snapshot and cursor capture share the main-actor boundary. Changes between the
snapshot and subscription are replayed. Events are notifications to reread the
affected domain, not terminal-output streams. Model summaries are separate from
observed broker state. Context uses existing app caches; it neither dumps every
terminal nor requests another model summary.

Event replay retains 1,024 notifications and persists across app restarts. A cursor
outside retained history returns `cursor_expired`; take a new context snapshot.
There are at most eight waiting event subscribers and 32 accepted socket clients.
Long polls use suspended tasks, not blocked UI threads or additional fleet polling.
`durable: false` / status diagnostics expose event persistence failures.

## Weekly Progress

```sh
argus weekly-progress projects create --document-file ./project.json --json
argus weekly-progress generate --project PROJECT_ID --week 2026-08-31 --request-id weekly-2026-08-31 --json
argus jobs wait GENERATION_ID --timeout 600 --json
argus weekly-progress get GENERATION_ID --json
```

A project document accepts `name`, `panels` (`session`, optional `machineID`), and
`workspaceRoots`. It needs a name and at least one panel or workspace root. Project
creation/editing does not change the human's selected project. Week dates must be
Mondays. Generate returns after the durable manifest is created, not after research
finishes. CLI exit or wait timeout does not cancel the app-owned job. Restarted
unfinished work is `interrupted`, not successful; resume is explicit.

Results expose manifests and absolute **Mac-local** report/deck output paths.
Cancellation is explicitly not advertised: the current execution backend cannot
yet guarantee cancellation of its external agent process.

## Shared workspace persistence and cross-client safety

Notes/Todos/Planner/Workflows migrate from preferences to an atomically written
`~/Library/Application Support/Argus/workspace/state.json`. The UI and CLI share
this store; preferences remain a compatibility mirror. Sync baselines and preserved
conflicts live beside it. Action receipts/archives and event replay live under
`Argus/local-control/`. Files are user-private; these are ordinary workspace data,
not a new credential vault. Existing vault encryption and approvals are unchanged.

Mac and Android now use `/userdata/merge`: a record-ID three-way merge instead of
last-write-wins snapshots. Independent edits (including separate nested todo items)
merge. Competing values or delete-versus-edit produce a conflict and preserve both
copies. The broker rejects legacy overwrites of a merge-protected collection. **Roll
out the updated broker and Android client with the Mac build.** An old client must
not be used to edit these collections after migration.

The Mac has **Local Automation Activity…** in its menu, including **Review…** for
sync conflicts. Android displays a Review action in the affected feature. CLI
clients use `sync conflicts`, then `sync resolve KEY --if-revision REVISION
--document-file reviewed.json`. Review is an explicit merge against the shown
remote baseline, not permission to overwrite newer data. Local writes, pending
sync, confirmed sync, and conflicts are distinct states.

## Local trust boundary

The bundled CLI connects to `~/.argus/run/cli.sock` (private directory 0700, socket
0600). A singleton file lock prevents a second app instance stealing the endpoint;
both peers verify the effective OS user with `getpeereid`. No TCP listener, Tailscale
route, Accessibility, Screen Recording, Keychain request, or new secret token is
needed for this integration. `--socket` is an explicit local-path override for tests.

**Same-user access is not per-agent isolation.** `--actor jarvis` is attribution,
not authentication. Other processes running as this OS user can use this interface;
do not interpret the actor field as a security claim. The command allowlist does not
expose arbitrary shell execution, credential contents, or sensitive-action approval.

## Verification

```sh
(cd clients/macos && swift test)
go test ./...
(cd clients/android && ./gradlew :app:testDebugUnitTest)
```

Regression coverage exercises the same handlers through UI-model edits and
phone-style adoption, revision conflicts, persisted request replay, uncertain
receipts, stable/ambiguous session resolution, attention-preserving navigation,
event replay/expiry, actual Unix sockets, and the shared merge contract on Swift,
Go, and Kotlin paths. Native UI rendering is separately inspected before rollout.
