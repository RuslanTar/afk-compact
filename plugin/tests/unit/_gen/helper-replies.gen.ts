// GEN by tools/helper-replies-gen from real helper runs (BT-05). Do not edit; run the tool.
// Strings are kept in parts split at the plugin name: join the parts with a name.
// $PLUGIN stands for the plugin folder, $TMP for the run's temp dir and ~ for its HOME.

export type RecordedReply = { name: string; argv: readonly (readonly string[])[]; exitCode: number; stdout: readonly string[]; stdin?: readonly string[] }

export const REPLY_SID = "5e55a001-0c0f-4f1e-9a00-00000000a001"
export const REPLY_NONCE = "1a2b3c4d"

/** Files the calls read, by recorded path (parts split at the name). */
export const REPLY_INPUTS: Readonly<Record<string, readonly string[]>> = {
 "$TMP/summary.txt": [
  "<summary>\n\u27ea",
  " v1 n=1a2b3c4d s=main\u27eb\n# LAB-42 \u2014 retry in progress\n## Resume here\nStatus: active\n\u27ea/",
  " n=1a2b3c4d\u27eb\n</summary>\n"
 ]
}

export const HELPER_REPLIES: readonly RecordedReply[] = [
 {
  "name": "ident",
  "argv": [
   [
    "ident"
   ],
   [
    "--sid"
   ],
   [
    "5e55a001-0c0f-4f1e-9a00-00000000a001"
   ]
  ],
  "exitCode": 0,
  "stdout": [
   "{\"pid\":424242,\"pid_lstart\":\"Tue Oct 21 09:00:00 2026\",\"execpath_version\":null,\"watch\":\"~/.local/state/",
   "/handoffs/.watch\",\"restart\":\"off\",\"restart_reports\":[]}\n"
  ]
 },
 {
  "name": "prev-copy-none",
  "argv": [
   [
    "prev-copy"
   ],
   [
    "--sid"
   ],
   [
    "5e55a001-0c0f-4f1e-9a00-00000000a001"
   ],
   [
    "--actor"
   ],
   [
    "main"
   ]
  ],
  "exitCode": 0,
  "stdout": [
   "none\n"
  ]
 },
 {
  "name": "dispatch-ok",
  "argv": [
   [
    "dispatch"
   ],
   [
    "--sid"
   ],
   [
    "5e55a001-0c0f-4f1e-9a00-00000000a001"
   ],
   [
    "--nonce"
   ],
   [
    "1a2b3c4d"
   ],
   [
    "--actor"
   ],
   [
    "main"
   ],
   [
    "--trigger"
   ],
   [
    "auto"
   ],
   [
    "--channel"
   ],
   [
    "mod-hook"
   ],
   [
    "--resume-pref"
   ],
   [
    "prompt.context"
   ],
   [
    "--tags"
   ],
   [
    "midturn"
   ],
   [
    "--midturn"
   ],
   [
    "true"
   ],
   [
    "--instr-sha8"
   ],
   [
    "9f2c01ab"
   ],
   [
    "--instr-bytes"
   ],
   [
    "3994"
   ],
   [
    "--cc-version"
   ],
   [
    "2.1.306"
   ],
   [
    "--load-id"
   ],
   [
    "l0ad0001"
   ]
  ],
  "exitCode": 0,
  "stdout": [
   "ok\n"
  ]
 },
 {
  "name": "dispatch-exists",
  "argv": [
   [
    "dispatch"
   ],
   [
    "--sid"
   ],
   [
    "5e55a001-0c0f-4f1e-9a00-00000000a001"
   ],
   [
    "--nonce"
   ],
   [
    "1a2b3c4d"
   ],
   [
    "--actor"
   ],
   [
    "main"
   ],
   [
    "--trigger"
   ],
   [
    "auto"
   ],
   [
    "--channel"
   ],
   [
    "mod-hook"
   ],
   [
    "--resume-pref"
   ],
   [
    "prompt.context"
   ],
   [
    "--tags"
   ],
   [
    "midturn"
   ],
   [
    "--midturn"
   ],
   [
    "true"
   ],
   [
    "--instr-sha8"
   ],
   [
    "9f2c01ab"
   ],
   [
    "--instr-bytes"
   ],
   [
    "3994"
   ],
   [
    "--cc-version"
   ],
   [
    "2.1.306"
   ],
   [
    "--load-id"
   ],
   [
    "l0ad0001"
   ]
  ],
  "exitCode": 3,
  "stdout": [
   "REFUSED: nonce-exists\n"
  ]
 },
 {
  "name": "checkpoint",
  "argv": [
   [
    "checkpoint"
   ],
   [
    "--sid"
   ],
   [
    "5e55a001-0c0f-4f1e-9a00-00000000a001"
   ],
   [
    "--nonce"
   ],
   [
    "1a2b3c4d"
   ],
   [
    "--budget-ms"
   ],
   [
    "10000"
   ]
  ],
  "exitCode": 0,
  "stdout": [
   "{\"checkpoint_ms\":{\"inventory\":0,\"git\":0,\"gsd\":0,\"lane\":0,\"evidence\":0,\"total\":0},\"consent\":{\"unattended_prod_reads\":\"forbid\"},\"evidence_map\":[],\"git\":\"not-git\",\"gsd\":[],\"inventory\":[],\"lane\":null,\"measured_block\":null,\"queued_line\":null,\"timeouts\":[]}\n"
  ]
 },
 {
  "name": "save-copy-saved",
  "argv": [
   [
    "save-copy"
   ],
   [
    "--sid"
   ],
   [
    "5e55a001-0c0f-4f1e-9a00-00000000a001"
   ],
   [
    "--nonce"
   ],
   [
    "1a2b3c4d"
   ],
   [
    "--from"
   ],
   [
    "$TMP/summary.txt"
   ],
   [
    "--writer"
   ],
   [
    "mod"
   ],
   [
    "--scope"
   ],
   [
    "main"
   ],
   [
    "--tokens"
   ],
   [
    "612345,41000"
   ]
  ],
  "exitCode": 0,
  "stdout": [
   "VERDICT ok marker_line=1 sentinel_from_end=1\nSaved copy: ~/.local/state/",
   "/handoffs/work/general/compact/2026-10-21_14-05-12_5e55a001_c1-1a2b3c.md\n"
  ]
 },
 {
  "name": "save-copy-exists",
  "argv": [
   [
    "save-copy"
   ],
   [
    "--sid"
   ],
   [
    "5e55a001-0c0f-4f1e-9a00-00000000a001"
   ],
   [
    "--nonce"
   ],
   [
    "1a2b3c4d"
   ],
   [
    "--from"
   ],
   [
    "$TMP/summary.txt"
   ],
   [
    "--writer"
   ],
   [
    "mod"
   ],
   [
    "--scope"
   ],
   [
    "main"
   ],
   [
    "--tokens"
   ],
   [
    "612345,41000"
   ]
  ],
  "exitCode": 0,
  "stdout": [
   "VERDICT ok marker_line=1 sentinel_from_end=1\nEXISTS: ~/.local/state/",
   "/handoffs/work/general/compact/2026-10-21_14-05-12_5e55a001_c1-1a2b3c.md sha-match\n"
  ]
 },
 {
  "name": "prev-copy-path",
  "argv": [
   [
    "prev-copy"
   ],
   [
    "--sid"
   ],
   [
    "5e55a001-0c0f-4f1e-9a00-00000000a001"
   ],
   [
    "--actor"
   ],
   [
    "main"
   ]
  ],
  "exitCode": 0,
  "stdout": [
   "~/.local/state/",
   "/handoffs/work/general/compact/2026-10-21_14-05-12_5e55a001_c1-1a2b3c.md\n"
  ]
 },
 {
  "name": "sweep",
  "argv": [
   [
    "sweep"
   ],
   [
    "--sid"
   ],
   [
    "5e55a001-0c0f-4f1e-9a00-00000000a001"
   ],
   [
    "--nonce"
   ],
   [
    "1a2b3c4d"
   ]
  ],
  "exitCode": 0,
  "stdout": [
   "TOTAL copied=0 dup=0 ref_only=0 redacted=0 withheld=0 referenced_budget=0\n"
  ]
 },
 {
  "name": "claim-claimed",
  "argv": [
   [
    "claim"
   ],
   [
    "--sid"
   ],
   [
    "5e55a001-0c0f-4f1e-9a00-00000000a001"
   ],
   [
    "--nonce"
   ],
   [
    "1a2b3c4d"
   ],
   [
    "--channel"
   ],
   [
    "prompt.context"
   ]
  ],
  "exitCode": 0,
  "stdout": [
   "CLAIMED\n"
  ]
 },
 {
  "name": "claim-taken",
  "argv": [
   [
    "claim"
   ],
   [
    "--sid"
   ],
   [
    "5e55a001-0c0f-4f1e-9a00-00000000a001"
   ],
   [
    "--nonce"
   ],
   [
    "1a2b3c4d"
   ],
   [
    "--channel"
   ],
   [
    "prompt.submit"
   ]
  ],
  "exitCode": 0,
  "stdout": [
   "TAKEN prompt.context\n"
  ]
 },
 {
  "name": "measure",
  "argv": [
   [
    "measure"
   ],
   [
    "--sid"
   ],
   [
    "5e55a001-0c0f-4f1e-9a00-00000000a001"
   ],
   [
    "--compact"
   ]
  ],
  "exitCode": 0,
  "stdout": [
   "git: not a repository\nIn flight: not listed (no sidecar yet)\n"
  ]
 },
 {
  "name": "log",
  "argv": [
   [
    "log"
   ],
   [
    "--sid"
   ],
   [
    "5e55a001-0c0f-4f1e-9a00-00000000a001"
   ],
   [
    "--json"
   ],
   [
    "{\"v\":1,\"ev\":\"nudge\",\"sid\":\"5e55a001-0c0f-4f1e-9a00-00000000a001\",\"actor\":\"main\",\"writer\":\"mod\"}"
   ]
  ],
  "exitCode": 0,
  "stdout": [
   ""
  ]
 },
 {
  "name": "log-paths",
  "argv": [
   [
    "log"
   ],
   [
    "--sid"
   ],
   [
    "5e55a001-0c0f-4f1e-9a00-00000000a001"
   ],
   [
    "--stream"
   ],
   [
    "paths"
   ],
   [
    "--json"
   ],
   [
    "{\"v\":1,\"ev\":\"temp_path\",\"path\":\"$TMP/out.log\"}"
   ]
  ],
  "exitCode": 0,
  "stdout": [
   ""
  ]
 },
 {
  "name": "handoff-turn-open",
  "argv": [
   [
    "handoff-turn"
   ],
   [
    "open"
   ],
   [
    "--sid"
   ],
   [
    "5e55a001-0c0f-4f1e-9a00-00000000a001"
   ],
   [
    "--ht"
   ],
   [
    "0a0b0c01"
   ],
   [
    "--reason"
   ],
   [
    "cap"
   ],
   [
    "--max-calls"
   ],
   [
    "34"
   ],
   [
    "--max-tokens"
   ],
   [
    "64000"
   ]
  ],
  "exitCode": 0,
  "stdout": [
   "ok\n"
  ]
 },
 {
  "name": "handoff-turn-open-exists",
  "argv": [
   [
    "handoff-turn"
   ],
   [
    "open"
   ],
   [
    "--sid"
   ],
   [
    "5e55a001-0c0f-4f1e-9a00-00000000a001"
   ],
   [
    "--ht"
   ],
   [
    "0a0b0c01"
   ],
   [
    "--reason"
   ],
   [
    "cap"
   ],
   [
    "--max-calls"
   ],
   [
    "34"
   ],
   [
    "--max-tokens"
   ],
   [
    "64000"
   ]
  ],
  "exitCode": 0,
  "stdout": [
   "EXISTS\n"
  ]
 },
 {
  "name": "handoff-turn-supersede",
  "argv": [
   [
    "handoff-turn"
   ],
   [
    "supersede"
   ],
   [
    "--sid"
   ],
   [
    "5e55a001-0c0f-4f1e-9a00-00000000a001"
   ],
   [
    "--ht"
   ],
   [
    "0a0b0c01"
   ],
   [
    "--nonce"
   ],
   [
    "1a2b3c4d"
   ]
  ],
  "exitCode": 0,
  "stdout": [
   "ok\n"
  ]
 },
 {
  "name": "handoff-turn-supersede-exists",
  "argv": [
   [
    "handoff-turn"
   ],
   [
    "supersede"
   ],
   [
    "--sid"
   ],
   [
    "5e55a001-0c0f-4f1e-9a00-00000000a001"
   ],
   [
    "--ht"
   ],
   [
    "0a0b0c01"
   ],
   [
    "--nonce"
   ],
   [
    "1a2b3c4d"
   ]
  ],
  "exitCode": 0,
  "stdout": [
   "EXISTS\n"
  ]
 },
 {
  "name": "handoff-turn-supersede-no-ht",
  "argv": [
   [
    "handoff-turn"
   ],
   [
    "supersede"
   ],
   [
    "--sid"
   ],
   [
    "5e55a001-0c0f-4f1e-9a00-00000000a001"
   ],
   [
    "--ht"
   ],
   [
    "0a0b0c09"
   ],
   [
    "--nonce"
   ],
   [
    "1a2b3c4d"
   ]
  ],
  "exitCode": 3,
  "stdout": [
   "REFUSED: no-ht\n"
  ]
 },
 {
  "name": "handoff-state-none",
  "argv": [
   [
    "handoff-state"
   ],
   [
    "--sid"
   ],
   [
    "5e55a001-0c0f-4f1e-9a00-00000000a001"
   ],
   [
    "--ht"
   ],
   [
    "0a0b0c02"
   ]
  ],
  "exitCode": 0,
  "stdout": [
   "none\n"
  ]
 },
 {
  "name": "handoff-state-staged",
  "argv": [
   [
    "handoff-state"
   ],
   [
    "--sid"
   ],
   [
    "5e55a001-0c0f-4f1e-9a00-00000000a001"
   ],
   [
    "--ht"
   ],
   [
    "0a0b0c03"
   ]
  ],
  "exitCode": 0,
  "stdout": [
   "staged ~/.local/state/",
   "/handoffs/repo/LAB-42/.staging/5e55a001-0a0b0c03 draft=1 finish=<store> publish --stage '~/.local/state/",
   "/handoffs/repo/LAB-42/.staging/5e55a001-0a0b0c03' --slug lab-42 --status in-progress\n"
  ]
 },
 {
  "name": "handoff-state-staged-no-finish",
  "argv": [
   [
    "handoff-state"
   ],
   [
    "--sid"
   ],
   [
    "5e55a001-0c0f-4f1e-9a00-00000000a001"
   ],
   [
    "--ht"
   ],
   [
    "0a0b0c04"
   ]
  ],
  "exitCode": 0,
  "stdout": [
   "staged ~/.local/state/",
   "/handoffs/repo/LAB-42/.staging/it's-0a0b0c04 draft=0 finish=none\n"
  ]
 },
 {
  "name": "handoff-state-published",
  "argv": [
   [
    "handoff-state"
   ],
   [
    "--sid"
   ],
   [
    "5e55a001-0c0f-4f1e-9a00-00000000a001"
   ],
   [
    "--ht"
   ],
   [
    "0a0b0c05"
   ]
  ],
  "exitCode": 0,
  "stdout": [
   "published ~/.local/state/",
   "/handoffs/repo/LAB-42/2026-10-21_14-05-12_5e55a001_retry.md\n"
  ]
 },
 {
  "name": "handoff-state-publish-failed",
  "argv": [
   [
    "handoff-state"
   ],
   [
    "--sid"
   ],
   [
    "5e55a001-0c0f-4f1e-9a00-00000000a001"
   ],
   [
    "--ht"
   ],
   [
    "0a0b0c06"
   ]
  ],
  "exitCode": 0,
  "stdout": [
   "publish-failed ~/.local/state/",
   "/handoffs/repo/LAB-42/2026-10-21_14-05-12_5e55a001_retry-2.md\n"
  ]
 },
 {
  "name": "handoff-state-superseded",
  "argv": [
   [
    "handoff-state"
   ],
   [
    "--sid"
   ],
   [
    "5e55a001-0c0f-4f1e-9a00-00000000a001"
   ],
   [
    "--ht"
   ],
   [
    "0a0b0c01"
   ]
  ],
  "exitCode": 0,
  "stdout": [
   "superseded 1a2b3c4d\n"
  ]
 },
 {
  "name": "log-jobs-caller",
  "argv": [
   [
    "log"
   ],
   [
    "--sid"
   ],
   [
    "5e55a001-0c0f-4f1e-9a00-00000000a001"
   ],
   [
    "--stream"
   ],
   [
    "jobs"
   ],
   [
    "--stdin"
   ]
  ],
  "exitCode": 3,
  "stdout": [
   "REFUSED: jobs-caller\n"
  ],
  "stdin": [
   "{\"kind\":\"job\",\"task_id\":\"b1x2y3\",\"command\":\"rg -n retry src\",\"cwd\":\"$TMP/work\",\"is_read_only\":true,\"backgrounded\":\"flag\"}\n"
  ]
 },
 {
  "name": "dispatch-handoff-ht",
  "argv": [
   [
    "dispatch"
   ],
   [
    "--sid"
   ],
   [
    "5e55a001-0c0f-4f1e-9a00-00000000a001"
   ],
   [
    "--nonce"
   ],
   [
    "2b3c4d5e"
   ],
   [
    "--actor"
   ],
   [
    "main"
   ],
   [
    "--trigger"
   ],
   [
    "auto"
   ],
   [
    "--channel"
   ],
   [
    "mod-hook"
   ],
   [
    "--resume-pref"
   ],
   [
    "prompt.context"
   ],
   [
    "--tags"
   ],
   [
    "midturn"
   ],
   [
    "--midturn"
   ],
   [
    "true"
   ],
   [
    "--instr-sha8"
   ],
   [
    "9f2c01ab"
   ],
   [
    "--instr-bytes"
   ],
   [
    "3994"
   ],
   [
    "--cc-version"
   ],
   [
    "2.1.306"
   ],
   [
    "--load-id"
   ],
   [
    "l0ad0001"
   ],
   [
    "--handoff-ht"
   ],
   [
    "0a0b0c01"
   ]
  ],
  "exitCode": 0,
  "stdout": [
   "ok\n"
  ]
 },
 {
  "name": "trial-measure-absent",
  "argv": [
   [
    "trial-measure"
   ],
   [
    "--sid"
   ],
   [
    "5e55a001-0c0f-4f1e-9a00-00000000a001"
   ],
   [
    "--budget-ms"
   ],
   [
    "7500"
   ],
   [
    "--cc-version"
   ],
   [
    "2.1.306"
   ]
  ],
  "exitCode": 0,
  "stdout": [
   "{\"state\":\"absent\",\"why\":null}\n"
  ]
 },
 {
  "name": "trial-save-absent",
  "argv": [
   [
    "trial-save"
   ],
   [
    "--sid"
   ],
   [
    "5e55a001-0c0f-4f1e-9a00-00000000a001"
   ]
  ],
  "exitCode": 0,
  "stdout": [
   "{\"why\":\"absent\",\"written\":false}\n"
  ],
  "stdin": [
   "{\"kind\":\"skip\",\"moment_id\":\"5e55a001-1a2b3c4d\",\"moment\":{\"kind\":\"m3-auto\",\"status\":\"skipped:cold\"}}\n"
  ]
 },
 {
  "name": "restart-gate-off",
  "argv": [
   [
    "restart"
   ],
   [
    "gate"
   ],
   [
    "--sid"
   ],
   [
    "5e55a001-0c0f-4f1e-9a00-00000000a001"
   ],
   [
    "--route"
   ],
   [
    "fg"
   ],
   [
    "--from"
   ],
   [
    "2.1.311"
   ],
   [
    "--to"
   ],
   [
    "2.1.312"
   ],
   [
    "--model"
   ],
   [
    ""
   ],
   [
    "--seen-mode"
   ],
   [
    "default"
   ],
   [
    "--seen-at"
   ],
   [
    "1792580712000"
   ],
   [
    "--turn-at"
   ],
   [
    "1792580700000"
   ],
   [
    "--now-ms"
   ],
   [
    "1792580712000"
   ]
  ],
  "exitCode": 0,
  "stdout": [
   "{\"ok\":false,\"why\":\"off\",\"setting\":\"off\",\"route\":\"fg\",\"mode\":null,\"effort\":null,\"job_short\":null,\"token\":null,\"types\":[],\"items\":[],\"launcher\":null}\n"
  ]
 },
 {
  "name": "restart-claim-none",
  "argv": [
   [
    "restart"
   ],
   [
    "claim"
   ],
   [
    "--sid"
   ],
   [
    "5e55a001-0c0f-4f1e-9a00-00000000a001"
   ],
   [
    "--load-id"
   ],
   [
    "l0ad0001"
   ],
   [
    "--now-ms"
   ],
   [
    "1792580712000"
   ]
  ],
  "exitCode": 0,
  "stdout": [
   "{\"claimed\":false,\"why\":\"none\",\"route\":null,\"from\":null,\"to\":null,\"continue\":false,\"nonce\":null,\"at\":null,\"refused\":[]}\n"
  ]
 },
 {
  "name": "restart-set-absent",
  "argv": [
   [
    "restart"
   ],
   [
    "set"
   ],
   [
    "--sid"
   ],
   [
    "5e55a001-0c0f-4f1e-9a00-00000000a001"
   ],
   [
    "--nonce"
   ],
   [
    "0123456789abcdef"
   ],
   [
    "--state"
   ],
   [
    "cancelled"
   ],
   [
    "--now-ms"
   ],
   [
    "1792580712000"
   ]
  ],
  "exitCode": 0,
  "stdout": [
   "{\"ok\":true,\"l\":\"absent\",\"c\":\"absent\",\"why\":null}\n"
  ]
 },
 {
  "name": "restart-respawn-cancel-none",
  "argv": [
   [
    "restart"
   ],
   [
    "respawn-cancel"
   ],
   [
    "--sid"
   ],
   [
    "5e55a001-0c0f-4f1e-9a00-00000000a001"
   ],
   [
    "--nonce"
   ],
   [
    "0123456789abcdef"
   ]
  ],
  "exitCode": 0,
  "stdout": [
   "{\"ok\":true,\"killed\":false,\"note\":false}\n"
  ]
 }
]
