// GEN by tools/assemble --goldens from tests/fixtures/assembly (runtime.json, expected/).
// Do not edit; edit the assets or runtime.json and run tools/assemble --goldens.
// The goldens live in one module per asset (overflow modules past 524288 bytes each: the test
// kit reads no file over 1 MiB). Each golden is split at the plugin name it was rendered
// with: join the parts with a name.

import { ROWS as ROWS_1 } from './goldens.handoff-instructions.gen'
import { ROWS as ROWS_2 } from './goldens.subagent-instructions.gen'
import { ROWS as ROWS_3 } from './goldens.resume-context.gen'
import { ROWS as ROWS_4 } from './goldens.checkpoint-nudge.gen'
import { ROWS as ROWS_5 } from './goldens.handoff-turn.gen'

export const GOLDEN_RUNTIME: Readonly<Record<string, string>> = {
 "draft_state": "present",
 "halt_reason": "the hourly auto-continue limit is reached",
 "handoff_finish": "`\"/p/scripts/afk-compact-store\" publish --stage '~/.claude/handoffs/.staging/5e55a001-h1' --slug retry --status active`",
 "handoff_path": "~/.claude/handoffs/example-repo/LAB-123/2026-10-21_14-00-00_5e55a001_retry.md",
 "idle_min": "49",
 "idle_used_at": "2026-10-21T14:30:00+03:00",
 "lane": "hard-blocked",
 "lane_basis": "2 of 3 listed steps marked done; 0 units running; git: 1 commit not pushed, 2 files changed",
 "lane_why": "the summary's Status line",
 "max_calls": "34",
 "measured_at": "2026-10-21T14:05:00+03:00",
 "measured_facts": "Git: feature/LAB-123-retry @ 3f9c2e1, 2 modified, 0 untracked, ahead 1\nGSD: phase 2 of 4, plan 2.3 in progress (checked 2026-10-21 14:05 +0300)",
 "nonce": "1a2b3c4d",
 "previous_copy": "~/.claude/handoffs/example-repo/LAB-123/compact/2026-10-21_12-30-00_5e55a001_c1-5ca1ab.md",
 "queue_add": "\"/p/scripts/afk-compact-store\" queue-add --sid 5e55a001-0c0f-4f1e-9a00-00000000a001 --nonce 1a2b3c4d",
 "remeasure": "Git: feature/LAB-123-retry @ 3f9c2e1, 2 modified, 0 untracked, ahead 1\nIn flight: none listed\nEvidence: none",
 "saved_copy": "~/.claude/handoffs/example-repo/LAB-123/compact/2026-10-21_14-05-12_5e55a001_c2-1a2b3c.md",
 "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
 "store": "\"/p/scripts/afk-compact-store\"",
 "tokens": "612,345"
}

export type Golden = { asset: string; tags: readonly string[]; parts: readonly string[] }

export const GOLDENS: readonly Golden[] = [...ROWS_1, ...ROWS_2, ...ROWS_3, ...ROWS_4, ...ROWS_5]

export const GOLDEN_COUNT = 324
