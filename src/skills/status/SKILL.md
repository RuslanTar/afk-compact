---
name: status
description: 'Show handoff plugin status: "handoff status", "did compaction save", last compactions, verdicts, saved copies, version check.'
---

# Status

`<store>` = `"${CLAUDE_PLUGIN_ROOT}/scripts/{{plugin}}-store"`, the plugin's helper. Type it with the quotes, as the first word of the command, never through a variable.

Run `<store> status --sid "${CLAUDE_SESSION_ID}"` and relay its lines as printed:
- effective thresholds, clamped values marked;
- `seat_state` of the last 5 compactions, with trigger, verdict and copy path;
- open escalations and open watcher alerts, with the last 7 days' counts by rule;
- halt state and auto-continues used this hour;
- handoff mode (private, or repo with its export folder and how to accept a repository) and the automatic-relaunch state;
- `smokeDue`, with the user-run line `! <store> smoke`;
- policy flags.

Repo mode is set up by the user, never by you: `! <store> project status --cwd <repo>`, then `! <store> project init --cwd <repo>` (writes the declaration, README and `.gitignore`; commits nothing), then adding the repository to `repo_roots` in `/config`. `project copy` is a dry run unless the user adds `--apply`. With `--from repo` it never imports an export that has a HARD secret hit: it prints `skip secret <rel> (rules <ids>)`, counted under `skip` in `TOTAL`.

No content, no transcript reads, no actions.
