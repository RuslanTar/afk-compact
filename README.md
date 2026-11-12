# afk-compact

When a Claude Code session compacts, afk-compact asks Claude Code's own summarizer for a handoff instead of a plain summary. It keeps a read-only copy of every summary, checks that the summary has the expected shape, and gives the next turn a short resume block. It also adds six skills: `/afk-compact:handoff`, `/afk-compact:resume`, `/afk-compact:status`, `/afk-compact:report`, `/afk-compact:settings` and `/afk-compact:prune`.

> [!NOTE]
> Early version (0.x). The parts that need a live session or a managed machine have not been run yet; see [Limits](docs/limitations.md#limits). This page describes the design and reports no measurements.

## Documentation

- [Getting started](docs/getting-started.md)
- [Installation](docs/installation.md)
- [How it works](docs/how-it-works.md)
- [Usage](docs/usage.md)
- [Handoffs and resume](docs/handoffs-and-resume.md)
- [Configuration](docs/configuration.md)
- [Idle compaction](docs/idle-compaction.md)
- [Keeping the cache warm while jobs run](docs/keep-warm.md)
- [Near a usage limit](docs/usage-limits.md)
- [The cache state in your status line](docs/status-line.md)
- [Background jobs](docs/background-jobs.md)
- [Safety and approvals](docs/safety-and-approvals.md)
- [Handoffs in git (repo mode)](docs/repo-mode.md)
- [Questions for your queue](docs/question-queue.md)
- [Restart on update (beta, opt-in)](docs/restart-on-update.md)
- [What it writes on your machine](docs/files-and-storage.md)
- [Upgrading](docs/upgrading.md)
- [Privacy and logs](docs/privacy-and-logs.md)
- [Compatibility](docs/compatibility.md)
- [Limits](docs/limitations.md)
- [Troubleshooting](docs/troubleshooting.md)
- [FAQ](docs/faq.md)
- [Design principles](docs/design-principles.md)
- [Claude Code's compaction with and without afk-compact](docs/comparison.md)

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
