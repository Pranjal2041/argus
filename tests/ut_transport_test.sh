#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/tailscale" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = ip ] && [ "${2:-}" = -4 ]; then
  printf '%s\n' "${FAKE_TAILSCALE_IP:-}"
  exit 0
fi
exit 1
EOF
chmod +x "$TMP/tailscale"

plan() {
  UT_TAILSCALE_BIN="$TMP/tailscale" FAKE_TAILSCALE_IP="${1:-}" \
    "$ROOT/ut" __transport-plan "${2:-0}"
}

assert_eq() {
  if [ "$1" != "$2" ]; then
    printf 'got <%s>, want <%s>\n' "$1" "$2" >&2
    exit 1
  fi
}

# A native host never creates a second identity merely because the shared key
# is installed (the regression that produced duplicate Macs).
assert_eq "$(plan 100.64.0.8 1)" $'native\t100.64.0.8'

# A headless/cluster host with the same key retains the rootless tsnet path.
assert_eq "$(plan '' 1)" $'embedded\t'

# A native host without a key still publishes through system Tailscale.
assert_eq "$(plan 100.64.0.9 0)" $'native\t100.64.0.9'

# With neither transport ready, local service remains available and the
# supervisor can rebind when a native IP subsequently appears.
assert_eq "$(plan '' 0)" $'native\t'

printf 'ut transport selection tests passed\n'
