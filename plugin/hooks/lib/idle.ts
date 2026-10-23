// The pre-idle handoff turn (MOD-SPEC §9.4, IC-1 D5; setting `idle_handoff_turn`, default auto).
// Idle D3 (owner 2026-10-23 02:4x, IA-1..3): "keep on if idle compaction is off, and OFF the
// plugin's idle when native idle setting is ON". With `auto` the timer is armed only while
// Claude Code's own idle compaction is off (deps.nativeIdle: `idleCompaction` or
// `autoCompactEnabled` false); the fire checks it again (`native-on`, `native-unknown`: a failed
// read counts as on, O-9 provisional). `off` arms nothing. One `idle_mode {native, plugin_turn}`
// row whenever the pair changes in a load, so a `/config` change shows at the next turn end.
// At every main turn end the mod (re)arms one timer for 49 minutes later (the measured native
// idle-compaction time of 54 minutes less a 5-minute lead). When it fires and every check
// passes, one plugin-submitted handoff turn runs on the D-18 machinery (handoff-turn.ts), so a
// handoff exists before the 1-hour prompt cache expires. No plugin compaction and no continue
// follow it (DP-4; PR-2 P-56 is not reviewed); at most one per idle episode.
import type { Deps } from './deps'
import { dispatchExists } from './compact'
import { effective } from './config'
import { MIN_ALLOWANCE, OPTIONAL_PER_HOUR, SPENT_MARGIN, dropDeferred, maxCalls, newTurn, openAndSubmit, recentTurns, skipped } from './handoff-turn'
import { log } from './log'

/** 54 − 5 minutes after the turn end (IC-1 F3, F6; no key: tuned from P-IC-1 / E-1 `idle_gap_s`). */
export const IDLE_FIRE_MS = 49 * 60000
/** `@idle_min@`: the minutes the `[submit-idle]` text names. */
export const IDLE_MIN_TEXT = '49'
/** Every rate-limit window must stay below this share (else `near-limit`). */
export const NEAR_LIMIT_PCT = 90
/**
 * O-9, PROVISIONAL (owner decision open; SPEC-DELTAS §9 recommended reading): a failed read of
 * Claude Code's idle settings counts as native idle on, so the plugin sends no pre-idle turn while
 * the user is away. `false` would treat an unreadable setting as native off (the plugin's turn on).
 */
export const NATIVE_UNKNOWN_COUNTS_AS_ON = true

function dueKey(sid: string): string {
  return `idle_due:${sid}`
}

/** The persisted timer: when it fires, and the idle episode it belongs to. */
type Due = { due: number; sid: string; episode: { since: number; done: boolean } | null }

function readDue(v: unknown): Due | undefined {
  if (typeof v !== 'object' || v === null) return undefined
  const o = v as Record<string, unknown>
  if (typeof o.due !== 'number' || typeof o.sid !== 'string') return undefined
  const e = o.episode as Record<string, unknown> | null | undefined
  const episode = e && typeof e.since === 'number' && typeof e.done === 'boolean' ? { since: e.since, done: e.done } : null
  return { due: o.due, sid: o.sid, episode }
}

/** Cancels the timer (synchronous: safe before any await in a hook). */
export function cancelIdleTimer(d: Deps): void {
  d.state.idleTimer?.cancel()
  d.state.idleTimer = undefined
}

/**
 * Cancels the timer and forgets the persisted due (a turn started, a prompt entered, the session
 * ended), so a reload of the same sid re-arms nothing already cancelled (AT-IC-14). Callers may
 * have cancelled the timer already (cancelIdleTimer before any await); the due is cleared all
 * the same.
 */
export async function cancelIdle(d: Deps, sid: string): Promise<void> {
  cancelIdleTimer(d)
  const stored = d.state.idleDueSid
  if (stored === undefined) return
  d.state.idleDueSid = undefined
  await d.storeSet(dueKey(stored), null)
  if (stored !== sid) await d.storeSet(dueKey(sid), null)
}

function schedule(d: Deps, sid: string, at: number, now: number): void {
  cancelIdleTimer(d)
  d.state.idleTimer = d.after(Math.max(0, at - now), () => {
    d.state.idleTimer = undefined
    d.state.inflight = fire(d, sid).catch(() => undefined)
  })
}

/**
 * IA-3: whether the plugin's pre-idle turn is on now (`auto` and native idle off), with one
 * `idle_mode` row when the pair differs from the last one this load wrote.
 */
async function pluginTurnOn(d: Deps, sid: string): Promise<{ on: boolean; native: 'on' | 'off' | 'unknown' }> {
  const native = await d.nativeIdle()
  const nativeOff = native === 'off' || (native === 'unknown' && !NATIVE_UNKNOWN_COUNTS_AS_ON)
  const on = d.cfg.idle_handoff_turn === 'auto' && nativeOff
  const pair = native + '/' + (on ? 'on' : 'off')
  if (d.state.idleMode !== pair) {
    d.state.idleMode = pair
    await log(d, sid, 'idle_mode', { native, plugin_turn: on ? 'on' : 'off' })
  }
  return { on, native }
}

/**
 * Main `turn.complete` (any origin): (re)arms the timer for `endAt + 49 min` while the plugin's
 * turn is on; `off`, or native idle on (or unknown), arms nothing and drops a timer armed before.
 */
export async function armIdle(d: Deps, sid: string, endAt: number): Promise<void> {
  if (!(await pluginTurnOn(d, sid)).on) {
    if (d.state.idleTimer !== undefined || d.state.idleDueSid !== undefined) await cancelIdle(d, sid)
    return
  }
  const due = endAt + IDLE_FIRE_MS
  const rec: Due = { due, sid, episode: d.state.idleEpisode ?? null }
  await d.storeSet(dueKey(sid), rec)
  d.state.idleDueSid = sid
  schedule(d, sid, due, await d.now())
}

/** Once per load (AT-IC-14): a persisted due still in the future for this sid is armed again. */
export async function loadIdle(d: Deps, sid: string): Promise<void> {
  if (!(await pluginTurnOn(d, sid)).on) return
  const rec = readDue(await d.storeGet(dueKey(sid)))
  if (!rec || rec.sid !== sid) return
  const now = await d.now()
  if (rec.due <= now) return
  if (rec.episode && !d.state.idleEpisode) d.state.idleEpisode = rec.episode
  d.state.idleDueSid = sid
  schedule(d, sid, rec.due, now)
}

/** The checks of §9.4 "Fire", in order; the first that fails is the skip reason. */
async function blocked(d: Deps, sid: string): Promise<string | { tokens: number; allowance: number; native: number; calls: number } > {
  const s = d.state
  if (!d.cfg.triggers) return 'triggers-off'
  // IA-3: native idle may have been switched on (or become unreadable) since the timer was armed.
  const mode = await pluginTurnOn(d, sid)
  if (mode.native === 'on') return 'native-on'
  if (mode.native === 'unknown' && NATIVE_UNKNOWN_COUNTS_AS_ON) return 'native-unknown'
  if (!mode.on) return 'disabled'
  const eff = await effective(d, sid)
  if (eff.disabled) return 'small-window'
  if ((await d.sessionId()) !== sid) return 'session-changed'
  if (s.mainTurnRunning || s.foreignPrompts > 0 || s.busy || s.handoffTurn !== undefined || s.ourSubmitPending) return 'busy'
  if (!s.lastTurnAnswer) return 'aborted'
  let u
  try {
    u = await d.usage()
  } catch {
    u = undefined
  }
  const tokens = u?.tokens
  if (tokens === undefined || tokens < d.cfg.idle_handoff_min_tokens) return 'small'
  const limits = u?.rateLimits ?? []
  if (limits.length === 0) return 'ttl-5m'
  if (limits.some(l => !(l.percentUsed < NEAR_LIMIT_PCT))) return 'near-limit'
  const ep = s.idleEpisode
  if (!ep || ep.done) return 'episode'
  if (s.publishedSinceHuman) return 'published'
  if ((await recentTurns(d, sid, await d.now())).length >= OPTIONAL_PER_HOUR) return 'cap'
  const c = maxCalls()
  if (c === undefined) return 'no-asset'
  const allowance = Math.min(d.cfg.handoff_turn_max_tokens, eff.native_trigger - SPENT_MARGIN - tokens)
  if (allowance < MIN_ALLOWANCE) return 'headroom'
  return { tokens, allowance, native: eff.native_trigger, calls: c }
}

/** The timer fired: one `handoff_skipped {why, reason: idle}` row, or the pre-idle turn. */
export async function fire(d: Deps, sid: string): Promise<void> {
  const s = d.state
  if (s.idleDueSid === sid) s.idleDueSid = undefined
  await d.storeSet(dueKey(sid), null)
  const b = await blocked(d, sid)
  if (typeof b === 'string') {
    await skipped(d, sid, b, null, 'idle')
    return
  }
  const h = newTurn('idle', b.tokens, b.allowance, b.native, b.calls)
  s.handoffTurn = h
  const ok = await openAndSubmit(d, sid, h, n => dispatchExists(d, sid, n))
  if (!ok) {
    if (s.handoffTurn === h) s.handoffTurn = undefined
    return
  }
  if (h.phase === 'delay') {
    // A user prompt came first (it entered, or its turn started): the user is back.
    await dropDeferred(d, sid, h)
    return
  }
  // One per idle episode, whatever the turn's end (§9.4 `episode`).
  if (s.idleEpisode) s.idleEpisode.done = true
}

/** The seconds since the last main turn end, for `handoff_turn_start.gap_s`. */
export async function gapSeconds(d: Deps): Promise<number | null> {
  const t = d.state.lastTurnEndAt
  return t === undefined ? null : Math.round(((await d.now()) - t) / 1000)
}

/** One `submit_dropped {why}` row: a submit site found the session changed (IC-1 D7 (ii)). */
export async function submitDropped(d: Deps, sid: string, site: string): Promise<void> {
  await log(d, sid, 'submit_dropped', { why: 'session-changed', site })
}
