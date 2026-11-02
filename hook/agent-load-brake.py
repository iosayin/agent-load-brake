#!/usr/bin/env python3
"""agent-load-brake: a Claude Code SessionStart hook that queues headless agent sessions while the machine is overloaded.

Why: an orchestrator that starts many `claude --print` sessions at once can freeze a workstation (load 50+, swap storm).
This hook runs before the session makes its first model call and holds it until there is room.

1. **Effective ceiling.** At most MAX_AGENTS (default 8) headless agent sessions run at the same time. When the machine is
   moderately loaded (load > MID_LOAD_PER_CORE x cores, free memory < MID_FREE_MEM_PCT, swap-out > MID_SWAP_OUT_MBPS) the
   ceiling drops to MID_MAX_AGENTS (4). When the machine is heavy the ceiling is 0: nobody new gets in, with one exception:
   if no agent is running at all, the head of the queue may start (starvation guard, the machine is never left idle).
   Counted = processes whose command line has a `claude` executable followed by `--print`/`-p` (and, if set, contains MATCH),
   minus the ones currently waiting in this hook. Interactive sessions do not match: they are never counted or delayed.
2. **Heavy.** 1-min load > HEAVY_LOAD_PER_CORE x cores, OR free memory < MIN_FREE_MEM_PCT, OR memory pressure is critical
   (macOS `kern.memorystatus_vm_pressure_level` >= 4, Linux PSI `full avg10` >= PSI_CRITICAL), OR swap-out rate
   > SWAP_OUT_MBPS (sampled over SAMPLE_SECONDS), OR free disk on DISK_PATH < MIN_FREE_DISK_GB. Free swap is logged but is not
   a signal (macOS does not shrink swap). A metric that cannot be read never triggers the brake. The measurement is shared
   under a lock for CACHE_SECONDS, so every waiter sees the same state and a late arrival cannot measure "light" and jump ahead.
3. **FIFO queue and persistent tickets.** Decisions are taken under a file lock; the free slots go to the oldest waiters. The
   queue position comes from a ticket keyed by the environment variables in TICKET_ENV (default: the task and agent ids an
   orchestrator passes to the session). A session terminated after MAX_WAIT_SECONDS keeps its ticket, so when the
   orchestrator retries the same task it re-enters with its old position. Tickets are removed on pass and expire after
   TICKET_TTL_SECONDS. Without those variables the queue position lives only as long as the process.
4. **Kill switch.** If the KILL_SWITCH file exists the hook passes immediately and logs it: `touch` it to turn the brake off
   without editing any settings, `rm` it to turn it back on.

Time limits: register the hook with a timeout above MAX_WAIT_SECONDS (the installer uses 1500 s vs 1380 s). Claude Code kills a
hook that times out and starts the session anyway, so the hook decides on its own before that. When MAX_WAIT_SECONDS runs out
it sends SIGTERM to the parent `claude` process and exits 2: no model call is made and the orchestrator sees a failed run it
can retry. (Returning `{"continue": false}` from SessionStart does not stop a headless session.)

Configuration: environment variables AGENT_LOAD_BRAKE_<NAME> override the JSON file CONFIG (lower-case keys) which overrides the
defaults below. `--status` prints the current measurement and decision without waiting.
Tests: AGENT_LOAD_BRAKE_MEASURE="load=3 mem_free=8 pressure=1 swap_free=700 swap_out=0 disk_free=40" replaces the
measurement (a field that is not given counts as unreadable; `load` falls back to the real value).
Any measurement or counting error lets the session through.
"""
import fcntl
import hashlib
import json
import os
import random
import re
import shutil
import signal
import stat
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
_RUNTIME = os.environ.get("XDG_RUNTIME_DIR", "")
# Per-user, never a shared world-writable directory: the lock and markers live here, and the hook refuses any directory
# that is not a real directory owned by this user with no group/other access (see secure_dir).
DEFAULT_STATE_DIR = (os.path.join(_RUNTIME, "agent-load-brake") if _RUNTIME and os.path.isabs(_RUNTIME) and os.path.isdir(_RUNTIME)
                     else os.path.join(HOME, ".local/state/agent-load-brake/run"))
DEFAULTS = {
    "max_agents": 8,
    "mid_max_agents": 4,
    "heavy_load_per_core": 2.0,
    "mid_load_per_core": 1.5,
    "min_free_mem_pct": 15.0,
    "mid_free_mem_pct": 25.0,
    "swap_out_mbps": 16.0,
    "mid_swap_out_mbps": 4.0,
    "min_free_disk_gb": 15.0,
    "disk_path": "/System/Volumes/Data" if os.path.isdir("/System/Volumes/Data") else "/",
    "psi_critical": 10.0,
    "max_wait_seconds": 1380,
    "poll_seconds": 15.0,
    "sample_seconds": 3.0,
    "cache_seconds": 10.0,
    "ticket_ttl_seconds": 6 * 3600,
    "ticket_env": "PAPERCLIP_TASK_ID,PAPERCLIP_AGENT_ID",
    "match": "",
    "state_dir": DEFAULT_STATE_DIR,
    "log_file": os.path.join(HOME, ".local/state/agent-load-brake/brake.log"),
    "kill_switch": os.path.join(HOME, ".config/agent-load-brake/disabled"),
    "sysctl": "/usr/sbin/sysctl",   # absolute paths: hooks may run without PATH; overridable for tests
    "vm_stat": "/usr/bin/vm_stat",
    "proc": "/proc",
}
CONFIG = os.environ.get("AGENT_LOAD_BRAKE_CONFIG", os.path.join(HOME, ".config/agent-load-brake/config.json"))
SHELLS = ("sh", "bash", "zsh", "dash")
FIELDS = ("load", "mem_free", "pressure", "swap_free", "swap_out", "disk_free")
PRESSURE_CRITICAL = 4


def load_config():
    cfg = dict(DEFAULTS)
    try:
        with open(CONFIG) as f:
            data = json.load(f)
        cfg.update({k: v for k, v in data.items() if k in DEFAULTS})
    except (OSError, ValueError, AttributeError):
        pass
    for key, default in DEFAULTS.items():
        raw = os.environ.get("AGENT_LOAD_BRAKE_" + key.upper())
        if raw is not None:
            cfg[key] = raw
    for key, default in DEFAULTS.items():   # coerce to the default's type
        try:
            cfg[key] = type(default)(float(cfg[key])) if isinstance(default, (int, float)) else str(cfg[key])
        except (TypeError, ValueError):
            cfg[key] = default
    return cfg


C = load_config()


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=10, env={**os.environ, "LC_ALL": "C"}).stdout


def read(path):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return None


def swapped_out_bytes():
    """Total bytes swapped out since boot, or None."""
    vmstat = read(os.path.join(C["proc"], "vmstat"))
    if vmstat is not None:   # Linux
        m = re.search(r"^pswpout\s+(\d+)", vmstat, re.M)
        return int(m.group(1)) * os.sysconf("SC_PAGE_SIZE") if m else None
    try:   # macOS
        t = run([C["vm_stat"]])
        page = re.search(r"page size of (\d+) bytes", t)
        return int(re.search(r"^Swapouts:\s+(\d+)", t, re.M).group(1)) * (int(page.group(1)) if page else 4096)
    except Exception:
        return None


def measure_linux(o):
    info = read(os.path.join(C["proc"], "meminfo"))
    if info is None:
        return False
    kb = {k: int(v) for k, v in re.findall(r"^(\w+):\s+(\d+)", info, re.M)}
    if kb.get("MemTotal") and "MemAvailable" in kb:
        o["mem_free"] = 100.0 * kb["MemAvailable"] / kb["MemTotal"]
    if "SwapFree" in kb:
        o["swap_free"] = kb["SwapFree"] / 1024
    psi = read(os.path.join(C["proc"], "pressure/memory"))
    if psi:
        some = re.search(r"^some .*?avg10=([\d.]+)", psi, re.M)
        full = re.search(r"^full .*?avg10=([\d.]+)", psi, re.M)
        if full and float(full.group(1)) >= C["psi_critical"]:
            o["pressure"] = 4.0
        elif some and float(some.group(1)) >= C["psi_critical"]:
            o["pressure"] = 2.0
        elif some or full:
            o["pressure"] = 1.0
    return True


def measure_macos(o):
    try:
        t = run([C["sysctl"], "-n", "kern.memorystatus_level", "kern.memorystatus_vm_pressure_level", "vm.swapusage"])
        lines = t.splitlines()
        # sysctl skips a key it cannot read and the lines shift: trust neither unless both integer lines are there.
        if len(lines) >= 3 and lines[0].strip().isdigit() and lines[1].strip().isdigit():
            o["mem_free"], o["pressure"] = float(lines[0]), float(lines[1])
        m = re.search(r"free = ([\d.,]+)M", t)   # some locales print a decimal comma ("6144,00M")
        if m:
            o["swap_free"] = float(m.group(1).replace(",", "."))
    except Exception:
        pass


def raw_measure():
    """{field: value | None}; an unreadable value is None."""
    fake = os.environ.get("AGENT_LOAD_BRAKE_MEASURE")
    if fake is not None:
        d = dict(p.split("=", 1) for p in fake.split() if "=" in p)

        def num(k):
            try:
                return float(d[k])
            except (KeyError, ValueError):
                return None
        o = {k: num(k) for k in FIELDS}
        if o["load"] is None:
            o["load"] = os.getloadavg()[0]
        return o
    o = dict.fromkeys(FIELDS)
    o["load"] = os.getloadavg()[0]
    s1 = swapped_out_bytes()
    if not measure_linux(o):
        measure_macos(o)
    try:
        st = os.statvfs(C["disk_path"])
        o["disk_free"] = st.f_bavail * st.f_frsize / 1e9
    except OSError:
        pass
    if s1 is not None:
        start = time.time()
        time.sleep(C["sample_seconds"])
        s2 = swapped_out_bytes()
        if s2 is not None and s2 >= s1:
            o["swap_out"] = (s2 - s1) / 1e6 / max(time.time() - start, 0.1)
    return o


def classify(o):
    """(effective ceiling, list of heavy reasons). Heavy means ceiling 0."""
    cores = os.cpu_count() or 8
    v = o.get
    heavy = []
    if v("load") is not None and v("load") > C["heavy_load_per_core"] * cores:
        heavy.append("load")
    if v("mem_free") is not None and v("mem_free") < C["min_free_mem_pct"]:
        heavy.append("memory")
    if v("pressure") is not None and v("pressure") >= PRESSURE_CRITICAL:
        heavy.append("pressure")
    if v("swap_out") is not None and v("swap_out") > C["swap_out_mbps"]:
        heavy.append("swap")
    if v("disk_free") is not None and v("disk_free") < C["min_free_disk_gb"]:
        heavy.append("disk")
    if heavy:
        return 0, heavy
    mid = ((v("load") is not None and v("load") > C["mid_load_per_core"] * cores)
           or (v("mem_free") is not None and v("mem_free") < C["mid_free_mem_pct"])
           or (v("swap_out") is not None and v("swap_out") > C["mid_swap_out_mbps"]))
    return (min(C["mid_max_agents"], C["max_agents"]) if mid else C["max_agents"]), []


def measure():
    """Called under the lock: reuse the shared measurement if younger than cache_seconds, else measure and store it."""
    path = os.path.join(C["state_dir"], "measurement")
    try:
        if time.time() - os.stat(path).st_mtime < C["cache_seconds"]:
            with open(path) as f:
                d = dict(p.split("=", 1) for p in f.read().split())
            return {k: (None if d.get(k, "?") == "?" else float(d[k])) for k in FIELDS}
    except (OSError, ValueError):
        pass
    o = raw_measure()
    try:
        with open_new(path + ".new") as f:
            f.write(" ".join(f"{k}={'?' if o[k] is None else o[k]}" for k in FIELDS))
        os.replace(path + ".new", path)
    except OSError:
        pass
    return o


def summary(o, ceiling, heavy):
    """One-line measurement summary for the log; unreadable values are '?'."""
    def f(k, fmt):
        return fmt.format(o[k]) if o.get(k) is not None else "?"
    return (f"load={f('load', '{:.1f}')} mem_free={f('mem_free', '{:.0f}%')} pressure={f('pressure', '{:.0f}')} "
            f"swap_out={f('swap_out', '{:.1f}')}MB/s disk_free={f('disk_free', '{:.0f}')}GB "
            f"swap_free={f('swap_free', '{:.0f}MB')} ceiling={ceiling}" + (f" heavy={','.join(heavy)}" if heavy else ""))


class UnsafeStateDir(Exception):
    pass


def secure_dir(path):
    """Create path (0700) if missing, then refuse it unless it is a real directory (not a symlink) owned by this user
    with no group/other permissions. Another local user must not be able to plant symlinks where the hook writes."""
    try:
        os.makedirs(path, mode=0o700, exist_ok=True)
        st = os.lstat(path)
    except OSError as e:
        raise UnsafeStateDir(f"{path}: {e}")
    if not stat.S_ISDIR(st.st_mode):
        raise UnsafeStateDir(f"{path} is not a directory (or is a symlink)")
    if st.st_uid != os.getuid():
        raise UnsafeStateDir(f"{path} is owned by uid {st.st_uid}, not {os.getuid()}")
    if st.st_mode & 0o077:
        raise UnsafeStateDir(f"{path} has mode {stat.S_IMODE(st.st_mode):o}, expected no group/other access (700)")


def open_new(path, mode="w"):
    """open() for writing that never follows a symlink at the final path component."""
    flags = os.O_WRONLY | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0) | (os.O_APPEND if mode == "a" else os.O_TRUNC)
    return os.fdopen(os.open(path, flags, 0o600), mode)


def log(line):
    try:
        os.makedirs(os.path.dirname(C["log_file"]), exist_ok=True)
        with open(C["log_file"], "a") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + line + "\n")
    except OSError:
        pass


def processes():
    """pid -> (ppid, command line)."""
    ps = shutil.which("ps", path="/bin:/usr/bin") or "ps"
    table = {}
    for line in run([ps, "-e", "-ww", "-o", "pid=,ppid=,args="]).splitlines():
        p = line.split(None, 2)
        if len(p) >= 2 and p[0].isdigit() and p[1].isdigit():
            table[int(p[0])] = (int(p[1]), p[2] if len(p) > 2 else "")
    return table


def is_agent(cmd):
    """A headless agent session: a `claude` executable followed by --print/-p (and MATCH, if set)."""
    if C["match"] and C["match"] not in cmd:
        return False
    parts = cmd.split()
    return any(os.path.basename(x) == "claude" and any(a in ("--print", "-p") for a in parts[i + 1:])
               for i, x in enumerate(parts))


def owner_pid(table):
    """The claude process running this hook: skip an intermediate shell (sh/bash/zsh) if there is one."""
    pid = os.getppid()
    for _ in range(3):
        cmd = table.get(pid, (0, ""))[1]
        first = os.path.basename(cmd.split()[0]) if cmd.split() else ""
        if first not in SHELLS or is_agent(cmd):
            return pid
        pid = table.get(pid, (pid, ""))[0]
    return pid


def marker(pid):
    return os.path.join(C["state_dir"], "waiting", str(pid))   # mtime = queue time (from the ticket or from arrival)


def ticket_path():
    """Persistent ticket keyed by the TICKET_ENV variables; None if any of them is missing."""
    names = [n.strip() for n in C["ticket_env"].split(",") if n.strip()]
    values = [os.environ.get(n, "") for n in names]
    if not names or not all(values):
        return None
    return os.path.join(C["state_dir"], "tickets", hashlib.sha256(":".join(values).encode()).hexdigest()[:24])


def take_ticket():
    """Queue time: the valid ticket's time if there is one, otherwise now (and the ticket is written)."""
    now = time.time()
    path = ticket_path()
    if path is None:
        return now, False
    folder = os.path.dirname(path)
    secure_dir(folder)
    for name in os.listdir(folder):   # expired tickets (the task ended some other way)
        try:
            if now - os.stat(os.path.join(folder, name)).st_mtime > C["ticket_ttl_seconds"]:
                os.remove(os.path.join(folder, name))
        except OSError:
            pass
    try:
        return os.stat(path).st_mtime, True
    except FileNotFoundError:
        open_new(path).close()
        os.utime(path, (now, now))
        return now, False


def drop_ticket():
    path = ticket_path()
    if path:
        try:
            os.remove(path)
        except FileNotFoundError:
            pass


def remove(path):
    try:
        os.remove(path)
    except FileNotFoundError:
        pass


def attempt(me):
    """Under the lock: measure, count, decide. Returns (passed, running, queued, ceiling, heavy, measurement, agents)."""
    with open_new(os.path.join(C["state_dir"], "lock")) as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        o = measure()
        ceiling, heavy = classify(o)
        agents = {p for p, (_, c) in processes().items() if is_agent(c)}
        waiting = {}   # pid -> queue time
        for name in os.listdir(os.path.join(C["state_dir"], "waiting")):
            try:
                if name.isdigit() and int(name) in agents:
                    waiting[int(name)] = os.stat(marker(name)).st_mtime
                    continue
                os.remove(os.path.join(C["state_dir"], "waiting", name))   # owner is gone
            except OSError:
                pass
        running = len(agents - set(waiting) - {me})
        # First come, first served: only as many of the oldest waiters as there are free slots may pass.
        ahead = sum(1 for p, t in waiting.items() if p != me and (t, p) < (waiting.get(me, 0), me))
        queued = len(waiting) - (me in waiting)
        passed = running + ahead < ceiling or (heavy and running == 0 and ahead == 0)   # starvation guard
        if passed:
            remove(marker(me))
        return passed, running, queued, ceiling, heavy, o, len(agents)


def wait(me, old):
    start = time.time()
    first = True
    tag = " ticket=old" if old else ""
    while True:
        elapsed = time.time() - start
        ok, running, queued, ceiling, heavy, o, agents = attempt(me)
        if ok:
            drop_ticket()
            if not first:
                log(f"passed after {int(elapsed)}s running={running + 1}/{ceiling} queued={queued} agents={agents} "
                    f"{summary(o, ceiling, heavy)}{tag} pid={me}")
            return 0
        reason = f"{'heavy' if heavy else 'ceiling full'} running={running}/{ceiling} queued={queued}"
        if first:
            log(f"waiting ({reason}) agents={agents} {summary(o, ceiling, heavy)}{tag} pid={me}")
            first = False
        if elapsed >= C["max_wait_seconds"]:
            remove(marker(me))
            msg = (f"agent-load-brake: no slot for {int(elapsed)}s ({reason}); stopping the session before any model "
                   f"call, the orchestrator can retry it (queue ticket kept)")
            log(f"terminated {msg} {summary(o, ceiling, heavy)} pid={me}")
            print(msg, file=sys.stderr)
            os.kill(me, signal.SIGTERM)
            return 2
        time.sleep(C["poll_seconds"] * random.uniform(0.8, 1.2))


def main():
    if os.path.exists(C["kill_switch"]):
        log(f"disabled: {C['kill_switch']} exists, passing pid={os.getppid()}")
        return 0
    table = processes()
    me = owner_pid(table)
    if not is_agent(table.get(me, (0, ""))[1]):
        return 0   # not a headless agent session (an interactive session, a manual run): never wait
    try:
        secure_dir(C["state_dir"])
        secure_dir(os.path.join(C["state_dir"], "waiting"))
    except UnsafeStateDir as e:
        log(f"unsafe state_dir, passing without queueing: {e} pid={me}")
        return 0
    t, old = take_ticket()
    open_new(marker(me)).close()   # counted as "waiting" right away; the decision is taken under the lock
    os.utime(marker(me), (t, t))
    try:
        return wait(me, old)
    except Exception:
        remove(marker(me))   # a leftover marker would count a running session as waiting and break the ceiling
        raise


def status():
    try:
        secure_dir(C["state_dir"])
        secure_dir(os.path.join(C["state_dir"], "waiting"))
    except UnsafeStateDir as e:
        print(f"agent-load-brake: unsafe state_dir, the hook passes every session without queueing: {e}")
        return 1
    o = raw_measure()
    ceiling, heavy = classify(o)
    agents = [p for p, (_, c) in processes().items() if is_agent(c)]
    waiting = [n for n in os.listdir(os.path.join(C["state_dir"], "waiting")) if n.isdigit() and int(n) in agents]
    state = "disabled (kill switch)" if os.path.exists(C["kill_switch"]) else ("HEAVY" if heavy else "ok")
    print(f"agent-load-brake: {state}")
    print(f"  {summary(o, ceiling, heavy)}")
    print(f"  cores={os.cpu_count()} agents={len(agents)} running={len(agents) - len(waiting)} queued={len(waiting)}")
    tilde = lambda p: "~" + p[len(HOME):] if p.startswith(HOME + "/") else p   # noqa: E731
    print(f"  log={tilde(C['log_file'])} kill_switch={tilde(C['kill_switch'])}")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--status"]:
        sys.exit(status())
    try:
        sys.stdin.read()
    except Exception:
        pass
    try:
        code = main()
    except Exception as e:   # a measurement/counting error never blocks a session
        log(f"error, passing: {e!r}")
        code = 0
    sys.exit(code)
