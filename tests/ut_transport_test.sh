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

# --- local control port is independent of the tailnet port -------------------
# Several brokers can share one host (another `-L` socket, or a second install
# under the same login). Each must publish the standard tailnet port while owning
# a distinct loopback control port, and its CLI must reach that same broker.
mkdir -p "$TMP/bin" "$TMP/home"
cat > "$TMP/bin/tmux" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in has-session|kill-session) exit 1 ;; esac
done
exit 0
EOF
cat > "$TMP/home/ut-broker" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "${UT_PORT:-}" "${UT_LOCAL_PORT:-}"
EOF
# Keep the fixture independent of brokers listening on the developer's machine.
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
chmod +x "$TMP/bin/tmux" "$TMP/bin/curl" "$TMP/home/ut-broker"

launch() { # socket [UT_LOCAL_PORT]
  (cd "$TMP" && env PATH="$TMP/bin:$PATH" UT_HOME="$TMP/home" UT_LOCAL_DIR="$TMP/local" \
    UT_TAILSCALE_BIN="$TMP/tailscale" UT_NO_ATTACH=1 UT_PORT=8722 \
    ${2:+UT_LOCAL_PORT=$2} "$ROOT/ut" -L "$1" demo)
}
launch base
launch second 8732
grep -q -- "--listen ':8722' --local-listen '127.0.0.1:8722'" "$TMP/local/supervise-base.sh"
grep -q -- "--listen '127.0.0.1:8722'" "$TMP/local/supervise-base.sh"
grep -q -- "--listen ':8722' --local-listen '127.0.0.1:8732'" "$TMP/local/supervise-second.sh"
grep -q -- "--listen '127.0.0.1:8732'" "$TMP/local/supervise-second.sh"
assert_eq "$(env UT_HOME="$TMP/home" UT_PORT=8722 UT_LOCAL_PORT=8732 "$ROOT/ut" ls)" '8722 8732'

# A second instance's state roots reach its broker even through a tmux server
# whose environment predates them; the default instance declares none.
(cd "$TMP" && env PATH="$TMP/bin:$PATH" UT_HOME="$TMP/home" UT_LOCAL_DIR="$TMP/local" \
  UT_TAILSCALE_BIN="$TMP/tailscale" UT_NO_ATTACH=1 UT_LOCAL_PORT=8742 \
  UT_STATE_DIR="$TMP/state dir" UT_LAB_ROOT="$TMP/lab" "$ROOT/ut" -L third demo)
(
  unset UT_STATE_DIR UT_LAB_ROOT UT_BACKUP_ROOT
  eval "$(grep "^export UT_" "$TMP/local/supervise-third.sh")"
  assert_eq "$UT_STATE_DIR|$UT_LAB_ROOT|${UT_BACKUP_ROOT:-}" "$TMP/state dir|$TMP/lab|"
)
if grep -q '^export UT_' "$TMP/local/supervise-base.sh"; then
  echo "default instance must not pin state roots" >&2
  exit 1
fi
assert_eq "$(env UT_HOME="$TMP/home" UT_PORT=8722 UT_LOCAL_PORT= "$ROOT/ut" ls)" '8722 8722'

printf 'ut transport selection tests passed\n'
