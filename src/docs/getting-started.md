# Getting started <!-- Source of docs/getting-started.md and part of plugin/README.md. Compare only with Claude Code's own behaviour, never name another plugin or tool. No recall, retention, speed or cost-saving number until the benchmark publishes one. No user-local paths beyond the configurable defaults. Cross-page links: page.md#anchor. -->

This page takes you from nothing to a first compaction, a handoff and a resume. It takes a few minutes; nothing here needs a setting changed.

## Before you start

You need Claude Code {{cc_min}} or newer (the one-line install below needs 2.1.292 or newer) and perl 5.28 or newer (already on macOS, Debian and Ubuntu). `git` is optional. The full list is in [Requirements](installation.md#requirements).

## Install in one line

At the prompt of a terminal session:

```
/plugin install {{plugin}} --marketplace {{repo}}
```

Answer `y` to add the marketplace, pick a scope (user scope is first), then review the settings screen: every setting has a working default, so you can accept it as it is. From a shell, in the desktop app, on an older Claude Code, and for updates, see [Install](installation.md#install).

## Check that it works

Run this in a session:

```
/{{plugin}}:status
```

On a fresh install it starts like this (your plugin folder and times differ):

```
ok: no compactions this session, no open alerts
watcher: true · logs 2 KB in 1 sessions · share: /{{plugin}}:report · off: watcher = false in /config
notice: {{plugin}}: local compaction logs are on (content-free; nothing is sent). To share them: /{{plugin}}:report. To turn them off: set watcher to false in /config.
plugin: 0.1.9 · <plugin folder>
thresholds: no mod row yet (settings: target 400000 · soft max 600000 · min_window 329000)
```

- The first line is the verdict: saved copies and open alerts. After the first compaction it also shows that compaction's verdict and the copy's path.
- `min_window 329000` is the smallest context window on which the plugin starts compactions of its own with the default settings. Native auto-compaction and `/compact` are shaped on any window; see [Limits](limitations.md#limits).
- `no mod row yet` is normal before the first turn: the plugin's module (see [Terms](how-it-works.md#terms)) has not reported in this session yet.
- If status prints `REFUSED: helper-runtime`, see [Troubleshooting](troubleshooting.md#refused-helper-runtime-or-no-perl).

## Your first compaction

To see it now, run `/compact` in a session with some history. Otherwise you do not start anything: the next time Claude Code compacts, whether on its own, by your `/compact`, or by the plugin at a clean turn end past `compact_target_tokens`, this happens:

1. The plugin adds its handoff instructions to the request. Claude Code's own summarizer writes the summary; the plugin never edits it and never blocks the compaction.
2. A read-only copy of the summary is saved and checked. You see one line, for example `{{plugin}}: compaction ok · copy saved`, with `· handoff <file>` and `· 2 jobs running` added when they apply. If the summary is not in handoff form, the line says so and names the verdict.
3. The next turn gets one short [resume block](how-it-works.md#terms), and the first reply opens with one status line before any tool call: `Resumed · step 1: <the summary's Step 1>`.

Run `/{{plugin}}:status` again to see the verdict and the copy's path. The detail is in [The path of one compaction](how-it-works.md#the-path-of-one-compaction).

## Write a handoff, clear, resume

A handoff is a file that a fresh session can resume from. To use one:

1. Run `/{{plugin}}:handoff`. It writes the file and ends with `✓ Handoff saved: <path>`. In the default permission mode Claude Code asks before the first write; to stop the prompt add `Edit(~/.local/state/{{plugin}}/**)` to `permissions.allow` in your user settings ([details](troubleshooting.md#write-prompts-for-the-plugin-folders)).
2. Run `/clear`, or start a new session. After `/clear` the plugin does nothing on its own.
3. Run `/{{plugin}}:resume`. It finds the newest handoff for this repository and ticket or topic, checks its claims against the live state, reports drift, and continues with the next step.

See [Usage](usage.md#skills) for all six skills and [Handoffs and resume](handoffs-and-resume.md#what-a-handoff-contains) for what a handoff holds.

## Where your files are kept

Everything stays on your machine, in a private store outside any repository:

| Where (defaults) | What |
|---|---|
| `~/.local/state/{{plugin}}/handoffs/<repo>/<ticket-or-topic>/compact/` | Read-only copies of summaries (`<ticket-or-topic>`: a ticket id from the branch name, else a topic the handoff names, else `general`; see Bucket in [Terms](how-it-works.md#terms)) |
| `~/.local/state/{{plugin}}/handoffs/<repo>/<ticket-or-topic>/` | Handoff files and their evidence |
| `~/.local/state/{{plugin}}/handoffs/.watch/` | Content-free logs |
| `~/.local/state/{{plugin}}/disposable/<YYYY-MM-DD>/` | Evidence copies, one folder per compaction |

The full table is in [What it writes](files-and-storage.md#what-it-writes-on-your-machine). In the default permission mode, a write to these folders asks until you allow it; see [Write prompts for the plugin folders](troubleshooting.md#write-prompts-for-the-plugin-folders).

## Next pages

- [How it works](how-it-works.md): what the plugin does around a compaction.
- [Idle compaction](idle-compaction.md) and [keep-warm](keep-warm.md): what happens while a session sits idle.
- [Settings](configuration.md#settings): every option, with its default.
- [Troubleshooting](troubleshooting.md) and the [FAQ](faq.md).
