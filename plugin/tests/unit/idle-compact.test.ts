// U tests through the kit: the plugin's own idle compaction (IDLE-COMPACT-SPEC revisions 2 and 3,
// lanes A and B; idle kind `compact`, and the 55.5-min check's compaction of lane B). With
// `"idleCompaction": false` (native `vetoed`) and automatic compaction on, the mod compacts an idle
// main session itself about 54 minutes after its last request, at Claude Code's idle minimum or
// more, behind the guards of §2.1, and replaces the 49-min turn (D2).
// Test ids are AT-IC-Cnn: idle.test.ts already uses AT-IC-01..14 for the IC-1 cases. Cases that
// run the pre-idle turn need the `[submit-idle]` lines of handoff-turn.txt; a build without them
// answers `no-asset`, and those cases accept that instead.
import { expect, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import { assemble, hasTag } from '../../hooks/lib/assemble'
import { DEFAULTS } from '../../hooks/lib/config'
import type { Deps, PendingResume } from '../../hooks/lib/deps'
import { TTL_ENV_NONE, cacheTtlOf, newState, ttlEnvOf } from '../../hooks/lib/deps'
import type { Due } from '../../hooks/lib/idle'
import { IDLE_TICK_MS, cancelIdleTimer, compactGuards, countIdleCompact, schedule } from '../../hooks/lib/idle'
import { PENDING_FILE, ARMED_FILE, pendingRecord } from '../../hooks/lib/resume'
import { SID_A, SID_B, T0, WATCH, World, raiseCompact } from './harness.test'

const IDLE = hasTag('handoff-turn', 'submit-idle')
// `idle_digest: submit` pins the away digest as built (owner xxxxxxxx-09); owner rule (c)
// (2026-10-28) makes `off` the default of 0.1.1, which its own D16 case names.
const ON = { idle_handoff_turn: 'true', precompact_turn: 'false', idle_digest: 'submit' }
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

/**
 * The line a resume-context tag adds to the plain block, or undefined when this build lacks it; it
 * ends before the step-5 digest's Basis, which code renders from the block's own facts (owner
 * 2026-10-27 22:32; lane.test.ts checks it).
 */
function lineOf(w: World, tag: 'idle' | 'idle-halt'): string | undefined {
  const cut = '\u0002'
  const rt = { session_id: SID_A, saved_copy: 'x', measured_at: 'x', remeasure: 'x', store: 'x', idle_used_at: 'x', lane_basis: cut }
  const plain = assemble(w.name, 'resume-context', ['prod-forbid'], rt).split('\n')
  const added = assemble(w.name, 'resume-context', ['prod-forbid', tag], rt).split('\n').filter(l => !plain.includes(l))
  return added.length > 0 ? added.join('\n').split(cut)[0] : undefined
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

test('AT-IC-C06: idle_compact off: the 49-min turn as before; idle_mode vetoed/on/off; no compaction', { options: { ...ON, idle_compact: 'false' } }, async ($, on) => {
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

test('AT-IC-C08 (lane B, owner Q2): native on and silent, no agents: nothing at 54 min; at 55.5 min idle_silent, then the plugin\'s own compaction (at check, agents 0), no turn; idle_mode on/check/check', { options: ON }, async ($, on) => {
  const w = world(on)
  w.policy = {}
  await w.start($)
  await humanTurn($, w)
  await w.advance(55 * MIN)
  expect([ic(w).length, skips(w).length, w.submits.length]).toEqual([0, 0, 0])
  await w.advance(MIN)
  expect(w.rowsOf('idle_silent').length).toBe(1)
  expect(ic(w).map(r => [r.at, r.gap_s, r.tokens, r.agents, r.late_s, r.adopted])).toEqual([['check', 3330, 260000, 0, 0, false]])
  expect([selfCompacts(w), w.rowsOf('compacted').map(r => r.skip), skips(w), w.submits.length]).toEqual([1, [null], [], 0])
  expect(dispatchArgs(w)).toContain('--idle=true')
  expect(modes(w)).toEqual(['on/check/check'])
  expect(w.rowsOf('idle_mode')[0]?.compact_min).toBe(200000)
})

test('AT-IC-C08 (lane B): native on with idle_compact off: the 55.5-min check runs the turn (or no-asset), no compaction; idle_mode on/check/off', { options: { ...ON, idle_compact: 'false' } }, async ($, on) => {
  const w = world(on)
  w.policy = {}
  await w.start($)
  await humanTurn($, w)
  await w.advance(56 * MIN)
  expect(w.rowsOf('idle_silent').length).toBe(1)
  expect([ic(w).length, selfCompacts(w)]).toEqual([0, 0])
  if (IDLE) expect([w.submits.length, skips(w)]).toEqual([1, []])
  else expect(skips(w)).toEqual([['no-asset', 'check']])
  expect(modes(w)).toEqual(['on/check/off'])
  expect(w.rowsOf('idle_mode')[0]?.compact_min).toBe(undefined)
})

// Owner xxxxxxxx (2026-10-30, "I want the handoff anyway"): the check's turn goes through the same
// gate as the 49-min one; only idle_handoff_near_limit `skip` skips it at a window of 90% or more
// (`skip-spend`, 0.1.2: a plan window is not a spend limit, so the turn runs as under `run`).
for (const mode of ['run', 'skip-spend', 'skip'] as const) {
  test(`AT-IC-C08 (lane B, near-limit): native on, idle_compact off, a window at 95% at the check, idle_handoff_near_limit ${mode}: ${mode !== 'skip' ? 'the turn runs (or no-asset)' : '[near-limit, check], no turn'}`, { options: { ...ON, idle_compact: 'false', idle_handoff_near_limit: mode } }, async ($, on) => {
    const w = world(on)
    w.policy = {}
    await w.start($)
    await humanTurn($, w)
    await w.advance(55 * MIN)
    w.rateLimits = [{ kind: 'five_hour', percentUsed: 12 }, { kind: 'seven_day', percentUsed: 95 }]
    await w.measure($)
    await w.advance(MIN)
    expect(w.rowsOf('idle_silent').length).toBe(1)
    expect([ic(w).length, selfCompacts(w)]).toEqual([0, 0])
    if (mode === 'skip') expect([w.submits.length, skips(w)]).toEqual([0, [['near-limit', 'check']]])
    else if (IDLE) expect([w.submits.length, skips(w)]).toEqual([1, []])
    else expect(skips(w)).toEqual([['no-asset', 'check']])
  })
}

test('AT-IC-C09: armed vetoed; native switched on at 30 min: [native-on, compact] at 54, then the check re-armed for end + 55.5 min runs', { options: ON }, async ($, on) => {
  const w = world(on)
  await w.start($)
  await humanTurn($, w)
  await w.advance(30 * MIN)
  w.policy = { idleCompaction: true }
  await w.advance(24 * MIN)
  expect(skips(w)).toEqual([['native-on', 'compact']])
  expect([ic(w).length, selfCompacts(w)]).toEqual([0, 0])
  expect(modes(w)).toEqual(['vetoed/on/on', 'on/check/check'])
  await w.advance(2 * MIN)
  expect(w.rowsOf('idle_silent').length).toBe(1)
  // Lane B (owner Q2): native stayed silent, so the check compacts instead of running the turn.
  expect([ic(w).map(r => r.at), selfCompacts(w), w.submits.length]).toEqual([['check'], 1, 0])
})

test('AT-IC-C09 (G0a): the settings unreadable at the fire: [native-unknown, compact], and the check armed for end + 55.5 min', { options: ON }, async ($, on) => {
  const w = world(on)
  await w.start($)
  await humanTurn($, w)
  const rec = w.storeGet(KEY) as Record<string, unknown>
  await w.advance(30 * MIN)
  w.settingsThrow = true
  await w.advance(24 * MIN)
  expect(skips(w)).toEqual([['native-unknown', 'compact']])
  expect([ic(w).length, selfCompacts(w)]).toEqual([0, 0])
  const next = w.storeGet(KEY) as Record<string, unknown>
  expect([next.kind, next.due]).toEqual(['check', (rec.end as number) + 55.5 * MIN])
  expect(modes(w)).toEqual(['vetoed/on/on', 'unknown/check/check'])
})

test('AT-IC-C07 (G0b): automatic compaction switched off after the arm (DISABLE_AUTO_COMPACT at 30 min): [compaction-off, compact] at 54, no compaction', { options: ON }, async ($, on) => {
  const w = world(on)
  await w.start($)
  await humanTurn($, w)
  await w.advance(30 * MIN)
  w.env = { DISABLE_AUTO_COMPACT: '1' }
  await w.advance(24 * MIN)
  expect(skips(w)).toEqual([['compaction-off', 'compact']])
  expect([ic(w).length, selfCompacts(w)]).toEqual([0, 0])
  expect(modes(w)).toEqual(['vetoed/on/on', 'compaction-off/on/off'])
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
  expect([ic(w).length, selfCompacts(w)]).toEqual([0, 0])
})

test('AT-IC-C11: a gateway\'s spend_limit only (D15): the record keeps ttl 5m, and the fire skips [ttl-5m, compact]', { options: ON }, async ($, on) => {
  const w = world(on)
  w.rateLimits = [{ kind: 'spend_limit', percentUsed: 10 }]
  await w.start($)
  await humanTurn($, w)
  expect((w.storeGet(KEY) as Record<string, unknown>).ttl).toBe('5m')
  await w.advance(54 * MIN)
  expect(skips(w)).toEqual([['ttl-5m', 'compact']])
  expect([ic(w).length, selfCompacts(w)]).toEqual([0, 0])
})

test('AT-IC-C11: DISABLE_PROMPT_CACHING=1: [ttl-5m, compact]; a per-model switch counts too', { options: ON }, async ($, on) => {
  const w = world(on)
  w.env = { DISABLE_PROMPT_CACHING: '1' }
  await w.start($)
  await humanTurn($, w)
  await w.advance(54 * MIN)
  expect(skips(w)).toEqual([['ttl-5m', 'compact']])
  expect([ic(w).length, selfCompacts(w)]).toEqual([0, 0])
})

/** A TTL switch case: the environment and the settings keys beside `idleCompaction: false`. */
type TtlCase = { name: string; env: Record<string, string>; set: Record<string, unknown> }

test('AT-IC-C11 (G11): Claude Code\'s own prompt-cache TTL switches, in its order (ttlEnvOf, cacheTtlOf)', () => {
  const t = (v: Parameters<typeof ttlEnvOf>[0], setting?: unknown) => cacheTtlOf(ttlEnvOf(v), setting)
  // Unset or not a value Claude Code takes: automatic (the plan windows decide).
  expect([t({}), t({}, '1H'), t({ ttl: '1H' }), t({ ttl: '2h' }), t({ force5m: '0' }), t({ messages: '1h' }), t({ enable1h: 'no' })])
    .toEqual([undefined, undefined, undefined, undefined, undefined, undefined, undefined])
  // FORCE_PROMPT_CACHING_5M, then CLAUDE_CODE_PROMPT_CACHE_TTL, then the setting, then ENABLE_PROMPT_CACHING_1H;
  // CLAUDE_CODE_MESSAGES_PROMPT_CACHE_TTL 5m over all of them.
  expect([t({ force5m: '1' }), t({ force5m: ' Yes ', ttl: '1h' }, '1h'), t({ ttl: ' 5m ' }, '1h'), t({}, '5m'), t({ enable1h: '1' }, '5m'), t({ messages: '5m' }, '1h'), t({ messages: ' 5m ', ttl: '1h', enable1h: 'on' })])
    .toEqual(['5m', '5m', '5m', '5m', '5m', '5m', '5m'])
  expect([t({ ttl: '1h' }, '5m'), t({}, '1h'), t({ enable1h: 'true' }), t({ ttl: '1h', enable1h: '1' })]).toEqual(['1h', '1h', '1h', '1h'])
})

for (const c of [
  { name: 'FORCE_PROMPT_CACHING_5M=1', env: { FORCE_PROMPT_CACHING_5M: '1' }, set: {} },
  { name: 'CLAUDE_CODE_PROMPT_CACHE_TTL=5m', env: { CLAUDE_CODE_PROMPT_CACHE_TTL: '5m' }, set: {} },
  { name: 'the promptCacheTtl setting 5m', env: {}, set: { promptCacheTtl: '5m' } },
  { name: 'CLAUDE_CODE_MESSAGES_PROMPT_CACHE_TTL=5m over a 1h setting', env: { CLAUDE_CODE_MESSAGES_PROMPT_CACHE_TTL: '5m' }, set: { promptCacheTtl: '1h' } },
  { name: 'FORCE_PROMPT_CACHING_5M over CLAUDE_CODE_PROMPT_CACHE_TTL=1h', env: { FORCE_PROMPT_CACHING_5M: 'true', CLAUDE_CODE_PROMPT_CACHE_TTL: '1h' }, set: {} },
  { name: 'the setting 5m over ENABLE_PROMPT_CACHING_1H', env: { ENABLE_PROMPT_CACHING_1H: '1' }, set: { promptCacheTtl: '5m' } },
] as TtlCase[]) {
  test(`AT-IC-C11 (G11): a five-minute cache set by ${c.name}, plan windows reported: the record keeps ttl 5m; [ttl-5m, compact]`, { options: ON }, async ($, on) => {
    const w = world(on)
    w.env = c.env
    w.policy = { ...NATIVE_OFF, ...c.set }
    await w.start($)
    await humanTurn($, w)
    expect((w.storeGet(KEY) as Record<string, unknown>).ttl).toBe('5m')
    await w.advance(54 * MIN)
    expect(skips(w)).toEqual([['ttl-5m', 'compact']])
    expect([ic(w).length, selfCompacts(w)]).toEqual([0, 0])
  })
}

test('AT-IC-C11 (G11): the promptCacheTtl setting changed to 5m after the arm (read at the fire): [ttl-5m, compact]', { options: ON }, async ($, on) => {
  const w = world(on)
  await w.start($)
  await humanTurn($, w)
  expect((w.storeGet(KEY) as Record<string, unknown>).ttl).toBe('1h')
  await w.advance(30 * MIN)
  w.policy = { ...NATIVE_OFF, promptCacheTtl: '5m' }
  await w.advance(24 * MIN)
  expect(skips(w)).toEqual([['ttl-5m', 'compact']])
  expect([ic(w).length, selfCompacts(w)]).toEqual([0, 0])
})

for (const c of [
  { name: 'CLAUDE_CODE_PROMPT_CACHE_TTL=1h', env: { CLAUDE_CODE_PROMPT_CACHE_TTL: ' 1h ' }, set: {} },
  { name: 'the promptCacheTtl setting 1h', env: {}, set: { promptCacheTtl: '1h' } },
  { name: 'ENABLE_PROMPT_CACHING_1H=1', env: { ENABLE_PROMPT_CACHING_1H: '1' }, set: {} },
  { name: 'CLAUDE_CODE_PROMPT_CACHE_TTL=1h over a 5m setting', env: { CLAUDE_CODE_PROMPT_CACHE_TTL: '1h' }, set: { promptCacheTtl: '5m' } },
] as TtlCase[]) {
  test(`AT-IC-C11 (G11): a one-hour cache set by ${c.name} with no plan window (an API key): the record keeps ttl 1h; the compaction runs`, { options: ON }, async ($, on) => {
    const w = world(on)
    w.env = c.env
    w.policy = { ...NATIVE_OFF, ...c.set }
    w.rateLimits = []
    await w.start($)
    await humanTurn($, w)
    expect((w.storeGet(KEY) as Record<string, unknown>).ttl).toBe('1h')
    await w.advance(54 * MIN)
    expect(skips(w)).toEqual([])
    expect([ic(w).length, selfCompacts(w)]).toEqual([1, 1])
  })
}

test('AT-IC-C11 (G11): prompt caching off wins over a one-hour switch: DISABLE_PROMPT_CACHING with promptCacheTtl 1h is [ttl-5m, compact]; the record keeps ttl 5m', { options: ON }, async ($, on) => {
  const w = world(on)
  w.env = { DISABLE_PROMPT_CACHING: '1' }
  w.policy = { ...NATIVE_OFF, promptCacheTtl: '1h' }
  await w.start($)
  await humanTurn($, w)
  expect((w.storeGet(KEY) as Record<string, unknown>).ttl).toBe('5m')
  await w.advance(54 * MIN)
  expect(skips(w)).toEqual([['ttl-5m', 'compact']])
})

test('AT-IC-C11 (G11, the 49-min turn): CLAUDE_CODE_PROMPT_CACHE_TTL=5m with plan windows: [ttl-5m, turn], no submit', { options: { ...ON, idle_compact: 'false' } }, async ($, on) => {
  const w = world(on)
  w.env = { CLAUDE_CODE_PROMPT_CACHE_TTL: '5m' }
  await w.start($)
  await humanTurn($, w)
  await w.advance(49 * MIN)
  expect(skips(w)).toEqual([['ttl-5m', 'turn']])
  expect(w.submits.length).toBe(0)
})

test('AT-IC-C11 (G11, the 49-min turn): the promptCacheTtl setting 1h with no plan window: the turn runs (or no-asset), not ttl-5m', { options: { ...ON, idle_compact: 'false' } }, async ($, on) => {
  const w = world(on)
  w.policy = { ...NATIVE_OFF, promptCacheTtl: '1h' }
  w.rateLimits = []
  await w.start($)
  await humanTurn($, w)
  await w.advance(49 * MIN)
  if (IDLE) expect([w.submits.length, skips(w)]).toEqual([1, []])
  else expect(skips(w)).toEqual([['no-asset', 'turn']])
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
    await w.measure($)
    await w.advance(MIN)
    expect(skips(w)).toEqual([['near-limit', 'compact']])
    expect([ic(w).length, selfCompacts(w)]).toEqual([0, 0])
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
  expect([ic(w).length, selfCompacts(w)]).toEqual([0, 0])
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
  expect(ic(w).length).toBe(0)
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
      expect([ic(w).length, selfCompacts(w)]).toEqual([0, 0])
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
  expect([ic(w).length, selfCompacts(w)]).toEqual([0, 0])
})

test('AT-IC-C17: the session id changed at 53 min: [session-changed, compact]', { options: ON }, async ($, on) => {
  const w = world(on)
  await w.start($)
  await humanTurn($, w)
  await w.advance(53 * MIN)
  w.sid = SID_B
  await w.advance(MIN)
  expect(skips(w)).toEqual([['session-changed', 'compact']])
  expect([ic(w).length, selfCompacts(w)]).toEqual([0, 0])
})

for (const c of [
  { name: 'held by another load', write: (rec: Record<string, unknown>) => ({ ...rec, load: 'other-load' }), row: null },
  { name: 'cleared by another load (a tombstone)', write: (rec: Record<string, unknown>) => ({ cancelled: true, sid: SID_A, load: 'other-load', due: rec.due, at: T0 + 50 * MIN }), row: null },
  { name: 'lost (null)', write: () => null, row: 'due-missing' },
  { name: 'rewritten by this load with another due (its older timer still pending)', write: (rec: Record<string, unknown>) => ({ ...rec, due: (rec.due as number) + 5 * MIN }), row: null },
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

test('AT-IC-C18 (§3.1): turn after turn leaves one pending tombstone delete per session id, not one per turn start', { options: ON }, async ($, on) => {
  let reads = 0
  // Registered before World.install, so it stands outside the store (first is outermost).
  on('store.get', { key: KEY }, (_$, e, next) => {
    reads++
    return next(e)
  })
  const w = world(on)
  await w.start($)
  for (let i = 0; i < 5; i++) {
    await humanTurn($, w)
    await w.advance(MIN)
  }
  // A last person's turn starts and runs on: its start clears the record with a tombstone.
  await w.userTurn($)
  expect(isTomb(w.storeGet(KEY))).toBe(true)
  reads = 0
  await w.advance(60 * MIN)
  // Only that tombstone's own delete is still pending: one read, and the key is gone.
  expect(reads).toBe(1)
  expect(w.storeGet(KEY)).toBeUndefined()
})

test('AT-IC-C39 (D14): a stale process (the record now held by another load) with native idle switched on: G1 before G0a, so no row, no check armed, the key unchanged', { options: ON }, async ($, on) => {
  const w = world(on)
  await w.start($)
  await humanTurn($, w)
  const rec = w.storeGet(KEY) as Record<string, unknown>
  expect(rec.kind).toBe('compact')
  await w.advance(30 * MIN)
  const written = { ...rec, load: 'other-load' }
  w.storeSet(KEY, written)
  w.policy = {}
  await w.advance(24 * MIN)
  expect(w.rowsOf('handoff_skipped')).toEqual([])
  expect(w.storeGet(KEY)).toEqual(written)
  // No policy read at that fire (no new idle_mode row) and no 55.5-min check persisted or run.
  expect(modes(w)).toEqual(['vetoed/on/on'])
  await w.advance(5 * MIN)
  expect([w.rowsOf('idle_silent').length, ic(w).length, selfCompacts(w), w.submits.length]).toEqual([0, 0, 0, 0])
  expect(w.storeGet(KEY)).toEqual(written)
})

test('AT-IC-C19: triggers false: [triggers-off, compact]', { options: { ...ON, triggers: false } }, async ($, on) => {
  const w = world(on)
  await w.start($)
  await humanTurn($, w)
  await w.advance(54 * MIN)
  expect(skips(w)).toEqual([['triggers-off', 'compact']])
  expect([ic(w).length, selfCompacts(w)]).toEqual([0, 0])
})

test('AT-IC-C19: a window too small for plugin compactions (200,000): [small-window, compact]', { options: ON }, async ($, on) => {
  const w = world(on, { window: 200000 })
  await w.start($)
  await humanTurn($, w)
  await w.advance(54 * MIN)
  expect(skips(w)).toEqual([['small-window', 'compact']])
  expect([ic(w).length, selfCompacts(w)]).toEqual([0, 0])
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
  expect([ic(w).length, selfCompacts(w)]).toEqual([0, 0])
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
    anchor: T0 - 54 * MIN, tokens: 260000, ttl: '1h', pct: 30, spct: null, cc: '2.1.311', model: 'claude-test-model',
  }
  const d = {
    cfg: DEFAULTS, state, now: async () => T0, storeGet: async () => undefined,
    usage: async () => ({ tokens: 260000, window: 1000000, rateLimits: LIMITS }),
    version: async () => ({ version: '2.1.311' }), model: async () => 'claude-test-model', promptCacheTtl: async () => undefined,
  } as unknown as Deps
  return { d, rec }
}
const ENV = { compactMin: 200000, cacheS: undefined, cacheOff: false, ttl: TTL_ENV_NONE }

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

test('AT-IC-C25 (D13, §9.1): the 55.5-min check\'s compaction while agents run: a main turn starting at its idle_compact row gives [busy, check] from the boundary\'s result', { options: ON }, async ($, on) => {
  const w = world(on)
  w.policy = {}
  w.agents = RUNNING
  await w.start($)
  await humanTurn($, w)
  let started = false
  w.atHelper = async (sub, args) => {
    if (started || sub !== 'log' || !(args[args.indexOf('--json') + 1] ?? '').includes('"ev":"idle_compact"')) return
    started = true
    await w.turnStart($)
  }
  await w.advance(56 * MIN)
  expect(started).toBe(true)
  expect(ic(w).map(r => r.at)).toEqual(['check'])
  expect(skips(w)).toEqual([['busy', 'check']])
  expect([w.callsOf('dispatch').length, selfCompacts(w)]).toEqual([0, 0])
})

for (const c of [
  { name: 'a person\'s whole turn', why: 'newer-turn', act: async (w: World, $: Engine) => { await w.userTurn($); w.tokens = 260000; await w.turnEnd($) } },
  { name: 'a keystroke', why: 'present', act: (w: World, $: Engine) => w.edit($) },
]) {
  test(`AT-IC-C25 (D13): ${c.name} while the checkpoint runs: idle_compact, then [${c.why}, compact] before the dispatch record; no compaction, no failure counted`, { options: ON }, async ($, on) => {
    const w = world(on)
    await w.start($)
    await humanTurn($, w)
    let acted = false
    w.atHelper = async sub => {
      if (acted || sub !== 'checkpoint') return
      acted = true
      await c.act(w, $)
    }
    await w.advance(54 * MIN)
    expect(acted).toBe(true)
    expect(ic(w).length).toBe(1)
    expect(skips(w)).toEqual([[c.why, 'compact']])
    expect([w.callsOf('dispatch').length, selfCompacts(w), w.rowsOf('idle_compact_off').length]).toEqual([0, 0, 0])
  })
}

/** The plugin's own idle dispatches (`--channel mod-self`); a native compaction's record is `mod-hook`. */
const modSelf = (w: World) => w.callsOf('dispatch').filter(c => w.flag(c, '--channel') === 'mod-self').length

/** Lets the engine's pending work run while the test holds a helper call open (no clock involved). */
async function until(cond: () => boolean, rounds = 20000): Promise<void> {
  for (let i = 0; i < rounds && !cond(); i++) await Promise.resolve()
}

test('AT-IC-C25 (D13, G6): a compaction other than ours (a /compact sent from a phone) runs to its end while the checkpoint runs: idle_compact, then [compacted, compact]; no mod-self dispatch, no failure counted', { options: ON }, async ($, on) => {
  const w = world(on)
  await w.start($)
  await humanTurn($, w)
  let acted = false
  w.atHelper = async sub => {
    if (acted || sub !== 'checkpoint') return
    acted = true
    await raiseCompact($, { trigger: 'manual' })
  }
  await w.advance(54 * MIN)
  expect(acted).toBe(true)
  expect(ic(w).length).toBe(1)
  expect(skips(w)).toEqual([['compacted', 'compact']])
  expect([modSelf(w), selfCompacts(w), w.rowsOf('idle_compact_off').length]).toEqual([0, 0, 0])
  expect(w.compacts.filter(c => c.trigger === 'manual').length).toBe(1)
})

test('AT-IC-C25 (D13, G4): a compaction other than ours starts while the checkpoint runs and is still running after it: idle_compact, then [busy, compact]; no mod-self dispatch', { options: ON }, async ($, on) => {
  const w = world(on)
  await w.start($)
  await humanTurn($, w)
  let release: (() => void) | undefined
  let running: Promise<unknown> | undefined
  w.atHelper = async sub => {
    if (running !== undefined || sub !== 'checkpoint') return
    w.compactGate = new Promise<void>(r => { release = r })
    const n = w.compacts.length
    running = raiseCompact($, { trigger: 'manual' })
    await until(() => w.compacts.length > n)
  }
  await w.advance(54 * MIN)
  expect(running).toBeDefined()
  expect(ic(w).length).toBe(1)
  expect(skips(w)).toEqual([['busy', 'compact']])
  expect([modSelf(w), selfCompacts(w), w.rowsOf('idle_compact_off').length]).toEqual([0, 0, 0])
  release?.()
  await running
  await w.settle()
})

test('AT-IC-C25 (§2.3): G1\'s own store read throws at the fire: one [error, compact] row; no compaction', { options: ON }, async ($, on) => {
  let boom = false
  on('store.get', { key: KEY }, (_$, e, next) => {
    if (boom) throw new Error('store unreadable')
    return next(e)
  })
  const w = world(on)
  await w.start($)
  await humanTurn($, w)
  await w.advance(53 * MIN)
  boom = true
  await w.advance(MIN)
  expect(skips(w)).toEqual([['error', 'compact']])
  expect([ic(w).length, selfCompacts(w)]).toEqual([0, 0])
})

test('AT-IC-C25 (§2.3, the 49-min turn): a read that throws in the turn\'s checks is one [error, turn] row; no submit', { options: { ...ON, idle_compact: 'false' } }, async ($, on) => {
  let boom = false
  on('store.get', { key: 'ht:' + SID_A }, (_$, e, next) => {
    if (boom) throw new Error('store unreadable')
    return next(e)
  })
  const w = world(on)
  await w.start($)
  await humanTurn($, w)
  await w.advance(48 * MIN)
  boom = true
  await w.advance(MIN)
  expect(skips(w)).toEqual([['error', 'turn']])
  expect(w.submits.length).toBe(0)
})

test('AT-IC-C25 (§2.3, the 55.5-min check): a read that throws in the check is one [error, check] row; no idle_silent, no submit', { options: ON }, async ($, on) => {
  let boom = false
  on('store.get', { key: 'idle_seen:' + SID_A }, (_$, e, next) => {
    if (boom) throw new Error('store unreadable')
    return next(e)
  })
  const w = world(on)
  w.policy = {}
  await w.start($)
  await humanTurn($, w)
  await w.advance(55 * MIN)
  boom = true
  await w.advance(MIN)
  expect(skips(w)).toEqual([['error', 'check']])
  expect([w.rowsOf('idle_silent').length, w.submits.length]).toEqual([0, 0])
})

test('AT-IC-C25 (§2.3): a guard read that throws at the fire is one [error, compact] row; no idle_compact row, no compaction', { options: ON }, async ($, on) => {
  let boom = false
  on('store.get', { key: 'idle_seen:' + SID_A }, (_$, e, next) => {
    if (boom) throw new Error('store unreadable')
    return next(e)
  })
  const w = world(on)
  await w.start($)
  await humanTurn($, w)
  await w.advance(53 * MIN)
  boom = true
  await w.advance(MIN)
  expect(skips(w)).toEqual([['error', 'compact']])
  expect([ic(w).length, selfCompacts(w)]).toEqual([0, 0])
})

test('AT-IC-C25 (§2.3, D7): a throw inside the compaction step is one [error, compact] row after idle_compact and counts as a failure (two in a row: idle_compact_off)', { options: ON }, async ($, on) => {
  let boom = false
  const w = world(on)
  // The first usage read after the idle_compact row (the boundary's own) fails once.
  let tokens: number | undefined = w.tokens
  Object.defineProperty(w, 'tokens', {
    configurable: true,
    get: () => {
      if (!boom) return tokens
      boom = false
      throw new Error('usage unreadable')
    },
    set: (v: number | undefined) => { tokens = v },
  })
  w.atHelper = async (sub, args) => {
    if (sub === 'log' && (args[args.indexOf('--json') + 1] ?? '').includes('"ev":"idle_compact"')) boom = true
  }
  await w.start($)
  for (let i = 0; i < 2; i++) {
    await humanTurn($, w)
    await w.advance(55 * MIN)
  }
  expect(ic(w).length).toBe(2)
  expect(skips(w)).toEqual([['error', 'compact'], ['error', 'compact']])
  expect(selfCompacts(w)).toBe(0)
  expect(w.rowsOf('idle_compact_off').map(r => [r.why, r.fails])).toEqual([['failed', 2]])
})

test('AT-IC-C25 (§1.7): a throw in the bookkeeping after a compaction that ran is no failure: no error row, and two in a row do not turn it off', { options: ON }, async ($, on) => {
  let boom = false
  let thrown = 0
  // Outside mock.clock: the first clock read after the compaction answered fails once.
  on('clock.now', {}, (_$, e, next) => {
    if (!boom) return next(e)
    boom = false
    thrown++
    throw new Error('clock unreadable')
  })
  const w = world(on)
  w.atCompact = () => { boom = true }
  await w.start($)
  for (let i = 0; i < 2; i++) {
    await humanTurn($, w)
    await w.advance(55 * MIN)
  }
  expect(thrown).toBe(2)
  expect([ic(w).length, selfCompacts(w)]).toEqual([2, 2])
  // The compacted row is the step that failed: none was written.
  expect(w.rowsOf('compacted')).toEqual([])
  expect(skips(w)).toEqual([])
  expect(w.rowsOf('idle_compact_off')).toEqual([])
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

test('AT-IC-C30 (G12, D-83): a record adopted by a fresh process, armed at a 95% window, with no rate-limit reading yet: the record\'s share was read at its turn end, so it is no fresh reading and decides nothing: the compaction runs (rule no-fresh on its row)', { options: ON }, async ($, on) => {
  const probe = new World()
  const w = world(on, {}, adoptedRecord(probe, { pct: 95 }))
  w.rateLimits = []
  w.tokens = undefined
  await w.start($)
  await w.advance(10 * MIN)
  expect(skips(w)).toEqual([])
  expect(ic(w).map(r => [r.rule, r.windows, r.usage_src])).toEqual([['no-fresh', ['arm:95'], ['arm:plugin']]])
  expect(selfCompacts(w)).toBe(1)
})

/** A 49-min turn record another process armed 39 min before T0 (due T0 + 10 min), with what it read at arm. */
const adoptedTurn = (ttl: string | null, pct = 30, spct?: number) => ({
  [KEY]: {
    kind: 'turn', due: T0 + 10 * MIN, sid: SID_A, end: T0 - 39 * MIN, anchor: T0 - 39 * MIN, load: 'old', tokens: 260000, ttl, pct,
    ...(spct === undefined ? {} : { spct }),
    cc: null, model: null, answer: true, published: false, episode: { since: T0 - 39 * MIN, done: false },
  },
})

test('AT-IC-C30 (turn; §9.2, G11/D15): a 49-min turn record adopted by a fresh process with no rate-limit or token reading yet: the record\'s ttl, tokens and pct decide, so the turn runs (or no-asset), not ttl-5m or small', { options: { ...ON, idle_compact: 'false' } }, async ($, on) => {
  const w = world(on, {}, adoptedTurn('1h'))
  w.rateLimits = []
  w.tokens = undefined
  await w.start($)
  await w.advance(10 * MIN)
  if (IDLE) expect([w.submits.length, skips(w)]).toEqual([1, []])
  else expect(skips(w)).toEqual([['no-asset', 'turn']])
})

test('AT-IC-C30 (turn; §9.2): the same record with no ttl recorded (an older build armed it): [ttl-5m, turn], no submit', { options: { ...ON, idle_compact: 'false' } }, async ($, on) => {
  const w = world(on, {}, adoptedTurn(null))
  w.rateLimits = []
  w.tokens = undefined
  await w.start($)
  await w.advance(10 * MIN)
  expect(skips(w)).toEqual([['ttl-5m', 'turn']])
  expect(w.submits.length).toBe(0)
})

// Owner xxxxxxxx (2026-10-30): with no rate-limit reading the record's share is the reading, and
// only idle_handoff_near_limit `skip` checks it; D-83: read at the record's turn end (49 min
// before), it is no fresh reading, so it skips nothing under `skip` either.
for (const mode of ['run', 'skip'] as const) {
  test(`AT-IC-C30 (turn, G12, D-83): the adopted 49-min turn record armed at a 95% window, no reading yet, idle_handoff_near_limit ${mode}: the turn runs (or no-asset)`, { options: { ...ON, idle_compact: 'false', idle_handoff_near_limit: mode } }, async ($, on) => {
    const w = world(on, {}, adoptedTurn('1h', 95))
    w.rateLimits = []
    w.tokens = undefined
    await w.start($)
    await w.advance(10 * MIN)
    if (IDLE) expect([w.submits.length, skips(w)]).toEqual([1, []])
    else expect(skips(w)).toEqual([['no-asset', 'turn']])
  })
}

// 0.1.2: under `skip-spend` the record's spend share (`spct`) is the reading, not its highest
// share: a record armed at a 95% plan window runs the turn; one an older build armed (no `spct`)
// reads as no spend limit, so the turn runs; D-83: one armed at a 95% spend limit 49 min before
// is no fresh reading, so it runs too.
for (const c of [{ name: 'a 95% plan window, no spend limit', spct: null, skip: false }, { name: 'a 95% spend limit', spct: 95, skip: false }, { name: 'no spct (an older build)', spct: undefined, skip: false }]) {
  test(`AT-IC-C30 (turn, G12, skip-spend): the adopted 49-min turn record armed at ${c.name}, no reading yet: ${c.skip ? '[near-limit, turn]' : 'the turn runs (or no-asset)'}`, { options: { ...ON, idle_compact: 'false', idle_handoff_near_limit: 'skip-spend' } }, async ($, on) => {
    const rec = adoptedTurn('1h', 95, c.spct ?? undefined)
    if (c.spct === null) (rec[KEY] as Record<string, unknown>).spct = null
    const w = world(on, {}, rec)
    w.rateLimits = []
    w.tokens = undefined
    await w.start($)
    await w.advance(10 * MIN)
    if (c.skip) expect([w.submits.length, skips(w)]).toEqual([0, [['near-limit', 'turn']]])
    else if (IDLE) expect([w.submits.length, skips(w)]).toEqual([1, []])
    else expect(skips(w)).toEqual([['no-asset', 'turn']])
  })
}

// 0.1.2: the arm records the highest spend-limit share apart from the highest share of any window.
for (const c of [
  { limits: [{ kind: 'five_hour', percentUsed: 95 }, { kind: 'spend_limit', percentUsed: 40 }], pct: 95, spct: 40 },
  { limits: [{ kind: 'five_hour', percentUsed: 12 }, { kind: 'seven_day', percentUsed: 30 }], pct: 30, spct: null },
]) {
  test(`AT-IC-C30 (arm, skip-spend): windows ${c.limits.map(l => `${l.kind} ${l.percentUsed}%`).join(', ')}: the record holds pct ${c.pct} and spct ${c.spct}`, { options: ON }, async ($, on) => {
    const w = world(on)
    w.rateLimits = c.limits
    await w.start($)
    await humanTurn($, w)
    const rec = w.storeGet(KEY) as Record<string, unknown>
    expect([rec.pct, rec.spct]).toEqual([c.pct, c.spct])
  })
}

test('AT-IC-C31 (§3.4): a due 30 s past at load, with no person\'s session.start (the load\'s first hook is another): it fires at once, late_s 30', { options: ON }, async ($, on) => {
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
  expect([ic(w).length, selfCompacts(w)]).toEqual([0, 0])
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
  expect([ic(w).length, selfCompacts(w)]).toEqual([0, 0])
})

test('AT-IC-C32 (§3.4): the load\'s own lapse bound decides before the policy now in force: a due 90 s past with idle_compact off since is [lapsed, compact], not disabled', { options: { ...ON, idle_compact: 'false' } }, async ($, on) => {
  const probe = new World()
  const w = world(on, {}, adoptedRecord(probe, { due: T0 - 90 * 1000, end: T0 - 55.5 * MIN, anchor: T0 - 55.5 * MIN }))
  await w.start($)
  await w.settle()
  expect(w.rowsOf('handoff_skipped').map(r => [r.why, r.kind, r.late_s])).toEqual([['lapsed', 'compact', 90]])
  expect([ic(w).length, selfCompacts(w), w.submits.length]).toEqual([0, 0, 0])
})

test('AT-IC-C32 (§3.4, the second bound): a due only 30 s past at load whose last request is 58.5 min old (a turn that ended 57 min after it) is [lapsed, compact] at load, not adopted (idle_compact off since, so only the load\'s bound gives lapsed)', { options: { ...ON, idle_compact: 'false' } }, async ($, on) => {
  const probe = new World()
  const w = world(on, { tokens: 260000 }, adoptedRecord(probe, { due: T0 - 30 * 1000, end: T0 - 1.5 * MIN, anchor: T0 - 58.5 * MIN }))
  await $.prompt.context({ blocks: [] })
  await w.settle()
  expect(w.rowsOf('handoff_skipped').map(r => [r.why, r.kind, r.late_s])).toEqual([['lapsed', 'compact', 30]])
  expect(isTomb(w.storeGet(KEY))).toBe(true)
  expect([ic(w).length, selfCompacts(w), w.submits.length]).toEqual([0, 0, 0])
})

test('AT-IC-C32 (§3.1): a load deletes an expired tombstone of its own session id', { options: ON }, async ($, on) => {
  const w = world(on, {}, { [KEY]: { cancelled: true, sid: SID_A, load: 'old', due: T0 - 10 * MIN, at: T0 - 10 * MIN } })
  await w.start($)
  await w.settle()
  expect(w.storeGet(KEY)).toBeUndefined()
  expect(w.rowsOf('handoff_skipped')).toEqual([])
})

test('AT-IC-C32 (§3.1): a load keeps a tombstone of its own session id that a timer could still hold (due 30 s ago)', { options: ON }, async ($, on) => {
  const tomb = { cancelled: true, sid: SID_A, load: 'old', due: T0 - 30 * 1000, at: T0 - 30 * 1000 }
  const w = world(on, {}, { [KEY]: tomb })
  await w.start($)
  await w.settle()
  expect(w.storeGet(KEY)).toEqual(tomb)
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
      expect([ic(w).length, selfCompacts(w)]).toEqual([0, 0])
    }
  })
}

test('AT-IC-C40 (G3a): /model in this load since the last request (no request, so nothing re-armed): [prefix-changed, compact], no compaction', { options: ON }, async ($, on) => {
  const w = world(on)
  await w.start($)
  await humanTurn($, w)
  await w.advance(30 * MIN)
  w.model = 'claude-other-model'
  await w.advance(24 * MIN)
  expect(skips(w)).toEqual([['prefix-changed', 'compact']])
  expect([ic(w).length, selfCompacts(w)]).toEqual([0, 0])
})

/** A 49-min turn record 3 min past at T0, armed `endMin` before T0 (null: a legacy record, no end). */
const turnRec = (endMin: number | null) => ({
  [KEY]: {
    kind: 'turn', due: T0 - 3 * MIN, sid: SID_A, answer: true, published: false, episode: { since: T0 - 52 * MIN, done: false },
    ...(endMin === null ? {} : { end: T0 - endMin * MIN }),
  },
})

test('AT-IC-C33 (§3.4): a 49-min turn record 3 min past at load, armed 52 min ago: the turn runs (or no-asset)', { options: { ...ON, idle_compact: 'false' } }, async ($, on) => {
  const w = world(on, { tokens: 260000 }, turnRec(52))
  await $.prompt.context({ blocks: [] })
  await w.settle()
  if (IDLE) expect([w.submits.length, skips(w)]).toEqual([1, []])
  else expect(skips(w)).toEqual([['no-asset', 'turn']])
})

test('AT-IC-C33 (§3.4, G7): the same record when a person resumes the session (interactive session.start): [present, turn], no submit in front of them', { options: { ...ON, idle_compact: 'false' } }, async ($, on) => {
  const w = world(on, { tokens: 260000 }, turnRec(52))
  await w.start($)
  await w.settle()
  expect(w.rowsOf('handoff_skipped').map(r => [r.why, r.kind])).toEqual([['present', 'turn']])
  expect(w.submits.length).toBe(0)
})

test('AT-IC-C33 (§3.4, G7): the same, with a prompt a hook drops before that late fire runs: the timer runs again as armed (at load), so still [present, turn]', { options: { ...ON, idle_compact: 'false' } }, async ($, on) => {
  const w = world(on, { tokens: 260000 }, turnRec(52))
  await w.start($)
  expect(w.rowsOf('handoff_skipped').length).toBe(0)
  w.dropIf = () => 'a peer dropped it'
  const r = await $.prompt.submit({ text: 'hello', origin: { kind: 'composer' } } as never)
  expect(r.drop).toBe('a peer dropped it')
  await w.settle()
  expect(w.rowsOf('handoff_skipped').map(r => [r.why, r.kind])).toEqual([['present', 'turn']])
  expect(w.submits).toEqual(['hello'])
})

/** A 55.5-min check record 30 s past at T0 (armed 56 min before T0), native idle on. */
const checkRec = () => ({
  [KEY]: { kind: 'check', due: T0 - 30 * 1000, sid: SID_A, end: T0 - 56 * MIN, answer: true, published: false, episode: { since: T0 - 56 * MIN, done: false } },
})

test('AT-IC-C31 (§3.4, check): a 55.5-min check record 30 s past at load, with no person\'s session.start: the check runs (idle_silent, then, lane B, the plugin\'s compaction; with idle_compact off the turn or no-asset)', { options: ON }, async ($, on) => {
  const w = world(on, { tokens: 260000 }, checkRec())
  w.policy = {}
  await $.prompt.context({ blocks: [] })
  await w.settle()
  expect(w.rowsOf('idle_silent').length).toBe(1)
  expect([ic(w).map(r => [r.at, r.late_s, r.adopted]), selfCompacts(w), w.submits.length, skips(w)]).toEqual([[['check', 30, true]], 1, 0, []])
})

test('AT-IC-C31 (§3.4, check, idle_compact off): the same record runs the turn (or no-asset)', { options: { ...ON, idle_compact: 'false' } }, async ($, on) => {
  const w = world(on, { tokens: 260000 }, checkRec())
  w.policy = {}
  await $.prompt.context({ blocks: [] })
  await w.settle()
  expect(w.rowsOf('idle_silent').length).toBe(1)
  if (IDLE) expect([w.submits.length, skips(w)]).toEqual([1, []])
  else expect(skips(w)).toEqual([['no-asset', 'check']])
})

test('AT-IC-C31 (§3.4, G7, check): the same check record when a person resumes the session (interactive session.start): [present, check]; no idle_silent, no submit', { options: ON }, async ($, on) => {
  const w = world(on, { tokens: 260000 }, checkRec())
  w.policy = {}
  await w.start($)
  await w.settle()
  expect(w.rowsOf('handoff_skipped').map(r => [r.why, r.kind])).toEqual([['present', 'check']])
  expect([w.rowsOf('idle_silent').length, w.submits.length]).toEqual([0, 0])
})

test('AT-IC-C33 (§3.4): the same record armed 57 min ago (past minute 55.5): [lapsed, turn] with late_s 180, no submit', { options: { ...ON, idle_compact: 'false' } }, async ($, on) => {
  const w = world(on, { tokens: 260000 }, turnRec(57))
  await $.prompt.context({ blocks: [] })
  await w.settle()
  expect(w.rowsOf('handoff_skipped').map(r => [r.why, r.kind, r.late_s])).toEqual([['lapsed', 'turn', 180]])
  expect(w.submits.length).toBe(0)
})

test('AT-IC-C33 (§3.4): a legacy record past its due (no turn end): nothing (AT-IC-14 unchanged)', { options: { ...ON, idle_compact: 'false' } }, async ($, on) => {
  const w = world(on, { tokens: 260000 }, turnRec(null))
  await $.prompt.context({ blocks: [] })
  await w.advance(60 * MIN)
  expect([w.rowsOf('handoff_skipped').length, w.submits.length]).toEqual([0, 0])
})

/**
 * D12 ticks (lane B): the computer sleeps through one idle wait, the first full tick started at or
 * after `from` (the clock's own reading picks it), which comes `late` later. Registered before
 * World.install, so it stands outside the clock (first is outermost); a hook on `clock.after`
 * needs a filter beside the clock's own, so it sees the full ticks only (the last one before a
 * due on a whole minute is full too).
 */
function sleepAt(on: Parameters<World['install']>[0], clock: () => number | undefined, from: number, late: number): () => boolean {
  let slept = false
  on('clock.after', { ms: IDLE_TICK_MS }, (_$, e, next) => {
    const now = clock()
    if (slept || now === undefined || now < from) return next(e)
    slept = true
    return next({ ...e, ms: e.ms + late })
  })
  return () => slept
}

test('AT-IC-C34 (a): the computer sleeps through the due (the last tick before it comes 10 min late): [lapsed, compact] with late_s about 600', { options: ON }, async ($, on) => {
  let w: World | undefined
  const slept = sleepAt(on, () => w?.clock.now(), T0 + 53 * MIN, 10 * MIN)
  w = world(on)
  await w.start($)
  await humanTurn($, w)
  await w.advance(65 * MIN)
  expect(slept()).toBe(true)
  const r = w.rowsOf('handoff_skipped').map(x => [x.why, x.kind, typeof x.late_s === 'number' && x.late_s >= 60])
  expect(r).toEqual([['lapsed', 'compact', true]])
  expect([ic(w).length, selfCompacts(w)]).toEqual([0, 0])
})

test('AT-IC-C34 (b, D12): the computer sleeps 20 min from minute 10 and wakes before the due: the next tick reads the clock, the compaction comes on time (T0 + 54 min, late_s 0)', { options: ON }, async ($, on) => {
  let w: World | undefined
  const slept = sleepAt(on, () => w?.clock.now(), T0 + 10 * MIN, 20 * MIN)
  w = world(on)
  await w.start($)
  await humanTurn($, w)
  await w.advance(54 * MIN - 1)
  expect(slept()).toBe(true)
  expect(ic(w).length).toBe(0)
  await w.advance(1)
  expect(ic(w).map(r => [r.at, r.late_s, r.gap_s])).toEqual([['timer', 0, 3240]])
  expect(skips(w)).toEqual([])
})

test('AT-IC-C34 (D12): no idle wait is longer than a tick: the due is reached minute by minute, the compaction on time', { options: ON }, async ($, on) => {
  let long = 0
  on('clock.after', { ms: 54 * MIN }, (_$, e, next) => {
    long++
    return next(e)
  })
  const w = world(on)
  await w.start($)
  await humanTurn($, w)
  await w.advance(54 * MIN)
  expect(ic(w).map(r => r.late_s)).toEqual([0])
  expect(long).toBe(0)
})

test('AT-IC-C34 (G3, the second bound): a turn that ends 57.5 min after its last request: due = end + 60 s, on time but 58.5 min after the anchor: [lapsed, compact], late_s 0', { options: ON }, async ($, on) => {
  const w = world(on)
  await w.start($)
  await w.userTurn($)
  await w.step($)
  await w.advance(57.5 * MIN)
  w.tokens = 260000
  await w.turnEnd($)
  await w.advance(MIN - 1)
  expect(w.rowsOf('handoff_skipped')).toEqual([])
  await w.advance(1)
  expect(w.rowsOf('handoff_skipped').map(r => [r.why, r.kind, r.late_s])).toEqual([['lapsed', 'compact', 0]])
  expect([ic(w).length, selfCompacts(w)]).toEqual([0, 0])
})

test('AT-IC-C34 (turn, §3.4): the computer sleeps through the 49-min due past minute 55.5 (the last tick comes 10 min late): [lapsed, turn] with late_s 600, no submit', { options: { ...ON, idle_compact: 'false' } }, async ($, on) => {
  let w: World | undefined
  const slept = sleepAt(on, () => w?.clock.now(), T0 + 48 * MIN, 10 * MIN)
  w = world(on)
  await w.start($)
  await humanTurn($, w)
  await w.advance(65 * MIN)
  expect(slept()).toBe(true)
  expect(w.rowsOf('handoff_skipped').map(x => [x.why, x.kind, x.late_s])).toEqual([['lapsed', 'turn', 600]])
  expect(w.submits.length).toBe(0)
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

test('AT-IC-C36 (D10): STORE_TEST_IDLE_CACHE_S=600 with idle_compact off: the 49-min turn path at 490 s', { options: { ...ON, idle_compact: 'false' } }, async ($, on) => {
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

/**
 * AT-IC-C42: the idle block's record as the first process's after-step leaves it at minute 54,
 * written by `pendingRecord` (the one writer `persistPending` uses), so the second case stands on
 * its own (one load per kit test) whatever order the cases run in. The first case checks that the
 * record it writes has this shape.
 */
function c42Record(): string {
  const nonce = '1a2b3c4d'
  const p: PendingResume = {
    sid: SID_A, nonce, block: '', builtAt: T0 + 54 * MIN, measuredAt: T0 + 54 * MIN, resumePref: 'prompt.context', turnSeq: 1, persisted: true,
    args: { nonce, midturn: false, nonok: false, savedCopy: '/w/handoffs/LAB-42/compact/2026-10-21_15-00-00_5e55a001_c1-1a2b3c.md', idle: true },
    outcome: { nudged: false, continued: false, halt: false },
  }
  return JSON.stringify(pendingRecord(p, 'first-load')) + '\n'
}

test('AT-IC-C42 (resume-persist), first process: the idle compaction\'s block is on disk at once (resume-pending.json, idle); the supervisor then stops the process with no session.end', { options: ON }, async ($, on) => {
  const w = world(on)
  await w.start($)
  await humanTurn($, w)
  await w.advance(54 * MIN)
  expect(selfCompacts(w)).toBe(1)
  const text = w.files.get(`${WATCH}/${SID_A}/${PENDING_FILE}`)
  expect(text).toBeDefined()
  const rec = JSON.parse(text ?? 'null') as Record<string, unknown>
  expect([rec.state, rec.session_id, (rec.args as Record<string, unknown> | undefined)?.idle]).toEqual(['pending', SID_A, true])
  expect(Object.keys(rec).sort()).toEqual(Object.keys(JSON.parse(c42Record()) as Record<string, unknown>).sort())
  expect(w.rowsOf('mod_outcome')).toEqual([])
})

test('AT-IC-C42 (resume-persist), the next process over the same store and watch folder (claude --resume, 2 min later): its first turn gets the idle block from disk, with [idle]', { options: ON }, async ($, on) => {
  const w = world(on, {}, { [KEY]: { cancelled: true, sid: SID_A, load: 'first-load', due: T0 + 54 * MIN, at: T0 + 54 * MIN } })
  // The classic SessionStart(resume) has armed the record the first process left (helper case AT-RP-04).
  w.files.set(`${WATCH}/${SID_A}/${ARMED_FILE}`, c42Record())
  await w.clock.set(T0 + 56 * MIN)
  await w.start($)
  await w.userTurn($, 'where were we?')
  const block = blockOf(w, await $.prompt.context({ blocks: [] })) ?? ''
  expect(block).toContain(SID_A)
  const idle = lineOf(w, 'idle')
  expect(idle).toBeDefined()
  expect(block).toContain(idle ?? '')
  expect(w.rowsOf('mod_outcome').map(r => r.resume)).toEqual(['delivered:prompt.context'])
})

/**
 * The classic SessionStart(compact) as the helper runs it (hook.pl `session_compact`): it claims
 * the block at compaction time, with no `[idle]` line (resumeblock.pm), only for a dispatch whose
 * `resume_pref` is `sessionstart`.
 */
function classicSessionStart(w: World): void {
  w.atCompact = () => {
    const d = w.callsOf('dispatch').at(-1)
    const n = d ? w.flag(d, '--nonce') : undefined
    if (!d || n === undefined || w.flag(d, '--resume-pref') !== 'sessionstart' || w.claims.has(n)) return
    w.claims.set(n, 'sessionstart')
    w.files.set(`${WATCH}/${SID_A}/resume-claimed/${n}`, 'sessionstart\n')
  }
}

test('AT-IC-C42 (resume-persist, P4 adopted load): a load that adopted the record and has had no prompt yet (classic-alive present) dispatches its idle compaction with resume_pref prompt.context; SessionStart(compact) leaves the block unclaimed on disk, and the person\'s return gets [idle], re-measured', { options: ON }, async ($, on) => {
  const probe = new World()
  const w = world(on, { tokens: 260000 }, adoptedRecord(probe))
  // A supervisor move or `claude respawn`: the classic SessionStart(resume) wrote classic-alive.json.
  w.files.set(`${WATCH}/${SID_A}/classic-alive.json`, '{}')
  classicSessionStart(w)
  await w.start($)
  await w.advance(10 * MIN)
  expect(selfCompacts(w)).toBe(1)
  const d = w.callsOf('dispatch')[0]
  const nonce = w.flag(d, '--nonce') ?? ''
  expect([w.flag(d, '--resume-pref'), w.claims.has(nonce)]).toEqual(['prompt.context', false])
  const rec = JSON.parse(w.files.get(`${WATCH}/${SID_A}/${PENDING_FILE}`) ?? 'null') as Record<string, unknown>
  expect([rec.state, rec.nonce, (rec.args as Record<string, unknown> | undefined)?.idle]).toEqual(['pending', nonce, true])
  // The person comes back 50 min later in the same load.
  await w.advance(50 * MIN)
  await w.userTurn($, 'where were we?')
  const block = blockOf(w, await $.prompt.context({ blocks: [] })) ?? ''
  expect(block).toContain(SID_A)
  const idle = lineOf(w, 'idle')
  expect(idle).toBeDefined()
  expect(block).toContain(idle ?? '')
  expect(w.rowsOf('resume_remeasured').map(r => r.nonce)).toEqual([nonce])
  expect(w.rowsOf('mod_outcome').map(r => [r.nonce, r.resume])).toEqual([[nonce, 'delivered:prompt.context']])
})

/**
 * The classic SessionStart(resume) of the next process as the helper runs it (resumeblock.pm
 * `arm`, helper case AT-RP-04): a pending record of this session id becomes resume-armed.json,
 * unless its nonce is claimed already (a block the classic SessionStart(compact) took is never
 * armed again).
 */
function classicResumeArm(w: World): void {
  const from = `${WATCH}/${SID_A}/${PENDING_FILE}`
  const t = w.files.get(from)
  if (t === undefined) return
  const j = JSON.parse(t) as Record<string, unknown>
  if (j.state !== 'pending' || j.session_id !== SID_A || w.files.has(`${WATCH}/${SID_A}/resume-claimed/${String(j.nonce)}`)) return
  w.files.delete(from)
  w.files.set(`${WATCH}/${SID_A}/${ARMED_FILE}`, t)
}

test('AT-IC-C42 (resume-persist, P4 adopted load, across processes): the adopted load compacts and leaves the block unclaimed on disk; the process ends; the next load\'s first prompt gets it with [idle], re-measured', { options: ON }, async ($, on) => {
  const probe = new World()
  const w = world(on, { tokens: 260000 }, adoptedRecord(probe))
  w.files.set(`${WATCH}/${SID_A}/classic-alive.json`, '{}')
  classicSessionStart(w)
  await w.start($)
  await w.advance(10 * MIN)
  expect(selfCompacts(w)).toBe(1)
  const nonce = w.flag(w.callsOf('dispatch')[0], '--nonce') ?? ''
  expect(w.claims.has(nonce)).toBe(false)
  // No prompt for 50 min, then the supervisor stops the process. A kit test gets one load, so the
  // process end and the next load are the in-process path a new process takes (AT-RP-02): the
  // load's end takes the block out of memory and keeps it on disk (no mod_outcome yet); the next
  // process's classic SessionStart(resume) arms it; its session.start runs; its first prompt.
  await w.advance(50 * MIN)
  await $.session.end({ reason: 'resume', sessionId: SID_A, resume: { id: SID_A } } as never)
  expect(w.rowsOf('mod_outcome')).toEqual([])
  classicResumeArm(w)
  expect(JSON.parse(w.files.get(`${WATCH}/${SID_A}/${ARMED_FILE}`) ?? 'null')).toMatchObject({ state: 'pending', nonce, args: { idle: true } })
  await w.advance(2 * MIN)
  w.measureBlock = 'Git: main @ 7c7c7c7, 1 modified, 0 untracked\nIn flight: none listed\nEvidence: none'
  await w.start($)
  await w.userTurn($, 'where were we?')
  const block = blockOf(w, await $.prompt.context({ blocks: [] })) ?? ''
  expect(block).toContain(SID_A)
  const idle = lineOf(w, 'idle')
  expect(idle).toBeDefined()
  expect(block).toContain(idle ?? '')
  // Built 52 min earlier: measured again at delivery.
  expect(block).toContain('7c7c7c7')
  expect(w.rowsOf('resume_remeasured').map(r => r.nonce)).toEqual([nonce])
  expect(w.claims.get(nonce)).toBe('prompt.context')
  expect(w.rowsOf('mod_outcome').map(r => [r.nonce, r.resume])).toEqual([[nonce, 'delivered:prompt.context']])
  expect(JSON.parse(w.files.get(`${WATCH}/${SID_A}/${ARMED_FILE}`) ?? 'null')).toMatchObject({ state: 'settled', nonce, resume: 'delivered:prompt.context' })
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

// ---- D16 (the merge with v012-digest): the plugin's own idle compaction arms the away digest, as
// Claude Code's idle compaction does in onCompact; under "idleCompaction": false it is the only one.
const DONE = hasTag('resume-context', 'idle-done')
const FINISHED = 'Status: finished · Acuity: stable · State: done (checkpoint: clean)\nStep 1: none\n## Next steps\n1. run the suite — done when green · done\n'

test('AT-IC-C44 (D16): vetoed, a finished lane, nothing running, idle_digest submit: one digest turn after the idle compaction (digest_submit submitted)', { options: ON }, async ($, on) => {
  const w = world(on)
  w.resumeHere = FINISHED
  await w.start($)
  await humanTurn($, w)
  await w.advance(54 * MIN)
  expect([ic(w).length, selfCompacts(w)]).toEqual([1, 1])
  await w.advance(5000)
  if (!DONE) return
  expect(w.rowsOf('digest_submit').map(r => [r.lane, r.result])).toEqual([['finished', 'submitted']])
  expect(w.submits.length).toBe(1)
  const evs = w.rows.map(r => r.ev)
  expect(evs.indexOf('digest_submit')).toBeGreaterThan(evs.indexOf('compacted'))
})

test('AT-IC-C44 (D16): a blocked lane with an agent running (soft-blocked): digest_submit skipped:running, no submit', { options: ON }, async ($, on) => {
  const w = world(on)
  w.resumeHere = 'Status: hard-blocked · Acuity: watch · State: waits on you (checkpoint: clean)\nStep 1: none\n'
  w.agents = RUNNING
  await w.start($)
  await humanTurn($, w)
  await w.advance(54 * MIN)
  expect(ic(w).map(r => r.agents)).toEqual([1])
  await w.advance(5000)
  expect(w.submits).toEqual([])
  if (DONE) expect(w.rowsOf('digest_submit').map(r => r.result)).toEqual(['skipped:running'])
})

test('AT-IC-C44 (D16): idle_digest return: no turn (digest_submit skipped:return)', { options: { ...ON, idle_digest: 'return' } }, async ($, on) => {
  const w = world(on)
  w.resumeHere = FINISHED
  await w.start($)
  await humanTurn($, w)
  await w.advance(54 * MIN + 5000)
  expect(w.submits).toEqual([])
  if (DONE) expect(w.rowsOf('digest_submit').map(r => r.result)).toEqual(['skipped:return'])
})

test('AT-IC-C44 (D16): idle_digest off (the default of 0.1.1, owner rule (c)): a finished lane, nothing running: no turn (digest_submit skipped:off)', { options: { idle_handoff_turn: 'true', precompact_turn: 'false' } }, async ($, on) => {
  const w = world(on)
  w.resumeHere = FINISHED
  await w.start($)
  await humanTurn($, w)
  await w.advance(54 * MIN)
  expect([ic(w).length, selfCompacts(w)]).toEqual([1, 1])
  await w.advance(60 * 1000)
  expect(w.submits).toEqual([])
  if (DONE) expect(w.rowsOf('digest_submit').map(r => [r.lane, r.result])).toEqual([['finished', 'skipped:off']])
})

// ---- 0.1.5 D-3 (owner 2026-11-07, "3. yes"; session xxxxxxxx, ~166k tokens, finished its work and
// logged handoff_skipped why=small at every idle check): a lane that reads finished at the idle
// check gets the handoff-when-idle turn whatever the context size; every other limit stands.

/** The plugin's idle compaction with an agent running, then that agent's result turn (it takes the block), ending at `tokens`. */
async function episodeAfterResult($: Engine, w: World, resumeHere: string, tokens: number): Promise<void> {
  w.resumeHere = resumeHere
  w.agents = RUNNING
  await w.start($)
  await humanTurn($, w)
  await w.advance(54 * MIN)
  expect([ic(w).length, selfCompacts(w)]).toEqual([1, 1])
  w.agents = [{ id: 'sub-1', status: 'completed' }]
  await w.userTurn($, 'Agent sub-1 finished.', 'task-notification')
  expect(blockOf(w, await $.prompt.context({ blocks: [] })) ?? '').toContain(SID_A)
  w.tokens = tokens
  await w.turnEnd($)
}

test('D-3: a lane that reads finished at the idle check, under idle_handoff_min_tokens (150K < 200K): the 49-min turn runs, no small skip (failed on 0.1.4)', { options: ON }, async ($, on) => {
  const w = world(on)
  await episodeAfterResult($, w, FINISHED, 150000)
  const before = w.submits.length
  await w.advance(49 * MIN)
  if (IDLE) expect([w.submits.length - before, skips(w)]).toEqual([1, []])
  else expect(skips(w)).toEqual([['no-asset', 'turn']])
})

test('D-3: a working lane under the floor still skips small', { options: ON }, async ($, on) => {
  const w = world(on)
  await episodeAfterResult($, w, 'Status: working · Acuity: stable · State: x (checkpoint: clean)\nStep 1: `make test` — for "go on"\n', 150000)
  await w.advance(49 * MIN)
  expect(skips(w)).toEqual([['small', 'turn']])
})

test('D-3: a finished lane under the floor still meets the other limits (idle_handoff_near_limit skip at 95%: near-limit)', { options: { ...ON, idle_handoff_near_limit: 'skip' } }, async ($, on) => {
  const w = world(on)
  await episodeAfterResult($, w, FINISHED, 150000)
  w.rateLimits = [{ kind: 'five_hour', percentUsed: 95 }]
  await w.advance(44 * MIN)
  await w.measure($)
  await w.advance(5 * MIN)
  expect(skips(w)).toEqual([['near-limit', 'turn']])
})

test('D83-02 (D-83): the idle handoff turn\'s near-limit skip (idle_handoff_near_limit skip) names the window\'s source and age', { options: { ...ON, idle_handoff_near_limit: 'skip' } }, async ($, on) => {
  const w = world(on)
  await episodeAfterResult($, w, FINISHED, 150000)
  w.rateLimits = [{ kind: 'five_hour', percentUsed: 95 }]
  await w.advance(44 * MIN)
  await w.measure($)
  await w.advance(5 * MIN)
  expect(w.rowsOf('handoff_skipped').filter(r => r.why === 'near-limit').map(r => [r.rule, r.windows, r.usage_src, r.usage_age_s]))
    .toEqual([['option-skip', ['five_hour:95'], ['five_hour:plugin'], { five_hour: 300 }]])
})

// ---- D-83 (owner U-60: "what can be more important than creating a handoff and compacting?
// reading cold cache seems to be more expensive"): every near-limit decision reads the session's
// own reading, its status line's and the other sessions' on this machine (the shared usage record),
// fresh ones only, and skips only when every fresh reading of a kind is at or over its limit.

/** A record entry (the fake helper `usage`): a reading `ago` seconds before now, times in epoch seconds. */
const entry = (w: World, kind: string, pct: number, src: string, sid8: string, ago = 30, resets: number | null = null) =>
  ({ kind, pct, resets_at: resets, at: Math.floor(w.clock.now() / 1000) - ago, src, sid8 })

/** The compaction timer's fire (54 min) with the own windows `own`, fresh (measured at 53 min), and the record's `entries` read then. */
async function timerWith($: Engine, w: World, own: World['rateLimits'], entries: (w: World) => Record<string, unknown>[]): Promise<void> {
  await w.start($)
  await humanTurn($, w)
  await w.advance(53 * MIN)
  w.rateLimits = own
  await w.measure($)
  w.usageEntries = entries(w)
  await w.advance(MIN)
}

test('D83-03 (D-83): own seven_day at 95 (fresh), another session on the machine at 40 (fresh): the readings disagree, so plugin idle compaction runs (rule split; the peer\'s reading named, 2 fresh readings)', { options: ON }, async ($, on) => {
  const w = world(on)
  await timerWith($, w, [{ kind: 'five_hour', percentUsed: 12 }, { kind: 'seven_day', percentUsed: 95 }], w => [entry(w, 'seven_day', 40, 'plugin', '5e55a002')])
  expect(skips(w)).toEqual([])
  expect(ic(w).map(r => [r.rule, r.windows, r.usage_src, r.usage_n])).toEqual([['split', ['five_hour:12', 'seven_day:40'], ['five_hour:plugin', 'seven_day:peer'], { five_hour: 1, seven_day: 2 }]])
  expect(selfCompacts(w)).toBe(1)
})

test('D83-04 (D-83): own seven_day at 95 and every other fresh reading at or over 90 (a peer at 96, a stale peer at 40 left out): [near-limit, compact]', { options: ON }, async ($, on) => {
  const w = world(on)
  await timerWith($, w, [{ kind: 'five_hour', percentUsed: 12 }, { kind: 'seven_day', percentUsed: 95 }], w => [entry(w, 'seven_day', 96, 'statusline', '5e55a002'), entry(w, 'seven_day', 40, 'plugin', '5e55a003', 11 * 60)])
  expect(w.rowsOf('handoff_skipped').filter(r => r.why === 'near-limit').map(r => [r.kind, r.windows, r.usage_n])).toEqual([['compact', ['five_hour:12', 'seven_day:95'], { five_hour: 1, seven_day: 2 }]])
  expect(selfCompacts(w)).toBe(0)
})

test('D83-05 (D-83): own seven_day at 95 read 54 min before (nothing refreshed it), no other reading: no fresh reading, so no skip on usage: the compaction runs (rule no-fresh, the reading\'s age logged)', { options: ON }, async ($, on) => {
  const w = world(on)
  await w.start($)
  await humanTurn($, w)
  w.rateLimits = [{ kind: 'five_hour', percentUsed: 12 }, { kind: 'seven_day', percentUsed: 95 }]
  await w.measure($)
  await w.advance(54 * MIN)
  expect(skips(w)).toEqual([])
  expect(ic(w).map(r => [r.rule, r.windows, r.usage_src, r.usage_n, (r.usage_age_s as Record<string, number>).seven_day])).toEqual([['no-fresh', ['five_hour:12', 'seven_day:95'], ['five_hour:plugin', 'seven_day:plugin'], { five_hour: 0, seven_day: 0 }, 3240]])
  expect(selfCompacts(w)).toBe(1)
})

test('D83-06 (D-83): the own reading 54 min old, the session\'s status line fresh at 95 (cache --note-usage): the status line\'s reading is the session\'s fresh one: [near-limit, compact]', { options: ON }, async ($, on) => {
  const w = world(on)
  await w.start($)
  await humanTurn($, w)
  w.rateLimits = [{ kind: 'five_hour', percentUsed: 12 }, { kind: 'seven_day', percentUsed: 95 }]
  await w.measure($)
  await w.advance(53 * MIN)
  w.usageEntries = [entry(w, 'seven_day', 95, 'statusline', SID_A.slice(0, 8)), entry(w, 'five_hour', 12, 'statusline', SID_A.slice(0, 8))]
  await w.advance(MIN)
  expect(w.rowsOf('handoff_skipped').filter(r => r.why === 'near-limit').map(r => [r.kind, r.usage_src])).toEqual([['compact', ['five_hour:statusline', 'seven_day:statusline']]])
})

test('D83-07 (D-83): a fresh peer reading whose reset is 5 h from the own one\'s (another account behind a proxy) is still a reading, marked an anomaly: split, the compaction runs', { options: ON }, async ($, on) => {
  const w = world(on)
  const R = Math.floor(T0 / 1000) + 3 * 3600
  await timerWith($, w, [{ kind: 'five_hour', percentUsed: 12 }, { kind: 'seven_day', percentUsed: 95, resetsAt: new Date(R * 1000).toISOString() } as never], w => [entry(w, 'seven_day', 41, 'plugin', '5e55a002', 30, R + 5 * 3600)])
  expect(ic(w).map(r => [r.rule, r.usage_anomaly])).toEqual([['split', ['seven_day:plugin', 'seven_day:peer']]])
  expect(selfCompacts(w)).toBe(1)
})

// ---- Lane B: the 55.5-min check's compaction runs behind the guards of the `compact` timer (D4),
// also with no agent running when Claude Code stayed silent (owner Q2, 18:54); the check is armed
// for the turn or for that compaction; ticks (D12).
const NATIVE_ON: Record<string, unknown> = {}

test('AT-IC-C38 (D4, D14): native on, agents running: G1 holds and the record is a tombstone at the fire; the check still compacts (at check, one mod-self dispatch); the guards read the store once (G1)', { options: ON }, async ($, on) => {
  let reads = 0
  // Registered before World.install, so it stands outside mock.store (first is outermost).
  on('store.get', { key: KEY }, (_$, e, next) => {
    reads++
    return next(e)
  })
  const w = world(on)
  w.policy = NATIVE_ON
  w.agents = RUNNING
  await w.start($)
  await humanTurn($, w)
  await w.advance(55 * MIN)
  reads = 0
  await w.advance(MIN)
  expect(reads).toBe(1)
  expect(isTomb(w.storeGet(KEY))).toBe(true)
  expect(ic(w).map(r => [r.at, r.agents])).toEqual([['check', 1]])
  expect([modSelfDispatches(w), selfCompacts(w), skips(w)]).toEqual([1, 1, []])
})

/** The plugin's own idle dispatches (`--channel mod-self`). */
const modSelfDispatches = (w: World) => w.callsOf('dispatch').filter(c => w.flag(c, '--channel') === 'mod-self').length

// D4: the guards lane A's check path did not have (it read only triggers, the window, 200K, halt and
// an open question): the cache, the limits, a person at the prompt, a changed prompt prefix; and
// the D5 halt rule (the cap does not stop it).
for (const c of [
  { name: 'no plan window at the fire (rate limits gone)', why: 'ttl-5m', at55: (w: World) => { w.rateLimits = [] } },
  { name: 'a window at 95%', why: 'near-limit', at55: (w: World) => { w.rateLimits = [{ kind: 'five_hour', percentUsed: 12 }, { kind: 'seven_day', percentUsed: 95 }] } },
  { name: 'the promptCacheTtl setting 5m (read at the fire)', why: 'ttl-5m', at55: (w: World) => { w.policy = { promptCacheTtl: '5m' } } },
  { name: 'a keystroke 30 s before the check', why: 'present', at55: (w: World, $: Engine) => w.edit($) },
  { name: '/model since the last request', why: 'prefix-changed', at55: (w: World) => { w.model = 'claude-other-model' } },
]) {
  test(`AT-IC-C45 (D4): the check's compaction while agents run: ${c.name}: [${c.why}, check], no compaction`, { options: ON }, async ($, on) => {
    const w = world(on)
    w.policy = NATIVE_ON
    w.agents = RUNNING
    await w.start($)
    await humanTurn($, w)
    await w.advance(55 * MIN)
    await c.at55(w, $)
    await w.measure($)
    await w.advance(MIN)
    expect(w.rowsOf('idle_silent').length).toBe(1)
    expect(skips(w)).toEqual([[c.why, 'check']])
    expect([ic(w).length, selfCompacts(w), w.submits.length]).toEqual([0, 0, 0])
  })
}

for (const c of [{ reason: 'cap', why: null }, { reason: 'thrash', why: 'halted' }]) {
  test(`AT-IC-C45 (D4, D5): halt for ${c.reason === 'cap' ? 'the auto-continue cap does not stop the check\'s compaction (lane A: halted)' : 'a thrash stops it: [halted, check]'}`, { options: ON }, async ($, on) => {
    const w = world(on)
    w.policy = NATIVE_ON
    w.agents = RUNNING
    w.files.set(`${WATCH}/${SID_A}/halt.json`, JSON.stringify({ active: true, reason: c.reason }))
    await w.start($)
    // A person's turn clears halt: here a background result's turn ends the last one.
    await w.userTurn($, 'Background task finished.', 'task-notification')
    w.tokens = 260000
    await w.turnEnd($)
    await w.advance(56 * MIN)
    if (c.why === null) expect([skips(w), ic(w).map(r => r.at), selfCompacts(w), w.rowsOf('continue').length]).toEqual([[], ['check'], 1, 0])
    else expect([skips(w), ic(w).length, selfCompacts(w)]).toEqual([[[c.why, 'check']], 0, 0])
  })
}

// Review of lane B (G0b at the check): `"autoCompactEnabled": false` set during the idle wait is an
// explicit user switch; the check reads it before it compacts, as the `compact` timer does (D1).
test('AT-IC-C45 (G0b): automatic compaction switched off during the wait, agents running: [compaction-off, check], no compaction, no turn', { options: ON }, async ($, on) => {
  const w = world(on)
  w.policy = NATIVE_ON
  w.agents = RUNNING
  await w.start($)
  await humanTurn($, w)
  await w.advance(55 * MIN)
  w.policy = { autoCompactEnabled: false }
  await w.advance(MIN)
  expect(w.rowsOf('idle_silent').length).toBe(1)
  expect([skips(w), ic(w).length, selfCompacts(w), w.submits.length]).toEqual([[['compaction-off', 'check']], 0, 0, 0])
})

test('AT-IC-C45 (G0b, owner Q2): automatic compaction switched off during the wait, no agents: no compaction; the turn runs (or no-asset), as D1 keeps it', { options: ON }, async ($, on) => {
  const w = world(on)
  w.policy = NATIVE_ON
  await w.start($)
  await humanTurn($, w)
  await w.advance(55 * MIN)
  w.policy = { autoCompactEnabled: false }
  await w.advance(MIN)
  expect([ic(w).length, selfCompacts(w)]).toEqual([0, 0])
  if (IDLE) expect([w.submits.length, skips(w)]).toEqual([1, []])
  else expect(skips(w)).toEqual([['no-asset', 'check']])
})

test('AT-IC-C45 (G0b): automatic compaction switched off during the wait, the turn off: [compaction-off, check], nothing runs', { options: { ...ON, idle_handoff_turn: 'false' } }, async ($, on) => {
  const w = world(on)
  w.policy = NATIVE_ON
  await w.start($)
  await humanTurn($, w)
  await w.advance(55 * MIN)
  w.policy = { autoCompactEnabled: false }
  await w.advance(MIN)
  expect([skips(w), ic(w).length, selfCompacts(w), w.submits.length]).toEqual([[['compaction-off', 'check']], 0, 0, 0])
})

// Root call on Q2 (2026-10-27): with no agents running, a refused check compaction gives no turn
// after it (D2) for these reasons; a thrash or bad-summary halt falls back to the turn, as before
// lane B (halt stops plugin compactions, not the turn).
for (const c of [
  { name: 'a keystroke 30 s before the check', why: 'present', at55: (w: World, $: Engine) => w.edit($) },
  { name: '/model since the last request', why: 'prefix-changed', at55: (w: World) => { w.model = 'claude-other-model' } },
  { name: 'the promptCacheTtl setting 5m (read at the fire)', why: 'ttl-5m', at55: (w: World) => { w.policy = { promptCacheTtl: '5m' } } },
]) {
  test(`AT-IC-C45 (owner Q2, root call): no agents, ${c.name}: [${c.why}, check], no compaction and no turn`, { options: ON }, async ($, on) => {
    const w = world(on)
    w.policy = NATIVE_ON
    await w.start($)
    await humanTurn($, w)
    await w.advance(55 * MIN)
    await c.at55(w, $)
    await w.advance(MIN)
    expect(w.rowsOf('idle_silent').length).toBe(1)
    expect([skips(w), ic(w).length, selfCompacts(w), w.submits.length]).toEqual([[[c.why, 'check']], 0, 0, 0])
  })
}

test('AT-IC-C45 (owner Q2, root call): no agents, halt for two bad summaries in the person\'s own turn: no compaction; the turn runs (or no-asset), as before lane B', { options: ON }, async ($, on) => {
  const w = world(on)
  w.policy = NATIVE_ON
  await w.start($)
  // The person's prompt opens the idle episode; two unshaped summaries in their turn halt it.
  await w.userTurn($)
  w.summaryMode = 'unshaped'
  await raiseCompact($, { trigger: 'auto' })
  await raiseCompact($, { trigger: 'auto' })
  w.summaryMode = 'ok'
  expect(w.rowsOf('halt').map(r => [r.reason, r.active])).toEqual([['2-nonok', true]])
  // The turn goes on after them (the compactions are before its end, not since it).
  await w.advance(1000)
  w.tokens = 260000
  await w.turnEnd($, 'Done with that step.')
  const compacts = w.compacts.length
  await w.advance(56 * MIN)
  expect([ic(w).length, w.compacts.length - compacts]).toEqual([0, 0])
  if (IDLE) expect([w.submits.length, skips(w)]).toEqual([1, []])
  else expect(skips(w)).toEqual([['no-asset', 'check']])
})

// 0.1.2: the check's turn under `skip-spend` with a spend limit at 95%: [near-limit, check], no turn;
// a plan window at 95% beside a spend limit at 50%: the turn runs (or no-asset).
for (const c of [{ spend: 95, plan: 12, skip: true }, { spend: 50, plan: 95, skip: false }]) {
  test(`AT-IC-C08 (lane B, near-limit, skip-spend): native on, idle_compact off, a spend limit at ${c.spend}% and a plan window at ${c.plan}% at the check: ${c.skip ? '[near-limit, check], no turn' : 'the turn runs (or no-asset)'}`, { options: { ...ON, idle_compact: 'false', idle_handoff_near_limit: 'skip-spend' } }, async ($, on) => {
    const w = world(on)
    w.policy = {}
    await w.start($)
    await humanTurn($, w)
    await w.advance(55 * MIN)
    w.rateLimits = [{ kind: 'five_hour', percentUsed: c.plan }, { kind: 'spend_limit', percentUsed: c.spend }]
    await w.measure($)
    await w.advance(MIN)
    expect([ic(w).length, selfCompacts(w)]).toEqual([0, 0])
    if (c.skip) expect([w.submits.length, skips(w)]).toEqual([0, [['near-limit', 'check']]])
    else if (IDLE) expect([w.submits.length, skips(w)]).toEqual([1, []])
    else expect(skips(w)).toEqual([['no-asset', 'check']])
  })
}

// Root call NL-2 (0.1.2): in halt mode (not the cap) the check's compaction never runs, so a window
// at 90% or more refuses nothing the halt had not; with idle_handoff_near_limit `run` the check
// falls back to the turn as it does for `halted`, and only `skip` keeps [near-limit, check]
// (`skip-spend`, 0.1.2: a plan window at 95% falls back as under `run`; a spend limit, below).
for (const mode of ['run', 'skip-spend', 'skip'] as const) {
  test(`AT-IC-C45 (NL-2): no agents, halt for two bad summaries, a window at 95% at the check, idle_handoff_near_limit ${mode}: ${mode !== 'skip' ? 'no compaction; the turn runs (or no-asset)' : '[near-limit, check], no compaction and no turn'}`, { options: { ...ON, idle_handoff_near_limit: mode } }, async ($, on) => {
    const w = world(on)
    w.policy = NATIVE_ON
    await w.start($)
    await w.userTurn($)
    w.summaryMode = 'unshaped'
    await raiseCompact($, { trigger: 'auto' })
    await raiseCompact($, { trigger: 'auto' })
    w.summaryMode = 'ok'
    expect(w.rowsOf('halt').map(r => [r.reason, r.active])).toEqual([['2-nonok', true]])
    await w.advance(1000)
    w.tokens = 260000
    await w.turnEnd($, 'Done with that step.')
    const compacts = w.compacts.length
    await w.advance(55 * MIN)
    w.rateLimits = [{ kind: 'five_hour', percentUsed: 12 }, { kind: 'seven_day', percentUsed: 95 }]
    await w.measure($)
    await w.advance(MIN)
    expect([ic(w).length, w.compacts.length - compacts]).toEqual([0, 0])
    if (mode === 'skip') expect([w.submits.length, skips(w)]).toEqual([0, [['near-limit', 'check']]])
    else if (IDLE) expect([w.submits.length, skips(w)]).toEqual([1, []])
    else expect(skips(w)).toEqual([['no-asset', 'check']])
  })
}

// NL-2 under `skip-spend` (0.1.2): halt for two bad summaries, no agents, a spend limit at 95%
// beside a plan window: the turn's own rule skips there, so [near-limit, check] stays, no
// compaction and no turn.
test('AT-IC-C45 (NL-2, skip-spend): no agents, halt for two bad summaries, a spend limit at 95% at the check: [near-limit, check], no compaction and no turn', { options: { ...ON, idle_handoff_near_limit: 'skip-spend' } }, async ($, on) => {
  const w = world(on)
  w.policy = NATIVE_ON
  await w.start($)
  await w.userTurn($)
  w.summaryMode = 'unshaped'
  await raiseCompact($, { trigger: 'auto' })
  await raiseCompact($, { trigger: 'auto' })
  w.summaryMode = 'ok'
  expect(w.rowsOf('halt').map(r => [r.reason, r.active])).toEqual([['2-nonok', true]])
  await w.advance(1000)
  w.tokens = 260000
  await w.turnEnd($, 'Done with that step.')
  const compacts = w.compacts.length
  await w.advance(55 * MIN)
  w.rateLimits = [{ kind: 'five_hour', percentUsed: 12 }, { kind: 'spend_limit', percentUsed: 95 }]
  await w.measure($)
  await w.advance(MIN)
  expect([ic(w).length, w.compacts.length - compacts]).toEqual([0, 0])
  expect([w.submits.length, skips(w)]).toEqual([0, [['near-limit', 'check']]])
})

// NL-2: a cap halt does not stop the check's compaction, so a window at 95% stays its refusal (no
// turn after it, D2) under `run` too; and with agents running a thrash halt keeps [near-limit, check].
for (const c of [{ reason: 'cap', agents: false }, { reason: 'thrash', agents: true }]) {
  test(`AT-IC-C45 (NL-2): halt for ${c.reason}${c.agents ? ', agents running' : ''}, a window at 95%, idle_handoff_near_limit run: [near-limit, check], no compaction and no turn`, { options: ON }, async ($, on) => {
    const w = world(on)
    w.policy = NATIVE_ON
    if (c.agents) w.agents = RUNNING
    w.files.set(`${WATCH}/${SID_A}/halt.json`, JSON.stringify({ active: true, reason: c.reason }))
    await w.start($)
    await w.userTurn($, 'Background task finished.', 'task-notification')
    w.tokens = 260000
    await w.turnEnd($)
    await w.advance(55 * MIN)
    w.rateLimits = [{ kind: 'five_hour', percentUsed: 12 }, { kind: 'seven_day', percentUsed: 95 }]
    await w.measure($)
    await w.advance(MIN)
    expect([skips(w), ic(w).length, selfCompacts(w), w.submits.length]).toEqual([[['near-limit', 'check']], 0, 0, 0])
  })
}

// NL-2 is scoped to halt mode: with no halt and no agents, a window at 95% at the check stays its
// refusal under `run` too (no turn after it, D2), as the README states.
test('AT-IC-C45 (NL-2): no halt, no agents, a window at 95% at the check, idle_handoff_near_limit run: [near-limit, check], no compaction and no turn', { options: ON }, async ($, on) => {
  const w = world(on)
  w.policy = NATIVE_ON
  await w.start($)
  await w.userTurn($)
  await w.advance(1000)
  w.tokens = 260000
  await w.turnEnd($, 'Done with that step.')
  const compacts = w.compacts.length
  await w.advance(55 * MIN)
  w.rateLimits = [{ kind: 'five_hour', percentUsed: 12 }, { kind: 'seven_day', percentUsed: 95 }]
  await w.measure($)
  await w.advance(MIN)
  expect(w.rowsOf('halt').length).toBe(0)
  expect([ic(w).length, w.compacts.length - compacts]).toEqual([0, 0])
  expect([w.submits.length, skips(w)]).toEqual([0, [['near-limit', 'check']]])
})

for (const c of [{ turn: true, why: 'episode' }, { turn: false, why: 'halted' }]) {
  test(`AT-IC-C45 (owner Q2, root call): no agents, halt for a thrash, the last turn a background result's${c.turn ? '' : ', the turn off'}: no compaction; [${c.why}, check]${c.turn ? ' (the turn\'s own rule: a background result opens no episode)' : ''}`, { options: c.turn ? ON : { ...ON, idle_handoff_turn: 'false' } }, async ($, on) => {
    const w = world(on)
    w.policy = NATIVE_ON
    w.files.set(`${WATCH}/${SID_A}/halt.json`, JSON.stringify({ active: true, reason: 'thrash' }))
    await w.start($)
    // A person's turn clears halt: here a background result's turn ends the last one.
    await w.userTurn($, 'Background task finished.', 'task-notification')
    w.tokens = 260000
    await w.turnEnd($)
    await w.advance(56 * MIN)
    expect([skips(w), ic(w).length, selfCompacts(w), w.submits.length]).toEqual([[[c.why, 'check']], 0, 0, 0])
  })
}

for (const c of [
  { name: 'a person\'s whole turn', why: 'newer-turn', act: async (w: World, $: Engine) => { await w.userTurn($); w.tokens = 260000; await w.turnEnd($) } },
  { name: 'a keystroke', why: 'present', act: (w: World, $: Engine) => w.edit($) },
]) {
  test(`AT-IC-C45 (D4, §2.4): ${c.name} while the check's checkpoint runs: idle_compact (at check), then [${c.why}, check] before the dispatch record; no compaction`, { options: ON }, async ($, on) => {
    const w = world(on)
    w.policy = NATIVE_ON
    w.agents = RUNNING
    await w.start($)
    await humanTurn($, w)
    let acted = false
    w.atHelper = async sub => {
      if (acted || sub !== 'checkpoint') return
      acted = true
      await c.act(w, $)
    }
    await w.advance(56 * MIN)
    expect(acted).toBe(true)
    expect(ic(w).map(r => r.at)).toEqual(['check'])
    expect(skips(w)).toEqual([[c.why, 'check']])
    expect([modSelfDispatches(w), selfCompacts(w), w.rowsOf('idle_compact_off').length]).toEqual([0, 0, 0])
  })
}

test('AT-IC-C45 (D4, D7): the check\'s compaction skipped twice in a row: idle_compact_off {failed, 2}; then on/check/failed, agents-running while agents run, and the turn (or no-asset) when none do', { options: ON }, async ($, on) => {
  const w = world(on)
  w.policy = NATIVE_ON
  w.agents = RUNNING
  w.compactMode = { skip: 'hook' }
  await w.start($)
  for (let i = 0; i < 2; i++) {
    await humanTurn($, w)
    await w.advance(56 * MIN)
  }
  expect(w.rowsOf('compacted').map(r => r.skip)).toEqual(['hook', 'hook'])
  expect(w.rowsOf('idle_compact_off').map(r => [r.why, r.fails])).toEqual([['failed', 2]])
  await humanTurn($, w)
  expect(modes(w)).toEqual(['on/check/check', 'on/check/failed'])
  await w.advance(56 * MIN)
  expect(skips(w)).toEqual([['agents-running', 'check']])
  w.agents = []
  await humanTurn($, w)
  await w.advance(56 * MIN)
  expect(ic(w).length).toBe(2)
  if (IDLE) expect([w.submits.length, skips(w).length]).toEqual([1, 1])
  else expect(skips(w)).toEqual([['agents-running', 'check'], ['no-asset', 'check']])
})

test('AT-IC-C45 (D7): the timer\'s and the check\'s failures count together: one at the timer (vetoed), one at the check (native on): idle_compact_off', { options: ON }, async ($, on) => {
  const w = world(on)
  w.compactMode = { skip: 'hook' }
  await w.start($)
  await humanTurn($, w)
  await w.advance(55 * MIN)
  expect(ic(w).map(r => r.at)).toEqual(['timer'])
  w.policy = NATIVE_ON
  w.agents = RUNNING
  await humanTurn($, w)
  await w.advance(56 * MIN)
  expect(ic(w).map(r => r.at)).toEqual(['timer', 'check'])
  expect(w.rowsOf('idle_compact_off').map(r => [r.why, r.fails])).toEqual([['failed', 2]])
})

test('AT-IC-C45 (owner Q2): idle_compact off with agents running: [agents-running, check] (the skip of before 2026-10-27), no compaction; idle_mode on/check/off', { options: { ...ON, idle_compact: 'false' } }, async ($, on) => {
  const w = world(on)
  w.policy = NATIVE_ON
  w.agents = RUNNING
  await w.start($)
  await humanTurn($, w)
  await w.advance(56 * MIN)
  expect(skips(w)).toEqual([['agents-running', 'check']])
  expect([ic(w).length, selfCompacts(w), w.submits.length]).toEqual([0, 0, 0])
  expect(modes(w)).toEqual(['on/check/off'])
})

test('AT-IC-C45 (owner Q2): below Claude Code\'s idle minimum (CLAUDE_CODE_IDLE_COMPACT_MIN_TOKENS 300000, 260K) the check runs the turn (or no-asset), no compaction; with agents running [small, check]', { options: ON }, async ($, on) => {
  const w = world(on)
  w.policy = NATIVE_ON
  w.env = { CLAUDE_CODE_IDLE_COMPACT_MIN_TOKENS: '300000' }
  await w.start($)
  await humanTurn($, w)
  await w.advance(56 * MIN)
  expect([ic(w).length, selfCompacts(w)]).toEqual([0, 0])
  if (IDLE) expect([w.submits.length, skips(w)]).toEqual([1, []])
  else expect(skips(w)).toEqual([['no-asset', 'check']])
})

test('AT-IC-C45 (owner Q2): below the minimum with agents running: [small, check] (they cannot get the turn), no compaction', { options: ON }, async ($, on) => {
  const w = world(on)
  w.policy = NATIVE_ON
  w.env = { CLAUDE_CODE_IDLE_COMPACT_MIN_TOKENS: '300000' }
  w.agents = RUNNING
  await w.start($)
  await humanTurn($, w)
  await w.advance(56 * MIN)
  expect([skips(w), selfCompacts(w), w.submits.length]).toEqual([[['small', 'check']], 0, 0])
})

test('AT-IC-C46 (lane B arming): native on, idle_handoff_turn off, idle_compact auto: the check is armed for the compaction (on/off/check) and compacts at 55.5 min, with or without agents; lane A armed nothing', { options: { ...ON, idle_handoff_turn: 'false' } }, async ($, on) => {
  const w = world(on)
  w.policy = NATIVE_ON
  await w.start($)
  await humanTurn($, w)
  expect(modes(w)).toEqual(['on/off/check'])
  await w.advance(56 * MIN)
  expect([ic(w).map(r => [r.at, r.agents]), selfCompacts(w), w.submits.length]).toEqual([[['check', 0]], 1, 0])
  w.agents = RUNNING
  await humanTurn($, w)
  await w.advance(56 * MIN)
  expect([ic(w).map(r => r.agents), selfCompacts(w), w.submits.length]).toEqual([[0, 1], 2, 0])
})

test('AT-IC-C46 (lane B arming): native on, idle_handoff_turn off, below the minimum (150K): nothing armed (the check could only skip small); both off: nothing armed, on/off/off', { options: { ...ON, idle_handoff_turn: 'false' } }, async ($, on) => {
  const w = world(on)
  w.policy = NATIVE_ON
  await w.start($)
  await humanTurn($, w, 150000)
  await w.advance(120 * MIN)
  expect([w.rowsOf('handoff_skipped').length, w.rowsOf('idle_silent').length, ic(w).length]).toEqual([0, 0, 0])
  expect(modes(w)).toEqual(['on/off/check'])
})

test('AT-IC-C46 (lane B arming): native on with idle_handoff_turn and idle_compact off: nothing armed; idle_mode on/off/off', { options: { ...ON, idle_handoff_turn: 'false', idle_compact: 'false' } }, async ($, on) => {
  const w = world(on)
  w.policy = NATIVE_ON
  w.agents = RUNNING
  await w.start($)
  await humanTurn($, w)
  await w.advance(120 * MIN)
  expect([w.rowsOf('handoff_skipped').length, w.rowsOf('idle_silent').length, ic(w).length, w.storeGet(KEY)]).toEqual([0, 0, 0, undefined])
  expect(modes(w)).toEqual(['on/off/off'])
})

test('AT-IC-C46 (owner Q2, D16): native on and silent, a finished lane, nothing running: the check compacts, then the away digest turn (digest_submit submitted)', { options: ON }, async ($, on) => {
  const w = world(on)
  w.policy = NATIVE_ON
  w.resumeHere = FINISHED
  await w.start($)
  await humanTurn($, w)
  await w.advance(56 * MIN)
  expect([ic(w).map(r => r.at), selfCompacts(w)]).toEqual([['check'], 1])
  await w.advance(5000)
  if (DONE) expect(w.rowsOf('digest_submit').map(r => r.result)).toEqual(['submitted'])
})

test('AT-IC-C35 (D12): a cancel (a turn start) while a tick reads the clock: that tick re-arms nothing and fires nothing; without one it ticks on, the last wait exact', async () => {
  const waits: number[] = []
  const fns: (() => void)[] = []
  let release: ((t: number) => void) | undefined
  let reads = 0
  const state = newState('load-1')
  const d = {
    state, cfg: DEFAULTS,
    after: (ms: number, fn: () => void) => {
      waits.push(ms)
      fns.push(fn)
      return { cancel: () => undefined }
    },
    now: () => new Promise<number>(r => { release = r }),
    storeGet: async () => {
      reads++
      return undefined
    },
  } as unknown as Deps
  const rec: Due = {
    due: T0 + 54 * MIN, sid: SID_A, episode: null, kind: 'compact', end: T0, answer: true, published: false, load: 'load-1',
    anchor: T0, tokens: 260000, ttl: '1h', pct: 30, spct: null, cc: null, model: null,
  }
  schedule(d, rec, T0 + 29 * MIN)
  expect(waits).toEqual([IDLE_TICK_MS])
  // The tick at minute 30 reads the clock; a turn starts meanwhile (alive.ts cancels the timer).
  fns[0]?.()
  cancelIdleTimer(d)
  release?.(T0 + 30 * MIN)
  await state.inflight
  expect([waits.length, reads]).toEqual([1, 0])
  // Uncancelled, the same tick arms the next one; the one 30 s before the due waits exactly 30 s.
  schedule(d, rec, T0 + 29 * MIN)
  fns[1]?.()
  release?.(T0 + 53.5 * MIN)
  await state.inflight
  expect(waits).toEqual([IDLE_TICK_MS, IDLE_TICK_MS, 30000])
  expect(reads).toBe(0)
})

// ---- D-76 (0.1.6): a near-limit skip row names the windows that were read

const nearRows = (w: World) => w.rowsOf('handoff_skipped').filter(r => r.reason === 'idle').map(r => [r.why, r.kind, r.windows])

test('D76-01 (compact): a seven-day window at 95% at the timer: the near-limit row names every reported window, in order, as kind:percent', { options: ON }, async ($, on) => {
  const w = world(on)
  await w.start($)
  await humanTurn($, w)
  await w.advance(53 * MIN)
  w.rateLimits = [{ kind: 'five_hour', percentUsed: 12 }, { kind: 'seven_day', percentUsed: 95 }]
  await w.measure($)
  await w.advance(MIN)
  expect(nearRows(w)).toEqual([['near-limit', 'compact', ['five_hour:12', 'seven_day:95']]])
})

test('D76-02 (turn, skip): a seven-day window at 94.6% before a five-hour one at 40%: the row keeps the reported order, whole percents rounded down', { options: { ...ON, idle_compact: 'false', idle_handoff_near_limit: 'skip' } }, async ($, on) => {
  const w = world(on)
  await w.start($)
  await humanTurn($, w)
  await w.advance(48 * MIN)
  w.rateLimits = [{ kind: 'seven_day', percentUsed: 94.6 }, { kind: 'five_hour', percentUsed: 40.9 }]
  await w.measure($)
  await w.advance(2 * MIN)
  expect(nearRows(w)).toEqual([['near-limit', 'turn', ['seven_day:94', 'five_hour:40']]])
})

test('D76-03 (check): native on, a spend limit at 95% at the 55.5-min check: the compaction\'s near-limit row names both windows', { options: { ...ON, idle_handoff_near_limit: 'skip' } }, async ($, on) => {
  const w = world(on)
  w.policy = {}
  await w.start($)
  await humanTurn($, w)
  await w.advance(55 * MIN)
  w.rateLimits = [{ kind: 'five_hour', percentUsed: 12 }, { kind: 'spend_limit', percentUsed: 95 }]
  await w.measure($)
  await w.advance(MIN)
  expect(nearRows(w)).toEqual([['near-limit', 'check', ['five_hour:12', 'spend_limit:95']]])
})

test('D76-04 (compact, arm; D-83): an adopted record armed at 95%, no reading yet: the compaction\'s row names the arm-time reading, arm:95, with its age (no fresh reading: rule no-fresh)', { options: ON }, async ($, on) => {
  const probe = new World()
  const w = world(on, {}, adoptedRecord(probe, { pct: 95.5 }))
  w.rateLimits = []
  w.tokens = undefined
  await w.start($)
  await w.advance(10 * MIN)
  expect(nearRows(w)).toEqual([])
  expect(ic(w).map(r => [r.rule, r.windows, Object.keys(r.usage_age_s as object)])).toEqual([['no-fresh', ['arm:95'], ['arm']]])
})

test('D76-05 (turn, skip-spend, arm; D-83): an adopted turn record armed at a 30% top share and a 95% spend share: the spend share is the reading, arm:95, 49 min old: no skip, the turn\'s start row names it (rule no-fresh)', { options: { ...ON, idle_compact: 'false', idle_handoff_near_limit: 'skip-spend' } }, async ($, on) => {
  const w = world(on, {}, adoptedTurn('1h', 30, 95))
  w.rateLimits = []
  w.tokens = undefined
  await w.start($)
  await w.advance(10 * MIN)
  expect(nearRows(w)).toEqual([])
  if (IDLE) expect(w.rowsOf('handoff_turn_open').length + w.submits.length).toBeGreaterThan(0)
})

test('D76-06: a skip row for any other reason has no windows field', { options: { ...ON, idle_compact: 'false' } }, async ($, on) => {
  const w = world(on, {}, adoptedTurn(null))
  w.rateLimits = []
  w.tokens = undefined
  await w.start($)
  await w.advance(10 * MIN)
  const rows = w.rowsOf('handoff_skipped').filter(r => r.reason === 'idle')
  expect(rows.map(r => [r.why, 'windows' in r])).toEqual([['ttl-5m', false]])
})
