#!/usr/bin/env bash
# Clean-machine smoke test of the published artifact: `npm pack`, then in a throwaway HOME with its own npm cache:
#   npx ./agent-load-brake-<version>.tgz install --dry-run   -> nothing written
#   npx ./agent-load-brake-<version>.tgz install             -> hook registered
#   one session start through the registered command          -> the hook runs (passes, then waits/stops with ceiling 0)
#   npx ./agent-load-brake-<version>.tgz uninstall           -> settings file identical to the original (empty diff)
# Usage: bash test/smoke-pack.sh   (exit 0 = all steps held). Prints every command and its output.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W=$(mktemp -d "${TMPDIR:-/tmp}/agent-load-brake-smoke.XXXXXX")
trap 'rm -r "$W"' EXIT
export HOME="$W/home" npm_config_cache="$W/npm-cache" npm_config_update_notifier=false npm_config_fund=false
unset CLAUDE_CONFIG_DIR PAPERCLIP_TASK_ID PAPERCLIP_AGENT_ID
for v in $(env | sed -n 's/^\(AGENT_LOAD_BRAKE_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
export AGENT_LOAD_BRAKE_MATCH="$W/"   # count only this test's stand-in session, not real agents on the machine
mkdir -p "$HOME/.claude" "$W/work" "$W/bin"
S="$HOME/.claude/settings.json"
step() { echo; echo "\$ $*"; "$@"; }
ok() { echo "OK    $1"; }
die() { echo "FAIL  $1"; exit 1; }

echo "node $(node --version), npm $(npm --version), $(python3 --version), $(uname -sm)"
TGZ=$(cd "$ROOT" && npm pack --silent --pack-destination "$W/work")
echo "packed: $TGZ ($(cd "$W/work" && shasum -a 256 "$TGZ" | cut -c1-16)…)"
tar -tzf "$W/work/$TGZ" | sed 's/^/  /'
cd "$W/work"

# A user's existing settings, deliberately not in the installer's formatting.
printf '{\n    "model": "sonnet",\n    "hooks": {\n        "Stop": [{"hooks": [{"type": "command", "command": "true"}]}]\n    }\n}\n' > "$S"
cp "$S" "$W/settings.orig"

step npx --yes "./$TGZ" install --dry-run
if ! cmp -s "$S" "$W/settings.orig" || [[ -e $HOME/.claude/hooks || -e $HOME/.config ]]; then die "dry run wrote something"; fi
ok "dry run: settings unchanged, no hook script, no state written"

step npx --yes "./$TGZ" install
grep -q 'agent-load-brake.py' "$S" || die "hook not registered"
[[ -x $HOME/.claude/hooks/agent-load-brake.py ]] || die "hook script missing"
ok "install: SessionStart hook registered, script at ~/.claude/hooks/agent-load-brake.py"
echo "--- settings after install:"; cat "$S"

# Start one "session" the way Claude Code does: the hook command runs as a child of the claude process, JSON on stdin.
CMD=$(node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  console.log(s.hooks.SessionStart.flatMap(g=>g.hooks).find(h=>h.command.includes("agent-load-brake.py")).command)' "$S")
cat > "$W/bin/claude" <<EOF
#!/usr/bin/env bash
trap '' TERM   # this stand-in ignores the hook's SIGTERM so it can report the exit code
echo '{"hook_event_name":"SessionStart","source":"startup"}' | sh -c '$CMD'
echo "hook exit=\$?"
EOF
chmod +x "$W/bin/claude"
echo; echo "\$ claude --print 'hello'   # stand-in parent running: $CMD"
out=$("$W/bin/claude" --print hello); echo "$out"
[[ $out == "hook exit=0" ]] || die "hook did not pass on an idle machine"
ok "session start: hook ran and let the session through (exit 0)"
echo; echo "\$ AGENT_LOAD_BRAKE_MAX_AGENTS=0 AGENT_LOAD_BRAKE_MAX_WAIT_SECONDS=2 claude --print 'hello'"
out=$(AGENT_LOAD_BRAKE_MAX_AGENTS=0 AGENT_LOAD_BRAKE_MAX_WAIT_SECONDS=2 AGENT_LOAD_BRAKE_POLL_SECONDS=0.5 \
  "$W/bin/claude" --print hello 2>&1); echo "$out"
LOG="$HOME/.local/state/agent-load-brake/brake.log"
echo "--- brake.log:"; sed "s|$HOME|~|g" "$LOG"
if ! [[ $out == *"hook exit=2"* ]] || ! grep -q "waiting (ceiling full running=0/0" "$LOG" || ! grep -q "terminated" "$LOG"; then
  die "hook did not hold the session with ceiling 0"
fi
ok "same hook with ceiling 0: waited, then stopped the session before any model call (exit 2)"

step npx --yes "./$TGZ" uninstall
echo; echo "\$ diff -u settings.orig settings.json"
if diff -u "$W/settings.orig" "$S"; then echo "(empty diff)"; else die "settings differ after uninstall"; fi
[[ ! -e $HOME/.claude/hooks/agent-load-brake.py ]] || die "hook script left behind"
ok "uninstall: settings byte-identical to the original, hook script removed"
echo; echo "SMOKE OK"
