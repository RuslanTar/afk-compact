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
// D-83 (owner U-60: "what can be more important than creating a handoff and compacting? reading cold
// cache seems to be more expensive"): a wrong skip lets a large session go cold (its whole cache
// written again), a wrong run costs one ping or one compaction, so every near-limit decision (this
// rule, keep-warm's wait, the idle handoff turn's `idle_handoff_near_limit`) reads all the readings
// it has of each window kind: the session's own, its status line's and the other sessions' on this
// machine (the shared usage record, helper `usage`; Claude Code fills the first two from one
// in-process reading, so only another session's is independent: one reading per session counts,
// its newest), and only those refreshed in the last 10 minutes. A status line gets that reading
// without its time: the record dates it from when a status line first showed it, and it never
// counts as newer than that session's own refresh (this session: its live reading, `usageAt`;
// another: its `plugin` entry of that kind; none: no reading). A window kind stops the action
// only when every fresh reading of it does; one that does not lets it run (`split`); with no fresh
// reading of a kind, it never stops (`no-fresh`: an old reading may be another account's, or
// before a reset). A fresh reading whose reset is more than an hour from the other readings' of
// its kind (under a proxy that routes requests across accounts, or around a compaction, the
// reading is the last response's account) is still a reading, logged as an anomaly.
// Each rule name goes on the row of the skip or stop it decided, or of the action an old or
// disputed reading did not stop (`rule`), with where each window's reading came from, how old it
// was, how many fresh readings of it there were and which were anomalies (`usage_src`,
// `usage_age_s`, `usage_n`, `usage_anomaly`).
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
/**
 * D-83: one window as read, with when (epoch ms; undefined: not known), where from, and for a
 * peer's the first 8 characters of its session id.
 */
export type Reading = Limit & { at: number | undefined; src: Src; sid8?: string }
/**
 * D-83: what a row that used a reading logs beside its `windows`: each window's source as
 * `kind:source`, in the same order, and its age in whole seconds by kind (none for a window whose
 * time is not known); after the trust rule also how many fresh readings of each kind there were
 * and the anomalies (`kind:source`). Content-free.
 */
export type UsageFields = { usage_src: string[]; usage_age_s: Record<string, number>; usage_n?: Record<string, number>; usage_anomaly?: string[] }

/**
 * D-83: why a reading at the limit did not stop an action (`split`, `no-fresh`) or the band it runs
 * in, for the row of that action: the rule, the windows and their sources and ages.
 */
export type LimitNote = { rule: string; windows: string[]; usage: UsageFields }

/** The note of a verdict that let the action run on something other than readings all below the limit; else undefined. */
export function noteOf(v: Verdict): LimitNote | undefined {
  return v.ok && v.rule !== '90' ? { rule: v.rule, windows: v.windows, usage: v.usage } : undefined
}

/** D-83: a fresh reading whose reset is this far from the other readings' of its kind is an anomaly. */
export const RESET_ANOMALY_MS = 60 * 60000

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
 * on; `rule`: the rule that decided (`band`, `90`, the first stopping window kind's: `spend-90`,
 * `other-90`, `cap`, `no-job`, `no-delta`, `delta`, or why a reading at the limit did not stop it,
 * D-83: `split`, `no-fresh`); `windows`: each window kind's deciding reading as the row names it
 * (idle.ts `limitWindows`); `usage`: their sources and ages (D-83); `reset`: when every reading
 * that stops the action or holds it in the band resets (plan windows only, the latest; undefined
 * when one does not say).
 */
export type Verdict = { ok: boolean; band: boolean; rule: string; windows: string[]; usage: UsageFields; reset?: number }

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

/** D-83: a reading refreshed in the last `LIMIT_FRESH_MS` (and not from further ahead: a clock skew). */
export function freshAt(r: Reading, now: number): boolean {
  return r.at !== undefined && Math.abs(now - r.at) <= LIMIT_FRESH_MS
}

/** D-83: the fresh readings of a kind whose reset is over an hour from most of the others' (a pair that differs: both). */
function anomalies(fresh: readonly Reading[]): Reading[] {
  return fresh.filter(r => {
    if (r.resetsAt === undefined) return false
    const o = fresh.filter(x => x !== r && x.resetsAt !== undefined)
    return o.length > 0 && o.filter(x => Math.abs((x.resetsAt ?? 0) - (r.resetsAt ?? 0)) > RESET_ANOMALY_MS).length * 2 > o.length
  })
}

/**
 * D-83, the trust rule: the verdict over every reading (`ruleOf` each one's rule, by default the
 * D-80 rule above at its own time). Per window kind: one reading per session (the newest; the own
 * session's `plugin` and `statusline` are one), the windows that reset count for nothing, only
 * the fresh ones decide: any `ok` among them lets the action run (`split` when another stops it),
 * else any `band` holds it in the band, else the kind stops it with the rule of the own reading
 * (else the newest). A kind with no fresh reading never stops it (`no-fresh` when an old one
 * would have). The first stopping kind decides; none: `band`, `split`, `no-fresh` or `90`.
 */
export function judge(all: readonly Reading[], c: LimitCtx, ruleOf: (r: Reading) => string = r => windowRule(r, { ...c, usageAt: r.at })): Verdict {
  const best = new Map<string, Reading>()
  for (const r of all) {
    if (r.resetsAt !== undefined && r.resetsAt <= c.now) continue
    const k = `${r.src === 'peer' ? 'p:' + (r.sid8 ?? '') : 'self'}\u0000${r.kind}`
    const o = best.get(k)
    if (o === undefined || (r.at ?? -Infinity) > (o.at ?? -Infinity)) best.set(k, r)
  }
  const rs = [...best.values()]
  const kinds = [...new Set(rs.map(r => r.kind))]
  const reps: Reading[] = []
  const n: Record<string, number> = {}
  const odd: string[] = []
  const pick = (xs: readonly Reading[]): Reading | undefined => xs.find(r => r.src !== 'peer') ?? [...xs].sort((a, b) => (b.at ?? 0) - (a.at ?? 0))[0]
  let stop: string | undefined
  let band = false
  let split = false
  let unread = false
  const holds: Reading[] = []
  for (const kind of kinds) {
    const of = rs.filter(r => r.kind === kind)
    const fresh = of.filter(r => freshAt(r, c.now))
    n[kind || 'unknown'] = fresh.length
    for (const r of anomalies(fresh)) odd.push(`${r.kind || 'unknown'}:${r.src}`)
    if (fresh.length === 0) {
      const old = pick(of)
      if (old !== undefined) reps.push(old)
      if (of.some(r => ruleOf(r) !== 'ok')) unread = true
      continue
    }
    const rules = fresh.map(r => ({ r, rule: ruleOf(r) }))
    const oks = rules.filter(x => x.rule === 'ok').map(x => x.r)
    if (oks.length > 0) {
      reps.push(pick(oks) ?? oks[0] as Reading)
      if (oks.length < fresh.length) split = true
      continue
    }
    const bands = rules.filter(x => x.rule === 'band').map(x => x.r)
    if (bands.length > 0) {
      reps.push(pick(bands) ?? bands[0] as Reading)
      band = true
      holds.push(...rules.filter(x => x.rule !== 'ok').map(x => x.r))
      continue
    }
    const rep = pick(fresh) ?? fresh[0] as Reading
    reps.push(rep)
    holds.push(...fresh)
    stop ??= rules.find(x => x.r === rep)?.rule
  }
  const usage: UsageFields = { ...usageFields(reps, c.now), usage_n: n, ...(odd.length > 0 ? { usage_anomaly: odd } : {}) }
  const windows = limitWindows(reps)
  const at = holds.length > 0 && holds.every(r => PLAN_CAPS[r.kind] !== undefined && r.resetsAt !== undefined) ? Math.max(...holds.map(r => r.resetsAt ?? 0)) : undefined
  if (stop !== undefined) return { ok: false, band: false, rule: stop, windows, usage, ...(at !== undefined ? { reset: at } : {}) }
  return { ok: true, band, rule: band ? 'band' : split ? 'split' : unread ? 'no-fresh' : '90', windows, usage, ...(band && at !== undefined ? { reset: at } : {}) }
}

/** The verdict over the session's own windows alone, read at `c.usageAt` (none: ok, rule `90`). */
export function verdictOf(limits: readonly Limit[], c: LimitCtx): Verdict {
  return judge(ownReadings(limits, c.usageAt), c)
}

/**
 * The time every window that stops the action, or holds it in the band, resets: when all are plan
 * windows that report a reset after `now` (the latest of them); else undefined. Own windows only.
 */
export function resetOf(limits: readonly Limit[], c: LimitCtx): number | undefined {
  return verdictOf(limits, c).reset
}

/**
 * D-83: the shared usage record's entries as readings (helper `usage`: times and resets in epoch
 * seconds): this session's status line's (`statusline`) and every other session's (`peer`); this
 * session's own `plugin` entries are left out (the live reading stands for them). A status line's
 * entry is its session's reading shown again (one object in Claude Code), and its `at` is only when
 * a status line first showed it (an entry dropped from the record comes back dated anew), so it is
 * never newer than that session's own refresh: this session's live reading (`ownAt`, epoch ms) or,
 * for another session or without `ownAt`, that session's `plugin` entry of the same kind; with
 * neither it is no reading. An entry out of form is dropped.
 */
export function recordReadings(entries: readonly unknown[], sid: string, ownAt?: number): Reading[] {
  const own = sid.slice(0, 8)
  const out: Reading[] = []
  const plugAt = new Map<string, number>()
  for (const x of entries) {
    if (typeof x !== 'object' || x === null) continue
    const { kind, at, src, sid8 } = x as Record<string, unknown>
    if (src === 'plugin' && typeof kind === 'string' && typeof sid8 === 'string' && typeof at === 'number' && Number.isFinite(at)) {
      const k = `${sid8}\u0000${kind}`
      plugAt.set(k, Math.max(at * 1000, plugAt.get(k) ?? -Infinity))
    }
  }
  for (const x of entries) {
    if (typeof x !== 'object' || x === null) continue
    const e = x as Record<string, unknown>
    const { kind, pct, at, src, sid8 } = e
    const r = e.resets_at
    if (typeof kind !== 'string' || kind === '' || typeof pct !== 'number' || !Number.isFinite(pct) || typeof at !== 'number' || !Number.isFinite(at)) continue
    if ((src !== 'plugin' && src !== 'statusline') || typeof sid8 !== 'string' || sid8 === '') continue
    if (sid8 === own && src === 'plugin') continue
    const resetsAt = typeof r === 'number' && Number.isFinite(r) ? r * 1000 : undefined
    let t = at * 1000
    if (src === 'statusline') {
      const cap = sid8 === own && ownAt !== undefined ? ownAt : plugAt.get(`${sid8}\u0000${kind}`)
      if (cap === undefined) continue
      t = Math.min(t, cap)
    }
    out.push({ kind, percentUsed: pct, ...(resetsAt !== undefined ? { resetsAt } : {}), at: t, ...(sid8 === own ? { src: 'statusline' as const } : { src: 'peer' as const, sid8 }) })
  }
  return out
}

/**
 * D-83: every reading a near-limit decision reads now: the session's own windows (`limits`, read at
 * `LoadState.usageAt`) and the shared record's other ones; the own reading is written to the record
 * in the same helper call. With no own window, the record is not read: a session that reports
 * none (an API key, before its first response) has no limit of its own that another session's
 * reading could tell of. A failed call leaves the own reading alone, and the next refresh writes it
 * (`noteUsage`).
 */
export async function readingsNow(d: Deps, sid: string, limits: readonly Limit[]): Promise<Reading[]> {
  const own = ownReadings(limits, d.state.usageAt)
  if (limits.length === 0) return own
  const at = d.state.usageAt
  const w = recordWindows(limits)
  let entries: unknown[] | undefined
  try {
    entries = await usageRecord(d, sid, at !== undefined && w.length > 0 ? { at: at / 1000, windows: w } : undefined)
  } catch {
    entries = undefined
  }
  if (entries !== undefined && at !== undefined && w.length > 0) d.state.usageNote = { key: noteKey(w), at }
  return [...own, ...recordReadings(entries ?? [], sid, at)]
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
 * The key a reading is compared by: each window's kind, whole points of its share and reset. A share
 * that moves by a fraction (each response's headers, many subagents at once) is the same reading
 * for the record until it reaches the next point or `USAGE_NOTE_MS` passes (0.1.9).
 */
function noteKey(w: ReturnType<typeof recordWindows>): string {
  return w.map(x => `${x.kind}:${Math.floor(x.pct)}:${x.resets_at ?? ''}`).join(',')
}

/**
 * D-83: Claude Code refreshed the session's usage reading at `at` (a response, `session.measure`):
 * written to the shared record when it changed (by whole points, `noteKey`) or the last write is
 * `USAGE_NOTE_MS` old, so a written reading is never more than that old while refreshes come and a
 * skip decision elsewhere still reads it as fresh (`LIMIT_FRESH_MS`). One write at a time (0.1.9):
 * a refresh while one runs is folded into one more check after it, of the newest reading. A failed
 * read writes nothing, and a failed helper call is not counted as written (the next refresh tries
 * again; a refresh folded in meanwhile is dropped); a write the helper could not make (no record in
 * a git work tree, a full disk) is not reported, so it is tried again `USAGE_NOTE_MS` later (fewer
 * fresh readings, the safe side).
 */
export async function noteUsage(d: Deps, at: number): Promise<void> {
  const busy = d.state.usageNoting
  if (busy !== undefined) {
    busy.next = Math.max(busy.next ?? at, at)
    return
  }
  const run: { next: number | undefined } = { next: undefined }
  d.state.usageNoting = run
  try {
    for (let t: number | undefined = at; t !== undefined; t = run.next) {
      run.next = undefined
      if (!(await noteOnce(d, t))) return
    }
  } finally {
    d.state.usageNoting = undefined
  }
}

/** One check of `noteUsage`: false when the helper call failed. */
async function noteOnce(d: Deps, at: number): Promise<boolean> {
  let w: ReturnType<typeof recordWindows>
  try {
    w = recordWindows((await d.usage()).rateLimits)
  } catch {
    return true
  }
  if (w.length === 0) return true
  const key = noteKey(w)
  const n = d.state.usageNote
  if (n !== undefined && n.key === key && at - n.at < USAGE_NOTE_MS) return true
  if ((await usageRecord(d, await d.sessionId(), { at: at / 1000, windows: w })) === undefined) return false
  d.state.usageNote = { key, at }
  return true
}
