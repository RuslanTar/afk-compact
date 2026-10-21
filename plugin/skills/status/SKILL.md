---
name: status
description: 'Show handoff plugin status: "handoff status", "did compaction save", last compactions, verdicts, saved copies, version check.'
---

# Status

Run `compactinue-store status --sid "${CLAUDE_SESSION_ID}"` (the plugin's helper, on the Bash PATH while the plugin is enabled; if not found: `"${CLAUDE_PLUGIN_ROOT}/bin/compactinue-store"`) and relay its lines as printed:
- effective thresholds, clamped values marked;
- `seat_state` of the last 5 compactions, with trigger, verdict and copy path;
- open escalations and open watcher alerts, with the last 7 days' counts by rule;
- halt state and auto-continues used this hour;
- handoff mode (private, or repo with its export folder and how to accept a repository) and the automatic-relaunch state;
- `smokeDue`, with the user-run line `! compactinue-store smoke`;
- policy flags.

Repo mode is set up by the user, never by you: `! compactinue-store project status --cwd <repo>`, then `! compactinue-store project init --cwd <repo>` (writes the declaration, README and `.gitignore`; commits nothing), then adding the repository to `repo_roots` in `/config`. `project copy` is a dry run unless the user adds `--apply`.

No content, no transcript reads, no actions.
