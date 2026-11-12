# Usage <!-- Source of docs/usage.md and part of plugin/README.md. Compare only with Claude Code's own behaviour, never name another plugin or tool. No recall, retention, speed or cost-saving number until the benchmark publishes one. No user-local paths beyond the configurable defaults. Cross-page links: page.md#anchor. -->

## Skills

| Skill | Use it for |
|---|---|
| `/{{plugin}}:handoff [ticket-or-topic] [note]` | Write a handoff file that a fresh session can resume from: before `/clear`, before a break, or when the session is getting long. The model writes intent, decisions, findings and next steps; the helper measures git state, background work and evidence, lints the draft, scans it for secrets and publishes it. |
| `/{{plugin}}:resume [path or ticket] [instructions]` | Resume from a handoff or a saved compaction copy. It finds the newest fitting file, checks its claims against the live state, reports drift and restarts background work only where the handoff allows it, then continues with the next step. Right after a compaction, when you have not invoked it yourself, the model follows a light path instead: at most three tool calls before real work. |
| `/{{plugin}}:status` | Show a one-line verdict (saved copies and open alerts), the watcher state, effective thresholds, the last five compactions (trigger, verdict, copy path, how they were shaped), open escalations and alerts, auto-continue and halt state, the handoff mode of the current repository, the state of automatic relaunch and of the question queue, and the allow rule and user-run commands with the real plugin folder. It shows no summary content. |
| `/{{plugin}}:settings [advanced \| all]` | Go through the plugin's settings section by section, with each value, where it comes from and its default, and change or reset the ones you pick. Only when you ask: it shows the change and asks before it writes your settings file, and it never changes a consent key (see [Changing settings from a session](configuration.md#settings)). `advanced` lists the rare tuning keys, `all` both. |
| `/{{plugin}}:report [--since 7d]` | Bundle the plugin's content-free logs, version, settings and recorded probe results into a zip that you can send to the developer yourself. Nothing is uploaded. Use it only when you want to share; see [Sending a report](privacy-and-logs.md#sending-a-report). |
| `/{{plugin}}:prune [--days N] [--min-mb N] [--root DIR]` | Only when you ask: list the evidence folders of old handoffs and the old dated folders of temporary evidence, with their age, size, bucket and handoff, then delete them after your yes. Handoff files, summary copies and the files a newer handoff cites always stay; see [Pruning old evidence](files-and-storage.md#pruning-old-evidence). |

## When to use each skill

- **Before `/clear`, before a break, or when a session is getting long:** `/{{plugin}}:handoff` writes a file that a fresh session can resume from.
- **In a fresh session, to pick up where a handoff or a saved compaction copy left off:** `/{{plugin}}:resume` reads the newest fitting file and continues with the next step.
- **To see what the plugin is doing:** `/{{plugin}}:status`.
- **To change a setting:** `/{{plugin}}:settings`.
- **To share logs or free disk space:** `/{{plugin}}:report` or `/{{plugin}}:prune`, only when you want to.

## Mechanical fixes when a handoff is saved

From 0.1.6 the save fixes two format rules itself instead of refusing the handoff: an id range it would refuse (`D-2..D-4` where the handoff chain defines those ids) is written as its ids (`D-2, D-3, D-4`), and when Next steps has no first item, Step 1 is copied there as item 1.

- It prints one line per change. When another rule still refuses the save, the draft is kept as written and those lines say what the save will change once the rest is fixed.
- A range whose two ends differ in kind (`D-2..X-4`), one that runs backwards or one over 50 ids, a range in quotes or backticks, after `=` (`--only=D-2..D-4`) or in a file name, a range on an approval line, and a first Next steps item that differs from Step 1, are left as written, and refused while they still break the rule. So is all of a section (a `##` heading to the next) that holds a line with three or more backticks or tildes in a row anywhere in it, a quote line (`>`), an HTML line (one starting with `<` and a letter, `/`, `!` or `?` after any indent and list markers: a tag such as `<details>`, an HTML comment or a `<https://…>` link), or a line indented 4 or more columns that is not a list continuation (a break such as `* * *`, a lone list marker and a numbered item other than `1.` or `1)` right under text start no list; a line where any of its leading list markers is followed by more than 4 columns before its text counts as indented); no item 1 is added when Next steps or Resume here is such a section.
- A range in other text on a fixed line, a command written without backticks included, is listed too.
- In a restart recipe, an agent's label may end in a counter after a dash (`fix-<n>`); a model id, an output name or a path ending that way still needs the real value. <!-- 0.1.5: publish auto-fixes the mechanical lints; text trimming waits; 0.1.6: a section with a code block, a quote or HTML is left as written, no block is guessed at -->

## The shared handoff format

The handoff and the compaction instructions share one format, so `/{{plugin}}:resume` reads both. A published handoff's frontmatter names the plugin version and folder that wrote it, as a summary copy's does (from 0.1.4).

## The ledger stays (from 0.1.5)

The `U-`, `D-` and `X-` lines (your constraints and asks, the decisions, the rejected options) carry from one handoff to the next, and so do the lines that mark one superseded or moved to `ledger.md`. When a draft drops one without marking it superseded, publish copies it back unchanged and says so. A draft that gives an existing id, or one already superseded or moved to `ledger.md`, to a different item is refused until that item takes a new id; a reworded line or a new status is only reported. A carried line with a private path or a secret is refused too. A saved compaction copy of the main conversation gets the same carry from the session's newest earlier copy that had the expected shape (not when a copy is saved late from a stash), and its frontmatter lists the added lines under `ledger_carried`.

## The helper

The skills and the plugin call one helper, `scripts/{{plugin}}-store` in the plugin folder, always by its full path; nothing is added to your `PATH`. Where this page shows a command for you to run, it is written `! "<plugin folder>/scripts/{{plugin}}-store" …`, and `/{{plugin}}:status` prints it with the real folder.

## After /clear

After `/clear` the plugin delivers no resume block, submits no prompt and runs no skill on its own; work resumes only when you ask for it. A continue or handoff turn that was about to start when you cleared is dropped. Background work keeps running (see [Lost background jobs](background-jobs.md#lost-background-jobs)).
