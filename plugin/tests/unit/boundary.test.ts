// U tests through the kit: turn-end scheduler, self-call, nudge, auto-continue, cap, halt,
// thrash (MOD-SPEC §4, §9) and the trigger switches (§1.2).
import { expect, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import { assemble, assembleIf, hasAsset } from '../../hooks/lib/assemble'
import { assetText } from '../../hooks/lib/assets.gen'
import { newState, promptEntering, promptNotEntered, refuseOwnSubmit, rejectClass, storeWord } from '../../hooks/lib/deps'
import { HALT_REASON_TEXT, maxCalls } from '../../hooks/lib/handoff-turn'
import { AGENT, SID_A, T0, WATCH, World, markerNonce, raiseCompact } from './harness.test'

/** The handoff-turn asset ships in this build (else last cycles degrade to no handoff turn). */
const TURN = hasAsset('handoff-turn')
const halted = (w: World, reason: keyof typeof HALT_REASON_TEXT, tokens = '610,000') =>
  assemble(w.name, 'checkpoint-nudge', TURN ? ['halt', 'halt-handoff'] : ['halt'], { tokens, halt_reason: HALT_REASON_TEXT[reason] })
const handoffSubmit = (w: World, reason: keyof typeof HALT_REASON_TEXT) =>
  assembleIf(w.name, 'handoff-turn', ['submit', 'submit-halt'], { halt_reason: HALT_REASON_TEXT[reason], max_calls: String(maxCalls()), store: storeWord(w.root, w.name) ?? '' })

const CONT = 'the session was compacted at the checkpoint you reached. Continue from Step 1 of the summary; questions the user owns stay open.'

/** A main turn that crosses the soft max (nudge), ends with `answer`, and compacts at 500 ms. */
async function nudgedTurn($: Engine, w: World, answer = 'Checkpoint: clean · Step 1: run the tests'): Promise<void> {
  await w.userTurn($)
  w.tokens = 610000
  await w.tool($)
  await w.turnEnd($, answer)
  await w.advance(500)
}

test('AT-M2-01: boundary at 410K after a clean answer: one $.session.compact with the mod-self nonce', { options: { precompact_turn: 'code' } }, async ($, on) => {
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

test('AT-B-01: timer at 2000 ms; a turn.start 1 s later cancels it', { options: { precompact_turn: 'code' } }, async ($, on) => {
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

test('AT-B-03: an eligible turn end 10 s after a plugin compaction: skip why=cooldown', { options: { precompact_turn: 'code' } }, async ($, on) => {
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

test('AT-B-05: two consecutive unshaped main verdicts: [halt] nudge with its reason; one handoff-turn submit, no continue, no compaction (DP-4)', async ($, on) => {
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
  w.compacts = []
  const r = await w.tool($)
  expect(r.context?.[0]).toBe(halted(w, '2-nonok'))
  expect(r.context?.[0]).not.toContain('Then it resumes the work by itself')
  // CR-F30/F35: a [halt] nudge promises no compaction (DP-4, DP-13). Not guarded on the asset:
  // a build whose nudge still makes the promise (before wp/text febc3c1, or a revert) fails here.
  expect(r.context?.[0]).not.toContain('the plugin compacts the session into a handoff summary')
  expect(r.context?.[0]).toContain('It compacts afterwards only if auto-continue is off or at its hourly limit.')
  await w.turnEnd($)
  await w.advance(5000)
  expect(w.submits).toEqual(TURN ? [handoffSubmit(w, '2-nonok')] : [])
  expect(w.rowsOf('continue').map(r => r.result)).toEqual(['halt:2-nonok'])
  if (TURN) {
    await w.turnStart($, '')
    await w.turnEnd($, 'Handoff written.')
    await w.advance(60000)
  }
  expect(w.compacts.length).toBe(0)
  expect(w.rowsOf('halt').length).toBe(1)
})

test('CR-F20: a continue answered { drop }: continue skipped:submit-failed', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  w.submitDrop = 'a Stop stands'
  await nudgedTurn($, w)
  expect(w.compacts.length).toBe(1)
  expect(w.rowsOf('continue').map(r => r.result)).toEqual(['submitted', 'skipped:submit-failed'])
})

/** A nudged turn ends; `meanwhile` runs after its end, before the 500-ms compaction and its continue. */
async function userFirst($: Engine, w: World, meanwhile: () => Promise<void>): Promise<string> {
  await w.userTurn($)
  w.tokens = 610000
  await w.tool($)
  await w.turnEnd($, 'Checkpoint: clean · Step 1: run the tests')
  await meanwhile()
  await w.advance(500)
  expect(w.compacts.length).toBe(1)
  return w.flag(w.callsOf('dispatch')[0], '--nonce') ?? ''
}

const PERSON = 'stop, use the staging database instead'
const isCont = (t: string) => t.includes(CONT)

test('AF-C1: a person\'s prompt entering before the continue: no continue, the block stays for that prompt\'s turn', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  const nonce = await userFirst($, w, async () => {
    await $.prompt.submit({ text: PERSON, origin: { kind: 'composer' } } as never)
  })
  expect(w.submits.filter(isCont)).toEqual([])
  expect(w.rowsOf('continue').map(r => r.result)).toEqual(['skipped:user-first'])
  expect(w.storeGet(`cont:${SID_A}`) ?? []).toEqual([])
  expect(w.claims.get(nonce)).toBeUndefined()
  await w.turnStart($, PERSON)
  const block = (await $.prompt.context({ blocks: [] })).blocks.find(b => b.name === `${w.name}-resume`)
  expect(block?.text.startsWith(`The ${w.name} plugin adds this after compaction`)).toBe(true)
  expect(w.claims.get(nonce)).toBe('prompt.context')
})

test('AF-C1: a main turn that started during the compaction: no continue', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  let open!: () => void
  await userFirst($, w, async () => {
    w.compactGate = new Promise<void>(r => { open = r })
  })
  await w.turnStart($, PERSON)
  open()
  await w.advance(10)
  // That turn's start already turned the continue off (resumeAfter): no row.
  expect(w.submits.filter(isCont)).toEqual([])
  expect(w.rowsOf('continue').map(r => r.result)).toEqual([])
})

test('AF-C2: a person\'s prompt entering after the continue\'s claim: our prompt.submit hook drops the continue (no await between check and drop); the block goes to that prompt\'s turn, the stamp is not spent', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  // Our own prompt.submit hook drops ours in this state (refuseOwnSubmit, unit test below); a hook beneath stands in for it here.
  w.dropIf = text => (isCont(text) ? 'a user prompt came first' : undefined)
  let release: (() => void) | undefined
  w.atHelper = async (sub, args) => {
    if (sub === 'claim' && args.includes('prompt.submit')) await new Promise<void>(r => { release = r })
  }
  await w.userTurn($)
  w.tokens = 610000
  await w.tool($)
  await w.turnEnd($, 'Checkpoint: clean · Step 1: run the tests')
  await w.advance(500)
  expect(release).toBeDefined()
  await $.prompt.submit({ text: PERSON, origin: { kind: 'composer' } } as never)
  release?.()
  await w.settle()
  const nonce = w.flag(w.callsOf('dispatch')[0], '--nonce') ?? ''
  expect(w.rowsOf('continue').map(r => r.result)).toEqual(['submitted', 'skipped:user-first'])
  expect(w.storeGet(`cont:${SID_A}`)).toEqual([])
  expect(w.claims.get(nonce)).toBe('prompt.submit')
  await w.turnStart($, PERSON)
  const block = (await $.prompt.context({ blocks: [] })).blocks.find(b => b.name === `${w.name}-resume`)
  expect(block?.text.startsWith(`The ${w.name} plugin adds this after compaction`)).toBe(true)
  expect(w.rowsOf('mod_outcome').find(r => r.nonce === nonce)?.resume).toBe('delivered:prompt.context')
})

test('AF-C2: refuseOwnSubmit covers the continue: refused while a main turn runs or a prompt of another is entering', () => {
  const s = newState('l')
  s.contSubmitting = true
  expect(refuseOwnSubmit(s)).toBe(false)
  promptEntering(s, 'composer')
  expect(refuseOwnSubmit(s)).toBe(true)
  promptNotEntered(s, 'composer')
  expect(refuseOwnSubmit(s)).toBe(false)
  s.mainTurnRunning = true
  expect(refuseOwnSubmit(s)).toBe(true)
  s.contSubmitting = false
  expect(refuseOwnSubmit(s)).toBe(false)
})

test('AT-B-06: 4 nudge-driven cycles within 50 min: 3 continues; the 4th capped at its nudged turn end, then the handoff turn, then one compaction, no continue', { options: { max_auto_continues_per_hour: 3 } }, async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  for (let i = 0; i < 4; i++) {
    if (i === 3) {
      await w.turnStart($)
      w.tokens = 610000
      expect((await w.tool($)).context?.[0]).toBe(halted(w, 'cap'))
      await w.turnEnd($)
      expect(w.rowsOf('continue_capped').length).toBe(1)
      expect(w.compacts.length).toBe(3)
      if (TURN) {
        await w.advance(2000)
        expect(w.submits.slice(3)).toEqual([handoffSubmit(w, 'cap')])
        await w.turnStart($, '')
        await w.turnEnd($, 'LINT stop.')
      }
      await w.advance(500)
      break
    }
    await nudgedTurn($, w)
    w.tokens = 100000
    await w.turnStart($, 'continue text')
    await w.turnEnd($)
    for (let q = 0; q < 2; q++) {
      await w.turnStart($)
      await w.turnEnd($)
    }
    await w.advance(10 * 60000)
  }
  expect(w.compacts.length).toBe(4)
  expect(w.submits.length).toBe(TURN ? 4 : 3)
  expect(w.submits.slice(0, 3).every(t => t.includes(CONT))).toBe(true)
  expect(w.rowsOf('thrash').length).toBe(0)
  expect(w.rowsOf('continue_capped').length).toBe(1)
  expect(w.rowsOf('halt')[0]?.reason).toBe('cap')
})

// S-SETTINGS A (owner 04:10): the default cap is 6 per rolling hour.
test('AT-CAP-01: default config, 7 nudge-driven cycles within 55 min: 6 continues; the 7th capped at its nudged turn end (halt cap, handoff turn, one compaction, no continue)', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  for (let i = 0; i < 7; i++) {
    if (i === 6) {
      await w.turnStart($)
      w.tokens = 610000
      expect((await w.tool($)).context?.[0]).toBe(halted(w, 'cap'))
      await w.turnEnd($)
      expect(w.rowsOf('continue_capped').length).toBe(1)
      expect(w.compacts.length).toBe(6)
      if (TURN) {
        await w.advance(2000)
        expect(w.submits.slice(6)).toEqual([handoffSubmit(w, 'cap')])
        await w.turnStart($, '')
        await w.turnEnd($, 'LINT stop.')
      }
      await w.advance(500)
      break
    }
    await nudgedTurn($, w)
    w.tokens = 100000
    await w.turnStart($, 'continue text')
    await w.turnEnd($)
    for (let q = 0; q < 2; q++) {
      await w.turnStart($)
      await w.turnEnd($)
    }
    await w.advance(8 * 60000)
  }
  expect(w.compacts.length).toBe(7)
  expect(w.submits.length).toBe(TURN ? 7 : 6)
  expect(w.submits.slice(0, 6).every(t => t.includes(CONT))).toBe(true)
  expect(w.rowsOf('thrash').length).toBe(0)
  expect(w.rowsOf('continue').filter(r => r.result === 'submitted').length).toBe(6)
  expect(w.rowsOf('halt')[0]?.reason).toBe('cap')
})

test('AT-B-07: two plugin compactions, each re-reaching target within 2 main turns: thrash + halt', { options: { precompact_turn: 'code' } }, async ($, on) => {
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

test('AT-B-09: a nudged turn that ends aborted: no continue', { options: { precompact_turn: 'code' } }, async ($, on) => {
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

test('AT-B-10: continue with the claim still free: fixed line + block, ≤9,800 chars (RP-4: BLOCK_MAX 9,500 + the fixed line), claim prompt.submit', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await nudgedTurn($, w)
  expect(w.submits.length).toBe(1)
  const text = w.submits[0] ?? ''
  expect(text.startsWith(`Note from the user's ${w.name} plugin: ${CONT}\n\nThe ${w.name} plugin adds this after compaction`)).toBe(true)
  expect(text.length <= 9800).toBe(true)
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

test('AT-B-13: halt mode: a turn end at 450K skips (halt); a tool call at 610K gets [halt]; that turn end starts a handoff turn', async ($, on) => {
  const w = new World().install(on)
  w.summaryMode = 'unshaped'
  await w.start($)
  await w.turnStart($)
  await raiseCompact($, { trigger: 'auto' })
  await raiseCompact($, { trigger: 'auto' })
  w.tokens = 450000
  await w.turnEnd($)
  expect(w.rowsOf('skip').map(r => r.why)).toEqual(['halt'])
  await w.advance(5000)
  expect(w.compacts.length).toBe(2)
  // A user turn clears halt; two more non-ok verdicts in it halt again, and its nudge is [halt].
  await w.turnStart($)
  await raiseCompact($, { trigger: 'auto' })
  await raiseCompact($, { trigger: 'auto' })
  w.tokens = 610000
  expect((await w.tool($)).context?.[0]).toBe(halted(w, '2-nonok'))
  await w.turnEnd($)
  await w.advance(5000)
  expect(w.submits).toEqual(TURN ? [handoffSubmit(w, '2-nonok')] : [])
  expect(w.rowsOf('skip').map(r => r.why)).toEqual(TURN ? ['halt'] : ['halt', 'halt'])
  expect(w.compacts.length).toBe(4)
})

test('halt mode survives a reload (halt.json) until a user-typed turn clears it', async ($, on) => {
  const w = new World().install(on)
  w.files.set(`${WATCH}/${SID_A}/halt.json`, JSON.stringify({ active: true, reason: 'thrash' }))
  await w.start($)
  w.tokens = 410000
  await raiseCompact($, { trigger: 'auto', agentId: undefined })
  await $.turn.complete({ answer: 'x', durationMs: 1, isAborted: false, turnId: 't0', reason: 'answer' })
  expect(w.rowsOf('skip').map(r => r.why)).toEqual(['halt'])
  await w.userTurn($)
  expect(w.rowsOf('halt').map(r => r.active)).toEqual([false])
})

/**
 * Halt on, a task notification's turn running: a prompt of `origin` is queued over it (typed
 * mid-turn, `turnId` set) and starts its own turn after it ends (xxxxxxxx 2026-10-30 04:36).
 */
async function queuedTurn($: Engine, w: World, origin: { kind: string; name?: string }): Promise<void> {
  w.files.set(`${WATCH}/${SID_A}/halt.json`, JSON.stringify({ active: true, reason: '2-nonok' }))
  w.storeSet(`cont:${SID_A}`, [T0 - 1000, T0 - 500])
  await w.start($)
  await w.userTurn($, 'Background task finished.', 'task-notification')
  await $.prompt.submit({ text: 'look at the failing spec', origin, turnId: 't1', wait: false } as never)
  await w.turnEnd($)
  await w.turnStart($, 'look at the failing spec')
}

test('AF-B1: halt on; a person\'s prompt queued while a turn runs starts its own turn after it: halt clears and the continue stamps reset', async ($, on) => {
  const w = new World().install(on)
  await queuedTurn($, w, { kind: 'composer' })
  expect(w.rowsOf('halt').map(r => [r.reason, r.active])).toEqual([['2-nonok', false]])
  expect(w.files.get(`${WATCH}/${SID_A}/halt.json`)).toContain('"active":false')
  expect(w.storeGet(`cont:${SID_A}`)).toEqual([])
})

for (const origin of [{ kind: 'task-notification' }, { kind: 'plugin', name: 'other' }]) {
  test(`AF-B2: halt on; a ${origin.kind} prompt queued mid-turn that starts its own turn leaves halt on`, async ($, on) => {
    const w = new World().install(on)
    await queuedTurn($, w, origin)
    expect(w.rowsOf('halt')).toEqual([])
    expect(w.files.get(`${WATCH}/${SID_A}/halt.json`)).toContain('"active":true')
    expect(w.storeGet(`cont:${SID_A}`)).toEqual([T0 - 1000, T0 - 500])
  })
}

test('AT-M2-03: $.session.compact rejects: compact_rejected, busy released, no timer; the next turn end schedules again', { options: { precompact_turn: 'code' } }, async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await w.turnStart($)
  w.tokens = 410000
  w.compactMode = 'reject'
  await w.turnEnd($)
  await w.advance(2000)
  // The row carries the rejection's text as the engine gave it (one line, ≤160 chars) and its class.
  const rej = w.rowsOf('compact_rejected')[0]
  const error = typeof rej?.error === 'string' ? rej.error : ''
  expect([error.length > 0, error.length <= 160, error.includes('\n'), rej?.error_class]).toEqual([true, true, false, rejectClass(error)])
  expect(w.rowsOf('headless').length).toBe(0)
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
  // P5-FOLD A3: disabled, so the thresholds are null and the computed values are the raw fields.
  expect([eff?.soft_max, eff?.target, eff?.soft_max_raw, eff?.target_raw]).toEqual([null, null, 51000, 34000])
  expect([eff?.disabled, eff?.small_window, eff?.min_window]).toEqual(['trigger-disabled-small-window', true, 329000])
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

test('AT-Q-08 (mod part): queue_cmd set: the nudge keeps [queue] with @queue_add@ naming this cycle\'s compaction nonce; unset: dropped', { options: { queue_cmd: '/q/bin/queue' } }, async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await w.turnStart($)
  w.tokens = 610000
  const r = await w.tool($)
  await w.turnEnd($)
  await w.advance(500)
  const nonce = w.flag(w.callsOf('dispatch')[0], '--nonce') ?? ''
  const queueAdd = storeWord(w.root, w.name) + ` queue-add --sid ${SID_A} --nonce ${nonce}`
  expect(r.context?.[0]).toBe(assemble(w.name, 'checkpoint-nudge', ['continue', 'queue'], { tokens: '610,000', queue_add: queueAdd }))
  if (assetText('checkpoint-nudge', w.name).includes('@queue_add@')) expect(r.context?.[0]).toContain(queueAdd)
  // The mod itself never runs the queue tool or queue-add (OD-21 as amended by D-10).
  expect(w.callsOf('queue-add').length).toBe(0)
})

test('AT-Q-08 (mod part): queue_cmd unset: the nudge has no [queue] line', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await w.turnStart($)
  w.tokens = 610000
  expect((await w.tool($)).context?.[0]).toBe(assemble(w.name, 'checkpoint-nudge', ['continue'], { tokens: '610,000' }))
})

test('AT-P5-07 (row): window 100000: config_effective has null thresholds, raw -49000 / -32667, min_window 329000; triggers off still computes them', async ($, on) => {
  const w = new World({ window: 100000 }).install(on)
  await w.start($)
  const eff = w.rowsOf('config_effective')[0]
  expect([eff?.soft_max, eff?.target, eff?.soft_max_raw, eff?.target_raw, eff?.disabled, eff?.small_window, eff?.min_window])
    .toEqual([null, null, -49000, -32667, 'trigger-disabled-small-window', true, 329000])
  expect(eff?.clamped).toEqual(['soft_max', 'target'])
})

test('AT-P5-07 (row, triggers off): small_window, min_window and the clamped list are computed as with triggers on', { options: { triggers: false } }, async ($, on) => {
  const w = new World({ window: 100000 }).install(on)
  await w.start($)
  const eff = w.rowsOf('config_effective')[0]
  expect([eff?.disabled, eff?.small_window, eff?.min_window, eff?.soft_max, eff?.soft_max_raw]).toEqual(['triggers-off', true, 329000, null, -49000])
  expect(eff?.clamped).toEqual(['soft_max', 'target'])
  expect(w.rowsOf('triggers_off').length).toBe(1)
})

test('AT-P5-07 (row): native_window_tokens 50000 counts as 100000, with one config_clamped', { options: { native_window_tokens: 50000 } }, async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  expect(w.rowsOf('config_effective')[0]?.window).toBe(100000)
  expect(w.rowsOf('config_clamped').filter(r => r.key === 'native_window_tokens').map(r => [r.configured, r.effective])).toEqual([[50000, 100000]])
})

// DP-30 (4): `compacted.ms` has one definition on every path: from the dispatch record written
// (or reused) to the compaction's answer, as on the mod-hook path.
test('DP-30 (4): a dispatch write that takes 250 ms is not in compacted.ms, on the mod-self path as on the mod-hook path', { options: { precompact_turn: 'code' } }, async ($, on) => {
  const w = new World().install(on)
  w.atHelper = async (sub) => {
    if (sub === 'dispatch') await w.clock.set(w.clock.now() + 250)
  }
  await w.start($)
  await w.turnStart($)
  w.tokens = 410000
  await w.turnEnd($)
  await w.advance(2000)
  await raiseCompact($, { trigger: 'manual' })
  const rows = w.rowsOf('compacted')
  expect(rows.length).toBe(2)
  expect(rows.map(r => r.ms)).toEqual([0, 0])
})

// ID-4 (owner D2, 2026-10-23; SPEC-DELTAS AT-ID-04; REVIEW-NIGHT-2 test gap): after a compaction the
// plugin did not start (native auto, manual, or a future idle trigger) it submits nothing on its own;
// only a nudge-driven cycle sets resumeAfter. A background result can still open a turn of its own.
test('AT-ID-04: after a native auto, manual or idle compaction the plugin submits nothing and logs no continue', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await w.userTurn($)
  await w.turnEnd($)
  for (const trigger of ['auto', 'manual', 'idle']) {
    await raiseCompact($, { trigger })
    await w.advance(60000)
  }
  expect(w.compacts.length).toBe(3)
  expect(w.submits.length).toBe(0)
  expect(w.rowsOf('continue').length).toBe(0)
})
