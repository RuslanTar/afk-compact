// GEN by tools/helper-replies-gen from real helper runs (BT-05). Do not edit; run the tool.
// Strings are kept in parts split at the plugin name: join the parts with a name.
// $TMP stands for the run's temp dir and ~ for its HOME.

export type RecordedReply = { name: string; argv: readonly (readonly string[])[]; exitCode: number; stdout: readonly string[] }

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
   "{\"pid\":424242,\"pid_lstart\":\"Tue Oct 21 09:00:00 2026\",\"execpath_version\":null,\"watch\":\"~/.claude/handoffs/.watch\"}\n"
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
   "{\"checkpoint_ms\":{\"inventory\":0,\"git\":0,\"gsd\":0,\"lane\":0,\"evidence\":0,\"total\":0},\"evidence_map\":[],\"git\":\"not-git\",\"gsd\":[],\"inventory\":[],\"lane\":null,\"measured_block\":null,\"queued_line\":null,\"timeouts\":[]}\n"
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
   "VERDICT ok marker_line=1 sentinel_from_end=1\nSaved copy: ~/.claude/handoffs/work/general/compact/2026-10-21_14-05-12_5e55a001_c1-1a2b3c.md\n"
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
   "VERDICT ok marker_line=1 sentinel_from_end=1\nEXISTS: ~/.claude/handoffs/work/general/compact/2026-10-21_14-05-12_5e55a001_c1-1a2b3c.md sha-match\n"
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
   "~/.claude/handoffs/work/general/compact/2026-10-21_14-05-12_5e55a001_c1-1a2b3c.md\n"
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
 }
]
