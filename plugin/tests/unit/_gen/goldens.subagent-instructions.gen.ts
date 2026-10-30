// GEN by tools/assemble --goldens from tests/fixtures/assembly (runtime.json, expected/).
// Do not edit; edit the assets or runtime.json and run tools/assemble --goldens.
// Goldens of subagent-instructions.txt in render order; goldens.gen.ts gathers every module.
// Each golden is split at the plugin name it was rendered with: join the parts with a name.

export const ROWS: readonly { asset: string; tags: readonly string[]; parts: readonly string[] }[] = [
 {
  "asset": "subagent-instructions",
  "tags": [],
  "parts": [
   "The user's ",
   " plugin asks for this form, not any list above; this subagent resumes cold. As of the last message: last action done, not done or [unverified]; no checked/verified marks; conclusions, not output.\n<summary> starts \u27ea",
   " v1 n=1a2b3c4d s=sub\u27eb; its last line before </summary>: \u27ea/",
   " n=1a2b3c4d\u27eb; in order:\n## Task as assigned: quoted\n## Constraints from the parent: quoted\n## Report: where, how (default text to parent)\n## Done: with proof\n## Findings: exact ids, numbers, paths, incidental too\n## Produced but not yet delivered: verbatim if short, else path\n## Own background tasks: <id> \u00b7 until <wait spec> \u00b7 due \u00b7 output <path>; wait yourself, never end a turn on it. None: none (not checked)\n## Next action: one exact command or edit\nKeep a prior summary's task, constraints, undelivered results as is. These rules aren't the parent's. No secrets, even quoted; say where they live. About 2\u20134K chars.\n"
  ]
 },
 {
  "asset": "subagent-instructions",
  "tags": [
   "fallback"
  ],
  "parts": [
   "Only if this is a subagent's assigned task from a parent agent, use this form instead of the one above; otherwise ignore this part.\nThe user's ",
   " plugin asks for this form, not any list above; this subagent resumes cold. As of the last message: last action done, not done or [unverified]; no checked/verified marks; conclusions, not output.\n<summary> starts \u27ea",
   " v1 n=1a2b3c4d s=sub\u27eb; its last line before </summary>: \u27ea/",
   " n=1a2b3c4d\u27eb; in order:\n## Task as assigned: quoted\n## Constraints from the parent: quoted\n## Report: where, how (default text to parent)\n## Done: with proof\n## Findings: exact ids, numbers, paths, incidental too\n## Produced but not yet delivered: verbatim if short, else path\n## Own background tasks: <id> \u00b7 until <wait spec> \u00b7 due \u00b7 output <path>; wait yourself, never end a turn on it. None: none (not checked)\n## Next action: one exact command or edit\nKeep a prior summary's task, constraints, undelivered results as is. These rules aren't the parent's. No secrets, even quoted; say where they live. About 2\u20134K chars.\n"
  ]
 }
]
