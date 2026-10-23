---
name: status
description: 'Show handoff plugin status: "handoff status", "did compaction save", last compactions, verdicts, saved copies, version check.'
---

# Status

`<store>` = `"${CLAUDE_PLUGIN_ROOT}/scripts/afk-compact-store"`, the plugin's helper. Type it with the quotes, as the first word of the command, never through a variable.

Run `<store> status --sid "${CLAUDE_SESSION_ID}"` and relay its lines as printed, in its order:
- `watcher:` first (its state, log size, how to share or turn it off), then `notice: <text>` while the first-run notice is unshown;
- effective thresholds with `min_window`, clamped values marked; `plugin compactions off: …` when the window is below it;
- `seat_state` of the last 5 compactions, with trigger, verdict and copy path;
- open escalations and open watcher alerts, with the last 7 days' counts by rule;
- halt state and auto-continues used this hour;
- `pre-idle handoff turn: …` (whether the plugin's own pre-idle turn is on, from `idle_handoff_turn` and Claude Code's idle compaction setting);
- `smokeDue`;
- `allow rule (default mode): …` (the rule that lets `wait` run unasked), and `allow rule for an older plugin folder: …` when one still names an old folder;
- `user-run commands (type them yourself, with the leading !):`, then each `! <store> …` line. Relay them; never run them yourself. `! <store> reconcile --sid <sid> --orphans --full` finishes the saved copies of ended sessions (about 10 s; writes only into the plugin's own store) and ends with `; orphans finished=<n> kept=<n> left=<n>`;
- policy flags, handoff mode (private, or repo with its export folder and how to accept a repository) and the automatic-relaunch state;
- `unattended_prod_reads: … · production patterns: …`, then `queue: off|on|degraded (<why>)`;
- `settings: resume_proceed … · handoff_reuse_window_min … · ticket_pattern … · secret_extra_rules … · evidence_total_max_mb … · watch_quota_mb …`;
- `kept mismatch stashes: <n>` with their paths.

Repo mode is set up by the user, never by you: `! <store> project status --cwd <repo>`, then `! <store> project init --cwd <repo>` (writes the declaration, README and `.gitignore`; commits nothing), then adding the repository to `repo_roots` in `/config`. `project copy` is a dry run unless the user adds `--apply`. With `--from repo` it never imports an export that has a HARD secret hit: it prints `skip secret <rel> (rules <ids>)`, counted under `skip` in `TOTAL`.

No content, no transcript reads, no actions.
