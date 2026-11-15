# FAQ <!-- Source of docs/faq.md and part of plugin/README.md. Compare only with Claude Code's own behaviour, never name another plugin or tool. No recall, retention, speed or cost-saving number until the benchmark publishes one. No user-local paths beyond the configurable defaults. Cross-page links: page.md#anchor. -->

Short answers, each with a link to the page that has the detail.

## Is this just a lower auto-compact threshold?

No. Claude Code's `/autocompact` can lower the point at which it compacts, but the compaction itself is still the plain one. The plugin changes what happens around a compaction:

- Every compaction, native auto-compaction and your own `/compact` included, gets the same handoff instructions. A note you type with `/compact` comes first and wins.
- Every summary is saved as a read-only copy and checked, and the next turn gets one resume block.
- On a large enough window the plugin can also compact at a clean turn end, before native auto-compaction cuts in mid-task.

See [How it works](how-it-works.md#what-it-does) and [The path of one compaction](how-it-works.md#the-path-of-one-compaction).

## Does it use more of my usage?

It can, in these ways, and each one has an off switch:

- **Earlier, more frequent compactions** on very large windows, because the plugin compacts at a target size. See `compact_target_tokens` in [Settings](configuration.md#settings).
- **A handoff turn** before a planned compaction and in a last cycle: an extra turn on your model with the full context, which counts toward your usage. Turn it off with `precompact_turn` or `handoff_turn` set to `false`; see [Handoffs and resume](handoffs-and-resume.md#the-handoff-turn-of-a-last-cycle).
- **Keep-warm requests** while your background jobs run. Set `keep_warm_hours` to `0` to turn it off; see [keep-warm](keep-warm.md#keeping-the-cache-warm-while-jobs-run).
- **Plugin idle compaction** and the **idle handoff turn** when a session sits idle. Set `idle_compact` to `false` to turn plugin idle compaction off. By default the idle handoff turn also runs when a limit is at 90% or more. Set `idle_handoff_turn` to `false`, or `idle_handoff_near_limit` to `skip`, to keep it out; see [Idle compaction](idle-compaction.md#idle-compaction).

## Does it send data anywhere?

No. There are no network calls and no telemetry from the plugin. Logs are content-free and stay on your disk, and a report is a zip on your disk that you send yourself, or not. The model requests the plugin causes (a handoff turn, keep-warm, plugin idle compaction, the optional comparison trial) go through Claude Code to your usual model provider, like any other turn. See [Privacy](privacy-and-logs.md#privacy).

## Does it change or block native compaction?

It never edits a summary and never blocks a compaction. It adds its handoff instructions to the request, and afterwards it saves a copy and gives a verdict. A verdict only informs: it adds a fallback note, a toast, an escalation, or halt mode. Native auto-compaction stays the backstop. See [Design principles](design-principles.md).

## Can the model change my settings?

Not the ones that matter. `/{{plugin}}:settings` changes the plugin's saved options only when you ask, shows the change and asks before it writes. The six consent keys (`repo_roots`, `relaunch_auto`, `relaunch_allow`, `unattended_prod_reads`, `restart_on_update` and `queue_cmd`) are read from your settings file only, and the plugin never sets or removes them, whoever runs its commands. See [Settings](configuration.md#settings).

## What happens after /clear?

After `/clear` the plugin delivers no resume block, submits no prompt and runs no skill on its own; work resumes only when you ask for it. Background work keeps running. See [After /clear](usage.md#after-clear).

## Do I need the status line?

No. The status line shows the cache state, and `--note-usage` records the usage limits it shows; leave that out to keep the command read-only. The plugin works the same without a status line. See [The cache state in your status line](status-line.md#the-cache-state-in-your-status-line).
