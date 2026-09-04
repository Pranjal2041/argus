#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/tailscale" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = ip ] && [ "${2:-}" = -4 ]; then
  printf '%s\n' "${FAKE_TAILSCALE_IP:-}"
  exit "${FAKE_TAILSCALE_EXIT:-0}"
fi
exit 1
EOF
chmod +x "$TMP/tailscale"

plan() {
  UT_TAILSCALE_BIN="$TMP/tailscale" FAKE_TAILSCALE_IP="${1:-}" \
    FAKE_TAILSCALE_EXIT="${4:-0}" \
    "$ROOT/ut" __transport-plan "${2:-0}" "${3:-}"
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

# Failed lookups and diagnostic output are unknown state, not a changed address.
# Test both previously-native and previously-embedded hosts, plus cold startup.
for previous in $'native\t100.64.0.8' $'embedded\t'; do
  for invalid in 'CLI failed to start' '100.64.0.999' '100.64.0' \
    '100.64.0.8:8722' '0.0.0.0' '000.0.0.0' '010.64.0.8' \
    $'100.64.0.8\ndiagnostic text'; do
    assert_eq "$(plan "$invalid" 1 "$previous")" "$previous"
    assert_eq "$(plan "$invalid" 1)" $'embedded\t'
  done
  assert_eq "$(plan '' 1 "$previous" 1)" "$previous"
  assert_eq "$(plan 'CLI failed to start' 1 "$previous" 1)" "$previous"
  # Even valid-looking output must not override a failed exit status.
  assert_eq "$(plan 100.64.0.9 1 "$previous" 1)" "$previous"
done

# Real address changes and embedded-to-native transitions still converge.
assert_eq "$(plan 100.64.0.9 1 $'native\t100.64.0.8')" $'native\t100.64.0.9'
assert_eq "$(plan 100.64.0.9 1 $'embedded\t')" $'native\t100.64.0.9'

printf 'ut transport selection tests passed\n'
