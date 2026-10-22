// The handoff turn (MOD-SPEC §9.1, D-18, D-20): in a cycle that will not auto-continue (a last
// cycle) the mod submits one turn after the nudged turn ends and before it compacts, so the
// handoff is written with the full context, on the session's model, from a warm cache. This
// module holds its state, its limits text and its end; boundary.ts schedules it and the
// compaction after it, compact.ts handles a native compaction that races it.
//
// The limits are context text only (DP-5, Q-R-2): no tool call is ever denied here, and the
// texts say what the model should do, never that the plugin stops anything (DP-14 (7)).
import type { Deps } from './deps'
import { submitPending, submitSettled } from './deps'
import type { Effective } from './config'
import type { Runtime, Tag } from './assemble'
import { assembleIf, hasAsset, hasTag } from './assemble'
import { specValue } from './detect'
import type { HandoffState } from './helper'
import { handoffState, handoffTurnClose, handoffTurnOpen } from './helper'
import { log } from './log'
import { drawNonce } from './nonce'
import { HOUR_MS, clearHalt } from './cont'
import { storeRuntime } from './resume'
import { IDLE_MIN_TEXT, gapSeconds, submitDropped } from './idle'

/** Why a cycle will not auto-continue (the `handoff-turn open --reason` values of a last cycle). */
export type HaltReason = '2-nonok' | 'thrash' | 'cap' | 'continue-off'

/**
 * Every `handoff-turn open --reason` value: a last cycle's halt reason, the pre-compaction turn
 * (§9.3) or the pre-idle turn (§9.4).
 */
export type TurnReason = HaltReason | 'precompact' | 'idle'

export function isHalt(r: TurnReason): r is HaltReason {
  return r !== 'precompact' && r !== 'idle'
}

/** The asset lines a turn of this reason is submitted with. */
export function kindOf(r: TurnReason): TurnKind {
  return r === 'precompact' ? 'precompact' : r === 'idle' ? 'idle' : 'halt'
}

/** `@halt_reason@` (D-18 B6): the plain words for each reason. */
export const HALT_REASON_TEXT: Record<HaltReason, string> = {
  '2-nonok': 'compaction failed twice in a row',
  thrash: 'compactions keep repeating without progress',
  cap: 'the hourly auto-continue limit is reached',
  'continue-off': 'auto-continue is turned off',
}

/**
 * What starts a handoff turn: a last cycle (`halt`, §9.1), the pre-compaction turn
 * (`precompact`, §9.3) or the pre-idle turn (`idle`, §9.4). Each has its own submit lines in
 * `handoff-turn.txt` around the shared `[submit]` line (S-SETTINGS D, IC-1 D5).
 */
export type TurnKind = 'halt' | 'precompact' | 'idle'
const KIND_TAG: Record<TurnKind, Tag> = { halt: 'submit-halt', precompact: 'submit-pre', idle: 'submit-idle' }

/**
 * The prompt of a handoff turn: the shared `[submit]` lines plus the kind's own, joined. Undefined
 * when the asset is missing, or when a `precompact` or `idle` text has no lines of its own in this
 * build (a last cycle's text works with or without its `[submit-halt]` split).
 */
export function submitText(name: string, kind: TurnKind, runtime: Runtime, drop: readonly string[] = []): string | undefined {
  if (kind !== 'halt' && !hasTag('handoff-turn', KIND_TAG[kind])) return undefined
  return assembleIf(name, 'handoff-turn', ['submit', KIND_TAG[kind]], runtime, drop)
}

/** DP-4: only these reasons get the plugin compaction after the handoff turn. */
export function compactsAfter(reason: HaltReason): boolean {
  return reason === 'cap' || reason === 'continue-off'
}

/**
 * The last cycle's reason as it stands now: a `thrash` or `2-nonok` halt that started after the
 * nudge (thrash is found at the nudged turn's end) wins over the `cap` or `continue-off` the
 * nudge saw, so DP-4 gives that cycle no plugin compaction. A halt for `cap` changes nothing.
 */
export function haltWins(d: Deps, reason: HaltReason): HaltReason {
  const h = d.state.halt
  if (!compactsAfter(reason) || !h.active || h.reason === 'cap') return reason
  return h.reason === 'thrash' ? 'thrash' : '2-nonok'
}

/** The pre-flight skip: below this allowance no handoff turn starts. */
export const MIN_ALLOWANCE = 20000
/** Bands below the native trigger `N` (MOD-SPEC §9.1). */
export const SPENT_MARGIN = 15000
export const NEAR_MARGIN = 25000
export const IMMINENT_MARGIN = 5000
/** Runaway guard: at most this many handoff turns per rolling hour per session. */
export const PER_HOUR = 2
/**
 * The optional turns (pre-compaction §9.3, pre-idle §9.4) take only the first hourly slot, so a
 * last-cycle handoff turn always keeps the second (S-SETTINGS D, IC-1 D5).
 */
export const OPTIONAL_PER_HOUR = 1

export type Band = 'near' | 'spent' | 'imminent'

export type HandoffTurn = {
  reason: TurnReason
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
  /** The hourly-cap stamp is written: a deferred-then-rerun turn counts once (DP-30 (2)). */
  stamped?: boolean
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

/** One `handoff_skipped` row; an optional turn's row also names its reason (`precompact`, `idle`). */
export async function skipped(d: Deps, sid: string, why: string, ht: string | null = null, reason?: TurnReason): Promise<void> {
  await log(d, sid, 'handoff_skipped', { why, ht, ...(reason !== undefined && !isHalt(reason) ? { reason } : {}) })
}

export function newTurn(reason: TurnReason, tokens: number, allowance: number, native: number, maxCalls: number): HandoffTurn {
  return {
    reason, phase: 'delay', ht: null, t0: tokens, allowance, native, maxCalls,
    calls: 0, resultChars: 0, bands: [], turnSeq: -1, turnId: null, startedAt: 0, interjected: false, race: null,
  }
}

/**
 * MOD-SPEC §9.3: at an eligible turn-end compaction (the caller checked the §9 turn-end guards and
 * that the turn was not nudged), with `precompact_turn: model`, the planned pre-compaction turn,
 * or undefined with one `handoff_skipped {why, reason: precompact}` row (then the normal
 * compaction runs exactly as with `code`). `code` plans nothing and logs nothing.
 */
export async function planPrecompact(d: Deps, sid: string, eff: Effective, tokens: number): Promise<HandoffTurn | undefined> {
  const s = d.state
  if (d.cfg.precompact_turn !== 'model') return undefined
  const skip = async (why: string) => void (await skipped(d, sid, why, null, 'precompact'))
  if (s.askOpen > 0 || s.lastTurnAsksUser) return skip('asks-user')
  const allowance = Math.min(d.cfg.handoff_turn_max_tokens, eff.native_trigger - SPENT_MARGIN - tokens)
  if (allowance < MIN_ALLOWANCE) return skip('headroom')
  if (s.precompactRan) return skip('again')
  if ((await recentTurns(d, sid, await d.now())).length >= OPTIONAL_PER_HOUR) return skip('cap')
  const c = maxCalls()
  if (!hasTag('handoff-turn', 'submit-pre') || c === undefined) return skip('no-asset')
  return newTurn('precompact', tokens, allowance, eff.native_trigger, c)
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
  return newTurn(reason, tokens, allowance, eff.native_trigger, c)
}

/**
 * The delay is over: draws the ht (checked against dispatch records and handoff-turn records),
 * opens its record, then submits the `[submit]` text, framed. False, with a `handoff_skipped`
 * row, when the record cannot be opened or the submit fails. True, with nothing submitted, when
 * a user turn started while it awaited the helper (§9.1 step 3: that turn cancels the handoff
 * turn and logs `why=user-turn`; the normal rules apply at its end); an ht opened by then is
 * closed (`handoff-turn close`), as after a failed submit. A user prompt that entered and whose
 * turn has not started yet counts the same (CR-F17), and so does our own submit dropped by our
 * `prompt.submit` hook because one came first; the phase is then `delay` again, so a prompt
 * that never starts its turn lets the delay run again (boundary.ts).
 */
export async function openAndSubmit(d: Deps, sid: string, h: HandoffTurn, dispatchTaken: (n: string) => Promise<boolean>): Promise<boolean> {
  const s = d.state
  // A user prompt came first: its turn started (onTurnStart marks it before its own awaits), or
  // it entered (`prompt.submit` counted it) and its turn is about to start (CR-F17, CR-F25).
  const userFirst = () => s.handoffTurn !== h || s.mainTurnRunning || s.foreignPrompts > 0
  // Checked again after every await.
  const cancelled = () => h.phase !== 'delay' || userFirst()
  const store = storeRuntime(d)
  const runtime: Runtime = { max_calls: String(h.maxCalls), ...store.runtime }
  if (isHalt(h.reason)) runtime.halt_reason = HALT_REASON_TEXT[h.reason]
  if (h.reason === 'idle') runtime.idle_min = IDLE_MIN_TEXT
  const text = submitText(d.name, kindOf(h.reason), runtime, store.drop)
  if (text === undefined) {
    await skipped(d, sid, 'no-asset', null, h.reason)
    return false
  }
  // A rerun after a deferral (boundary.ts) starts with no ht: the earlier one is closed.
  h.ht = null
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
  if (cancelled()) {
    // A user turn started (or a user prompt entered) while the open ran: its record is closed,
    // so `begin` cannot bind it; a cancel row written from here on names it.
    if (opened !== undefined) {
      h.ht = opened
      await handoffTurnClose(d, sid, opened, 'cancelled')
    }
    return true
  }
  if (opened === undefined) {
    await skipped(d, sid, 'open-failed', null, h.reason)
    return false
  }
  // Set before the check below, so a cancel row written from here on names the ht.
  h.ht = opened
  if (!h.stamped) {
    h.stamped = true
    const now = await d.now()
    await d.storeSet(htKey(sid), [...(await recentTurns(d, sid, now)), now])
  }
  // IC-1 D7 (ii): the session this turn was planned for is still the one running (a `/clear`
  // in the delay leaves it to the old conversation): else nothing is submitted, and nothing
  // compacts in its place.
  if ((await d.sessionId()) !== sid) {
    if (s.handoffTurn === h) s.handoffTurn = undefined
    await submitDropped(d, sid, 'handoff-turn')
    await handoffTurnClose(d, sid, opened, 'cancelled')
    return true
  }
  if (cancelled()) {
    await handoffTurnClose(d, sid, opened, 'cancelled')
    return true
  }
  // No await between the check above and the submit call: a user turn that started meanwhile wins.
  h.phase = 'submitted'
  submitPending(s, text)
  s.handoffSubmitting = true
  try {
    await d.submit(text)
  } catch {
    s.handoffSubmitting = false
    submitSettled(s)
    if (userFirst()) {
      // Our prompt.submit hook dropped it: a user prompt came first, and its turn cancels the
      // handoff turn (`why=user-turn`, at its turn.start). Our prompt never runs (CR-F17).
      s.orphanSubmit = false
      if (s.handoffTurn === h) {
        h.phase = 'delay'
        await handoffTurnClose(d, sid, opened, 'cancelled')
      }
      return true
    }
    await skipped(d, sid, 'submit-failed', opened, h.reason)
    await handoffTurnClose(d, sid, opened, 'cancelled')
    return false
  }
  s.handoffSubmitting = false
  return true
}

/**
 * A main `turn.start`: our submit's turn becomes the handoff turn (no checkpoint nudge in it);
 * a user's turn during the delay cancels the handoff turn (`why=user-turn`).
 */
export async function onHandoffTurnStart(d: Deps, sid: string, ours: boolean, turnId: string): Promise<void> {
  const s = d.state
  const h = s.handoffTurn
  if (ours && s.orphanSubmit) {
    // The handoff prompt a user turn cancelled (below) runs now: no checkpoint nudge in it.
    s.orphanSubmit = false
    s.nudgedThisTurn = true
  }
  if (!h) return
  if (h.phase === 'submitted' && ours) {
    h.phase = 'running'
    h.turnSeq = s.turnSeq
    h.turnId = turnId
    h.startedAt = await d.now()
    s.nudgedThisTurn = true
    // §9.3 `again`: one pre-compaction turn per main compaction, whatever its end.
    if (h.reason === 'precompact') s.precompactRan = true
    await log(d, sid, 'handoff_turn_start', {
      ht: h.ht, reason: h.reason, turn_id: turnId, t0: h.t0, max_calls: h.maxCalls, max_tokens: h.allowance,
      ...(h.reason === 'idle' ? { gap_s: await gapSeconds(d) } : {}),
    })
    return
  }
  if (!ours) {
    s.handoffTurn = undefined
    await skipped(d, sid, 'user-turn', h.ht, h.reason)
    // CR-F17: a user prompt that entered beside our submit started first. Our prompt is still
    // queued and runs after it as a plain turn (it is still ours: claimTurn kept it pending);
    // its ht is closed so neither turn's `begin` binds it as a handoff turn's.
    if (h.phase === 'submitted') {
      s.orphanSubmit = s.ourSubmitPending
      if (h.ht !== null) await handoffTurnClose(d, sid, h.ht, 'cancelled')
    }
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
  const store = storeRuntime(d)
  return assembleIf(d.name, 'handoff-turn', [band], store.runtime, store.drop)
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
  /**
   * One plugin compaction, exempt from cooldown (and from halt after a last cycle), `[handoff]`
   * when published.
   */
  | { kind: 'compact'; ht: string; path: string | undefined; stats: Record<string, string | number | null>; exemptHalt: boolean }

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
  if (path !== undefined) {
    s.published = { ht: h.ht, path: shown ?? path }
    s.publishedSinceHuman = true
  }
  const halt = isHalt(h.reason) ? h.reason : undefined
  // DP-4: a thrash or 2-nonok halt that started since the plan still rules out the compaction.
  // §9.3: a pre-compaction turn ending `answer` is always followed by its compaction (`[handoff]`
  // when published, else the full text); §9.4: a pre-idle turn never is.
  const follows = halt !== undefined ? compactsAfter(haltWins(d, halt)) : h.reason === 'precompact'
  const compact = reason === 'answer' && h.race === null && !h.interjected && follows
  // §9.4 `cache_read_share`: the first request's cache-read share is not in `$.session.usage()`;
  // null until a source exists (P-IC-6 measures it from the transcript).
  await log(d, sid, 'handoff_turn_end', {
    ...stats, reason: h.reason, turn_id: h.turnId, interjected: h.interjected, compaction: compact,
    ...(h.reason === 'idle' ? { cache_read_share: null } : {}),
  })
  // The user took the turn over: halt clears at its end as for any user turn (§9.1).
  if (h.interjected) {
    await clearHalt(d, sid)
    return { kind: 'normal' }
  }
  if (reason !== 'answer' || h.race !== null) return { kind: 'done' }
  // The optional turns toast nothing (§9.3: one `handoff_turn_end` row; `/status` counts them).
  if (halt === undefined) return compact ? { kind: 'compact', ht: h.ht, path: shown, stats, exemptHalt: false } : { kind: 'done' }
  const why = HALT_REASON_TEXT[haltWins(d, halt)]
  if (compact) {
    if (shown !== undefined) d.toast(`${d.name}: auto-continue paused (${why}); handoff saved: ${shown}`)
    return { kind: 'compact', ht: h.ht, path: shown, stats, exemptHalt: true }
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

/**
 * A pre-idle turn that `openAndSubmit` deferred because a user prompt came first: the user is
 * back, so it is dropped (no rerun), with its `user-turn` row unless that turn already wrote it.
 */
export async function dropDeferred(d: Deps, sid: string, h: HandoffTurn): Promise<void> {
  if (d.state.handoffTurn !== h) return
  d.state.handoffTurn = undefined
  await skipped(d, sid, 'user-turn', h.ht, h.reason)
}
