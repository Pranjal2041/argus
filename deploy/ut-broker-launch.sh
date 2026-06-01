#!/usr/bin/env bash
# universal_tmux — launch a per-node broker that auto-joins the tailnet and
# serves THIS node's tmux sessions. The macOS app discovers it automatically
# (any tailnet node named `ut-<hostname>`).
#
# Usage — on any cluster node where you hold an allocation, or inside your
# sbatch script (after your agent's tmux session is set up):
#
#     TS_AUTHKEY=tskey-... deploy/ut-broker-launch.sh &
#
# Env:
#   TS_AUTHKEY    (required) reusable Tailscale auth key  [admin -> Settings -> Keys]
#   UT_BROKER     broker binary           (default: ~/.universal-tmux/ut-broker)
#   UT_TSNET_DIR  node-local tsnet state  (default: /tmp/ut-tsnet-$USER)
#   UT_SESSION    session to warm         (default: main)
#
# Notes: state is kept node-local (not NFS) so each node is its own tailnet
# identity and they never clash. With an ephemeral key, nodes auto-remove from
# the tailnet when the job ends — no orphans.
set -euo pipefail

: "${TS_AUTHKEY:?Set TS_AUTHKEY to a reusable Tailscale auth key (admin -> Settings -> Keys)}"
BIN="${UT_BROKER:-$HOME/.universal-tmux/ut-broker}"
[ -x "$BIN" ] || { echo "ut-broker not found/executable at $BIN" >&2; exit 1; }

exec "$BIN" \
  --tsnet-host="ut-$(hostname)" \
  --tsnet-dir="${UT_TSNET_DIR:-/tmp/ut-tsnet-$USER}" \
  --listen=":8722" \
  --session="${UT_SESSION:-main}"
