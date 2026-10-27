// The pre-idle handoff turn (MOD-SPEC §9.4, IC-1 D5; setting `idle_handoff_turn`, default auto).
// Idle D3 (owner 2026-10-23 02:4x, IA-1..3), reworded by owner xxxxxxxx-17 ("Check outcome at
// 55.5m"): the plugin's turn is off when native idle compaction actually compacts, not when the
// setting merely allows it. With `auto`, at every main turn end the mod (re)arms one timer:
// - Claude Code's own idle compaction off in the settings (deps.nativeIdle `off`): the handoff
//   turn 49 minutes later (the measured native idle time of 54 minutes less a 5-minute lead), as
//   before;
// - on, or unreadable (O-9: "unreadable means check what happened"): an outcome check 55.5 minutes
//   later. Native fires 54:00 after the last request and the cache lasts to minute 60. When the
//   plugin's own records show a main compaction since that turn end it stands down
//   (`native-fired`); otherwise native stayed silent for whatever reason (served `off`, a keypress,
//   a dialog, a failure), one `idle_silent` row counts the break, and the handoff turn runs while
//   the cache is still warm. While agents run (native never compacts then) the plugin compacts
//   the main session itself instead (owner 2026-10-27 03:4x "Compact (Recommended)", which
//   replaces xxxxxxxx-38 "Measure more first"): one shaped compaction through the same self-call
//   as its other compactions (boundary.ts), with an idle dispatch record and resume block and no
//   continue after it (`idle_compact` row).
// `off` arms nothing. One `idle_mode {native, plugin_turn, served_hint}` row whenever the triple
// changes in a load; `served_hint` (2b) is Claude Code's cached server mode, logged only, never
// used to decide. When the turn's checks pass, one plugin-submitted handoff turn runs on the D-18
// machinery (handoff-turn.ts). No plugin compaction and no continue follow it (DP-4; PR-2 P-56 is
// not reviewed); at most one per idle episode.
import type { Deps } from './deps'
import type { Effective } from './config'
import { boundary } from './boundary'
import { compactedSince, dispatchExists } from './compact'
import { effective } from './config'
import { MIN_ALLOWANCE, OPTIONAL_PER_HOUR, SPENT_MARGIN, dropDeferred, maxCalls, newTurn, openAndSubmit, recentTurns, skipped } from './handoff-turn'
import { log } from './log'

/** 54 − 5 minutes after the turn end (IC-1 F3, F6; no key: tuned from P-IC-1 / E-1 `idle_gap_s`). */
export const IDLE_FIRE_MS = 49 * 60000
/** `@idle_min@`: the minutes the `[submit-idle]` text names. */
export const IDLE_MIN_TEXT = '49'
/**
 * Owner xxxxxxxx-17: the outcome check, about 55.5 minutes after the turn end (native fired 54:00
 * after the last request in 5 of 5 cases, within 15 s; its boundary lands 6–16 s later; the
 * 1-hour cache lasts to minute 60).
 */
export const IDLE_CHECK_MS = 55.5 * 60000
/** `@idle_min@` of a handoff turn the outcome check runs. */
export const IDLE_CHECK_MIN_TEXT = '55'
/** Claude Code's default idle floor (`CLAUDE_CODE_IDLE_COMPACT_MIN_TOKENS`, IC-1 F3): `idle_silent` rows from here up only. */
export const NATIVE_IDLE_FLOOR = 200000
/** Every rate-limit window must stay below this share (else `near-limit`). */
export const NEAR_LIMIT_PCT = 90

function dueKey(sid: string): string {
  return `idle_due:${sid}`
}

/** `turn`: the 49-min handoff turn (native off); `check`: the 55.5-min outcome check (native on or unreadable). */
export type IdleKind = 'turn' | 'check'

/** The persisted timer: when it fires, its kind, the turn end it was armed at, and the idle episode it belongs to. */
type Due = { due: number; sid: string; episode: { since: number; done: boolean } | null; kind: IdleKind; end: number | null }

function readDue(v: unknown): Due | undefined {
  if (typeof v !== 'object' || v === null) return undefined
  const o = v as Record<string, unknown>
  if (typeof o.due !== 'number' || typeof o.sid !== 'string') return undefined
  const e = o.episode as Record<string, unknown> | null | undefined
  const episode = e && typeof e.since === 'number' && typeof e.done === 'boolean' ? { since: e.since, done: e.done } : null
  // A record written before the outcome check has no kind: it is the 49-min turn.
  return { due: o.due, sid: o.sid, episode, kind: o.kind === 'check' ? 'check' : 'turn', end: typeof o.end === 'number' ? o.end : null }
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

function schedule(d: Deps, rec: Due, now: number): void {
  cancelIdleTimer(d)
  d.state.idleTimer = d.after(Math.max(0, rec.due - now), () => {
    d.state.idleTimer = undefined
    d.state.inflight = fire(d, rec.sid, rec.kind, rec.end).catch(() => undefined)
  })
}

async function persist(d: Deps, rec: Due): Promise<void> {
  await d.storeSet(dueKey(rec.sid), rec)
  d.state.idleDueSid = rec.sid
  schedule(d, rec, await d.now())
}

/**
 * IA-3 and owner xxxxxxxx-17: what idle arms now, `off` (setting off), `turn` (native idle off)
 * or `check` (native on or unreadable), with one `idle_mode {native, plugin_turn, served_hint}`
 * row when the triple differs from the last one this load wrote. The served hint (2b) is read
 * only where it could matter (the check), and only logged.
 */
async function idleKind(d: Deps, sid: string): Promise<{ kind: IdleKind | 'off'; native: 'on' | 'off' | 'unknown' }> {
  const native = await d.nativeIdle()
  // A headless session has no idle break a plugin compaction could follow: off.
  const kind = d.cfg.idle_handoff_turn !== 'auto' || d.state.headless ? 'off' : native === 'off' ? 'turn' : 'check'
  const served = kind === 'check' ? await d.servedHint() : undefined
  const pluginTurn = kind === 'turn' ? 'on' : kind
  const triple = native + '/' + pluginTurn + '/' + (served ?? '')
  if (d.state.idleMode !== triple) {
    d.state.idleMode = triple
    await log(d, sid, 'idle_mode', { native, plugin_turn: pluginTurn, ...(served !== undefined ? { served_hint: served } : {}) })
  }
  return { kind, native }
}

/**
 * Main `turn.complete` (any origin): (re)arms the timer for `endAt + 49 min` (the turn) or
 * `endAt + 55.5 min` (the outcome check); `off` arms nothing and drops a timer armed before.
 */
export async function armIdle(d: Deps, sid: string, endAt: number): Promise<void> {
  const m = await idleKind(d, sid)
  if (m.kind === 'off') {
    if (d.state.idleTimer !== undefined || d.state.idleDueSid !== undefined) await cancelIdle(d, sid)
    return
  }
  const due = endAt + (m.kind === 'turn' ? IDLE_FIRE_MS : IDLE_CHECK_MS)
  await persist(d, { due, sid, episode: d.state.idleEpisode ?? null, kind: m.kind, end: endAt })
}

/** Once per load (AT-IC-14): a persisted due still in the future for this sid is armed again. */
export async function loadIdle(d: Deps, sid: string): Promise<void> {
  if ((await idleKind(d, sid)).kind === 'off') return
  const rec = readDue(await d.storeGet(dueKey(sid)))
  if (!rec || rec.sid !== sid) return
  const now = await d.now()
  if (rec.due <= now) return
  if (rec.episode && !d.state.idleEpisode) d.state.idleEpisode = rec.episode
  d.state.idleDueSid = sid
  schedule(d, rec, now)
}

type Go = { tokens: number; allowance: number; native: number; calls: number }

type Use = { tokens: number | undefined; rateLimits: { percentUsed: number }[] } | undefined

/** The checks of §9.4 "Fire" from `aborted` on, in order; the first that fails is the skip reason. */
async function laterChecks(d: Deps, sid: string, eff: Effective, u: Use): Promise<string | Go> {
  const s = d.state
  if (!s.lastTurnAnswer) return 'aborted'
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

function isBusy(s: Deps['state']): boolean {
  return s.mainTurnRunning || s.foreignPrompts > 0 || s.busy || s.handoffTurn !== undefined || s.ourSubmitPending
}

async function usageOrNone(d: Deps): Promise<Use> {
  try {
    return await d.usage()
  } catch {
    return undefined
  }
}

/**
 * The agents of this session still running (owner xxxxxxxx-38; the 2026-10-27 idle compaction):
 * the listed subagents and teammates that have not ended, with the agent loops whose turn is
 * running in this load (a workflow's agents are not listed).
 */
export async function agentsRunning(d: Deps): Promise<number> {
  const ids = new Set<string>(d.state.agentTurns)
  for (const id of (await d.agentsAlive()) ?? []) ids.add(id)
  return ids.size
}

/** The 49-min turn: the checks of §9.4 "Fire", in order. */
async function turnBlocked(d: Deps, sid: string): Promise<string | Go> {
  if (!d.cfg.triggers) return 'triggers-off'
  const eff = await effective(d, sid)
  if (eff.disabled) return 'small-window'
  if ((await d.sessionId()) !== sid) return 'session-changed'
  if (isBusy(d.state)) return 'busy'
  return laterChecks(d, sid, eff, await usageOrNone(d))
}

/** The plugin's own idle compaction while agents run (owner 2026-10-27): its `idle_compact` row. */
type Compact = { compact: true; gapS: number; tokens: number; agents: number }

/**
 * Owner 2026-10-27 03:4x ("Compact (Recommended)", replaces xxxxxxxx-38 "Measure more first"):
 * native idle compaction does not run while agents run (EXPERIMENT-RESULTS §11), so the check
 * compacts itself, as native would have: `triggers` on, a window large enough for plugin
 * compactions, a context at Claude Code's idle floor or more (below it native would not compact
 * either), not in halt mode (no plugin compactions there) and no question open.
 */
async function compactBlocked(d: Deps, sid: string, u: Use): Promise<string | undefined> {
  if (!d.cfg.triggers) return 'triggers-off'
  if ((await effective(d, sid)).disabled) return 'small-window'
  if (u?.tokens === undefined || u.tokens < NATIVE_IDLE_FLOOR) return 'small'
  if (d.state.halt.active) return 'halted'
  if (d.state.askOpen > 0) return 'asks-user'
  return undefined
}

/**
 * Owner xxxxxxxx-17: the 55.5-min outcome check. A main compaction since the turn end stands
 * down (`native-fired` for an idle one, else `compacted`); a session that changed or is busy is no
 * idle break. Otherwise native stayed silent: one `idle_silent` row at 200K and more, then, while
 * agents run, the plugin's own idle compaction (owner 2026-10-27) or its skip reason; else the
 * checks of the turn.
 */
async function checkBlocked(d: Deps, sid: string, end: number | null): Promise<string | Go | Compact> {
  if (d.cfg.idle_handoff_turn !== 'auto' || d.state.headless) return 'disabled'
  const c = end === null ? undefined : await compactedSince(d, sid, end)
  if (c !== undefined) return c.idle ? 'native-fired' : 'compacted'
  if ((await d.sessionId()) !== sid) return 'session-changed'
  // A compaction other than ours still running (a slow summary call) is not silence either.
  if (isBusy(d.state) || d.state.nativeCompacting > 0) return 'busy'
  const u = await usageOrNone(d)
  const agents = await agentsRunning(d)
  const gap = end === null ? null : Math.round(((await d.now()) - end) / 1000)
  if (u?.tokens !== undefined && u.tokens >= NATIVE_IDLE_FLOOR) {
    const served = await d.servedHint()
    await log(d, sid, 'idle_silent', { gap_s: gap, tokens: u.tokens, agents, ...(served !== undefined ? { served_hint: served } : {}) })
  }
  if (agents > 0) {
    const why = await compactBlocked(d, sid, u)
    if (why !== undefined) return why
    // compactBlocked found the tokens; the gap is the timer's own (about 3,330 s) when unknown.
    return { compact: true, gapS: gap ?? Math.round(IDLE_CHECK_MS / 1000), tokens: u?.tokens ?? 0, agents }
  }
  if (!d.cfg.triggers) return 'triggers-off'
  const eff = await effective(d, sid)
  if (eff.disabled) return 'small-window'
  return laterChecks(d, sid, eff, u)
}

/**
 * The timer fired: one `handoff_skipped {why, reason: idle}` row, or the handoff turn. A 49-min
 * turn that finds native idle on or unreadable now logs `native-on` / `native-unknown` and checks
 * the outcome at 55.5 min instead (owner xxxxxxxx-17).
 */
export async function fire(d: Deps, sid: string, kind: IdleKind = 'turn', end: number | null = null): Promise<void> {
  const s = d.state
  if (s.idleDueSid === sid) s.idleDueSid = undefined
  await d.storeSet(dueKey(sid), null)
  if (kind === 'turn') {
    const m = await idleKind(d, sid)
    if (m.kind === 'check') {
      await skipped(d, sid, m.native === 'on' ? 'native-on' : 'native-unknown', null, 'idle')
      if (end !== null && end + IDLE_CHECK_MS > (await d.now())) {
        await persist(d, { due: end + IDLE_CHECK_MS, sid, episode: s.idleEpisode ?? null, kind: 'check', end })
      }
      return
    }
    if (m.kind === 'off') {
      await skipped(d, sid, 'disabled', null, 'idle')
      return
    }
  }
  const b = kind === 'check' ? await checkBlocked(d, sid, end) : await turnBlocked(d, sid)
  if (typeof b === 'string') {
    await skipped(d, sid, b, null, 'idle')
    return
  }
  if ('compact' in b) {
    // Owner 2026-10-27: one shaped compaction instead of the turn. A rejection (a turn started,
    // or a headless host that cannot compact between turns) is one `compact_rejected` row from
    // boundary(), never retried: the next check comes only after another main turn end.
    await log(d, sid, 'idle_compact', { gap_s: b.gapS, tokens: b.tokens, agents: b.agents })
    await boundary(d, { idle: { gapS: b.gapS } })
    return
  }
  const h = newTurn('idle', b.tokens, b.allowance, b.native, b.calls)
  if (kind === 'check') h.idleMin = IDLE_CHECK_MIN_TEXT
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
