// U tests through the kit: the handoff turn of a last cycle (MOD-SPEC §9.1, §9.2; D-18 with
// DP-4, DP-5, DP-13). Shipped prose is never matched literally: every expected text is the
// assembled tag contract (assemble with the tag and runtime the mod must use), so the tests hold
// for any wording of the assets. Until `handoff-turn.txt` ships in this build, the turn cannot be
// submitted: those tests check the safe degrade instead (`handoff_skipped why=no-asset`, and the
// normal compaction for `cap`/`continue-off`), and the integrator re-runs them after the text merge.
import { expect, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import { assemble, assembleIf, hasAsset, hasTag, leftovers } from '../../hooks/lib/assemble'
import { assetText } from '../../hooks/lib/assets.gen'
import { DEFAULTS } from '../../hooks/lib/config'
import { continueLine, lastCycleOf } from '../../hooks/lib/cont'
import type { Deps } from '../../hooks/lib/deps'
import { claimTurn, isOurText, isOwnOrigin, newState, promptEntering, promptNotEntered, refuseOwnSubmit, storeWord, submitPending } from '../../hooks/lib/deps'
import { HALT_REASON_TEXT, maxCalls, submitText as kindText } from '../../hooks/lib/handoff-turn'
import { BRAND } from './_gen/brand.gen'
import { HOME, SID_A, T0, WATCH, World, markerNonce, raiseCompact } from './harness.test'

const TURN = hasAsset('handoff-turn')
const C = maxCalls() ?? 0
const STAGE = HOME + '/.claude/handoffs/r/LAB-42/.stage/2026-10-21_14-05-12_ab12'
const FINISH = `<store> publish --stage '${STAGE}' --slug lab-42 --status in-progress`
const PUBLISHED = HOME + '/.claude/handoffs/r/LAB-42/2026-10-21_14-07-00_5e55a001_handoff.md'
const SHOWN = '~/.claude/handoffs/r/LAB-42/2026-10-21_14-07-00_5e55a001_handoff.md'
/** Three continues in the last hour: the next nudged cycle is capped (max 3). */
const CAPPED = { ['cont:' + SID_A]: [T0 - 50 * 60000, T0 - 30 * 60000, T0 - 10 * 60000] }
/** These tests test cap semantics, not the default (6): they pin the cap at 3 (S-SETTINGS A). */
const CAP3 = { max_auto_continues_per_hour: 3 }
/** Owner 2026-10-30 07:49: the `[handoff-ack]` line's start for SHOWN (a report not sent). */
const ACK = 'Its report was not sent: that report is only `✓ Handoff saved: ' + SHOWN + '`'

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
  return assembleIf(w.name, 'handoff-turn', ['submit', 'submit-halt'], { halt_reason: HALT_REASON_TEXT[reason], max_calls: String(C), store: storeWord(w.root, w.name) ?? '' })
}

function bandText(w: World, band: 'near' | 'spent' | 'imminent'): string | undefined {
  return assembleIf(w.name, 'handoff-turn', [band], { store: storeWord(w.root, w.name) ?? '' })
}

test('c = 1 + call_cap + recipe_cap from the shared spec = 34 (RV-25, DP-6)', () => {
  expect(C).toBe(34)
})

test('DP-24 (g), P-LT-1, AT-LT-18: no text the plugin submits starts with "/" (the host refuses it as a user command): continue, and every handoff-turn kind', () => {
  const texts = [continueLine(BRAND.name)]
  for (const name of [BRAND.name, 'x', 'x'.repeat(16)]) {
    for (const reason of Object.keys(HALT_REASON_TEXT) as (keyof typeof HALT_REASON_TEXT)[]) {
      const t = kindText(name, 'halt', { halt_reason: HALT_REASON_TEXT[reason], max_calls: String(C), store: '"/p/scripts/' + name + '-store"' })
      expect(t === undefined).toBe(!TURN)
      if (t !== undefined) texts.push(t)
    }
    for (const kind of ['precompact', 'idle'] as const) {
      const t = kindText(name, kind, { max_calls: String(C), idle_min: '49', store: '"/p/scripts/' + name + '-store"' })
      // A build whose handoff-turn text has no lines of this kind yet gives no text (never the last-cycle one).
      expect(t === undefined).toBe(!hasTag('handoff-turn', kind === 'idle' ? 'submit-idle' : 'submit-pre'))
      if (t !== undefined) texts.push(t)
    }
  }
  for (const t of texts) expect(t.trimStart().startsWith('/')).toBe(false)
  for (const t of texts.slice(1)) expect(leftovers(t)).toEqual([])
})

test('AT-IC-12: the [submit-idle] text, when this build has it: never starts with "/", says to launch no agents or workflows, carries the shared [submit] line', () => {
  if (!hasTag('handoff-turn', 'submit-idle')) return
  const shared = assembleIf('x', 'handoff-turn', ['submit'], { max_calls: String(C), halt_reason: 'r', store: '"/p/scripts/x-' + 'store"' }) ?? ''
  for (let n = 1; n <= 16; n++) {
    const name = 'x'.repeat(n)
    const t = kindText(name, 'idle', { max_calls: String(C), idle_min: '49', store: '"/p/scripts/' + name + '-store"' }) ?? ''
    expect(t.trimStart().startsWith('/')).toBe(false)
    expect(t.toLowerCase()).toContain('launch no agents or workflows')
    expect(leftovers(t)).toEqual([])
  }
  expect(shared.length).toBeGreaterThan(0)
})

test('AT-LT-01: nudge at 610K: [halt] with @halt_reason@ for (a) halt, (b) cap reached, (c) max 0; [continue] for (d)', { options: CAP3 }, async ($, on) => {
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

test('handoff_turn off: [halt] without the handoff-turn sentence; the normal compaction, no continue', { options: { ...CAP3, handoff_turn: 'off' } }, async ($, on) => {
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

test('AT-LT-02: last-cycle turn ends answer at 640K, window 800000: one framed submit after the delay, no compaction before it', { options: CAP3 }, async ($, on) => {
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

test('AT-LT-03: a user turn.start during the delay cancels the submit: handoff_skipped why=user-turn', { options: CAP3 }, async ($, on) => {
  const w = new World().install(on, CAPPED)
  await w.start($)
  await lastCycleTurn($, w)
  if (!TURN) return
  await w.advance(1000)
  await w.userTurn($, 'actually, stop here')
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

test('AT-LT-06: bands are context text only: one [near], [spent] from t0+H, [imminent] at N-5K; nothing denied; no nudge', { options: CAP3 }, async ($, on) => {
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

test('AT-LT-07: 35 calls with tokens low (c = 34): [near] at call 27, [spent] on call 35, nothing denied', { options: CAP3 }, async ($, on) => {
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

test('AT-LT-08: a user prompt delivered into the handoff turn lifts the limits text; halt clears at that turn end', { options: CAP3 }, async ($, on) => {
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

const VARIANTS: { name: string; options: Record<string, number | string>; store: Record<string, unknown> }[] = [
  { name: 'cap', options: { ...CAP3, precompact_turn: 'code' }, store: CAPPED },
  { name: 'continue-off', options: { max_auto_continues_per_hour: 0, precompact_turn: 'code' }, store: {} },
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
    // Owner 2026-10-30 07:49: the answer carried neither the receipt nor the path, so the report
    // counts as not sent and the block asks for the one-line ack.
    if (hasTag('resume-context', 'handoff-ack')) expect(block).toContain(ACK)
    // Owner 2026-10-30 07:52: the plugin's own compaction gets its line too (boundary.ts settleSelf).
    expect(w.compactLines.length).toBe(1)
    expect(w.compactLines[0]?.startsWith(`${w.name}: compaction ok · copy saved · handoff ${SHOWN.replace(/^.*\//, '')}`)).toBe(true)
    expect(w.rowsOf('mod_outcome').find(r => r.nonce === nonce)?.handoff_turn).toBe('published')
    await w.advance(60000)
    expect(w.submits.length).toBe(1)
  })
}

test('AT-LT-10: handoff turn ends answer, state staged (LINT stop), reason cap: full-text compaction, handoff_turn failed:lint', { options: CAP3 }, async ($, on) => {
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

test('AT-LT-11: native auto during the handoff turn, draft present: [midturn] full text, handoff_race, [handoff-partial], superseded, no second compaction', { options: CAP3 }, async ($, on) => {
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

// Owner 2026-10-30 07:49 (review of the first build): the report the turn's answer carried is
// sent, so the block after the plugin compaction has [handoff] without the ack.
test('handoff turn whose answer carries the receipt: [handoff] with the path, no [handoff-ack]', { options: { ...CAP3, precompact_turn: 'code' } }, async ($, on) => {
  const w = new World().install(on, CAPPED)
  await w.start($)
  await lastCycleTurn($, w)
  if (!TURN) return
  await w.advance(2000)
  await handoffTurnStarts($, w)
  w.publish(w.lastHt() ?? '', PUBLISHED)
  w.tokens = 690000
  await w.turnEnd($, 'Wrote handoff to: ' + PUBLISHED + '\nResume with: /afk-compact:resume ' + PUBLISHED)
  await w.advance(500)
  expect(w.compacts.length).toBe(1)
  const block = (await $.prompt.context({ blocks: [] })).blocks.find(b => b.name === `${w.name}-resume`)?.text ?? ''
  expect(block).toContain('A handoff was saved just before this compaction: ' + SHOWN + '.')
  expect(block).not.toContain('Handoff saved')
})

// A native auto compaction that cuts the handoff turn off after its publish: the report was
// certainly not sent, so the block has [handoff] and the ack.
test('native auto during the handoff turn after its publish: [handoff] and [handoff-ack] with the path', { options: CAP3 }, async ($, on) => {
  const w = new World().install(on, CAPPED)
  await w.start($)
  await lastCycleTurn($, w)
  if (!TURN) return
  await w.advance(2000)
  await handoffTurnStarts($, w)
  const ht = w.lastHt() ?? ''
  w.publish(ht, PUBLISHED)
  w.tokens = 700000
  await raiseCompact($, { trigger: 'auto' })
  expect(w.rowsOf('handoff_race').map(r => [r.published, r.ht])).toEqual([[true, ht]])
  const block = (await $.prompt.context({ blocks: [] })).blocks.find(b => b.name === `${w.name}-resume`)?.text ?? ''
  expect(block).toContain('A handoff was saved just before this compaction: ' + SHOWN + '.')
  if (hasTag('resume-context', 'handoff-ack')) expect(block).toContain(ACK)
  expect(w.compactLines.length).toBe(1)
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

test('AT-LT-14: a precompute during the handoff turn: [midturn], no [handoff], handoff_ht set, no checkpoint or sweep', { options: CAP3 }, async ($, on) => {
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

test('the handoff turn is never started for a subagent turn, nor on the 400K turn-end path with precompact_turn code (OD-4)', { options: { ...CAP3, precompact_turn: 'code' } }, async ($, on) => {
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

/**
 * Two plugin compactions at 410K turn ends, the first re-reaching target the next turn: the
 * next turn end that is at target again finds thrash (AT-B-07's rule).
 */
async function refillTwice($: Engine, w: World): Promise<void> {
  w.tokens = 410000
  for (let i = 0; i < 2; i++) {
    await w.turnStart($)
    await w.turnEnd($)
    await w.advance(2000)
    await w.advance(60000)
  }
  expect(w.compacts.length).toBe(2)
  expect(w.rowsOf('halt').length).toBe(0)
}

const THRASH_VARIANTS: { name: 'cap' | 'continue-off'; options: Record<string, number | string>; store: Record<string, unknown> }[] = [
  { name: 'cap', options: { ...CAP3, precompact_turn: 'code' }, store: CAPPED },
  { name: 'continue-off', options: { max_auto_continues_per_hour: 0, precompact_turn: 'code' }, store: {} },
]
for (const opt of THRASH_VARIANTS) {
  test(`CR-F18, CR-F24, AT-LT-17 (thrash): thrash found at the end of a ${opt.name} nudged turn wins: handoff turn for thrash, then no plugin compaction (DP-4)`, { options: opt.options }, async ($, on) => {
    const w = new World().install(on, opt.store)
    await w.start($)
    await refillTwice($, w)
    await lastCycleTurn($, w)
    expect(w.rowsOf('nudge').slice(-1)[0]?.last_cycle).toBe(opt.name)
    expect(w.rowsOf('halt').map(r => [r.reason, r.active])).toEqual([['thrash', true]])
    expect(w.rowsOf('continue').map(r => r.result)).toEqual(['halt:thrash'])
    expect(w.rowsOf('continue_capped').length).toBe(0)
    if (!TURN) {
      expect(w.rowsOf('skip').map(r => r.why)).toEqual(['halt'])
      await w.advance(5000)
      expect(w.compacts.length).toBe(2)
      return
    }
    await w.advance(2000)
    expect(w.submits).toEqual([submitText(w, 'thrash')])
    expect(w.flag(w.callsOf('handoff-turn')[0], '--reason')).toBe('thrash')
    await handoffTurnStarts($, w)
    const ht = w.lastHt() ?? ''
    w.publish(ht, PUBLISHED)
    await w.turnEnd($, 'Handoff written.')
    await w.advance(60000)
    expect(w.compacts.length).toBe(2)
    expect(w.rowsOf('handoff_turn_end').map(r => [r.handoff_turn, r.compaction])).toEqual([['published', false]])
    expect(w.toasts.filter(t => t.includes(SHOWN) && t.includes(HALT_REASON_TEXT.thrash)).length).toBe(1)
    expect(w.rowsOf('halt').filter(r => r.active === false).length).toBe(0)
  })
}

test('CR-F18, CR-F24: handoff_turn off: thrash found at a capped nudged turn\'s end: skip why=halt, no plugin compaction (DP-4, DP-22)', { options: { precompact_turn: 'code', ...CAP3, handoff_turn: 'off' } }, async ($, on) => {
  const w = new World().install(on, CAPPED)
  await w.start($)
  await refillTwice($, w)
  await lastCycleTurn($, w)
  expect(w.rowsOf('halt').map(r => r.reason)).toEqual(['thrash'])
  expect(w.rowsOf('skip').map(r => r.why)).toEqual(['halt'])
  await w.advance(5000)
  expect(w.compacts.length).toBe(2)
  expect(w.submits.length).toBe(0)
})

test('CR-F26, AT-LT-05 (2-nonok): H < 20K: why=headroom, then no plugin compaction (DP-4, E-M-3)', async ($, on) => {
  const w = new World({ window: 800000 }).install(on)
  await w.start($)
  await haltTwoNonOk($, w)
  w.tokens = 610000
  await w.tool($)
  w.tokens = 745000
  await w.turnEnd($, 'Checkpoint: clean · Step 1: x')
  await w.advance(5000)
  expect(w.rowsOf('handoff_skipped').map(r => r.why)).toEqual([TURN ? 'headroom' : 'no-asset'])
  expect(w.rowsOf('skip').map(r => r.why)).toEqual(['halt'])
  expect(w.compacts.length).toBe(0)
  expect(w.submits.length).toBe(0)
})

test('CR-F26, AT-LT-05 (thrash): thrash at a continue-off nudged turn\'s end, H < 20K: why=headroom, then no plugin compaction', { options: { precompact_turn: 'code', max_auto_continues_per_hour: 0 } }, async ($, on) => {
  const w = new World({ window: 800000 }).install(on)
  await w.start($)
  await refillTwice($, w)
  await lastCycleTurn($, w, 'Checkpoint: clean · Step 1: x', 745000)
  await w.advance(5000)
  expect(w.rowsOf('halt').map(r => r.reason)).toEqual(['thrash'])
  expect(w.rowsOf('handoff_skipped').map(r => r.why)).toEqual([TURN ? 'headroom' : 'no-asset'])
  expect(w.rowsOf('skip').map(r => r.why)).toEqual(['halt'])
  expect(w.compacts.length).toBe(2)
  expect(w.submits.length).toBe(0)
})

test('CR-F17, CR-F25: a user turn.start while `handoff-turn open` runs: no submit, why=user-turn, that turn is not the handoff turn', { options: CAP3 }, async ($, on) => {
  const w = new World().install(on, CAPPED)
  await w.start($)
  await lastCycleTurn($, w)
  if (!TURN) return
  let raced = false
  w.atHelper = async (sub, args) => {
    if (raced || sub !== 'handoff-turn' || args[0] !== 'open') return
    raced = true
    await w.userTurn($, 'actually, stop here')
  }
  await w.advance(2000)
  expect(raced).toBe(true)
  await w.advance(10000)
  expect(w.submits.length).toBe(0)
  expect(w.rowsOf('handoff_skipped').map(r => r.why)).toEqual(['user-turn'])
  expect(w.rowsOf('handoff_turn_start').length).toBe(0)
  // The ht that open created meanwhile is closed, so `begin` cannot bind it (BL-2).
  const ht = w.lastHt() ?? ''
  expect(w.callsOf('handoff-turn').map(c => [c.args[0], w.flag(c, '--ht'), w.flag(c, '--why') ?? null])).toEqual([['open', ht, null], ['close', ht, 'cancelled']])
  expect(w.files.has(`${WATCH}/${SID_A}/handoff-turn/${ht}.closed`)).toBe(true)
  expect(w.rowsOf('halt').filter(r => r.active === false).length).toBe(1)
  // The user's turn gets no limits text, and its end follows the normal rules.
  w.tokens = 704000
  expect((await w.tool($)).context?.[0]).not.toBe(bandText(w, 'spent'))
  await w.turnEnd($)
  expect(w.rowsOf('handoff_turn_end').length).toBe(0)
})

test('CR-F20: a handoff-turn submit answered { drop }: why=submit-failed with the ht; the cap cycle compacts; the next user turn is not the handoff turn', { options: CAP3 }, async ($, on) => {
  const w = new World().install(on, CAPPED)
  await w.start($)
  await lastCycleTurn($, w)
  if (!TURN) return
  w.submitDrop = 'a Stop stands'
  await w.advance(2000)
  const ht = w.lastHt() ?? ''
  expect(w.rowsOf('handoff_skipped').map(r => [r.why, r.ht])).toEqual([['submit-failed', ht]])
  expect(w.callsOf('handoff-turn').map(c => c.args[0])).toEqual(['open', 'close'])
  expect(w.compacts.length).toBe(1)
  w.submitDrop = undefined
  await w.userTurn($, 'what happened?')
  expect(w.rowsOf('handoff_turn_start').length).toBe(0)
  expect(w.rowsOf('halt').filter(r => r.active === false).length).toBe(1)
})

test('CR-F21: a prompt queued with wait=true during the handoff turn is no interjection: the limits text stays', { options: CAP3 }, async ($, on) => {
  const w = new World().install(on, CAPPED)
  await w.start($)
  await lastCycleTurn($, w)
  if (!TURN) return
  await w.advance(2000)
  await handoffTurnStarts($, w)
  await $.prompt.submit({ text: 'after this, run the tests', origin: { kind: 'composer' }, turnId: 't2', wait: true } as never)
  expect(w.rowsOf('handoff_user_interjected').length).toBe(0)
  w.tokens = 704000
  expect((await w.tool($)).context).toEqual([bandText(w, 'spent')])
})

test('CR-F19: a native compaction inside the 500 ms after the handoff turn ends: no second compaction, skip why=compacted', { options: CAP3 }, async ($, on) => {
  const w = new World().install(on, CAPPED)
  await w.start($)
  await lastCycleTurn($, w)
  if (!TURN) return
  await w.advance(2000)
  await handoffTurnStarts($, w)
  const ht = w.lastHt() ?? ''
  w.publish(ht, PUBLISHED)
  await w.turnEnd($, 'Handoff written.')
  await raiseCompact($, { trigger: 'auto' })
  expect(w.compacts.length).toBe(1)
  await w.advance(500)
  await w.advance(60000)
  expect(w.compacts.length).toBe(1)
  expect(w.rowsOf('skip').map(r => [r.why, r.ht])).toEqual([['compacted', ht]])
})

test('CR-F19: a native compaction still running when the post-handoff timer fires: no second compaction; it decides at the native end', { options: CAP3 }, async ($, on) => {
  const w = new World().install(on, CAPPED)
  await w.start($)
  await lastCycleTurn($, w)
  if (!TURN) return
  await w.advance(2000)
  await handoffTurnStarts($, w)
  const ht = w.lastHt() ?? ''
  w.publish(ht, PUBLISHED)
  await w.turnEnd($, 'Handoff written.')
  let release!: () => void
  w.compactGate = new Promise<void>(r => { release = r })
  const p = raiseCompact($, { trigger: 'auto' })
  await w.advance(500)
  await w.advance(1000)
  expect(w.compacts.map(c => c.trigger)).toEqual(['auto'])
  w.compactGate = undefined
  release()
  await p
  await w.advance(60000)
  expect(w.compacts.map(c => c.trigger)).toEqual(['auto'])
  expect(w.rowsOf('skip').map(r => [r.why, r.ht])).toEqual([['compacted', ht]])
})

test('CR-F19: that native compaction ends skipped: the post-handoff compaction runs after it, once', { options: CAP3 }, async ($, on) => {
  const w = new World().install(on, CAPPED)
  await w.start($)
  await lastCycleTurn($, w)
  if (!TURN) return
  await w.advance(2000)
  await handoffTurnStarts($, w)
  const ht = w.lastHt() ?? ''
  w.publish(ht, PUBLISHED)
  await w.turnEnd($, 'Handoff written.')
  let release!: () => void
  w.compactGate = new Promise<void>(r => { release = r })
  w.compactMode = { skip: 'nothing to compact' }
  const p = raiseCompact($, { trigger: 'auto' })
  await w.advance(500)
  await w.advance(1000)
  expect(w.compacts.length).toBe(1)
  w.compactGate = undefined
  release()
  await p
  w.compactMode = 'ok'
  await w.advance(60000)
  expect(w.compacts.map(c => c.trigger)).toEqual(['auto', undefined])
  expect(w.rowsOf('compacted').filter(r => r.handoff_ht === ht && r.skip === null).length).toBe(1)
  expect(w.rowsOf('skip').length).toBe(0)
})

test('CR-F19: a native compaction that starts while the post-handoff checkpoint runs: no dispatch, no second compaction', { options: CAP3 }, async ($, on) => {
  const w = new World().install(on, CAPPED)
  await w.start($)
  await lastCycleTurn($, w)
  if (!TURN) return
  await w.advance(2000)
  await handoffTurnStarts($, w)
  const ht = w.lastHt() ?? ''
  w.publish(ht, PUBLISHED)
  await w.turnEnd($, 'Handoff written.')
  let release!: () => void
  let p: Promise<unknown> | undefined
  w.atHelper = async sub => {
    if (sub !== 'checkpoint' || p !== undefined) return
    w.compactGate = new Promise<void>(r => { release = r })
    p = raiseCompact($, { trigger: 'auto' })
  }
  await w.advance(500)
  await w.advance(1000)
  expect(p).toBeDefined()
  expect(w.compacts.map(c => c.trigger)).toEqual(['auto'])
  w.atHelper = undefined
  w.compactGate = undefined
  release()
  await p
  await w.advance(60000)
  expect(w.compacts.map(c => c.trigger)).toEqual(['auto'])
  expect(w.callsOf('dispatch').filter(c => w.flag(c, '--channel') === 'mod-self').length).toBe(0)
  expect(w.rowsOf('skip').map(r => [r.why, r.ht])).toEqual([['compacted', ht]])
})

test('CR-F17, CR-F25: a user prompt that entered but has not started its turn at the last check: our prompt is never submitted; its turn cancels the handoff turn', { options: CAP3 }, async ($, on) => {
  const w = new World().install(on, CAPPED)
  await w.start($)
  await lastCycleTurn($, w)
  if (!TURN) return
  const USER = 'the user typed this'
  let held: Promise<unknown> | undefined
  let reached!: () => void
  const atBottom = new Promise<void>(r => { reached = r })
  let open!: () => void
  const gate = new Promise<void>(r => { open = r })
  w.atSubmit = async text => {
    if (text !== USER) return
    reached()
    await gate
  }
  // The user presses Enter while `handoff-turn open` runs: prompt.submit counts it; its turn starts later.
  w.atHelper = async (sub, args) => {
    if (held !== undefined || sub !== 'handoff-turn' || args[0] !== 'open') return
    held = $.prompt.submit({ text: USER, origin: { kind: 'composer' } } as never)
    await atBottom
  }
  await w.advance(2000)
  expect(held).toBeDefined()
  expect(w.submits).toEqual([USER])
  const ht = w.lastHt() ?? ''
  expect(w.callsOf('handoff-turn').map(c => [c.args[0], w.flag(c, '--ht'), w.flag(c, '--why') ?? null])).toEqual([['open', ht, null], ['close', ht, 'cancelled']])
  open()
  await held
  await w.turnStart($, USER)
  expect(w.rowsOf('handoff_skipped').map(r => [r.why, r.ht])).toEqual([['user-turn', ht]])
  expect(w.rowsOf('handoff_turn_start').length).toBe(0)
  expect(w.rowsOf('halt').filter(r => r.active === false).length).toBe(1)
  w.tokens = 100000
  await w.turnEnd($, 'Here you go.')
  await w.advance(60000)
  expect(w.submits).toEqual([USER])
  expect(w.rowsOf('handoff_turn_end').length).toBe(0)
  expect(w.compacts.length).toBe(0)
})

test('CR-F17: a user prompt that entered at the last check but is dropped on its way in: the delay runs again and the handoff turn follows', { options: CAP3 }, async ($, on) => {
  const w = new World().install(on, CAPPED)
  await w.start($)
  await lastCycleTurn($, w)
  if (!TURN) return
  const ours = submitText(w, 'cap') ?? ''
  const USER = 'the user typed this'
  let held: Promise<unknown> | undefined
  let reached!: () => void
  const atBottom = new Promise<void>(r => { reached = r })
  let open!: () => void
  const gate = new Promise<void>(r => { open = r })
  w.atSubmit = async text => {
    if (text !== USER) return
    reached()
    await gate
  }
  w.dropIf = text => (text === USER ? 'refused by a guard' : undefined)
  w.atHelper = async (sub, args) => {
    if (held !== undefined || sub !== 'handoff-turn' || args[0] !== 'open') return
    held = $.prompt.submit({ text: USER, origin: { kind: 'composer' } } as never)
    await atBottom
  }
  await w.advance(2000)
  const first = w.lastHt() ?? ''
  expect(w.submits).toEqual([USER])
  open()
  await held
  await w.settle()
  await w.advance(2000)
  expect(w.submits).toEqual([USER, ours])
  const ht = w.lastHt() ?? ''
  expect(ht).not.toBe(first)
  await handoffTurnStarts($, w)
  expect(w.rowsOf('handoff_turn_start').map(r => r.ht)).toEqual([ht])
  expect(w.rowsOf('handoff_skipped').length).toBe(0)
  expect(w.rowsOf('halt').filter(r => r.active === false).length).toBe(0)
})

test('CR-F17, CR-F25: our handoff-turn submit refused because a user prompt entered as it went in: it never runs, no submit-failed, no compaction; the user turn cancels the handoff turn', { options: CAP3 }, async ($, on) => {
  const w = new World().install(on, CAPPED)
  await w.start($)
  await lastCycleTurn($, w)
  if (!TURN) return
  const ours = submitText(w, 'cap') ?? ''
  const USER = 'the user typed this'
  let held: Promise<unknown> | undefined
  let reached!: () => void
  const atBottom = new Promise<void>(r => { reached = r })
  let open!: () => void
  const gate = new Promise<void>(r => { open = r })
  w.atSubmit = async text => {
    if (text === USER) {
      reached()
      await gate
      return
    }
    if (text !== ours || held !== undefined) return
    held = $.prompt.submit({ text: USER, origin: { kind: 'composer' } } as never)
    await atBottom
  }
  // Our own prompt.submit hook drops ours in this state (refuseOwnSubmit); a hook beneath stands in for it here.
  w.dropIf = text => (text === ours ? 'a user prompt came first' : undefined)
  await w.advance(2000)
  expect(w.submits).toEqual([ours, USER])
  const ht = w.lastHt() ?? ''
  expect(w.rowsOf('handoff_skipped').length).toBe(0)
  expect(w.callsOf('handoff-turn').map(c => [c.args[0], w.flag(c, '--ht')])).toEqual([['open', ht], ['close', ht]])
  expect(w.compacts.length).toBe(0)
  open()
  await held
  await w.turnStart($, USER)
  expect(w.rowsOf('handoff_skipped').map(r => [r.why, r.ht])).toEqual([['user-turn', ht]])
  expect(w.rowsOf('halt').filter(r => r.active === false).length).toBe(1)
  w.tokens = 100000
  await w.turnEnd($, 'Here you go.')
  await w.advance(60000)
  expect(w.submits).toEqual([ours, USER])
  // The next turn is the user's, not an orphaned prompt of ours: it gets its checkpoint nudge.
  await w.turnStart($, 'more please')
  w.tokens = 640000
  expect((await w.tool($)).context).toBeDefined()
  expect(w.rowsOf('handoff_turn_start').length).toBe(0)
})

test('CR-F17, CR-F25: our own submit is told by origin; a handoff-turn one is refused in our hook once a user prompt came first', () => {
  expect(isOwnOrigin({ kind: 'plugin', name: 'x' }, 'x')).toBe(true)
  expect(isOwnOrigin({ kind: 'plugin', name: 'y' }, 'x')).toBe(false)
  expect(isOwnOrigin({ kind: 'composer' }, 'x')).toBe(false)
  const s = newState('l')
  expect(refuseOwnSubmit(s)).toBe(false)
  promptEntering(s)
  expect(refuseOwnSubmit(s)).toBe(false)
  s.handoffSubmitting = true
  expect(refuseOwnSubmit(s)).toBe(true)
  promptNotEntered(s)
  expect(refuseOwnSubmit(s)).toBe(false)
  s.mainTurnRunning = true
  expect(refuseOwnSubmit(s)).toBe(true)
  // A dropped prompt runs a deferred handoff turn's delay again only once none is entering and no turn runs.
  let again = 0
  s.mainTurnRunning = false
  s.afterForeign = () => { again++ }
  promptEntering(s)
  promptEntering(s)
  promptNotEntered(s)
  expect(again).toBe(0)
  promptNotEntered(s)
  expect([again, s.afterForeign]).toEqual([1, undefined])
})

test('CR-F17 (REG-register-42): a peer hook beneath rewrites our handoff-turn prompt: its turn is still the handoff turn (origin, not text); the next user turn clears halt', { options: CAP3 }, async ($, on) => {
  const w = new World().install(on, CAPPED)
  await w.start($)
  await lastCycleTurn($, w)
  if (!TURN) return
  const ours = submitText(w, 'cap') ?? ''
  const REWORDED = 'A peer plugin reworded this prompt.'
  w.rewrite = text => (text === ours ? REWORDED : undefined)
  // The engine runs our submit through every hook but the calling one, so our prompt.submit hook
  // sees it (d.ts); the kit skips the whole plugin, so the test raises that pass itself.
  let echoed = false
  w.atSubmit = async text => {
    if (echoed || text !== ours) return
    echoed = true
    await $.prompt.submit({ text: ours, origin: { kind: 'plugin', name: w.name } } as never)
  }
  await w.advance(2000)
  expect(echoed).toBe(true)
  expect(w.submits).toEqual([ours, ours])
  expect(w.submitOrigins).toEqual([{ kind: 'plugin', name: w.name }, { kind: 'plugin', name: w.name }])
  const ht = w.lastHt() ?? ''
  await w.turnStart($, REWORDED)
  expect(w.rowsOf('handoff_turn_start').map(r => r.ht)).toEqual([ht])
  expect(w.rowsOf('handoff_skipped').length).toBe(0)
  expect(w.rowsOf('halt').filter(r => r.active === false).length).toBe(0)
  w.publish(ht, PUBLISHED)
  await w.turnEnd($, 'Handoff written.')
  await w.advance(500)
  expect(w.compacts.length).toBe(1)
  // Our submit is settled: the user's next turn is theirs (halt clears), not taken as ours.
  await w.userTurn($, 'what now?')
  expect(w.rowsOf('halt').filter(r => r.active === false).length).toBe(1)
})

test('REG-boundary-205 (CR-F19): a native compaction that starts during the post-handoff checkpoint and ends skipped: no dispatch before it, the rerun uses the nudge\'s nonce, one record', { options: { ...CAP3, queue_cmd: '/q/bin/queue' } }, async ($, on) => {
  const w = new World().install(on, CAPPED)
  await w.start($)
  const r = await lastCycleTurn($, w)
  if (!TURN) return
  const named = /--nonce ([0-9a-f]{8})/.exec(r.context?.[0] ?? '')?.[1] ?? ''
  expect(named).not.toBe('')
  await w.advance(2000)
  await handoffTurnStarts($, w)
  const ht = w.lastHt() ?? ''
  w.publish(ht, PUBLISHED)
  await w.turnEnd($, 'Handoff written.')
  let release!: () => void
  let p: Promise<unknown> | undefined
  w.atHelper = async sub => {
    if (sub !== 'checkpoint' || p !== undefined) return
    w.compactGate = new Promise<void>(res => { release = res })
    w.compactMode = { skip: 'nothing to compact' }
    p = raiseCompact($, { trigger: 'auto' })
  }
  await w.advance(500)
  await w.advance(1000)
  expect(p).toBeDefined()
  const selfDispatch = () => w.callsOf('dispatch').filter(c => w.flag(c, '--channel') === 'mod-self')
  expect(selfDispatch().length).toBe(0)
  w.atHelper = undefined
  w.compactGate = undefined
  release()
  await p
  w.compactMode = 'ok'
  await w.advance(60000)
  expect(w.compacts.map(c => c.trigger)).toEqual(['auto', undefined])
  expect(selfDispatch().map(c => w.flag(c, '--nonce'))).toEqual([named])
  expect(markerNonce(w, w.compacts[1]?.instructions)).toBe(named)
})

test('REG-boundary-205 (CR-F19): a native compaction that starts while the dispatch record is written and ends skipped: the rerun reuses that record (one dispatch, same nonce and text)', { options: CAP3 }, async ($, on) => {
  const w = new World().install(on, CAPPED)
  await w.start($)
  await lastCycleTurn($, w)
  if (!TURN) return
  await w.advance(2000)
  await handoffTurnStarts($, w)
  const ht = w.lastHt() ?? ''
  w.publish(ht, PUBLISHED)
  await w.turnEnd($, 'Handoff written.')
  let release!: () => void
  let p: Promise<unknown> | undefined
  w.atHelper = async (sub, args) => {
    if (sub !== 'dispatch' || !args.includes('mod-self') || p !== undefined) return
    w.compactGate = new Promise<void>(res => { release = res })
    w.compactMode = { skip: 'nothing to compact' }
    p = raiseCompact($, { trigger: 'auto' })
  }
  await w.advance(500)
  await w.advance(1000)
  expect(p).toBeDefined()
  expect(w.compacts.map(c => c.trigger)).toEqual(['auto'])
  w.atHelper = undefined
  w.compactGate = undefined
  release()
  await p
  w.compactMode = 'ok'
  await w.advance(60000)
  const self = w.callsOf('dispatch').filter(c => w.flag(c, '--channel') === 'mod-self')
  expect(self.length).toBe(1)
  const nonce = w.flag(self[0], '--nonce') ?? ''
  expect(w.compacts.map(c => c.trigger)).toEqual(['auto', undefined])
  expect(markerNonce(w, w.compacts[1]?.instructions)).toBe(nonce)
  expect(w.rowsOf('compacted').filter(r => r.nonce === nonce && r.skip === null && r.handoff_ht === ht).length).toBe(1)
  expect(w.rowsOf('skip').length).toBe(0)
})

/**
 * CR-F17 (residual): the user pressed Enter as our handoff-turn prompt went in, past our hook; the
 * user's turn starts first and ends. Returns our queued prompt's text, the closed ht and the halt
 * row count, or undefined in a build without the handoff-turn text.
 */
async function orphanQueued($: Engine, w: World): Promise<{ ours: string; ht: string; haltRows: number } | undefined> {
  await w.start($)
  await lastCycleTurn($, w)
  if (!TURN) return undefined
  const ours = submitText(w, 'cap') ?? ''
  let fired = false
  w.atSubmit = async text => {
    if (fired || text !== ours) return
    fired = true
    await $.prompt.submit({ text: 'the user typed this', origin: { kind: 'composer' } } as never)
    await w.turnStart($, 'the user typed this')
  }
  await w.advance(2000)
  expect(fired).toBe(true)
  w.tokens = 100000
  await w.turnEnd($, 'Here you go.')
  return { ours, ht: w.lastHt() ?? '', haltRows: w.rowsOf('halt').length }
}

// OT-1 (owner xxxxxxxx-06 "Abort the leftover turn", 2026-10-22; SPEC-DELTAS AT-OT-01, AT-OT-02).
test('AT-OT-01: our queued handoff-turn prompt\'s turn is aborted at its start: one abort of that turn, one handoff_orphan_aborted row with the closed ht, no handoff_turn_start, no nudge', { options: CAP3 }, async ($, on) => {
  const w = new World().install(on, CAPPED)
  const q = await orphanQueued($, w)
  if (!q) return
  expect(w.aborts).toEqual([])
  await w.turnStart($, q.ours)
  expect(w.aborts.length).toBe(1)
  expect(w.rowsOf('handoff_orphan_aborted').map(r => [r.turn_id, r.ht])).toEqual([[w.aborts[0], q.ht]])
  expect(w.rowsOf('handoff_orphan_abort_failed').length).toBe(0)
  expect(w.rowsOf('handoff_turn_start').length).toBe(0)
  expect(w.rowsOf('halt').length).toBe(q.haltRows)
  w.tokens = 640000
  expect((await w.tool($)).context).toBeUndefined()
  // The next turn of ours is not aborted again.
  await w.turnEnd($, '', 'aborted')
  await w.userTurn($)
  expect(w.aborts.length).toBe(1)
})

test('AT-OT-02: the abort rejects: one handoff_orphan_abort_failed row, and the turn runs as before (no handoff_turn_start, no checkpoint nudge)', { options: CAP3 }, async ($, on) => {
  const w = new World().install(on, CAPPED)
  const q = await orphanQueued($, w)
  if (!q) return
  w.abortThrow = true
  await w.turnStart($, q.ours)
  expect(w.aborts.length).toBe(1)
  expect(w.rowsOf('handoff_orphan_abort_failed').map(r => [r.turn_id, r.ht, r.why])).toEqual([[w.aborts[0], q.ht, 'rejected']])
  expect(w.rowsOf('handoff_orphan_aborted').length).toBe(0)
  expect(w.rowsOf('handoff_turn_start').length).toBe(0)
  w.tokens = 640000
  expect((await w.tool($)).context).toBeUndefined()
})

// REVIEW-NIGHT-3 R3-07: an abort must never cancel the user's words. With another prompt entering
// beside ours, a turn whose text is more than ours may carry that prompt too: it is not aborted.
test('R3-07 (OT-1): another prompt entered and the turn holds more than our prompt: no abort, handoff_orphan_abort_failed why other-text, no nudge', { options: CAP3 }, async ($, on) => {
  const w = new World().install(on, CAPPED)
  const q = await orphanQueued($, w)
  if (!q) return
  await $.prompt.submit({ text: 'and run the linter too', origin: { kind: 'composer' } } as never)
  await w.turnStart($, q.ours + '\n\nand run the linter too')
  expect(w.aborts).toEqual([])
  expect(w.rowsOf('handoff_orphan_abort_failed').map(r => [r.ht, r.why])).toEqual([[q.ht, 'other-text']])
  expect(w.rowsOf('handoff_orphan_aborted').length).toBe(0)
  expect(w.rowsOf('handoff_turn_start').length).toBe(0)
  w.tokens = 640000
  expect((await w.tool($)).context).toBeUndefined()
})

test('R3-07 (OT-1): another prompt entered but the turn holds our prompt alone: it is aborted', { options: CAP3 }, async ($, on) => {
  const w = new World().install(on, CAPPED)
  const q = await orphanQueued($, w)
  if (!q) return
  await $.prompt.submit({ text: 'and run the linter too', origin: { kind: 'composer' } } as never)
  await w.turnStart($, q.ours)
  expect(w.aborts.length).toBe(1)
  expect(w.rowsOf('handoff_orphan_aborted').map(r => r.ht)).toEqual([q.ht])
})

test('CR-F17 (residual): Enter reaches prompt.submit only after our prompt went past our hook, and its turn starts first: no handoff turn, halt clears, the ht is closed, our queued prompt\'s turn is aborted (OT-1)', { options: CAP3 }, async ($, on) => {
  const w = new World().install(on, CAPPED)
  await w.start($)
  await lastCycleTurn($, w)
  if (!TURN) return
  const ours = submitText(w, 'cap') ?? ''
  let fired = false
  w.atSubmit = async text => {
    if (fired || text !== ours) return
    fired = true
    // The user pressed Enter as our prompt went in, past our hook: their prompt passes prompt.submit, then its turn starts.
    await $.prompt.submit({ text: 'the user typed this', origin: { kind: 'composer' } } as never)
    await w.turnStart($, 'the user typed this')
  }
  await w.advance(2000)
  expect(fired).toBe(true)
  const ht = w.lastHt() ?? ''
  expect(w.rowsOf('handoff_turn_start').length).toBe(0)
  expect(w.rowsOf('halt').filter(r => r.active === false).length).toBe(1)
  expect(w.rowsOf('handoff_skipped').map(r => [r.why, r.ht])).toEqual([['user-turn', ht]])
  expect(w.callsOf('handoff-turn').map(c => c.args[0])).toEqual(['open', 'close'])
  // The user's turn ends by the normal rules (no handoff_turn_end).
  w.tokens = 100000
  await w.turnEnd($, 'Here you go.')
  expect(w.rowsOf('handoff_turn_end').length).toBe(0)
  // Our queued prompt's turn: still ours (no second halt row), not a handoff turn, aborted at
  // its start (OT-1), no nudge.
  const haltRows = w.rowsOf('halt').length
  await w.turnStart($, ours)
  expect(w.rowsOf('halt').length).toBe(haltRows)
  expect(w.rowsOf('handoff_turn_start').length).toBe(0)
  expect(w.aborts.length).toBe(1)
  expect(w.rowsOf('handoff_orphan_aborted').length).toBe(1)
  w.tokens = 640000
  expect((await w.tool($)).context).toBeUndefined()
})

test('CR-F17: a user prompt entering beside our submit while our own turn starts first: ours is the handoff turn, the user turn after it clears halt', { options: CAP3 }, async ($, on) => {
  const w = new World().install(on, CAPPED)
  await w.start($)
  await lastCycleTurn($, w)
  if (!TURN) return
  const ours = submitText(w, 'cap') ?? ''
  let held: Promise<unknown> | undefined
  let reached!: () => void
  const atBottom = new Promise<void>(r => { reached = r })
  let open!: () => void
  const gate = new Promise<void>(r => { open = r })
  w.atSubmit = async text => {
    if (text === 'run the tests next') {
      reached()
      await gate
      return
    }
    if (text !== ours || held !== undefined) return
    held = $.prompt.submit({ text: 'run the tests next', origin: { kind: 'composer' } } as never)
    await atBottom
    await w.turnStart($, ours)
  }
  await w.advance(2000)
  const ht = w.lastHt() ?? ''
  expect(w.rowsOf('handoff_turn_start').map(r => r.ht)).toEqual([ht])
  expect(w.rowsOf('halt').filter(r => r.active === false).length).toBe(0)
  await w.turnEnd($, 'Handoff written.')
  open()
  await held
  await w.userTurn($, 'run the tests next')
  expect(w.rowsOf('halt').filter(r => r.active === false).length).toBe(1)
  expect(w.rowsOf('handoff_skipped').length).toBe(0)
})

test('CR-F17: claimTurn: the first turn is ours with no other prompt entering; beside one, only the turn with our text', () => {
  const s = newState('l')
  submitPending(s, 'Note from the plugin: write the handoff.')
  expect(claimTurn(s, '')).toBe(true)
  expect(s.ourSubmitPending).toBe(false)
  submitPending(s, 'Note from the plugin: write the handoff.')
  promptEntering(s)
  expect(claimTurn(s, 'the user typed this')).toBe(false)
  expect([s.ourSubmitPending, s.foreignPrompts]).toEqual([true, 0])
  expect(claimTurn(s, 'Note from the plugin: write the handoff.')).toBe(true)
  submitPending(s, 'Note from the plugin: write the handoff.')
  promptEntering(s)
  expect(claimTurn(s, '<framed>\nNote from the plugin: write the handoff.\n</framed>')).toBe(true)
  expect(s.foreignPrompts).toBe(1)
  expect(claimTurn(s, 'the user typed this')).toBe(false)
  expect(s.foreignPrompts).toBe(0)
  promptEntering(s)
  promptNotEntered(s)
  promptNotEntered(s)
  expect(s.foreignPrompts).toBe(0)
  expect(isOurText('anything', undefined)).toBe(false)
  expect(isOurText('anything', '  ')).toBe(false)
})

// DP-30 (2): the hourly stamp is written once per handoff turn, so a turn deferred for a prompt
// that then never entered, and run again, still leaves the second hourly slot free.
test('DP-30 (2): our submit dropped for an entering user prompt, that prompt dropped too, the delay runs again: one hourly stamp, so the next last cycle still promises its handoff turn', { options: { max_auto_continues_per_hour: 0 } }, async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await lastCycleTurn($, w)
  if (!TURN) return
  const ours = submitText(w, 'continue-off') ?? ''
  const USER = 'the user typed this'
  let held: Promise<unknown> | undefined
  let reached!: () => void
  const atBottom = new Promise<void>(r => { reached = r })
  let open!: () => void
  const gate = new Promise<void>(r => { open = r })
  let dropOurs = true
  w.atSubmit = async text => {
    if (text === USER) {
      reached()
      await gate
      return
    }
    if (text !== ours || held !== undefined) return
    held = $.prompt.submit({ text: USER, origin: { kind: 'composer' } } as never)
    await atBottom
  }
  w.dropIf = text => (text === USER ? 'refused by a guard' : text === ours && dropOurs ? 'a user prompt came first' : undefined)
  await w.advance(2000)
  expect(w.submits).toEqual([ours, USER])
  dropOurs = false
  open()
  await held
  await w.settle()
  await w.advance(2000)
  expect(w.submits).toEqual([ours, USER, ours])
  await handoffTurnStarts($, w)
  expect(w.rowsOf('handoff_turn_start').length).toBe(1)
  w.tokens = 100000
  await w.turnEnd($, 'Handoff written.')
  await w.advance(60000)
  // The next last cycle (continue-off): one stamp in the last hour, so [halt-handoff] is kept.
  await w.turnStart($, 'more please')
  w.tokens = 610000
  expect((await w.tool($)).context?.[0]).toBe(assemble(w.name, 'checkpoint-nudge', ['halt', 'halt-handoff'], { tokens: '610,000', halt_reason: HALT_REASON_TEXT['continue-off'] }))
})

// DP-30 (1): a rerun after a wait stop reuses the first checkpoint (its sweep's evidence): no
// second checkpoint with the same id6, whose sweep would answer `skipped: swept` with no rows.
test('DP-30 (1): a native compaction that stops the post-handoff compaction after its checkpoint and ends skipped: the rerun reuses that checkpoint (one checkpoint call for the nonce)', { options: { ...CAP3, queue_cmd: '/q/bin/queue' } }, async ($, on) => {
  const w = new World().install(on, CAPPED)
  await w.start($)
  const r = await lastCycleTurn($, w)
  if (!TURN) return
  const named = /--nonce ([0-9a-f]{8})/.exec(r.context?.[0] ?? '')?.[1] ?? ''
  await w.advance(2000)
  await handoffTurnStarts($, w)
  w.publish(w.lastHt() ?? '', PUBLISHED)
  await w.turnEnd($, 'Handoff written.')
  let release!: () => void
  let p: Promise<unknown> | undefined
  w.atHelper = async sub => {
    if (sub !== 'checkpoint' || p !== undefined) return
    w.compactGate = new Promise<void>(res => { release = res })
    w.compactMode = { skip: 'nothing to compact' }
    p = raiseCompact($, { trigger: 'auto' })
  }
  await w.advance(500)
  await w.advance(1000)
  w.atHelper = undefined
  w.compactGate = undefined
  release()
  await p
  w.compactMode = 'ok'
  await w.advance(60000)
  const cps = w.callsOf('checkpoint').map(c => w.flag(c, '--nonce'))
  expect(cps.filter(n => n === named).length).toBe(1)
  expect(markerNonce(w, w.compacts[1]?.instructions)).toBe(named)
  expect(w.callsOf('dispatch').filter(c => w.flag(c, '--channel') === 'mod-self').map(c => w.flag(c, '--nonce'))).toEqual([named])
})

// DP-29 (E-M-15 option): the post-handoff dispatch record a native compaction made a second one
// is closed by a `compacted` row with `skip: native-ran` and its nonce.
test('DP-29: a native compaction that starts while the post-handoff dispatch record is written and compacts: no second compaction; compacted skip native-ran with that nonce', { options: CAP3 }, async ($, on) => {
  const w = new World().install(on, CAPPED)
  await w.start($)
  await lastCycleTurn($, w)
  if (!TURN) return
  await w.advance(2000)
  await handoffTurnStarts($, w)
  const ht = w.lastHt() ?? ''
  w.publish(ht, PUBLISHED)
  await w.turnEnd($, 'Handoff written.')
  let release!: () => void
  let p: Promise<unknown> | undefined
  w.atHelper = async (sub, args) => {
    if (sub !== 'dispatch' || !args.includes('mod-self') || p !== undefined) return
    w.compactGate = new Promise<void>(res => { release = res })
    p = raiseCompact($, { trigger: 'auto' })
  }
  await w.advance(500)
  await w.advance(1000)
  expect(p).toBeDefined()
  w.atHelper = undefined
  w.compactGate = undefined
  release()
  await p
  await w.advance(60000)
  expect(w.compacts.map(c => c.trigger)).toEqual(['auto'])
  const self = w.callsOf('dispatch').filter(c => w.flag(c, '--channel') === 'mod-self')
  expect(self.length).toBe(1)
  const nonce = w.flag(self[0], '--nonce') ?? ''
  expect(w.rowsOf('compacted').filter(r => r.nonce === nonce).map(r => [r.skip, r.handoff_ht])).toEqual([['native-ran', ht]])
  expect(w.rowsOf('skip').map(r => [r.why, r.ht])).toEqual([['compacted', ht]])
})

test('DP-29: a native compaction that compacts during the post-handoff checkpoint: no dispatch record, so no native-ran row', { options: CAP3 }, async ($, on) => {
  const w = new World().install(on, CAPPED)
  await w.start($)
  await lastCycleTurn($, w)
  if (!TURN) return
  await w.advance(2000)
  await handoffTurnStarts($, w)
  w.publish(w.lastHt() ?? '', PUBLISHED)
  await w.turnEnd($, 'Handoff written.')
  let p: Promise<unknown> | undefined
  w.atHelper = async sub => {
    if (sub !== 'checkpoint' || p !== undefined) return
    p = raiseCompact($, { trigger: 'auto' })
    await p
  }
  await w.advance(500)
  await w.advance(60000)
  expect(w.rowsOf('compacted').filter(r => r.skip === 'native-ran').length).toBe(0)
  expect(w.callsOf('dispatch').filter(c => w.flag(c, '--channel') === 'mod-self').length).toBe(0)
})
