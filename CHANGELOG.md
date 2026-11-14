# Changelog

All notable changes to afk-compact are listed here, newest first. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html). While the version is 0.x, a minor release may change settings or behaviour; each release lists what to do under Upgrade notes.

Each version links to its GitHub release. Tags are named `vX.Y.Z`. Every release states the Claude Code versions it needs and the one it was tested against under Compatibility.

## [Unreleased]

## [0.1.12] - 2026-11-14

afk-compact 0.1.12 stops ordinary file paths from reading as secrets, and fixes repo mode, GSD re-entry and non-ASCII checkout paths under Git Bash on Windows.

### Windows (Git Bash)

Windows (Git Bash) support in this release was checked by emulating Git for Windows on macOS and by two test runs on a Windows PC. Those runs found no failure in the plugin itself. Some test cases do not run on Windows yet: the cases that use a stand-in for git's drive-letter output, and the watch cases that rely on file modes or symbolic links. They are tracked for the next release.

One fix is not yet confirmed on a real Windows machine: repo mode with a repository path written with its drive letter (such as `C:/w/repo`). It was checked only by emulation on macOS, because the Windows test run did not reach it: the tests' stand-in git had a defect. It is the part of this release most likely to misbehave on Windows; the other Windows fixes were confirmed with real Git for Windows.

### Fixed

- **File paths no longer read as secrets.** The checks for long base64-style values (`high-entropy`) and bare 40-character cloud keys (`cloud-key-bare`) treated `/` as part of a key, so an ordinary file path could look like one: a macOS temp folder (`/var/folders/…/T/…`), a Windows temp folder written with forward slashes or in its Git Bash form, a long project path, or an in-repo path that a repo-mode export writes as a relative one. Publishing then showed a false `ADVISORY secret-warn`, a repo-mode export was refused with `secret-warn`, a resume asked about a secret, and an evidence copy could come out redacted. A value made of 3 or more `/`-separated parts, none of which looks like a key on its own, is now skipped when it is a path: it starts with `/`, `~/`, `./` or `../` (or its word does), a file extension follows it, or every part reads as a word. A key with `/` inside, one that starts with `/`, and one kept as a single part of a path are still caught. The report's own secret scan applies the same rule.
- **RRP-07 needs a repo temp folder outside the temp folders.** The case is reported as not run, with the reason, when the runner's `--repo-tmp` folder lies under `/tmp` or `/var/folders` (the runner need `repo-tmp-off-temp`), instead of failing.
- **Repo mode under Git Bash.** Git for Windows gives a checkout's folder and its git folders with a drive letter (`C:/…`). The plugin read that as a relative path, so a repository listed in `repo_roots` was never accepted, and the hint asked you to add a `C:/…` folder that the settings then refused. Git's paths are now read in Git Bash's form (`/c/…`) where they come in, so a listed repository and the worktrees git made for it are accepted, and the hint names the folder in the form the settings read. A `repo_roots` entry written with its drive letter (`C:/work/app`, `C:\work\app`) is accepted too.
- **GSD re-entry under Git Bash.** The GSD re-entry, Was driving and Active driver commands for work in the session's own checkout got a stray `--cwd <this checkout>`, because the checkout's folder with a drive letter matched no GSD folder. A session folder that Claude Code wrote with a drive letter is read the same way. `measure` and `locate` now print the checkout's folder in the form they print the current folder.
- **A checkout path with a letter outside ASCII under Git Bash.** `measure <handoff>` with a GSD line ended with `Out of memory!` before any output when the checkout's path held a letter such as `ë`: Git Bash's perl failed when its path conversion got such a path as text. The conversion now gets only the path's leading ASCII folders, as bytes, and keeps the rest as it is.
- **Helper cases under Git Bash.** A case or step now names what it needs from the machine, and under Git Bash it is reported as not run, with the reason, instead of failing: real symbolic links (`symlinks`), file modes that chmod sets (`exact-modes`), git in folders past 260 characters (`long-paths`), restart on update (`unix-os`) and file names that Windows refuses (`posix-names`). A symlink setup where links cannot be made ends its case with that reason instead of planting a copy. The not-executable queue programs hold no `#!` line, which Git Bash reads as executable, and AT-ST-10's names that Windows refuses moved to AT-ST-10b.
- **U-06 under a reaping init.** The helper case that checks a killed helper takes its pattern child along could read a child that its new parent had just reaped as still alive, and failed about 2 times in 100 in a Linux container. A child seen gone now stays gone; the case still fails when the helper leaves its child behind.

### Upgrade notes

- No action is required.

### Compatibility

- Requires Claude Code 2.1.287 or newer. The one-line install needs 2.1.292 or newer.
- Tested against Claude Code 2.1.325.

## [0.1.11] - 2026-11-12

afk-compact 0.1.11 makes keep-warm easier to follow. It now says why it stays off for an idle gap, shows a request while it is out, and its results appear in reports. It also reads usage near a limit more strictly, and fixes several problems under Git Bash on Windows.

### Added

- **Keep-warm says why it stays off.** When keep-warm does not start in an idle gap, the log has one `keep_warm_stop` row with `refused: true` and the reason (`no-jobs`, `ttl-5m`, `near-limit`, `no-idle-path`, `cutoff`, …). `/afk-compact:status` shows `keep-warm off (<why>)` for that gap, or `the last gap: keep-warm off (<why>)` once a later request of the session came. The status line command adds ` · keep-warm off (<why>)` to its cache line, except for `no-jobs` (no background job of the session is open), which is the normal idle case.
- **A request in flight.** While a keep-warm request is out, the status line command adds ` · ping pending`, for at most 150 seconds.
- **Late requests.** A keep-warm request that reads the cache but takes over about 2 minutes, or comes back more than 58 minutes after the last request that refreshed the cache, counts for nothing: the log's `keep_warm_ping` row says `late`, and keeping warm stops for the gap (`missed`). A slow request that did not read the cache, or that failed, keeps its own result.
- **Keep-warm statistics in reports.** `/afk-compact:report` adds `keep-warm.json` to its zip, and the helper's `watch report` adds a Keep-warm section. They list the idle gaps that warmed and those refused (by reason), the requests sent and how they came back (`warm`, `fork-miss`, `late` or failed), why warming stopped, the gaps handed back to plugin idle compaction or the idle handoff turn, and for each gap the cache result of the session's next main request. Both are built from the log rows and hold only counts, durations, reasons and versions.
- **Cache reads after a pause.** The watcher logs one `cache_after_gap` row for the first main response after a pause of 5 minutes or more: the pause, its cache reads, cache writes and uncached input, and `hit`, `miss` or `none`. When Claude Code reports a cache miss reason in the transcript, the row has it, with the missed token count. The row holds no text.

### Changed

- **The status line after a compaction.** The cache line reads `cache compacted` instead of `cache cold (compacted)`: the context is nearly empty then, and the next request writes the cache anew. The JSON output (`cache --stdin --json`) gains a `label` key (`warm`, `compacted`, `cold` or `unknown`), and `keep_warm.pending` and `keep_warm.off` for the two new parts. `state` keeps its old values (`cold` right after a compaction), so scripts should read `label`.
- **Near a usage limit** (plugin idle compaction, keep-warm and the idle handoff turn):
  - A reading's time is refreshed only when Claude Code reports that a limit's share moved, or by a response. A report that only the context or the cost moved (after a keep-warm request, say) leaves the reading as old as it was, so going past 90% no longer runs on a reading that says nothing of the usage since.
  - A reading dated more than a minute ahead of the clock is stale for going past 90%, since its time is not known.
  - A reset time further ahead than its window is long (a five-hour limit's more than about 5 hours away, a seven-day limit's more than about 7 days away) is not believed. The reading counts as one with no reset time, in the shared usage record too.
  - When the shared usage record is full, it keeps each period's latest reading by the same rule the plugin's decision uses, so a reading dated ahead of the clock with a smaller share no longer pushes out the real latest one.
- **Existing output files.** `/afk-compact:report`, and `watch report` with `--out`, never replace a file that is already there. They now print `REFUSED: output file exists` (exit 73) for it, instead of `REFUSED: output folder not writable`.
- **Report file names.** `watch report` without `--out` claims its file name by exclusive create, and moves on to the next free number when another run took it first. A name held by a broken link is skipped, never written through.

### Fixed

- **Wait paths with a drive letter.** A `wait --for` path that starts with a drive letter (`file:C:/work/out.log`, `exit:C:\…`, `marker:C:/…:<regex>`), as Claude Code gives paths on Windows, was refused as a usage error. It now parses.
- **GSD state under Git Bash.** Git for Windows gives the worktree's path with a drive letter, so the handoff check read every GSD `STATE.md` as outside the worktree and never read a handoff's GSD state. A nested checkout is still refused.
- **Folders outside git with non-ASCII names.** In a folder that is not a git work tree and whose name has non-ASCII characters, handoffs were saved under a second, wrongly encoded folder, and the session's own handoff was taken for another session's.
- **Session identity under Git Bash.** Git Bash's Perl sees every hook's parent as process 1, so the helper took process 1 for Claude Code, and every record kept by process (the session's alive record, sessions, locks) named it. Under Git Bash and Cygwin the helper now goes by Claude Code's own `CLAUDE_PID`. On macOS and Linux a helper whose parent is process 1 is an orphan and keeps process 1, as before.
- **Report name clashes.** Two `watch report` runs on one date could pick the same file name: one report replaced the other, or the second one said the output folder was not writable.
- **Own usage readings in `/afk-compact:status`.** Only the other sessions' readings were grouped by period, so a reading of the session that the near-limit rule does not go by looked like the deciding one. The line now says when another session read the same period later, with that share. On a full tie the session's own reading stays the latest, as in the plugin, and a reading dated more than a minute ahead of the clock shows as of unknown time.

### Upgrade notes

- Status-line scripts that matched `cold (compacted)` should read the JSON `label` key, which is `compacted` right after a compaction. The plain line now reads `cache compacted`; `state` still reads `cold`.
- No other action is required.

### Compatibility

- Requires Claude Code 2.1.287 or newer. The one-line install needs 2.1.292 or newer.
- Tested against Claude Code 2.1.322.

## [0.1.10] - 2026-11-12

afk-compact 0.1.10 fixes a hang on resume. On Claude Code 2.1.322, the first prompt after `claude --resume` could hang with no reply, because the plugin waited for a context reading that Claude Code only finishes after that prompt's own hooks. The fault dates from 0.1.4.

### Fixed

- **Resumed sessions no longer hang on the first prompt.** After `claude --resume`, the first prompt could wait forever with no request sent (seen on Claude Code 2.1.322). The plugin no longer waits for the compaction window reading before that prompt; it still reads the window once and uses it as soon as it arrives.
- **Halt mode on resume.** A resumed session now reads halt mode and its idle state from the earlier process before the first prompt is handled, so a note restored on that prompt shows halt mode when it is on.

### Upgrade notes

- No action is required.

### Compatibility

- Requires Claude Code 2.1.287 or newer. The one-line install needs 2.1.292 or newer.
- Tested against Claude Code 2.1.322.

## [0.1.9] - 2026-11-11

afk-compact 0.1.9 keeps near-limit stops in force through long idle gaps. Before this release, a usage reading counted for only 10 minutes, so after 10 idle minutes a limit at 99% no longer stopped keep-warm or plugin idle compaction. A reading now counts until its limit resets. This release also supports installs that Claude Code reads in place from a local folder marketplace.

### Changed

- **Near a usage limit** (plugin idle compaction, keep-warm and the idle handoff turn): a reading now counts until its limit resets, however old it is. Until the reset, a limit's share only grows, and nothing refreshes an idle session's reading (keep-warm's requests do not). A reading whose reset time has passed counts for nothing. A reading with no reset time counts only while it is from the last 10 minutes.
- **Readings are grouped by period.** Readings of one limit with the same reset time (within a minute) belong to one period, and the latest of them is that period's share. A limit stops these actions only when every period of it is at or over the limit. Behind a proxy that spreads requests over several accounts, each account has its own period, so one with room lets them run.
- **Going above 90% still needs a current reading.** When an agent, a workflow or a working teammate is open, running past 90% needs a reading from the last 10 minutes. An older one stops them at 90%, and the log row says `rule: stale`.
- **A reading of unknown time** is the latest of its period only when its share is larger. This covers a reading dated more than a minute ahead of the clock, and the session's own reading just after a plugin reload, before Claude Code refreshes it.
- **When no limit is reported**, for example by a session restarted during the idle gap before its first response, the session's own entries in the shared usage record stand for it, beside the other sessions' entries. After a plugin reload, they are read beside the reported reading too.
- **The shared usage record keeps an entry until its limit resets.** An entry with no reset time is kept for 10 minutes after it was last read or shown. A full record never drops a period's latest reading.
- **`/afk-compact:status`** lists each of the session's usage readings with its age and reset time. A reading past its reset is marked "not counted", and so is one with no reset time after 10 minutes. The line also lists the other sessions' readings that count, the latest of each period.
- **Usage writes are throttled.** Only one runs at a time, a refresh that arrives during a write is folded into one check after it, and shares are compared by whole points. Many parallel subagents now start one helper process instead of one each.

### Fixed

- **Local folder marketplaces.** A copy that Claude Code reads in place from a local folder marketplace now counts as installed. Its first session writes the status line's fixed command path (`~/.local/state/afk-compact/bin/afk-compact-store`), and its options and version scope resolve like any other installed copy's. A `--plugin-dir` load of the same folder still never changes that path.
- A session whose marketplace was later pointed at another folder keeps its install by its data folder. A `--plugin-dir` data folder under `CLAUDE_CODE_PLUGIN_CACHE_DIR` stays a `--plugin-dir` load.
- **The status line's next keep-warm time** (`keep_warm.next_due_at`) now follows the gap's own ping interval, which the `keep_warm_start` row now records as `ping_s`.

### Upgrade notes

- No action is required.
- After uninstalling a copy read in place from a local folder marketplace, the status line's fixed command path keeps running that folder for as long as it exists, because Claude Code never deletes it. Delete `~/.local/state/afk-compact/bin/afk-compact-store` yourself and remove the call from your status line.

### Compatibility

- Requires Claude Code 2.1.287 or newer. The one-line install needs 2.1.292 or newer.
- Tested against Claude Code 2.1.319.

## [0.1.8] - 2026-11-11

afk-compact 0.1.8 changes how the plugin reads your usage limits before it runs plugin idle compaction, keep-warm and the idle handoff turn. Sessions on the same machine now share their usage readings. Only recent readings count, and a limit stops these actions only when every recent reading of it agrees.

### Added

- **Shared usage record.** Each session's hooks write their latest usage reading to one small file, `~/.local/state/afk-compact/usage.v1.json`. For each window it stores the share, the reset time, when it was read, the source and the first 8 characters of the session id. It holds no account or conversation data. Entries that were not read or shown for an hour are dropped at the next write. Like the cache state, it is never written inside a git work tree.
- **`--note-usage` for the status line command.** `afk-compact-store cache --stdin --note-usage` also writes the five-hour and seven-day shares (and their reset times) that your status line shows into the shared usage record. Without the flag the command stays read-only, and the plugin works the same without a status line.
- **`/afk-compact:status` shows usage.** A new line gives the session's last reading of each window, with its source (plugin or status line) and age, plus the number of recent readings from other sessions on this machine. A session with no recent entry reads "no reading of this session in the last hour".
- **More detail in the logs.** Each row that uses a usage reading now records where each window's reading came from (`plugin`, `statusline` or `peer`), its age (`usage_age_s`) and how many recent readings there were (`usage_n`). A compaction, keep-warm request or idle handoff turn that runs although one reading is at the limit records why: `split` (another recent reading had room) or `no-fresh` (no reading from the last 10 minutes). A reading whose reset time is more than an hour away from the others is logged as `usage_anomaly`.

### Changed

- **Near a usage limit** (plugin idle compaction, keep-warm and the idle handoff turn): the plugin reads every reading it has of a limit: the session's own, its status line's and those of your other sessions on this machine. Only readings from the last 10 minutes count. A limit stops these actions only when every such reading is at or over it. If any recent reading has room, or there is no recent reading, they run. A status line's reading never counts as newer than the plugin's own reading of that session.
- The 10-minute freshness requirement used to apply only to the band above 90% (when an agent, a workflow or a working teammate is open). It now applies to all readings, so the `stale` rule no longer appears in log rows.
- When no limit is reported, plugin idle compaction and the idle handoff turn use the share read when the last turn ended only if that reading is from the last 10 minutes.
- `idle_handoff_near_limit` (`skip` and `skip-spend`) now reads limits the same way: the turn is skipped only when every reading of the limit from the last 10 minutes is at 90% or more. The setting's name, options and default (`run`) are unchanged.
- In skip and stop rows, `windows` now gives the share of the reading that made the decision. Where readings disagree, this is the one with room, which can come from another session.
- When keep-warm waits for a usage window to reset, it logs a `keep_warm_wait` row with the time the next request is due. The status line's cache state (`keep_warm.next_due_at`) then shows that time instead of 50 minutes after the last warm request.

### Fixed

- If the list of running agents cannot be read, plugin idle compaction and the away digest now count open teammates the same way keep-warm already did.
- A failed write to the shared usage record no longer counts as written, so the next refresh tries again right away.

### Upgrade notes

- No action is required.
- Optional: to share your status line's usage readings with the plugin, add `--note-usage` to the `afk-compact-store cache --stdin` command in your status line setup (see "The cache state in your status line" in the README).
- If `XDG_STATE_HOME` points inside a git work tree, the usage record is not written. Each session then reads only its own usage, and `/afk-compact:status` shows none.

### Compatibility

- Requires Claude Code 2.1.287 or newer. The one-line install needs 2.1.292 or newer.
- Tested against Claude Code 2.1.319.

## [0.1.7] - 2026-11-11

afk-compact 0.1.7 can show the prompt cache's state in your Claude Code status line. It replaces the fixed 90% usage-limit cutoff for plugin idle compaction and keep-warm with an adaptive rule. When keep-warm stops with real work still open, the plugin now compacts the session instead of letting the cache go cold.

### Added

- **Cache state in your status line.** A new helper command, `cache --stdin`, prints whether the conversation is still cached and how long it has left. While keep-warm runs, it also shows which request of the idle gap it is on, for example `cache 1h warm 42m left ↻3/7` or `cache cold (compacted)`. You call it through a fixed path that the plugin keeps current, `~/.local/state/afk-compact/bin/afk-compact-store`. Add `--json` for your own format, or `--sid <session id>` to ask about a session by its id. The README shows a plain `statusLine`, a wrapper script that keeps your own line, and a ccstatusline widget. The format is described in `assets/cache-contract.md`.
- **Near a usage limit** (new README section). Plugin idle compaction and keep-warm still stop at 90% of a spend limit. For the five-hour or seven-day window, they can now go on up to 98% or 95% when all of these hold: an agent, a workflow or a working teammate is still open, the usage reading is less than 10 minutes old, and the compaction's measured effect on your usage still fits under the cap. When a window resets before the cache would expire, keep-warm waits for the reset. There is no setting for this.
- Log rows for limit skips and stops now name the rule that decided (`rule`) and, where Claude Code provides them, the plan and tier. Each plugin compaction logs the plan windows' usage before and after it.

### Changed

- **Keep-warm hand-over.** Keep-warm can stop at its `keep_warm_hours` cutoff, at the last moment the waiting compaction can run, or in the band near a usage limit. If an agent, a workflow or a working teammate is still open at that point, plugin idle compaction now runs from `idle_handoff_min_tokens` up, so also below the usual idle-compaction minimum. The idle handoff turn still runs there instead when plugin idle compaction is off (`idle_compact: false`, automatic compaction off, or after plugin idle compaction failed twice). A background shell alone does not trigger this, because it may never end.
- **Teammates.** A teammate that is waiting idle for a message no longer counts as an open job for keep-warm, plugin idle compaction or the digest's `Basis:` count. A teammate that is working, or an agent waiting on its own background work, still counts.
- **Cold cache after a missed keep-warm request.** If a keep-warm request finds the cache cold, plugin idle compaction and the idle handoff turn now wait for the session's next request instead of running on a cold cache.
- `idle_handoff_near_limit` now applies only to the idle handoff turn. Plugin idle compaction and keep-warm follow the rule in "Near a usage limit". The `/config` text for this setting, `keep_warm_hours` and `idle_handoff_min_tokens` was updated to match. Defaults are unchanged.
- `/afk-compact:status` shows the size below which nothing runs while idle. It also says why there is no idle handoff turn after plugin idle compaction failed twice.
- `/afk-compact:prune --apply` also deletes the status line's cache state files for sessions that ended more than 7 days ago.
- Handoff and resume: a durable recurring scheduled task survives exit, so it is no longer listed as work that stops when Claude Code exits. The handoff report leaves out its "Running now" item when only such work is running.

### Fixed

- Saving a handoff with a very long line of list markers took seconds. It now takes time in proportion to the line's length.
- A failed keep-warm request no longer cancels the cache expiry recorded by an earlier successful one.

### Upgrade notes

- The status line is opt-in. To use it, add the command to `statusLine` in your settings as shown in the README. The plugin's first session after the update creates the fixed path.
- Uninstalling the plugin leaves `~/.local/state/afk-compact/bin/afk-compact-store` in place. Once Claude Code deletes the old plugin folder, that script fails. To clean up, delete the script and remove the call from your status line.

### Compatibility

- Requires Claude Code 2.1.287 or newer. The one-line install needs 2.1.292 or newer.
- Tested against Claude Code 2.1.319.

## [0.1.6] - 2026-11-09

afk-compact 0.1.6 changes the on/off settings to `true`/`false` with a picker in `/config`, adds `/afk-compact:prune` for cleaning up old evidence, and ships a written contract and a `queue check` command for the optional question queue. Saving a handoff now fixes two simple format problems itself instead of refusing the handoff.

### Added

- **`/afk-compact:prune [--days N] [--min-mb N] [--root DIR]`**: lists the evidence folders of old handoffs and the old dated folders of temporary evidence, with their age, size, bucket and handoff. It deletes them only after you say yes (`--apply` with the plan hash from the dry run). Handoff files, summary copies, `MANIFEST.tsv`, logs and files that a newer handoff cites are never deleted. Deleted copies show as `pruned` (not `missing`) in `verify` and `/afk-compact:resume`.
- **Question queue contract**: `assets/queue-contract.md` in the plugin folder, with a JSON Schema for the `list` reply and one for the `add` draft, plus a minimal folder-based example program (`assets/examples/queue-folder.sh`). The new README section "Connect your own question queue" explains how to set it up.
- **`queue check`**: `"<plugin folder>/scripts/afk-compact-store" queue check [<program>]` runs your program's `list` once and checks the reply against the contract. It prints `ok` or `FAIL` for each check, with a fix for each failure, and writes nothing. While `queue_cmd` is set, `/afk-compact:status` lists the command.
- **Fixes when a handoff is saved**: an id range that the save would refuse is written out as its individual ids, and a missing first item under Next steps gets a copy of Step 1. The save prints one line for each change. Approval lines, quoted or code text, and sections that contain code fences, quotes, HTML or indented code are left exactly as written.

### Changed

- **On/off settings take `true` or `false`**: `handoff_turn`, `precompact_turn`, `watcher`, `unattended_prod_reads`, `idle_handoff_turn`, `idle_compact` and `resume_proceed`. All of them default to `true` except `unattended_prod_reads`, which defaults to `false`. `relaunch_auto`, `restart_on_update`, `idle_handoff_near_limit` and `idle_digest` keep their words. In `/config`, all eleven now open a picker with the setting's description.
- **`otel_log_path` is no longer shown** on the install screen or in `/config`. It had no effect.
- **`disposable_keep_days`** is now also prune's default age (14 days while it is `0`).
- **Idle compaction terms**: the README, `/config` and `/afk-compact:status` now separate *native idle compaction* (Claude Code's own), *plugin idle compaction* (`idle_compact`) and the *idle handoff turn*. The status idle line prints the token range each one covers, based on your effective settings. `idle_handoff_min_tokens` is documented as the minimum size for the idle handoff turn, not as an idle-compaction threshold.
- **Log rows**: when the idle handoff turn or keep-warm is skipped near a usage limit, the log row now names the usage windows it read and their shares.
- **Background work, `/clear` and exit**: handoffs and resume now say that background work keeps running after `/clear` and stops at exit. "Move to background and exit" carries over only shells, agents and workflows.
- **`/afk-compact:status` and `settings show`** now warn about a saved value that is not one of the setting's options.

### Fixed

- In the resume block, a background task that its notification reported as ended now shows as ended.
- Question queue `add`: size caps are checked again after secrets are redacted, so every cap holds for what your program receives. A question's closing `?` is kept. `recommendation_none_reason` keeps its 200-byte cap even next to a recommended option, and if it is blank there it is dropped instead of refused.

### Upgrade notes

- Only values you saved yourself for the seven on/off settings are affected. Values saved by earlier releases (`halt`, `model`, `shadow`, `allow`, `auto`, `off`, `code`, `forbid`, `confirm`) are still read by `/afk-compact:status`, `settings show` and the skills. However, Claude Code treats a value that is not on a setting's list as unset, so the hooks use the default. For example, a behaviour you turned off would run again. Run `! "<plugin folder>/scripts/afk-compact-store" settings migrate` to see what would change, then add `--apply` to save the new form. Consent keys are only listed: set those again in `/config`.
- A saved `otel_log_path` value can stay or be removed. It did nothing before and does nothing now.

### Compatibility

- Requires Claude Code 2.1.287 or newer. The one-line install needs 2.1.292 or newer. The option lists in `/config` need 2.1.271 or newer, which this covers.
- Tested against Claude Code 2.1.306. The `/config` pickers were checked on Claude Code 2.1.319.

## [0.1.5] - 2026-11-08

afk-compact 0.1.5 keeps the ledger lines (`U-`, `D-` and `X-`) from one handoff to the next. Summary steps can now be marked as waiting on a job or on you, and the plugin reads those marks after an idle compaction. This release also fixes how the resume block is delivered while a background agent runs.

### Added

- **The ledger stays.** `U-`, `D-` and `X-` lines are your constraints and asks, the decisions and the rejected options. They now carry from one handoff to the next. Lines that mark one superseded or moved to `ledger.md` carry too.
  - If a draft drops a ledger line without marking it superseded, publish copies the line back unchanged and says so.
  - Publish refuses a draft that gives an existing id to a different item, including an id already superseded or moved to `ledger.md`. The item needs a new id first. A reworded line or a new status is only reported.
  - Publish also refuses a carried line that contains a private path or a secret.
  - A saved compaction copy of the main conversation gets the same carry from the session's newest earlier copy that had the expected shape. Copies saved late from a stash do not get it. The copy's frontmatter lists the added lines under `ledger_carried`.
- **Wait marks on next steps.** In the compaction summary and the handoff template, a step still to do can now carry `waits: job` (it waits on a running job's result) or `waits: you` (it waits on you). A gated step is marked `waits: you`.
  - A step's `waits:` mark takes priority over its wording. Wording is still used for steps with no mark, such as those in older summaries.
  - A first step with a `waits:` mark no longer counts as a step that can still run.
  - A wait mark counts after a dash, a bullet or a colon, and also inside brackets.

### Changed

- Step marks are read more loosely. A `todo` or `done` mark after a dash, a bullet or a colon, or in brackets of its own (`(done)`), reads the same as `· done`. A note in brackets after the mark is fine (`— done (commit 1a2b3c)`). A mark inside a note's brackets never counts: `— todo (review: done)` and `· todo (build · done)` stay todo.
- The away digest now opens with the `Basis:` line, given exactly as the plugin fills it in. The work lane's state and the rest follow.
- `idle_handoff_min_tokens` (default 200,000, range unchanged): a work lane that reads finished after an idle compaction now gets the handoff-when-idle turn at any known size, until your next message. The turn never runs when the context size is unknown.

### Fixed

- While a background agent runs, Claude Code's side requests, such as the summary it writes of that agent, no longer take the resume block. The main turn gets the block.
- A resume block that one of those side requests passed over is now delivered with the next main prompt, without waiting for another request.

### Upgrade notes

- No settings were added, renamed or removed, and you don't need to do anything to upgrade.

### Compatibility

- Requires Claude Code 2.1.287 or newer. The one-line install needs 2.1.292 or newer.
- Tested against Claude Code 2.1.306.

## [0.1.4] - 2026-11-07

afk-compact 0.1.4 reads Claude Code's own compaction window and says straight away when an update has replaced the plugin copy a session runs. It also makes the Resumed line depend on who reads the reply and tightens protected-branch gates. Watcher alerts are more accurate, and this release fixes non-ASCII paths, perl under MSYS and Cygwin, and hooks whose perl cannot start.

### Added

- **Notice when a copy is replaced.** If an update or uninstall replaces the copy a session runs, the session reports it at once: `this session runs 0.1.4, replaced by an install at <time>: /reload-plugins`. The notice goes away after `/reload-plugins`.
- A published handoff's frontmatter now names the plugin version and folder that wrote it, the same way a summary copy does. The repo-mode export keeps the version and drops the folder.

### Changed

- **`native_window_tokens`** (default `0`): when unset, it now follows the compaction window Claude Code reports. That window comes from `CLAUDE_CODE_AUTO_COMPACT_WINDOW`, `autoCompactWindow` or the model's default, and when Claude Code reports its own compaction point the plugin uses it. The plugin reads the window once per load, locally, with no API request. If Claude Code reports no window, the plugin uses `autoCompactWindow` and then the model's window, as before. The `config_effective` row records `window_from` and `autocompact_source`.
- **Resumed line:** the line is now left out when a script reads the reply (`claude -p`, the Agent SDK). It stays in the terminal, the desktop app, IDE extensions, mobile, Slack, Cowork and SSH remote sessions. The plugin decides from `CLAUDE_CODE_ENTRYPOINT`, which now also works where only the classic hooks run.
- **Approvals and explicit gates:** a carried approval never covers an explicit gate. Protected branches are matched by name on any remote, `staging` is now on the list, and so is any branch that you or the repository's instructions or settings name as protected.
- **Auto permission mode:** the actions asked again after a compaction, quoting your approval, are now limited to the kinds that Claude Code's auto-mode classifier still blocks: force-push, history rewrite, branch or tag delete, and external write.
- **Watcher alerts:**
  - The stalled-item alert (A-11) follows a background workflow's run journal and its agents' transcripts.
  - The lost-rule alert (A-09) no longer counts a renumbered or re-spaced ledger line as lost.
  - The continue-without-nudge alert (A-27) skips earlier and idle compactions and the plugin's own handoff-turn message.
  - Claude Code's "Compacted while idle" notice now marks a compaction as idle.
  - The folder-quota warning (A-24) also fires above 20,000 entries and closes once the folder is back under the limit.
- The daily prune now also covers per-session records in `.sessions/by-pid/`, and it keeps the records of processes that are still running.

### Fixed

- A hook whose perl is found but cannot start, or ends on a signal, now exits quietly like the no-perl case. Helper commands print that perl's error.
- A store folder with a non-ASCII name no longer gets a second, double-encoded copy when a skill reads the session id. Non-ASCII repository, worktree and transcript paths in copies are now encoded once.
- Under perl from MSYS or Cygwin, non-ASCII folders and process start times are now read correctly, and a Windows drive path set as a folder is now checked like any other folder inside a git work tree. Native Windows is still not supported.
- A relative `handoff_root` or `log_dir` is now refused instead of writing under the working folder. `/afk-compact:status` shows `root: <key> refused (root-invalid)` for such a folder.
- In the project-state measurement, the project-state lines now come before the git header, so changed files no longer look like part of them.
- Command fragments such as `/tmp/run-$n` or `/tmp/out-%d` are no longer recorded as temp paths.

### Upgrade notes

- After updating, run `/reload-plugins` in running sessions. No settings were renamed or removed.
- On its first Stop after the update, the watcher re-checks open lost-rule (A-09) and continue-without-nudge (A-27) alerts written by older versions and closes the ones the changed rules would not raise (`superseded: rule changed in 0.1.4`). No rows are deleted.

### Compatibility

- Requires Claude Code 2.1.287 or newer. The one-line install needs 2.1.292 or newer.
- Tested against Claude Code 2.1.306.

## [0.1.3] - 2026-11-03

afk-compact 0.1.3 adds a status line to the first reply after a compaction and a one-line verdict to `/afk-compact:status`. It also warns when other sessions run a different plugin version, makes the watcher's alerts less noisy and makes the end-of-turn hook faster on long sessions.

### Added

- **Resumed line.** The first reply after a compaction opens with one status line, before any tool call: `Resumed · step 1: <the summary's Step 1>`, or `Resumed after compaction` when no Step 1 can be read. After a cut-off handoff, its `✓ Handoff saved: <path>` line takes that place. Headless sessions (`claude -p`, the Agent SDK, the desktop app) leave the line out when the plugin's mod is loaded.
- **Verdict line in `/afk-compact:status`.** It now opens with `ok: …` or `attention: …`, which counts saved copies and open warn or critical alerts for this session (or the last 7 days when there is no session id).
- **Version skew notice.** Saved copies record the plugin version and folder that saved them. `/afk-compact:status` always shows the session's version and plugin folder. When sessions started later run another version, status, the resume block and `/afk-compact:handoff`'s report say so in one line that ends with `/reload-plugins`.
- **`ok-unclosed` verdict.** This is a summary that has every required section through Next steps but no closing line. It counts as ok: no fallback note, and it never counts toward halt mode.
- Each turn's end writes a `stop_timing` row to the local logs (not with `watcher: off`).

### Changed

- `native_window_tokens`: when unset (`0`, the default), the plugin now follows Claude Code's `autoCompactWindow` setting, capped at the model's window. If that setting holds no number, it uses the model's window. A number you set yourself still wins.
- `stall_min`: a background job whose output file cannot be checked is no longer flagged as stalled.
- Approvals in a handoff: when the plugin cannot find an approval's words in your own messages, the save no longer fails. The approval moves to Open questions so you are asked again, and the save prints one note for each approval it moved.
- Fewer false alerts. The watcher no longer raises missing-copy, band or missing-hooks alerts for compactions from before the session's first plugin row, and the band alert skips idle compactions.
- After a compaction, a question whose dialog timed out is not asked in a dialog again until you write. It is listed at the end of the turn instead.
- The end-of-turn (Stop) hook now has a 3.5-second budget, counted from the helper's start. Work that does not fit waits for the next turn. A missing-copy alert waits until the copy is saved or the session ends.
- The handoff secret warning now names the draft's line numbers along with the rule ids, never the value.

### Fixed

- Scanning a long transcript for temp paths could take minutes and run past the hook timeout. It now runs in linear time and uses much less memory.
- The classic hooks' `last-version` record could be written into another plugin's data folder. It now stays in this plugin's own data folder.
- Some summaries had no closing line. The closing-line rule now comes last in the handoff instructions.
- `/afk-compact:handoff` no longer lists pieces of shell commands (variables, globs, relative fragments) as temp-file candidates.

### Upgrade notes

- Run `claude plugin update afk-compact`, then `/reload-plugins` in sessions that are already open. Until then, a session keeps the copy it loaded.
- The version skew notice works only when both sessions run 0.1.3 or later.
- On its first turn end after the update, the watcher re-checks open alerts written by older versions. It closes the ones the new rules would not raise by adding a row (reason `superseded: rule changed in 0.1.3`) and deletes nothing. For 7 days, status shows how many alerts it closed this way.

### Compatibility

- Requires Claude Code 2.1.287 or newer. The one-line install needs 2.1.292 or newer.
- Tested against Claude Code 2.1.306.

## [0.1.2] - 2026-10-31

afk-compact 0.1.2 moves the default handoff and evidence folders out of `~/.claude`, so Claude Code no longer asks before every write in the default permission mode. It also adds a settings skill, shows every setting's default, keeps the prompt cache warm while background jobs run, and carries approvals more carefully across compactions.

### Added

- **`/afk-compact:settings`**, a fifth skill. It goes through the plugin's settings section by section and shows each value, where it comes from and its default. It changes or resets only the settings you pick, and it shows the change and asks before writing your settings file. It never changes the six consent keys. Before it writes, it keeps a backup of `~/.claude/settings.json` next to the file.
- **Helper commands** `settings show`, `settings set <key>=<value>` and `settings reset <key>` (or `--all`). They are dry runs unless you add `--apply`.
- **Visible defaults.** Every setting's title now ends with its default, for example `[default 400,000]`. `/afk-compact:status` lists every value the plugin uses under `settings values:`, with its source and default.
- **`keep_warm_hours`** (default `6`, allowed 0 to 24, `0` = off). The session may be idle while one of its own background jobs (an agent, a workflow or a background shell) is still running. In that case the plugin sends one small hidden request about every 50 minutes to keep the one-hour prompt cache warm. When the time is up and a job is still running, the plugin compacts the session (or runs the handoff-when-idle turn) while the cache is warm. This only happens with the one-hour cache, and it stops when a turn starts or a usage limit reaches 90%. Each request counts toward your usage limits. `/afk-compact:status` shows a keep-warm line.
- **`idle_handoff_near_limit`** (`run`, `skip-spend` or `skip`; default `run`). It controls whether the handoff-when-idle turn runs when a usage limit is at 90% or more. With `run`, that turn counts toward a nearly used allowance, and if your plan has extra usage turned on, usage past a plan limit may be billed. The plugin's own idle compaction never runs at 90% or more.
- **Open questions are carried over.** If the last turn ended on a question you have not answered (in its text, or in a question dialog that timed out), the resume block after a compaction quotes it.
- **`migrate`** helper command. It copies the old default folders into the new ones. It is a dry run by default, `--apply` copies, and it never deletes, moves or overwrites anything.

### Changed

- **New default folders:** `handoff_root` is now `~/.local/state/afk-compact/handoffs` and `disposable_root` is `~/.local/state/afk-compact/disposable`. If `XDG_STATE_HOME` is an absolute path, both go under `$XDG_STATE_HOME/afk-compact/`. While these settings are unset (or set to the new default), the old `~/.claude/handoffs` and `~/.claude/trash-staging` are still read but never written. A value you set yourself is never changed.
- **Approvals:**
  - A handoff the plugin asked for itself (when it stops a turn, before a compaction or while you are away) records every approval as context only, and the next step asks you again.
  - An approval whose action was refused in the session is also context only.
  - In auto permission mode, a carried approval no longer covers an outward action that the auto-mode classifier gates. The resume asks first.
- **Question dialogs:** a dialog you answered no longer counts as the turn asking you a question. Only a dialog still open at the end of the turn, or one closed without an answer, stops auto-continue, the handoff turn and restart.
- **Handoff limits:** the size limit for each handoff section was raised.
- **smoke:** it now fails only when a rare string in the Claude Code binary or the compaction experiment's list of arms changes. Changes in common words print an `info c8` line. If no type declarations are found, it tells you to type `/plugin-authoring` once.

### Fixed

- Log timestamps now use the system time zone at the moment each row is written. After a time zone change, rows no longer carry the old offset.

### Upgrade notes

- In the default permission mode, add `Edit(~/.local/state/afk-compact/**)` to `permissions.allow` in `~/.claude/settings.json` to stop the write prompt. A `Write(...)` rule does not match these writes. If you set `XDG_STATE_HOME`, name that folder instead.
- If your home folder is a git work tree, add `/.local/state/afk-compact/` to `~/.gitignore`. Otherwise the plugin writes nothing there, and `/afk-compact:status` reports the folders as `in git, not ignored`.
- To keep using the old folders, set `handoff_root` to `~/.claude/handoffs` and `disposable_root` to `~/.claude/trash-staging`.

### Compatibility

- Requires Claude Code 2.1.287 or newer. The one-line install needs 2.1.292 or newer.
- Tested against Claude Code 2.1.306. The smoke baseline was recorded on Claude Code 2.1.314.

## [0.1.1] - 2026-10-30

afk-compact 0.1.1 can compact a long idle session itself before the one-hour prompt cache expires. It also keeps a pending resume block across an exit or restart and compacts headless sessions by running `/compact`. The settings screen now describes every option in plain language.

### Added

- **Idle compaction by the plugin (`idle_compact`, default `auto`).** Applies when `"idleCompaction": false` is in your Claude Code settings. A main conversation of 200,000 tokens or more is compacted about 54 minutes after its last request, before the prompt cache expires. If your settings leave Claude Code's own idle compaction on, the plugin checks at about 55.5 minutes and compacts only when Claude Code did not. It also does this while agents or workflows are running. It is skipped when the cache has probably expired, when the cache is the five-minute one, when a usage limit is at 90% or more, or when someone is typing. After two failures in a row it stops for that session. Terminal sessions only for now.
- **Away digest (`idle_digest`: `submit`, `return` or `off`; default `off`).** After an idle compaction whose work is finished or only waiting on you, the next reply starts nothing new. With `off`, it says in one line where the work stands, then what needs you. `submit` sends a short summary turn right away. `return` puts the summary at the top of the reply to your next message.
- **Compaction line after each compaction.** A dim line in the transcript says how the compaction went: the verdict, whether the copy was saved, whether a handoff came before it, and which jobs are still running. The model does not see it, and it is never shown in a subagent. It is controlled by `warn_ui`.
- **Short handoff acknowledgment.** A handoff published just before a compaction gets one acknowledgment line after the compaction, not a repeat of its report.
- **Restart on update (`restart_on_update`: `on`, `shadow` or `off`; default `off`; beta, read from your settings file only).** This adds the setting and the `afk-compact-claude` launcher for a future automatic move onto a newly installed Claude Code. Neither restart route is active in this version. `/afk-compact:status` shows the current state.
- **Headless sessions** (`claude -p`, the Agent SDK, the desktop app). Claude Code rejects the plugin's compaction call there. At a turn end at or above the target, the plugin now runs `/compact` and shapes that compaction itself. This is not yet checked in a live session.
- **Cache reads of each compaction are logged.** A large compaction that read a cold cache raises an alert in `/afk-compact:status`.

### Changed

- If a session exits or restarts before its next turn, its resume block now waits on disk. It goes to the first turn after `claude --resume` of the same session and is measured again if it is more than 10 minutes old. A newer compaction replaces it, `/clear` drops it, and a forked session never gets it.
- `idle_handoff_turn` now runs only when nobody compacts the idle session. That means `idle_compact: off`, automatic compaction off, the conversation below the minimum, or the plugin's compaction failing twice.
- Every option on the install screen and in `/config` has a clearer title and a plain-language description. The README has a matching table, and the exact rules are in a collapsible section. No key was renamed.
- If `CLAUDE_CONFIG_DIR` points to a folder whose `settings.json` is a link to `~/.claude/settings.json`, the keys read from your settings file only now come from that file as usual.

### Fixed

- A prompt you queue while a turn runs now clears halt mode when its own turn starts. An auto-continue or a plugin compaction no longer goes ahead of a prompt you are entering.
- The summary is found even when Claude Code puts a header before it.
- The watcher writes nothing when its log folder or handoff folder is inside a git work tree that does not ignore it. This includes folders not created yet and paths with non-ASCII names.
- A moved or respawned session keeps its idle timer.
- `save-copy` refuses a folder given as `--from`.
- `report --since` accepts only real calendar dates.
- Helper output no longer includes a Perl locale warning.

### Upgrade notes

- If you have `"idleCompaction": false` in your Claude Code settings, idle sessions with the plugin enabled are now compacted by the plugin. Before this version, no idle compaction ran. To keep none, set `idle_compact` to `off`.
- `restart_on_update` is read from `~/.claude/settings.json` only, the same as the other options that let the plugin act without asking.

### Compatibility

- Requires Claude Code 2.1.287 or newer. The one-line install needs 2.1.292 or newer.
- Tested against Claude Code 2.1.306.

## [0.1.0] - 2026-10-28

The first release of afk-compact, a Claude Code plugin for long unattended sessions. When a session compacts, the plugin asks Claude Code's own summarizer for a handoff instead of a plain summary. It keeps a read-only copy of every summary, checks that the summary has the expected shape, and gives the next turn a short resume block so the work can continue.

This is an early (0.x) version. Some parts that need a live session or a managed machine have not been run end to end yet. The README's Limits section lists them.

### Added

- **Shaped compactions.** Native auto-compaction, a manual `/compact` (your note comes first and wins) and compactions the plugin starts itself all get the same handoff instructions. Subagents get a shorter form. If the plugin's mod hook does not run, a classic `PreCompact` hook gives the same instructions instead.
- **Compaction at a clean turn end.** Once the context passes `compact_target_tokens`, the plugin can compact after a turn ends normally, before native auto-compaction cuts in mid-task. Past `compact_soft_max_tokens` it adds one checkpoint nudge. After a nudged compaction it can send one continue note, up to `max_auto_continues_per_hour`. Two non-ok verdicts in a row, a compaction loop or the hourly cap switch on halt mode.
- **Handoff turns.** Before a planned compaction, and before the last compaction of a run that will not continue by itself, the model gets one extra turn to write a handoff while the full context is still there. When Claude Code's own idle compaction is off or did not run, an optional pre-idle handoff turn does the same.
- **Summary copies and verdicts.** Each summary is saved once, read-only. Every compaction gets one verdict: `ok`, `ok-trailer`, `truncated`, `unshaped`, `scope-leak` or `stale`. Verdicts only inform. They never block or rewrite a compaction.
- **Resume block.** After a compaction, the next turn gets the path of the saved copy and a fresh git and project-state measurement. After an idle compaction, the measurement is repeated when you come back.
- **Evidence copies.** Temp files that the session cited are copied to a dated folder. The copy has size caps and secret checks, and the plugin deletes nothing.
- **Lost background jobs.** A background job that is gone is checked again from the plugin's own records. A read-only or allowlisted job may start again by itself, and everything else asks you first.
- **Repo mode (opt-in).** A repository that declares `.claude/handoffs.json`, and is also listed in your `repo_roots`, receives a scanned export of each published handoff. The plugin never stages, commits or pushes it.
- **Optional question queue** through a `queue_cmd` executable of your own. It is off by default.
- **Watcher.** It keeps local, content-free logs of compactions, nudges, continues and resumes, and shows alerts. It makes no network calls and sends no telemetry.
- **Skills.** `/afk-compact:handoff`, `/afk-compact:resume`, `/afk-compact:status` and `/afk-compact:report`. The report skill bundles the logs into a zip on your disk, and nothing is uploaded.
- **Settings** for thresholds, handoff turns, storage folders, evidence, the watcher, relaunch and production safety. Every setting has a working default. Keys that let the plugin act without asking are read only from your user settings file. The README lists every key and its default.

### Requirements

- Claude Code 2.1.287 or newer. The one-line install needs 2.1.292 or newer. This release was tested against Claude Code 2.1.306.
- Perl 5.28 or newer, using only modules that ship with Perl. Perl is already present on macOS, Debian and Ubuntu. On Alpine, run `apk add perl`.
- `git` for the git measurements.
- Supported: macOS 13 or newer, and Linux with glibc. Expected to work but not yet tested in a session: Alpine/musl and WSL 2. Native Windows is not supported yet.

[Unreleased]: https://github.com/RuslanTar/afk-compact/compare/v0.1.12...HEAD
[0.1.12]: https://github.com/RuslanTar/afk-compact/releases/tag/v0.1.12
[0.1.11]: https://github.com/RuslanTar/afk-compact/releases/tag/v0.1.11
[0.1.10]: https://github.com/RuslanTar/afk-compact/releases/tag/v0.1.10
[0.1.9]: https://github.com/RuslanTar/afk-compact/releases/tag/v0.1.9
[0.1.8]: https://github.com/RuslanTar/afk-compact/releases/tag/v0.1.8
[0.1.7]: https://github.com/RuslanTar/afk-compact/releases/tag/v0.1.7
[0.1.6]: https://github.com/RuslanTar/afk-compact/releases/tag/v0.1.6
[0.1.5]: https://github.com/RuslanTar/afk-compact/releases/tag/v0.1.5
[0.1.4]: https://github.com/RuslanTar/afk-compact/releases/tag/v0.1.4
[0.1.3]: https://github.com/RuslanTar/afk-compact/releases/tag/v0.1.3
[0.1.2]: https://github.com/RuslanTar/afk-compact/releases/tag/v0.1.2
[0.1.1]: https://github.com/RuslanTar/afk-compact/releases/tag/v0.1.1
[0.1.0]: https://github.com/RuslanTar/afk-compact/releases/tag/v0.1.0
