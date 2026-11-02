# Changelog

## 0.1.0

First release.

- SessionStart hook that queues headless Claude Code sessions (`claude --print` / `-p`) until there is room. Interactive sessions are never counted or delayed.
- Signals: 1-minute load per core, free memory, memory pressure (macOS `memorystatus`, Linux PSI), swap-out rate, free disk. Unreadable metrics never trigger the brake.
- Dynamic ceiling: 8 sessions normally, 4 under moderate load, 0 when heavy, with a starvation guard (the head of the queue starts when nothing is running).
- FIFO queue under a file lock with persistent tickets: a session stopped after the maximum wait keeps its place when the orchestrator retries it.
- The hook never lets a session through just because it waited long: after `max_wait_seconds` it stops the session before any model call.
- Hook state in a per-user directory (`$XDG_RUNTIME_DIR/agent-load-brake` or `~/.local/state/agent-load-brake/run`, mode 700). A state directory that is a symlink, owned by another user or group/other-accessible is refused (the session passes and the log says why); lock and marker files are created without following symlinks.
- Kill switch file, JSON config file and `AGENT_LOAD_BRAKE_*` environment variables.
- `npx agent-load-brake install | install --dry-run | uninstall | status`; uninstall restores the settings file byte for byte when nothing else changed.
