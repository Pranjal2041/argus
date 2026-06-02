<p align="center"><img src="brand/argus-lockup.png" alt="Argus" width="440"></p>

<p align="center"><b>One watchful eye over every coding agent, on every machine.</b></p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/platforms-macOS%20%C2%B7%20Android%20%C2%B7%20Windows-444" alt="Platforms: macOS, Android, Windows">
  <img src="https://img.shields.io/badge/transport-Tailscale%20P2P-7c3aed" alt="Transport: Tailscale, peer-to-peer">
  <img src="https://img.shields.io/badge/central%20server-none-2ea44f" alt="No central server">
</p>

<p align="center">
  <a href="https://pranjal2041.github.io/argus/"><b>Documentation</b></a> ·
  <a href="DESIGN.md">Architecture</a> ·
  <a href="#quickstart">Quickstart</a>
</p>

**Argus** is a native app (macOS · Android · Windows) that reaches every `claude`
coding-agent session across all your machines at once — your Mac, SLURM/HPC clusters,
Windows boxes, your phone — over [Tailscale](https://tailscale.com), peer-to-peer, with
**no central server**. Beyond terminals it's a cross-host **file explorer + editor** and a
**port-forward hub**: one calm pane of glass over a sprawl of agents and compute.

> Named for **Argus Panoptes**, the hundred-eyed giant who watched over everything.
> *(Formerly `universal_tmux`; the `ut` CLI and per-host broker keep that name internally —
> it's load-bearing for tailnet discovery.)*

---

## Why

Coding agents now run *everywhere* — a few on your laptop, a dozen on a cluster behind
SLURM, some on a Windows box, maybe one on your phone. Checking on them means a drawer full
of SSH sessions, port-forwards, and `tmux attach`, each tied to one host. Argus collapses
all of that into a single client that sees **every session on every machine** and tells you
which agents are **working**, **waiting on you**, or **idle** — so your attention goes where
it's needed instead of hunting for it.

It does this without a backend. Each host runs a small **broker**; the app dials those
brokers **directly over your tailnet** (encrypted, peer-to-peer). Nothing is centralized,
nothing is hosted, and a machine that goes away simply drops off the map.

## What it does

- **Terminals** — stream any session live (tmux control-mode on Unix, ConPTY on Windows)
  over a binary WebSocket. Full input, resize/reflow, 100k-line scrollback, auto-reconnect,
  create / rename / kill, find-in-terminal, and a cross-machine command palette.
- **Attention model** — a sidebar of *machines → folders → sessions* with a live state dot per
  session, **running** (blue) vs **idle** (green). The broker reads it passively from the session
  screen (`tmux capture-pane` on Unix, the ConPTY output ring on Windows): running = the agent's
  `esc to interrupt` footer is on screen — Claude Code and Codex both print it only during a turn.
  No input is sent to the agent, so it works even with nothing attached.
- **Files** — a cross-host file explorer with a CodeMirror 6 viewer/editor (syntax
  highlighting for dozens of languages), image / PDF / media preview, upload & download with
  progress, and *reveal-from-session* to jump straight to a session's working directory.
- **Ports** — a port-forward hub: bind a local port and tunnel it over the tailnet to any
  remote broker, no `ssh -L` juggling.
- **`ut` CLI** — a drop-in for `tmux` that publishes a host's tmux server to your tailnet.

## How it works

```
        ┌───────────────┐        Tailscale tailnet — WireGuard, peer-to-peer
        │   Argus app   │   ●─────────────────────────────────────────●
        │ mac · phone · │                       │
        │    windows    │   probes :8722 → GET /whoami identity handshake
        └───────┬───────┘   dials each broker it trusts, directly (no hub)
                │
   ┌────────────┼──────────────────┬─────────────────────┐
   ▼            ▼                  ▼                       ▼
┌─────────┐ ┌─────────┐      ┌──────────┐           ┌──────────┐
│ broker  │ │ broker  │      │  broker  │    ...    │  broker  │
│  Mac    │ │ Linux   │      │ Windows  │           │  phone   │
│ tmux-CC │ │ tmux-CC │      │  ConPTY  │           │  tsnet   │
└─────────┘ └─────────┘      └──────────┘           └──────────┘
```

The unit is the **tmux server (its socket)** — not a SLURM/PBS job — so the same binary
works identically on the cluster, a plain SSH box, or your Mac. The first `ut` on a socket
lazily starts **one broker** that every later `ut` reuses; it embeds `tsnet` (rootless, no
TUN) to join the tailnet, and exits when its host process tree is torn down so its device
auto-removes. Discovery is **capability-based, never by hostname**: the client probes each
online tailnet peer on `:8722` and trusts only those that return the broker identity
handshake. Full design in **[DESIGN.md](DESIGN.md)**.

## Quickstart

> **Prerequisite:** a [Tailscale](https://tailscale.com) tailnet that your machines (and the
> app) belong to. Brokers join rootlessly via an auth key; the macOS/Windows host can simply
> already be on the tailnet.

### 1 · Broker (every host you want to reach)

```sh
go build -o bin/ut-broker ./cmd/ut-broker

# Local (loopback) — the host is already on your tailnet:
./bin/ut-broker --listen 127.0.0.1:8722

# Or use the `ut` CLI, a drop-in for tmux that starts the broker for you:
ut                 # attach/create a session in $PWD and publish this server
ut my-experiment   # a named session (attach-or-create)
ut -L scratch      # a separate tmux server + broker, like `tmux -L`
```

### 2 · macOS app

```sh
cd clients/macos
swift build -c release && bash build-app.sh
cp -R Argus.app /Applications/ && open /Applications/Argus.app
```

### 3 · Android app

```sh
cd clients/android
bash dev-install.sh          # builds the debug APK and installs to the connected device
```

The phone joins the tailnet itself via an embedded `tsnet` core — paste a Tailscale auth key
in the app; no system Tailscale client or manual hostnames required.

### 4 · Windows

Build `ut-broker` for Windows (`GOOS=windows go build ./cmd/ut-broker`) and run it on the
box; the broker speaks ConPTY behind the same interface. The macOS/Android apps reach it like
any other host.

### Web fallback

A zero-install **xterm.js** client lives in [`web/`](web/) — point it at a broker's
`--listen` address for a browser terminal when you can't install the native app.

## Documentation

Full docs — install per platform, architecture, the `ut` CLI, Files & Ports guides, and the
security model — live at **[pranjal2041.github.io/argus](https://pranjal2041.github.io/argus/)**
(built with [Fumadocs](https://fumadocs.dev), source in [`docs/`](docs/)).

## Repository layout

| path | role |
|---|---|
| `cmd/ut-broker/`      | the per-host broker binary (Go) |
| `cmd/ut/`             | the `ut` CLI launcher |
| `internal/tmux/`      | tmux control-mode `SessionProvider` (the modular seam) |
| `internal/broker/`    | per-client WebSocket server + frame codec |
| `internal/fsvc/`      | the `/fs/*` file service (browse / read / write / upload) |
| `internal/forward/`   | the port-forward agent |
| `internal/conpty/`    | Windows ConPTY `SessionProvider` |
| `clients/macos/`      | native macOS app (AppKit + SwiftTerm + CodeMirror) |
| `clients/android/`    | native Android app (Kotlin/Compose + embedded `tsnet`) |
| `web/`                | xterm.js web client (zero-install fallback) |
| `docs/`               | Fumadocs documentation site |

## Security

- All traffic rides your **Tailscale tailnet** (WireGuard) — brokers are reachable only by
  devices on your tailnet, never exposed publicly.
- Brokers run **as you**, on your own hosts; there is **no central server** to trust or
  breach. A dead host's broker auto-removes its tailnet device (ephemeral key).
- The broker only ever serves a host it was started on; discovery requires the
  `GET /whoami` identity handshake, so an unrelated service on `:8722` is never mistaken for
  one. Auth keys and other secrets are never committed (see [`.gitignore`](.gitignore)).

## License

[MIT](LICENSE) © 2026 Pranjal Aggarwal
