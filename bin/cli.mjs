#!/usr/bin/env node
// agent-load-brake CLI: installs/removes the SessionStart hook in Claude Code's settings. Zero dependencies.
import { spawnSync } from "node:child_process";
import { chmodSync, copyFileSync, existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { delimiter, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { HOOK_FILE, HOOK_TIMEOUT, addHook, hasHook, hookCommand, uninstallPlan } from "../src/settings.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const VERSION = JSON.parse(readFileSync(join(ROOT, "package.json"), "utf8")).version;
const HELP = `agent-load-brake ${VERSION}: queue headless Claude Code sessions while the machine is overloaded

Usage:
  npx agent-load-brake install [--dry-run]     copy the hook and register it in Claude Code's settings
  npx agent-load-brake uninstall [--dry-run]   remove the hook (settings go back to how they were)
  npx agent-load-brake status                  current load, memory, swap, disk and the decision

Options:
  --settings <file>   settings file to edit (default: $CLAUDE_CONFIG_DIR/settings.json or ~/.claude/settings.json)
  --python <path>     Python 3.8+ interpreter for the hook (default: python3 from PATH)
  --dry-run           print what would change, write nothing
`;

const fail = (msg) => {
  console.error(`agent-load-brake: ${msg}`);
  process.exit(1);
};

function parseArgs(argv) {
  const opts = { command: null, dryRun: false, settings: null, python: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--dry-run") opts.dryRun = true;
    else if (a === "--settings" || a === "--python") {
      if (!argv[i + 1]) fail(`${a} needs a value`);
      opts[a.slice(2)] = resolve(argv[++i]);
    } else if (a === "-h" || a === "--help") opts.command = "help";
    else if (a === "-v" || a === "--version") opts.command = "version";
    else if (!opts.command && !a.startsWith("-")) opts.command = a;
    else fail(`unknown argument: ${a}\n\n${HELP}`);
  }
  return opts;
}

const tilde = (p) => (p.startsWith(homedir() + "/") ? "~" + p.slice(homedir().length) : p);
const claudeDir = () => process.env.CLAUDE_CONFIG_DIR || join(homedir(), ".claude");
const stateFile = () => join(homedir(), ".config", "agent-load-brake", "install-state.json");
const hookTarget = () => join(claudeDir(), "hooks", HOOK_FILE);

function findPython(explicit) {
  const candidates = explicit
    ? [explicit]
    : (process.env.PATH || "").split(delimiter).filter(Boolean).map((d) => join(d, "python3"));
  for (const p of candidates) {
    if (!existsSync(p)) continue;
    const r = spawnSync(p, ["-c", "import sys; print(sys.version_info >= (3, 8))"], { encoding: "utf8" });
    if (r.status === 0 && r.stdout.trim() === "True") return p;
  }
  return null;
}

function readSettings(file) {
  if (!existsSync(file)) return { text: null, data: {} };
  const text = readFileSync(file, "utf8");
  if (text.trim() === "") return { text, data: {} };
  try {
    const data = JSON.parse(text);
    if (data === null || typeof data !== "object" || Array.isArray(data)) throw new Error("not a JSON object");
    return { text, data };
  } catch (e) {
    fail(`${tilde(file)} is not valid JSON (${e.message}); fix it first, nothing was changed`);
  }
}

const readState = () => {
  try {
    return JSON.parse(readFileSync(stateFile(), "utf8"));
  } catch {
    return {};
  }
};

function writeAtomic(file, text) {
  mkdirSync(dirname(file), { recursive: true });
  const tmp = `${file}.agent-load-brake.tmp`;
  writeFileSync(tmp, text);
  renameSync(tmp, file);
}

function install(opts, file) {
  if (process.platform === "win32") fail("Windows is not supported (the hook needs macOS or Linux)");
  const python = findPython(opts.python);
  if (!python) fail("Python 3.8+ not found; install it or pass --python <path>");
  const target = hookTarget();
  const command = hookCommand(python, target);
  const { text, data } = readSettings(file);
  const next = addHook(data, command);
  const already = hasHook(data);
  const verb = opts.dryRun ? "would" : "will";
  console.log(`agent-load-brake ${VERSION} install${opts.dryRun ? " (dry run, nothing is written)" : ""}`);
  console.log(`  hook script  : ${verb} copy to ${tilde(target)}`);
  console.log(`  settings     : ${verb} ${already ? "update the existing" : "add a"} SessionStart hook in ${tilde(file)}`);
  console.log(`  command      : ${tilde(command.replaceAll(homedir() + "/", "~/"))}  (timeout ${HOOK_TIMEOUT}s)`);
  if (opts.dryRun) {
    console.log("\nSettings after install:\n" + JSON.stringify(next, null, 2));
    return;
  }
  mkdirSync(dirname(target), { recursive: true });
  copyFileSync(join(ROOT, "hook", HOOK_FILE), target);
  chmodSync(target, 0o755);
  const state = readState();
  if (!state[file]) {
    state[file] = { original: text };
    writeAtomic(stateFile(), JSON.stringify(state, null, 2) + "\n");
  }
  writeAtomic(file, JSON.stringify(next, null, 2) + "\n");
  console.log("\nInstalled. New headless sessions (claude --print / -p) now wait for a free slot.");
  console.log("  check     : npx agent-load-brake status");
  console.log("  turn off  : touch ~/.config/agent-load-brake/disabled   (rm it to turn back on)");
}

function uninstall(opts, file) {
  const { data } = readSettings(file);
  const state = readState();
  const saved = state[file];
  const plan = uninstallPlan(data, saved ? saved.original : undefined);
  const target = hookTarget();
  const verb = opts.dryRun ? "would" : "will";
  console.log(`agent-load-brake ${VERSION} uninstall${opts.dryRun ? " (dry run, nothing is written)" : ""}`);
  if (!hasHook(data) && !saved) console.log(`  settings     : no agent-load-brake hook in ${tilde(file)}, nothing to change`);
  else if (plan.action === "restore") console.log(`  settings     : ${verb} restore ${tilde(file)} exactly as it was before install`);
  else if (plan.action === "delete") console.log(`  settings     : ${verb} remove ${tilde(file)} (it did not exist before install)`);
  else console.log(`  settings     : ${verb} remove the hook from ${tilde(file)} (your other changes are kept)`);
  console.log(`  hook script  : ${verb} remove ${tilde(target)}`);
  if (opts.dryRun) return;
  if (hasHook(data) || saved) {
    if (plan.action === "delete") rmSync(file, { force: true });
    else writeAtomic(file, plan.text);
  }
  rmSync(target, { force: true });
  if (saved) {
    delete state[file];
    if (Object.keys(state).length) writeAtomic(stateFile(), JSON.stringify(state, null, 2) + "\n");
    else rmSync(stateFile(), { force: true });
  }
  console.log("\nUninstalled. The log and an optional config file under ~/.config/agent-load-brake are left in place.");
}

function status(opts, file) {
  const python = findPython(opts.python);
  if (!python) fail("Python 3.8+ not found; install it or pass --python <path>");
  const installed = hasHook(readSettings(file).data);
  const r = spawnSync(python, [join(ROOT, "hook", HOOK_FILE), "--status"], { stdio: "inherit" });
  console.log(`  hook ${installed ? "installed in" : "NOT installed in"} ${tilde(file)}`);
  process.exit(r.status ?? 1);
}

const opts = parseArgs(process.argv.slice(2));
const file = opts.settings || join(claudeDir(), "settings.json");
switch (opts.command) {
  case "install":
    install(opts, file);
    break;
  case "uninstall":
    uninstall(opts, file);
    break;
  case "status":
    status(opts, file);
    break;
  case "version":
    console.log(VERSION);
    break;
  case "help":
  case null:
    console.log(HELP);
    break;
  default:
    fail(`unknown command: ${opts.command}\n\n${HELP}`);
}
