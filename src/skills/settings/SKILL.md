---
name: settings
description: 'Plugin settings, only when the user asks: go through each section with current values and defaults, then change or reset keys.'
argument-hint: "[advanced | all]"
---

# Settings
<!-- 0.1.2 onboarding and the settings writer (owner 2026-10-30, "helper writer, safe keys"): the helper writes the plugin's options in the user's settings file for every key but the six consent keys, which it refuses on every path. No disable-model-invocation and no allowed-tools until PR-2 row P-156 is reviewed; the description says "only when the user asks" instead. -->

`<store>` = `"${CLAUDE_PLUGIN_ROOT}/scripts/{{plugin}}-store"`, the plugin's helper. Type it with the quotes, as the first word of the command, never through a variable. If that path starts `/scripts/` or has `${`, the plugin root is `${CLAUDE_SKILL_DIR}/../..`; use that root. If that has `${` too or no helper is there, say so and stop. <!-- CW-1 (Cowork check 2026-10-26), as in the status skill -->

The helper is the only way you change these settings. Never edit, write or read the settings file with any other tool, and never write a default yourself: setting a key to its default removes it.

1. **Load.** Run `<store> settings show --json --tier common` (`--tier advanced` when the user's argument is `advanced`, `--tier all` for `all`). It prints one JSON object: `sections` (each with its `title` and `keys`), `settings` (per key: `title`, `kind`, `default`, `min`, `max`, `values`, `value`, `source`, `clamped`, `class`), `config_key`, `write_refused` and `notes`.
2. **Show.** One short table per section: key, value, where it comes from (`source`), default. A `consent` key is shown as read-only. If `write_refused` is set, say why, say the settings can be changed in `/config`, and stop after the tables.
3. **Ask.** Per section, ask with the question tool whether to change anything there ("Keep all (Recommended)" or "Change some"); then, for each key the user names, ask its new value: the `values` of an enum key or true/false as options, plus "Default (<default>)"; a number, path or list in the free answer, with its `min` and `max`. A protective key (`class` `protective`) only gains entries: offer to add, never to drop one. Without the question tool, ask in numbered text. Collect every answer first.
4. **Dry run.** Run `<store> settings set '<key>=<value>' …` once with every change, each word in single quotes; `'<key>='` (empty) puts a key back to its default. Relay its lines as printed: each change as old -> new, and any `note:` (a number the clamp lowers is still written as given). If it refuses a value, relay the reason and ask again for that key only.
5. **Apply.** Ask once with the question tool: "Apply these changes to your settings file?" ("Apply" or "Not now"). Only after "Apply" run the same command with the `--plan <hash> --apply` the dry run printed, and relay its lines as printed, the backup path included. A refusal writes nothing: relay it and stop.
6. **Consent keys** (`repo_roots`, `relaunch_auto`, `relaunch_allow`, `unattended_prod_reads`, `queue_cmd`, `restart_on_update`): the helper never writes them, whoever asks. For one the user wants changed, run `<store> settings set '<key>=<value>'` without `--apply`: it refuses and prints the ways the user changes it, `/config` and a `! … claude plugin configure …` line. Relay those lines; never run the `!` line yourself.
7. **Reset.** To put keys back to their defaults: `<store> settings reset <key>…` (or `--all`, which keeps the consent and protective keys) as a dry run, relay it, ask as in step 5, then run the apply line it printed.

End with: the changes apply in a new session or after `/reload-plugins`, and `/{{plugin}}:status` lists every value the plugin uses.
