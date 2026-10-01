#!/bin/bash
#SBATCH -J argus
#SBATCH -o argus-%j.out
#SBATCH --open-mode=append
#
# Publishes this allocation's node to Argus. Submitted by `slurm-node` (resources
# come from its sbatch options); terminals opened from Argus run inside the job.
# The allocation is held for its full time limit, like `sleep infinity`: losing
# the broker or its tmux server never ends the job, and the broker is restarted
# within a minute. Release it early with `slurm-node <host> down` or scancel.
UT="${UT:-$HOME/.universal-tmux/ut}"
[ -x "$UT" ] || UT="$(command -v ut || true)"
if [ -z "$UT" ] || [ ! -x "$UT" ]; then
  echo "ut not found: install it to ~/.universal-tmux/ut (see the Argus installation docs)" >&2
  exit 1
fi
cd "$HOME"
echo "=== $(date) ARGUS node $(hostname) job ${SLURM_JOB_ID} ==="
echo "ATTACH: srun --jobid=${SLURM_JOB_ID} --overlap --pty bash"
while :; do
  if ! tmux -L ut has-session -t _ut-ut 2>/dev/null; then
    echo "=== $(date) starting broker ==="
    UT_NO_ATTACH=1 "$UT" main || echo "=== $(date) broker start failed; retrying ==="
  fi
  sleep 60
done
