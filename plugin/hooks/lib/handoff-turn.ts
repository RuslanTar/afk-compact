// The handoff turn (MOD-SPEC §9.1, D-18, D-20): in a cycle that will not auto-continue (a last
// cycle) the mod submits one turn after the nudged turn ends and before it compacts, so the
// handoff is written with the full context, on the session's model, from a warm cache. This
// module holds its state, its limits text and its end; boundary.ts schedules it and the
// compaction after it, compact.ts handles a native compaction that races it.
//
// The limits are context text only (DP-5, Q-R-2): no tool call is ever denied here, and the
// texts say what the model should do, never that the plugin stops anything (DP-14 (7)).
import type { Deps } from './deps'
import type { Effective } from './config'
import type { Runtime } from './assemble'
import { assembleIf, hasAsset } from './assemble'
import { specValue } from './detect'
import type { HandoffState } from './helper'
import { handoffState, handoffTurnOpen } from './helper'
import { log } from './log'
import { drawNonce } from './nonce'
import { HOUR_MS, clearHalt } from './cont'

/** Why a cycle will not auto-continue (the `handoff-turn open --reason` values). */
export type HaltReason = '2-nonok' | 'thrash' | 'cap' | 'continue-off'

/** `@halt_reason@` (D-18 B6): the plain words for each reason. */
export const HALT_REASON_TEXT: Record<HaltReason, string> = {
  '2-nonok': 'compaction failed twice in a row',
  thrash: 'compactions keep repeating without progress',
  cap: 'the hourly auto-continue limit is reached',
  'continue-off': 'auto-continue is turned off',
}

/** DP-4: only these reasons get the plugin compaction after the handoff turn. */
export function compactsAfter(reason: HaltReason): boolean {
  return reason === 'cap' || reason === 'continue-off'
}

/** The pre-flight skip: below this allowance no handoff turn starts. */
export const MIN_ALLOWANCE = 20000
/** Bands below the native trigger `N` (MOD-SPEC §9.1). */
export const SPENT_MARGIN = 15000
export const NEAR_MARGIN = 25000
export const IMMINENT_MARGIN = 5000
/** Runaway guard: at most this many handoff turns per rolling hour per session. */
export const PER_HOUR = 2

export type Band = 'near' | 'spent' | 'imminent'

export type HandoffTurn = {
  reason: HaltReason
  /** `delay`: waiting for `boundary_delay_ms`; `submitted`: the prompt is in; `running`: its turn. */
  phase: 'delay' | 'submitted' | 'running'
  /** The handoff id, set once `handoff-turn open` created its record. */
  ht: string | null
  /** Tokens at the nudged turn's end, the allowance `H`, the native trigger `N`, the call cap `c`. */
  t0: number
  allowance: number
  native: number
  maxCalls: number
  calls: number
  resultChars: number
  /** Bands already crossed (one `handoff_limit` row each); `[near]` is given once. */
  bands: Band[]
  turnSeq: number
  turnId: string | null
  startedAt: number
  interjected: boolean
  /** A native compaction ran during the turn (the race); the plugin compaction is dropped. */
  race: { nonce: string; trigger: string } | null
}

/** A handoff published by a handoff turn, until the next main turn or compaction. */
export type Published = { ht: string; path: string }

/** `c` = 1 + `call_cap` + `recipe_cap` from the shared spec (RV-25), or undefined without them. */
export function maxCalls(): number | undefined {
  const a = specValue('call_cap')
  const b = specValue('recipe_cap')
  return typeof a === 'number' && typeof b === 'number' ? 1 + a + b : undefined
}

function htKey(sid: string): string {
  return `ht:${sid}`
}

/** Start times of this session's handoff turns in the last 60 min (`$.store`, survives reloads). */
export async function recentTurns(d: Deps, sid: string, now: number): Promise<number[]> {
  const raw = await d.storeGet(htKey(sid))
  return (Array.isArray(raw) ? raw : []).filter((t): t is number => typeof t === 'number' && now - t < HOUR_MS)
}

/** The nudge may promise a handoff turn: the setting is on and the hourly guard has room. */
export async function handoffPossible(d: Deps, sid: string): Promise<boolean> {
  if (d.cfg.handoff_turn !== 'halt' || !hasAsset('handoff-turn') || maxCalls() === undefined) return false
  return (await recentTurns(d, sid, await d.now())).length < PER_HOUR
}

async function skipped(d: Deps, sid: string, why: string, ht: string | null = null): Promise<void> {
  await log(d, sid, 'handoff_skipped', { why, ht })
}

/**
 * At a last cycle's nudged turn end (`answer`): the Start checks of §9.1. Returns the planned
 * turn (to submit after `boundary_delay_ms`), or undefined with a `handoff_skipped` row when one
 * applies. `handoff_turn` off plans nothing and logs nothing.
 */
export async function planHandoff(d: Deps, sid: string, reason: HaltReason, eff: Effective, tokens: number): Promise<HandoffTurn | undefined> {
  const s = d.state
  if (d.cfg.handoff_turn !== 'halt') return undefined
  if (s.askOpen > 0 || s.lastTurnAsksUser) return void (await skipped(d, sid, 'asks-user'))
  if (s.compactedInTurn === s.turnSeq) return void (await skipped(d, sid, 'compacted'))
  const c = maxCalls()
  if (!hasAsset('handoff-turn') || c === undefined) return void (await skipped(d, sid, 'no-asset'))
  if ((await recentTurns(d, sid, await d.now())).length >= PER_HOUR) return void (await skipped(d, sid, 'cap'))
  const allowance = Math.min(d.cfg.handoff_turn_max_tokens, eff.native_trigger - SPENT_MARGIN - tokens)
  if (allowance < MIN_ALLOWANCE) return void (await skipped(d, sid, 'headroom'))
  return {
    reason, phase: 'delay', ht: null, t0: tokens, allowance, native: eff.native_trigger, maxCalls: c,
    calls: 0, resultChars: 0, bands: [], turnSeq: -1, turnId: null, startedAt: 0, interjected: false, race: null,
  }
}

/**
 * The delay is over: draws the ht (checked against dispatch records and handoff-turn records),
 * opens its record, then submits the `[submit]` text, framed. False, with a `handoff_skipped`
 * row, when the record cannot be opened or the submit fails. True, with nothing submitted, when
 * a user turn started while it awaited the helper (§9.1 step 3: that turn cancels the handoff
 * turn and logs `why=user-turn`; the normal rules apply at its end).
 */
export async function openAndSubmit(d: Deps, sid: string, h: HandoffTurn, dispatchTaken: (n: string) => Promise<boolean>): Promise<boolean> {
  const s = d.state
  // Checked again after every await: onTurnStart marks a main turn before its own awaits.
  const cancelled = () => s.handoffTurn !== h || h.phase !== 'delay' || s.mainTurnRunning
  const runtime: Runtime = { halt_reason: HALT_REASON_TEXT[h.reason], max_calls: String(h.maxCalls) }
  const text = assembleIf(d.name, 'handoff-turn', ['submit'], runtime)
  if (text === undefined) {
    await skipped(d, sid, 'no-asset')
    return false
  }
  const p = await d.paths()
  const taken = async (n: string) => (await dispatchTaken(n)) || (p !== undefined && (await d.exists(`${p.watch}/${sid}/handoff-turn/${n}.json`)))
  let opened: string | undefined
  for (let i = 0; i < 3 && opened === undefined; i++) {
    const ht = await drawNonce(taken)
    if (cancelled()) return true
    const r = await handoffTurnOpen(d, sid, ht, h.reason, h.maxCalls, h.allowance)
    if (r === 'failed') break
    if (r === 'ok') opened = ht
  }
  if (opened === undefined) {
    if (cancelled()) return true
    await skipped(d, sid, 'open-failed')
    return false
  }
  // Set before the check below, so a cancel row written from here on names the ht.
  h.ht = opened
  const now = await d.now()
  await d.storeSet(htKey(sid), [...(await recentTurns(d, sid, now)), now])
  // No await between this check and the submit call: a user turn that started meanwhile wins.
  if (cancelled()) return true
  h.phase = 'submitted'
  s.ourSubmitPending = true
  try {
    await d.submit(text)
  } catch {
    s.ourSubmitPending = false
    await skipped(d, sid, 'submit-failed', opened)
    return false
  }
  return true
}

/**
 * A main `turn.start`: our submit's turn becomes the handoff turn (no checkpoint nudge in it);
 * a user's turn during the delay cancels the handoff turn (`why=user-turn`).
 */
export async function onHandoffTurnStart(d: Deps, sid: string, ours: boolean, turnId: string): Promise<void> {
  const s = d.state
  const h = s.handoffTurn
  if (!h) return
  if (h.phase === 'submitted' && ours) {
    h.phase = 'running'
    h.turnSeq = s.turnSeq
    h.turnId = turnId
    h.startedAt = await d.now()
    s.nudgedThisTurn = true
    await log(d, sid, 'handoff_turn_start', { ht: h.ht, reason: h.reason, turn_id: turnId, t0: h.t0, max_calls: h.maxCalls, max_tokens: h.allowance })
    return
  }
  if (!ours) {
    s.handoffTurn = undefined
    await skipped(d, sid, 'user-turn', h.ht)
  }
}

function running(d: Deps): HandoffTurn | undefined {
  const h = d.state.handoffTurn
  return h && h.phase === 'running' && h.turnSeq === d.state.turnSeq ? h : undefined
}

/** A main `tool.call` before `next(e)`: counted in the handoff turn, denied or not. */
export function countCall(d: Deps): void {
  const h = running(d)
  if (h) h.calls++
}

/**
 * After a main tool result in the handoff turn: sums its text length and returns the band text
 * that applies, strongest first: `[imminent]` at ≥ `N − 5,000`; `[spent]` at ≥ `spent`, past the
 * call cap, or after a race; `[near]` once, at ≥ `near` or from call `c − 7`. Undefined outside
 * the handoff turn, after a user interjection, or when no band applies.
 */
export async function limitText(d: Deps, sid: string, resultText: string | undefined): Promise<string | undefined> {
  const h = running(d)
  if (!h) return undefined
  h.resultChars += resultText?.length ?? 0
  if (h.interjected) return undefined
  let tokens: number | undefined
  try {
    tokens = (await d.usage()).tokens
  } catch {
    tokens = undefined
  }
  const t = tokens ?? h.t0
  const near = Math.min(h.t0 + 0.75 * h.allowance, h.native - NEAR_MARGIN)
  const spent = Math.min(h.t0 + h.allowance, h.native - SPENT_MARGIN)
  let band: Band | undefined
  if (t >= h.native - IMMINENT_MARGIN) band = 'imminent'
  else if (t >= spent || h.calls > h.maxCalls || h.race !== null) band = 'spent'
  else if (!h.bands.includes('near') && (t >= near || h.calls >= h.maxCalls - 7)) band = 'near'
  if (band === undefined) return undefined
  if (!h.bands.includes(band)) {
    h.bands.push(band)
    await log(d, sid, 'handoff_limit', { ht: h.ht, band, calls: h.calls, tokens: tokens ?? null })
  }
  if (!h.bands.includes('near')) h.bands.push('near')
  return assembleIf(d.name, 'handoff-turn', [band], {})
}

/**
 * `prompt.submit` from the user (`composer` or `bridge`) delivered into the running handoff turn:
 * the user leads from here, so no more limits text (`handoff_user_interjected`).
 */
export async function onInterjection(d: Deps, sid: string, turnId: string): Promise<void> {
  const h = running(d)
  if (!h || h.interjected || h.turnId !== turnId) return
  h.interjected = true
  await log(d, sid, 'handoff_user_interjected', { ht: h.ht })
}

/** What the end of the handoff turn leaves to do. */
export type HandoffEnd =
  /** Not a handoff-turn end, or one the user took over: the normal turn-end rules apply. */
  | { kind: 'normal' }
  /** Nothing more: aborted, raced, or a halt reason that gets no plugin compaction (DP-4). */
  | { kind: 'done' }
  /** One plugin compaction, exempt from halt and cooldown, `[handoff]` when published. */
  | { kind: 'compact'; ht: string; path: string | undefined; stats: Record<string, string | number | null> }

/**
 * The handoff turn's `turn.complete`: one `handoff_turn_end` row (MOD-SPEC §2.5 fields) and
 * what follows. Published + `cap`/`continue-off` → compaction with `[handoff]`; not published →
 * the same compaction with the full text; `2-nonok`/`thrash` → no compaction, halt stays, the
 * toast says why; aborted or raced → nothing.
 */
export async function endHandoffTurn(d: Deps, sid: string, reason: string): Promise<HandoffEnd> {
  const s = d.state
  const h = running(d)
  if (!h || h.ht === null) return { kind: 'normal' }
  s.handoffTurn = undefined
  let tokens: number | undefined
  try {
    tokens = (await d.usage()).tokens
  } catch {
    tokens = undefined
  }
  const state: HandoffState = await handoffState(d, sid, h.ht)
  const result = h.race !== null ? 'race'
    : reason !== 'answer' ? 'aborted'
      : state.state === 'published' ? 'published'
        : state.state === 'staged' ? 'failed:lint'
          : state.state === 'superseded' ? 'race'
            : state.state === 'none' ? 'none'
              : 'failed:state-unknown'
  const stats: Record<string, string | number | null> = {
    handoff_turn: result,
    handoff_ht: h.ht,
    handoff_tokens: tokens === undefined ? null : tokens - h.t0,
    handoff_calls: h.calls,
    handoff_result_chars: h.resultChars,
    handoff_ms: (await d.now()) - h.startedAt,
    handoff_headroom: tokens === undefined ? null : h.native - tokens,
  }
  const path = state.state === 'published' ? state.path : undefined
  const shown = path === undefined ? undefined : await tilde(d, path)
  if (path !== undefined) s.published = { ht: h.ht, path: shown ?? path }
  const compact = reason === 'answer' && h.race === null && !h.interjected && compactsAfter(h.reason)
  await log(d, sid, 'handoff_turn_end', { ...stats, reason: h.reason, turn_id: h.turnId, interjected: h.interjected, compaction: compact })
  // The user took the turn over: halt clears at its end as for any user turn (§9.1).
  if (h.interjected) {
    await clearHalt(d, sid)
    return { kind: 'normal' }
  }
  if (reason !== 'answer' || h.race !== null) return { kind: 'done' }
  const why = HALT_REASON_TEXT[h.reason]
  if (compact) {
    if (shown !== undefined) d.toast(`${d.name}: auto-continue paused (${why}); handoff saved: ${shown}`)
    return { kind: 'compact', ht: h.ht, path: shown, stats }
  }
  d.toast(shown !== undefined
    ? `${d.name}: handoff saved: ${shown}; no plugin compaction because ${why}`
    : `${d.name}: handoff not saved (${result}); no plugin compaction because ${why}`)
  return { kind: 'done' }
}

/** A path with the home folder as `~` (MOD-SPEC §9.1 `@handoff_path@`). */
export async function tilde(d: Deps, path: string): Promise<string> {
  const home = (await d.home())?.replace(/\/+$/, '')
  if (home && home !== '' && (path === home || path.startsWith(home + '/'))) return '~' + path.slice(home.length)
  return path
}

/** The handoff turn a main compaction of this trigger interrupts, if one is running. */
export function racedTurn(d: Deps, trigger: string): HandoffTurn | undefined {
  const h = running(d)
  return h && h.ht !== null && (trigger === 'auto' || trigger === 'precompute') ? h : undefined
}

/** `[handoff-partial]` runtime for a resume block after a race, or `[handoff]` when published. */
export type RaceBlock = { published: string } | { draft: boolean; finish: string | null }

export async function raceBlock(d: Deps, st: HandoffState): Promise<RaceBlock> {
  if (st.state === 'published') return { published: await tilde(d, st.path) }
  if (st.state === 'staged') return { draft: st.draft, finish: st.finish }
  return { draft: false, finish: null }
}
