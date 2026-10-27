// U tests through the kit: the plugin's own idle compaction (IDLE-COMPACT-SPEC revision 2, lane A;
// idle kind `compact`). With `"idleCompaction": false` (native `vetoed`) and automatic compaction
// on, the mod compacts an idle main session itself about 54 minutes after its last request, at
// Claude Code's idle minimum or more, behind the guards of §2.1, and replaces the 49-min turn (D2).
// Test ids are AT-IC-Cnn: idle.test.ts already uses AT-IC-01..14 for the IC-1 cases. Cases that
// run the pre-idle turn need the `[submit-idle]` lines of handoff-turn.txt; a build without them
// answers `no-asset`, and those cases accept that instead.
import { expect, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import { assemble, hasTag } from '../../hooks/lib/assemble'
import { DEFAULTS } from '../../hooks/lib/config'
import type { Deps } from '../../hooks/lib/deps'
import { newState } from '../../hooks/lib/deps'
import type { Due } from '../../hooks/lib/idle'
import { compactGuards, countIdleCompact } from '../../hooks/lib/idle'
import { PENDING_FILE, ARMED_FILE } from '../../hooks/lib/resume'
import { SID_A, SID_B, T0, WATCH, World, raiseCompact } from './harness.test'

const IDLE = hasTag('handoff-turn', 'submit-idle')
const ON = { idle_handoff_turn: 'auto', precompact_turn: 'code' }
const NATIVE_OFF: Record<string, unknown> = { idleCompaction: false }
const MIN = 60000
const LIMITS = [{ kind: 'five_hour', percentUsed: 12 }, { kind: 'seven_day', percentUsed: 30 }]
const RUNNING = [{ id: 'sub-1', status: 'running' }]
const KEY = 'idle_due:' + SID_A

const skips = (w: World) => w.rowsOf('handoff_skipped').filter(r => r.reason === 'idle').map(r => [r.why, r.kind])
const ic = (w: World) => w.rowsOf('idle_compact')
const modes = (w: World) => w.rowsOf('idle_mode').map(r => `${String(r.native)}/${String(r.plugin_turn)}/${String(r.plugin_compact)}`)
const selfCompacts = (w: World) => w.compacts.filter(c => c.trigger === undefined).length
const dispatchArgs = (w: World, i = 0) => w.callsOf('dispatch')[i]?.args ?? []
const isTomb = (v: unknown): boolean => typeof v === 'object' && v !== null && (v as Record<string, unknown>).cancelled === true
const blockOf = (w: World, ctx: { blocks: readonly { name: string; text: string }[] }) => ctx.blocks.find(b => b.name === `${w.name}-resume`)?.text

/** The line a resume-context tag adds to the plain block, or undefined when this build lacks it. */
function lineOf(w: World, tag: 'idle' | 'idle-halt'): string | undefined {
  const rt = { session_id: SID_A, saved_copy: 'x', measured_at: 'x', remeasure: 'x', store: 'x', idle_used_at: 'x' }
  const plain = assemble(w.name, 'resume-context', ['prod-forbid'], rt).split('\n')
  const added = assemble(w.name, 'resume-context', ['prod-forbid', tag], rt).split('\n').filter(l => !plain.includes(l))
  return added.length > 0 ? added.join('\n') : undefined
}

/** The default setup (§6): native vetoed, plan windows, 260K. */
function world(on: Parameters<World['install']>[0], init: ConstructorParameters<typeof World>[0] = {}, store: Record<string, unknown> = {}): World {
  const w = new World(init).install(on, store)
  w.policy = NATIVE_OFF
  w.rateLimits = LIMITS
  return w
}

/** A person's turn that ends at `tokens` (an idle episode starts at its end). */
async function humanTurn($: Engine, w: World, tokens = 260000, reason: 'answer' | 'aborted' = 'answer'): Promise<void> {
  await w.userTurn($)
  w.tokens = tokens
  await w.turnEnd($, 'Done with that step.', reason)
}

// ---- Arming and selecting the kind

test('AT-IC-C01: vetoed at 260K: nothing at 49 min; at 54 min one idle_compact row, one mod-self idle dispatch, shaped, no submit and no continue; idle_mode vetoed/on/on', { options: ON }, async ($, on) => {
  const w = world(on)
  await w.start($)
  await humanTurn($, w)
  await w.advance(49 * MIN)
  expect([w.submits.length, skips(w).length, ic(w).length]).toEqual([0, 0, 0])
  await w.advance(5 * MIN)
  expect(ic(w).map(r => [r.at, r.gap_s, r.tokens, r.agents, r.late_s, r.adopted])).toEqual([['timer', 3240, 260000, 0, 0, false]])
  const args = dispatchArgs(w)
  expect([w.flag(w.callsOf('dispatch')[0], '--channel'), w.flag(w.callsOf('dispatch')[0], '--trigger'), args.includes('--idle=true'), args.includes('--idle-gap-s=3240')])
    .toEqual(['mod-self', 'plugin', true, true])
  expect(w.rowsOf('compacted').map(r => r.skip)).toEqual([null])
  expect([selfCompacts(w), w.submits.length, w.rowsOf('continue').length, skips(w).length]).toEqual([1, 0, 0, 0])
  expect(modes(w)).toEqual(['vetoed/on/on'])
  expect(w.rowsOf('idle_mode')[0]?.compact_min).toBe(200000)
  expect(w.rowsOf('idle_mode')[0]?.cache_s).toBeUndefined()
})

test('AT-IC-C02: the due counts from the start of the last main request (turn.step), not the turn end: a step 5 min before the end compacts 49 min after it', { options: ON }, async ($, on) => {
  const w = world(on)
  await w.start($)
  await w.userTurn($)
  await w.step($)
  await w.advance(5 * MIN)
  w.tokens = 260000
  await w.turnEnd($)
  await w.advance(49 * MIN - 1)
  expect(ic(w).length).toBe(0)
  await w.advance(1)
  expect(ic(w).map(r => r.gap_s)).toEqual([2940])
  expect(selfCompacts(w)).toBe(1)
})

test('AT-IC-C03: a turn that ends (aborted) 53.5 min after its last request: due = end + 60 s; it compacts (no aborted guard)', { options: ON }, async ($, on) => {
  const w = world(on)
  await w.start($)
  await w.userTurn($)
  await w.step($)
  await w.advance(53.5 * MIN)
  w.tokens = 260000
  await w.turnEnd($, 'Stopped.', 'aborted')
  await w.advance(59 * 1000)
  expect(ic(w).length).toBe(0)
  await w.advance(1000)
  expect(ic(w).map(r => r.gap_s)).toEqual([60])
  expect(selfCompacts(w)).toBe(1)
})

test('AT-IC-C04: below the minimum (150K) the 49-min turn is armed instead: it runs with idle_handoff_min_tokens 100000, and skips small (kind turn) at the default floor', { options: { ...ON, idle_handoff_min_tokens: 100000 } }, async ($, on) => {
  const w = world(on)
  await w.start($)
  await humanTurn($, w, 150000)
  await w.advance(49 * MIN)
  expect(ic(w).length).toBe(0)
  if (IDLE) expect([w.submits.length, skips(w)]).toEqual([1, []])
  else expect(skips(w)).toEqual([['no-asset', 'turn']])
  expect(selfCompacts(w)).toBe(0)
})

test('AT-IC-C04: below the minimum at the default floor: the 49-min turn skips small (kind turn), no compaction', { options: ON }, async ($, on) => {
  const w = world(on)
  await w.start($)
  await humanTurn($, w, 150000)
  await w.advance(56 * MIN)
  expect(skips(w)).toEqual([['small', 'turn']])
  expect([ic(w).length, selfCompacts(w)]).toEqual([0, 0])
})

test('AT-IC-C05: CLAUDE_CODE_IDLE_COMPACT_MIN_TOKENS 300000: 260K arms the 49-min turn, no compaction', { options: ON }, async ($, on) => {
  const w = world(on)
  w.env = { CLAUDE_CODE_IDLE_COMPACT_MIN_TOKENS: '300000' }
  await w.start($)
  await humanTurn($, w)
  await w.advance(49 * MIN)
  expect(ic(w).length).toBe(0)
  if (IDLE) expect(w.submits.length).toBe(1)
  else expect(skips(w)).toEqual([['no-asset', 'turn']])
  expect(w.rowsOf('idle_mode')[0]?.compact_min).toBe(300000)
  await w.advance(10 * MIN)
  expect(selfCompacts(w)).toBe(0)
})

test('AT-IC-C05: CLAUDE_CODE_IDLE_COMPACT_MIN_TOKENS 50000: the floor is 100,000; 150K compacts at 54 min', { options: ON }, async ($, on) => {
  const w = world(on)
  w.env = { CLAUDE_CODE_IDLE_COMPACT_MIN_TOKENS: '50000' }
  await w.start($)
  await humanTurn($, w, 150000)
  await w.advance(55 * MIN)
  expect(ic(w).map(r => r.tokens)).toEqual([150000])
  expect(selfCompacts(w)).toBe(1)
  expect(w.rowsOf('idle_mode')[0]?.compact_min).toBe(100000)
})

test('AT-IC-C06: idle_compact off: the 49-min turn as before; idle_mode vetoed/on/off; no compaction', { options: { ...ON, idle_compact: 'off' } }, async ($, on) => {
  const w = world(on)
  await w.start($)
  await humanTurn($, w)
  await w.advance(49 * MIN)
  if (IDLE) expect(w.submits.length).toBe(1)
  else expect(skips(w)).toEqual([['no-asset', 'turn']])
  await w.advance(6 * MIN)
  expect([ic(w).length, selfCompacts(w)]).toEqual([0, 0])
  expect(modes(w)).toEqual(['vetoed/on/off'])
  expect(w.rowsOf('idle_mode')[0]?.compact_min).toBeUndefined()
})

for (const c of [
  { name: 'autoCompactEnabled false', setup: (w: World) => { w.policy = { idleCompaction: false, autoCompactEnabled: false } } },
  { name: 'DISABLE_AUTO_COMPACT=1', setup: (w: World) => { w.env = { DISABLE_AUTO_COMPACT: '1' } } },
  { name: 'DISABLE_COMPACT=true', setup: (w: World) => { w.env = { DISABLE_COMPACT: 'true' } } },
]) {
  test(`AT-IC-C07: ${c.name}: compaction-off/on/off, the 49-min turn path, never a plugin compaction (D1)`, { options: ON }, async ($, on) => {
    const w = world(on)
    c.setup(w)
    await w.start($)
    await humanTurn($, w)
    await w.advance(49 * MIN)
    if (IDLE) expect(w.submits.length).toBe(1)
    else expect(skips(w)).toEqual([['no-asset', 'turn']])
    await w.advance(6 * MIN)
    expect([ic(w).length, selfCompacts(w)]).toEqual([0, 0])
    expect(modes(w)).toEqual(['compaction-off/on/off'])
  })
}

test('AT-IC-C07: DISABLE_COMPACT with native idle on: compaction-off too (it used to arm the 55.5-min check against a native that never fires)', { options: ON }, async ($, on) => {
  const w = world(on)
  w.policy = {}
  w.env = { DISABLE_COMPACT: '1' }
  await w.start($)
  await humanTurn($, w)
  await w.advance(56 * MIN)
  expect(w.rowsOf('idle_silent').length).toBe(0)
  expect(modes(w)).toEqual(['compaction-off/on/off'])
})

test('AT-IC-C08: native on: nothing at 54 min; the 55.5-min check (idle_silent, then the turn or no-asset); idle_mode on/check/agents', { options: ON }, async ($, on) => {
  const w = world(on)
  w.policy = {}
  await w.start($)
  await humanTurn($, w)
  await w.advance(55 * MIN)
  expect([ic(w).length, skips(w).length, w.submits.length]).toEqual([0, 0, 0])
  await w.advance(MIN)
  expect(w.rowsOf('idle_silent').length).toBe(1)
  expect(w.submits.length + skips(w).length).toBe(1)
  expect(modes(w)).toEqual(['on/check/agents'])
  expect(w.rowsOf('idle_mode')[0]?.compact_min).toBe(200000)
})

test('AT-IC-C09: armed vetoed; native switched on at 30 min: [native-on, compact] at 54, then the check re-armed for end + 55.5 min runs', { options: ON }, async ($, on) => {
  const w = world(on)
  await w.start($)
  await humanTurn($, w)
  await w.advance(30 * MIN)
  w.policy = { idleCompaction: true }
  await w.advance(24 * MIN)
  expect(skips(w)).toEqual([['native-on', 'compact']])
  expect(selfCompacts(w)).toBe(0)
  expect(modes(w)).toEqual(['vetoed/on/on', 'on/check/agents'])
  await w.advance(2 * MIN)
  expect(w.rowsOf('idle_silent').length).toBe(1)
  if (IDLE) expect(w.submits.length).toBe(1)
  else expect(skips(w)).toEqual([['native-on', 'compact'], ['no-asset', 'check']])
})

test('AT-IC-C10: agents running: the compaction runs with agents 1, no continue; the turn an agent\'s result opens gets the [idle] block', { options: ON }, async ($, on) => {
  const w = world(on)
  w.agents = RUNNING
  await w.start($)
  await humanTurn($, w)
  await w.advance(54 * MIN)
  expect(ic(w).map(r => r.agents)).toEqual([1])
  expect(selfCompacts(w)).toBe(1)
  await w.advance(5 * MIN)
  expect([w.submits.length, w.rowsOf('continue').length]).toEqual([0, 0])
  await w.userTurn($, 'Agent sub-1 finished.', 'task-notification')
  const block = blockOf(w, await $.prompt.context({ blocks: [] })) ?? ''
  expect(block).toContain(SID_A)
  const idle = lineOf(w, 'idle')
  if (idle !== undefined) expect(block).toContain(idle)
})

// ---- Guards (§2.1)

test('AT-IC-C11: no plan window at the fire (rate limits gone in this load): [ttl-5m, compact], no compaction', { options: ON }, async ($, on) => {
  const w = world(on)
  await w.start($)
  await humanTurn($, w)
  await w.advance(53 * MIN)
  w.rateLimits = []
  await w.advance(MIN)
  expect(skips(w)).toEqual([['ttl-5m', 'compact']])
  expect(selfCompacts(w)).toBe(0)
})

test('AT-IC-C11: a gateway\'s spend_limit only (D15): the record keeps ttl 5m, and the fire skips [ttl-5m, compact]', { options: ON }, async ($, on) => {
  const w = world(on)
  w.rateLimits = [{ kind: 'spend_limit', percentUsed: 10 }]
  await w.start($)
  await humanTurn($, w)
  expect((w.storeGet(KEY) as Record<string, unknown>).ttl).toBe('5m')
  await w.advance(54 * MIN)
  expect(skips(w)).toEqual([['ttl-5m', 'compact']])
  expect(selfCompacts(w)).toBe(0)
})

test('AT-IC-C11: DISABLE_PROMPT_CACHING=1: [ttl-5m, compact]; a per-model switch counts too', { options: ON }, async ($, on) => {
  const w = world(on)
  w.env = { DISABLE_PROMPT_CACHING: '1' }
  await w.start($)
  await humanTurn($, w)
  await w.advance(54 * MIN)
  expect(skips(w)).toEqual([['ttl-5m', 'compact']])
  expect(selfCompacts(w)).toBe(0)
})

for (const [name, limits] of [
  ['a seven-day window at 95%', [{ kind: 'five_hour', percentUsed: 12 }, { kind: 'seven_day', percentUsed: 95 }]],
  ['a gateway\'s spend limit at 95%', [{ kind: 'five_hour', percentUsed: 12 }, { kind: 'spend_limit', percentUsed: 95 }]],
] as const) {
  test(`AT-IC-C12: ${name} at 53 min: [near-limit, compact]`, { options: ON }, async ($, on) => {
    const w = world(on)
    await w.start($)
    await humanTurn($, w)
    await w.advance(53 * MIN)
    w.rateLimits = [...limits]
    await w.advance(MIN)
    expect(skips(w)).toEqual([['near-limit', 'compact']])
    expect(selfCompacts(w)).toBe(0)
  })
}

test('AT-IC-C13: the context fell below the minimum after arming: [small, compact]', { options: ON }, async ($, on) => {
  const w = world(on)
  await w.start($)
  await humanTurn($, w)
  await w.advance(53 * MIN)
  w.tokens = 150000
  await w.advance(MIN)
  expect(skips(w)).toEqual([['small', 'compact']])
})

test('AT-IC-C14: a turn-end plugin compaction still in flight at 54 min: [busy, compact]', { options: ON }, async ($, on) => {
  const w = world(on)
  await w.start($)
  let release!: () => void
  w.compactGate = new Promise<void>(r => { release = r })
  await humanTurn($, w, 410000)
  await w.advance(2000)
  expect(w.compacts.length).toBe(1)
  await w.advance(54 * MIN)
  expect(skips(w)).toEqual([['busy', 'compact']])
  expect(ic(w).length).toBe(0)
  release()
  await w.settle()
})

test('AT-IC-C14: a native compaction running at 54 min: [busy, compact]', { options: ON }, async ($, on) => {
  const w = world(on)
  await w.start($)
  await humanTurn($, w)
  await w.advance(53 * MIN)
  let release!: () => void
  w.compactGate = new Promise<void>(r => { release = r })
  const running = raiseCompact($, { trigger: 'auto' })
  await w.advance(MIN)
  expect(skips(w)).toEqual([['busy', 'compact']])
  release()
  await running
  await w.settle()
})

for (const c of [
  { name: 'a keystroke 30 s before the due', at: 53.5, act: (w: World, $: Engine) => w.edit($), why: 'present' },
  { name: 'a keystroke 66 s before the due', at: 52.9, act: (w: World, $: Engine) => w.edit($), why: null },
  { name: 'a history recall 30 s before the due', at: 53.5, act: (w: World, $: Engine) => w.change($, 'history'), why: 'present' },
  { name: 'a plugin\'s fill 30 s before the due', at: 53.5, act: (w: World, $: Engine) => w.change($, 'plugin'), why: null },
  { name: 'an engine write 30 s before the due', at: 53.5, act: (w: World, $: Engine) => w.change($, 'engine'), why: 'present' },
]) {
  test(`AT-IC-C15 (D11): ${c.name}: ${c.why === null ? 'the compaction runs' : `[${c.why}, compact]`}`, { options: ON }, async ($, on) => {
    const w = world(on)
    await w.start($)
    await humanTurn($, w)
    await w.advance(c.at * MIN)
    await c.act(w, $)
    await w.advance((54 - c.at) * MIN)
    if (c.why === null) {
      expect(skips(w)).toEqual([])
      expect(selfCompacts(w)).toBe(1)
    } else {
      expect(skips(w)).toEqual([[c.why, 'compact']])
      expect(selfCompacts(w)).toBe(0)
    }
  })
}

test('AT-IC-C16: a typed /compact at 30 min, with no turn after it: [compacted, compact]', { options: ON }, async ($, on) => {
  const w = world(on)
  await w.start($)
  await humanTurn($, w)
  await w.advance(30 * MIN)
  await raiseCompact($, { trigger: 'manual' })
  await w.advance(24 * MIN)
  expect(skips(w)).toEqual([['compacted', 'compact']])
  expect(selfCompacts(w)).toBe(0)
})

test('AT-IC-C17: the session id changed at 53 min: [session-changed, compact]', { options: ON }, async ($, on) => {
  const w = world(on)
  await w.start($)
  await humanTurn($, w)
  await w.advance(53 * MIN)
  w.sid = SID_B
  await w.advance(MIN)
  expect(skips(w)).toEqual([['session-changed', 'compact']])
  expect(selfCompacts(w)).toBe(0)
})

for (const c of [
  { name: 'held by another load', write: (rec: Record<string, unknown>) => ({ ...rec, load: 'other-load' }), row: null },
  { name: 'cleared by another load (a tombstone)', write: (rec: Record<string, unknown>) => ({ cancelled: true, sid: SID_A, load: 'other-load', due: rec.due, at: T0 + 50 * MIN }), row: null },
  { name: 'lost (null)', write: () => null, row: 'due-missing' },
]) {
  test(`AT-IC-C18 (G1, D14): the record ${c.name} at 50 min: ${c.row === null ? 'no row at all, the key left as written' : `[${c.row}, compact]`}`, { options: ON }, async ($, on) => {
    const w = world(on)
    await w.start($)
    await humanTurn($, w)
    const rec = w.storeGet(KEY) as Record<string, unknown>
    expect(rec.kind).toBe('compact')
    await w.advance(50 * MIN)
    const written = c.write(rec)
    w.storeSet(KEY, written)
    await w.advance(5 * MIN)
    expect([ic(w).length, selfCompacts(w)]).toEqual([0, 0])
    if (c.row === null) {
      expect(w.rowsOf('handoff_skipped')).toEqual([])
      expect(w.storeGet(KEY)).toEqual(written)
    } else {
      expect(skips(w)).toEqual([[c.row, 'compact']])
    }
  })
}

test('AT-IC-C18: after a fire the key holds a tombstone of this load, gone once every timer for that due has fired (due + 2 min)', { options: ON }, async ($, on) => {
  const w = world(on)
  await w.start($)
  await humanTurn($, w)
  const rec = w.storeGet(KEY) as Record<string, unknown>
  await w.advance(54 * MIN)
  expect(selfCompacts(w)).toBe(1)
  const t = w.storeGet(KEY) as Record<string, unknown>
  expect(isTomb(t)).toBe(true)
  expect([t.sid, t.due, t.load === rec.load]).toEqual([SID_A, rec.due, true])
  await w.advance(2 * MIN + 1000)
  expect(w.storeGet(KEY)).toBeUndefined()
})

test('AT-IC-C18: a person\'s turn start clears the record with a tombstone (no null), and the timer does not fire', { options: ON }, async ($, on) => {
  const w = world(on)
  await w.start($)
  await humanTurn($, w)
  await w.advance(30 * MIN)
  await w.userTurn($)
  expect(isTomb(w.storeGet(KEY))).toBe(true)
  await w.advance(30 * MIN)
  expect([skips(w).length, ic(w).length, selfCompacts(w)]).toEqual([0, 0, 0])
})

test('AT-IC-C19: triggers false: [triggers-off, compact]', { options: { ...ON, triggers: false } }, async ($, on) => {
  const w = world(on)
  await w.start($)
  await humanTurn($, w)
  await w.advance(54 * MIN)
  expect(skips(w)).toEqual([['triggers-off', 'compact']])
})

test('AT-IC-C19: a window too small for plugin compactions (200,000): [small-window, compact]', { options: ON }, async ($, on) => {
  const w = world(on, { window: 200000 })
  await w.start($)
  await humanTurn($, w)
  await w.advance(54 * MIN)
  expect(skips(w)).toEqual([['small-window', 'compact']])
})

test('AT-IC-C20 (D5): halt for thrash, the last turn a background result\'s: [halted, compact]', { options: ON }, async ($, on) => {
  const w = world(on)
  w.files.set(`${WATCH}/${SID_A}/halt.json`, JSON.stringify({ active: true, reason: 'thrash' }))
  await w.start($)
  await w.userTurn($, 'Background task finished.', 'task-notification')
  w.tokens = 260000
  await w.turnEnd($)
  await w.advance(54 * MIN)
  expect(skips(w)).toEqual([['halted', 'compact']])
  expect(selfCompacts(w)).toBe(0)
})

test('AT-IC-C20 (D5): halt for the auto-continue cap: the compaction runs (exempt), no continue; the next background turn\'s block has [idle-halt]', { options: ON }, async ($, on) => {
  const w = world(on)
  w.files.set(`${WATCH}/${SID_A}/halt.json`, JSON.stringify({ active: true, reason: 'cap' }))
  await w.start($)
  await w.userTurn($, 'Background task finished.', 'task-notification')
  w.tokens = 260000
  await w.turnEnd($)
  await w.advance(54 * MIN)
  expect([skips(w), selfCompacts(w), w.submits.length, w.rowsOf('continue').length]).toEqual([[], 1, 0, 0])
  await w.userTurn($, 'Another background task finished.', 'task-notification')
  const block = blockOf(w, await $.prompt.context({ blocks: [] })) ?? ''
  const halt = lineOf(w, 'idle-halt')
  if (halt !== undefined) expect(block).toContain(halt)
})

/** A fake Deps for the guard function alone (no store record, no helper). */
function guardDeps(over: Partial<Deps['state']> = {}): { d: Deps; rec: Due } {
  const state = { ...newState('load-1'), ...over }
  state.eff = { disabled: null } as never
  const rec: Due = {
    due: T0, sid: SID_A, episode: null, kind: 'compact', end: T0 - 54 * MIN, answer: true, published: false, load: 'load-1',
    anchor: T0 - 54 * MIN, tokens: 260000, ttl: '1h', pct: 30, cc: '2.1.311', model: 'claude-test-model',
  }
  const d = {
    cfg: DEFAULTS, state, now: async () => T0, storeGet: async () => undefined,
    usage: async () => ({ tokens: 260000, window: 1000000, rateLimits: LIMITS }),
    version: async () => ({ version: '2.1.311' }), model: async () => 'claude-test-model',
  } as unknown as Deps
  return { d, rec }
}
const ENV = { compactMin: 200000, cacheS: undefined, cacheOff: false }

test('AT-IC-C21: guard function: a turn end after the record\'s (newer-turn), a request after its anchor (newer-turn), a question open (asks-user); none: the tokens', async () => {
  const a = guardDeps()
  a.d.state.lastTurnEndAt = (a.rec.end ?? 0) + 1
  expect(await compactGuards(a.d, SID_A, a.rec, T0, ENV)).toEqual({ why: 'newer-turn' })
  const b = guardDeps({ lastMainReqAt: T0 - 54 * MIN + 1 })
  expect(await compactGuards(b.d, SID_A, b.rec, T0, ENV)).toEqual({ why: 'newer-turn' })
  const c = guardDeps({ askOpen: 1, mainTurnRunning: false })
  expect(await compactGuards(c.d, SID_A, c.rec, T0, ENV)).toEqual({ why: 'asks-user' })
  const ok = guardDeps()
  expect(await compactGuards(ok.d, SID_A, ok.rec, T0, ENV)).toEqual({ tokens: 260000 })
})

test('AT-IC-C41 (D6 b): guard function: an adopted load with ADOPTED_IDLE_COMPACT false skips adopted-cold; a load\'s own record passes', async () => {
  const a = guardDeps({ idleAdopted: true })
  expect(await compactGuards(a.d, SID_A, a.rec, T0, ENV, false)).toEqual({ why: 'adopted-cold' })
  expect(await compactGuards(a.d, SID_A, a.rec, T0, ENV, true)).toEqual({ tokens: 260000 })
  const b = guardDeps({ idleAdopted: false })
  expect(await compactGuards(b.d, SID_A, b.rec, T0, ENV, false)).toEqual({ tokens: 260000 })
})

// ---- Failures and refusals (§1.7, D7, D13)

test('AT-IC-C22 (D7): a hook skips the idle compaction twice in a row: idle_compact_off {failed, 2}; the next turn end arms the 49-min turn (vetoed/on/failed)', { options: ON }, async ($, on) => {
  const w = world(on)
  w.compactMode = { skip: 'hook' }
  await w.start($)
  for (let i = 0; i < 2; i++) {
    await humanTurn($, w)
    await w.advance(55 * MIN)
  }
  expect(w.rowsOf('compacted').map(r => r.skip)).toEqual(['hook', 'hook'])
  expect(w.rowsOf('idle_compact_off').map(r => [r.why, r.fails])).toEqual([['failed', 2]])
  await humanTurn($, w)
  expect(modes(w)).toEqual(['vetoed/on/on', 'vetoed/on/failed'])
  await w.advance(49 * MIN)
  if (IDLE) expect(w.submits.length).toBe(1)
  else expect(skips(w)).toEqual([['no-asset', 'turn']])
  await w.advance(6 * MIN)
  expect(ic(w).length).toBe(2)
})

test('AT-IC-C23 (D7): a failure, a success, a failure: no idle_compact_off (a success resets the count)', { options: ON }, async ($, on) => {
  const w = world(on)
  await w.start($)
  for (const mode of [{ skip: 'hook' }, 'ok', { skip: 'hook' }] as const) {
    w.compactMode = mode
    await humanTurn($, w)
    await w.advance(55 * MIN)
  }
  expect(w.rowsOf('compacted').map(r => r.skip)).toEqual(['hook', null, 'hook'])
  expect(w.rowsOf('idle_compact_off')).toEqual([])
})

// The kit passes no message of a test hook's rejection through (harness.test.ts): a rejected
// self-call reads as class `other` there, which counts. The `turn-running` and `headless` classes
// (Claude Code's own texts) are checked on the counting step itself.
test('AT-IC-C24 (D7): a rejection of class other counts (two in a row: idle_compact_off); turn-running and headless never count, a refusal neither', { options: ON }, async ($, on) => {
  const w = world(on)
  w.compactMode = 'reject'
  await w.start($)
  for (let i = 0; i < 2; i++) {
    await humanTurn($, w)
    await w.advance(55 * MIN)
  }
  expect(w.rowsOf('compact_rejected').map(r => r.error_class)).toEqual(['other', 'other'])
  expect(w.rowsOf('idle_compact_off').map(r => [r.why, r.fails])).toEqual([['failed', 2]])
  const a = guardDeps()
  for (let i = 0; i < 3; i++) await countIdleCompact(a.d, SID_A, { ran: true, ok: false, failClass: 'turn-running' })
  await countIdleCompact(a.d, SID_A, { ran: true, ok: false, failClass: 'headless' })
  await countIdleCompact(a.d, SID_A, { ran: false, why: 'busy' })
  expect([a.d.state.idleCompactFails, a.d.state.idleCompactOff]).toEqual([0, undefined])
  for (const c of ['skipped', 'other', 'failed', 'unclaimed', 'error']) {
    const b = guardDeps()
    await countIdleCompact(b.d, SID_A, { ran: true, ok: false, failClass: c })
    expect([c, b.d.state.idleCompactFails]).toEqual([c, 1])
  }
})

test('AT-IC-C25 (D13): a main turn starts between the guards and the compaction: idle_compact, then [busy, compact] from the boundary\'s result; no dispatch', { options: ON }, async ($, on) => {
  const w = world(on)
  await w.start($)
  await humanTurn($, w)
  let started = false
  w.atHelper = async (sub, args) => {
    if (started || sub !== 'log' || !(args[args.indexOf('--json') + 1] ?? '').includes('"ev":"idle_compact"')) return
    started = true
    await w.turnStart($)
  }
  await w.advance(54 * MIN)
  expect(started).toBe(true)
  expect(ic(w).length).toBe(1)
  expect(skips(w)).toEqual([['busy', 'compact']])
  expect([w.callsOf('dispatch').length, selfCompacts(w)]).toEqual([0, 0])
})

// ---- Headless (lane A: nothing armed)

test('AT-IC-C26a: headless, vetoed, 260K: nothing armed, no idle row; idle_mode vetoed/off/off', { options: ON }, async ($, on) => {
  const w = world(on)
  w.interactive = false
  await w.start($)
  await humanTurn($, w)
  await w.advance(120 * MIN)
  expect([skips(w).length, ic(w).length, w.commandRuns.length, w.submits.length]).toEqual([0, 0, 0, 0])
  expect(modes(w)).toEqual(['vetoed/off/off'])
})

test('AT-IC-C29: headless, native on: nothing armed, no idle row', { options: ON }, async ($, on) => {
  const w = world(on)
  w.policy = {}
  w.interactive = false
  await w.start($)
  await humanTurn($, w)
  await w.advance(120 * MIN)
  expect([skips(w).length, ic(w).length, w.rowsOf('idle_silent').length, w.commandRuns.length]).toEqual([0, 0, 0, 0])
})

// ---- Timer survival (§3.4)

/** A record another process armed 44 min before T0 (due T0 + 10 min unless given). */
function adoptedRecord(w: World, over: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    [KEY]: {
      kind: 'compact', due: T0 + 10 * MIN, sid: SID_A, end: T0 - 44 * MIN, anchor: T0 - 44 * MIN, load: 'old', tokens: 260000, ttl: '1h', pct: 30,
      cc: w.version.version, model: w.model, answer: true, published: false, episode: { since: T0 - 44 * MIN, done: false }, ...over,
    },
  }
}

test('AT-IC-C30: a record adopted by a fresh process (no rate-limit or token reading yet): compacts at its due from the record\'s ttl and tokens; adopted true; the record now names this load', { options: ON }, async ($, on) => {
  const probe = new World()
  const w = world(on, {}, adoptedRecord(probe))
  w.rateLimits = []
  w.tokens = undefined
  await w.start($)
  const held = w.storeGet(KEY) as Record<string, unknown>
  expect(typeof held.load === 'string' && held.load !== 'old').toBe(true)
  await w.advance(10 * MIN)
  expect(skips(w)).toEqual([])
  expect(ic(w).map(r => [r.tokens, r.adopted, r.gap_s])).toEqual([[260000, true, 3240]])
  expect(selfCompacts(w)).toBe(1)
})

test('AT-IC-C31 (§3.4): a due 30 s past at load, with no interactive session.start (a hot reload): it fires at once, late_s 30', { options: ON }, async ($, on) => {
  const probe = new World()
  const w = world(on, { tokens: 260000 }, adoptedRecord(probe, { due: T0 - 30 * 1000, end: T0 - 54.5 * MIN, anchor: T0 - 54.5 * MIN }))
  await $.prompt.context({ blocks: [] })
  await w.settle()
  expect(ic(w).map(r => [r.late_s, r.adopted])).toEqual([[30, true]])
  expect(selfCompacts(w)).toBe(1)
})

test('AT-IC-C31 (§3.4, D11): the same record when a person resumes the session (interactive session.start): [present, compact], late_s 30; no compaction in front of them', { options: ON }, async ($, on) => {
  const probe = new World()
  const w = world(on, { tokens: 260000 }, adoptedRecord(probe, { due: T0 - 30 * 1000, end: T0 - 54.5 * MIN, anchor: T0 - 54.5 * MIN }))
  await w.start($)
  await w.settle()
  expect(w.rowsOf('handoff_skipped').map(r => [r.why, r.kind, r.late_s])).toEqual([['present', 'compact', 30]])
  expect(selfCompacts(w)).toBe(0)
})

test('AT-IC-C32 (§3.4): a due 90 s past at load: [lapsed, compact] with late_s 90; the record is cleared (a tombstone, deleted once expired)', { options: ON }, async ($, on) => {
  const probe = new World()
  const w = world(on, {}, adoptedRecord(probe, { due: T0 - 90 * 1000, end: T0 - 55.5 * MIN, anchor: T0 - 55.5 * MIN }))
  await w.start($)
  await w.settle()
  expect(w.rowsOf('handoff_skipped').map(r => [r.why, r.kind, r.late_s])).toEqual([['lapsed', 'compact', 90]])
  expect(isTomb(w.storeGet(KEY))).toBe(true)
  await w.advance(MIN)
  expect(w.storeGet(KEY)).toBeUndefined()
  expect(selfCompacts(w)).toBe(0)
})

for (const c of [
  { name: 'another Claude Code version', over: { cc: '2.1.310' }, why: 'prefix-changed' },
  { name: 'another main model', over: { model: 'claude-other-model' }, why: 'prefix-changed' },
  { name: 'no version recorded', over: { cc: null }, why: null },
]) {
  test(`AT-IC-C40 (D6 a): an adopted record armed with ${c.name}: ${c.why === null ? 'the compaction runs' : `[${c.why}, compact], no compaction`}`, { options: ON }, async ($, on) => {
    const probe = new World()
    const w = world(on, { tokens: 260000 }, adoptedRecord(probe, c.over))
    await w.start($)
    await w.advance(10 * MIN)
    if (c.why === null) {
      expect([skips(w), selfCompacts(w)]).toEqual([[], 1])
    } else {
      expect(skips(w)).toEqual([[c.why, 'compact']])
      expect(selfCompacts(w)).toBe(0)
    }
  })
}

/** A 49-min turn record 3 min past at T0, armed `endMin` before T0 (null: a legacy record, no end). */
const turnRec = (endMin: number | null) => ({
  [KEY]: {
    kind: 'turn', due: T0 - 3 * MIN, sid: SID_A, answer: true, published: false, episode: { since: T0 - 52 * MIN, done: false },
    ...(endMin === null ? {} : { end: T0 - endMin * MIN }),
  },
})

test('AT-IC-C33 (§3.4): a 49-min turn record 3 min past at load, armed 52 min ago: the turn runs (or no-asset)', { options: { ...ON, idle_compact: 'off' } }, async ($, on) => {
  const w = world(on, { tokens: 260000 }, turnRec(52))
  await $.prompt.context({ blocks: [] })
  await w.settle()
  if (IDLE) expect([w.submits.length, skips(w)]).toEqual([1, []])
  else expect(skips(w)).toEqual([['no-asset', 'turn']])
})

test('AT-IC-C33 (§3.4): the same record armed 57 min ago (past minute 55.5): [lapsed, turn] with late_s 180, no submit', { options: { ...ON, idle_compact: 'off' } }, async ($, on) => {
  const w = world(on, { tokens: 260000 }, turnRec(57))
  await $.prompt.context({ blocks: [] })
  await w.settle()
  expect(w.rowsOf('handoff_skipped').map(r => [r.why, r.kind, r.late_s])).toEqual([['lapsed', 'turn', 180]])
  expect(w.submits.length).toBe(0)
})

test('AT-IC-C33 (§3.4): a legacy record past its due (no turn end): nothing (AT-IC-14 unchanged)', { options: { ...ON, idle_compact: 'off' } }, async ($, on) => {
  const w = world(on, { tokens: 260000 }, turnRec(null))
  await $.prompt.context({ blocks: [] })
  await w.advance(60 * MIN)
  expect([w.rowsOf('handoff_skipped').length, w.submits.length]).toEqual([0, 0])
})

test('AT-IC-C34 (a): the computer sleeps through the due (the wait comes 10 min late): [lapsed, compact] with late_s about 600', { options: ON }, async ($, on) => {
  let slept = false
  // Registered before World.install, so it stands outside the clock (first is outermost).
  on('clock.after', { ms: 54 * MIN }, (_$, e, next) => {
    if (slept) return next(e)
    slept = true
    return next({ ...e, ms: e.ms + 10 * MIN })
  })
  const w = world(on)
  await w.start($)
  await humanTurn($, w)
  await w.advance(65 * MIN)
  expect(slept).toBe(true)
  const r = w.rowsOf('handoff_skipped').map(x => [x.why, x.kind, typeof x.late_s === 'number' && x.late_s >= 60])
  expect(r).toEqual([['lapsed', 'compact', true]])
  expect(selfCompacts(w)).toBe(0)
})

test('AT-IC-C36 (D10): STORE_TEST_IDLE_CACHE_S=600: the compaction at 540 s; idle_mode cache_s 600', { options: ON }, async ($, on) => {
  const w = world(on)
  w.env = { STORE_TEST_IDLE_CACHE_S: '600' }
  await w.start($)
  await humanTurn($, w)
  await w.advance(539 * 1000)
  expect(ic(w).length).toBe(0)
  await w.advance(1000)
  expect(ic(w).map(r => r.gap_s)).toEqual([540])
  expect(selfCompacts(w)).toBe(1)
  expect(w.rowsOf('idle_mode')[0]?.cache_s).toBe(600)
})

test('AT-IC-C36 (D10): STORE_TEST_IDLE_CACHE_S=600 with idle_compact off: the 49-min turn path at 490 s', { options: { ...ON, idle_compact: 'off' } }, async ($, on) => {
  const w = world(on)
  w.env = { STORE_TEST_IDLE_CACHE_S: '600' }
  await w.start($)
  await humanTurn($, w)
  await w.advance(489 * 1000)
  expect(w.submits.length + skips(w).length).toBe(0)
  await w.advance(1000)
  expect(w.submits.length + skips(w).length).toBe(1)
})

for (const v of ['60', 'abc']) {
  test(`AT-IC-C36 (D10): STORE_TEST_IDLE_CACHE_S=${v} is ignored: due at 54 min, no cache_s`, { options: ON }, async ($, on) => {
    const w = world(on)
    w.env = { STORE_TEST_IDLE_CACHE_S: v }
    await w.start($)
    await humanTurn($, w)
    await w.advance(54 * MIN - 1)
    expect(ic(w).length).toBe(0)
    await w.advance(1)
    expect(ic(w).length).toBe(1)
    expect(w.rowsOf('idle_mode')[0]?.cache_s).toBeUndefined()
  })
}

test('AT-IC-C42 (resume-persist): the idle compaction\'s block is on disk at once; a session end with no /clear keeps it, and a resume of the session id in a load delivers it from disk to the first turn, with [idle]', { options: ON }, async ($, on) => {
  const w = world(on)
  await w.start($)
  await humanTurn($, w)
  await w.advance(54 * MIN)
  expect(selfCompacts(w)).toBe(1)
  const pending = `${WATCH}/${SID_A}/${PENDING_FILE}`
  const rec = JSON.parse(w.files.get(pending) ?? '{}') as Record<string, unknown>
  expect([rec.state, rec.session_id]).toEqual(['pending', SID_A])
  // The supervisor's stop: the process ends with no /clear; the next process resumes the id.
  await $.session.end({ reason: 'other', sessionId: SID_A, resume: { id: SID_A } } as never)
  expect(w.rowsOf('mod_outcome')).toEqual([])
  const t = w.files.get(pending)
  if (t !== undefined) {
    w.files.delete(pending)
    w.files.set(`${WATCH}/${SID_A}/${ARMED_FILE}`, t)
  }
  await w.userTurn($, 'where were we?')
  const block = blockOf(w, await $.prompt.context({ blocks: [] })) ?? ''
  expect(block).toContain(SID_A)
  const idle = lineOf(w, 'idle')
  if (idle !== undefined) expect(block).toContain(idle)
  expect(w.rowsOf('mod_outcome').map(r => r.resume)).toEqual(['delivered:prompt.context'])
})

test('AT-IC-C43 (§1.2): after a /clear in the same load, the new session id\'s first turn end writes its own idle_mode row', { options: ON }, async ($, on) => {
  const w = world(on)
  await w.start($)
  await humanTurn($, w)
  await $.session.end({ reason: 'clear', sessionId: SID_A, resume: { id: SID_A } } as never)
  w.sid = SID_B
  await humanTurn($, w)
  expect(w.rowsOf('idle_mode').map(r => [r.sid, `${String(r.native)}/${String(r.plugin_turn)}/${String(r.plugin_compact)}`]))
    .toEqual([[SID_A, 'vetoed/on/on'], [SID_B, 'vetoed/on/on']])
})
