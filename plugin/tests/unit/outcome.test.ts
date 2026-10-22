// U tests through the kit: the per-compaction `mod_outcome` row (F2-3, MOD-SPEC §2.5 rollup
// fields nudged, continued, halt, resume). One append-only row per compaction, written once
// the compaction's resume block has settled; readers join it to the rollup by nonce.
import { expect, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import { hasAsset } from '../../hooks/lib/assemble'
import { AGENT, SID_A, WATCH, World, markerNonce, raiseCompact } from './harness.test'

/** A main turn that crosses the soft max (nudge), ends with `answer`, and compacts at 500 ms. */
async function nudgedTurn($: Engine, w: World): Promise<void> {
  await w.turnStart($)
  w.tokens = 610000
  await w.tool($)
  await w.turnEnd($, 'Checkpoint: clean · Step 1: run the tests')
  await w.advance(500)
}

const nonceOf = (w: World, i: number): string | undefined => w.flag(w.callsOf('dispatch')[i], '--nonce')

test('F2-3: main auto, no nudge: no row while the block is pending; prompt.context delivers it: one row, delivered:prompt.context', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await w.turnStart($)
  await raiseCompact($, { trigger: 'auto' })
  expect(w.rowsOf('mod_outcome').length).toBe(0)
  await $.prompt.context({ blocks: [] })
  await $.prompt.context({ blocks: [] })
  const rows = w.rowsOf('mod_outcome')
  expect(rows.length).toBe(1)
  expect(rows[0]).toMatchObject({
    nonce: nonceOf(w, 0), nudged: false, continued: false, halt: false, resume: 'delivered:prompt.context',
    actor: 'main', writer: 'mod', sid: SID_A, v: 1,
  })
  for (const k of ['ts', 'pid', 'plugin_version', 'cc_version', 'turn_seq']) expect(Object.keys(rows[0] ?? {})).toContain(k)
})

test('F2-3: subagent compaction: one row at once, none-subagent, actor = the agent id', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await raiseCompact($, { trigger: 'auto', agentId: AGENT })
  expect(w.rowsOf('mod_outcome').map(r => [r.nonce, r.actor, r.nudged, r.continued, r.halt, r.resume]))
    .toEqual([[nonceOf(w, 0), AGENT, false, false, false, 'none-subagent']])
})

test('F2-3: nudge-driven plugin compaction with an auto-continue: nudged, continued, delivered:prompt.submit', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await nudgedTurn($, w)
  expect(w.submits.length).toBe(1)
  expect(w.rowsOf('mod_outcome').map(r => [r.nonce, r.nudged, r.continued, r.halt, r.resume]))
    .toEqual([[nonceOf(w, 0), true, true, false, 'delivered:prompt.submit']])
})

test('F2-3: SessionStart won the claim: prompt.context adds nothing and the row says delivered:sessionstart', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  w.atCompact = () => {
    const n = markerNonce(w, w.compacts[w.compacts.length - 1]?.instructions)
    if (n) w.claims.set(n, 'sessionstart')
  }
  await raiseCompact($, { trigger: 'auto' })
  const ctx = await $.prompt.context({ blocks: [] })
  expect(ctx.blocks.length).toBe(0)
  expect(w.rowsOf('mod_outcome').map(r => r.resume)).toEqual(['delivered:sessionstart'])
})

test('F2-3: a block no channel took through a whole turn: undelivered; one claimed by SessionStart meanwhile: delivered:sessionstart', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await w.turnStart($)
  await raiseCompact($, { trigger: 'auto' })
  await w.turnEnd($)
  await w.turnStart($)
  await w.turnEnd($)
  await raiseCompact($, { trigger: 'auto' })
  w.files.set(`${WATCH}/${SID_A}/resume-claimed/${nonceOf(w, 1) ?? ''}`, 'sessionstart')
  await w.turnStart($)
  await w.turnEnd($)
  await w.turnStart($)
  await w.turnEnd($)
  expect(w.rowsOf('mod_outcome').map(r => [r.nonce, r.resume])).toEqual([[nonceOf(w, 0), 'undelivered'], [nonceOf(w, 1), 'delivered:sessionstart']])
  expect(w.rowsOf('resume_undelivered').length).toBe(1)
})

test('F2-3: a pending block replaced by a newer compaction gets its row then (undelivered); the newer one when delivered', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await w.turnStart($)
  await raiseCompact($, { trigger: 'auto' })
  await raiseCompact($, { trigger: 'auto' })
  expect(w.rowsOf('mod_outcome').map(r => [r.nonce, r.resume])).toEqual([[nonceOf(w, 0), 'undelivered']])
  await $.prompt.context({ blocks: [] })
  expect(w.rowsOf('mod_outcome').map(r => [r.nonce, r.resume])).toEqual([[nonceOf(w, 0), 'undelivered'], [nonceOf(w, 1), 'delivered:prompt.context']])
})

test('F2-3: the second consecutive non-ok verdict enters halt: its row has halt true, the first false', async ($, on) => {
  const w = new World().install(on)
  w.summaryMode = 'unshaped'
  await w.start($)
  await w.turnStart($)
  await raiseCompact($, { trigger: 'auto' })
  await $.prompt.context({ blocks: [] })
  await raiseCompact($, { trigger: 'auto' })
  await $.prompt.context({ blocks: [] })
  expect(w.rowsOf('mod_outcome').map(r => r.halt)).toEqual([false, true])
})

test('F2-3: the capped 4th nudge-driven compaction: not continued, halt true, its block delivered later by prompt.context', { options: { max_auto_continues_per_hour: 3 } }, async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  for (let i = 0; i < 4; i++) {
    await nudgedTurn($, w)
    if (i === 3) {
      // The capped cycle's handoff turn (MOD-SPEC §9.1) comes first; nothing is published here.
      if (hasAsset('handoff-turn')) {
        await w.advance(2000)
        await w.turnStart($, '')
        await w.turnEnd($, 'LINT stop.')
        await w.advance(500)
      }
      w.tokens = 100000
      break
    }
    w.tokens = 100000
    await w.turnStart($, 'continue text')
    await w.turnEnd($)
    for (let q = 0; q < 2; q++) {
      await w.turnStart($)
      await w.turnEnd($)
    }
    await w.advance(10 * 60000)
  }
  expect(w.rowsOf('continue_capped').length).toBe(1)
  expect(w.rowsOf('mod_outcome').map(r => [r.continued, r.resume])).toEqual([
    [true, 'delivered:prompt.submit'], [true, 'delivered:prompt.submit'], [true, 'delivered:prompt.submit'],
  ])
  await $.prompt.context({ blocks: [] })
  const rows = w.rowsOf('mod_outcome')
  expect(rows.length).toBe(4)
  expect(rows[3]).toMatchObject({ nonce: nonceOf(w, 3), nudged: true, continued: false, halt: true, resume: 'delivered:prompt.context' })
  if (hasAsset('handoff-turn')) expect(rows[3]?.handoff_turn).toBe('none')
  expect(new Set(rows.map(r => r.nonce)).size).toBe(4)
})

test('F2-3: skipped and precompute dispatches get no row (no compaction to report)', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await raiseCompact($, { trigger: 'precompute' })
  w.compactMode = { skip: 'vetoed' }
  await raiseCompact($, { trigger: 'auto' })
  await $.prompt.context({ blocks: [] })
  expect(w.rowsOf('mod_outcome').length).toBe(0)
})
