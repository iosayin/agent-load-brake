import { strict as assert } from "node:assert";
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { addHook, hasHook, hookCommand, removeHook, uninstallPlan } from "../src/settings.mjs";

const CLI = join(dirname(fileURLToPath(import.meta.url)), "..", "bin", "cli.mjs");
const CMD = hookCommand("/usr/bin/python3", "/home/u/.claude/hooks/agent-load-brake.py");
const OTHER = { hooks: { SessionStart: [{ hooks: [{ type: "command", command: "echo hi", timeout: 5 }] }] }, model: "x" };

test("addHook adds one SessionStart entry and keeps other hooks", () => {
  const s = addHook(OTHER, CMD);
  assert.equal(s.hooks.SessionStart.length, 2);
  assert.deepEqual(s.hooks.SessionStart[0], { hooks: [{ type: "command", command: CMD, timeout: 1500 }] });
  assert.deepEqual(s.hooks.SessionStart[1], OTHER.hooks.SessionStart[0]);
  assert.equal(s.model, "x");
  assert.ok(!hasHook(OTHER) && hasHook(s));
});

test("addHook twice still leaves a single entry", () => {
  const s = addHook(addHook({}, CMD), CMD.replace("/usr/bin", "/opt/bin"));
  assert.equal(s.hooks.SessionStart.length, 1);
  assert.match(s.hooks.SessionStart[0].hooks[0].command, /^\/opt\/bin/);
});

test("removeHook undoes addHook, including containers it created", () => {
  assert.deepEqual(removeHook(addHook(OTHER, CMD)), OTHER);
  assert.deepEqual(removeHook(addHook({}, CMD)), {});
  assert.deepEqual(removeHook({ a: 1 }), { a: 1 });
});

test("hookCommand quotes paths with spaces", () => {
  assert.equal(hookCommand("/usr/bin/python3", "/a b/agent-load-brake.py"), "/usr/bin/python3 '/a b/agent-load-brake.py'");
});

test("uninstallPlan restores original bytes, deletes a file it created, keeps later edits", () => {
  const original = '{\n    "model": "x"\n}\n';
  assert.deepEqual(uninstallPlan(addHook({ model: "x" }, CMD), original), { action: "restore", text: original });
  assert.deepEqual(uninstallPlan(addHook({}, CMD), null), { action: "delete" });
  const edited = { ...addHook({ model: "x" }, CMD), theme: "dark" };
  assert.deepEqual(uninstallPlan(edited, original), { action: "write", text: '{\n  "model": "x",\n  "theme": "dark"\n}\n' });
});

// End to end: the CLI against a throwaway HOME and Claude config dir.
function sandbox() {
  const root = mkdtempSync(join(tmpdir(), "alb-cli-"));
  const env = { ...process.env, HOME: join(root, "home"), CLAUDE_CONFIG_DIR: join(root, "home", ".claude"),
    AGENT_LOAD_BRAKE_STATE_DIR: join(root, "state") };
  mkdirSync(env.CLAUDE_CONFIG_DIR, { recursive: true });
  const run = (...args) => spawnSync(process.execPath, [CLI, ...args], { env, encoding: "utf8" });
  const settings = join(env.CLAUDE_CONFIG_DIR, "settings.json");
  const tree = () => listAll(env.HOME);
  return { root, env, run, settings, tree, done: () => rmSync(root, { recursive: true, force: true }) };
}

function listAll(dir) {
  return readdirSync(dir, { recursive: true }).sort().map((f) => {
    const p = join(dir, f);
    try {
      return `${f}:${readFileSync(p, "utf8")}`;
    } catch {
      return `${f}/`;
    }
  });
}

test("install --dry-run writes nothing", () => {
  const s = sandbox();
  writeFileSync(s.settings, '{"model": "x"}');
  const before = s.tree();
  const r = s.run("install", "--dry-run");
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /dry run, nothing is written/);
  assert.match(r.stdout, /agent-load-brake\.py/);
  assert.deepEqual(s.tree(), before);
  s.done();
});

test("install then uninstall brings back the exact original file", () => {
  const s = sandbox();
  const original = '{\n    "model": "x",\n    "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "true"}]}]}\n}';
  writeFileSync(s.settings, original);
  let r = s.run("install");
  assert.equal(r.status, 0, r.stderr);
  const installed = JSON.parse(readFileSync(s.settings, "utf8"));
  assert.ok(hasHook(installed));
  assert.equal(installed.hooks.SessionStart[0].hooks[0].timeout, 1500);
  assert.ok(existsSync(join(s.env.CLAUDE_CONFIG_DIR, "hooks", "agent-load-brake.py")));
  r = s.run("install"); // idempotent
  assert.equal(JSON.parse(readFileSync(s.settings, "utf8")).hooks.SessionStart.length, 1);
  r = s.run("uninstall");
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /exactly as it was/);
  assert.equal(readFileSync(s.settings, "utf8"), original);
  assert.ok(!existsSync(join(s.env.CLAUDE_CONFIG_DIR, "hooks", "agent-load-brake.py")));
  assert.ok(!existsSync(join(s.env.HOME, ".config", "agent-load-brake", "install-state.json")));
  s.done();
});

test("uninstall removes a settings file that install created", () => {
  const s = sandbox();
  assert.equal(s.run("install").status, 0);
  assert.ok(existsSync(s.settings));
  assert.equal(s.run("uninstall").status, 0);
  assert.ok(!existsSync(s.settings));
  s.done();
});

test("uninstall keeps edits made after install", () => {
  const s = sandbox();
  writeFileSync(s.settings, '{"model": "x"}\n');
  s.run("install");
  const edited = JSON.parse(readFileSync(s.settings, "utf8"));
  edited.theme = "dark";
  writeFileSync(s.settings, JSON.stringify(edited));
  assert.equal(s.run("uninstall").status, 0);
  assert.deepEqual(JSON.parse(readFileSync(s.settings, "utf8")), { model: "x", theme: "dark" });
  s.done();
});

test("invalid settings JSON: exit 1, file untouched", () => {
  const s = sandbox();
  writeFileSync(s.settings, "{ not json");
  const r = s.run("install");
  assert.equal(r.status, 1);
  assert.match(r.stderr, /not valid JSON/);
  assert.equal(readFileSync(s.settings, "utf8"), "{ not json");
  s.done();
});

test("--settings targets another file; status reports it; unknown command fails", () => {
  const s = sandbox();
  const project = join(s.root, "project-settings.json");
  assert.equal(s.run("install", "--settings", project).status, 0);
  assert.ok(hasHook(JSON.parse(readFileSync(project, "utf8"))));
  assert.ok(!existsSync(s.settings));
  const st = s.run("status", "--settings", project);
  assert.equal(st.status, 0, st.stderr);
  assert.match(st.stdout, /agent-load-brake: (ok|HEAVY|disabled)/);
  assert.match(st.stdout, /hook installed in/);
  assert.equal(s.run("frobnicate").status, 1);
  s.done();
});
