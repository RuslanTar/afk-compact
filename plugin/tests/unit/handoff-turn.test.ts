// U tests through the kit: the handoff turn of a last cycle (MOD-SPEC §9.1, §9.2; D-18 with
// DP-4, DP-5, DP-13). Shipped prose is never matched literally: every expected text is the
// assembled tag contract (assemble with the tag and runtime the mod must use), so the tests hold
// for any wording of the assets. Until `handoff-turn.txt` ships in this build, the turn cannot be
// submitted: those tests check the safe degrade instead (`handoff_skipped why=no-asset`, and the
// normal compaction for `cap`/`continue-off`), and the integrator re-runs them after the text merge.
import { expect, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import { assemble, assembleIf, hasAsset } from '../../hooks/lib/assemble'
import { assetText } from '../../hooks/lib/assets.gen'
import { DEFAULTS } from '../../hooks/lib/config'
import { lastCycleOf } from '../../hooks/lib/cont'
import type { Deps } from '../../hooks/lib/deps'
import { newState } from '../../hooks/lib/deps'
import { HALT_REASON_TEXT, maxCalls } from '../../hooks/lib/handoff-turn'
import { HOME, SID_A, T0, WATCH, World, raiseCompact } from './harness.test'

const TURN = hasAsset('handoff-turn')
const C = maxCalls() ?? 0
const STAGE = HOME + '/.claude/handoffs/r/LAB-42/.stage/2026-10-21_14-05-12_ab12'
const FINISH = `<store> publish --stage '${STAGE}' --slug lab-42 --status in-progress`
const PUBLISHED = HOME + '/.claude/handoffs/r/LAB-42/2026-10-21_14-07-00_5e55a001_handoff.md'
const SHOWN = '~/.claude/handoffs/r/LAB-42/2026-10-21_14-07-00_5e55a001_handoff.md'
/** Three continues in the last hour: the next nudged cycle is capped (max 3). */
const CAPPED = { ['cont:' + SID_A]: [T0 - 50 * 60000, T0 - 30 * 60000, T0 - 10 * 60000] }

/** A main turn that crosses the soft max (nudge) and ends with `answer` at `end` tokens. */
async function lastCycleTurn($: Engine, w: World, answer = 'Checkpoint: clean · Step 1: run the tests', end = 640000): Promise<{ context?: readonly string[] }> {
  await w.turnStart($)
  w.tokens = 610000
  const r = await w.tool($)
  w.tokens = end
  await w.turnEnd($, answer)
  return r
}

/** Two unshaped main verdicts inside one user turn: halt `2-nonok` stays on for that turn. */
async function haltTwoNonOk($: Engine, w: World): Promise<void> {
  w.summaryMode = 'unshaped'
  await w.turnStart($)
  await raiseCompact($, { trigger: 'auto' })
  await raiseCompact($, { trigger: 'auto' })
  w.summaryMode = 'ok'
  w.compacts = []
}

/** Our submitted handoff turn starts (the engine runs it once idle). */
async function handoffTurnStarts($: Engine, w: World): Promise<void> {
  await w.turnStart($, '')
}

function submitText(w: World, reason: keyof typeof HALT_REASON_TEXT): string | undefined {
  return assembleIf(w.name, 'handoff-turn', ['submit'], { halt_reason: HALT_REASON_TEXT[reason], max_calls: String(C) })
}

function bandText(w: World, band: 'near' | 'spent' | 'imminent'): string | undefined {
  return assembleIf(w.name, 'handoff-turn', [band], {})
}

test('c = 1 + call_cap + recipe_cap from the shared spec = 34 (RV-25, DP-6)', () => {
  expect(C).toBe(34)
})

test('AT-LT-01: nudge at 610K: [halt] with @halt_reason@ for (a) halt, (b) cap reached, (c) max 0; [continue] for (d)', async ($, on) => {
  const w = new World().install(on, CAPPED)
  await w.start($)
  const r = await lastCycleTurn($, w)
  const want = assemble(w.name, 'checkpoint-nudge', TURN ? ['halt', 'halt-handoff'] : ['halt'], { tokens: '610,000', halt_reason: HALT_REASON_TEXT.cap })
  expect(r.context?.[0]).toBe(want)
  if (assetText('checkpoint-nudge', w.name).includes('@halt_reason@')) expect(r.context?.[0]).toContain(HALT_REASON_TEXT.cap)
  expect(r.context?.[0]).not.toBe(assemble(w.name, 'checkpoint-nudge', ['continue'], { tokens: '610,000' }))
  expect(w.rowsOf('nudge')[0]?.last_cycle).toBe('cap')
  // (b) the cap is found at the nudged turn's end, before any compaction (DP-13).
  expect(w.rowsOf('continue_capped').length).toBe(1)
  expect(w.rowsOf('halt').map(r => [r.reason, r.active])).toEqual([['cap', true]])
  expect(w.rowsOf('continue').map(r => r.result)).toEqual(['halt:cap'])
  expect(w.compacts.length).toBe(0)
})

test('AT-LT-01 (a): halt 2-nonok gives [halt] with its reason', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await haltTwoNonOk($, w)
  w.tokens = 610000
  const r = await w.tool($)
  expect(r.context?.[0]).toBe(assemble(w.name, 'checkpoint-nudge', TURN ? ['halt', 'halt-handoff'] : ['halt'], { tokens: '610,000', halt_reason: HALT_REASON_TEXT['2-nonok'] }))
  expect(w.rowsOf('nudge')[0]?.last_cycle).toBe('2-nonok')
})

test('AT-LT-01 (a) thrash and unknown persisted reasons; (c) max 0; (d) none (lastCycleOf)', async () => {
  const fake = (halt: { active: boolean; reason: string | null }, max = 3, stamps: number[] = []) => {
    const state = newState('l')
    state.halt = halt
    return { cfg: { ...DEFAULTS, max_auto_continues_per_hour: max }, state, now: async () => T0, storeGet: async () => stamps } as unknown as Deps
  }
  expect(await lastCycleOf(fake({ active: true, reason: 'thrash' }), SID_A)).toBe('thrash')
  expect(await lastCycleOf(fake({ active: true, reason: null }), SID_A)).toBe('2-nonok')
  expect(await lastCycleOf(fake({ active: false, reason: null }, 0), SID_A)).toBe('continue-off')
  expect(await lastCycleOf(fake({ active: false, reason: null }, 3, [T0 - 1000, T0 - 2000]), SID_A)).toBeNull()
  expect(await lastCycleOf(fake({ active: false, reason: null }, 3, [T0 - 1000, T0 - 2000, T0 - 3000]), SID_A)).toBe('cap')
  expect(await lastCycleOf(fake({ active: false, reason: null }, 3, [T0 - 61 * 60000, T0 - 2000, T0 - 3000]), SID_A)).toBeNull()
})

test('AT-LT-01 (c): max_auto_continues_per_hour 0: [halt] (continue-off), never the [continue] promise (DP-13)', { options: { max_auto_continues_per_hour: 0 } }, async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  const r = await lastCycleTurn($, w)
  expect(r.context?.[0]).toBe(assemble(w.name, 'checkpoint-nudge', TURN ? ['halt', 'halt-handoff'] : ['halt'], { tokens: '610,000', halt_reason: HALT_REASON_TEXT['continue-off'] }))
  expect(w.rowsOf('continue').map(r => r.result)).toEqual(['skipped:disabled'])
  expect(w.rowsOf('halt').length).toBe(0)
})

test('handoff_turn off: [halt] without the handoff-turn sentence; the normal compaction, no continue', { options: { handoff_turn: 'off' } }, async ($, on) => {
  const w = new World().install(on, CAPPED)
  await w.start($)
  const r = await lastCycleTurn($, w)
  expect(r.context?.[0]).toBe(assemble(w.name, 'checkpoint-nudge', ['halt'], { tokens: '610,000', halt_reason: HALT_REASON_TEXT.cap }))
  await w.advance(500)
  expect(w.compacts.length).toBe(1)
  expect(w.submits.length).toBe(0)
  expect(w.rowsOf('handoff_skipped').length).toBe(0)
  expect(w.callsOf('handoff-turn').length).toBe(0)
})

test('AT-LT-02: last-cycle turn ends answer at 640K, window 800000: one framed submit after the delay, no compaction before it', async ($, on) => {
  const w = new World({ window: 800000 }).install(on, CAPPED)
  await w.start($)
  await lastCycleTurn($, w)
  if (!TURN) {
    expect(w.rowsOf('handoff_skipped').map(r => r.why)).toEqual(['no-asset'])
    await w.advance(500)
    expect([w.compacts.length, w.submits.length]).toEqual([1, 0])
    return
  }
  await w.advance(1999)
  expect([w.submits.length, w.callsOf('handoff-turn').length]).toEqual([0, 0])
  await w.advance(1)
  expect(w.submits).toEqual([submitText(w, 'cap')])
  expect(w.compacts.length).toBe(0)
  const open = w.callsOf('handoff-turn')[0]
  const ht = w.flag(open, '--ht') ?? ''
  expect([open?.args[0], w.flag(open, '--reason'), w.flag(open, '--max-calls'), w.flag(open, '--max-tokens')]).toEqual(['open', 'cap', '34', '64000'])
  expect(w.files.has(`${WATCH}/${SID_A}/handoff-turn/${ht}.json`)).toBe(true)
  await handoffTurnStarts($, w)
  expect(w.rowsOf('halt').filter(r => r.active === false).length).toBe(0)
  expect(w.rowsOf('handoff_turn_start').map(r => [r.ht, r.reason, r.turn_id])).toEqual([[ht, 'cap', 't2']])
})

test('AT-LT-03: a user turn.start during the delay cancels the submit: handoff_skipped why=user-turn', async ($, on) => {
  const w = new World().install(on, CAPPED)
  await w.start($)
  await lastCycleTurn($, w)
  if (!TURN) return
  await w.advance(1000)
  await w.turnStart($, 'actually, stop here')
  await w.advance(10000)
  expect(w.submits.length).toBe(0)
  expect(w.rowsOf('handoff_skipped').map(r => [r.why, r.ht])).toEqual([['user-turn', null]])
  expect(w.rowsOf('halt').filter(r => r.active === false).length).toBe(1)
})

// max 0 keeps every cycle a last cycle across user turns (a user turn clears halt and the cap).
test('AT-LT-04: no handoff turn after (a) a question, (b) an AskUserQuestion call, (c) aborted, (d) a native compaction in that turn', { options: { max_auto_continues_per_hour: 0 } }, async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await lastCycleTurn($, w, 'All green.\n\nShould I push?')
  await w.advance(5000)
  expect(w.rowsOf('handoff_skipped').map(r => r.why)).toEqual(['asks-user'])
  expect(w.submits.length).toBe(0)
  // (b)
  await w.advance(60000)
  await w.turnStart($)
  w.tokens = 610000
  await w.tool($)
  await $.tool.call({ tool: 'AskUserQuestion', questions: [] } as never)
  await w.turnEnd($)
  await w.advance(5000)
  // (c)
  await w.advance(60000)
  await w.turnStart($)
  w.tokens = 610000
  await w.tool($)
  await w.turnEnd($, '', 'aborted')
  await w.advance(5000)
  // (d)
  await w.advance(60000)
  await w.turnStart($)
  w.tokens = 610000
  await w.tool($)
  await raiseCompact($, { trigger: 'auto' })
  w.tokens = 620000
  await w.turnEnd($)
  await w.advance(5000)
  expect(w.rowsOf('handoff_skipped').map(r => r.why)).toEqual(['asks-user', 'asks-user', 'compacted'])
  expect(w.submits.length).toBe(0)
  expect(w.callsOf('handoff-turn').length).toBe(0)
})

test('AT-LT-05: turn ends at 745K with N 767K (H < 20K): why=headroom; one plugin compaction with the full text; no submit', { options: { max_auto_continues_per_hour: 0 } }, async ($, on) => {
  const w = new World({ window: 800000 }).install(on)
  await w.start($)
  await lastCycleTurn($, w, 'Checkpoint: clean · Step 1: x', 745000)
  await w.advance(500)
  expect(w.rowsOf('handoff_skipped').map(r => r.why)).toEqual([TURN ? 'headroom' : 'no-asset'])
  expect(w.compacts.length).toBe(1)
  expect(w.callsOf('dispatch')[0]?.args).not.toContain('--handoff-ht')
  expect(w.flag(w.callsOf('dispatch')[0], '--tags')?.split(',')).not.toContain('handoff')
  expect(w.submits.length).toBe(0)
})

test('AT-LT-06: bands are context text only: one [near], [spent] from t0+H, [imminent] at N-5K; nothing denied; no nudge', async ($, on) => {
  const w = new World().install(on, CAPPED)
  await w.start($)
  await lastCycleTurn($, w)
  if (!TURN) return
  await w.advance(2000)
  await handoffTurnStarts($, w)
  // window 1,000,000: N 967,000; t0 640,000; H 64,000: near 688,000, spent 704,000, imminent 962,000.
  w.tokens = 650000
  expect((await w.tool($)).context).toBeUndefined()
  w.tokens = 688000
  expect((await w.tool($)).context).toEqual([bandText(w, 'near')])
  w.tokens = 690000
  expect((await w.tool($)).context).toBeUndefined()
  w.tokens = 704000
  const spent = await w.tool($)
  expect([spent.deny, spent.context]).toEqual([undefined, [bandText(w, 'spent')]])
  expect((await w.tool($)).context).toEqual([bandText(w, 'spent')])
  w.tokens = 962000
  expect((await w.tool($)).context).toEqual([bandText(w, 'imminent')])
  expect(w.rowsOf('nudge').length).toBe(1)
  expect(w.rowsOf('handoff_limit').map(r => r.band)).toEqual(['near', 'spent', 'imminent'])
})

test('AT-LT-07: 35 calls with tokens low (c = 34): [near] at call 27, [spent] on call 35, nothing denied', async ($, on) => {
  const w = new World().install(on, CAPPED)
  await w.start($)
  await lastCycleTurn($, w)
  if (!TURN) return
  await w.advance(2000)
  await handoffTurnStarts($, w)
  const got: (string | undefined)[] = []
  for (let i = 1; i <= 35; i++) {
    const r = await w.tool($)
    expect(r.deny).toBeUndefined()
    got.push(r.context?.[0])
  }
  expect(got[26]).toBe(bandText(w, 'near'))
  expect(got.slice(27, 34).every(t => t === undefined)).toBe(true)
  expect(got.slice(0, 26).every(t => t === undefined)).toBe(true)
  expect(got[34]).toBe(bandText(w, 'spent'))
})

test('AT-LT-08: a user prompt delivered into the handoff turn lifts the limits text; halt clears at that turn end', async ($, on) => {
  const w = new World().install(on, CAPPED)
  await w.start($)
  await lastCycleTurn($, w)
  if (!TURN) return
  await w.advance(2000)
  await handoffTurnStarts($, w)
  const ht = w.lastHt()
  await $.prompt.submit({ text: 'I will take it from here', origin: { kind: 'composer' }, turnId: 't2', wait: false } as never)
  expect(w.rowsOf('handoff_user_interjected').map(r => r.ht)).toEqual([ht])
  w.tokens = 704000
  expect((await w.tool($)).context).toBeUndefined()
  await w.turnEnd($)
  expect(w.rowsOf('halt').filter(r => r.active === false).length).toBe(1)
  expect(w.rowsOf('handoff_turn_end')[0]?.interjected).toBe(true)
})

const VARIANTS: { name: string; options: Record<string, number>; store: Record<string, unknown> }[] = [
  { name: 'cap', options: {}, store: CAPPED },
  { name: 'continue-off', options: { max_auto_continues_per_hour: 0 }, store: {} },
]
for (const opt of VARIANTS) {
  test(`AT-LT-09 (${opt.name}): published: one compaction despite halt and cooldown, [handoff] with the path, handoff_ht, no submit, one toast`, { options: opt.options }, async ($, on) => {
    const w = new World().install(on, opt.store)
    await w.start($)
    await lastCycleTurn($, w)
    if (!TURN) {
      await w.advance(500)
      expect([w.compacts.length, w.submits.length]).toEqual([1, 0])
      return
    }
    await w.advance(2000)
    await handoffTurnStarts($, w)
    const ht = w.lastHt() ?? ''
    w.publish(ht, PUBLISHED)
    w.tokens = 690000
    await w.turnEnd($, 'Handoff written.')
    await w.advance(499)
    expect(w.compacts.length).toBe(0)
    await w.advance(1)
    expect(w.compacts.length).toBe(1)
    const d = w.callsOf('dispatch')[0]
    const nonce = w.flag(d, '--nonce') ?? ''
    expect([w.flag(d, '--handoff-ht'), w.flag(d, '--channel')]).toEqual([ht, 'mod-self'])
    expect(w.flag(d, '--tags')?.split(',')).toContain('handoff')
    const text = assemble(w.name, 'handoff-instructions', ['handoff'], { nonce, handoff_path: SHOWN, measured_at: '' })
    if (text.includes(SHOWN)) expect(w.compacts[0]?.instructions).toContain(SHOWN)
    expect(w.submits.length).toBe(1)
    expect(w.rowsOf('handoff_turn_end').map(r => [r.handoff_turn, r.handoff_ht, r.compaction])).toEqual([['published', ht, true]])
    expect(w.toasts.filter(t => t.includes('handoff saved: ' + SHOWN)).length).toBe(1)
    const ctx = await $.prompt.context({ blocks: [] })
    const block = ctx.blocks.find(b => b.name === `${w.name}-resume`)?.text ?? ''
    const resumeLine = assemble(w.name, 'resume-context', ['handoff'], { handoff_path: SHOWN, session_id: SID_A, saved_copy: 'x', measured_at: 'x', remeasure: 'x' })
    if (resumeLine.includes(SHOWN)) expect(block).toContain(SHOWN)
    expect(w.rowsOf('mod_outcome').find(r => r.nonce === nonce)?.handoff_turn).toBe('published')
    await w.advance(60000)
    expect(w.submits.length).toBe(1)
  })
}

test('AT-LT-10: handoff turn ends answer, state staged (LINT stop), reason cap: full-text compaction, handoff_turn failed:lint', async ($, on) => {
  const w = new World().install(on, CAPPED)
  await w.start($)
  await lastCycleTurn($, w)
  if (!TURN) return
  await w.advance(2000)
  await handoffTurnStarts($, w)
  w.htStates.set('*', `staged ${STAGE} draft=1 finish=${FINISH}`)
  await w.turnEnd($, 'LINT stop: 2 lines to fix.')
  await w.advance(500)
  expect(w.compacts.length).toBe(1)
  expect(w.flag(w.callsOf('dispatch')[0], '--tags')?.split(',')).not.toContain('handoff')
  expect(w.flag(w.callsOf('dispatch')[0], '--handoff-ht')).toBe(w.lastHt())
  expect(w.rowsOf('handoff_turn_end').map(r => r.handoff_turn)).toEqual(['failed:lint'])
})

test('AT-LT-11: native auto during the handoff turn, draft present: [midturn] full text, handoff_race, [handoff-partial], superseded, no second compaction', async ($, on) => {
  const w = new World().install(on, CAPPED)
  await w.start($)
  await lastCycleTurn($, w)
  if (!TURN) return
  await w.advance(2000)
  await handoffTurnStarts($, w)
  const ht = w.lastHt() ?? ''
  w.htStates.set(ht, `staged ${STAGE} draft=1 finish=${FINISH}`)
  w.tokens = 700000
  await raiseCompact($, { trigger: 'auto' })
  const d = w.callsOf('dispatch')[0]
  const nonce = w.flag(d, '--nonce') ?? ''
  expect([w.flag(d, '--channel'), w.flag(d, '--midturn'), w.flag(d, '--handoff-ht')]).toEqual(['mod-hook', 'true', ht])
  expect(w.flag(d, '--tags')?.split(',')).not.toContain('handoff')
  expect(w.rowsOf('handoff_race').map(r => [r.trigger, r.draft, r.published, r.ht])).toEqual([['auto', true, false, ht]])
  expect(w.files.get(`${WATCH}/${SID_A}/handoff-turn/${ht}.superseded`)).toBe(nonce + '\n')
  const ctx = await $.prompt.context({ blocks: [] })
  const block = ctx.blocks.find(b => b.name === `${w.name}-resume`)?.text ?? ''
  const partial = assemble(w.name, 'resume-context', ['handoff-partial'], { draft_state: 'present', handoff_finish: '`' + FINISH + '`', session_id: SID_A, saved_copy: 'x', measured_at: 'x', remeasure: 'x' })
  if (partial.includes(FINISH)) expect(block).toContain('`' + FINISH + '`')
  // Post-race: [spent] from the next call on (context only).
  w.tokens = 60000
  expect((await w.tool($)).context).toEqual([bandText(w, 'spent')])
  await w.turnEnd($, 'Published after the compaction.')
  await w.advance(60000)
  expect(w.compacts.length).toBe(1)
  expect(w.rowsOf('handoff_turn_end').map(r => r.handoff_turn)).toEqual(['race'])
})

test('AT-LT-12, AT-LT-13: a second last cycle gets a new ht (first file unchanged); a third within 60 min: why=cap', { options: { max_auto_continues_per_hour: 0 } }, async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  const hts: string[] = []
  for (let i = 0; i < 2; i++) {
    await lastCycleTurn($, w)
    if (!TURN) return
    await w.advance(2000)
    await handoffTurnStarts($, w)
    const ht = w.lastHt() ?? ''
    hts.push(ht)
    w.publish(ht, PUBLISHED)
    await w.turnEnd($, 'Handoff written.')
    await w.advance(500)
    await w.advance(5 * 60000)
  }
  expect(hts[0]).not.toBe(hts[1])
  const first = w.files.get(`${WATCH}/${SID_A}/handoff-turn/${hts[0]}.json`)
  expect(first).toBeDefined()
  await lastCycleTurn($, w)
  await w.advance(5000)
  expect(w.rowsOf('handoff_skipped').map(r => r.why)).toEqual(['cap'])
  expect(w.files.get(`${WATCH}/${SID_A}/handoff-turn/${hts[0]}.json`)).toBe(first)
  expect(w.callsOf('handoff-turn').filter(c => c.args[0] === 'open').length).toBe(2)
})

test('AT-LT-14: a precompute during the handoff turn: [midturn], no [handoff], handoff_ht set, no checkpoint or sweep', async ($, on) => {
  const w = new World().install(on, CAPPED)
  await w.start($)
  await lastCycleTurn($, w)
  if (!TURN) return
  await w.advance(2000)
  await handoffTurnStarts($, w)
  const before = [w.callsOf('checkpoint').length, w.callsOf('sweep').length]
  await raiseCompact($, { trigger: 'precompute' })
  const d = w.callsOf('dispatch').slice(-1)[0]
  expect([w.flag(d, '--midturn'), w.flag(d, '--handoff-ht')]).toEqual(['true', w.lastHt()])
  expect(w.flag(d, '--tags')?.split(',')).not.toContain('handoff')
  expect([w.callsOf('checkpoint').length, w.callsOf('sweep').length]).toEqual(before)
  expect(w.rowsOf('handoff_race').length).toBe(0)
})

for (const reason of ['2-nonok'] as const) {
  test(`AT-LT-17 (${reason}): published, then no plugin compaction; the toast names the reason; halt stays (DP-4)`, async ($, on) => {
    const w = new World().install(on)
    await w.start($)
    await haltTwoNonOk($, w)
    w.tokens = 610000
    await w.tool($)
    w.tokens = 640000
    await w.turnEnd($)
    if (!TURN) {
      expect(w.rowsOf('skip').map(r => r.why)).toEqual(['halt'])
      await w.advance(5000)
      expect(w.compacts.length).toBe(0)
      return
    }
    await w.advance(2000)
    expect(w.submits).toEqual([submitText(w, reason)])
    await handoffTurnStarts($, w)
    const ht = w.lastHt() ?? ''
    w.publish(ht, PUBLISHED)
    await w.turnEnd($, 'Handoff written.')
    await w.advance(60000)
    expect(w.compacts.length).toBe(0)
    expect(w.toasts.filter(t => t.includes(SHOWN) && t.includes(HALT_REASON_TEXT[reason])).length).toBe(1)
    expect(w.rowsOf('halt').filter(r => r.active === false).length).toBe(0)
    expect(w.rowsOf('handoff_turn_end').map(r => [r.handoff_turn, r.compaction])).toEqual([['published', false]])
    // §3.1: a native idle auto right after it gets [handoff] and the ht.
    await raiseCompact($, { trigger: 'auto' })
    const d = w.callsOf('dispatch').slice(-1)[0]
    expect(w.flag(d, '--handoff-ht')).toBe(ht)
    expect(w.flag(d, '--tags')?.split(',')).toContain('handoff')
  })
}

test('the handoff turn is never started for a subagent turn, nor on the 400K turn-end path (OD-4)', async ($, on) => {
  const w = new World().install(on, CAPPED)
  await w.start($)
  await w.turnStart($)
  w.tokens = 450000
  await w.turnEnd($)
  await w.advance(5000)
  expect(w.compacts.length).toBe(1)
  expect(w.callsOf('handoff-turn').length).toBe(0)
  expect(w.rowsOf('handoff_skipped').length).toBe(0)
})
