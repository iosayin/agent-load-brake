// Pure helpers that add or remove the agent-load-brake SessionStart hook in a Claude Code settings object.
import { isDeepStrictEqual } from "node:util";

export const HOOK_FILE = "agent-load-brake.py";
export const HOOK_TIMEOUT = 1500; // seconds; above the hook's own max_wait_seconds (1380)

const quote = (s) => (/^[\w@%+=:,./-]+$/.test(s) ? s : `'${s.replaceAll("'", `'\\''`)}'`);

export const hookCommand = (python, script) => `${quote(python)} ${quote(script)}`;

export const isOurs = (hook) => typeof hook?.command === "string" && hook.command.includes(HOOK_FILE);

const clone = (o) => JSON.parse(JSON.stringify(o ?? {}));

/** Settings without any agent-load-brake hook; groups, arrays and objects left empty by the removal are dropped. */
export function removeHook(settings) {
  const out = clone(settings);
  const groups = out.hooks?.SessionStart;
  if (!Array.isArray(groups)) return out;
  const kept = [];
  for (const g of groups) {
    if (!Array.isArray(g?.hooks) || !g.hooks.some(isOurs)) {
      kept.push(g);
      continue;
    }
    const rest = g.hooks.filter((h) => !isOurs(h));
    if (rest.length) kept.push({ ...g, hooks: rest });
  }
  if (kept.length) out.hooks.SessionStart = kept;
  else delete out.hooks.SessionStart;
  if (Object.keys(out.hooks).length === 0) delete out.hooks;
  return out;
}

/** Settings with exactly one agent-load-brake hook (an existing one is replaced, other hooks are kept in order). */
export function addHook(settings, command, timeout = HOOK_TIMEOUT) {
  const out = removeHook(settings);
  out.hooks ??= {};
  out.hooks.SessionStart ??= [];
  out.hooks.SessionStart.unshift({ hooks: [{ type: "command", command, timeout }] });
  return out;
}

export const hasHook = (settings) =>
  (settings?.hooks?.SessionStart ?? []).some((g) => Array.isArray(g?.hooks) && g.hooks.some(isOurs));

/**
 * What uninstall should leave on disk. `original` is the file text saved at install time (null if the file did not exist),
 * `current` the parsed settings now. If nothing else changed since install, the original bytes come back (or the file is
 * removed); otherwise the user's later edits are kept and only the hook is removed.
 * Returns { action: "restore" | "delete" | "write", text? }.
 */
export function uninstallPlan(current, original) {
  const cleaned = removeHook(current);
  if (original === null && Object.keys(cleaned).length === 0) return { action: "delete" };
  if (typeof original === "string") {
    try {
      if (isDeepStrictEqual(cleaned, JSON.parse(original))) return { action: "restore", text: original };
    } catch {
      // the saved copy is not JSON: fall through and write the cleaned settings
    }
  }
  return { action: "write", text: JSON.stringify(cleaned, null, 2) + "\n" };
}
