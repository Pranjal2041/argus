# Terminal refresh contract

A screen capture is not just text. After a refresh, the next live output byte
must affect the same cell that it would have affected without the refresh.
This applies to every shell and full-screen application, with no name-based
selection or compatibility branches.

The display stream preserves:

- Authoritative geometry before the bytes formatted for that geometry.
- All visible physical rows, including blank bottom rows, and captured history.
- The editing cursor, independently of the last painted cell (suggestions and
  footers commonly draw beyond it).
- Pending right-margin wrap, including trailing spaces and wide characters.
- Active screen buffer, scrolling margins, origin, wrap, insert, and cursor
  visibility modes used by the grid reconstruction.
- Snapshot/live-output ordering, including snapshots split across wire frames.

`Session.RequestSnapshot(id)` emits an ordered snapshot through `Output()`.
Only the broker hub pump writes output frames; a snapshot is delivered only to
its requesting subscriber. New subscribers receive no pre-snapshot deltas.
Duplicate requests are coalesced; failed or timed-out captures disconnect the
viewer so it can reconnect, rather than silently corrupting its display.

The tmux adapter captures metadata and the active grid in one command list on
the same control connection as live output. Guarded capture responses are data,
not `%output` notifications. `capture-pane -N` retains trailing spaces. The
shared `ScreenSnapshot` encoder restores cursor placement after repainting;
for pending wrap it repaints the last cursor row to re-arm autowrap.

The ConPTY adapter serializes its existing raw replay capture and live output
under the same lock. Its bounded raw-history representation is unchanged; this
change does not claim to make arbitrary truncated replay lossless.

Regression coverage includes isolated real tmux sessions, broker subscriber
ordering, and shared wire fixtures replayed in the actual Mac SwiftTerm view.
Wide-character continuation is checked in SwiftTerm because the legacy Go
vt10x test emulator models every rune as one cell. To save local visual QA:

```sh
mkdir -p /tmp/argus-terminal-qa
cd clients/macos
ARGUS_TERMINAL_QA_DIR=/tmp/argus-terminal-qa swift test --filter TerminalSnapshotTests
```

This captures the test's own view, not the desktop, and requires no Screen
Recording permission. No user terminal is cleared or sent test input.
