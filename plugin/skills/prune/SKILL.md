---
name: prune
description: 'Prune old evidence copies, only when the user asks: list old or big evidence folders of handoffs, then delete them after a yes.'
argument-hint: "[--days N] [--min-mb N] [--root DIR] [--protect DIR]"
---

# Prune


`<store>` = `"${CLAUDE_PLUGIN_ROOT}/scripts/afk-compact-store"`, the plugin's helper. Type it with the quotes, as the first word of the command, never through a variable. If that path starts `/scripts/` or has `${`, the plugin root is `${CLAUDE_SKILL_DIR}/../..`; use that root. If that has `${` too or no helper is there, say so and stop.

The helper is the only way you delete here. Never delete, move or edit a file in the plugin's folders with any other tool. Add the user's arguments to each call when they gave any (for example `--days 30`), except `--apply` and `--plan`.

1. **List.** Run `<store> prune`. It deletes nothing. Say in plain words what it found: per folder its age, size, bucket and the handoff or summary copy it belongs to, then the total it would free; a `(+N smaller folders …)` line's folders are deleted too. Say that handoff files, summary copies, `MANIFEST.tsv`, `ledger.md` and every file a newer handoff cites stay, and that folders marked read-only are only listed. If it printed `nothing to prune`, say so and stop. If it printed `REFUSED: protected-root`, relay its lines as printed (a folder prune would work in touches a protected path from `prune_protected_roots` or `--protect`, so nothing was listed or deleted) and stop: never change that list or the roots yourself.
2. **Ask.** Ask once with the question tool: "Delete the <n> files in the <k> folders listed (<size>)? Handoff files and their manifests stay." Options: "Not now (Recommended)" and "Delete them". No answer or a timeout means no; without the question tool, ask in text and wait for the user's reply.
3. **Delete.** Only after "Delete them" in this run, run the `prune --apply --plan <plan>` line the dry run printed, with the same arguments, and relay its lines as printed. `REFUSED: plan-changed` means the folders changed since the list: run step 1 again and ask again. `REFUSED: protected-root` means the protected list or a root changed since the list: relay it and stop, as in step 1. A `failed: … (inside the protected path …)` line is a file left alone because its folder became part of a protected path during the run.

A pruned copy reads `pruned` in `/afk-compact:resume`'s evidence check, not `missing`.
