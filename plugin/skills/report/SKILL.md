---
name: report
description: 'Only when the user asks for a report: zip the plugin''s content-free logs, version, settings and probe results for the developer. Nothing is uploaded.'
argument-hint: "[--since 7d]"
---

# Report


`<store>` = `"${CLAUDE_PLUGIN_ROOT}/scripts/afk-compact-store"`, the plugin's helper. Type it with the quotes, as the first word of the command, never through a variable.

Three steps; add the user's arguments to each call when they gave any (for example `--since 7d`).

1. Run `<store> report --dry-run` and relay its lines exactly as printed. It writes nothing.
2. If it printed `summaries: <n> available` with n above 0, ask once with the question tool: "Add <n> compaction summaries to this report? They hold your sessions' text. Secrets and your names, paths and hosts are scanned and any file with a hit is left out, but business content is not masked." Options: "No, logs only (Recommended)" and "Yes, add them". No answer or a timeout means no.
3. Run `<store> report`, or `<store> report --with-summaries` after a yes in step 2, and relay its lines exactly as printed. Never pass `--with-summaries` without a yes in this run.

Do not read, open or summarise any log or the zip. Do not run the REVEAL or COPY lines. If the output has `smokeDue`, say first that the user may run the `! … smoke` line that `/afk-compact:status` prints, and then the report again. If the helper is missing, print the README path of the plugin and stop.
