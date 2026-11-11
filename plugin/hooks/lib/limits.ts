// The usage-limit rule of keep-warm and plugin idle compaction (D-80, owner 2026-11-08 23:31: "I
// think it should be adaptive", "we also may need to look at the session limit (if present)", and
// 23:59: "never fixed. always adaptive"). The idle handoff turn keeps its own rule
// (`idle_handoff_near_limit`, 90%), and so does the shadow trial (shadow.ts).
//
// Each window Claude Code reports is read on its own:
// - a gateway's `spend_limit` (a money cap) stops at 90%;
// - a plan window (`five_hour`, Claude Code's "session" limit, and `seven_day`) stops at 90% too,
//   unless all of these hold, then it runs on up to its cap (98% for `five_hour`, 95% for
//   `seven_day`, whose overrun stops every session of the account for days): an agent, a workflow or
//   a teammate at work is open (its result turn is certain; a background shell alone may never
//   report), the reading is fresh (refreshed in the last 10 minutes: a reading 50 minutes old says
//   nothing of the other sessions on the account), and the share plus the largest of the last five
//   changes the plugin's own compactions made in that window kind (one under a point counts as one:
//   readings are whole points, and one taken before Claude Code refreshed it reads 0), plus one
//   point, stays below the cap (none measured yet: 90%). A window whose reset time has passed has reset: its old reading
//   counts for nothing.
// - any other window stops at 90%.
// Each rule name goes on the row of the skip or stop it decided (`rule`), and (D-83) where each
// window's reading came from and how old it was (`usage_src`, `usage_age_s`).
import type { Deps, Usage } from './deps'
import { usageRecord } from './helper'
import { limitWindows } from './idle'

/** The share every window stops at unless the band rule below lets a plan window go on. */
export const LIMIT_SHARE = 90
/** D-80: the plan windows' caps for the band above LIMIT_SHARE. */
export const PLAN_CAPS: Readonly<Record<string, number>> = { five_hour: 98, seven_day: 95 }
/** D-80: a reading refreshed this recently is fresh. */
export const LIMIT_FRESH_MS = 10 * 60000
/** D-80: the smallest measured compaction change the band counts (a whole point: readings are whole points). */
export const LIMIT_DELTA_FLOOR = 1
/** D-80: the measured compaction changes kept per window kind (the newest). */
export const LIMIT_DELTAS_KEPT = 5
/** The store key of the measured changes: `{ five_hour: number[], seven_day: number[] }`, oldest first. */
export const LIMIT_DELTAS_KEY = 'limit_deltas'
const SPEND = 'spend_limit'

export type Limit = Usage['rateLimits'][number]

/**
 * D-83: where a reading came from: the session's own `$.session.usage()` (`plugin`), this session's
 * status line (`statusline`), or another session on this machine (`peer`), the last two through
 * the shared usage record.
 */
export type Src = 'plugin' | 'statusline' | 'peer'
/** D-83: one window as read, with when (epoch ms; undefined: not known) and where from. */
export type Reading = Limit & { at: number | undefined; src: Src }
/**
 * D-83: what a row that used a reading logs beside its `windows`: each window's source as
 * `kind:source`, in the same order, and its age in whole seconds by kind (none for a window whose
 * time is not known). Content-free.
 */
export type UsageFields = { usage_src: string[]; usage_age_s: Record<string, number> }

/** The session's own windows as readings, read at `at` (`LoadState.usageAt`). */
export function ownReadings(limits: readonly Limit[], at: number | undefined): Reading[] {
  return limits.map(l => ({ ...l, at, src: 'plugin' as const }))
}

/** D-83: the `usage_src` and `usage_age_s` of these readings at `now`. */
export function usageFields(rs: readonly Reading[], now: number): UsageFields {
  const age: Record<string, number> = {}
  for (const r of rs) if (r.at !== undefined) age[r.kind || 'unknown'] = Math.max(0, Math.round((now - r.at) / 1000))
  return { usage_src: rs.map(r => `${r.kind || 'unknown'}:${r.src}`), usage_age_s: age }
}

/** What the band rule reads beside the windows. */
export type LimitCtx = { job: boolean; usageAt: number | undefined; now: number; deltas: Readonly<Record<string, readonly number[]>> }

/**
 * `ok`: nothing stops the action; `band`: a plan window is above 90% and the band rule lets it go
 * on; `rule`: the rule that decided (`band`, `90`, or the first stopping window's: `spend-90`,
 * `other-90`, `cap`, `no-job`, `stale`, `no-delta`, `delta`); `windows`: every window as the row
 * names it (idle.ts `limitWindows`); `usage`: each window's source and age (D-83).
 */
export type Verdict = { ok: boolean; band: boolean; rule: string; windows: string[]; usage: UsageFields }

/** The windows that have not reset by `now` (a past `resetsAt`: the reading is of an ended window). */
export function liveWindows(limits: readonly Limit[], now: number): Limit[] {
  return limits.filter(l => l.resetsAt === undefined || l.resetsAt > now)
}

/** One window's rule: `ok`, `band`, or why it stops. */
export function windowRule(l: Limit, c: LimitCtx): string {
  if (l.kind === SPEND) return l.percentUsed < LIMIT_SHARE ? 'ok' : 'spend-90'
  const cap = PLAN_CAPS[l.kind]
  if (l.percentUsed < LIMIT_SHARE) return 'ok'
  if (cap === undefined) return 'other-90'
  // NaN reads as at the cap.
  if (!(l.percentUsed < cap)) return 'cap'
  if (!c.job) return 'no-job'
  if (c.usageAt === undefined || c.now - c.usageAt > LIMIT_FRESH_MS) return 'stale'
  const ds = c.deltas[l.kind] ?? []
  if (ds.length === 0) return 'no-delta'
  return l.percentUsed + Math.max(LIMIT_DELTA_FLOOR, ...ds) + 1 < cap ? 'band' : 'delta'
}

/** The verdict over every window reported (none: ok, rule `90`). */
export function verdictOf(limits: readonly Limit[], c: LimitCtx): Verdict {
  const windows = limitWindows([...limits])
  const usage = usageFields(ownReadings(limits, c.usageAt), c.now)
  const rules = liveWindows(limits, c.now).map(l => windowRule(l, c))
  const stop = rules.find(r => r !== 'ok' && r !== 'band')
  if (stop !== undefined) return { ok: false, band: false, rule: stop, windows, usage }
  const band = rules.includes('band')
  return { ok: true, band, rule: band ? 'band' : '90', windows, usage }
}

/**
 * The time every window that stops the action, or holds it in the band, resets: when all are plan
 * windows that report a reset after `now` (the latest of them); else undefined.
 */
export function resetOf(limits: readonly Limit[], c: LimitCtx): number | undefined {
  let at: number | undefined
  for (const l of liveWindows(limits, c.now)) {
    if (windowRule(l, c) === 'ok') continue
    if (PLAN_CAPS[l.kind] === undefined || l.resetsAt === undefined) return undefined
    at = Math.max(at ?? 0, l.resetsAt)
  }
  return at
}

/** The measured compaction changes from the store, sanitized (a bad value reads as none). */
export async function readDeltas(d: Deps): Promise<Record<string, number[]>> {
  let v: unknown
  try {
    v = await d.storeGet(LIMIT_DELTAS_KEY)
  } catch {
    return {}
  }
  const out: Record<string, number[]> = {}
  if (typeof v !== 'object' || v === null) return out
  for (const kind of Object.keys(PLAN_CAPS)) {
    const a = (v as Record<string, unknown>)[kind]
    if (Array.isArray(a)) out[kind] = a.filter((x): x is number => typeof x === 'number' && Number.isFinite(x) && x >= 0).slice(-LIMIT_DELTAS_KEPT)
  }
  return out
}

/** The context for a check now: the job flag the caller read, the freshness stamp, the stored changes. */
export async function limitCtx(d: Deps, job: boolean, now: number): Promise<LimitCtx> {
  return { job, usageAt: d.state.usageAt, now, deltas: await readDeltas(d) }
}

/** The shares of the plan windows in a reading, by kind, as a row logs them (`pct_before`, `pct_after`). */
export function planShares(limits: readonly Limit[] | undefined): Record<string, number> {
  const out: Record<string, number> = {}
  for (const l of limits ?? []) if (PLAN_CAPS[l.kind] !== undefined && Number.isFinite(l.percentUsed)) out[l.kind] = l.percentUsed
  return out
}

/**
 * After a plugin compaction: each plan window's change from the reading before it to the one after
 * it, added to the store (the newest LIMIT_DELTAS_KEPT per kind). Only a window read on both sides
 * in the same period (the same reset time, or none on either) that did not go down counts; other
 * sessions only add to a change, which errs on the safe side.
 */
export async function recordDeltas(d: Deps, before: readonly Limit[] | undefined, after: readonly Limit[] | undefined): Promise<void> {
  const add: Record<string, number> = {}
  for (const a of after ?? []) {
    if (PLAN_CAPS[a.kind] === undefined) continue
    const b = (before ?? []).find(x => x.kind === a.kind)
    if (b === undefined || b.resetsAt !== a.resetsAt || !Number.isFinite(b.percentUsed) || !Number.isFinite(a.percentUsed)) continue
    const delta = a.percentUsed - b.percentUsed
    if (delta >= 0) add[a.kind] = Math.round(delta * 10) / 10
  }
  if (Object.keys(add).length === 0) return
  const all = await readDeltas(d)
  for (const [k, v] of Object.entries(add)) all[k] = [...(all[k] ?? []), v].slice(-LIMIT_DELTAS_KEPT)
  try {
    await d.storeSet(LIMIT_DELTAS_KEY, all)
  } catch {
    // not stored: the next compaction measures again
  }
}

/** The plan words for a limit row (D-80), when Claude Code's environment has them. */
export async function tierFields(d: Deps): Promise<{ plan?: string; tier?: string }> {
  try {
    return (await d.planTier?.()) ?? {}
  } catch {
    return {}
  }
}

/**
 * D-83: the session's own reading goes to the shared usage record (helper `usage`, lib/usagerec.pm:
 * one small file per machine, each session's latest reading per window kind and source) when it
 * changed, or once this long after it was last written unchanged, so the other sessions on the
 * machine read it while it is fresh.
 */
export const USAGE_NOTE_MS = 5 * 60000

/** A reading's windows as the record's entries: the share, and the reset in epoch seconds (null: none). */
export function recordWindows(limits: readonly Limit[]): { kind: string; pct: number; resets_at: number | null }[] {
  return limits.filter(l => l.kind !== '' && Number.isFinite(l.percentUsed)).map(l => ({ kind: l.kind, pct: l.percentUsed, resets_at: l.resetsAt === undefined ? null : Math.floor(l.resetsAt / 1000) }))
}

/**
 * D-83: Claude Code refreshed the session's usage reading at `at` (a response, `session.measure`):
 * written to the shared record when it changed or the last write is `USAGE_NOTE_MS` old. A failed
 * read or write writes nothing (the next refresh tries again).
 */
export async function noteUsage(d: Deps, at: number): Promise<void> {
  let w: ReturnType<typeof recordWindows>
  try {
    w = recordWindows((await d.usage()).rateLimits)
  } catch {
    return
  }
  if (w.length === 0) return
  const key = w.map(x => `${x.kind}:${x.pct}:${x.resets_at ?? ''}`).join(',')
  const n = d.state.usageNote
  if (n !== undefined && n.key === key && at - n.at < USAGE_NOTE_MS) return
  d.state.usageNote = { key, at }
  await usageRecord(d, await d.sessionId(), { at: at / 1000, windows: w })
}
