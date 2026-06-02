# Argus — Feature List

One native macOS client to reach every coding-agent (`claude`) tmux session across all your machines (local Mac + HPC cluster nodes) over Tailscale, with no central hub. The point: a control tower that shows which agents are **working / waiting on you / idle**, across every node, and routes your attention there.

Legend — effort: S/M/L/XL · where: `client` (Swift) / `broker` (Go) / `both`.

## Done (built + verified)
- Stream any session live (tmux `-CC` under PTY → binary WebSocket), input, resize.
- Terminal **reflows to the live window size** on connect/show (was stuck 153×41).
- **Auto-reconnect** with backoff; live connection dot in the header.
- **Sidebar** machines → folders → sessions, with status dots, activity times, count badges.
- **Sidebar collapse** + narrow-window handling (terminal never vanishes).
- Hidden titlebar / seamless dark theme; vibrant sidebar; seam divider.
- **Session lifecycle**: create / rename / kill (broker `/control` + context menu + sheet).
- **Find in terminal** (⌘F), **scroll-to-bottom** pill, **command palette** (⌘K) across machines.
- Copy / paste / select-all; large scrollback (100k); auto-refresh poll.
- **Agent-state detection (broker)**: `/sessions` reports `working|idle`, read **passively** from the session screen (`tmux capture-pane` on Unix, the ConPTY output ring on Windows) — `working` when the agent's `esc to interrupt` footer is visible (Claude Code and Codex both print it only during a turn), else `idle`. No input is sent to the agent, so it works with nothing attached. Surfaced as a pulsing blue / solid green **state dot per session** in the sidebar.

## Now — basics that are still missing (fixing immediately)
- [ ] **Thick top margin** above the terminal header — remove the unneeded 28pt reserve on the detail side. `S · client`
- [ ] **Font-size control that works + persists** (terminal pane) + a **Settings window (⌘,)**. `S · client`
- [ ] **UI element / chrome text scaling** (independent of terminal font). `M · client`
- [ ] Cross-machine **"Needs attention" list** + **notification / Dock badge** — needs a "waiting for input" signal; the shipped detector is running/idle only, so this path is currently dormant. `M · both`

## Terminal emulator (table stakes)
- [ ] Themes / color schemes (catalog + import iTerm/Alacritty), per-machine accent. `M · client`
- [ ] Font family picker, ligatures, cursor style. `M · client`
- [ ] Clickable URLs + file paths (host-aware: paths live on the node, not the Mac). `M · both`
- [ ] Mouse reporting / bracketed paste / option-as-meta as preferences. `M · both`
- [ ] Selection/copy hardening (copy-on-select, rectangular select, copy-as-plain/ANSI). `M · client`
- [ ] Configurable bell (audible / visual flash / off) per session. `S · client`
- [ ] Scrollbar styling + scroll-position indicator. `S · client`
- [ ] Semantic shell integration (OSC 133 prompt marks): jump-to-prompt, copy-last-output. `L · both`

## Session / multiplexer
- [ ] **Tabs** (several sessions in one window; can mix machines). `M · client`
- [ ] **Split panes** (client-composited, can mix machines) + zoom. `L · client`
- [ ] **Broadcast input** to multiple selected sessions. `M · both`
- [ ] Real tmux **window/pane topology** (not just the first pane) + switch/split/close. `XL · both`
- [ ] Session templates: spawn an agent in a chosen dir running a chosen command; duplicate session. `M · both`
- [ ] Detach (keep running, free local memory) + show who else is attached. `M · both`
- [ ] Bulk ops (kill all idle/finished), restart agent in place. `M · both`
- [ ] Multi-window app (tear a session into its own window / second display). `L · client`

## Attention model (the reason this exists)
- [ ] Agent state classifier hardened (working/waiting/idle/done), pushed as events. `L · both`
- [ ] Background monitoring so state is known for sessions you're NOT viewing. `M · broker`
- [ ] **"Needs attention" inbox** across all machines, sorted by time-blocked. `M · client`
- [ ] **Notifications + Dock badge + menu-bar glance** on state change. `M · both`
- [ ] Quick **approve / deny / continue** + snippets/quick-commands from the inbox. `M · both`
- [ ] Output **keyword alerts** (regex watch rules, run broker-side). `M · both`
- [ ] Per-session activity sparkline + unseen-output badges. `M · both`
- [ ] Reconnect **backfill** (replay only the missed tail, not a full snapshot). `L · both`
- [ ] Search across ALL sessions' output (one query, every node). `L · both`

## Cross-node / cluster
- [ ] Structured per-host health (state, RTT, last error) + per-host retry backoff. `S · client`
- [ ] Per-node info: SLURM job id / partition / GPUs / **walltime countdown**, real compute node, tailnet path. `L · both`
- [ ] One-click broker deploy to a new node (SSH bootstrap) + auth-key management in Keychain. `L · both`
- [ ] Launch a broker **inside a new SLURM allocation** (sbatch from the GUI). `XL · both`
- [ ] Walltime-expiry warnings + **follow-the-session** reconnect across a requeue. `XL · both`
- [ ] Node grouping, session groups, pinning/favorites, manual sort, notes. `M · client`
- [ ] Cross-node file transfer / remote open (pull a checkpoint to the Mac). `L · both`
- [ ] All-machines overview screen (health, counts, walltimes) when nothing is selected. `M · client`

## Platform / app polish
- [ ] Settings store (Codable persistence) — substrate for everything above. `M · client`
- [ ] Restore last selection + persisted machine list on launch. `S · client`
- [ ] JSON control/RPC + EVENT lane on the WebSocket (one seam for lifecycle/topology/state). `M · broker`
- [ ] Customizable keyboard shortcuts (note: ⌘\ collides with 1Password → use ⌃⌘S). `M · client`
- [ ] Auth on mutating broker actions (token / tsnet identity). `M · both`
- [ ] App icon, Sparkle auto-update, accessibility / VoiceOver, connection diagnostics, `universaltmux://` deep links. `L · client`
