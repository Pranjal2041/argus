#!/usr/bin/env bash
# The bundled Slurm machine launcher: submission arguments, reuse, and the
# ARGUS_MACHINE announcement Argus uses to find the node.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NODE="$ROOT/clients/macos/Resources/launchers/slurm-node"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Fake `ssh -o BatchMode=yes <host> <command>`: records each remote command and
# any sbatch stdin, and answers squeue from $TMP/queue.
cat > "$TMP/ssh" <<'EOF'
#!/usr/bin/env bash
shift 3   # -o BatchMode=yes <host>
printf '%s\n' "$*" >> "$FAKE/commands"
case "$*" in
  sbatch*)
    eval "set -- $*"   # the remote shell's word splitting
    printf '[%s]' "$@" > "$FAKE/sbatch-args"
    cat > "$FAKE/sbatch-stdin"
    printf '4242 RUNNING node7\n' > "$FAKE/queue"
    echo "4242;babel" ;;
  "squeue -j"*) awk '{print $2, $3, "None"}' "$FAKE/queue" 2>/dev/null || true ;;
  squeue*) cat "$FAKE/queue" 2>/dev/null || true ;;
  scancel*) rm -f "$FAKE/queue" ;;
esac
EOF
chmod +x "$TMP/ssh"

run() { FAKE="$TMP" ARGUS_SSH="$TMP/ssh" ARGUS_SLURM_POLL=0 /bin/bash "$NODE" "$@"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# No extra options: sbatch receives no empty argument (it would read '' as the
# script), and the job script travels on stdin.
out="$(run babel up)"
[ "$(cat "$TMP/sbatch-args")" = '[sbatch][--parsable]' ] || fail "unexpected sbatch args: $(cat "$TMP/sbatch-args")"
cmp -s "$TMP/sbatch-stdin" "$ROOT/clients/macos/Resources/launchers/argus-node.sbatch" || fail "job script not sent on stdin"
grep -qx 'ARGUS_MACHINE=node7' <<<"$out" || fail "no announcement in: $out"

# A running Argus job is reused, not duplicated.
rm -f "$TMP/sbatch-args"
out="$(run babel up --gres=gpu:2)"
[ ! -e "$TMP/sbatch-args" ] || fail "up submitted a second job"
grep -q 'using existing job: 4242' <<<"$out" || fail "existing job not reused: $out"

# `new` always submits, and options with spaces stay single arguments.
run babel new --partition=general --comment='two words' >/dev/null
[ "$(cat "$TMP/sbatch-args")" = '[sbatch][--parsable][--partition=general][--comment=two words]' ] \
  || fail "options not preserved: $(cat "$TMP/sbatch-args")"

# A job that leaves the queue before running is a failure.
rm -f "$TMP/queue"
sed -i.bak 's/printf .4242 RUNNING node7.n. > "$FAKE\/queue"/:/' "$TMP/ssh"
if run babel new >/dev/null 2>&1; then fail "a vanished job reported success"; fi

[ "$(run babel status)" = "no Argus job on babel" ] || fail "status with no job"
printf 'slurm-node tests passed\n'
