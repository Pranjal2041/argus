# Session transport recovery

The shared `session.Provider.ListInventory(ctx)` contract distinguishes an
unavailable backend from an empty workspace. Every provider returns an error
when discovery is uncertain. The broker retains its last successful inventory
on error; only a successful inventory may remove sessions. Tiered screen
classification is optional and does not change this contract.

## tmux

A missing UNIX socket does not imply that its server or sessions exited. On a
connection failure, the tmux adapter reads the resolved endpoint from tmux's
error and checks live UNIX socket descriptors with `lsof`. This works without a
cached PID, including after a broker restart, and respects custom `TMUX_TMPDIR`
paths and inherited socket selection.

When exactly one same-user tmux process still owns that endpoint, the adapter
verifies its ownership and process identity again, restores the immediate
private socket directory if necessary, and sends that process `SIGUSR1`.
This is tmux's documented socket-recreation signal; it does not restart the
server, shells or sessions. Recovery is serialized, bounded by the caller's
deadline, and followed by an inventory read. Successful recovery is logged with
the endpoint and original server PID.

Owner discovery requires `lsof` and `ps` (provided by macOS; install them on
other Unix hosts if absent). Missing tools, incomplete scans, ambiguous owners,
unsafe directories and failed recovery return errors, never an empty inventory.
No command signals processes by name or removes an occupied socket. A complete
scan finding no live owner permits a genuinely absent server to be reported.

All three session-creation paths validate inventory first. If a server exists,
they use tmux's `-N` option so a subsequent socket loss cannot cause automatic
creation of a replacement server. Mutating commands are never replayed during
recovery. Attach remains attach-only.

## Verification

`go test ./...` covers the shared error contract for both tiered and in-memory
non-tiered providers. Isolated real-tmux regression tests remove a socket and
its parent directory, create fresh providers, and issue concurrent reads. They
check unchanged session lineage, server/pane PIDs and terminal history. Other
tests cover unrelated servers, all creation paths, the read/create race,
genuine empty servers, cancellation, incomplete/ambiguous owner scans and
unsafe directories. `go test -race ./internal/tmux ./internal/broker` exercises
the affected concurrency paths.
