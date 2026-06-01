# Argus — design

One client (macOS / web / phone / watch) to reach every coding-agent (`claude`, shells, …) tmux session across heterogeneous machines — a SLURM/HPC cluster, macOS, future native Windows — from a single place. We **own** our sessions (no adopting foreign ones).

## Core principle (locked 2026-05-29) — scheduler-agnostic, no "job" concept

`ut` is a drop-in for tmux. It connects to a tmux server chosen by its socket, which is the default one per machine or a named one via `-L`, and the first `ut` on that server starts one broker that every later `ut` reuses. The broker publishes that server's sessions to the tailnet under a unique, persisted identity joined with an ephemeral key, and it exits when the server dies so that its device removes itself. The Mac client finds brokers by probing each online tailnet peer and trusting only those that return the broker's identity handshake, then connects to each directly. You isolate brokers by choosing a different socket.

Everything below is held to this principle. The unit is the **tmux server (its socket)** — not a SLURM/PBS job — so it works identically on the cluster, a plain SSH box, or the Mac. Isolation (per job, per project, whatever) is opt-in by choosing a different socket, exactly as with tmux.

## Layers (each swappable; the SessionProvider is the only place that knows a specific multiplexer/OS)

- **L0 Substrate** — the real multiplexer. Unix = **tmux** in control mode (`tmux -CC`). Windows (later) = ConPTY directly.
- **L1 SessionProvider** — the modular seam. One interface modeled on tmux control-mode vocabulary (the lowest common denominator other backends can implement):
  - `ListSessions/Windows/Panes` → `{session $id, window @id, pane %id, title, cwd (pane_current_path), cmd (pane_current_command), layout}`
  - `Subscribe()` → event stream `{Output, WindowAdd, WindowClose, WindowRenamed, SessionChanged, LayoutChange, PaneExited}`
  - `SendKeys / Spawn / Rename / SetLayout / KillPane`, `OpenFile(osc8)` RPC
  - Impl now: `TmuxControlModeProvider`. Later: `ConPtyProvider`.
- **L2 Broker** — **one broker per tmux server (its socket)**, started lazily by the first `ut` on that socket and reused by every later `ut`; owns exactly one `-CC` channel to L0; un-escapes `%output` octal → raw bytes; derives topology from the `%` notification stream; exposes **one WebSocket per client**. Clients never see control-mode text. It embeds `tsnet` for a rootless tailnet listener and persists a unique device identity in its state dir. The broker is a child of whatever started it (a shell, a login, a job), so it exits when that context's process tree is torn down.
- **L3 Transport** — **Tailscale everywhere** (`tsnet`, rootless, no TUN). Brokers are reached **directly over the tailnet**, wherever they run. No SSH-transport. **No central hub** — the client dials N brokers directly (P2P). Discovery is **capability-based, never by hostname or tag**: the client probes `:8722` on every online tailnet peer and accepts only those that return the broker's identity handshake (`GET /whoami` → a `universal-tmux-broker` marker plus a display name), so an unrelated service on 8722 is never mistaken for a broker. This covers every machine type — cluster nodes (tsnet), personal Macs, and Windows — with no renaming. A `tag:utmux-broker` ACL stays **optional**, used only to gate which devices the client may reach. Brokers join with an **ephemeral** key so a dead one's device auto-removes. An optional aggregator seam exists at L2's client-facing interface for later (thin watch/phone clients, replay, search) — built fresh if ever needed.
- **L4 Client + renderer** — DECISION (2026-05-28): **native, macOS-first**. AppKit + **SwiftTerm** (Miguel de Icaza) in `clients/macos/` (SwiftPM + SwiftTerm + `URLSessionWebSocketTask`, no other deps). Flutter/`xterm.dart` was rejected after research (unfixed crash in the alt-screen/scroll path agent TUIs hit, no OSC 8, broken modern emoji, dormant repo → would mean owning a renderer fork). SwiftTerm gives OSC 8 cmd+click for free via its `requestOpenLink` delegate, plus Metal rendering + correct Unicode. The xterm.js **web client stays as the zero-install fallback**. Android/iOS deferred (later: native too — dial brokers by `100.x` IP per the Android MagicDNS bug, rely on the system Tailscale app, don't embed tsnet). Apple Watch = glance + notify only. Presence/reconnect on per-connection heartbeats, never Tailscale `Peer.Online`.

## Protocol (broker ↔ client)

One binary **WebSocket** (gRPC-web and WebTransport rejected: no browser bidi / can't traverse TCP). 1-byte opcode framing, two lanes on the same socket:
- **raw**: `OUTPUT(pane, bytes)` down; `INPUT(pane, bytes)`, `RESIZE(pane, w, h)` up.
- **control**: JSON `EVENT` (topology) + request-id `RPC` (list / rename / spawn / open-file).

Flow control: `refresh-client -f pause-after=N` so a streaming pane can't back up and trip tmux's slow-control-client disconnect (`%pause`/`%continue`; confirmed working on tmux 3.2a).

## Cluster (and any scheduler) specifics

The cluster is **not a special case** — it is just a machine where you run `ut` inside an allocation. Nothing reads `$SLURM_JOB_ID` or any scheduler variable.

- You run `ut` inside your allocation (interactively or from the batch script); the first `ut` lazily starts the broker as a child of that allocation's process tree.
- **Durability = the allocation, not tmux** (the scheduler's cgroup tears down every process — broker and tmux server alike — when the job ends, on SLURM or PBS): the recovery story is `--requeue`-style auto-rerun + a checkpoint trap + a **stable socket name** so the client transparently reattaches when the job comes back.
- Tailnet: an **ephemeral** auth key (read once from `~/.universal-tmux/authkey`) tagged `tag:utmux-broker`, so a dead allocation's device auto-cleans.
- Isolation between two allocations on one node is opt-in: each passes a distinct socket (`ut -L <name>`), exactly as with tmux. By default they share the node's default server and one broker.
- tmux: system **3.2a is fine** for control-mode (subscriptions + pause-after confirmed). **OSC 8 cmd+click needs ≥3.4** → build 3.5a/3.6 into `$HOME/local` (static libevent+ncurses, dynamic glibc, ship `tmux-256color`) for **fresh** sessions; never `kill-server`.

## Validated (2026-05-28, on real hardware)

- Rootless userspace Tailscale on an HPC **compute node** (no root, no TUN); `tailscale ping` mac→node punched to **direct WireGuard ~6 ms**; `tailscale serve --tcp/--http` + `curl` over the tailnet → HTTP 200. Outbound 443 to control/DERP works from both login and compute nodes, no proxy.
- tmux control mode on 3.2a: `%output` octal is losslessly reversible; topology notifications, `-B` subscriptions, `-f pause-after` all functional.

## Build order

0. **Local-first core** — broker ↔ xterm.js on the mac (tmux 3.6a): control-mode parse, `%output` un-escape, opcode framing, render + send keys. *(in progress)*
1. **Cluster slice** — same binary inside a SLURM job, `tsnet` listener, reached from the mac over Tailscale.
2. SessionProvider interface formalized; topology events + JSON RPC lane.
3. Multi-pane/window + reconnect/state-resync + autossh-free tailnet reconnect.
4. SLURM lifecycle hardening (`--requeue` + checkpoint + stable id); `$HOME` tmux 3.6 build.
5. Features: OSC 8 cmd+click open-file, rename, group-by-machine, group-by-folder.
6. P2P fan-out (N brokers) + second renderer (SwiftTerm).
7. *(optional)* aggregator seam + Apple Watch glance/notify.
8. *(only if a Windows node appears)* ConPtyProvider behind the same seam.
