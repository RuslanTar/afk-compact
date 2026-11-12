# Documentation

Every page of the afk-compact documentation, grouped by what you want to do. The same pages, joined into one file, ship with the plugin as its `README.md`, so they are on your machine after install.

New here? Read [Getting started](getting-started.md), then [How it works](how-it-works.md). The [Terms](how-it-works.md#terms) table explains the words these pages use.

## Start

| Page | What it covers |
|---|---|
| [Getting started](getting-started.md) | Install, check, a first compaction, a handoff and a resume |
| [Installation](installation.md) | Requirements, install in the terminal, a shell or the desktop app, update, uninstall |

## Use

| Page | What it covers |
|---|---|
| [Usage](usage.md) | The six skills and when to use each, the ledger, the helper |
| [Handoffs and resume](handoffs-and-resume.md) | What a handoff holds, the resume block and the first reply, the handoff turns |
| [Idle compaction](idle-compaction.md) | Native idle compaction, plugin idle compaction and the idle handoff turn; cost; the away digest |
| [Keeping the cache warm while jobs run](keep-warm.md) | Keep-warm: when it runs, when it stops, what it costs |
| [Near a usage limit](usage-limits.md) | What the plugin skips or stops near a usage limit |
| [The cache state in your status line](status-line.md) | The `cache` status-line command and its states |
| [Background jobs](background-jobs.md) | Waiting for background work, lost jobs after an exit |
| [Safety and approvals](safety-and-approvals.md) | Production commands, commands from a handoff, approvals and explicit gates |
| [Handoffs in git (repo mode)](repo-mode.md) | Exporting handoffs into a repository, when both sides opt in |
| [Questions for your queue](question-queue.md) | Connecting your own question queue |
| [Restart on update](restart-on-update.md) | The opt-in restart onto a new Claude Code (not active in this version) |

## Reference

| Page | What it covers |
|---|---|
| [Configuration](configuration.md) | Every setting: default, effect and cost; where settings are read from |
| [What it writes on your machine](files-and-storage.md) | Every folder and file the plugin writes, file modes, pruning |
| [Upgrading](upgrading.md) | The folders moved in 0.1.2 and other changes between releases |
| [Privacy and logs](privacy-and-logs.md) | What is logged and what never is, the watcher, sending a report |
| [Compatibility](compatibility.md) | Platforms, Claude Code surfaces, Team, Enterprise and managed machines |
| [Limits](limitations.md) | What this version does not do, and what has not been run live yet |
| [Troubleshooting](troubleshooting.md) | Symptoms and their fixes |

## Explain

| Page | What it covers |
|---|---|
| [How it works](how-it-works.md) | Terms, the path of one compaction, when the plugin acts, the idle timeline |
| [Claude Code's compaction with and without afk-compact](comparison.md) | A side-by-side table, each Claude Code cell linked to its documentation |
| [Design principles](design-principles.md) | The rules the plugin holds itself to |
| [FAQ](faq.md) | Short answers to common questions |

Also: the [changelog](../CHANGELOG.md), [contributing](../CONTRIBUTING.md), and the [license](../LICENSE).
