# Contributing

Thanks for helping! This project is small on purpose: one Python hook (standard library only) and a Node.js installer with no dependencies.

- **Bug?** Open an issue with your OS, Python and Claude Code versions, what you expected and what happened. Attach the relevant lines of `~/.local/state/agent-load-brake/brake.log`. Please remove host names, paths and private task content first.
- **Idea?** Open an issue first so we can agree on the shape before you write code.
- **Pull requests:** keep them focused, no new dependencies, run `npm run check` and `npm test` before pushing. A new signal or threshold needs a test in `test/brake.test.sh` with a negative and a positive case.
