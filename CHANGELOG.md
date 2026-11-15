# Changelog

All notable changes to afk-compact are listed here, newest first.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/2.0.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). A breaking change is one a user must act on after upgrading: a setting, a slash command or its flags, a command pasted into a status line, or the minimum Claude Code version. While the version is 0.x a minor or patch release may contain one; each is marked **Breaking:**.

## [Unreleased]

### Added

- A `prune_protected_roots` setting, and `prune --protect DIR`, name folders `/afk-compact:prune` never works in. When a folder it would read or delete in is one (also through a link or another spelling), lies inside one or holds one, prune refuses and deletes nothing.

### Changed

- After the update, every session reads its whole transcript once more for the GSD line, on any operating system: the GSD line now reads Windows file paths it used to skip, so its saved progress starts over once. Later reads take only the new part of the transcript again.

### Fixed

- Under Git Bash or Cygwin on Windows, GSD work done through Edit and Write is now seen: Claude Code on Windows records those files as `C:\…\.planning\STATE.md`, which the GSD line missed. Paths on a network share or in WSL (`\\server\…`) are still not read.
- Under Git Bash or Cygwin on Windows, when the session's transcript is in more than one project folder, the GSD line now reads it from the folder Claude Code names from the Windows path (`C--work-app` for `C:\work\app`).
- Under Git Bash or Cygwin on Windows, a running Claude Code session started from PowerShell, cmd, Windows Terminal or Git Bash is no longer taken for ended, so another session no longer closes its open work, takes over its handoff or reports its background jobs as lost.
- Under Git Bash or Cygwin on Windows, the plugin's skills, which run through the Bash tool, now find the session they run in, instead of working as if outside any session.
- Under Git Bash or Cygwin on Windows, the resume skill's check of background work no longer reports a running Claude Code session started from PowerShell or Git Bash as not running. A session started from PowerShell now reads as unverified, as its start time cannot be read.

## [0.1.16] - 2026-11-15

afk-compact 0.1.16 keeps your standing approvals working across the plugin's own handoffs, compactions and resumes, counts an approval as standing only when your words say so, and asks again for denied approvals and pushes that reach every branch. Requires Claude Code 2.1.287 or newer; tested against 2.1.325.

### Changed

- A standing approval now stays valid after a handoff the plugin asked for itself (idle, before a compaction, at a stop). The plugin puts back each standing approval your previous handoff held as checked. One-time approvals in such a handoff are still asked again.
- After a compaction or a resume, a standing approval you already used still counts. Before, the resume rule said to act only on an unused one. Deploys, environment, infrastructure and production writes, and protected-branch pushes are still always asked again.
- An approval counts as standing only when your own words say so, such as "don't ask again", "feel free to" or "from now on". Words like "just this once" or "for now" in the same sentence keep it one-time. Saving a handoff notes a line that calls other words standing.
- After a compaction or a resume, an approval whose action was refused in the session, or in an earlier session of your chain, is listed as denied and asked again.

### Fixed

- An approval for `git push --all`, `--branches` or `--mirror` now counts as a push to a protected branch and is asked again after a compaction or a resume, since such a push reaches every branch.
- After a compaction, approvals the summary copied from a handoff (with the question after your words, or a used time with words) were not read, and the resume block said `Approvals (checked): none`. They are read now, and a line the plugin cannot read is listed to ask again.

## [0.1.15] - 2026-11-15

afk-compact 0.1.15 fixes the status line meter: it reads `0m` as soon as you send a prompt and stays `compacted` after a compaction until your next request. The one-line install needs 2.1.292 or newer. Requires Claude Code 2.1.287 or newer; tested against 2.1.325.

### Fixed

- The status line meter now reads `0m` as soon as you send a prompt, instead of a brief `cold` or the old cache's age while the request is under way. After a compaction it stays `compacted` until your next request, however long the session is idle.

## [0.1.14] - 2026-11-15

afk-compact 0.1.14 moves keep-warm's first request, in an idle gap where Claude Code's own idle compaction can run, to after that compaction, so the request is no longer wasted. The one-line install needs 2.1.292 or newer. Requires Claude Code 2.1.287 or newer; tested against 2.1.325.

### Changed

- In an idle gap at Claude Code's idle minimum (200,000 tokens by default) or more on the one-hour cache, keep-warm's first request now comes at about minute 55, not 50. Claude Code compacts such a gap at about minute 54, and a request at 50 did not stop that.
- Keep-warm now sends that first request only when Claude Code did not compact; when it did, keep-warm stops (`compacted`) without a request. A failed request is still tried again a minute later, at minutes 56 and 57.
- The later timing needs the plugin to have seen the gap's last request; after a reload during the turn, the first request stays at minute 50.
- With the later timing, a machine put to sleep between minutes 50 and 55 of such a gap loses the cache, and the status line meter shows no keep-warm mark until that first request. With `"idleCompaction": false` in `settings.json`, the first request still comes at minute 50.
- The log's `keep_warm_start` row and a refused `keep_warm_stop` row now say which timing applied, in `first_due_s` and `first_why` (`native-window` or `default`).

## [0.1.13] - 2026-11-15

afk-compact 0.1.13 adds a prompt cache meter for your status line, with a `/afk-compact:settings` step that prints its snippet, keeps a status line quiet once the plugin's folder is gone, and stops a false `copy-mismatch` warning for Claude Code's trailer. The one-line install needs 2.1.292 or newer. Requires Claude Code 2.1.287 or newer; tested against 2.1.325.

### Added

- A cache meter for your status line: `cache --stdin --bar` prints `██████░░░░░░ 30m`, 12 cells filling as the cache nears expiry (blue, yellow from half its lifetime, red from 90%) and the cache's age. Before the first response, or with an unknown lifetime, it prints nothing.
- The meter reads `↻3/7` in cyan while keep-warm runs, `cold 1h02m` or `cold miss` in magenta for a cold cache, and `compacted` after a compaction. Its flags are stable but its text may change, so use `--json` if you parse the output.
- Meter options: `--left` shows time left instead of age, `--short` drops the cells, `--ascii` draws `#` and `-`, and `--color auto|always|never` follows `NO_COLOR` and `TERM=dumb`. A locale that is not UTF-8 turns on `--ascii`, and a `COLUMNS` below 60 turns on `--short`.
- Where the plugin's helper cannot run, `--bar` prints nothing and exits 0 instead of `REFUSED: helper-runtime`. A plugin copy older than 0.1.13 does not know `--bar` and shows nothing until you update.
- `/afk-compact:settings` has a "Status line meter" step that reads which status line your user, project and local settings run (only the name of what it runs, never the full command), previews the meter and prints a snippet for your case to paste. It changes no file.
- The snippet is a settings entry, a script adding the meter as a second line under your own, or values for a ccstatusline Custom Command widget. It runs the meter only once the plugin's fixed path exists, so before the plugin's first session the line stays empty, not an error.

### Fixed

- A status line that calls `~/.local/state/afk-compact/bin/afk-compact-store` no longer prints `sh` errors after an uninstall, a prune or a failed update: with the installed copy gone it now prints nothing and exits 0.
- The file at that path is rewritten at the next session start if an earlier version wrote it, and is now also written when the plugin folder's path contains a `'`.
- After a downgrade to 0.1.12 or earlier, that file keeps running the 0.1.13 copy while it exists, as older versions leave it alone; once that copy is gone the segment stays blank. Delete the file and the older version writes its own at its next session start (without `--bar`).
- When the installed summary differed from the saved copy only by lines Claude Code added after the end marker, a complete copy got a false `copy-mismatch` toast and an `escalations:` count in `/afk-compact:status`. Not any more; a real difference is still shown and counted.

## [0.1.12] - 2026-11-14

afk-compact 0.1.12 stops ordinary file paths from reading as secrets, and fixes repo mode, GSD re-entry and checkout paths with letters outside ASCII under Git Bash on Windows. The one-line install needs 2.1.292 or newer. Requires Claude Code 2.1.287 or newer; tested against 2.1.325.

### Fixed

- Ordinary file paths, such as a macOS or Windows temp folder or a long project path, no longer read as secrets, so you no longer get a false `ADVISORY secret-warn`, a refused repo-mode export, a secret question on resume or a redacted evidence copy.
- A real key with `/` inside, one that starts with `/`, and one kept as a single part of a path are still caught, and the report's own secret scan applies the same path rule.
- Under Git Bash, a repository listed in `repo_roots` and the worktrees git made for it are now accepted, and the hint names the folder in the form the settings read; before, git's drive-letter paths (`C:/…`) were read as relative, so no listed repository was accepted.
- Under Git Bash, a `repo_roots` entry written with its drive letter (`C:/work/app`, `C:\work\app`) is now accepted. Repo mode with drive-letter repository paths was checked only by emulation on macOS, not yet on a real Windows machine, so it may still misbehave there.
- Under Git Bash, the GSD re-entry, Was driving and Active driver commands for work in the session's own checkout no longer get a stray `--cwd <this checkout>`, and `measure` and `locate` print the checkout's folder in the same form as the current folder.
- Under Git Bash, `measure <handoff>` with a GSD line no longer stops with `Out of memory!` before any output when the checkout's path holds a letter outside ASCII, such as `ë`.

## [0.1.11] - 2026-11-12

afk-compact 0.1.11 makes keep-warm easier to follow: it says why it stays off for an idle gap, shows a request while it is out, and its results appear in reports. It also reads usage near a limit more strictly and fixes several problems under Git Bash on Windows. The one-line install needs 2.1.292 or newer. Requires Claude Code 2.1.287 or newer; tested against 2.1.322.

### Added

- When keep-warm does not start in an idle gap, `/afk-compact:status` shows `keep-warm off (<why>)`, or `the last gap: keep-warm off (<why>)` after a later request, and the log records the reason (such as `no-jobs`, `ttl-5m`, `near-limit`, `no-idle-path` or `cutoff`).
- The status line command adds ` · keep-warm off (<why>)` to its cache line when keep-warm stays off, except for `no-jobs` (no background job of the session is open), which is the normal idle case.
- While a keep-warm request is out, the status line command adds ` · ping pending`, for at most 150 seconds.
- The JSON output of the status line command (`cache --stdin --json`) gains a `label` key (`warm`, `compacted`, `cold` or `unknown`), plus `keep_warm.pending` and `keep_warm.off` for the two new status line parts.
- A keep-warm request that reads the cache but takes over about 2 minutes, or returns over 58 minutes after the last cache refresh, is logged as `late`, counts for nothing and ends keep-warm for the gap. A slow request that did not read the cache, or failed, keeps its own result.
- `/afk-compact:report` adds `keep-warm.json` to its zip and `watch report` adds a Keep-warm section, both built from the log and holding only counts, durations, reasons and versions.
- The keep-warm report lists idle gaps warmed and refused (by reason), requests sent and how they came back (`warm`, `fork-miss`, `late` or failed), why warming stopped, gaps handed back to plugin idle compaction or the idle handoff turn, and the next main request's cache result.
- After a pause of 5 minutes or more, the log records the pause and whether the first main response read the cache (`hit`, `miss` or `none`), with its cache reads, cache writes and uncached input, and Claude Code's cache miss reason and missed tokens when given. It holds no text.

### Changed

- **Breaking:** After a compaction the status line reads `cache compacted`, not `cache cold (compacted)`, as the next request writes the cache anew. If your script matched `cold (compacted)`, read the JSON `label` key (`compacted`) instead; `state` still reads `cold`.
- Near a usage limit, plugin idle compaction, keep-warm and the idle handoff turn treat a reading as new only when a limit's share moved or a response came. A report that only the context or cost moved no longer lets them go past 90% on a reading that says nothing of usage since.
- A usage reading dated more than a minute ahead of the clock is now stale for going past 90%, since its time is not known.
- A limit reset time further ahead than its window is long (over about 5 hours for the five-hour limit, about 7 days for the seven-day one) is no longer believed; the reading counts as one with no reset time, in the shared usage record too.
- `/afk-compact:report`, and `watch report` with `--out`, still never replace an existing file, but now print `REFUSED: output file exists` (exit 73) instead of `REFUSED: output folder not writable`.

### Fixed

- When the shared usage record is full, a reading dated ahead of the clock with a smaller share no longer pushes out the real latest reading of its period; the record now keeps the same latest reading the plugin decides by.
- Two `watch report` runs on one date could pick the same file name, so one report replaced the other or the second said the folder was not writable. Without `--out` it now takes the next free number, and skips a name held by a broken link instead of writing through it.
- A `wait --for` path starting with a drive letter (`file:C:/work/out.log`, `exit:C:\…`, `marker:C:/…:<regex>`), as Claude Code gives paths on Windows, was refused as a usage error. It now parses.
- Under Git Bash on Windows, the worktree's path has a drive letter, so the handoff check read every GSD `STATE.md` as outside it and a handoff never got its GSD state. It now reads it, and a nested checkout is still refused.
- In a folder outside git whose name has non-ASCII characters, handoffs were saved under a second, wrongly encoded folder, and the session's own handoff was taken for another session's.
- Under Git Bash the helper took process 1 for Claude Code, so the session's alive record, sessions and locks all named it. Under Git Bash and Cygwin it now uses Claude Code's own `CLAUDE_PID`; on macOS and Linux an orphaned helper keeps process 1, as before.
- `/afk-compact:status` grouped only other sessions' usage readings by period, so the session's own reading could look like the deciding one when it was not. It now says when another session read the same period later, with that share.
- In `/afk-compact:status`, on a full tie the session's own usage reading stays the latest, as in the plugin, and a reading dated more than a minute ahead of the clock shows as of unknown time.

## [0.1.10] - 2026-11-12

This release fixes a hang on the first prompt after `claude --resume`, a fault present since 0.1.4, and makes a resumed session pick up halt mode before that prompt. The one-line install needs 2.1.292 or newer. Requires Claude Code 2.1.287 or newer; tested against 2.1.322.

### Fixed

- After `claude --resume`, the first prompt no longer hangs with no request sent (seen on Claude Code 2.1.322). The plugin no longer waits for the compaction window reading before that prompt; it still reads the window once and uses it as soon as it arrives.
- A resumed session now reads halt mode and its idle state from the earlier session before handling the first prompt, so a note restored on that prompt shows halt mode when it is on.

## [0.1.9] - 2026-11-11

afk-compact 0.1.9 keeps near-limit stops in force through long idle gaps, because a usage reading now counts until its limit resets instead of for only 10 minutes. It also supports installs that Claude Code reads in place from a local folder marketplace. The one-line install needs 2.1.292 or newer. Requires Claude Code 2.1.287 or newer; tested against 2.1.319.

### Changed

- Near a usage limit, plugin idle compaction, keep-warm and the idle handoff turn count a reading until its limit resets, as the share only grows and an idle session's reading is never refreshed, even by keep-warm. Past the reset it counts for nothing; without one, 10 minutes.
- Readings of one limit with the same reset time (within a minute) form one period, its share being the latest. A limit stops these actions only when every period is at or over it, so behind a proxy that spreads requests over several accounts, an account with room lets them run.
- With an agent, a workflow or a working teammate open, these actions still run past 90% only on a reading from the last 10 minutes. An older one stops them at 90%, and the log row says `rule: stale`.
- A reading of unknown time, such as one dated more than a minute ahead of the clock or the session's own reading just after a plugin reload, before Claude Code refreshes it, becomes its period's latest only when its share is larger.
- When no limit is reported, for example in a session restarted during an idle gap before its first response, the session's own entries in the shared usage record stand for it, beside other sessions' entries. After a plugin reload they are also read beside the reported reading.
- The shared usage record keeps an entry until its limit resets, and one with no reset time for 10 minutes after it was last read or shown. A full record never drops a period's latest reading.
- `/afk-compact:status` lists each of the session's usage readings with its age and reset time, marking as "not counted" one past its reset or one with no reset time after 10 minutes. It also lists the other sessions' counted readings, the latest of each period.
- Usage writes are throttled: one runs at a time, a refresh during a write is folded into one check after it, and shares are compared in whole points. Many parallel subagents now start one helper process instead of one each.

### Fixed

- A copy Claude Code reads in place from a local folder marketplace now counts as installed: its first session writes the status line's fixed command path, and options and version scope resolve as for other installs. A `--plugin-dir` load of that folder never changes the path.
- After you uninstall such a copy, the status line's fixed command path keeps running that folder while it exists, because Claude Code never deletes it. Delete `~/.local/state/afk-compact/bin/afk-compact-store` yourself and remove its call from your status line.
- A session whose marketplace was later pointed at another folder keeps its install by its data folder, and a `--plugin-dir` data folder under `CLAUDE_CODE_PLUGIN_CACHE_DIR` stays a `--plugin-dir` load.
- The status line's next keep-warm time (`keep_warm.next_due_at`) now follows the gap's own ping interval, which the `keep_warm_start` log row now records as `ping_s`.

## [0.1.8] - 2026-11-11

Your sessions on the same machine now share their usage readings, and a usage limit stops plugin idle compaction, keep-warm and the idle handoff turn only when every reading of it from the last 10 minutes agrees. The one-line install needs 2.1.292 or newer. Requires Claude Code 2.1.287 or newer; tested against 2.1.319.

### Added

- Sessions on the same machine now share their latest usage readings through one small file, `~/.local/state/afk-compact/usage.v1.json`. It stores each window's share, reset time, read time, source and the first 8 characters of the session id, and no account or conversation data.
- Shared usage entries not read or shown for an hour are dropped at the next write, and if a write fails, the next refresh tries again right away.
- Like the cache state, the shared usage record is never written inside a git work tree: if `XDG_STATE_HOME` points into one, each session reads only its own usage and `/afk-compact:status` shows none.
- Add `--note-usage` to `afk-compact-store cache --stdin` in your status line setup to write the five-hour and seven-day shares and reset times it shows to the shared usage record. Without the flag the command stays read-only, and the plugin works the same with no status line.
- `/afk-compact:status` shows each window's last reading for the session, with its source (plugin or status line) and age, plus the number of recent readings from your other sessions on this machine. With no recent entry it reads "no reading of this session in the last hour".
- Log rows that use a usage reading now record each window's source (`plugin`, `statusline` or `peer`), its age (`usage_age_s`) and the number of recent readings (`usage_n`). A reading whose reset time is more than an hour away from the others is logged as `usage_anomaly`.
- When a compaction, keep-warm request or idle handoff turn runs although one reading is at the limit, the log records why: `split` (another recent reading had room) or `no-fresh` (no reading from the last 10 minutes).

### Changed

- Before plugin idle compaction, keep-warm and the idle handoff turn, the plugin now weighs every reading of a limit from the last 10 minutes: the session's own, its status line's and those of your other sessions on this machine.
- A limit now stops these actions only when every such recent reading is at or over it; if any has room, or none is recent, they run. A status line's reading never counts as newer than the plugin's own reading of that session.
- The 10-minute freshness rule, which used to apply only above 90% (when an agent, a workflow or a working teammate is open), now applies to all readings, so log rows no longer show the `stale` rule.
- When no limit is reported, plugin idle compaction and the idle handoff turn use the share read when the last turn ended only if that reading is from the last 10 minutes.
- `idle_handoff_near_limit` (`skip` and `skip-spend`) now skips the turn only when every reading of the limit from the last 10 minutes is at 90% or more. The setting's name, options and default (`run`) are unchanged.
- In skip and stop log rows, `windows` now gives the share of the reading that made the decision; where readings disagree, that is the one with room, which can come from another session.
- When keep-warm waits for a usage window to reset, it logs a `keep_warm_wait` row with the time the next request is due, and the status line's `keep_warm.next_due_at` shows that time instead of 50 minutes after the last warm request.

### Fixed

- If the list of running agents cannot be read, plugin idle compaction and the away digest now count open teammates the same way keep-warm already does.

## [0.1.7] - 2026-11-11

afk-compact 0.1.7 can show the prompt cache's state in your Claude Code status line and replaces the fixed 90% usage-limit cutoff for plugin idle compaction and keep-warm with an adaptive rule. When keep-warm stops with real work still open, the plugin now compacts the session instead of letting the cache go cold. The one-line install needs 2.1.292 or newer. Requires Claude Code 2.1.287 or newer; tested against 2.1.319.

### Added

- New command `cache --stdin` for your status line: it prints whether the conversation is still cached, how long it has left and, while keep-warm runs, which request of the idle gap it is on, for example `cache 1h warm 42m left ↻3/7` or `cache cold (compacted)`.
- The status line is opt-in: add the command to `statusLine` in your settings as the README shows, through the fixed path `~/.local/state/afk-compact/bin/afk-compact-store`. The plugin's first session after the update creates that path and keeps it current.
- Add `--json` to `cache` for your own format (described in `assets/cache-contract.md`), or `--sid <session id>` to ask about a session by its id. The README shows a plain `statusLine`, a wrapper script that keeps your own line, and a ccstatusline widget.
- Uninstalling the plugin leaves `~/.local/state/afk-compact/bin/afk-compact-store` in place, and it fails once Claude Code deletes the old plugin folder. To clean up, delete the script and remove the call from your status line.
- Log rows for limit skips and stops now name the rule that decided (`rule`) and, where Claude Code provides them, your plan and tier. Each plugin compaction also logs the plan windows' usage before and after it.

### Changed

- Near a five-hour or seven-day usage limit, plugin idle compaction and keep-warm can now go on up to 98% or 95% while an agent, a workflow or a working teammate is still open. They still stop at 90% of a spend limit.
- The 98% and 95% caps apply only when the usage reading is less than 10 minutes old and the compaction's measured effect on your usage still fits under the cap. There is no setting for this; the README's "Near a usage limit" section explains it.
- When a usage window resets before the cache would expire, keep-warm now waits for the reset.
- When keep-warm stops (at its `keep_warm_hours` cutoff, at the last moment the waiting compaction can run, or near a usage limit) while an agent, a workflow or a working teammate is open, plugin idle compaction now runs from `idle_handoff_min_tokens` up.
- This hand-over runs even below the usual idle-compaction minimum, but not for a background shell alone, which may never end. With plugin idle compaction off (`idle_compact: false`, automatic compaction off, or after it failed twice) the idle handoff turn runs instead.
- A teammate waiting idle for a message no longer counts as an open job for keep-warm, plugin idle compaction or the digest's `Basis:` count. A working teammate, or an agent waiting on its own background work, still counts.
- If a keep-warm request finds the cache cold, plugin idle compaction and the idle handoff turn now wait for the session's next request instead of running on a cold cache.
- `idle_handoff_near_limit` now applies only to the idle handoff turn; plugin idle compaction and keep-warm follow the "Near a usage limit" rule instead. The `/config` text for it, `keep_warm_hours` and `idle_handoff_min_tokens` was updated to match, and defaults are unchanged.
- `/afk-compact:status` shows the size below which nothing runs while idle, and says why there is no idle handoff turn after plugin idle compaction failed twice.
- `/afk-compact:prune --apply` also deletes the status line's cache state files for sessions that ended more than 7 days ago.
- A durable recurring scheduled task survives exit, so handoff and resume no longer list it as work that stops when Claude Code exits. The handoff report leaves out its "Running now" item when only such work is running.

### Fixed

- Saving a handoff with a very long line of list markers no longer takes seconds; it now takes time in proportion to the line's length.
- A failed keep-warm request no longer cancels the cache expiry recorded by an earlier successful one.

## [0.1.6] - 2026-11-09

afk-compact 0.1.6 switches the on/off settings to `true`/`false` with a picker in `/config`, adds `/afk-compact:prune` for cleaning up old evidence, and gives the optional question queue a written contract and a `queue check` command. The one-line install needs 2.1.292 or newer. Requires Claude Code 2.1.287 or newer; tested against 2.1.306.

### Added

- New `/afk-compact:prune` command lists the evidence folders of old handoffs and the old dated folders of temporary evidence, with age, size, bucket and handoff. It deletes them only after you confirm with `--apply` and the plan hash from its dry run.
- Prune takes `--days N`, `--min-mb N` and `--root DIR`. It never deletes handoff files, summary copies, `MANIFEST.tsv`, logs or files a newer handoff cites, and copies it deleted show as `pruned`, not `missing`, in `verify` and `/afk-compact:resume`.
- The optional question queue has a written contract, `assets/queue-contract.md` in the plugin folder, with JSON Schemas for the `list` reply and the `add` draft and a minimal folder-based example program, `assets/examples/queue-folder.sh`.
- The new README section "Connect your own question queue" explains how to set up your own queue program.
- New `queue check` command (`"<plugin folder>/scripts/afk-compact-store" queue check [<program>]`) runs your program's `list` once and checks the reply against the contract. It prints `ok` or `FAIL` for each check, with a fix for each failure, and writes nothing.
- While `queue_cmd` is set, `/afk-compact:status` lists the queue command.

### Changed

- The on/off settings `handoff_turn`, `precompact_turn`, `watcher`, `unattended_prod_reads`, `idle_handoff_turn`, `idle_compact` and `resume_proceed` now take `true` or `false`. All default to `true` except `unattended_prod_reads`, which defaults to `false`.
- In `/config`, those seven settings and `relaunch_auto`, `restart_on_update`, `idle_handoff_near_limit` and `idle_digest` (which keep their words) now open a picker with the setting's description (checked on Claude Code 2.1.319).
- **Breaking:** an old-form value you saved yourself for one of these seven settings (like `off` or `forbid`) now counts as unset, so a behaviour you turned off would run again. Run `! "<plugin folder>/scripts/afk-compact-store" settings migrate` to preview, then add `--apply`.
- **Breaking:** `settings migrate` only lists consent keys saved in an old form and does not change them; set those again in `/config`. Old values are still read by `/afk-compact:status`, `settings show` and the skills, but not by the hooks.
- Saving a handoff now fixes two simple format problems instead of refusing it: an id range the save would refuse is written out as its individual ids, and a missing first item under Next steps gets a copy of Step 1. The save prints one line for each change.
- These save fixes leave approval lines, quoted or code text, and sections that contain code fences, quotes, HTML or indented code exactly as written.
- `disposable_keep_days` now also sets prune's default age (14 days while it is `0`).
- The README, `/config` and `/afk-compact:status` now separate native idle compaction (Claude Code's own), plugin idle compaction (`idle_compact`) and the idle handoff turn. The status idle line prints the token range each one covers under your effective settings.
- `idle_handoff_min_tokens` is now documented as the minimum size for the idle handoff turn, not as an idle-compaction threshold.
- When the idle handoff turn or keep-warm is skipped near a usage limit, the log row now names the usage windows it read and their shares.
- Handoffs and resume now say that background work keeps running after `/clear` and stops at exit, and that "Move to background and exit" carries over only shells, agents and workflows.
- `/afk-compact:status` and `settings show` now warn about a saved value that is not one of the setting's options.

### Removed

- `otel_log_path` is no longer shown on the install screen or in `/config`, because it had no effect. A value you saved can stay or be removed; it still does nothing.

### Fixed

- In the resume block, a background task that its notification reported as ended now shows as ended.
- Question queue `add` checks its size caps again after secrets are redacted, so every cap holds for what your program receives, and a question's closing `?` is now kept.
- `recommendation_none_reason` keeps its 200-byte cap even next to a recommended option, and a blank one there is now dropped instead of refused.

## [0.1.5] - 2026-11-08

afk-compact 0.1.5 keeps your ledger lines from one handoff to the next, lets next steps be marked as waiting on a job or on you, and fixes how the resume block is delivered while a background agent runs. The one-line install needs 2.1.292 or newer. Requires Claude Code 2.1.287 or newer; tested against 2.1.306.

### Added

- Ledger lines (`U-`, `D-` and `X-`: your constraints and asks, the decisions and the rejected options) now carry from one handoff to the next, including the lines that mark one superseded or moved to `ledger.md`.
- If a handoff draft drops a ledger line without marking it superseded, publish copies the line back unchanged and says so. A reworded ledger line or a new status is only reported.
- Publish refuses a draft that gives an existing ledger id to a different item, even an id already superseded or moved to `ledger.md`; give the item a new id first. Publish also refuses a carried ledger line that contains a private path or a secret.
- A saved compaction copy of the main conversation also carries ledger lines from the session's newest earlier copy that had the expected shape, and lists them under `ledger_carried` in its frontmatter. Copies saved late from a stash do not get this.
- In the compaction summary and the handoff template, a step still to do can be marked `waits: job` (it waits on a running job's result) or `waits: you` (it waits on you); a gated step is marked `waits: you`. The plugin reads these marks after an idle compaction.
- A `waits:` mark takes priority over a step's wording, counts after a dash, a bullet or a colon or inside brackets, and a first step with one no longer counts as able to run. Steps with no mark, as in older summaries, are still read by wording.

### Changed

- A `todo` or `done` step mark now also counts after a dash, a bullet or a colon, or in its own brackets (`(done)`), and may be followed by a note in brackets (`— done (commit 1a2b3c)`). A mark inside a note's brackets never counts: `— todo (review: done)` stays todo.
- The away digest now opens with the `Basis:` line, exactly as the plugin fills it in, followed by the work lane's state and the rest.
- A work lane that reads finished after an idle compaction now gets the idle handoff turn at any known context size, even below `idle_handoff_min_tokens` (default 200,000, range unchanged), until your next message. The turn never runs at an unknown size.

### Fixed

- While a background agent runs, Claude Code's side requests, such as its summary of that agent, no longer take the resume block; the main turn gets it. A resume block that a side request passed over now arrives with the next main prompt, without waiting for another request.

## [0.1.4] - 2026-11-07

afk-compact 0.1.4 follows Claude Code's own compaction window, tells you at once when an update has replaced the plugin copy a session runs, makes watcher alerts more accurate and tightens protected-branch gates. It also fixes non-ASCII paths, perl under MSYS and Cygwin, and hooks whose perl cannot start. The one-line install needs 2.1.292 or newer. Requires Claude Code 2.1.287 or newer; tested against 2.1.306.

### Added

- If an update or uninstall replaces the plugin copy a session runs, the session now says so at once: `this session runs 0.1.4, replaced by an install at <time>: /reload-plugins`. After updating, run `/reload-plugins` in open sessions; the notice then goes away.
- A published handoff now names in its frontmatter the plugin version and folder that wrote it, as a summary copy does. The repo-mode export keeps the version and leaves out the folder.

### Changed

- With `native_window_tokens` at its default `0`, the plugin now follows the compaction window Claude Code reports (from `CLAUDE_CODE_AUTO_COMPACT_WINDOW`, `autoCompactWindow` or the model's default) and its compaction point if given, read locally once per load with no API request.
- The log now records where the compaction window came from. If Claude Code reports no window, the plugin uses `autoCompactWindow` and then the model's window, as before.
- The Resumed line is now left out when a script reads the reply (`claude -p`, the Agent SDK) and stays in the terminal, desktop app, IDE extensions, mobile, Slack, Cowork and SSH remote sessions. This now also works where only the classic hooks run.
- A carried-over approval never covers an explicit gate. Protected branches are now matched by name on any remote, and the list now includes `staging` and any branch that you or the repository's instructions or settings name as protected.
- In auto permission mode, the actions asked again after a compaction, quoting your approval, are now only those Claude Code's auto-mode classifier still blocks: force-push, history rewrite, branch or tag delete, and external write.
- The stalled-item alert now follows a background workflow's run journal and its agents' transcripts.
- Claude Code's "Compacted while idle" notice now marks a compaction as idle for the watcher.
- The folder-quota warning now also fires above 20,000 entries, and closes once the folder is back under the limit.
- The daily prune now also covers per-session process records, and keeps the records of processes that are still running.

### Fixed

- The lost-rule alert no longer counts a renumbered or re-spaced ledger line as lost. The first time Claude finishes a turn after the update, the watcher closes older open lost-rule alerts the new rule would not raise, and deletes no alert rows.
- The continue-without-nudge alert now skips earlier and idle compactions and the plugin's own handoff-turn message. The first time Claude finishes a turn after the update, the watcher closes older open alerts of this kind the new rule would not raise, and deletes no alert rows.
- A hook whose perl is found but cannot start, or ends on a signal, now exits quietly as when there is no perl, and helper commands print that perl's error.
- A store folder with a non-ASCII name no longer gets a second, double-encoded copy when a skill reads the session id, and non-ASCII repository, worktree and transcript paths in copies are now encoded once.
- Under perl from MSYS or Cygwin, non-ASCII folders and process start times are now read correctly, and a Windows drive path set as a folder is checked like any other folder inside a git work tree. Native Windows is still not supported.
- A relative `handoff_root` or `log_dir` is now refused instead of writing under the working folder, and `/afk-compact:status` shows `root: <key> refused (root-invalid)` for it.
- In the project-state measurement, the project-state lines now come before the git header, so changed files no longer look like part of them.
- Command fragments such as `/tmp/run-$n` or `/tmp/out-%d` are no longer recorded as temp paths.

## [0.1.3] - 2026-11-03

afk-compact 0.1.3 adds a status line to the first reply after a compaction, a one-line verdict to `/afk-compact:status` and a notice when other sessions run a different plugin version. It also makes the watcher's alerts less noisy and the end-of-turn hook faster on long sessions. The one-line install needs 2.1.292 or newer. Requires Claude Code 2.1.287 or newer; tested against 2.1.306.

### Added

- The first reply after a compaction opens with one status line before any tool call: `Resumed · step 1: <the summary's Step 1>`, or `Resumed after compaction` when no Step 1 can be read. After a cut-off handoff, its `✓ Handoff saved: <path>` line takes that place.
- Headless sessions (`claude -p`, the Agent SDK, the desktop app) leave out the new resume status line when the plugin's mod is loaded.
- `/afk-compact:status` now opens with an `ok: …` or `attention: …` line that counts saved copies and open warn or critical alerts for this session, or for the last 7 days when there is no session id.
- Saved copies now record the plugin version and folder that saved them, and `/afk-compact:status` always shows the session's plugin version and folder.
- When sessions started later run another plugin version, `/afk-compact:status`, the resume block and the `/afk-compact:handoff` report say so in one line that ends with `/reload-plugins`. This works only when both sessions run 0.1.3 or later.
- A summary that has every required section through Next steps but no closing line now gets the `ok-unclosed` verdict. It counts as ok: no fallback note, and it never counts toward halt mode.
- Each turn's end now writes a timing row to the plugin's local logs, except with `watcher: off`.

### Changed

- When `native_window_tokens` is unset (`0`, the default), the plugin now follows Claude Code's `autoCompactWindow` setting, capped at the model's window, or uses the model's window if that setting holds no number. A number you set yourself still wins.
- When the plugin cannot find an approval's words in your own messages, saving a handoff no longer fails. The approval moves to Open questions so you are asked again, and the save prints one note for each approval it moved.
- After a compaction, a question whose dialog timed out is not asked in a dialog again until you write. It is listed at the end of the turn instead.
- The end-of-turn hook now has a 3.5-second budget, and work that does not fit waits for the next turn. A missing-copy alert waits until the copy is saved or the session ends.
- The handoff secret warning now names the draft's line numbers along with the rule ids, never the value.

### Fixed

- The watcher no longer raises missing-copy, band or missing-hooks alerts for compactions from before the session's first plugin row, and the band alert skips idle compactions.
- On its first turn end after the update, the watcher closes open alerts from older versions that the new rules would not raise, by adding a row and deleting nothing. For 7 days, `/afk-compact:status` shows how many it closed this way.
- `stall_min` no longer flags a background job as stalled when its output file cannot be checked.
- Scanning a long transcript for temp paths could take minutes and run past the hook timeout. It now runs in linear time and uses much less memory.
- The classic hooks could write their last-version record into another plugin's data folder. It now stays in this plugin's own data folder.
- Some summaries had no closing line. The closing-line rule now comes last in the handoff instructions.
- `/afk-compact:handoff` no longer lists pieces of shell commands (variables, globs, relative fragments) as temp-file candidates.

## [0.1.2] - 2026-10-31

afk-compact 0.1.2 moves the default handoff and evidence folders out of `~/.claude`, so with one allow rule Claude Code no longer asks before every write in the default permission mode, and adds a settings skill, visible defaults, a warm prompt cache while background jobs run and more careful approvals across compactions. The one-line install needs 2.1.292 or newer. Requires Claude Code 2.1.287 or newer; tested against 2.1.306.

### Added

- A fifth skill, `/afk-compact:settings`, shows each setting's value, source and default, by section. It changes or resets only what you pick, shows the change and asks before writing, never changes the six consent keys and backs up `~/.claude/settings.json` next to it first.
- New helper commands `settings show`, `settings set <key>=<value>` and `settings reset <key>` (or `--all`) let you view and change settings. They are dry runs unless you add `--apply`.
- Every setting's title now ends with its default, for example `[default 400,000]`, and `/afk-compact:status` lists every value the plugin uses under `settings values:`, with its source and default.
- New `keep_warm_hours` setting (default `6`, 0 to 24, `0` = off): while the session is idle but one of its own agents, workflows or background shells still runs, the plugin sends one small hidden request about every 50 minutes to keep the one-hour prompt cache warm.
- When the `keep_warm_hours` time is up and a job is still running, the plugin compacts the session (or runs the handoff-when-idle turn) while the cache is warm. Keep-warm works only with the one-hour cache and stops when a turn starts or a usage limit reaches 90%.
- Each keep-warm request counts toward your usage limits, and `/afk-compact:status` shows a keep-warm line.
- New `idle_handoff_near_limit` setting (`run`, `skip-spend` or `skip`; default `run`) controls whether the handoff-when-idle turn runs when a usage limit is at 90% or more. The plugin's own idle compaction never runs at that level.
- With `idle_handoff_near_limit` set to `run`, that handoff turn counts toward a nearly used allowance, and if your plan has extra usage turned on, usage past a plan limit may be billed.
- If the last turn ended on a question you have not answered (in its text, or in a question dialog that timed out), the resume block after a compaction now quotes it.
- New `migrate` helper command copies the old default folders into the new ones. It is a dry run unless you add `--apply`, and it never deletes, moves or overwrites anything.

### Changed

- The default `handoff_root` is now `~/.local/state/afk-compact/handoffs` and `disposable_root` is `~/.local/state/afk-compact/disposable`. If `XDG_STATE_HOME` is an absolute path, both go under `$XDG_STATE_HOME/afk-compact/` instead.
- While `handoff_root` and `disposable_root` are unset or set to the new default, the old `~/.claude/handoffs` and `~/.claude/trash-staging` are still read but never written. A value you set yourself is never changed; set them to the old folders to keep using those.
- To stop the write prompt in the default permission mode, add `Edit(~/.local/state/afk-compact/**)` to `permissions.allow` in `~/.claude/settings.json`; a `Write(...)` rule does not match these writes. If you set `XDG_STATE_HOME`, name that folder instead.
- **Breaking:** If your home folder is a git work tree, add `/.local/state/afk-compact/` to `~/.gitignore`. Until you do, the plugin writes nothing there and `/afk-compact:status` reports the folders as `in git, not ignored`.
- A handoff the plugin asked for itself (when it stops a turn, before a compaction or while you are away) now records every approval as context only, so the next step asks you again. An approval whose action was refused in the session is now context only too.
- In auto permission mode, an approval carried across a compaction no longer covers an outward action that the auto-mode classifier gates; the resume asks you first.
- A question dialog you answered no longer counts as the turn asking you a question. Only a dialog still open at the end of the turn, or one closed without an answer, stops auto-continue, the handoff turn and restart.
- The size limit for each handoff section was raised.
- The smoke check now fails only when a rare string in the Claude Code binary or the compaction experiment's list of arms changes; changes in common words print an `info c8` line. If it finds no type declarations, it tells you to type `/plugin-authoring` once.

### Fixed

- Log timestamps now use the system time zone at the moment each row is written, so after a time zone change, rows no longer carry the old offset.

## [0.1.1] - 2026-10-30

afk-compact 0.1.1 can compact a long idle session itself before the one-hour prompt cache expires, keeps a pending resume block across an exit or restart, compacts headless sessions by running `/compact`, and describes every option in plain language. The one-line install needs 2.1.292 or newer. Requires Claude Code 2.1.287 or newer; tested against 2.1.306.

### Added

- The plugin can now compact an idle session (`idle_compact`, default `auto`) when `"idleCompaction": false` is in your Claude Code settings. A main conversation of 200,000 tokens or more is compacted about 54 minutes after its last request, before the prompt cache expires.
- If your settings leave Claude Code's own idle compaction on, the plugin checks at about 55.5 minutes and compacts only when Claude Code did not. Plugin idle compaction also runs while agents or workflows are running, and works in terminal sessions only for now.
- Plugin idle compaction is skipped when the cache has probably expired, when the cache is the five-minute one, when a usage limit is at 90% or more, or when someone is typing. After two failures in a row it stops for that session.
- A new away digest (`idle_digest`, default `off`): after an idle compaction whose work is finished or only waiting on you, the next reply starts nothing new. With `off`, it says in one line where the work stands, then what needs you.
- With `idle_digest` set to `submit`, a short summary turn is sent right away after such an idle compaction; with `return`, the summary goes at the top of the reply to your next message.
- After each compaction, a dim line in the transcript says how it went: the verdict, whether the copy was saved, whether a handoff came before it, and which jobs are still running. The model does not see it, it is never shown in a subagent, and `warn_ui` controls it.
- A handoff published just before a compaction now gets one acknowledgment line after the compaction, not a repeat of its report.
- A beta `restart_on_update` setting (`on`, `shadow` or `off`; default `off`) and the `afk-compact-claude` launcher prepare a future automatic move onto a newly installed Claude Code. Neither restart route is active yet; `/afk-compact:status` shows the current state.
- `restart_on_update` is read from `~/.claude/settings.json` only, the same as the other options that let the plugin act without asking.
- In headless sessions (`claude -p`, the Agent SDK, the desktop app), where Claude Code rejects the plugin's compaction call, the plugin now runs `/compact` at a turn end at or above the target and shapes that compaction itself. This is not yet checked in a live session.
- The cache reads of each compaction are now logged, and a large compaction that read a cold cache raises an alert in `/afk-compact:status`.

### Changed

- **Breaking:** If `"idleCompaction": false` is in your Claude Code settings, the plugin now compacts your idle sessions, where before no idle compaction ran. To keep none, set `idle_compact` to `off`.
- If a session exits or restarts before its next turn, its resume block now waits on disk for the first turn after `claude --resume` of that session, measured again if over 10 minutes old. A newer compaction replaces it, `/clear` drops it, and a forked session never gets it.
- `idle_handoff_turn` now runs only when nobody compacts the idle session: with `idle_compact: off`, with automatic compaction off, with the conversation below the minimum, or after the plugin's compaction failed twice.
- Every option on the install screen and in `/config` has a clearer title and a plain-language description, and the README has a matching table with the exact rules in a collapsible section. No key was renamed.

### Fixed

- A prompt you queue while a turn runs now clears halt mode when its own turn starts, so an auto-continue or a plugin compaction no longer goes ahead of a prompt you are entering.
- The summary is now found even when Claude Code puts a header before it.
- A moved or respawned session now keeps its idle timer.
- `/afk-compact:report --since` now accepts only real calendar dates.
- If `CLAUDE_CONFIG_DIR` points to a folder whose `settings.json` is a link to `~/.claude/settings.json`, the options read from your settings file only now come from that file as usual.
- The helper's output no longer includes a Perl locale warning.

### Security

- The watcher now writes nothing when its log folder or handoff folder is inside a git work tree that does not ignore it, including folders not created yet and paths with non-ASCII names.

## [0.1.0] - 2026-10-28

The first release of afk-compact, a Claude Code plugin for long unattended sessions: when a session compacts, it asks Claude Code's own summarizer for a handoff, keeps a read-only copy of every summary, checks its shape and gives the next turn a short resume block so the work can continue. The one-line install needs 2.1.292 or newer. Requires Claude Code 2.1.287 or newer; tested against 2.1.306.

### Added

- Native auto-compaction, a manual `/compact` and compactions the plugin starts itself all get the same handoff instructions, and subagents get a shorter form. In a manual `/compact`, your own note comes first and wins.
- If the plugin's usual hook does not run, a classic `PreCompact` hook gives the same handoff instructions instead.
- Once the context passes `compact_target_tokens`, the plugin can compact after a turn ends normally, before native auto-compaction cuts in mid-task. Past `compact_soft_max_tokens` it adds one checkpoint nudge.
- After a nudged compaction the plugin can send one continue note, up to `max_auto_continues_per_hour`. Two non-ok verdicts in a row, a compaction loop or reaching that hourly cap switch on halt mode.
- Before a planned compaction, and before the last compaction of a run that will not continue by itself, the model gets one extra turn to write a handoff while the full context is still there.
- When Claude Code's own idle compaction is off or did not run, an optional pre-idle handoff turn gives the model the same chance to write a handoff.
- Each summary is saved once as a read-only copy and gets one verdict: `ok`, `ok-trailer`, `truncated`, `unshaped`, `scope-leak` or `stale`. Verdicts only inform and never block or rewrite a compaction.
- After a compaction, the next turn gets a resume block with the path of the saved copy and a fresh git and project-state measurement. After an idle compaction, the measurement is repeated when you come back.
- Temp files that the session cited are copied to a dated folder, with size caps and secret checks. The plugin deletes nothing.
- A background job that is gone is checked again from the plugin's own records. A read-only or allowlisted job may start again by itself, and everything else asks you first.
- Opt-in repo mode: a repository that declares `.claude/handoffs.json` and is also listed in your `repo_roots` receives a scanned export of each published handoff. The plugin never stages, commits or pushes it.
- An optional question queue through a `queue_cmd` executable of your own, off by default.
- A watcher keeps local, content-free logs of compactions, nudges, continues and resumes, and shows alerts. It makes no network calls and sends no telemetry.
- The skills `/afk-compact:handoff`, `/afk-compact:resume`, `/afk-compact:status` and `/afk-compact:report`. The report skill bundles the logs into a zip on your disk, and nothing is uploaded.
- Settings for thresholds, handoff turns, storage folders, evidence, the watcher, relaunch and production safety, each with a working default listed in the README. Keys that let the plugin act without asking are read only from your user settings file.
- The plugin needs Perl 5.28 or newer with only the modules that ship with it, already present on macOS, Debian and Ubuntu (on Alpine, run `apk add perl`). The git measurements need `git`.
- Supported on macOS 13 or newer and Linux with glibc. Alpine/musl and WSL 2 are expected to work but not yet tested in a session, and native Windows is not supported yet.

[Unreleased]: https://github.com/RuslanTar/afk-compact/compare/v0.1.16...HEAD
[0.1.16]: https://github.com/RuslanTar/afk-compact/compare/v0.1.15...v0.1.16
[0.1.15]: https://github.com/RuslanTar/afk-compact/compare/v0.1.14...v0.1.15
[0.1.14]: https://github.com/RuslanTar/afk-compact/compare/v0.1.13...v0.1.14
[0.1.13]: https://github.com/RuslanTar/afk-compact/compare/v0.1.12...v0.1.13
[0.1.12]: https://github.com/RuslanTar/afk-compact/compare/v0.1.11...v0.1.12
[0.1.11]: https://github.com/RuslanTar/afk-compact/compare/v0.1.10...v0.1.11
[0.1.10]: https://github.com/RuslanTar/afk-compact/compare/v0.1.9...v0.1.10
[0.1.9]: https://github.com/RuslanTar/afk-compact/compare/v0.1.8...v0.1.9
[0.1.8]: https://github.com/RuslanTar/afk-compact/compare/v0.1.7...v0.1.8
[0.1.7]: https://github.com/RuslanTar/afk-compact/compare/v0.1.6...v0.1.7
[0.1.6]: https://github.com/RuslanTar/afk-compact/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/RuslanTar/afk-compact/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/RuslanTar/afk-compact/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/RuslanTar/afk-compact/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/RuslanTar/afk-compact/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/RuslanTar/afk-compact/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/RuslanTar/afk-compact/releases/tag/v0.1.0
