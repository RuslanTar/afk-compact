// U tests through the kit: the pre-compaction handoff turn (MOD-SPEC §9.3, S-SETTINGS D, OD-4;
// setting `precompact_turn`). The cases that run the turn need the `[submit-pre]` lines of
// handoff-turn.txt; a build without them skips the turn (`no-asset`) and those cases check that.
import { expect, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import { assemble, hasTag } from '../../hooks/lib/assemble'
import { storeWord } from '../../hooks/lib/deps'
import { maxCalls, submitText } from '../../hooks/lib/handoff-turn'
import { HOME, SID_A, T0, World, markerNonce } from './harness.test'

/** This build's handoff-turn text has the pre-compaction turn's own lines. */
const PRE = hasTag('handoff-turn', 'submit-pre')
const MODEL = { precompact_turn: 'model' }
const PUBLISHED = HOME + '/.claude/handoffs/r/LAB-42/2026-10-21_14-09-00_5e55a001_handoff.md'
const SHOWN = '~/.claude/handoffs/r/LAB-42/2026-10-21_14-09-00_5e55a001_handoff.md'

const preText = (w: World): string | undefined =>
  submitText(w.name, 'precompact', { max_calls: String(maxCalls()), store: storeWord(w.root, w.name) ?? '' })

/** A main turn with no tool call that ends `answer` at `tokens` (not nudged). */
async function eligibleEnd($: Engine, w: World, answer = 'Done with that step.', tokens = 410000): Promise<void> {
  await w.turnStart($)
  w.tokens = tokens
  await w.turnEnd($, answer)
}

/** Three low-token main turns: a compaction before them does not count toward thrash. */
async function quiet($: Engine, w: World): Promise<void> {
  w.tokens = 100000
  for (let i = 0; i < 3; i++) {
    await w.turnStart($)
    await w.turnEnd($)
  }
}

const skips = (w: World) => w.rowsOf('handoff_skipped').map(r => [r.why, r.reason])

test('AT-PC-01: model: a turn ends answer at 410K → one [submit-pre]+[submit] submit after the delay, ht reason precompact, no compaction before it; published → one compaction with [handoff], no continue, no toast', { options: MODEL }, async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await eligibleEnd($, w)
  if (!PRE) {
    await w.advance(2000)
    expect(skips(w)).toEqual([['no-asset', 'precompact']])
    expect([w.compacts.length, w.submits.length]).toEqual([1, 0])
    return
  }
  await w.advance(1999)
  expect([w.compacts.length, w.submits.length]).toEqual([0, 0])
  await w.advance(1)
  expect(w.submits).toEqual([preText(w)])
  expect(w.compacts.length).toBe(0)
  const open = w.callsOf('handoff-turn').filter(c => c.args[0] === 'open')
  expect(open.map(c => w.flag(c, '--reason'))).toEqual(['precompact'])
  await w.turnStart($, '')
  const ht = w.lastHt() ?? ''
  expect(w.rowsOf('handoff_turn_start').map(r => [r.ht, r.reason])).toEqual([[ht, 'precompact']])
  w.publish(ht, PUBLISHED)
  w.tokens = 450000
  await w.turnEnd($, 'Handoff written.')
  await w.advance(499)
  expect(w.compacts.length).toBe(0)
  await w.advance(1)
  expect(w.compacts.length).toBe(1)
  const d = w.callsOf('dispatch')[0]
  expect([w.flag(d, '--handoff-ht'), w.flag(d, '--channel')]).toEqual([ht, 'mod-self'])
  expect(w.flag(d, '--tags')?.split(',')).toContain('handoff')
  const text = assemble(w.name, 'handoff-instructions', ['handoff'], { nonce: w.flag(d, '--nonce') ?? '', handoff_path: SHOWN, measured_at: '' })
  if (text.includes(SHOWN)) expect(w.compacts[0]?.instructions).toContain(SHOWN)
  await w.advance(60000)
  expect(w.submits.length).toBe(1)
  expect(w.toasts.filter(t => t.includes('handoff'))).toEqual([])
  expect(w.rowsOf('handoff_turn_end').map(r => [r.handoff_turn, r.reason, r.compaction])).toEqual([['published', 'precompact', true]])
})

test('AT-PC-01 (end): not published → the normal compaction with the full text (no [handoff]); no continue', { options: MODEL }, async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await eligibleEnd($, w)
  if (!PRE) return
  await w.advance(2000)
  await w.turnStart($, '')
  await w.turnEnd($, 'LINT stop.')
  await w.advance(500)
  expect(w.compacts.length).toBe(1)
  const d = w.callsOf('dispatch')[0]
  expect(w.flag(d, '--tags')?.split(',') ?? []).not.toContain('handoff')
  expect(markerNonce(w, w.compacts[0]?.instructions)).toBe(w.flag(d, '--nonce'))
  await w.advance(60000)
  expect(w.submits.length).toBe(1)
})

test('AT-PC-02 (a): the turn ends on a question → asks-user, then the normal compaction with the full text', { options: MODEL }, async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await eligibleEnd($, w, 'All green. Should I push now?')
  await w.advance(2000)
  expect(skips(w)).toEqual([['asks-user', 'precompact']])
  expect([w.compacts.length, w.submits.length]).toEqual([1, 0])
})

test('AT-PC-02 (b): a handoff turn in the last 60 min → cap (first slot only), then the normal compaction', { options: MODEL }, async ($, on) => {
  const w = new World().install(on, { ['ht:' + SID_A]: [T0 - 30 * 60000] })
  await w.start($)
  await eligibleEnd($, w)
  await w.advance(2000)
  expect(skips(w)).toEqual([['cap', 'precompact']])
  expect([w.compacts.length, w.submits.length]).toEqual([1, 0])
})

test('AT-PC-02 (d): H < 20K → headroom, then the normal compaction', { options: MODEL }, async ($, on) => {
  const w = new World({ window: 800000 }).install(on)
  await w.start($)
  await eligibleEnd($, w, 'Done.', 745000)
  await w.advance(2000)
  expect(skips(w)).toEqual([['headroom', 'precompact']])
  expect([w.compacts.length, w.submits.length]).toEqual([1, 0])
})

test('AT-PC-02 (c): an aborted pre-compaction turn compacts nothing; the next eligible turn end before a compaction → again, then the normal compaction', { options: MODEL }, async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await eligibleEnd($, w)
  if (!PRE) return
  await w.advance(2000)
  await w.turnStart($, '')
  await w.turnEnd($, '', 'aborted')
  await w.advance(60000)
  expect(w.compacts.length).toBe(0)
  expect(w.rowsOf('handoff_turn_end').map(r => [r.handoff_turn, r.compaction])).toEqual([['aborted', false]])
  await eligibleEnd($, w)
  await w.advance(2000)
  expect(skips(w)).toEqual([['again', 'precompact']])
  expect([w.compacts.length, w.submits.length]).toEqual([1, 1])
  // After that compaction, and once the hourly slot is free, a new eligible turn end gets its
  // pre-compaction turn again.
  await w.advance(61 * 60000)
  await eligibleEnd($, w)
  await w.advance(2000)
  expect(w.submits.length).toBe(2)
})

test('AT-PC-03: model, a user turn.start during the delay: no submit, no compaction; handoff_skipped why=user-turn', { options: MODEL }, async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await eligibleEnd($, w)
  if (!PRE) return
  await w.advance(1000)
  await w.turnStart($)
  expect(skips(w)).toEqual([['user-turn', 'precompact']])
  await w.advance(10000)
  expect([w.compacts.length, w.submits.length]).toEqual([0, 0])
})

for (const v of [
  { name: 'code', options: { precompact_turn: 'code' }, invalid: false },
  { name: 'sometimes', options: { precompact_turn: 'sometimes' }, invalid: true },
]) {
  test(`AT-PC-04 (${v.name}): as built: no submit, the normal compaction at boundary_delay_ms${v.invalid ? ', config_invalid' : ''}`, { options: v.options }, async ($, on) => {
    const w = new World().install(on)
    await w.start($)
    await eligibleEnd($, w)
    await w.advance(2000)
    expect([w.compacts.length, w.submits.length, w.rowsOf('handoff_skipped').length]).toEqual([1, 0, 0])
    expect(w.rowsOf('config_invalid').map(r => r.key)).toEqual(v.invalid ? ['precompact_turn'] : [])
  })
}

test('AT-PC-04 (Model ): trimmed and folded to model', { options: { precompact_turn: ' Model ' } }, async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await eligibleEnd($, w)
  await w.advance(2000)
  expect(w.rowsOf('config_invalid').length).toBe(0)
  if (PRE) expect(w.submits).toEqual([preText(w)])
  else expect(skips(w)).toEqual([['no-asset', 'precompact']])
})

test('AT-PC-05: a pre-compaction turn, then within 60 min a last cycle: its handoff turn still runs (slot kept); a third → cap', { options: { ...MODEL, max_auto_continues_per_hour: 0 } }, async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await eligibleEnd($, w)
  if (!PRE) return
  await w.advance(2000)
  await w.turnStart($, '')
  await w.turnEnd($, 'Handoff written.')
  await w.advance(500)
  expect(w.compacts.length).toBe(1)
  await w.advance(10 * 60000)
  await quiet($, w)
  // A last cycle (continue-off): nudged at 610K, ends at 640K.
  await w.turnStart($)
  w.tokens = 610000
  await w.tool($)
  w.tokens = 640000
  await w.turnEnd($, 'Checkpoint: clean · Step 1: run the tests')
  await w.advance(2000)
  expect(w.submits.length).toBe(2)
  await w.turnStart($, '')
  expect(w.rowsOf('handoff_turn_start').map(r => r.reason)).toEqual(['precompact', 'continue-off'])
  w.tokens = 100000
  await w.turnEnd($, 'Handoff written.')
  await w.advance(60000)
  await quiet($, w)
  // A third handoff turn within the hour: no room, for either kind.
  await eligibleEnd($, w)
  await w.advance(2000)
  expect(skips(w).filter(s => s[0] === 'cap')).toEqual([['cap', 'precompact']])
  expect(w.submits.length).toBe(2)
})
