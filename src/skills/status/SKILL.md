---
name: status
description: 'Show handoff plugin status: "handoff status", "did compaction save", last compactions, verdicts, saved copies, version check.'
---

# Status

`<store>` = `"${CLAUDE_PLUGIN_ROOT}/scripts/{{plugin}}-store"`, the plugin's helper. Type it with the quotes, as the first word of the command, never through a variable. If that path starts `/scripts/` or has `${`, the plugin root is `${CLAUDE_SKILL_DIR}/../..`; use that root. If that has `${` too or no helper is there, say so and stop. <!-- Cowork: the task's skill text kept the variables and its Bash had them empty. PROVISIONAL: `${CLAUDE_SKILL_DIR}` is documented (Claude Code changelog 2.1.69), but Cowork kept its skill folder in another tree than the plugin, so whether `<skill dir>/../..` holds the helper there is unchecked; a re-check in Cowork decides this line. The base-directory fallback was dropped: undocumented, and in 2.1.310 built from the same data as `${CLAUDE_SKILL_DIR}` -->

Run `<store> status --sid '${CLAUDE_SESSION_ID}'` and relay its lines as printed, in its order. If that `--sid` value is empty or has `${`, run it as written: never guess or invent a session id (no folder name or other id). The helper then prints `session: unknown (no session id)` and only the lines that are not about this session. <!-- review: single quotes, so an unsubstituted reference reaches the helper as written (no id) instead of whatever CLAUDE_SESSION_ID holds in the Bash environment -->
- `ok: …` or `attention: …` first (one line: saved copies and open alerts; without a session id, the last 7 days; none while the watcher is off), then `watcher:` (its state, log size, how to share or turn it off), then `notice: <text>` while the first-run notice is unshown;
- `plugin: <version> · <folder>` (the copy this session runs), then `plugin notice: …` when this copy was replaced or sessions started since run another version;
- effective thresholds with `min_window`, clamped values marked; `plugin compactions off: …` when the window is below it;
- `seat_state` of the last 5 compactions, with trigger, verdict and copy path;
- open escalations and open watcher alerts, with the last 7 days' counts by rule;
- halt state and auto-continues used this hour;
- `idle compaction: …` (token bands of native idle compaction (Claude Code's), plugin idle compaction and the idle handoff turn, as this session reads your settings; a note while native is on);
- `keep-warm: on|off …` (`keep_warm_hours`: whether the plugin keeps the cache warm while this session's own background jobs run; then the last idle gap that warmed, with its pings and why it stopped, or `keep-warm off (<why>)` for a gap it did not start in (`no-jobs`, `ttl-5m`, `near-limit`, `no-idle-path`, …); once a later main request came (this skill's own turn sends one), that gap is over and it reads `not warming (the last gap: keep-warm off (<why>))`. This skill's own turn ends a gap's warming, so it shows `stopped: turn` for the gap it interrupted; only `! <store> status --sid <this session id>`, typed by the user, shows a gap still warming);
- `smokeDue`;
- `allow rule (default mode): …` (the rule that lets `wait` run unasked), and `allow rule for an older plugin folder: …` when one still names an old folder;
- `user-run commands (type them yourself, with the leading !):`, then each `! <store> …` line. Relay them; never run them yourself. `! <store> reconcile --sid <sid> --orphans --full` finishes the saved copies of ended sessions (about 10 s; writes only into the plugin's own store) and ends with `; orphans finished=<n> kept=<n> left=<n>`; that line is not shown without a session id;
- policy flags, handoff mode (private, or repo with its export folder and how to accept a repository) and the automatic-relaunch state;
- `unattended_prod_reads: … · production patterns: …`, then `queue: off|on|degraded (<why>)`;
- `settings: resume_proceed … · handoff_reuse_window_min … · ticket_pattern … · secret_extra_rules … · evidence_total_max_mb … · watch_quota_mb …`;
- `settings values: <n> not at default, <n> at default`: one line per value not at its default, with its source and default, then `at default:` lines; a `warning:` that ends with a `! <store> settings reset <key> --apply` or `settings migrate --apply` line (a value saved empty, or in a form from before 0.1.6) names a command that edits the user's settings file (`/config` for a consent key): relay it, never run it here; `/{{plugin}}:settings` changes settings when the user asks (`<store> settings show` only reads, and lists every value);
- `kept mismatch stashes: <n>` with their paths.

Repo mode is set up by the user, never by you: `! <store> project status --cwd <repo>`, then `! <store> project init --cwd <repo>` (writes the declaration, README and `.gitignore`; commits nothing), then adding the repository to `repo_roots` in `/config`. `project copy` is a dry run unless the user adds `--apply`. With `--from repo` it never imports an export that has a HARD secret hit: it prints `skip secret <rel> (rules <ids>)`, counted under `skip` in `TOTAL`.

No content, no transcript reads, no actions.
