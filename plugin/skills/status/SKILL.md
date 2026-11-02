---
name: status
description: 'Show handoff plugin status: "handoff status", "did compaction save", last compactions, verdicts, saved copies, version check.'
---

# Status

`<store>` = `"${CLAUDE_PLUGIN_ROOT}/scripts/afk-compact-store"`, the plugin's helper. Type it with the quotes, as the first word of the command, never through a variable. If that path starts `/scripts/` or has `${`, the plugin root is `${CLAUDE_SKILL_DIR}/../..`; use that root. If that has `${` too or no helper is there, say so and stop.

Run `<store> status --sid '${CLAUDE_SESSION_ID}'` and relay its lines as printed, in its order. If that `--sid` value is empty or has `${`, run it as written: never guess or invent a session id (no folder name or other id). The helper then prints `session: unknown (no session id)` and only the lines that are not about this session.
- `ok: …` or `attention: …` first (one line: saved copies and open alerts; without a session id, the last 7 days; none while the watcher is off), then `watcher:` (its state, log size, how to share or turn it off), then `notice: <text>` while the first-run notice is unshown;
- `plugin: <version> · <folder>` (the copy this session runs), then `plugin notice: …` when sessions started since run another version;
- effective thresholds with `min_window`, clamped values marked; `plugin compactions off: …` when the window is below it;
- `seat_state` of the last 5 compactions, with trigger, verdict and copy path;
- open escalations and open watcher alerts, with the last 7 days' counts by rule;
- halt state and auto-continues used this hour;
- `idle compaction: …` (who compacts an idle session — Claude Code, the plugin or nobody — as this session reads your settings, with `idle_compact` and `idle_handoff_turn`; a note while Claude Code's own is on);
- `keep-warm: on|off …` (`keep_warm_hours`: whether the plugin keeps the cache warm while this session's own background jobs run; then the last idle gap that warmed, with its pings and why it stopped. This skill's own turn ends a gap's warming, so it shows `stopped: turn` for the gap it interrupted; only `! <store> status --sid <this session id>`, typed by the user, shows a gap still warming);
- `smokeDue`;
- `allow rule (default mode): …` (the rule that lets `wait` run unasked), and `allow rule for an older plugin folder: …` when one still names an old folder;
- `user-run commands (type them yourself, with the leading !):`, then each `! <store> …` line. Relay them; never run them yourself. `! <store> reconcile --sid <sid> --orphans --full` finishes the saved copies of ended sessions (about 10 s; writes only into the plugin's own store) and ends with `; orphans finished=<n> kept=<n> left=<n>`; that line is not shown without a session id;
- policy flags, handoff mode (private, or repo with its export folder and how to accept a repository) and the automatic-relaunch state;
- `unattended_prod_reads: … · production patterns: …`, then `queue: off|on|degraded (<why>)`;
- `settings: resume_proceed … · handoff_reuse_window_min … · ticket_pattern … · secret_extra_rules … · evidence_total_max_mb … · watch_quota_mb …`;
- `settings values: <n> not at default, <n> at default`: one line per value not at its default, with its source and default, then `at default:` lines; `warning: <key>: saved empty, …` ends with a `! <store> settings reset <key> --apply` line, which edits the user's settings file (`/config` for a consent key): relay it, never run it here; `/afk-compact:settings` changes settings when the user asks (`<store> settings show` only reads, and lists every value);
- `kept mismatch stashes: <n>` with their paths.

Repo mode is set up by the user, never by you: `! <store> project status --cwd <repo>`, then `! <store> project init --cwd <repo>` (writes the declaration, README and `.gitignore`; commits nothing), then adding the repository to `repo_roots` in `/config`. `project copy` is a dry run unless the user adds `--apply`. With `--from repo` it never imports an export that has a HARD secret hit: it prints `skip secret <rel> (rules <ids>)`, counted under `skip` in `TOTAL`.

No content, no transcript reads, no actions.
