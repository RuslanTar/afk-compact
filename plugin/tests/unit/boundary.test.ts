// U tests through the kit: turn-end scheduler, self-call, nudge, auto-continue, cap, halt,
// thrash (MOD-SPEC §4, §9) and the trigger switches (§1.2).
import { expect, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import { AGENT, SID_A, WATCH, World, markerNonce, raiseCompact } from './harness.test'

const CONT = 'the session was compacted at the checkpoint you reached. Continue from Step 1 of the summary; questions the user owns stay open.'

/** A main turn that crosses the soft max (nudge), ends with `answer`, and compacts at 500 ms. */
async function nudgedTurn($: Engine, w: World, answer = 'Checkpoint: clean · Step 1: run the tests'): Promise<void> {
  await w.turnStart($)
  w.tokens = 610000
  await w.tool($)
  await w.turnEnd($, answer)
  await w.advance(500)
}

test('AT-M2-01: boundary at 410K after a clean answer: one $.session.compact with the mod-self nonce', async ($, on) => {
  const w = new World().install(on)
  let dispatchedBefore = false
  w.atCompact = () => {
    dispatchedBefore = w.callsOf('dispatch').length === 1
  }
  await w.start($)
  await w.turnStart($)
  w.tokens = 410000
  await w.turnEnd($)
  await w.advance(2000)
  expect(w.compacts.length).toBe(1)
  const d = w.callsOf('dispatch')[0]
  expect(dispatchedBefore).toBe(true)
  expect(w.flag(d, '--channel')).toBe('mod-self')
  expect(w.flag(d, '--trigger')).toBe('plugin')
  expect(w.flag(d, '--midturn')).toBe('false')
  expect(markerNonce(w, w.compacts[0]?.instructions)).toBe(w.flag(d, '--nonce'))
  expect(w.compacts[0]?.instructions).not.toContain('This began mid-turn')
  expect(w.callsOf('checkpoint').length).toBe(1)
  expect(w.callsOf('save-copy').length).toBe(1)
  expect(w.submits.length).toBe(0)
})

test('AT-B-01: timer at 2000 ms; a turn.start 1 s later cancels it', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await w.turnStart($)
  w.tokens = 410000
  await w.turnEnd($)
  await w.advance(1999)
  expect(w.compacts.length).toBe(0)
  await w.advance(1)
  expect(w.compacts.length).toBe(1)

  w.compacts = []
  await w.advance(60000)
  await w.turnStart($)
  await w.turnEnd($)
  await w.advance(1000)
  await w.turnStart($)
  await w.advance(10000)
  expect(w.compacts.length).toBe(0)
})

test('AT-B-02: a turn ending while an AskUserQuestion call is open: skip why=asks, no timer', async ($, on) => {
  const w = new World().install(on)
  let release: (() => void) | undefined
  w.toolAnswer = tool => (tool === 'AskUserQuestion' ? new Promise(r => (release = () => r({ result: {} }))) : { result: {} })
  await w.start($)
  await w.turnStart($)
  w.tokens = 410000
  const open = $.tool.call({ tool: 'AskUserQuestion', questions: [] } as never)
  await w.settle()
  await w.turnEnd($)
  expect(w.rowsOf('skip').map(r => r.why)).toEqual(['asks'])
  await w.advance(5000)
  expect(w.compacts.length).toBe(0)
  release?.()
  await open
})

test('AT-B-03: an eligible turn end 10 s after a plugin compaction: skip why=cooldown', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await w.turnStart($)
  w.tokens = 410000
  await w.turnEnd($)
  await w.advance(2000)
  expect(w.compacts.length).toBe(1)
  await w.advance(8000)
  await w.turnStart($)
  await w.turnEnd($)
  expect(w.rowsOf('skip').map(r => r.why)).toEqual(['cooldown'])
  await w.advance(5000)
  expect(w.compacts.length).toBe(1)
})

test('AT-B-04: one nudge per main turn; none for a subagent call or a denied call', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await w.turnStart($)
  w.tokens = 700000
  expect((await w.tool($, AGENT)).context).toBeUndefined()
  w.tokens = 620000
  w.toolAnswer = () => ({ deny: 'no' })
  expect((await w.tool($)).deny).toBe('no')
  w.toolAnswer = () => ({ result: {} })
  w.tokens = 610000
  const first = await w.tool($)
  const second = await w.tool($)
  expect(first.context?.length).toBe(1)
  expect(first.context?.[0]).toContain(`Note from the user's ${w.name} plugin: context is at 610,000 tokens.`)
  expect(first.context?.[0]).toContain('Then it resumes the work by itself')
  expect(second.context).toBeUndefined()
  expect(w.rowsOf('nudge').length).toBe(1)
})

test('AT-B-05: two consecutive unshaped main verdicts: [halt] nudge, no continue, one halt row and toast', async ($, on) => {
  const w = new World().install(on)
  w.summaryMode = 'unshaped'
  await w.start($)
  await w.turnStart($)
  await raiseCompact($, { trigger: 'auto' })
  await raiseCompact($, { trigger: 'auto' })
  expect(w.rowsOf('halt').length).toBe(1)
  expect(w.rowsOf('halt')[0]?.reason).toBe('2-nonok')
  expect(w.toasts.filter(t => t.includes(': halt;')).length).toBe(1)
  expect(w.files.get(`${WATCH}/${SID_A}/halt.json`)).toContain('"active":true')
  w.tokens = 610000
  const r = await w.tool($)
  expect(r.context?.[0]).toContain('so the plugin will not resume the work by itself')
  expect(r.context?.[0]).not.toContain('Then it resumes the work by itself')
  await w.turnEnd($)
  await w.advance(5000)
  expect(w.submits.length).toBe(0)
})

test('AT-B-06: 4 nudge-driven compactions within 50 min: 3 continues, the 4th continue_capped + halt', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  for (let i = 0; i < 4; i++) {
    await nudgedTurn($, w)
    w.tokens = 100000
    if (i === 3) break
    await w.turnStart($, 'continue text')
    await w.turnEnd($)
    for (let q = 0; q < 2; q++) {
      await w.turnStart($)
      await w.turnEnd($)
    }
    await w.advance(10 * 60000)
  }
  expect(w.compacts.length).toBe(4)
  expect(w.submits.length).toBe(3)
  expect(w.submits.every(t => t.includes(CONT))).toBe(true)
  expect(w.rowsOf('thrash').length).toBe(0)
  expect(w.rowsOf('continue_capped').length).toBe(1)
  expect(w.rowsOf('halt')[0]?.reason).toBe('cap')
})

test('AT-B-07: two plugin compactions, each re-reaching target within 2 main turns: thrash + halt', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  w.tokens = 410000
  for (let i = 0; i < 2; i++) {
    await w.turnStart($)
    await w.turnEnd($)
    await w.advance(2000)
    await w.advance(60000)
  }
  expect(w.compacts.length).toBe(2)
  await w.turnStart($)
  await w.turnEnd($)
  expect(w.rowsOf('thrash').length).toBe(1)
  expect(w.rowsOf('halt')[0]?.reason).toBe('thrash')
  expect(w.rowsOf('skip').map(r => r.why)).toEqual(['halt'])
  await w.advance(5000)
  expect(w.compacts.length).toBe(2)
})

test('AT-B-08: halt, then a user-typed turn: halt cleared; the next nudge-driven compaction continues', async ($, on) => {
  const w = new World().install(on)
  w.summaryMode = 'unshaped'
  await w.start($)
  await raiseCompact($, { trigger: 'auto' })
  await raiseCompact($, { trigger: 'auto' })
  expect(w.rowsOf('halt').length).toBe(1)
  w.summaryMode = 'ok'
  await nudgedTurn($, w)
  expect(w.rowsOf('halt').filter(r => r.active === false).length).toBe(1)
  expect(w.files.get(`${WATCH}/${SID_A}/halt.json`)).toContain('"active":false')
  expect(w.submits.length).toBe(1)
})

test('AT-B-09: a nudged turn that ends aborted: no continue', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await w.turnStart($)
  w.tokens = 610000
  await w.tool($)
  await w.turnEnd($, '', 'aborted')
  await w.advance(5000)
  expect(w.compacts.length).toBe(0)
  await w.turnStart($)
  w.tokens = 410000
  await w.turnEnd($)
  await w.advance(2000)
  expect(w.compacts.length).toBe(1)
  expect(w.submits.length).toBe(0)
})

test('AT-B-10: continue with the claim still free: fixed line + block, ≤5,500 chars, claim prompt.submit', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await nudgedTurn($, w)
  expect(w.submits.length).toBe(1)
  const text = w.submits[0] ?? ''
  expect(text.startsWith(`Note from the user's ${w.name} plugin: ${CONT}\n\nThe ${w.name} plugin adds this after compaction`)).toBe(true)
  expect(text.length <= 5500).toBe(true)
  const nonce = w.flag(w.callsOf('dispatch')[0], '--nonce') ?? ''
  expect(w.claims.get(nonce)).toBe('prompt.submit')
  expect(w.rowsOf('continue')[0]?.result).toBe('submitted')
})

test('AT-B-12: a nudged turn ending on a question, or with an AskUserQuestion call: skip why=asks-user', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await nudgedTurn($, w, 'All green.\n\nShould I push now?')
  expect(w.compacts.length).toBe(1)
  await w.advance(60000)
  await w.turnStart($)
  w.tokens = 610000
  await w.tool($)
  await $.tool.call({ tool: 'AskUserQuestion', questions: [] } as never)
  await w.turnEnd($)
  await w.advance(500)
  expect(w.compacts.length).toBe(2)
  expect(w.rowsOf('skip').filter(r => r.why === 'asks-user').length).toBe(2)
  expect(w.submits.length).toBe(0)
})

test('AT-B-13: halt mode: a tool call at 610K gets the [halt] nudge; a turn end at 450K skips (halt)', async ($, on) => {
  const w = new World().install(on)
  w.summaryMode = 'unshaped'
  await w.start($)
  await w.turnStart($)
  await raiseCompact($, { trigger: 'auto' })
  await raiseCompact($, { trigger: 'auto' })
  w.tokens = 610000
  expect((await w.tool($)).context?.[0]).toContain('so the plugin will not resume the work by itself')
  w.tokens = 450000
  await w.turnEnd($)
  expect(w.rowsOf('skip').map(r => r.why)).toEqual(['halt'])
  await w.advance(5000)
  expect(w.compacts.length).toBe(2)
})

test('halt mode survives a reload (halt.json) until a user-typed turn clears it', async ($, on) => {
  const w = new World().install(on)
  w.files.set(`${WATCH}/${SID_A}/halt.json`, JSON.stringify({ active: true, reason: 'thrash' }))
  await w.start($)
  w.tokens = 410000
  await raiseCompact($, { trigger: 'auto', agentId: undefined })
  await $.turn.complete({ answer: 'x', durationMs: 1, isAborted: false, turnId: 't0', reason: 'answer' })
  expect(w.rowsOf('skip').map(r => r.why)).toEqual(['halt'])
  await w.turnStart($)
  expect(w.rowsOf('halt').map(r => r.active)).toEqual([false])
})

test('AT-M2-03: $.session.compact rejects: compact_rejected, busy released, no timer; the next turn end schedules again', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await w.turnStart($)
  w.tokens = 410000
  w.compactMode = 'reject'
  await w.turnEnd($)
  await w.advance(2000)
  expect(w.rowsOf('compact_rejected').length).toBe(1)
  await w.advance(30000)
  expect(w.compacts.length).toBe(1)
  w.compactMode = 'ok'
  await w.turnStart($)
  await w.turnEnd($)
  await w.advance(2000)
  expect(w.compacts.length).toBe(2)
  expect(w.callsOf('save-copy').length).toBe(1)
})

test('AT-M2-04: $.session.compact resolves {skip:"vetoed"}: no save, no block, no continue', async ($, on) => {
  const w = new World().install(on)
  w.compactMode = { skip: 'vetoed' }
  await w.start($)
  await nudgedTurn($, w)
  expect(w.compacts.length).toBe(1)
  expect(w.rowsOf('compacted').map(r => r.skip)).toEqual(['vetoed'])
  expect(w.callsOf('save-copy').length).toBe(0)
  expect(w.callsOf('measure').length).toBe(0)
  expect(w.submits.length).toBe(0)
})

test('AT-P-09: triggers false: one triggers_off row; no nudge, compaction or submit; shaping still appends', { options: { triggers: false } }, async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await w.turnStart($)
  w.tokens = 610000
  expect((await w.tool($)).context).toBeUndefined()
  w.tokens = 450000
  await w.turnEnd($)
  await w.advance(5000)
  expect(w.rowsOf('triggers_off').length).toBe(1)
  expect(w.rowsOf('nudge').length).toBe(0)
  expect(w.compacts.length).toBe(0)
  expect(w.submits.length).toBe(0)
  await raiseCompact($, { trigger: 'auto' })
  expect(markerNonce(w, w.compacts[0]?.instructions)).toBeDefined()
})

test('AT-P-04: window 200000: trigger_disabled_small_window; no nudge or plugin compaction; shaping appends', async ($, on) => {
  const w = new World({ window: 200000 }).install(on)
  await w.start($)
  await w.turnStart($)
  w.tokens = 150000
  expect((await w.tool($)).context).toBeUndefined()
  await w.turnEnd($)
  await w.advance(5000)
  const eff = w.rowsOf('config_effective')[0]
  expect(eff?.soft_max).toBe(67000)
  expect(eff?.target).toBe(44666)
  expect(w.rowsOf('trigger_disabled_small_window').length).toBe(1)
  expect(w.compacts.length).toBe(0)
  await raiseCompact($, { trigger: 'auto' })
  expect(markerNonce(w, w.compacts[0]?.instructions)).toBeDefined()
})

test('AT-P-03: soft max 900000 over window 800000: soft_max 640000, target 400000, one config_clamped', {
  options: { compact_soft_max_tokens: 900000, native_window_tokens: 800000 },
}, async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  const eff = w.rowsOf('config_effective')[0]
  expect(eff?.soft_max).toBe(640000)
  expect(eff?.target).toBe(400000)
  expect(w.rowsOf('config_clamped').map(r => [r.key, r.configured, r.effective])).toEqual([['soft_max', 900000, 640000]])
})
