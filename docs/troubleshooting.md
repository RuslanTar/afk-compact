# Troubleshooting

Find the line you see, then follow its fix. Each entry names the page that has the full detail. Start with `/afk-compact:status`: it prints the verdict, open alerts, and the rule or note behind most of the entries below.

## REFUSED: helper-runtime or no perl

**You see:** the hooks print nothing, and helper commands answer `REFUSED: helper-runtime`. Or a helper command prints a perl error.

- **Cause:** no usable perl: Alpine without `apk add perl`, a minimal Fedora image without perl, a perl older than 5.28, or one found but unable to start (a version manager's shim with no perl picked, or one that aborts on a missing library).
- **Fix:** install perl 5.28 or newer (`apk add perl` on Alpine, `dnf install perl-interpreter` on a minimal Fedora image). With a perl that cannot start, helper commands print its error instead; repair or remove that perl.
- **Meanwhile:** the mod still adds its instructions, but no summary or evidence copies are saved. `/afk-compact:handoff` prints the handoff into the chat, marked as not saved and not secret-scanned.

See [Requirements](installation.md#requirements) and [Limits](limitations.md#limits).

## Write prompts for the plugin folders

**You see:** a permission prompt for each helper call, or for a write under `~/.local/state/afk-compact/`.

- **Helper calls, default permission mode:** each helper call prompts until you add the rule that `/afk-compact:status` prints, with the real folder, as `allow rule (default mode): Bash("<plugin folder>/scripts/afk-compact-store" wait *)`. The plugin folder name contains the version, so after an update the old rule stops matching. When your user or project settings still name an older folder, `/afk-compact:status` says so in a line `allow rule for an older plugin folder: <old folder>; current: <plugin folder>` and prints the new rule. It only reads your settings files; it never edits them.
- **Writes to the state folders, default permission mode:** a write to the new folders asks until you allow it. This allow rule in your user settings (`~/.claude/settings.json`, under `permissions.allow`) stops the prompt (measured): `Edit(~/.local/state/afk-compact/**)`. A `Write(…)` rule for the same folder does not match these writes. If you set `XDG_STATE_HOME`, name that folder instead.

See [Upgrading](upgrading.md#the-handoff-and-evidence-folders-moved-in-012).

## In git, not ignored

**You see:** `/afk-compact:status` lists a folder as `in git, not ignored`, and the plugin writes no handoffs, summary copies or logs.

- **Cause:** your home folder is a git work tree (a dotfiles repository), and a `.gitignore` that ignores only `.claude/` keeps the old folders out of git but not `~/.local/state/afk-compact/`. The plugin writes nothing in a folder git would show.
- **Fix:** add the line `/.local/state/afk-compact/` to `~/.gitignore`, or set `handoff_root` and `disposable_root` to folders outside any git work tree.

See [Upgrading](upgrading.md#the-handoff-and-evidence-folders-moved-in-012) and [What it writes](files-and-storage.md#what-it-writes-on-your-machine).

## Smoke check due

**You see:** after a Claude Code update, `/afk-compact:status` says a check is due and offers a command to run.

- **Fix:** type the command it prints, with the real folder: `! "<plugin folder>/scripts/afk-compact-store" smoke`.
- **If smoke says no type declarations were found:** type `/plugin-authoring` once in any session (it costs one model turn), then run smoke again while that session is open (or pass `--types FILE`).

See [The smoke check after a Claude Code update](installation.md#the-smoke-check-after-a-claude-code-update).

## Saved-word warnings

**You see:** `/afk-compact:status` or `settings show` warns about a saved value, and a behaviour you turned off runs again.

- **Cause:** releases before 0.1.6 saved other words than `true` and `false` for the on/off settings. The plugin still reads them as before, but Claude Code reads a saved value that is not on the setting's list as unset, so the hooks run the default.
- **Fix:** save `true` or `false` for the setting (`settings set` takes the old words too and saves `true` or `false`).

See [Settings](configuration.md#settings).

## The version-mismatch line

**You see:** a line like `this session runs 0.1.2; sessions started since 2026-11-01 14:02 +0200 run 0.1.3: /reload-plugins`, in `/afk-compact:status`, in the resume block or in a handoff's report.

- **Cause:** you updated, or rolled back, and this session still runs the copy it loaded.
- **Fix:** run `/reload-plugins`, or start a new session.

See [When sessions run different versions](installation.md#when-sessions-run-different-versions).

## root-invalid

**You see:** `root: <key> refused (root-invalid)` in `/afk-compact:status`, and nothing written under that root.

- **Cause:** a root that is not an absolute path: a relative path, or a Windows drive path such as `C:\x` outside Git Bash's perl, which reads it as `/c/x`. An unset `log_dir` follows `handoff_root` and is refused with it; the logs then go to the default folder.
- **Fix:** set `handoff_root`, `log_dir` or `disposable_root` to an absolute path outside any git work tree.

See [What it writes](files-and-storage.md#what-it-writes-on-your-machine).

## queue: degraded

**You see:** `queue: degraded (<reason>)` in `/afk-compact:status`, for example `queue: degraded (untagged)`, and no `Queued:` line in the handoff.

- **Cause:** `queue_cmd` is set, but the path is not an executable file, or a `list` reply is not one JSON object with `"schema": "queue-stub/v1"`. The plugin uses nothing from the reply.
- **Fix:** make your program keep the contract; the reason in the status line says which part fails. `queue_cmd` is read from your settings file only.

See [Connect your own question queue](question-queue.md#connect-your-own-question-queue).

## Hook errors on Windows

**You see:** a visible hook error at each plugin hook's event, on native Windows without Git for Windows.

- **Cause:** Claude Code runs hook commands in PowerShell, which cannot start the plugin's launcher. These errors do not block a tool call or a compaction, but compactions are not reliably shaped, no summary or evidence copies are saved, and the skills cannot call the helper.
- **Fix:** native Windows is not supported yet. Running Claude Code inside WSL 2 is the expected route until native support lands.

See [Platforms](compatibility.md#platforms).

## Plugin compactions off: window below the minimum

**You see:** `plugin compactions off: window <W> is below <N>, the smallest for these settings` in `/afk-compact:status`.

- **Cause:** Claude Code treats windows below 100,000 as 100,000, and the plugin's own compactions need a larger window. `/afk-compact:status` ends its `thresholds:` line with `min_window <N>`, the smallest window that turns plugin compactions on with your settings (`min_window 329000` with the defaults), or `min_window never` when `compact_target_tokens` or `compact_soft_max_tokens` is set too low for any window.
- **What still runs:** native auto-compaction, shaping, copies and verdicts.
- **Fix:** none is needed when the window is meant to be small: only the plugin's own compactions are off on it. Otherwise compare `compact_target_tokens` and `compact_soft_max_tokens` with `min_window`; see [Settings](configuration.md#settings).

## A verdict other than ok

**You see:** a toast, a fallback note in the resume block, or a verdict word other than `ok` in the log or in `/afk-compact:status`. Verdicts only inform: they add a fallback note, a toast, an escalation, or halt mode. They never block or rewrite a compaction.

| Verdict | Meaning |
|---|---|
| `ok` | The summary is complete and in handoff form. |
| `ok-trailer` | Complete and in handoff form, with text after the closing line. Counts as ok. |
| `ok-unclosed` | A summary with every required section through its last one (Next steps) but no closing line. It counts as ok: no fallback note, and it never counts toward halt mode. |
| `truncated` | A summary cut off inside its body. |
| `unshaped` | The summary carries none of the plugin's marker: it is not in handoff form. |
| `scope-leak` | The summary is of the other scope: a main conversation's in a subagent compaction, or the reverse. |
| `stale` | The summary does not belong to the compaction the plugin recorded. |

See [The path of one compaction](how-it-works.md#the-path-of-one-compaction).

## Filing a bug

Open an issue at https://github.com/RuslanTar/afk-compact/issues with what you saw and the plugin version (`/afk-compact:status` shows it); attach a report zip only if you want to share the logs. To make the zip, see [Sending a report](privacy-and-logs.md#sending-a-report).
