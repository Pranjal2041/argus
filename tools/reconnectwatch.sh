#!/bin/zsh
# Argus reconnectwatch — persistent frame-delivery probe against every babel
# broker. Companion to hangwatch (same Logs dir, correlatable timestamps).
# Catches the "panes stuck reconnecting" blackhole episodes with evidence:
# a WS dial that handshakes but delivers no first frame = poisoned flow.
# Probe source: tools/wsprobe/main.go → binary at ~/.universal-tmux/wsprobe.

LOGDIR="$HOME/Library/Logs/argus-hangwatch"
PROBE="$HOME/.universal-tmux/wsprobe"
mkdir -p "$LOGDIR"

while true; do
  LOG="$LOGDIR/reconnect-$(date +%F).log"
  TS=$(date +%H:%M:%S)
  # discover babel brokers from tailscale (ut-* linux peers)
  HOSTS=$(/Applications/Tailscale.app/Contents/MacOS/Tailscale status 2>/dev/null | awk '/ut-babel|ut-orchard/{print $2}')
  LINE="$TS"
  for h in ${(f)HOSTS}; do
    S=$(curl -sk --max-time 6 "https://$h.tail2f43bc.ts.net:8722/sessions" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin)['sessions'][0]['name'])" 2>/dev/null)
    [ -z "$S" ] && { LINE="$LINE $h:HTTP-DEAD"; continue }
    R=$("$PROBE" "wss://$h.tail2f43bc.ts.net:8722/ws?session=$S" 2>/dev/null | head -1)
    case "$R" in
      *NO\ FRAMES*) LINE="$LINE $h:BLACKHOLE" ;;
      *first-frame*) LINE="$LINE $h:ok(${R##* })" ;;
      *) LINE="$LINE $h:DIAL-ERR" ;;
    esac
  done
  echo "$LINE" >> "$LOG"
  find "$LOGDIR" -name "reconnect-*.log" -mtime +7 -delete 2>/dev/null
  sleep 30
done
