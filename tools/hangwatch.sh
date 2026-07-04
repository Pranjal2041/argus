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

  NOW=$(date +%s)
  if [ "$UI_MS" -gt "$THRESH_MS" ] && [ $((NOW - last_capture)) -gt "$COOLDOWN" ]; then
    last_capture=$NOW
    CAP="$LOGDIR/hang-$(date +%F-%H%M%S).txt"
    {
      echo "=== HANG DETECTED: ui probe ${UI_MS}ms at $(date) ==="
      echo "--- second probe (still hung?) ---"; echo "ui2=$(ui_probe_ms)ms"
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
