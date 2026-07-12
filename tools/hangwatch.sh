#!/bin/zsh
# Argus hangwatch — a flight recorder for system-wide UI hangs.
#
# The symptom it exists for: the whole macOS UI (incl. system menus) turns
# molasses while background processes run at full speed — and killing any one
# app doesn't help. Something starves the display path; this records enough
# every 15s to convict the culprit after the fact, and takes a heavy capture
# the moment UI latency spikes.
#
# Runs as a LaunchAgent (see tools/install-hangwatch.sh). Logs:
#   ~/Library/Logs/argus-hangwatch/YYYY-MM-DD.log        (one line / 15s)
#   ~/Library/Logs/argus-hangwatch/hang-<ts>.txt         (heavy capture on trigger)
# Keeps 7 days.

LOGDIR="$HOME/Library/Logs/argus-hangwatch"
mkdir -p "$LOGDIR"
THRESH_MS=2000     # UI probe slower than this = hang → heavy capture
COOLDOWN=120       # min seconds between heavy captures
last_capture=0

ui_probe_ms() {
  # Round-trips the system UI plumbing the user's symptom lives in.
  local t0=$(($(date +%s%N)/1000000))
  osascript -e 'tell application "System Events" to count processes' >/dev/null 2>&1
  local t1=$(($(date +%s%N)/1000000))
  echo $((t1 - t0))
}

# Instantaneous WindowServer CPU. The AppleEvent probe above only catches
# CPU/kernel stalls; a compositor-bound "desktop is molasses but mouse is fine"
# slowdown (WindowServer pegged) does NOT move it. This does.
ws_inst_cpu() {
  local wp=$(pgrep -x WindowServer | head -1)
  [ -z "$wp" ] && { echo 0; return; }
  top -l 2 -s 1 -pid "$wp" -stats cpu 2>/dev/null | tail -1 | tr -dc '0-9.' | awk '{print int($1)}'
}

ws_high=0   # consecutive cycles WindowServer has been pegged

while true; do
  DAY=$(date +%F)
  LOG="$LOGDIR/$DAY.log"
  TS=$(date +%H:%M:%S)

  UI_MS=$(ui_probe_ms)
  LOAD=$(sysctl -n vm.loadavg | awk '{print $2}')
  FREE_PCT=$(memory_pressure -Q 2>/dev/null | awk '/free percentage/{print $NF}' | tr -d '%')
  SWAP=$(sysctl -n vm.swapusage | awk '{print $6}')
  WS_CPU=$(ps -eo %cpu,comm | awk '/WindowServer/{print $1; exit}')
  ARGUS=$(ps -eo %cpu,rss,comm | awk '/MacOS\/Argus$/{printf "%.0f%%/%dMB", $1, $2/1024; exit}')
  WK_N=$(pgrep -f com.apple.WebKit | wc -l | tr -d ' ')
  WK_MB=$(ps -eo rss,comm | awk '/WebKit/{s+=$1} END {print int(s/1024)}')
  TOPCPU=$(ps -eo %cpu,comm | sort -rn | head -4 | awk '{printf "%s:%s ", $2, $1}' | sed 's|/.*/||g')

  echo "$TS ui=${UI_MS}ms load=$LOAD free=${FREE_PCT}% swap=$SWAP ws=${WS_CPU}% argus=${ARGUS:-dead} webkit=${WK_N}p/${WK_MB}MB top:[$TOPCPU]" >> "$LOG"

  WS_INST=$(ws_inst_cpu)
  if [ "${WS_INST:-0}" -gt 60 ]; then ws_high=$((ws_high + 1)); else ws_high=0; fi

  NOW=$(date +%s)
  # Trigger on EITHER a CPU/kernel stall (UI probe) OR a sustained compositor
  # peg (WindowServer >60% for 2+ cycles = the desktop-slow-but-mouse-fine case).
  if { [ "$UI_MS" -gt "$THRESH_MS" ] || [ "$ws_high" -ge 2 ]; } && [ $((NOW - last_capture)) -gt "$COOLDOWN" ]; then
    last_capture=$NOW
    CAP="$LOGDIR/hang-$(date +%F-%H%M%S).txt"
    {
      echo "=== HANG DETECTED at $(date) — ui probe ${UI_MS}ms, WindowServer ${WS_INST}% (ws_high=${ws_high}) ==="
      echo "--- second probe (still hung?) ---"; echo "ui2=$(ui_probe_ms)ms"
      # THE KEY ADDITION: sample the actual busy processes so next time we get
      # the exact hot call stack (Flow? Argus? something else?) — not a guess.
      echo "--- sampling the top CPU processes (3s each) ---"
      for spid in $(top -l 2 -s 1 -n 15 -o cpu -stats pid,command 2>/dev/null | tail -15 | grep -viE "kernel_task|WindowServer|\\bsample\\b|\\btop\\b" | awk 'NF>=2 && $1 ~ /^[0-9]+$/ {print $1}' | head -4); do
        echo "· sample pid $spid ($(ps -o comm= -p $spid 2>/dev/null | sed 's|.*/||')) ·"
        sample "$spid" 3 -mayDie 2>/dev/null | sed -n '/Call graph/,/Total number/p' | head -60
      done
      # WindowServer's own hot stack needs root; grab it only if passwordless sudo exists.
      if sudo -n true 2>/dev/null; then
        echo "--- WindowServer sample (3s) ---"; sudo -n sample $(pgrep -x WindowServer) 3 -mayDie 2>/dev/null | sed -n '/Call graph/,/Total number/p' | head -50
      fi
      echo "--- memory ---"; memory_pressure 2>/dev/null | head -12; sysctl vm.swapusage; vm_stat
      echo "--- full process table by CPU ---"; ps aux | sort -rnk3 | head -25
      echo "--- full process table by RSS ---"; ps aux | sort -rnk6 | head -25
      echo "--- WindowServer ---"; ps -p $(pgrep -x WindowServer) -o pid,%cpu,rss,etime,command 2>/dev/null
      echo "--- top snapshot ---"; top -l 2 -n 12 -o cpu -stats pid,cpu,mem,command 2>/dev/null | tail -20
      # Deep capture if passwordless sudo for spindump was granted (optional):
      if sudo -n true 2>/dev/null; then
        echo "--- spindump (10s) ---"
        sudo -n spindump -notarget 10 10 -file "$LOGDIR/hang-$(date +%F-%H%M%S).spindump.txt" 2>&1 | tail -2
      else
        echo "(no passwordless sudo — spindump skipped; grant with: echo \"$USER ALL=(ALL) NOPASSWD: /usr/sbin/spindump\" | sudo tee /etc/sudoers.d/hangwatch)"
      fi
    } >> "$CAP" 2>&1
  fi

  # rotation: drop logs older than 7 days
  find "$LOGDIR" -name "*.log" -mtime +7 -delete 2>/dev/null
  find "$LOGDIR" -name "hang-*" -mtime +14 -delete 2>/dev/null
  sleep 15
done
