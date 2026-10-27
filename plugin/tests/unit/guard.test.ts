// U tests through the kit: the "never a different model" guard (ratify R4 kept with a tested
// guarantee, owner xxxxxxxx-18, 2026-10-23; SPEC-DELTAS MG-2…MG-4). The mod names no model,
// effort, fallback model or agent in any compact or submit call (MG-2, a spy on every call that
// reaches the bottom); it records the session's model (MG-4), the prefix read of the summarizer
// request with its uncovered input (root ruling 2026-10-27 23:16) and the cache-read share of the
// handoff turn's first request (MG-3), the runtime sign that a request went to another model (it
// cannot read the session's cache).
import { expect, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import { hasTag } from '../../hooks/lib/assemble'
import { prefixRead, readShare, uncoveredInput } from '../../hooks/lib/deps'
import { HOME, World, markerNonce, raiseCompact } from './harness.test'

const FORBIDDEN = ['model', 'effort', 'fallbackModel', 'agent', 'agentType']
const PRE = hasTag('handoff-turn', 'submit-pre')
const IDLE = hasTag('handoff-turn', 'submit-idle')
const MIN = 60000
const PUBLISHED = HOME + '/.claude/handoffs/r/LAB-42/2026-10-21_14-09-00_5e55a001_handoff.md'

/** MG-2: the plugin's compact calls carry `instructions` only; no call names a model. */
function keysClean(w: World): void {
  for (const [i, keys] of w.compactKeys.entries()) {
    expect(keys.filter(k => FORBIDDEN.includes(k))).toEqual([])
    // A compaction the plugin started has no trigger of the caller's: its keys are its own.
    if (w.compacts[i]?.trigger === undefined) expect(keys).toEqual(['instructions'])
  }
  for (const keys of w.submitKeys) {
    expect(keys.filter(k => FORBIDDEN.includes(k))).toEqual([])
    expect(keys).toContain('text')
  }
}

/** A main turn that crosses the soft max (nudge), ends with a clean answer and compacts. */
async function nudgedTurn($: Engine, w: World): Promise<void> {
  await w.userTurn($)
  w.tokens = 610000
  await w.tool($)
  await w.turnEnd($, 'Checkpoint: clean · Step 1: run the tests')
  await w.advance(2000)
}

test('AT-MG-02: boundary and continue paths: the plugin compaction and the continue submit name no model, effort or agent', { options: { precompact_turn: 'code' } }, async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await nudgedTurn($, w)
  expect(w.compacts.filter(c => c.trigger === undefined).length).toBe(1)
  expect(w.submits.length).toBe(1)
  keysClean(w)
})

test('AT-MG-02: handoff-turn path (precompact_turn model): the handoff-turn submit and the compaction after it name no model', { options: { precompact_turn: 'model' } }, async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await w.turnStart($)
  w.tokens = 410000
  await w.turnEnd($, 'Done with that step.')
  await w.advance(2000)
  if (PRE) {
    expect(w.submits.length).toBe(1)
    await w.turnStart($, '')
    w.publish(w.lastHt() ?? '', PUBLISHED)
    w.tokens = 450000
    await w.turnEnd($, 'Handoff written.')
    await w.advance(500)
  }
  expect(w.compacts.filter(c => c.trigger === undefined).length).toBe(1)
  keysClean(w)
})

test('AT-MG-02: idle path: the pre-idle turn submit names no model; a native auto, manual or idle compaction gets instructions added and nothing else', { options: { idle_handoff_turn: 'auto', precompact_turn: 'code', idle_compact: 'off' } }, async ($, on) => {
  const w = new World().install(on)
  w.policy = { idleCompaction: false }
  w.rateLimits = [{ kind: 'five_hour', percentUsed: 12 }]
  await w.start($)
  await w.userTurn($)
  w.tokens = 260000
  await w.turnEnd($, 'Done with that step.')
  await w.advance(49 * MIN)
  expect(w.submits.length).toBe(IDLE ? 1 : 0)
  for (const trigger of ['auto', 'manual', 'idle']) await raiseCompact($, { trigger })
  for (const [i, keys] of w.compactKeys.entries()) {
    if (w.compacts[i]?.trigger !== undefined) expect(keys).toEqual(['instructions', 'messages', 'trigger'])
  }
  keysClean(w)
})

// IDLE-COMPACT D2: with "idleCompaction": false the plugin's own idle compaction at 54 min takes
// the 49-min turn's place; it is a plugin compaction like the others, naming no model.
test('AT-MG-02: idle path (the plugin\'s own idle compaction): one mod-self idle compaction at 54 min with instructions only; nothing submitted', { options: { idle_handoff_turn: 'auto', precompact_turn: 'code' } }, async ($, on) => {
  const w = new World().install(on)
  w.policy = { idleCompaction: false }
  w.rateLimits = [{ kind: 'five_hour', percentUsed: 12 }]
  await w.start($)
  await w.userTurn($)
  w.tokens = 260000
  await w.turnEnd($, 'Done with that step.')
  await w.advance(49 * MIN)
  expect([w.submits.length, w.compacts.length]).toEqual([0, 0])
  await w.advance(5 * MIN)
  expect(w.callsOf('dispatch').map(c => w.flag(c, '--channel'))).toEqual(['mod-self'])
  expect(w.compacts.map(c => c.trigger)).toEqual([undefined])
  expect(w.submits.length).toBe(0)
  keysClean(w)
})

test('MG-3: readShare is cache reads over all input tokens, 3 places; null without usage or input', () => {
  expect(readShare({ input_tokens: 2000, cache_read_input_tokens: 380000, cache_creation_input_tokens: 10000 })).toBe(0.969)
  expect(readShare({ input_tokens: 0, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 })).toBe(null)
  expect(readShare(null)).toBe(null)
  expect(readShare(undefined)).toBe(null)
})

// Root ruling 2026-10-27 23:16 (the L3 cold-cache forensics): a compaction's request leaves the
// context after its one cache marker uncached, warm or cold, so the cold test reads the prefix only.
test('prefixRead is cache reads over the cached prefix (reads + writes), 3 places; uncoveredInput the input outside it; null without usage or cache tokens', () => {
  // L3 (warm, 54 min): 0.045 of all input read, but 0.925 of the prefix.
  const l3 = { input_tokens: 338700, cache_read_input_tokens: 16048, cache_creation_input_tokens: 1301 }
  expect([readShare(l3), prefixRead(l3), uncoveredInput(l3)]).toEqual([0.045, 0.925, 338700])
  expect(prefixRead({ input_tokens: 2000, cache_read_input_tokens: 380000, cache_creation_input_tokens: 10000 })).toBe(0.974)
  expect(prefixRead({ input_tokens: 2000, cache_read_input_tokens: 0, cache_creation_input_tokens: 398000 })).toBe(0)
  // Caching off: no prefix at all, so no prefix read (the input is all uncovered).
  expect([prefixRead({ input_tokens: 400000, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 }),
    uncoveredInput({ input_tokens: 400000, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 })]).toEqual([null, 400000])
  expect([prefixRead(null), prefixRead(undefined), uncoveredInput(null), uncoveredInput(undefined)]).toEqual([null, null, null, null])
})

test('AT-MG-03: a compaction with usage {read 380K, input 2K, creation 10K} → compaction_cache prefix_read ≈0.97, uncovered 2K, no compaction_cold; read 0 at 400K → compaction_cold; no usage → no row', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  w.tokens = 392000
  w.compactUsage = { input_tokens: 2000, output_tokens: 9000, cache_read_input_tokens: 380000, cache_creation_input_tokens: 10000 }
  await raiseCompact($, { trigger: 'manual' })
  const n1 = markerNonce(w, w.compacts[0]?.instructions)
  expect(w.rowsOf('compaction_cache').map(r => [r.nonce, r.prefix_read, r.uncovered, r.read_share])).toEqual([[n1, 0.974, 2000, undefined]])
  expect(w.rowsOf('compaction_cold').length).toBe(0)
  w.tokens = 400000
  w.compactUsage = { input_tokens: 2000, output_tokens: 9000, cache_read_input_tokens: 0, cache_creation_input_tokens: 398000 }
  await raiseCompact($, { trigger: 'auto' })
  const n2 = markerNonce(w, w.compacts[1]?.instructions)
  expect(w.rowsOf('compaction_cold').map(r => [r.nonce, r.prefix_read, r.read_share])).toEqual([[n2, 0, undefined]])
  // Under 100K a cold read is not reported as cold.
  w.tokens = 90000
  w.compactUsage = { input_tokens: 2000, output_tokens: 9000, cache_read_input_tokens: 0, cache_creation_input_tokens: 88000 }
  await raiseCompact($, { trigger: 'manual' })
  expect(w.rowsOf('compaction_cold').length).toBe(1)
  expect(w.rowsOf('compaction_cache').length).toBe(3)
  w.compactUsage = undefined
  await raiseCompact($, { trigger: 'manual' })
  expect(w.rowsOf('compaction_cache').length).toBe(3)
})

test('AT-MG-03 (root ruling 2026-10-27 23:16): the L3 idle compaction, warm, with 338K of tool results after the last cache marker: not cold; the uncovered input is logged apart', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  w.tokens = 355000
  w.compactUsage = { input_tokens: 338700, output_tokens: 3800, cache_read_input_tokens: 16048, cache_creation_input_tokens: 1301 }
  await raiseCompact($, { trigger: 'auto' })
  const n = markerNonce(w, w.compacts[0]?.instructions)
  expect(w.rowsOf('compaction_cache').map(r => [r.nonce, r.prefix_read, r.uncovered])).toEqual([[n, 0.925, 338700]])
  expect(w.rowsOf('compaction_cold').length).toBe(0)
  // A cold one of the same size (the prefix written again, about 0.27 read): cold.
  w.compactUsage = { input_tokens: 290000, output_tokens: 3800, cache_read_input_tokens: 17000, cache_creation_input_tokens: 46000 }
  await raiseCompact($, { trigger: 'auto' })
  const n2 = markerNonce(w, w.compacts[1]?.instructions)
  expect(w.rowsOf('compaction_cold').map(r => [r.nonce, r.prefix_read])).toEqual([[n2, 0.27]])
  // Caching off: no prefix, so no cold row; the whole input is uncovered.
  w.compactUsage = { input_tokens: 355000, output_tokens: 3800, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 }
  await raiseCompact($, { trigger: 'auto' })
  expect(w.rowsOf('compaction_cache').map(r => [r.prefix_read, r.uncovered]).slice(-1)).toEqual([[null, 355000]])
  expect(w.rowsOf('compaction_cold').length).toBe(1)
})

test('AT-MG-03: the plugin\'s own compaction logs compaction_cache too', { options: { precompact_turn: 'code' } }, async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  w.compactUsage = { input_tokens: 1000, output_tokens: 9000, cache_read_input_tokens: 600000, cache_creation_input_tokens: 9000 }
  await nudgedTurn($, w)
  const n = markerNonce(w, w.compacts[0]?.instructions)
  expect(w.rowsOf('compaction_cache').map(r => [r.nonce, r.prefix_read, r.uncovered])).toEqual([[n, 0.985, 1000]])
  expect(w.rowsOf('compaction_cold').length).toBe(0)
})

test('MG-4: the dispatch call and the handoff_turn_start row carry the session\'s model; an unreadable model is left out', { options: { precompact_turn: 'model' } }, async ($, on) => {
  const w = new World().install(on)
  w.model = 'claude-opus-5-5[1m]'
  await w.start($)
  await raiseCompact($, { trigger: 'manual' })
  expect(w.callsOf('dispatch')[0]?.args).toContain('--model=claude-opus-5-5[1m]')
  w.model = undefined
  await raiseCompact($, { trigger: 'manual' })
  expect((w.callsOf('dispatch')[1]?.args ?? []).some(a => a.startsWith('--model'))).toBe(false)
  if (!PRE) return
  w.model = 'claude-opus-5-5[1m]'
  await w.turnStart($)
  w.tokens = 410000
  await w.turnEnd($, 'Done with that step.')
  await w.advance(2000)
  await w.turnStart($, '')
  expect(w.rowsOf('handoff_turn_start').map(r => r.model)).toEqual(['claude-opus-5-5[1m]'])
})

test('MG-3: handoff_turn_end logs the first request\'s cache_read_share for a pre-compaction turn (every reason); later steps and other turns do not change it; no step usage → null', { options: { precompact_turn: 'model' } }, async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  // A step of an ordinary turn is not a handoff turn's.
  await w.turnStart($)
  w.stepUsage = { input_tokens: 10, output_tokens: 10, cache_read_input_tokens: 0, cache_creation_input_tokens: 400000, model: 'claude-test-model' }
  await w.step($, 0)
  w.tokens = 410000
  await w.turnEnd($, 'Done with that step.')
  await w.advance(2000)
  if (!PRE) return
  await w.turnStart($, '')
  w.stepUsage = { input_tokens: 2000, output_tokens: 500, cache_read_input_tokens: 300000, cache_creation_input_tokens: 98000, model: 'claude-test-model' }
  await w.step($, 0)
  w.stepUsage = { input_tokens: 2000, output_tokens: 500, cache_read_input_tokens: 0, cache_creation_input_tokens: 400000, model: 'claude-test-model' }
  await w.step($, 1)
  w.publish(w.lastHt() ?? '', PUBLISHED)
  w.tokens = 450000
  await w.turnEnd($, 'Handoff written.')
  expect(w.rowsOf('handoff_turn_end').map(r => [r.reason, r.cache_read_share])).toEqual([['precompact', 0.75]])
})

test('MG-3: a pre-compaction turn whose first step result has no usage: handoff_turn_end cache_read_share null', { options: { precompact_turn: 'model' } }, async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await w.turnStart($)
  w.tokens = 410000
  await w.turnEnd($, 'Done with that step.')
  await w.advance(2000)
  if (!PRE) return
  await w.turnStart($, '')
  w.stepUsage = null
  await w.step($, 0)
  w.publish(w.lastHt() ?? '', PUBLISHED)
  await w.turnEnd($, 'Handoff written.')
  expect(w.rowsOf('handoff_turn_end').map(r => [r.reason, r.cache_read_share])).toEqual([['precompact', null]])
})
