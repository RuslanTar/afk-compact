---
name: report
description: 'Only when the user asks for a report: zip the plugin''s content-free logs, version, settings and probe results for the developer. Nothing is uploaded.'
argument-hint: "[--since 7d]"
---

# Report
<!-- W-BETA C (CROSS-REVIEW XR-04, XR-21): no disable-model-invocation and no allowed-tools until PR-2 row P-156 is reviewed; the description says "Only when the user asks" instead. -->

`<store>` = `"${CLAUDE_PLUGIN_ROOT}/scripts/{{plugin}}-store"`, the plugin's helper. Type it with the quotes, as the first word of the command, never through a variable. If that path starts `/scripts/` or has `${`, the plugin root is `${CLAUDE_SKILL_DIR}/../..` (if that has `${` too: two folders above this skill's base directory); use that root. <!-- CW-1 (Cowork check 2026-10-26). CW-1 review: `${CLAUDE_SKILL_DIR}` is the documented substitution for a skill's own folder (Claude Code changelog); the base-directory line is the second fallback -->

Three steps; add the user's arguments to each call when they gave any (for example `--since 7d`). <!-- RS-1 (owner xxxxxxxx-19: summaries opt-in per report, asked each time) -->

1. Run `<store> report --dry-run` and relay its lines exactly as printed. It writes nothing.
2. If it printed `summaries: <n> available` or `handoffs: <m> available` with a count above 0, ask once with the question tool, one question per such kind in the same dialog, each its own yes: "Add <n> compaction summaries to this report?" and "Add <m> published handoffs to this report?", each followed by "They hold your sessions' text. Secrets and your names, paths and hosts are scanned and any file with a hit is left out, but business content is not masked." Options for each: "No, logs only (Recommended)" and "Yes, add them". No answer or a timeout means no. <!-- RS-5 (owner xxxxxxxx-33: also handoffs, a second, separate yes) -->
3. Run `<store> report`, adding `--with-summaries` after a yes to summaries and `--with-handoffs` after a yes to handoffs (`<store> report --with-summaries --with-handoffs` after both), and relay its lines exactly as printed. Never pass `--with-summaries` or `--with-handoffs` without its own yes in this run.

Do not read, open or summarise any log or the zip. Do not run the REVEAL or COPY lines. If the output has `smokeDue`, say first that the user may run the `! … smoke` line that `/{{plugin}}:status` prints, and then the report again. If the helper is missing, print the README path of the plugin and stop.
