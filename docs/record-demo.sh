#!/usr/bin/env bash
# Records the timeline behind docs/demo.gif from a real run: the installed hook, real load from busy processes, real
# measurements and decisions. Run it on a spare Linux/macOS machine or VM (it keeps every core busy for a minute or two).
#   1. two headless sessions start on an idle machine and pass;
#   2. busy processes push the 1-min load above heavy_load_per_core x cores (lowered to 1.0 for the demo);
#   3. two more sessions arrive and are queued ("heavy");
#   4. the busy processes stop, the load falls, the queued sessions pass in arrival order.
# Usage: bash docs/record-demo.sh <output dir>   -> <dir>/timeline.log (events + brake.log lines, sorted) and brake.log
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT=$(mkdir -p "${1:?output dir}" && cd "$1" && pwd)
W=$(mktemp -d "${TMPDIR:-/tmp}/agent-load-brake-demo.XXXXXX")
BUSY=()
cleanup() {
  [[ ${#BUSY[@]} -gt 0 ]] && kill "${BUSY[@]}" 2>/dev/null
  touch "$W"/stop-agent-{1,2,3,4}; sleep 1
  HOME="$W/home" node "$ROOT/bin/cli.mjs" uninstall >/dev/null 2>&1 || true
  pkill -f "$W/" 2>/dev/null || true
  rm -r "$W"
}
trap cleanup EXIT
export HOME="$W/home"
unset CLAUDE_CONFIG_DIR PAPERCLIP_TASK_ID PAPERCLIP_AGENT_ID
for v in $(env | sed -n 's/^\(AGENT_LOAD_BRAKE_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
CORES=$(getconf _NPROCESSORS_ONLN)
mkdir -p "$HOME/.config/agent-load-brake" "$W/bin"
cat > "$HOME/.config/agent-load-brake/config.json" <<EOF
{"heavy_load_per_core": 1.0, "mid_load_per_core": 0.75, "poll_seconds": 3, "cache_seconds": 2, "match": "$W/"}
EOF
node "$ROOT/bin/cli.mjs" install >/dev/null
CMD=$(node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  console.log(s.hooks.SessionStart.flatMap(g=>g.hooks).find(h=>h.command.includes("agent-load-brake.py")).command)' \
  "$HOME/.claude/settings.json")
TL="$W/timeline"; : > "$TL"
event() { echo "$(date '+%Y-%m-%d %H:%M:%S') # $*" | tee -a "$TL"; }
cat > "$W/bin/claude" <<EOF
#!/usr/bin/env bash
echo '{"hook_event_name":"SessionStart","source":"startup"}' | sh -c '$CMD'
echo "\$(date '+%Y-%m-%d %H:%M:%S') # \$NAME: session started (hook exit \$?)" >> "$TL"
while [[ ! -e "$W/stop-\$NAME" ]]; do sleep 0.5; done
EOF
chmod +x "$W/bin/claude"
agent() { NAME=$1 "$W/bin/claude" --print "demo task" & }
status() { python3 "$HOME/.claude/hooks/agent-load-brake.py" --status | sed -n 2p | sed 's/^ *//'; }
load1() { python3 -c 'import os; print(f"{os.getloadavg()[0]:.1f}")'; }
started() { grep -q "# $1: session started" "$TL"; }

event "machine: $CORES cores, demo thresholds: heavy at load > $CORES, moderate at load > $((CORES * 3 / 4))"
event "status: $(status)"
agent agent-1; agent agent-2
for _ in $(seq 40); do started agent-1 && started agent-2 && break; sleep 0.5; done
event "load generator: $((CORES * 2)) busy processes"
for _ in $(seq $((CORES * 2))); do (while :; do :; done) & BUSY+=($!); done
for _ in $(seq 60); do
  sleep 5; event "load $(load1)"
  python3 "$HOME/.claude/hooks/agent-load-brake.py" --status | grep -q HEAVY && break
done
event "status: $(status)"
agent agent-3; sleep 2; agent agent-4
sleep 20
event "load generator stopped"
kill "${BUSY[@]}"; BUSY=()
for _ in $(seq 60); do
  sleep 5; event "load $(load1)"
  started agent-3 && started agent-4 && break
done
event "status: $(status)"
sleep 1
LOG="$HOME/.local/state/agent-load-brake/brake.log"
cp "$LOG" "$OUT/brake.log"
sort -s -k1,2 "$TL" "$LOG" > "$OUT/timeline.log"
echo "--- $OUT/timeline.log"; cat "$OUT/timeline.log"
started agent-3 && started agent-4 && grep -q "waiting (heavy" "$LOG" && grep -q "passed after" "$LOG"
