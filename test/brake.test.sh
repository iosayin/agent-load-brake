#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2317,SC2329  # assertions are evaluated lazily with eval (single quotes on purpose)
# End-to-end test of hook/agent-load-brake.py with fake `claude` processes. It never touches real sessions: its own MATCH
# pattern, its own state/ticket/log directory and a fake measurement (independent of the machine's real load).
#   Round 1: ceiling 2 -> A, B pass; C and then D wait; an interactive session (no --print) passes without waiting;
#            when A ends C passes first (first come, first served) and D keeps waiting; when B ends D passes.
#   Round 2: the ceiling stays full -> F is terminated with SIGTERM when its wait runs out (no model call); E, G unaffected.
#   Round 3: the hook's own exit code (2) and its stderr reason.
#   Round 4: heavy signals - load > factor x cores, free memory < 15%, pressure >= 4, swap-out > threshold, free disk
#            < 15 GB - each one alone holds the session for the whole wait and never lets it through; free swap does not;
#            unreadable metrics pass; with 0 running agents the head of the queue passes even when heavy (starvation guard).
#   Round 5: FIFO + persistent ticket: a later arrival never passes first; a terminated task that comes back keeps its place.
#   Round 6: default ceiling 8 -> the 9th waits; load 1.6 x cores -> ceiling 4.
#   Round 7: kill switch file -> passes without waiting even when heavy.
#   Round 8: Linux metrics from a fake /proc (meminfo, PSI, vmstat), the JSON config file and --status.
#   Round 9: state directory safety - a group/other-writable or symlinked state_dir is refused (the session passes, a
#            planted lock symlink is never followed); new directories are 0700; the default is per-user, never /tmp.
#   Every decision is read from the hook's exit code (0 passed, 2 terminated).
# Usage: bash test/brake.test.sh   (exit 0 = every assertion held). Polls for events instead of fixed sleeps.
set -uo pipefail

HOOK="$(cd "$(dirname "$0")/.." && pwd)/hook/agent-load-brake.py"
PY=${PYTHON:-python3}
T=$(mktemp -d "${TMPDIR:-/tmp}/agent-load-brake-test.XXXXXX")
trap 'pkill -f "$T/" 2>/dev/null; rm -r "$T"' EXIT
mkdir -p "$T/bin" "$T/once"
for v in $(env | sed -n 's/^\(AGENT_LOAD_BRAKE_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
unset PAPERCLIP_TASK_ID PAPERCLIP_AGENT_ID   # the test may itself run inside an agent session: tickets only from the test
export AGENT_LOAD_BRAKE_MATCH="$T/fake-orchestrator/" AGENT_LOAD_BRAKE_STATE_DIR="$T/state"
export AGENT_LOAD_BRAKE_LOG_FILE="$T/brake.log" AGENT_LOAD_BRAKE_KILL_SWITCH="$T/disabled"
export AGENT_LOAD_BRAKE_CONFIG="$T/config.json" AGENT_LOAD_BRAKE_CACHE_SECONDS=0
export AGENT_LOAD_BRAKE_MAX_AGENTS=2 AGENT_LOAD_BRAKE_POLL_SECONDS=0.3
export AGENT_LOAD_BRAKE_HEAVY_LOAD_PER_CORE=1000 AGENT_LOAD_BRAKE_MID_LOAD_PER_CORE=1000
export AGENT_LOAD_BRAKE_MEASURE="load=1 mem_free=90 pressure=1 swap_out=0 disk_free=100"
: > "$T/events"; : > "$T/brake.log"
CORES=$($PY -c 'import os; print(os.cpu_count() or 8)')

# Fake claude (session): runs the hook as a child process (as Claude Code does: claude -> hook), then the "session" goes on
# until $T/stop-<name> exists.
cat > "$T/bin/claude" <<EOF
#!/usr/bin/env bash
$PY "$HOOK" </dev/null; code=\$?
echo "\$NAME hook=\$code" >> "$T/events"
while [[ ! -e "$T/stop-\$NAME" ]]; do sleep 0.2; done
echo "\$NAME ended" >> "$T/events"
EOF
# Fake claude (one shot): ignores SIGTERM, writes the hook's exit code and duration to $T/code, never starts a session.
cat > "$T/once/claude" <<EOF
#!/usr/bin/env bash
trap '' TERM
start=\$(date +%s); $PY "$HOOK" </dev/null 2>"$T/stderr"; code=\$?
echo "hook=\$code took=\$((\$(date +%s) - start))" > "$T/code"
EOF
chmod +x "$T/bin/claude" "$T/once/claude"
PROMPT=(--append-system-prompt-file "$T/fake-orchestrator/instances/x/prompt.md")
agent() { NAME=$1 "$T/bin/claude" --print "${PROMPT[@]}" & }
interactive() { NAME=$1 "$T/bin/claude" --resume abc & }   # an interactive session: no --print, no orchestrator path

fail=0; count=0
check() { count=$((count + 1)); if eval "$2"; then echo "PASS  $1"; else echo "FAIL  $1"; fail=1; fi; }
code() { awk -v a="$1" '$1==a && $2 ~ /^hook=/ {sub("hook=","",$2); print $2}' "$T/events"; }
poll() { local i; for ((i = 0; i < 150; i++)); do eval "$1" && return 0; sleep 0.2; done; echo "  (timeout: $1)"; return 1; }
queued() { poll "grep -q 'waiting.*pid=$1\$' '$T/brake.log'"; }
running() { local n=0 a; for a in "$@"; do [[ -n $(code "$a") ]] && ! grep -q "^$a ended" "$T/events" && n=$((n + 1)); done; echo "$n"; }
finish() { local a; for a in "$@"; do touch "$T/stop-$a"; done; for a in "$@"; do poll "grep -q '^$a ended' '$T/events'"; done; }
once() { env "$@" "$T/once/claude" --print "${PROMPT[@]}"; sed -E 's/^hook=([0-9]+).*/\1/' "$T/code"; }

echo "-- Round 1: ceiling 2"
export AGENT_LOAD_BRAKE_MAX_WAIT_SECONDS=60
agent A; poll '[[ -n $(code A) ]]'
agent B; poll '[[ -n $(code B) ]]'
agent C; CP=$!; queued $CP
agent D; DP=$!; queued $DP
interactive I; poll '[[ -n $(code I) ]]'
check "A and B passed (hook 0)" '[[ $(code A) == 0 && $(code B) == 0 ]]'
check "C and D are waiting" '[[ -z $(code C) && -z $(code D) ]]'
check "interactive session passed without waiting while the ceiling is full (hook 0)" '[[ $(code I) == 0 ]]'
touch "$T/stop-A"; poll '[[ -n $(code C) ]]'; sleep 1
check "A ended -> C (first in line) passed, D still waiting" '[[ $(code C) == 0 && -z $(code D) ]]'
check "2 agents running (B, C)" '[[ $(running A B C D) == 2 ]]'
touch "$T/stop-B"; poll '[[ -n $(code D) ]]'
check "B ended -> D passed" '[[ $(code D) == 0 ]]'
touch "$T/stop-C" "$T/stop-D" "$T/stop-I"; wait
sed 's/^/  log: /' "$T/brake.log"

echo "-- Round 2: the ceiling stays full (E, G running), F finds no slot within 3 s"
: > "$T/brake.log"
export AGENT_LOAD_BRAKE_MAX_WAIT_SECONDS=3
agent E; poll '[[ -n $(code E) ]]'
agent G; poll '[[ -n $(code G) ]]'
agent F; FP=$!
wait $FP; fcode=$?
check "the hook logged that it terminated F (pid=$FP)" 'grep -q "terminated.*pid=$FP\$" "$T/brake.log"'
check "F ended by SIGTERM (exit $fcode = 143) and never reached the session body" '[[ $fcode == 143 && -z $(code F) ]]'
check "E and G unaffected (hook 0, still running)" '[[ $(code E) == 0 && $(code G) == 0 && $(running E G) == 2 ]]'
sed 's/^/  log: /' "$T/brake.log"
finish E G

echo "-- Round 3: the hook's exit code (ceiling 0; the fake parent ignores SIGTERM)"
AGENT_LOAD_BRAKE_MAX_AGENTS=0 AGENT_LOAD_BRAKE_MAX_WAIT_SECONDS=1 AGENT_LOAD_BRAKE_MEASURE="mem_free=90 pressure=1" \
  "$T/once/claude" --print "${PROMPT[@]}"
check "hook exited 2 and wrote the reason to stderr" 'grep -q "^hook=2 " "$T/code" && grep -q "ceiling full" "$T/stderr"'
sed 's/^/  stderr: /' "$T/stderr"

echo "-- Round 4: heavy signals (ceiling 100; Z is running -> the starvation guard is not in play)"
AGENT_LOAD_BRAKE_MAX_AGENTS=100 agent Z; poll '[[ -n $(code Z) ]]'
# heavy <AGENT_LOAD_BRAKE_MEASURE or "-" (real measurement)> [extra env...] -> hook exit code; the log is reset on each call
heavy() {
  local m=$1 envs
  shift
  if [[ $m == - ]]; then envs=(-u AGENT_LOAD_BRAKE_MEASURE); else envs=(AGENT_LOAD_BRAKE_MEASURE="$m"); fi
  : > "$T/brake.log"
  env "${envs[@]}" AGENT_LOAD_BRAKE_MAX_AGENTS=100 AGENT_LOAD_BRAKE_MAX_WAIT_SECONDS=1 AGENT_LOAD_BRAKE_HEAVY_LOAD_PER_CORE=2 \
    AGENT_LOAD_BRAKE_MID_LOAD_PER_CORE=1000 "$@" "$T/once/claude" --print "${PROMPT[@]}"
  sed 's/^/    log: /' "$T/brake.log" >&2
  sed -E 's/^hook=([0-9]+).*/\1/' "$T/code"
}
heavywait() { grep -q "waiting (heavy" "$T/brake.log"; }
nopass() { ! grep -q "passed" "$T/brake.log"; }
H=$($PY -c "print(5.5 * $CORES)"); L=$($PY -c "print(0.5 * $CORES)")
k=$(heavy "load=$H mem_free=40 pressure=2" AGENT_LOAD_BRAKE_MAX_WAIT_SECONDS=8)
s=$(sed -E 's/.*took=([0-9]+).*/\1/' "$T/code")
check "load $H (5.5 x cores), wait 8 s -> never let through (hook $k = 2, $s s >= 8), no 'passed' in the log" \
  '[[ $k == 2 && $s -ge 8 ]] && heavywait && nopass && grep -q "terminated" "$T/brake.log"'
k=$(heavy "load=$L mem_free=40 pressure=2" AGENT_LOAD_BRAKE_MAX_WAIT_SECONDS=8)
check "positive pair: load $L -> passed (hook $k = 0)" '[[ $k == 0 ]] && ! heavywait'
k=$(heavy "load=1 mem_free=60 pressure=1 swap_out=0 disk_free=10")
check "free disk 10 GB -> heavy (hook $k = 2), heavy=disk" '[[ $k == 2 ]] && grep -q "heavy=disk" "$T/brake.log" && nopass'
k=$(heavy "load=1 mem_free=60 pressure=1 swap_out=0 disk_free=40")
check "positive pair: free disk 40 GB -> passed (hook $k = 0)" '[[ $k == 0 ]]'
k=$(heavy "load=1 mem_free=60 pressure=1 swap_out=24 disk_free=40")
check "swap-out 24 MB/s (threshold 16) -> heavy (hook $k = 2), heavy=swap" '[[ $k == 2 ]] && grep -q "heavy=swap" "$T/brake.log"'
k=$(heavy "load=1 mem_free=60 pressure=1 swap_out=14 disk_free=40")
check "positive pair: swap-out 14 MB/s -> passed (hook $k = 0)" '[[ $k == 0 ]]'
k=$(heavy "mem_free=40 pressure=1 swap_free=0 load=1")
check "free swap 0 MB -> not a signal (hook $k = 0)" '[[ $k == 0 ]] && ! heavywait'
k=$(heavy "mem_free=8 pressure=1 swap_free=5000 load=1")
check "free memory 8% -> heavy (hook $k = 2), log shows mem_free=8%" '[[ $k == 2 ]] && heavywait && grep -q "mem_free=8% " "$T/brake.log"'
k=$(heavy "mem_free=14 pressure=1 load=1")
check "edge: free memory 14% -> heavy (hook $k = 2)" '[[ $k == 2 ]]'
k=$(heavy "mem_free=15 pressure=1 load=1")
check "edge: free memory 15% -> light (hook $k = 0)" '[[ $k == 0 ]]'
k=$(heavy "mem_free=60 pressure=4 load=1")
check "pressure 4 alone -> heavy (hook $k = 2)" '[[ $k == 2 ]] && heavywait'
k=$(heavy "mem_free=60 pressure=2 load=1")
check "pressure 2 (warning) -> light (hook $k = 0)" '[[ $k == 0 ]]'
k=$(heavy - AGENT_LOAD_BRAKE_SYSCTL="$T/none/sysctl" AGENT_LOAD_BRAKE_VM_STAT="$T/none/vm_stat" \
  AGENT_LOAD_BRAKE_PROC="$T/none" AGENT_LOAD_BRAKE_DISK_PATH="$T/none" AGENT_LOAD_BRAKE_HEAVY_LOAD_PER_CORE=1000)
check "sysctl/vm_stat/proc/disk unreadable -> passes (hook $k = 0), no wait in the log" '[[ $k == 0 ]] && ! heavywait'
k=$(heavy "garbage-measurement" AGENT_LOAD_BRAKE_HEAVY_LOAD_PER_CORE=1000)
check "measurement cannot be parsed -> passes (hook $k = 0)" '[[ $k == 0 ]]'
k=$(heavy - AGENT_LOAD_BRAKE_MAX_AGENTS=0 AGENT_LOAD_BRAKE_HEAVY_LOAD_PER_CORE=1000 AGENT_LOAD_BRAKE_SWAP_OUT_MBPS=1e12 \
  AGENT_LOAD_BRAKE_MIN_FREE_DISK_GB=0 AGENT_LOAD_BRAKE_MIN_FREE_MEM_PCT=0 AGENT_LOAD_BRAKE_PSI_CRITICAL=1000)
check "real measurement path: numeric swap_out and disk_free in the log (ceiling 0 -> hook $k = 2)" \
  '[[ $k == 2 ]] && grep -Eq "swap_out=[0-9.]+MB/s disk_free=[0-9]+GB" "$T/brake.log"'
finish Z
k=$(heavy "load=$H mem_free=40 pressure=2")
check "starvation guard: 0 running, load $H -> the single session at the head passed (hook $k = 0)" '[[ $k == 0 ]]'

echo "-- Round 5: FIFO + persistent ticket (ceiling 1)"
: > "$T/brake.log"
export AGENT_LOAD_BRAKE_MAX_AGENTS=1 AGENT_LOAD_BRAKE_MAX_WAIT_SECONDS=60
agent H; poll '[[ -n $(code H) ]]'
PAPERCLIP_TASK_ID=task-B PAPERCLIP_AGENT_ID=agent-1 agent B2; BP=$!; queued $BP
sleep 1.1   # queue times more than a second apart
PAPERCLIP_TASK_ID=task-C PAPERCLIP_AGENT_ID=agent-2 agent C2; CP=$!; queued $CP
touch "$T/stop-H"; poll '[[ -n $(code B2) ]]'; sleep 1
check "H ended -> B2 (first in line) passed, C2 (later) did not" '[[ $(code B2) == 0 && -z $(code C2) ]]'
finish B2; poll '[[ -n $(code C2) ]]'
check "B2 ended -> C2 passed" '[[ $(code C2) == 0 ]]'
finish C2
# Ticket: P (task-P) arrives first and is terminated after 3 s (ticket stays); Q arrives later; P comes back -> passes before Q.
: > "$T/brake.log"
agent H2; poll '[[ -n $(code H2) ]]'
PAPERCLIP_TASK_ID=task-P PAPERCLIP_AGENT_ID=agent-3 AGENT_LOAD_BRAKE_MAX_WAIT_SECONDS=3 agent P1; PP=$!; queued $PP
sleep 1.1
PAPERCLIP_TASK_ID=task-Q PAPERCLIP_AGENT_ID=agent-4 agent Q1; QP=$!; queued $QP
wait $PP; pcode=$?
check "P1 terminated when its wait ran out (exit $pcode = 143), its ticket is kept" \
  '[[ $pcode == 143 ]] && [[ $(ls "$T/state/tickets" | wc -l) -ge 2 ]]'
PAPERCLIP_TASK_ID=task-P PAPERCLIP_AGENT_ID=agent-3 agent P2; P2P=$!; queued $P2P
check "P2 came back with the old ticket (ticket=old in the log)" 'grep -q "ticket=old pid=$P2P\$" "$T/brake.log"'
touch "$T/stop-H2"; poll '[[ -n $(code P2) || -n $(code Q1) ]]'; sleep 1
check "H2 ended -> P2 (old position) passed, Q1 still waiting although it queued before P2 came back" \
  '[[ $(code P2) == 0 && -z $(code Q1) ]]'
finish P2; poll '[[ -n $(code Q1) ]]'
check "P2 ended -> Q1 passed; tickets of passed sessions are removed" '[[ $(code Q1) == 0 && $(ls "$T/state/tickets" | wc -l) -eq 0 ]]'
finish Q1
sed 's/^/  log: /' "$T/brake.log"

echo "-- Round 6: default ceiling 8 and dynamic ceiling 4 ($CORES cores)"
: > "$T/brake.log"
unset AGENT_LOAD_BRAKE_MAX_AGENTS
export AGENT_LOAD_BRAKE_MAX_WAIT_SECONDS=60 AGENT_LOAD_BRAKE_HEAVY_LOAD_PER_CORE=2 AGENT_LOAD_BRAKE_MID_LOAD_PER_CORE=1.5
for a in S1 S2 S3 S4 S5 S6 S7 S8; do agent $a; poll "[[ -n \$(code $a) ]]"; done
check "8 agents passed" '[[ $(running S1 S2 S3 S4 S5 S6 S7 S8) == 8 ]]'
k=$(once AGENT_LOAD_BRAKE_MAX_WAIT_SECONDS=1)
check "8 running -> the 9th waited (hook $k = 2), ceiling=8" '[[ $k == 2 ]] && grep -q "ceiling full running=8/8" "$T/brake.log"'
finish S5 S6 S7 S8
Y16=$($PY -c "print(1.6 * $CORES)"); Y5=$($PY -c "print(0.5 * $CORES)")
: > "$T/brake.log"
k=$(once AGENT_LOAD_BRAKE_MAX_WAIT_SECONDS=1 AGENT_LOAD_BRAKE_MEASURE="load=$Y16 mem_free=90 pressure=1")
check "4 running, load $Y16 (1.6 x cores) -> ceiling 4, waited (hook $k = 2)" '[[ $k == 2 ]] && grep -q "running=4/4" "$T/brake.log"'
k=$(once AGENT_LOAD_BRAKE_MAX_WAIT_SECONDS=1 AGENT_LOAD_BRAKE_MEASURE="load=$Y5 mem_free=90 pressure=1")
check "positive pair: 4 running, load $Y5 -> ceiling 8, passed (hook $k = 0)" '[[ $k == 0 ]]'
k=$(once AGENT_LOAD_BRAKE_MAX_WAIT_SECONDS=1 AGENT_LOAD_BRAKE_MEASURE="load=$Y5 mem_free=20 pressure=1")
check "4 running, free memory 20% (< 25%) -> ceiling 4, waited (hook $k = 2)" '[[ $k == 2 ]]'
finish S4
k=$(once AGENT_LOAD_BRAKE_MAX_WAIT_SECONDS=1 AGENT_LOAD_BRAKE_MEASURE="load=$Y16 mem_free=90 pressure=1")
check "positive pair: 3 running, load $Y16 -> ceiling 4, passed (hook $k = 0)" '[[ $k == 0 ]]'

echo "-- Round 7: kill switch (3 agents running, heavy)"
: > "$T/brake.log"; touch "$T/disabled"
k=$(once AGENT_LOAD_BRAKE_MAX_WAIT_SECONDS=5 AGENT_LOAD_BRAKE_MEASURE="load=$H mem_free=5 pressure=4")
check "with the switch the hook passed at once while heavy (hook $k = 0), log says 'disabled'" \
  '[[ $k == 0 ]] && grep -q "disabled:" "$T/brake.log"'
rm "$T/disabled"
k=$(once AGENT_LOAD_BRAKE_MAX_WAIT_SECONDS=1 AGENT_LOAD_BRAKE_MEASURE="load=$H mem_free=5 pressure=4")
check "negative pair: switch removed, same measurement -> waited (hook $k = 2)" '[[ $k == 2 ]]'

echo "-- Round 8: Linux /proc metrics, config file, --status (3 agents running)"
P="$T/proc"; mkdir -p "$P/pressure"
printf 'MemTotal:       16000000 kB\nMemAvailable:    1600000 kB\nSwapFree:        2048000 kB\n' > "$P/meminfo"
printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=0\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' > "$P/pressure/memory"
printf 'pswpin 0\npswpout 100\n' > "$P/vmstat"
k=$(heavy - AGENT_LOAD_BRAKE_PROC="$P" AGENT_LOAD_BRAKE_HEAVY_LOAD_PER_CORE=1000 AGENT_LOAD_BRAKE_DISK_PATH="$T/none" \
  AGENT_LOAD_BRAKE_SAMPLE_SECONDS=0.1)
check "MemAvailable 10% of MemTotal -> heavy=memory (hook $k = 2), mem_free=10%, swap_free=2000MB" \
  '[[ $k == 2 ]] && grep -q "mem_free=10% pressure=1 swap_out=0.0MB/s" "$T/brake.log" && grep -q "swap_free=2000MB" "$T/brake.log"'
printf 'MemTotal:       16000000 kB\nMemAvailable:    8000000 kB\n' > "$P/meminfo"
printf 'some avg10=40.00 avg60=0.00 avg300=0.00 total=0\nfull avg10=25.00 avg60=0.00 avg300=0.00 total=0\n' > "$P/pressure/memory"
k=$(heavy - AGENT_LOAD_BRAKE_PROC="$P" AGENT_LOAD_BRAKE_HEAVY_LOAD_PER_CORE=1000 AGENT_LOAD_BRAKE_DISK_PATH="$T/none" \
  AGENT_LOAD_BRAKE_SAMPLE_SECONDS=0.1)
check "PSI full avg10 25 (>= 10) -> heavy=pressure (hook $k = 2)" '[[ $k == 2 ]] && grep -q "heavy=pressure" "$T/brake.log"'
printf 'some avg10=40.00 avg60=0.00 avg300=0.00 total=0\nfull avg10=5.00 avg60=0.00 avg300=0.00 total=0\n' > "$P/pressure/memory"
k=$(heavy - AGENT_LOAD_BRAKE_PROC="$P" AGENT_LOAD_BRAKE_HEAVY_LOAD_PER_CORE=1000 AGENT_LOAD_BRAKE_DISK_PATH="$T/none" \
  AGENT_LOAD_BRAKE_SAMPLE_SECONDS=0.1)
check "positive pair: PSI full avg10 5, some 40 -> warning only (pressure=2), passed (hook $k = 0)" '[[ $k == 0 ]]'
echo '{"max_agents": 3, "mid_max_agents": 2}' > "$T/config.json"
: > "$T/brake.log"
k=$(once AGENT_LOAD_BRAKE_MAX_WAIT_SECONDS=1)
check "config file max_agents 3 with 3 running -> waited (hook $k = 2), ceiling 3" '[[ $k == 2 ]] && grep -q "running=3/3" "$T/brake.log"'
k=$(once AGENT_LOAD_BRAKE_MAX_WAIT_SECONDS=1 AGENT_LOAD_BRAKE_MAX_AGENTS=4)
check "environment overrides the config file (MAX_AGENTS=4 -> passed, hook $k = 0)" '[[ $k == 0 ]]'
rm "$T/config.json"
out=$(AGENT_LOAD_BRAKE_MEASURE="load=1 mem_free=8 pressure=1" $PY "$HOOK" --status)
printf '  status: %s\n' "${out//$'\n'/$'\n'  status: }"
check "--status prints HEAVY, heavy=memory and the agent count without waiting" \
  'grep -q "agent-load-brake: HEAVY" <<<"$out" && grep -q "heavy=memory" <<<"$out" && grep -q "agents=3 " <<<"$out"'
finish S1 S2 S3

echo "-- Round 9: state directory safety (no agents running; MAX_AGENTS=0 would hold every session)"
printf 'precious\n' > "$T/victim"
mkdir -m 0777 "$T/shared"; chmod 0777 "$T/shared"; ln -s "$T/victim" "$T/shared/lock"; mkdir -m 0777 "$T/shared/waiting"
: > "$T/brake.log"
k=$(once AGENT_LOAD_BRAKE_STATE_DIR="$T/shared" AGENT_LOAD_BRAKE_MAX_AGENTS=0 AGENT_LOAD_BRAKE_MAX_WAIT_SECONDS=2)
check "group/other-writable state_dir with a planted lock symlink: passed (hook $k = 0), victim untouched, logged" \
  '[[ $k == 0 ]] && [[ $(cat "$T/victim") == precious ]] && grep -q "unsafe state_dir.*mode 777" "$T/brake.log"'
mkdir -m 0700 "$T/real"; ln -s "$T/real" "$T/linked"
: > "$T/brake.log"
k=$(once AGENT_LOAD_BRAKE_STATE_DIR="$T/linked" AGENT_LOAD_BRAKE_MAX_AGENTS=0 AGENT_LOAD_BRAKE_MAX_WAIT_SECONDS=2)
check "state_dir that is a symlink: refused, passed (hook $k = 0)" \
  '[[ $k == 0 ]] && grep -q "unsafe state_dir.*symlink" "$T/brake.log" && [[ -z $(ls "$T/real") ]]'
mkdir -m 0700 "$T/own"; mkdir -m 0700 "$T/own/waiting"; ln -s "$T/victim" "$T/own/lock"
: > "$T/brake.log"
k=$(once AGENT_LOAD_BRAKE_STATE_DIR="$T/own" AGENT_LOAD_BRAKE_MAX_AGENTS=0 AGENT_LOAD_BRAKE_MAX_WAIT_SECONDS=2)
check "lock symlink inside a private state_dir: not followed (victim untouched), passed (hook $k = 0)" \
  '[[ $k == 0 ]] && [[ $(cat "$T/victim") == precious ]] && grep -q "error, passing" "$T/brake.log"'
k=$(once AGENT_LOAD_BRAKE_STATE_DIR="$T/fresh/state" AGENT_LOAD_BRAKE_MAX_AGENTS=0 AGENT_LOAD_BRAKE_MAX_WAIT_SECONDS=1)
mode=$($PY -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.lstat(sys.argv[1]).st_mode)))' "$T/fresh/state")
check "positive pair: a new state_dir is created 0700 and the brake still holds (hook $k = 2, mode $mode)" \
  '[[ $k == 2 && $mode == 0o700 ]]'
out=$(env -u AGENT_LOAD_BRAKE_STATE_DIR -u XDG_RUNTIME_DIR HOME="$T/home" "$PY" "$HOOK" --status)
check "default state_dir without XDG_RUNTIME_DIR is ~/.local/state/agent-load-brake/run (0700), not /tmp" \
  '[[ -d "$T/home/.local/state/agent-load-brake/run" ]] && [[ $($PY -c "import os,stat,sys; print(oct(stat.S_IMODE(os.lstat(sys.argv[1]).st_mode)))" "$T/home/.local/state/agent-load-brake/run") == 0o700 ]]'
mkdir -m 0700 "$T/xdg"
out=$(env -u AGENT_LOAD_BRAKE_STATE_DIR XDG_RUNTIME_DIR="$T/xdg" HOME="$T/home2" "$PY" "$HOOK" --status)
check "default state_dir with XDG_RUNTIME_DIR is \$XDG_RUNTIME_DIR/agent-load-brake" '[[ -d "$T/xdg/agent-load-brake/waiting" ]]'
chmod 0755 "$T/own"
out=$(AGENT_LOAD_BRAKE_STATE_DIR="$T/own" $PY "$HOOK" --status); rc=$?
check "--status reports an unsafe state_dir (exit $rc = 1)" '[[ $rc == 1 ]] && grep -q "unsafe state_dir" <<<"$out"'

echo "$count assertions, $([[ $fail == 0 ]] && echo "all passed" || echo "some FAILED")"
exit $fail
