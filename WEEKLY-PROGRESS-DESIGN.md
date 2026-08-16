# Weekly Progress Pipeline

Status: pipeline and native Argus UI implemented.

## Purpose

Weekly Progress turns the Activity Journal and project evidence into a self-readable research deck for one project and one Monday-through-Sunday period. It is not a general presentation generator. Its job is to preserve what was tried, what was measured, what changed, and what remains uncertain well enough for personal review or a PI meeting.

## Core principles

1. **Evidence before slides.** Journal captures are first reconciled into a research report and claim ledger. A deck is never generated directly from raw activity snippets.
2. **Explicit project membership.** A project owns a list of panel selectors and workspace roots. One project can span machines and working copies; a panel selector without a machine follows that panel across Babel nodes.
3. **One durable agent conversation.** The research, draft, and repair turns resume the same Codex session. Every generation pins `gpt-5.6-sol` with `xhigh` reasoning and records the session ID.
4. **Verification is a gate.** A model saying “passed” is insufficient. Completion also requires a valid PowerPoint, a numbered PNG render for every slide, and an independent parse of the actual visible PowerPoint text. Objective language violations trigger another repair turn even when the model's own audit claims success.
5. **The successful interaction is replayed, not rewritten.** The pipeline contains the five actual user messages from Codex session `019f630d-5663-7722-bc65-5fd298a497ec`: research, initial slides, the self-readable rewrite, the font correction, and the final language correction. Their SHA256 hashes are pinned by tests. Argus adds only project/date mapping and durable file names.
6. **Versions are preserved.** Re-running the same week creates another generation instead of overwriting an earlier report.
7. **The UI is a reader of durable state.** Pipeline state lives in JSON files, so an Argus view can close, reopen, or observe a long generation without owning the agent process.
8. **Aggregation is virtual.** “All” reads the existing project manifests and rendered slides. It never creates a synthetic project, duplicates evidence, or merges decks on disk.

## Pipeline

1. Export matching journal events for the requested local-time week into `evidence/journal.jsonl`.
2. Ask the agent to write `research-report.md` and `evidence-ledger.json` after reconciling available workspace evidence.
3. Resume the session with the original slide request to create `draft.pptx`.
4. Replay the three original correction messages in order: rebuild the deck as a self-readable progress report, correct the unreadable font size, and correct the remaining unscientific language.
5. Require `weekly-progress.pptx`, its complete render, and `audit.json` after every correction turn.
6. Parse the visible text stored in the final PowerPoint and write `language-audit.json`. Colons, semicolons, double hyphens, em dashes, rhetorical `x, not y` formulas, and the unexplained terms explicitly named in the user's correction fail independently of `audit.json`.
7. If either audit or the concrete outputs are incomplete after the original sequence, resume with the exact machine-detected issues for another repair pass. The default maximum is three additional passes.
8. Mark the generation complete and let the existing seven-day Argus backup loop create cheap hard-linked recovery points.

## Storage

```text
~/Library/Application Support/Argus/weekly-progress/
  projects/<project-uuid>/
    project.json
    weeks/<monday-yyyy-mm-dd>/
      generations/<utc-timestamp>-<generation-id>/
        request.json
        state.json
        evidence/
          journal.jsonl
          summary.json
        research-report.md
        evidence-ledger.json
        draft.pptx
        weekly-progress.pptx
        audit.json
        language-audit.json
        render/final/*.png
        agent/
          *-prompt.md
          *.jsonl
          *.stderr.log
          *-final.txt
```

`state.json` is the integration boundary for the Argus view. It records the project snapshot, week, prompt revision, current stage, evidence counts, model, reasoning effort, Codex session ID, audit pass count, output paths, and any failure.

## Argus UI

The full-window Weekly Progress view exposes these operations over the core:

- create or edit a project by selecting either live panels or ended panels from durable session
  history, with recorded workspace roots carried forward automatically;
- inspect the exact panel scopes and folder paths represented by the project rail's counts;
- choose any Monday-through-Sunday period and explicitly click **Generate review**;
- observe progress, resume a failed/interrupted generation, browse immutable versions, and read the final slides or research report in Argus.
- select the virtual **All** collection to browse every project's slides for one week without
  changing project ownership; and
- switch either the aggregate or one project into **Calendar list** to browse weekly decks newest
  first. A newer in-flight version does not conceal the latest completed deck.

Nothing is scheduled. A generation only starts after the user chooses a project/week and clicks the button. Closing the view does not stop an active generation because the app-level controller observes the durable pipeline state.

Before that UI is wired, the installed app binary also exposes a headless verification bridge:

```bash
/Applications/Argus.app/Contents/MacOS/Argus --weekly-progress-generate request.json
/Applications/Argus.app/Contents/MacOS/Argus --weekly-progress-resume "<generation-directory>"
```

The request is JSON containing `project`, an ISO-8601 `weekContaining` timestamp, and optional `journalDirectory` and `storeDirectory` overrides. The command prints the completed generation and final deck paths as JSON. This is an integration harness, not the intended user interface.
