# Design principles

The rules afk-compact holds itself to. Each one points to the page that states it in full.

## It never edits a summary or blocks a compaction

Claude Code's own summarizer writes every summary. The plugin adds instructions, saves a read-only copy and gives a verdict. A verdict only informs: it adds a fallback note, a toast, an escalation or halt mode, and never blocks or rewrites a compaction. Claude Code's own auto-compaction is never turned off; it stays the backstop. See [How it works](how-it-works.md#the-path-of-one-compaction) and [Limits](limitations.md#limits).

## Your instructions come first

The plugin uses Claude Code's own hooks. A note you type with `/compact` comes first and wins over its instructions, and your settings decide when it acts. See [How it works](how-it-works.md#what-it-does).

## Local only

No telemetry, and no network connection of its own. The model requests it asks for (handoff turns, keep-warm, its own compactions) go through Claude Code and count toward your usage like any turn. A report is a zip on your disk that you send yourself, if you want to. See [Privacy](privacy-and-logs.md#privacy).

## It removes nothing on its own

No handoff, saved copy, evidence file or log is deleted by the plugin on its own. `/afk-compact:prune` lists old evidence and deletes it only after your yes. See [Pruning old evidence](files-and-storage.md#pruning-old-evidence).

## Your repository stays yours

The private store is never written inside a git work tree unless that path is git-ignored. In repo mode, which both your settings and the repository must turn on, the only write is a scanned export, and the plugin never stages, commits or pushes it. See [What it writes on your machine](files-and-storage.md#what-it-writes-on-your-machine) and [Handoffs in git](repo-mode.md#handoffs-in-git-repo-mode).

## Outward steps need your words

- A lost background job starts again by itself only when it is read-only or on your allowlist; production writes and anything with outside effects always ask. See [Lost background jobs](background-jobs.md#lost-background-jobs).
- An approval carries across a compaction only when your words are found in a message you typed and its targets still match. Deploys, production writes and pushes to a protected branch always ask again. See [Safety and approvals](safety-and-approvals.md).
- The six settings that let the plugin act without asking are read from your own settings file only, and the plugin never changes them. See [Consent keys](configuration.md#consent-keys).

## Every default is listed with its cost

Each setting is listed with its default, what it does and what it costs, and the settings that send model requests each have an off-switch. See [What the settings cost](configuration.md#what-the-settings-cost).

## Numbers only with a method

These pages give no recall, retention, speed or cost-saving number. The benchmark method is fixed in advance ([bench/METHOD.md](../bench/METHOD.md)), and its results will be published there. The one dollar figure, the cost of plugin idle compaction's own summary call, is a labelled estimate and is not set against a cost without the plugin. What has not been run live yet is listed in [Limits](limitations.md#limits).
