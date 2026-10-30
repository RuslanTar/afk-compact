// U tests through the kit: keep-warm (decision D-14, 2026-10-30; keepwarm.ts, setting
// `keep_warm_hours`). While the main session is idle and one of its own background jobs is open,
// on the one-hour cache, a hidden fork ping about every 50 minutes keeps the prompt cache warm; the
// idle timer's turn, compaction or check waits, and at the cutoff (or another stop with the cache
// warm) the idle path runs then. Test ids AT-KW-nn. Synthetic values only.
import { expect, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { On } from 'claude-code'
import { hasTag } from '../../hooks/lib/assemble'
import { DEFAULTS, parseOptions } from '../../hooks/lib/config'
import { IDLE_CACHE_MS, IDLE_LAPSE_FRACTION } from '../../hooks/lib/idle'
import { KEEP_WARM_COLD_SHARE, KEEP_WARM_LATEST_MS, KEEP_WARM_PING_MS, forkOutcome } from '../../hooks/lib/keepwarm'
import { SID_A, SID_B, T0, World } from './harness.test'

const IDLE = hasTag('handoff-turn', 'submit-idle')
const ON = { idle_handoff_turn: 'auto', precompact_turn: 'code', keep_warm_hours: 2 }
const NATIVE_OFF: Record<string, unknown> = { idleCompaction: false }
const MIN = 60000
const LIMITS = [{ kind: 'five_hour', percentUsed: 12 }, { kind: 'seven_day', percentUsed: 30 }]
const RUNNING = [{ id: 'sub-1', status: 'running' }]
const WARM = { input_tokens: 11, output_tokens: 4, cache_read_input_tokens: 228161, cache_creation_input_tokens: 9 }
const KEY = `idle_due:${SID_A}`
const COLD = { input_tokens: 11, output_tokens: 4, cache_read_input_tokens: 0, cache_creation_input_tokens: 228170 }

type Answer = { isAnswered: boolean; reason?: string; text?: string; usage?: unknown; status?: number; error?: string }

/** Every `$.model.fork`, with the clock minute it came at (since `t0`), answered by `answer` (by call order). */
function forks(on: On, w: World, answer: (i: number) => Answer = () => ({ isAnswered: true, text: 'OK', usage: WARM })): { at: number[]; prompts: string[]; t0: number } {
  const out = { at: [] as number[], prompts: [] as string[], t0: 0 }
  on('model.fork', (_$, e) => {
    out.at.push(Math.round((w.clock.now() - out.t0) / MIN))
    out.prompts.push(e.prompt)
    return { value: answer(out.at.length - 1) } as never
  })
  return out
}

function world(on: On, policy: Record<string, unknown> = NATIVE_OFF): World {
  const w = new World().install(on)
  w.policy = policy
  w.rateLimits = LIMITS
  w.agents = RUNNING
  return w
}

/** A person's turn that ends at 260K; returns the clock at its end. */
async function humanTurn($: Engine, w: World, tokens = 260000): Promise<number> {
  await w.userTurn($)
  w.tokens = tokens
  await w.turnEnd($)
  return w.clock.now()
}

/** Moves the clock minute by minute to `minutes` after `t0` (each tick of the plugin's timers runs). */
async function until(w: World, t0: number, minutes: number): Promise<void> {
  while (w.clock.now() + MIN <= t0 + minutes * MIN) await w.advance(MIN)
  const rest = t0 + minutes * MIN - w.clock.now()
  if (rest > 0) await w.advance(rest)
}

const pings = (w: World) => w.rowsOf('keep_warm_ping').map(r => [r.result, r.n])
const stops = (w: World) => w.rowsOf('keep_warm_stop').map(r => [r.why, r.handover, r.pings])
const skips = (w: World) => w.rowsOf('handoff_skipped').filter(r => r.reason === 'idle').map(r => [r.why, r.kind])
const ic = (w: World) => w.rowsOf('idle_compact')
const selfCompacts = (w: World) => w.compacts.filter(c => c.trigger === undefined).length

/** Raise a classic hook event the way the engine does (the Stop's in-flight background tasks). */
async function stopHook($: Engine, e: Record<string, unknown>): Promise<void> {
  await ($ as unknown as { classic: Record<string, (e: unknown) => Promise<unknown>> }).classic['Stop']?.({ stop_hook_active: false, session_id: SID_A, ...e })
}

// ---- The setting

test('AT-KW-01 options: keep_warm_hours default 6; 0 is off; fractions as given; clamped to 0..24 with config_clamped', () => {
  expect(DEFAULTS.keep_warm_hours).toBe(6)
  expect(parseOptions({}).keep_warm_hours).toBe(6)
  expect(parseOptions({ keep_warm_hours: 0 } as never).keep_warm_hours).toBe(0)
  expect(parseOptions({ keep_warm_hours: '3' } as never).keep_warm_hours).toBe(3)
  // Not floored (review finding 3): 0.5 stays 0.5 (not off), 1.5 stays 1.5, with no clamp note.
  const half = parseOptions({ keep_warm_hours: 0.5 } as never)
  expect([half.keep_warm_hours, half.notes.clamped]).toEqual([0.5, []])
  expect(parseOptions({ keep_warm_hours: '1.5' } as never).keep_warm_hours).toBe(1.5)
  // As Number() reads a string (the helper's /status reads it alike, AT-KW-20): hex 16; a sign before 0x is no number.
  expect(parseOptions({ keep_warm_hours: '0x10' } as never).keep_warm_hours).toBe(16)
  expect(parseOptions({ keep_warm_hours: '-0x2' } as never).keep_warm_hours).toBe(6)
  const hi = parseOptions({ keep_warm_hours: 30 } as never)
  expect([hi.keep_warm_hours, hi.notes.clamped]).toEqual([24, [{ key: 'keep_warm_hours', configured: 30, effective: 24 }]])
  const lo = parseOptions({ keep_warm_hours: -1 } as never)
  expect([lo.keep_warm_hours, lo.notes.clamped]).toEqual([0, [{ key: 'keep_warm_hours', configured: -1, effective: 0 }]])
  expect(parseOptions({ keep_warm_hours: '${user_config.keep_warm_hours}' } as never).keep_warm_hours).toBe(6)
})

test('AT-KW-02 timing: the ping at 50 min (at most 55), never later than the idle path\'s 58-min lapse bound', () => {
  expect(KEEP_WARM_PING_MS).toBe(50 * MIN)
  expect(KEEP_WARM_PING_MS <= 55 * MIN).toBe(true)
  expect(KEEP_WARM_LATEST_MS).toBe(IDLE_LAPSE_FRACTION * IDLE_CACHE_MS)
  expect(KEEP_WARM_LATEST_MS).toBe(58 * MIN)
})

test('AT-KW-02 forkOutcome: warm at a cache read share of the prefix at or above the cold share; fork-miss below (the fork did not read the main prefix); no-text classes', () => {
  expect(KEEP_WARM_COLD_SHARE).toBe(0.5)
  expect(forkOutcome({ isAnswered: true, text: 'OK', usage: WARM })).toEqual({ result: 'warm', read: 228161, created: 9 })
  expect(forkOutcome({ isAnswered: true, text: 'OK', usage: COLD })).toEqual({ result: 'fork-miss', read: 0, created: 228170 })
  expect(forkOutcome({ isAnswered: false, reason: 'empty-reply', usage: WARM }).result).toBe('warm')
  expect(forkOutcome({ isAnswered: false, reason: 'nothing-to-fork' }).result).toBe('nothing-to-fork')
  expect(forkOutcome({ isAnswered: false, reason: 'api-error', status: 529, error: 'overloaded', usage: WARM })).toEqual({ result: 'api-error', read: 228161, created: 9, status: 529 })
  expect(forkOutcome({ isAnswered: false, reason: 'aborted', usage: WARM }).result).toBe('aborted')
  expect(forkOutcome(undefined).result).toBe('error')
  expect(forkOutcome({ isAnswered: true, text: 'OK' }).result).toBe('fork-miss')
})

// ---- Warming and the hand-over at the cutoff

test('AT-KW-03: vetoed, an agent running: pings at 50 and 100 min, the 54-min compaction waits (keep-warm), at the cutoff (2 h) it runs while warm', { options: ON }, async ($, on) => {
  const w = world(on)
  const f = forks(on, w)
  await w.start($)
  const t0 = await humanTurn($, w)
  f.t0 = t0
  await until(w, t0, 49)
  expect(f.at).toEqual([])
  await until(w, t0, 54)
  expect(f.at).toEqual([50])
  expect(f.prompts[0]).toBe('Reply with the single word OK.')
  expect(skips(w)).toEqual([['keep-warm', 'compact']])
  expect([ic(w).length, selfCompacts(w)]).toEqual([0, 0])
  expect(w.rowsOf('keep_warm_start').map(r => [r.jobs, r.gap_s, r.hours, r.windows])).toEqual([[1, 3000, 2, 2]])
  await until(w, t0, 149)
  expect(f.at).toEqual([50, 100])
  expect(pings(w)).toEqual([['warm', 1], ['warm', 2]])
  expect(w.rowsOf('keep_warm_ping').map(r => [r.cache_read, r.cache_creation, r.since_s, r.gap_s])).toEqual([[228161, 9, 3000, 3000], [228161, 9, 3000, 6000]])
  expect(selfCompacts(w)).toBe(0)
  await until(w, t0, 150)
  expect(stops(w)).toEqual([['cutoff', true, 2]])
  expect(f.at).toEqual([50, 100])
  expect(ic(w).map(r => [r.at, r.gap_s, r.agents, r.late_s])).toEqual([['timer', 9000, 1, 0]])
  expect(selfCompacts(w)).toBe(1)
  expect([w.submits.length, w.rowsOf('continue').length]).toEqual([0, 0])
  // Nothing more in this gap.
  await until(w, t0, 300)
  expect([f.at.length, selfCompacts(w), stops(w).length]).toEqual([2, 1, 1])
})

test('AT-KW-04: native on, an agent running: the 55.5-min check waits; at the cutoff it compacts at the check while warm (agents 1)', { options: ON }, async ($, on) => {
  const w = world(on, {})
  const f = forks(on, w)
  await w.start($)
  const t0 = await humanTurn($, w)
  f.t0 = t0
  await until(w, t0, 57)
  expect(skips(w)).toEqual([['keep-warm', 'check']])
  expect(selfCompacts(w)).toBe(0)
  await until(w, t0, 150)
  expect(f.at).toEqual([50, 100])
  expect(stops(w)).toEqual([['cutoff', true, 2]])
  expect(ic(w).map(r => [r.at, r.gap_s, r.agents])).toEqual([['check', 9000, 1]])
  expect(selfCompacts(w)).toBe(1)
})

test('AT-KW-05: automatic compaction off, an agent running: the 49-min handoff turn waits; at the cutoff the turn runs (or no-asset), and its end starts no new warming', { options: ON }, async ($, on) => {
  const w = world(on, { autoCompactEnabled: false })
  const f = forks(on, w)
  await w.start($)
  const t0 = await humanTurn($, w)
  f.t0 = t0
  await until(w, t0, 50)
  expect(skips(w)).toEqual([['keep-warm', 'turn']])
  expect(w.submits.length).toBe(0)
  await until(w, t0, 150)
  expect(stops(w)).toEqual([['cutoff', true, 2]])
  if (IDLE) {
    expect(w.submits.length).toBe(1)
    // The handoff turn the hand-over submitted runs and ends: no new gap warms after it.
    await w.turnStart($, w.submits[0])
    await w.turnEnd($)
    await until(w, t0, 300)
    expect(f.at).toEqual([50, 100])
  } else expect(skips(w)).toEqual([['keep-warm', 'turn'], ['no-asset', 'turn']])
  expect(selfCompacts(w)).toBe(0)
})

test('AT-KW-06: a background shell from the main Stop counts as a job; a Monitor or an ended task does not', { options: ON }, async ($, on) => {
  const w = world(on)
  w.agents = []
  const f = forks(on, w)
  await w.start($)
  await w.userTurn($)
  w.tokens = 260000
  await stopHook($, {
    background_tasks: [
      { id: 'bsh1', type: 'shell', status: 'running', description: 'x' }, { id: 'm1', type: 'monitor', status: 'running', description: 'x' },
      { id: 'bsh0', type: 'shell', status: 'completed', description: 'x' }, { id: 'cr1', type: 'cron', status: 'running', description: 'x' },
    ],
  })
  await w.turnEnd($)
  f.t0 = w.clock.now()
  await until(w, f.t0, 51)
  expect(f.at).toEqual([50])
  expect(w.rowsOf('keep_warm_start').map(r => r.jobs)).toEqual([1])
})

// ---- Never warming

for (const c of [
  { name: 'no background job open (plain user absence)', set: (w: World) => { w.agents = [] } },
  { name: 'only a Monitor in the Stop list', set: (w: World) => { w.agents = [] }, stop: [{ id: 'm1', type: 'monitor', status: 'running' }] },
  { name: 'the five-minute cache: no plan window', set: (w: World) => { w.rateLimits = [] } },
  { name: 'the five-minute cache: promptCacheTtl 5m', set: (w: World) => { w.policy = { ...NATIVE_OFF, promptCacheTtl: '5m' } } },
  { name: 'the five-minute cache: CLAUDE_CODE_PROMPT_CACHE_TTL=5m', set: (w: World) => { w.env = { CLAUDE_CODE_PROMPT_CACHE_TTL: '5m' } } },
  { name: 'a usage window at 92%', set: (w: World) => { w.rateLimits = [{ kind: 'five_hour', percentUsed: 92 }, { kind: 'seven_day', percentUsed: 30 }] } },
]) {
  test(`AT-KW-07: ${c.name}: no fork, no keep-warm row; the idle path runs as before`, { options: ON }, async ($, on) => {
    const w = world(on)
    c.set(w)
    const f = forks(on, w)
    await w.start($)
    await w.userTurn($)
    w.tokens = 260000
    if (c.stop) await stopHook($, { background_tasks: c.stop })
    await w.turnEnd($)
    f.t0 = w.clock.now()
    await until(w, f.t0, 120)
    expect(f.at).toEqual([])
    expect([w.rowsOf('keep_warm_start').length, w.rowsOf('keep_warm_ping').length, w.rowsOf('keep_warm_stop').length]).toEqual([0, 0, 0])
    expect(skips(w).filter(s => s[0] === 'keep-warm')).toEqual([])
  })
}

test('AT-KW-07: keep_warm_hours 0: no fork with an agent running; the idle compaction runs at 54 min as before', { options: { ...ON, keep_warm_hours: 0 } }, async ($, on) => {
  const w = world(on)
  const f = forks(on, w)
  await w.start($)
  const t0 = await humanTurn($, w)
  f.t0 = t0
  await until(w, t0, 55)
  expect(f.at).toEqual([])
  expect(ic(w).map(r => r.at)).toEqual(['timer'])
  expect(selfCompacts(w)).toBe(1)
})

test('AT-KW-08: the explicit one-hour TTL with no usage windows readable: it warms (the limit guard is skipped)', { options: ON }, async ($, on) => {
  const w = world(on)
  w.rateLimits = []
  w.env = { CLAUDE_CODE_PROMPT_CACHE_TTL: '1h' }
  const f = forks(on, w)
  await w.start($)
  const t0 = await humanTurn($, w)
  f.t0 = t0
  await until(w, t0, 101)
  expect(f.at).toEqual([50, 100])
  // No usage window read: the start row says so (the near-limit guard is skipped).
  expect(w.rowsOf('keep_warm_start').map(r => r.windows)).toEqual([0])
})

// ---- Stop rules

test('AT-KW-09: a main turn starts: warming stops (turn), the deferred compaction is dropped, no ping after; the next gap warms again', { options: ON }, async ($, on) => {
  const w = world(on)
  const f = forks(on, w)
  await w.start($)
  const t0 = await humanTurn($, w)
  f.t0 = t0
  await until(w, t0, 70)
  await w.userTurn($, 'Agent sub-1 finished.', 'task-notification')
  expect(stops(w)).toEqual([['turn', false, 1]])
  await w.turnEnd($)
  const t1 = w.clock.now()
  await until(w, t1, 49)
  expect(f.at).toEqual([50])
  expect(selfCompacts(w)).toBe(0)
  await until(w, t1, 51)
  expect(f.at).toEqual([50, 120])
})

test('AT-KW-10: no background job open at a ping (the agent ended, no result turn yet): stop no-jobs, the compaction runs at once while warm', { options: ON }, async ($, on) => {
  const w = world(on)
  const f = forks(on, w)
  await w.start($)
  const t0 = await humanTurn($, w)
  f.t0 = t0
  await until(w, t0, 60)
  w.agents = [{ id: 'sub-1', status: 'completed' }]
  await until(w, t0, 100)
  expect(f.at).toEqual([50])
  expect(stops(w)).toEqual([['no-jobs', true, 1]])
  expect(ic(w).map(r => [r.at, r.gap_s, r.agents])).toEqual([['timer', 6000, 0]])
  expect(selfCompacts(w)).toBe(1)
})

test('AT-KW-11: a usage window reaches 90% between pings: stop near-limit, the deferred compaction gets its own near-limit skip', { options: ON }, async ($, on) => {
  const w = world(on)
  const f = forks(on, w)
  await w.start($)
  const t0 = await humanTurn($, w)
  f.t0 = t0
  await until(w, t0, 60)
  w.rateLimits = [{ kind: 'five_hour', percentUsed: 90 }, { kind: 'seven_day', percentUsed: 30 }]
  await until(w, t0, 100)
  expect(f.at).toEqual([50])
  expect(stops(w)).toEqual([['near-limit', true, 1]])
  expect(skips(w)).toEqual([['keep-warm', 'compact'], ['near-limit', 'compact']])
  expect(selfCompacts(w)).toBe(0)
})

test('AT-KW-12: the cache switched to five minutes between pings: stop ttl-5m with the hand-over', { options: ON }, async ($, on) => {
  const w = world(on)
  const f = forks(on, w)
  await w.start($)
  const t0 = await humanTurn($, w)
  f.t0 = t0
  await until(w, t0, 60)
  w.policy = { ...NATIVE_OFF, promptCacheTtl: '5m' }
  await until(w, t0, 100)
  expect(f.at).toEqual([50])
  expect(stops(w)).toEqual([['ttl-5m', true, 1]])
  expect(skips(w)).toEqual([['keep-warm', 'compact'], ['ttl-5m', 'compact']])
})

test('AT-KW-13: a later ping misses the main prefix (cache read near zero): stop fork-miss; the main cache is as warm as the last warm ping left it, so the held compaction goes back to the idle path and runs', { options: ON }, async ($, on) => {
  const w = world(on)
  const f = forks(on, w, i => ({ isAnswered: true, text: 'OK', usage: i === 0 ? WARM : COLD }))
  await w.start($)
  const t0 = await humanTurn($, w)
  f.t0 = t0
  await until(w, t0, 150)
  expect(f.at).toEqual([50, 100])
  expect(pings(w)).toEqual([['warm', 1], ['fork-miss', 1]])
  expect(w.rowsOf('keep_warm_ping')[1]?.cache_read).toBe(0)
  expect(stops(w)).toEqual([['fork-miss', true, 1]])
  expect(ic(w).map(r => [r.at, r.gap_s])).toEqual([['timer', 6000]])
  expect(selfCompacts(w)).toBe(1)
})

test('AT-KW-13 (REV2-C): the first ping misses the main prefix: the same rule, nothing held yet, so the idle timer\'s compaction runs at 54 as armed', { options: ON }, async ($, on) => {
  const w = world(on)
  const f = forks(on, w, () => ({ isAnswered: true, text: 'OK', usage: COLD }))
  await w.start($)
  const t0 = await humanTurn($, w)
  f.t0 = t0
  await until(w, t0, 120)
  expect(f.at).toEqual([50])
  expect(stops(w)).toEqual([['fork-miss', false, 0]])
  expect(skips(w)).toEqual([])
  expect(ic(w).map(r => [r.at, r.gap_s])).toEqual([['timer', 3240]])
  expect(selfCompacts(w)).toBe(1)
})

test('AT-KW-14: nothing-to-fork while a request is out (a compaction starting beside the ping) is tried again at no cost once it ended; the next ping counts from the one that warmed', { options: ON }, async ($, on) => {
  const w = world(on)
  let release: () => void = () => undefined
  const f = forks(on, w, i => {
    if (i > 0) return { isAnswered: true, text: 'OK', usage: WARM }
    w.compactMode = { skip: 'nothing to compact' }
    w.compactGate = new Promise<void>(r => { release = r })
    void $.session.compact({ trigger: 'auto', messages: [{ role: 'user', text: 'hello', toolUses: [] }] } as never)
    return { isAnswered: false, reason: 'nothing-to-fork' }
  })
  await w.start($)
  const t0 = await humanTurn($, w)
  f.t0 = t0
  await until(w, t0, 52.5)
  expect(f.at).toEqual([50])
  release()
  await w.settle()
  await until(w, t0, 103)
  expect(f.at).toEqual([50, 53, 103])
  expect(pings(w)).toEqual([['nothing-to-fork', 0], ['warm', 1], ['warm', 2]])
  expect(stops(w)).toEqual([])
})

const OVERLOADED: Answer = { isAnswered: false, reason: 'api-error', status: 529, error: 'overloaded', usage: { input_tokens: 0, output_tokens: 0, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 } }

test('AT-KW-15 (the held record\'s deadline): retries never pass the held compaction\'s 58-min lapse bound: after the one at 58, stop deadline with the hand-over, the compaction runs then', { options: ON }, async ($, on) => {
  const w = world(on)
  const f = forks(on, w, () => OVERLOADED)
  await w.start($)
  const t0 = await humanTurn($, w)
  f.t0 = t0
  await until(w, t0, 70)
  expect(f.at).toEqual([50, 51, 52, 53, 54, 55, 56, 57, 58])
  expect(w.rowsOf('keep_warm_ping').map(r => r.status)).toEqual(Array(9).fill(529))
  expect(stops(w)).toEqual([['deadline', true, 0]])
  expect(ic(w).map(r => [r.at, r.gap_s])).toEqual([['timer', 3480]])
  expect(selfCompacts(w)).toBe(1)
  await until(w, t0, 200)
  expect(f.at.length).toBe(9)
})

test('AT-KW-15: the held handoff turn\'s deadline is its 55.5-min bound: after the retry at 55, stop deadline with the hand-over, the turn runs then', { options: ON }, async ($, on) => {
  const w = world(on, { autoCompactEnabled: false })
  const f = forks(on, w, () => OVERLOADED)
  await w.start($)
  const t0 = await humanTurn($, w)
  f.t0 = t0
  await until(w, t0, 70)
  expect(f.at).toEqual([50, 51, 52, 53, 54, 55])
  expect(stops(w)).toEqual([['deadline', true, 0]])
  if (IDLE) expect(w.submits.length).toBe(1)
  else expect(skips(w)).toEqual([['keep-warm', 'turn'], ['no-asset', 'turn']])
})

test('AT-KW-16: the session ends while warming: stop session-end, no ping after', { options: ON }, async ($, on) => {
  const w = world(on)
  const f = forks(on, w)
  await w.start($)
  const t0 = await humanTurn($, w)
  f.t0 = t0
  await until(w, t0, 60)
  await $.session.end({ sessionId: SID_A, reason: 'prompt_input_exit' } as never)
  await w.settle()
  expect(stops(w)).toEqual([['session-end', false, 1]])
  await until(w, t0, 200)
  expect(f.at).toEqual([50])
  expect(selfCompacts(w)).toBe(0)
})

test('AT-KW-17: Claude Code compacted the session during the gap: warming stops (compacted), no hand-over', { options: ON }, async ($, on) => {
  const w = world(on, {})
  const f = forks(on, w)
  await w.start($)
  const t0 = await humanTurn($, w)
  f.t0 = t0
  await until(w, t0, 60)
  await $.session.compact({ trigger: 'auto', messages: [{ role: 'user', text: 'hello', toolUses: [] }] } as never)
  await w.settle()
  await until(w, t0, 101)
  expect(f.at).toEqual([50])
  expect(stops(w)).toEqual([['compacted', false, 1]])
})

// ---- Review fixes (fix round 1)

test('AT-KW-18 (finding 1): a realistic Stop lists the running subagent; it ends with no result turn: stop no-jobs at the next ping, the compaction runs while warm', { options: ON }, async ($, on) => {
  const w = world(on)
  const f = forks(on, w)
  await w.start($)
  await w.userTurn($)
  w.tokens = 260000
  await stopHook($, { background_tasks: [{ id: 'sub-1', type: 'subagent', status: 'running', description: 'x', agent_type: 'general-purpose' }] })
  await w.turnEnd($)
  f.t0 = w.clock.now()
  await until(w, f.t0, 60)
  w.agents = [{ id: 'sub-1', status: 'completed' }]
  await until(w, f.t0, 160)
  expect(f.at).toEqual([50])
  expect(stops(w)).toEqual([['no-jobs', true, 1]])
  expect(selfCompacts(w)).toBe(1)
})

test('AT-KW-18: a task a notification reported ended does not count, though the next Stop still lists it running', { options: ON }, async ($, on) => {
  const w = world(on)
  w.agents = []
  const f = forks(on, w)
  await w.start($)
  await w.userTurn($)
  w.tokens = 260000
  const shell = [{ id: 'bsh1', type: 'shell', status: 'running', description: 'x' }]
  await stopHook($, { background_tasks: shell })
  await w.turnEnd($)
  const t0 = w.clock.now()
  f.t0 = t0
  await until(w, t0, 60)
  expect(f.at).toEqual([50])
  await w.userTurn($, '<task-notification><task-id>bsh1</task-id><status>completed</status><summary>done</summary></task-notification>', 'task-notification')
  await stopHook($, { background_tasks: shell })
  await w.turnEnd($)
  const t1 = w.clock.now()
  await until(w, t1, 120)
  expect(f.at).toEqual([50])
  expect(w.rowsOf('keep_warm_start').length).toBe(1)
})

test('AT-KW-19 (finding 2): while warming the store holds the idle record (due at the next ping, anchored at the last warm one), so a reload can adopt it; a turn start clears it', { options: ON }, async ($, on) => {
  const w = world(on)
  const f = forks(on, w)
  await w.start($)
  const t0 = await humanTurn($, w)
  f.t0 = t0
  await until(w, t0, 60)
  const at60 = w.storeGet(KEY) as Record<string, unknown>
  expect([at60.cancelled, at60.kind, at60.due, at60.warm, at60.anchor, at60.held]).toEqual([undefined, 'compact', t0 + 100 * MIN, t0 + 50 * MIN, t0 + 50 * MIN, { start: t0, pings: 1 }])
  await until(w, t0, 110)
  const at110 = w.storeGet(KEY) as Record<string, unknown>
  expect([at110.due, at110.warm, at110.held]).toEqual([t0 + 150 * MIN, t0 + 100 * MIN, { start: t0, pings: 2 }])
  await w.userTurn($, 'Agent sub-1 finished.', 'task-notification')
  expect((w.storeGet(KEY) as Record<string, unknown>).cancelled).toBe(true)
  expect(stops(w)).toEqual([['turn', false, 2]])
})

test('AT-KW-19: a load that adopts a held record (a reload while warming): one keep_warm_stop reload row, then the compaction at its due while warm', { options: ON }, async ($, on) => {
  const probe = new World()
  const store = {
    [KEY]: {
      kind: 'compact', due: T0 + 40 * MIN, sid: SID_A, end: T0 - 60 * MIN, anchor: T0 - 10 * MIN, warm: T0 - 10 * MIN, load: 'old', tokens: 260000, ttl: '1h', pct: 30,
      cc: probe.version.version, model: probe.model, answer: true, published: false, episode: { since: T0 - 60 * MIN, done: false }, held: { start: T0 - 60 * MIN, pings: 1 },
    },
  }
  const w = new World().install(on, store)
  w.policy = NATIVE_OFF
  w.rateLimits = LIMITS
  w.agents = RUNNING
  w.tokens = 260000
  const f = forks(on, w)
  await w.start($)
  expect(stops(w)).toEqual([['reload', true, 1]])
  expect(w.rowsOf('keep_warm_stop')[0]?.gap_s).toBe(3600)
  expect((w.storeGet(KEY) as Record<string, unknown>).held).toBe(undefined)
  await w.advance(39 * MIN)
  expect(selfCompacts(w)).toBe(0)
  await w.advance(2 * MIN)
  expect(ic(w).map(r => [r.at, r.agents, r.adopted])).toEqual([['timer', 1, true]])
  expect(selfCompacts(w)).toBe(1)
  expect(f.at).toEqual([])
})

test('AT-KW-19: SessionEnd other while warming: stop session-end with the record kept for the next process (no held mark, due at the next ping)', { options: ON }, async ($, on) => {
  const w = world(on)
  const f = forks(on, w)
  await w.start($)
  const t0 = await humanTurn($, w)
  f.t0 = t0
  await until(w, t0, 60)
  await $.session.end({ sessionId: SID_A, reason: 'other' } as never)
  await w.settle()
  expect(stops(w)).toEqual([['session-end', true, 1]])
  const v = w.storeGet(KEY) as Record<string, unknown>
  expect([v.cancelled, v.due, v.warm, v.held]).toEqual([undefined, t0 + 100 * MIN, t0 + 50 * MIN, undefined])
  await until(w, t0, 200)
  expect(f.at).toEqual([50])
})

test('AT-KW-21 (finding 4): the main model changed since the gap began (/model sends no request): stop prefix-changed before forking; the idle path\'s G3a skips the compaction', { options: ON }, async ($, on) => {
  const w = world(on)
  const f = forks(on, w)
  await w.start($)
  const t0 = await humanTurn($, w)
  f.t0 = t0
  await until(w, t0, 60)
  w.model = 'claude-other-model'
  await until(w, t0, 101)
  expect(f.at).toEqual([50])
  expect(stops(w)).toEqual([['prefix-changed', true, 1]])
  expect(skips(w)).toEqual([['keep-warm', 'compact'], ['prefix-changed', 'compact']])
  expect(selfCompacts(w)).toBe(0)
})

test('AT-KW-21: the Claude Code version changed since the gap began: stop prefix-changed, no fork', { options: ON }, async ($, on) => {
  const w = world(on)
  const f = forks(on, w)
  await w.start($)
  const t0 = await humanTurn($, w)
  f.t0 = t0
  await until(w, t0, 60)
  w.version = { version: '2.1.399' }
  await until(w, t0, 101)
  expect(f.at).toEqual([50])
  expect(stops(w)).toEqual([['prefix-changed', true, 1]])
})

test('AT-KW-22 (finding 3): keep_warm_hours 0.5: the cutoff comes before the first ping, so the gap never warms; the idle compaction runs at 54 min', { options: { ...ON, keep_warm_hours: 0.5 } }, async ($, on) => {
  const w = world(on)
  const f = forks(on, w)
  await w.start($)
  const t0 = await humanTurn($, w)
  f.t0 = t0
  await until(w, t0, 56)
  expect(f.at).toEqual([])
  expect(w.rowsOf('keep_warm_start').length).toBe(0)
  expect(ic(w).map(r => r.at)).toEqual(['timer'])
  expect(selfCompacts(w)).toBe(1)
})

test('AT-KW-22: keep_warm_hours 1.5: one ping at 50, the cutoff at the next due (100 min), with the hand-over', { options: { ...ON, keep_warm_hours: 1.5 } }, async ($, on) => {
  const w = world(on)
  const f = forks(on, w)
  await w.start($)
  const t0 = await humanTurn($, w)
  f.t0 = t0
  await until(w, t0, 101)
  expect(f.at).toEqual([50])
  expect(stops(w)).toEqual([['cutoff', true, 1]])
  expect(selfCompacts(w)).toBe(1)
})

test('AT-KW-23 (M16): a compaction under way at the ping: no fork beside it; once it ran, the gap stops warming (never started: no rows)', { options: ON }, async ($, on) => {
  const w = world(on)
  const f = forks(on, w)
  await w.start($)
  const t0 = await humanTurn($, w)
  f.t0 = t0
  await until(w, t0, 49)
  let release: () => void = () => undefined
  w.compactGate = new Promise<void>(r => { release = r })
  const p = $.session.compact({ trigger: 'auto', messages: [{ role: 'user', text: 'hello', toolUses: [] }] } as never)
  await until(w, t0, 52)
  expect(f.at).toEqual([])
  release()
  await p
  await w.settle()
  await until(w, t0, 60)
  expect(f.at).toEqual([])
  expect([w.rowsOf('keep_warm_start').length, w.rowsOf('keep_warm_stop').length]).toEqual([0, 0])
})

test('AT-KW-24 (M17): a fork the engine refuses (a hook\'s deny): stop error with the hand-over, the compaction runs while warm', { options: ON }, async ($, on) => {
  const w = world(on)
  const at: number[] = []
  let t0 = 0
  on('model.fork', () => {
    at.push(Math.round((w.clock.now() - t0) / MIN))
    if (at.length > 1) throw new Error('denied by a hook')
    return { value: { isAnswered: true, text: 'OK', usage: WARM } } as never
  })
  await w.start($)
  t0 = await humanTurn($, w)
  await until(w, t0, 102)
  expect(at).toEqual([50, 100])
  expect(pings(w)).toEqual([['warm', 1], ['error', 1]])
  expect(stops(w)).toEqual([['error', true, 1]])
  expect(selfCompacts(w)).toBe(1)
})

test('AT-KW-25 (M20): the session id changed during the gap: stop session-changed, no hand-over, no fork after', { options: ON }, async ($, on) => {
  const w = world(on)
  const f = forks(on, w)
  await w.start($)
  const t0 = await humanTurn($, w)
  f.t0 = t0
  await until(w, t0, 60)
  w.sid = SID_B
  await until(w, t0, 101)
  expect(stops(w)).toEqual([['session-changed', false, 1]])
  expect((w.storeGet(KEY) as Record<string, unknown>).cancelled).toBe(true)
  await until(w, t0, 160)
  expect(f.at).toEqual([50])
  expect(selfCompacts(w)).toBe(0)
})

test('AT-KW-26 (M26): automatic compaction off and no job open: the 49-min handoff turn runs as before, keep-warm holds nothing', { options: ON }, async ($, on) => {
  const w = world(on, { autoCompactEnabled: false })
  w.agents = []
  const f = forks(on, w)
  await w.start($)
  const t0 = await humanTurn($, w)
  f.t0 = t0
  await until(w, t0, 51)
  expect(f.at).toEqual([])
  expect(skips(w).filter(s => s[0] === 'keep-warm')).toEqual([])
  expect([w.rowsOf('keep_warm_start').length, w.rowsOf('keep_warm_stop').length]).toEqual([0, 0])
  if (IDLE) expect(w.submits.length).toBe(1)
  else expect(skips(w)).toEqual([['no-asset', 'turn']])
})

test('AT-KW-27 (finding 7): a prompt entering that a peer hook drops starts no turn: the ping timer runs again, the ping comes at 50', { options: ON }, async ($, on) => {
  const w = world(on)
  const f = forks(on, w)
  await w.start($)
  const t0 = await humanTurn($, w)
  f.t0 = t0
  await until(w, t0, 49)
  w.dropIf = () => 'a peer dropped it'
  const r = await $.prompt.submit({ text: 'hello', origin: { kind: 'composer' } } as never)
  expect(r.drop).toBe('a peer dropped it')
  await until(w, t0, 101)
  expect(f.at).toEqual([50, 100])
})

// ---- Review fixes (fix round 3)

test('AT-KW-28 (REV2-A): nothing-to-fork with no request of the main session out (no snapshot to fork): stop at once, no retry; nothing held yet, so the compaction runs at 54 as armed', { options: ON }, async ($, on) => {
  const w = world(on)
  const f = forks(on, w, () => ({ isAnswered: false, reason: 'nothing-to-fork' }))
  await w.start($)
  const t0 = await humanTurn($, w)
  f.t0 = t0
  await until(w, t0, 120)
  expect(f.at).toEqual([50])
  expect(stops(w)).toEqual([['nothing-to-fork', false, 0]])
  expect(ic(w).map(r => r.at)).toEqual(['timer'])
  expect(selfCompacts(w)).toBe(1)
})

test('AT-KW-28 (REV2-A2): the same with the 49-min handoff turn held: stop nothing-to-fork with the hand-over, the turn runs at once', { options: ON }, async ($, on) => {
  const w = world(on, { autoCompactEnabled: false })
  const f = forks(on, w, () => ({ isAnswered: false, reason: 'nothing-to-fork' }))
  await w.start($)
  const t0 = await humanTurn($, w)
  f.t0 = t0
  await until(w, t0, 60)
  expect(f.at).toEqual([50])
  expect(stops(w)).toEqual([['nothing-to-fork', true, 0]])
  if (IDLE) expect(w.submits.length).toBe(1)
  else expect(skips(w)).toEqual([['keep-warm', 'turn'], ['no-asset', 'turn']])
})

test('AT-KW-29: a compaction under way from before the next ping to past the 58-min bound: no fork beside it, then stop missed with no hand-over beside the busy session', { options: ON }, async ($, on) => {
  const w = world(on)
  const f = forks(on, w)
  await w.start($)
  const t0 = await humanTurn($, w)
  f.t0 = t0
  await until(w, t0, 60)
  let release: () => void = () => undefined
  w.compactGate = new Promise<void>(r => { release = r })
  const p = $.session.compact({ trigger: 'auto', messages: [{ role: 'user', text: 'hello', toolUses: [] }] } as never)
  // One advance each (a compaction under way slows every settle): the ping timer still ticks each minute.
  await w.advance(48.5 * MIN)
  expect(stops(w)).toEqual([])
  await w.advance(1.5 * MIN)
  expect(f.at).toEqual([50])
  expect(stops(w)).toEqual([['missed', false, 1]])
  release()
  await p
  await w.settle()
})

test('AT-KW-30: after a hand-over, a person\'s turn lets the next gap warm again (the plugin\'s own handoff turn does not, AT-KW-05)', { options: ON }, async ($, on) => {
  const w = world(on)
  const f = forks(on, w)
  await w.start($)
  const t0 = await humanTurn($, w)
  f.t0 = t0
  await until(w, t0, 160)
  expect(stops(w)).toEqual([['cutoff', true, 2]])
  expect(selfCompacts(w)).toBe(1)
  await humanTurn($, w)
  await until(w, t0, 211)
  expect(f.at).toEqual([50, 100, 210])
  expect(w.rowsOf('keep_warm_start').length).toBe(2)
})

test('AT-KW-31: another load adopted the held record (a reload while this load runs on): stop held-elsewhere at the next ping, no fork, the record left to that load', { options: ON }, async ($, on) => {
  const w = world(on)
  const f = forks(on, w)
  await w.start($)
  const t0 = await humanTurn($, w)
  f.t0 = t0
  await until(w, t0, 60)
  w.storeSet(KEY, { ...(w.storeGet(KEY) as Record<string, unknown>), load: 'other' })
  await until(w, t0, 160)
  expect(f.at).toEqual([50])
  expect(stops(w)).toEqual([['held-elsewhere', false, 1]])
  const v = w.storeGet(KEY) as Record<string, unknown>
  expect([v.load, v.cancelled]).toEqual(['other', undefined])
  expect(selfCompacts(w)).toBe(0)
})

test('AT-KW-32: a load that adopts a held record already past its late-fire bound: one keep_warm_stop reload row with no hand-over, the lapsed skip, a tombstone', { options: ON }, async ($, on) => {
  const probe = new World()
  const store = {
    [KEY]: {
      kind: 'compact', due: T0 - 5 * MIN, sid: SID_A, end: T0 - 70 * MIN, anchor: T0 - 55 * MIN, warm: T0 - 55 * MIN, load: 'old', tokens: 260000, ttl: '1h', pct: 30,
      cc: probe.version.version, model: probe.model, answer: true, published: false, episode: { since: T0 - 70 * MIN, done: false }, held: { start: T0 - 70 * MIN, pings: 1 },
    },
  }
  const w = new World().install(on, store)
  w.policy = NATIVE_OFF
  w.rateLimits = LIMITS
  w.agents = RUNNING
  const f = forks(on, w)
  await w.start($)
  expect(stops(w)).toEqual([['reload', false, 1]])
  expect(w.rowsOf('keep_warm_stop')[0]?.gap_s).toBe(4200)
  expect(skips(w)).toEqual([['lapsed', 'compact']])
  expect((w.storeGet(KEY) as Record<string, unknown>).cancelled).toBe(true)
  await w.advance(60 * MIN)
  expect([f.at.length, selfCompacts(w)]).toEqual([0, 0])
})

/** A person's prompt that enters (cancelling the ping timer) and stays pending until `drop()`, sent at the first `send()` (from inside a read the plugin makes). */
function pendingPrompt($: Engine, w: World): { send: () => void; sent: () => boolean; drop: () => Promise<void> } {
  let open: () => void = () => undefined
  let sub: Promise<unknown> | undefined
  w.atSubmit = () => new Promise<void>(r => { open = r })
  w.dropIf = () => 'a peer dropped it'
  return {
    send: () => {
      if (sub === undefined) sub = $.prompt.submit({ text: 'hello', origin: { kind: 'composer' } } as never)
    },
    sent: () => sub !== undefined,
    drop: async () => {
      open()
      await sub
      await w.settle()
    },
  }
}

test('AT-KW-33: a prompt enters during a ping\'s checks and stays pending: that ping ends there and no timer runs meanwhile (no retry, no stop); once a hook drops it the gap goes on (missed by then)', { options: ON }, async ($, on) => {
  const w = world(on)
  const f = forks(on, w)
  const pp = pendingPrompt($, w)
  let armed = false
  const agents = w.agents
  Object.defineProperty(w, 'agents', { configurable: true, get() { if (armed) pp.send(); return agents }, set() {} })
  await w.start($)
  const t0 = await humanTurn($, w)
  f.t0 = t0
  await until(w, t0, 99.5)
  armed = true
  await w.advance(11.5 * MIN)
  expect(pp.sent()).toBe(true)
  expect(f.at).toEqual([50])
  expect(stops(w)).toEqual([])
  await pp.drop()
  expect(stops(w)).toEqual([['missed', false, 1]])
})

test('AT-KW-33: a prompt enters while a warm ping moves the held record on and stays pending: no next ping is armed meanwhile; once a hook drops it the gap goes on (missed by then)', { options: ON }, async ($, on) => {
  const w = world(on)
  let armed = false
  const f = forks(on, w, i => {
    if (i === 1) armed = true
    return { isAnswered: true, text: 'OK', usage: WARM }
  })
  const pp = pendingPrompt($, w)
  const mem = (w as unknown as { storeMem: Map<string, unknown> }).storeMem
  const get = mem.get.bind(mem)
  Object.defineProperty(mem, 'get', { configurable: true, value: (k: string) => { if (armed && k === KEY) pp.send(); return get(k) } })
  await w.start($)
  const t0 = await humanTurn($, w)
  f.t0 = t0
  await until(w, t0, 100.5)
  await w.advance(60.5 * MIN)
  expect(pp.sent()).toBe(true)
  expect(f.at).toEqual([50, 100])
  expect(stops(w)).toEqual([])
  await pp.drop()
  expect(stops(w)).toEqual([['missed', false, 2]])
})

test('AT-KW-34: the task ids a notification reported ended are forgotten at session end: after /clear a task with that id counts again', { options: ON }, async ($, on) => {
  const w = world(on)
  w.agents = []
  const f = forks(on, w)
  await w.start($)
  await w.userTurn($, '<task-notification><task-id>bsh1</task-id><status>completed</status><summary>done</summary></task-notification>', 'task-notification')
  await w.turnEnd($)
  await $.session.end({ reason: 'clear', sessionId: SID_A, resume: { id: SID_A } } as never)
  w.sid = SID_B
  await w.userTurn($)
  w.tokens = 260000
  await stopHook($, { session_id: SID_B, background_tasks: [{ id: 'bsh1', type: 'shell', status: 'running', description: 'x' }] })
  await w.turnEnd($)
  f.t0 = w.clock.now()
  await until(w, f.t0, 51)
  expect(f.at).toEqual([50])
})

const kwRows = (w: World) => w.rows.filter(r => String(r.ev).startsWith('keep_warm')).map(r => [r.ev, r.why ?? null])

test('AT-KW-35 (REV2-F): a person\'s turn starts while the first ping writes keep_warm_start: the stop row comes after the start row, and no fork', { options: ON }, async ($, on) => {
  const w = world(on)
  const f = forks(on, w)
  let turn: Promise<void> | undefined
  w.atHelper = async (sub, args) => {
    if (sub === 'log' && turn === undefined && args.some(a => a.includes('"keep_warm_start"'))) {
      turn = w.userTurn($, 'back now')
      await w.settle()
    }
  }
  await w.start($)
  const t0 = await humanTurn($, w)
  f.t0 = t0
  await until(w, t0, 52)
  await turn
  await w.settle()
  expect(turn).toBeDefined()
  expect(kwRows(w)).toEqual([['keep_warm_start', null], ['keep_warm_stop', 'turn']])
  expect(f.at).toEqual([])
})

test('AT-KW-35 (REV2-E): a person\'s turn starts during the 49-min fire\'s keep-warm checks: nothing held, no keep-warm row, the idle path skips busy', { options: ON }, async ($, on) => {
  const w = world(on, { autoCompactEnabled: false })
  const f = forks(on, w)
  let turn: Promise<void> | undefined
  let armed = false
  const agents = w.agents
  Object.defineProperty(w, 'agents', { configurable: true, get() { if (armed && turn === undefined) turn = w.userTurn($, 'back now'); return agents }, set() {} })
  await w.start($)
  const t0 = await humanTurn($, w)
  f.t0 = t0
  await until(w, t0, 48.5)
  armed = true
  await until(w, t0, 49.5)
  await turn
  await w.settle()
  expect(turn).toBeDefined()
  expect(kwRows(w)).toEqual([])
  expect(skips(w)).toEqual([['busy', 'turn']])
  expect((w.storeGet(KEY) as Record<string, unknown>).cancelled).toBe(true)
  await until(w, t0, 75)
  expect([f.at.length, w.submits.length]).toEqual([0, 0])
})

test('AT-KW-36: a prompt enters while warming begins (its job count read) and stays pending: no start row and no fork meanwhile; once a hook drops it the first ping goes out', { options: ON }, async ($, on) => {
  const w = world(on)
  const f = forks(on, w)
  const pp = pendingPrompt($, w)
  let reads = 0
  let armed = false
  const agents = w.agents
  // The ping's checks list the agents first, then warming's start row counts the jobs: the prompt enters at that second list
  // (the harness reads `agents` twice per list).
  Object.defineProperty(w, 'agents', { configurable: true, get() { if (armed && ++reads === 3) pp.send(); return agents }, set() {} })
  await w.start($)
  const t0 = await humanTurn($, w)
  f.t0 = t0
  await until(w, t0, 49.5)
  armed = true
  await w.advance(2 * MIN)
  expect(pp.sent()).toBe(true)
  expect([f.at, w.rowsOf('keep_warm_start').length]).toEqual([[], 0])
  await pp.drop()
  expect(f.at).toEqual([52])
  expect(w.rowsOf('keep_warm_start').length).toBe(1)
})

test('AT-KW-36: a prompt enters while the start row is written and stays pending: no fork meanwhile; once a hook drops it the ping goes out', { options: ON }, async ($, on) => {
  const w = world(on)
  const f = forks(on, w)
  const pp = pendingPrompt($, w)
  w.atHelper = async (sub, args) => {
    if (sub === 'log' && args.some(a => a.includes('"keep_warm_start"'))) pp.send()
  }
  await w.start($)
  const t0 = await humanTurn($, w)
  f.t0 = t0
  await w.advance(52 * MIN)
  expect(pp.sent()).toBe(true)
  expect([f.at, w.rowsOf('keep_warm_start').length]).toEqual([[], 1])
  await pp.drop()
  expect(f.at).toEqual([52])
  expect(pings(w)).toEqual([['warm', 1]])
})

test('AT-KW-36: a prompt enters during the idle fire\'s compaction check while warming and stays pending: the record is not held (the idle path skips it as busy)', { options: ON }, async ($, on) => {
  const w = world(on)
  const f = forks(on, w)
  const pp = pendingPrompt($, w)
  let armed = false
  const mem = (w as unknown as { storeMem: Map<string, unknown> }).storeMem
  const get = mem.get.bind(mem)
  Object.defineProperty(mem, 'get', { configurable: true, value: (k: string) => { if (armed && k.startsWith('idle_seen:')) pp.send(); return get(k) } })
  await w.start($)
  const t0 = await humanTurn($, w)
  f.t0 = t0
  await until(w, t0, 53.5)
  armed = true
  await w.advance(MIN)
  expect(pp.sent()).toBe(true)
  expect(f.at).toEqual([50])
  expect(skips(w).filter(s => s[0] === 'keep-warm')).toEqual([])
  expect((w.storeGet(KEY) as Record<string, unknown>).held).toBe(undefined)
  await pp.drop()
})

test('AT-KW-37: pings that take 15 s: each retry a minute after the last one ended, the compaction held at 54:00 as a retry ends, and the deadline counted from the last warm request (the hand-over after the retry that ends at 57:45)', { options: ON }, async ($, on) => {
  const w = world(on)
  const at: number[] = []
  let t0 = 0
  on('model.fork', async () => {
    at.push(w.clock.now() - t0)
    await w.clock.sleep(15000)
    return { value: OVERLOADED } as never
  })
  await w.start($)
  t0 = await humanTurn($, w)
  await until(w, t0, 70)
  expect(at.slice(0, 4)).toEqual([50 * MIN, 51.25 * MIN, 52.5 * MIN, 53.75 * MIN])
  expect(skips(w)).toEqual([['keep-warm', 'compact']])
  expect(stops(w)).toEqual([['deadline', true, 0]])
  expect(ic(w).length).toBe(1)
  expect(selfCompacts(w)).toBe(1)
})

// ---- Review fixes (fix round 4)

/** P2's world: native on (the 55.5-min check), the plugin's idle compaction off, a background shell and no agent. */
async function checkGap($: Engine, w: World): Promise<number> {
  w.agents = []
  await w.start($)
  await w.userTurn($)
  w.tokens = 260000
  await stopHook($, { background_tasks: [{ id: 'bsh1', type: 'shell', status: 'running', description: 'x' }] })
  await w.turnEnd($)
  return w.clock.now()
}

for (const c of [
  { name: 'an API error', last: () => OVERLOADED },
  { name: 'a fork the engine refuses', last: (): Answer => { throw new Error('denied by a hook') } },
  { name: 'nothing-to-fork', last: (): Answer => ({ isAnswered: false, reason: 'nothing-to-fork' }) },
]) {
  test(`AT-KW-38 (REV3-1): the held check's last retry comes back past its deadline (a 3-min fork from 57:30 to 60:30, ${c.name}): stop missed, no hand-over, no turn on the lapsed cache`, { options: { ...ON, idle_compact: 'off' } }, async ($, on) => {
    const w = world(on, {})
    const at: number[] = []
    let t0 = 0
    on('model.fork', async () => {
      const m = (w.clock.now() - t0) / MIN
      at.push(m)
      await w.clock.sleep(m >= 57 ? 3 * MIN : 15000)
      return { value: m >= 57 ? c.last() : OVERLOADED } as never
    })
    t0 = await checkGap($, w)
    await until(w, t0, 70)
    expect(at).toEqual([50, 51.25, 52.5, 53.75, 55, 56.25, 57.5])
    expect(stops(w)).toEqual([['missed', false, 0]])
    expect(skips(w)).toEqual([['keep-warm', 'check']])
    expect([w.submits.length, selfCompacts(w)]).toEqual([0, 0])
    // The record it held is cleared (a tombstone, deleted a minute or two later): nothing fires it.
    const v = w.storeGet(KEY) as Record<string, unknown> | undefined
    expect(v === undefined || v.cancelled === true).toBe(true)
  })
}

test('AT-KW-38 (REV3-1): a fork-miss ping that comes back past the 58-min bound hands the check back; its turn path skips lapsed (no turn on a cache past the bound of the last warm request)', { options: { ...ON, idle_compact: 'off' } }, async ($, on) => {
  const w = world(on, {})
  let t0 = 0
  on('model.fork', async () => {
    const m = (w.clock.now() - t0) / MIN
    await w.clock.sleep(m >= 57 ? 3 * MIN : 15000)
    return { value: m >= 57 ? { isAnswered: true, text: 'OK', usage: COLD } : OVERLOADED } as never
  })
  t0 = await checkGap($, w)
  await until(w, t0, 70)
  expect(stops(w)).toEqual([['fork-miss', true, 0]])
  expect(skips(w)).toEqual([['keep-warm', 'check'], ['lapsed', 'check']])
  expect(w.submits.length).toBe(0)
})

// The first ping and the 49-min fire meet on one gap: a gate holds one `session.usage` read (the n-th from `from` minutes on)
// until 50:30. P3: the ping first (the turn ends 61 s after the last request: the fire at 50:01); P4: the fire first (59 s: 49:59).
for (const c of [
  { name: 'the first ping first', endAfter: 61000, from: 50 },
  { name: 'the 49-min fire first', endAfter: 59000, from: 49 + 59 / 60 },
]) {
  for (const g of [1, 2, 3]) {
    test(`AT-KW-39 (REV3-2): ${c.name}, usage read ${g} held: one start row, the turn held, the pings go on, the hand-over at the cutoff`, { options: ON }, async ($, on0) => {
      let from = Infinity
      let n = 0
      let release: () => void = () => undefined
      const gate = new Promise<void>(r => { release = r })
      let wref: World | undefined
      const on = ((name: string, h: (...a: unknown[]) => unknown) => on0(name as never, (name === 'session.usage'
        ? async (...a: unknown[]) => {
          if (wref && wref.clock.now() >= from && ++n === g) await gate
          return h(...a)
        }
        : h) as never)) as unknown as On
      const w = world(on, { autoCompactEnabled: false })
      wref = w
      const f = forks(on0, w)
      await w.start($)
      await w.userTurn($)
      await w.step($)
      const t0 = w.clock.now()
      f.t0 = t0
      from = t0 + c.from * MIN
      await w.advance(c.endAfter)
      w.tokens = 260000
      await w.turnEnd($)
      await until(w, t0, 50.5)
      release()
      await w.settle()
      await until(w, t0, 52)
      expect(f.at.length).toBe(1)
      expect(w.rowsOf('keep_warm_start').length).toBe(1)
      expect(skips(w)).toEqual([['keep-warm', 'turn']])
      // The start row first, whichever began the gap.
      expect(w.rows.findIndex(r => r.ev === 'keep_warm_start')).toBeLessThan(w.rows.findIndex(r => r.ev === 'handoff_skipped'))
      expect(w.submits.length).toBe(0)
      expect((w.storeGet(KEY) as Record<string, unknown>).held).toEqual({ start: t0, pings: 1 })
      await until(w, t0, 160)
      expect(f.at.length).toBe(2)
      expect(stops(w)).toEqual([['cutoff', true, 2]])
      if (IDLE) expect(w.submits.length).toBe(1)
      else expect(skips(w)).toEqual([['keep-warm', 'turn'], ['no-asset', 'turn']])
    })
  }
}

test('AT-KW-40 (REV3-2): the first ping\'s warming start finds the gap off (the 49-min fire\'s checks found a window at 92% meanwhile): no start row, no fork; the fire skips near-limit', { options: ON }, async ($, on0) => {
  let from = Infinity
  let n = 0
  let release: () => void = () => undefined
  const gate = new Promise<void>(r => { release = r })
  let wref: World | undefined
  // The ping's checks read the usage once, warming's start once more: that second read waits, and the window reaches 92% then.
  const on = ((name: string, h: (...a: unknown[]) => unknown) => on0(name as never, (name === 'session.usage'
    ? async (...a: unknown[]) => {
      if (wref && wref.clock.now() >= from && ++n === 2) {
        wref.rateLimits = [{ kind: 'five_hour', percentUsed: 92 }, { kind: 'seven_day', percentUsed: 30 }]
        await gate
      }
      return h(...a)
    }
    : h) as never)) as unknown as On
  const w = world(on, { autoCompactEnabled: false })
  wref = w
  const f = forks(on0, w)
  await w.start($)
  await w.userTurn($)
  await w.step($)
  const t0 = w.clock.now()
  f.t0 = t0
  from = t0 + 50 * MIN
  await w.advance(61000)
  w.tokens = 260000
  await w.turnEnd($)
  await until(w, t0, 50.5)
  release()
  await w.settle()
  await until(w, t0, 120)
  expect(n).toBeGreaterThan(2)
  expect([f.at, w.rowsOf('keep_warm_start').length, stops(w)]).toEqual([[], 0, []])
  expect(skips(w)).toEqual([['near-limit', 'turn']])
})

test('AT-KW-41 (REV3-3): two prompts a hook drops while the ping is out: no second timer or fork beside it; the ping counts and the next comes at 100', { options: ON }, async ($, on) => {
  const w = world(on)
  const at: number[] = []
  let t0 = 0
  let dropped: Promise<unknown> | undefined
  on('model.fork', async () => {
    at.push(Math.round((w.clock.now() - t0) / MIN))
    if (at.length === 1) {
      w.dropIf = () => 'a peer dropped it'
      dropped = (async () => {
        await $.prompt.submit({ text: 'one', origin: { kind: 'composer' } } as never)
        await $.prompt.submit({ text: 'two', origin: { kind: 'composer' } } as never)
      })()
      await dropped
    }
    await w.clock.sleep(30000)
    return { value: { isAnswered: true, text: 'OK', usage: WARM } } as never
  })
  await w.start($)
  t0 = await humanTurn($, w)
  await until(w, t0, 52)
  expect(dropped).toBeDefined()
  expect(at).toEqual([50])
  expect(pings(w)).toEqual([['warm', 1]])
  await until(w, t0, 101)
  expect(at).toEqual([50, 100])
  expect(pings(w)).toEqual([['warm', 1], ['warm', 2]])
})

test('AT-KW-41 (REV3-4): a prompt enters while a failed ping\'s row is written and stays pending: no retry, no stop meanwhile (no timer runs); once a hook drops it the gap goes on (missed by then)', { options: ON }, async ($, on) => {
  const w = world(on)
  const f = forks(on, w, () => OVERLOADED)
  const pp = pendingPrompt($, w)
  w.atHelper = async (sub, args) => {
    if (sub === 'log' && args.some(a => a.includes('"keep_warm_ping"'))) pp.send()
  }
  await w.start($)
  const t0 = await humanTurn($, w)
  f.t0 = t0
  await until(w, t0, 70)
  expect(pp.sent()).toBe(true)
  expect([f.at, stops(w)]).toEqual([[50], []])
  await pp.drop()
  expect(stops(w)).toEqual([['missed', false, 0]])
  expect(f.at).toEqual([50])
})

test('AT-KW-42 (REV3-4): the session ends while the turn end arms the gap (its model read waits for the end): no gap is armed, so nothing pings after the end', { options: ON }, async ($, on0) => {
  let armed = false
  let ended: Promise<unknown> | undefined
  // The idle timer is armed first (its record stored), keep-warm's gap after it: the first model read after that store is the gap's.
  const on = ((name: string, h: (...a: unknown[]) => unknown) => on0(name as never, (name === 'session.model'
    ? async (...a: unknown[]) => {
      if (armed && ended === undefined) {
        ended = $.session.end({ sessionId: SID_A, reason: 'prompt_input_exit' } as never)
        await ended
      }
      return h(...a)
    }
    : h) as never)) as unknown as On
  const w = world(on)
  const f = forks(on0, w)
  const mem = (w as unknown as { storeMem: Map<string, unknown> }).storeMem
  const set = mem.set.bind(mem)
  Object.defineProperty(mem, 'set', { configurable: true, value: (k: string, v: unknown) => { if (k === KEY && w.tokens === 260000) armed = true; return set(k, v) } })
  await w.start($)
  const t0 = await humanTurn($, w)
  f.t0 = t0
  expect(ended).toBeDefined()
  await until(w, t0, 120)
  expect(f.at).toEqual([])
  expect(w.rows.filter(r => String(r.ev).startsWith('keep_warm'))).toEqual([])
})

test('AT-KW-43 (REV3-3): a prompt a hook drops at once while warming begins (its job count read): that tick goes on with the gap, the first ping goes out', { options: ON }, async ($, on) => {
  const w = world(on)
  const f = forks(on, w)
  let reads = 0
  let armed = false
  let dropped: Promise<unknown> | undefined
  w.dropIf = () => 'a peer dropped it'
  const agents = w.agents
  // As AT-KW-36: the second agent list of the ping is warming's job count.
  Object.defineProperty(w, 'agents', {
    configurable: true,
    get() {
      if (armed && ++reads === 3) dropped = $.prompt.submit({ text: 'hello', origin: { kind: 'composer' } } as never)
      return agents
    },
    set() {},
  })
  await w.start($)
  const t0 = await humanTurn($, w)
  f.t0 = t0
  await until(w, t0, 49.5)
  armed = true
  await until(w, t0, 52)
  await dropped
  expect(dropped).toBeDefined()
  expect(f.at).toEqual([50])
  expect(w.rowsOf('keep_warm_start').length).toBe(1)
  expect(pings(w)).toEqual([['warm', 1]])
})

test('AT-KW-44 (REV3-2): the 49-min fire\'s checks find a window at 92% while the first ping began warming beside them: the fire holds nothing, the gap stays warming and ends with its stop row', { options: ON }, async ($, on0) => {
  let from = Infinity
  let n = 0
  let release: () => void = () => undefined
  const gate = new Promise<void>(r => { release = r })
  let wref: World | undefined
  // The fire's first usage read (49:59) waits past the first ping (50:00) and then reads the window at 92%; every other read 12%.
  const on = ((name: string, h: (...a: unknown[]) => unknown) => on0(name as never, (name === 'session.usage'
    ? async (...a: unknown[]) => {
      if (wref && wref.clock.now() >= from && ++n === 1) {
        await gate
        const r = (await h(...a)) as { value: Record<string, unknown> }
        return { value: { ...r.value, rateLimits: [{ kind: 'five_hour', percentUsed: 92 }] } }
      }
      return h(...a)
    }
    : h) as never)) as unknown as On
  const w = world(on, { autoCompactEnabled: false })
  wref = w
  const f = forks(on0, w)
  await w.start($)
  await w.userTurn($)
  await w.step($)
  const t0 = w.clock.now()
  f.t0 = t0
  from = t0 + (49 + 59 / 60) * MIN
  await w.advance(59000)
  w.tokens = 260000
  await w.turnEnd($)
  await until(w, t0, 50.5)
  expect(f.at).toEqual([50])
  release()
  await w.settle()
  await until(w, t0, 160)
  expect(skips(w).filter(s => s[0] === 'keep-warm')).toEqual([])
  expect(w.rowsOf('keep_warm_start').length).toBe(1)
  expect(stops(w).length).toBe(1)
  // One submit, the 49-min fire's own handoff turn: the fire held nothing (keep-warm's read found the window near the limit), so
  // the idle path ran as it does with keep-warm off, its own reads at 12%. That turn's start would end the gap (`turn`); in this
  // world the submitted prompt starts no turn, so the gap ends at its stop row as above. Without the asset: no-asset, no submit.
  if (IDLE) expect([skips(w), w.submits.length]).toEqual([[], 1])
  else expect([skips(w), w.submits.length]).toEqual([[['no-asset', 'turn']], 0])
})

// ---- Review fixes (fix round 5)

test('AT-KW-45: a prompt a hook drops while the ping is out, then a second that enters and stays pending: no timer runs while it waits (no retry, no stop); once a hook drops it the gap goes on (missed by then)', { options: ON }, async ($, on) => {
  const w = world(on)
  const at: number[] = []
  let t0 = 0
  let open: () => void = () => undefined
  let second: Promise<unknown> | undefined
  on('model.fork', async () => {
    at.push(Math.round((w.clock.now() - t0) / MIN))
    if (at.length === 1) {
      w.dropIf = () => 'a peer dropped it'
      // The first is dropped at once (the tick goes on with the gap), the second waits in a hook beneath.
      await $.prompt.submit({ text: 'one', origin: { kind: 'composer' } } as never)
      w.atSubmit = () => new Promise<void>(r => { open = r })
      second = $.prompt.submit({ text: 'two', origin: { kind: 'composer' } } as never)
    }
    await w.clock.sleep(30000)
    return { value: { isAnswered: true, text: 'OK', usage: WARM } } as never
  })
  await w.start($)
  t0 = await humanTurn($, w)
  await until(w, t0, 70)
  expect(second).toBeDefined()
  expect(at).toEqual([50])
  // The ping came back while the second prompt waited: not counted, and the tick arms nothing after it.
  expect([pings(w), stops(w)]).toEqual([[['warm', 0]], []])
  open()
  await second
  await w.settle()
  expect(stops(w)).toEqual([['missed', false, 0]])
  expect(at).toEqual([50])
})

// The held check's deadline is the 58-min lapse bound of the last warm request: the last retry (57:30) comes back a few seconds
// either side of it. Before it the check goes back to the idle path and still gets its turn (the 55.5-min turn bound does not
// apply to a check); past it the gap stops missed with no hand-over.
for (const c of [
  { name: 'just before it (57:55): stop deadline with the hand-over, the check runs', ms: 25000, stop: ['deadline', true, 0], back: true },
  { name: 'just past it (58:05): stop missed, no hand-over, nothing runs', ms: 35000, stop: ['missed', false, 0], back: false },
]) {
  test(`AT-KW-46: the held check's last retry comes back ${c.name}`, { options: { ...ON, idle_compact: 'off' } }, async ($, on) => {
    const w = world(on, {})
    const at: number[] = []
    let t0 = 0
    on('model.fork', async () => {
      const m = (w.clock.now() - t0) / MIN
      at.push(m)
      await w.clock.sleep(m >= 57 ? c.ms : 15000)
      return { value: OVERLOADED } as never
    })
    t0 = await checkGap($, w)
    await until(w, t0, 70)
    expect(at).toEqual([50, 51.25, 52.5, 53.75, 55, 56.25, 57.5])
    expect(stops(w)).toEqual([c.stop])
    expect(selfCompacts(w)).toBe(0)
    if (!c.back) {
      expect([skips(w), w.submits.length]).toEqual([[['keep-warm', 'check']], 0])
      // The record it held is cleared (a tombstone): nothing fires it later.
      const v = w.storeGet(KEY) as Record<string, unknown> | undefined
      expect(v === undefined || v.cancelled === true).toBe(true)
    } else if (IDLE) expect([skips(w), w.submits.length]).toEqual([[['keep-warm', 'check']], 1])
    else expect(skips(w)).toEqual([['keep-warm', 'check'], ['no-asset', 'check']])
  })
}

test('AT-KW-46: a fork-miss ping hands the check back at 56:30, past the turn\'s 55.5-min bound and before the 58-min one: the check still gets its turn', { options: { ...ON, idle_compact: 'off' } }, async ($, on) => {
  const w = world(on, {})
  let t0 = 0
  on('model.fork', async () => {
    const m = (w.clock.now() - t0) / MIN
    await w.clock.sleep(15000)
    return { value: m >= 56 ? { isAnswered: true, text: 'OK', usage: COLD } : OVERLOADED } as never
  })
  t0 = await checkGap($, w)
  await until(w, t0, 70)
  expect(stops(w)).toEqual([['fork-miss', true, 0]])
  if (IDLE) expect([skips(w), w.submits.length]).toEqual([[['keep-warm', 'check']], 1])
  else expect(skips(w)).toEqual([['keep-warm', 'check'], ['no-asset', 'check']])
})

// ---- A fork-miss (live probe 2026-10-31): the fork's request missed the main prefix (its thinking
// setting differed for that history shape). The main cache is not claimed lapsed; no gap pings again
// until the session's next main request, which changes the history.

/** A person's turn with one main request (`turn.step`), ending at 260K; returns the clock at its end. */
async function requestTurn($: Engine, w: World): Promise<number> {
  await w.userTurn($)
  await w.step($)
  w.tokens = 260000
  await w.turnEnd($)
  return w.clock.now()
}

test('AT-KW-47: after a fork-miss no ping in that gap, none in a later gap a turn with no main request opens, and pings resume after the next main request', { options: ON }, async ($, on) => {
  const w = world(on)
  const f = forks(on, w, i => ({ isAnswered: true, text: 'OK', usage: i === 0 ? COLD : WARM }))
  await w.start($)
  const t0 = await humanTurn($, w)
  f.t0 = t0
  await until(w, t0, 53)
  expect(f.at).toEqual([50])
  expect(pings(w)).toEqual([['fork-miss', 0]])
  expect(stops(w)).toEqual([['fork-miss', false, 0]])
  // A turn that sends no main request: the history is the same, so its gap does not warm (no row, no fork).
  const t1 = await humanTurn($, w)
  await until(w, t1, 53)
  expect(f.at).toEqual([50])
  expect([w.rowsOf('keep_warm_start').length, w.rowsOf('keep_warm_stop').length]).toEqual([1, 1])
  // A turn with a main request: the next gap pings at 50 again and warms.
  const t2 = await requestTurn($, w)
  await until(w, t2, 51)
  expect(f.at.length).toBe(2)
  expect(pings(w)).toEqual([['fork-miss', 0], ['warm', 1]])
  expect(w.rowsOf('keep_warm_start').length).toBe(2)
  // The reason is logged once: one fork-miss ping row and one fork-miss stop row.
  expect(w.rowsOf('keep_warm_stop').filter(r => r.why === 'fork-miss').length).toBe(1)
})

test('AT-KW-47: a later ping\'s fork-miss stops the gap with the hand-over: no further ping in it, and the idle compaction it held runs', { options: ON }, async ($, on) => {
  const w = world(on)
  const f = forks(on, w, i => ({ isAnswered: true, text: 'OK', usage: i === 1 ? COLD : WARM }))
  await w.start($)
  const t0 = await humanTurn($, w)
  f.t0 = t0
  await until(w, t0, 240)
  expect(f.at).toEqual([50, 100])
  expect(stops(w)).toEqual([['fork-miss', true, 1]])
  expect(selfCompacts(w)).toBe(1)
})

test('AT-KW-48: a main request while the fork is out (a person\'s turn): that fork-miss does not hold back the turn\'s own gap, which pings at 50', { options: ON }, async ($, on) => {
  const w = world(on)
  let t0 = 0
  const at: number[] = []
  let release: () => void = () => undefined
  const gate = new Promise<void>(r => { release = r })
  on('model.fork', async () => {
    at.push(Math.round((w.clock.now() - t0) / MIN))
    if (at.length === 1) {
      await gate
      return { value: { isAnswered: true, text: 'OK', usage: COLD } } as never
    }
    return { value: { isAnswered: true, text: 'OK', usage: WARM } } as never
  })
  await w.start($)
  t0 = await humanTurn($, w)
  await until(w, t0, 50.5)
  expect(at).toEqual([50])
  const t1 = await requestTurn($, w)
  release()
  await w.settle()
  expect(pings(w)).toEqual([['fork-miss', 0]])
  await until(w, t1, 51)
  expect(at.length).toBe(2)
  expect(pings(w)).toEqual([['fork-miss', 0], ['warm', 1]])
})

test('AT-KW-49: a prompt enters while a fork-miss ping is out and stays pending; once a hook drops it the gap stops fork-miss with no second fork', { options: ON }, async ($, on) => {
  const w = world(on)
  let t0 = 0
  const at: number[] = []
  let open: () => void = () => undefined
  let pending: Promise<unknown> | undefined
  on('model.fork', async () => {
    at.push(Math.round((w.clock.now() - t0) / MIN))
    w.dropIf = () => 'a peer dropped it'
    w.atSubmit = () => new Promise<void>(r => { open = r })
    pending = $.prompt.submit({ text: 'one', origin: { kind: 'composer' } } as never)
    await w.clock.sleep(15000)
    return { value: { isAnswered: true, text: 'OK', usage: COLD } } as never
  })
  await w.start($)
  t0 = await humanTurn($, w)
  await until(w, t0, 51)
  expect(pending).toBeDefined()
  expect([pings(w), stops(w)]).toEqual([[['fork-miss', 0]], []])
  open()
  await pending
  await w.settle()
  await until(w, t0, 53)
  expect(at).toEqual([50])
  expect(stops(w)).toEqual([['fork-miss', false, 0]])
})

test('AT-KW-49: the same with a held compaction (a warm ping at 50, the fork-miss at 100): the gap stops fork-miss with the hand-over, and the compaction runs', { options: ON }, async ($, on) => {
  const w = world(on)
  let t0 = 0
  const at: number[] = []
  let open: () => void = () => undefined
  let pending: Promise<unknown> | undefined
  on('model.fork', async () => {
    at.push(Math.round((w.clock.now() - t0) / MIN))
    if (at.length === 2) {
      w.dropIf = () => 'a peer dropped it'
      w.atSubmit = () => new Promise<void>(r => { open = r })
      pending = $.prompt.submit({ text: 'one', origin: { kind: 'composer' } } as never)
    }
    await w.clock.sleep(15000)
    return { value: { isAnswered: true, text: 'OK', usage: at.length === 2 ? COLD : WARM } } as never
  })
  await w.start($)
  t0 = await humanTurn($, w)
  await until(w, t0, 101)
  expect(pending).toBeDefined()
  expect([pings(w), stops(w)]).toEqual([[['warm', 1], ['fork-miss', 1]], []])
  open()
  await pending
  await w.settle()
  await until(w, t0, 110)
  expect(at).toEqual([50, 100])
  expect(stops(w)).toEqual([['fork-miss', true, 1]])
  expect(selfCompacts(w)).toBe(1)
})

test('AT-KW-47: a fork-miss holds back only its own session: after /clear the new session\'s gap pings at 50 with no request of its own yet', { options: ON }, async ($, on) => {
  const w = world(on)
  const f = forks(on, w, i => ({ isAnswered: true, text: 'OK', usage: i === 0 ? COLD : WARM }))
  await w.start($)
  const t0 = await humanTurn($, w)
  f.t0 = t0
  await until(w, t0, 51)
  expect(pings(w)).toEqual([['fork-miss', 0]])
  await $.session.end({ reason: 'clear', sessionId: SID_A, resume: { id: SID_A } } as never)
  w.sid = SID_B
  const t1 = await humanTurn($, w)
  await until(w, t1, 51)
  expect(f.at.length).toBe(2)
  expect(pings(w)).toEqual([['fork-miss', 0], ['warm', 1]])
})
