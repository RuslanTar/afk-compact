---
name: report
description: 'Only when the user asks for a report: zip the plugin''s content-free logs, version, settings and probe results for the developer. Nothing is uploaded.'
argument-hint: "[--since 7d]"
---

# Report
<!-- W-BETA C (CROSS-REVIEW XR-04, XR-21): no disable-model-invocation and no allowed-tools until PR-2 row P-156 is reviewed; the description says "Only when the user asks" instead. -->

`<store>` = `"${CLAUDE_PLUGIN_ROOT}/scripts/{{plugin}}-store"`, the plugin's helper. Type it with the quotes, as the first word of the command, never through a variable.

Run `<store> report` once, adding the user's arguments when they gave any (for example `--since 7d`), and relay its lines exactly as printed. Do not read, open or summarise any log or the zip. Do not run the REVEAL or COPY lines. If the output has `smokeDue`, say first that the user may run the `! … smoke` line that `/{{plugin}}:status` prints, and then the report again. If the helper is missing, print the README path of the plugin and stop.
