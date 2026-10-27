// U tests through the kit: the pending resume block across a restart (owner 2026-10-27 "Fix in
// 0.1.1", VERSION-REFRESH tier 1 gap). The after-step persists the block as
// `<watch>/<sid>/resume-pending.json`; a session end other than `/clear` keeps it; the classic
// SessionStart(resume) renames it to `resume-armed.json` (helper case AT-RP-04); the first
// prompt.context of the same session id in a load delivers it once, re-measured past 600 s.
import { expect, test } from 'claude-code/testing'
import type { PendingResume } from '../../hooks/lib/deps'
import { ARMED_FILE, PENDING_FILE, pendingRecord } from '../../hooks/lib/resume'
import { SID_A, SID_B, T0, WATCH, World, raiseCompact } from './harness.test'

const PENDING = `${WATCH}/${SID_A}/${PENDING_FILE}`
const ARMED = `${WATCH}/${SID_A}/${ARMED_FILE}`
const EXIT = { reason: 'prompt_input_exit', sessionId: SID_A, resume: { id: SID_A } }
const SWITCH = { reason: 'resume', sessionId: SID_A, resume: { id: SID_A } }
const CLEAR = { reason: 'clear', sessionId: SID_A, resume: { id: SID_A } }
const SAVED = '~/.claude/handoffs/r/LAB-42/compact/2026-10-21_14-05-12_5e55a001_c1-ab0c00.md'

const json = (w: World, path: string): Record<string, unknown> | undefined => {
  const t = w.files.get(path)
  return t === undefined ? undefined : (JSON.parse(t) as Record<string, unknown>)
}
const blockOf = (w: World, ctx: { blocks: readonly { name: string; text: string }[] }): string | undefined =>
  ctx.blocks.find(b => b.name === `${w.name}-resume`)?.text

/** What the classic SessionStart(resume) does to the record (helper case AT-RP-04). */
function arm(w: World, sid = SID_A): void {
  const from = `${WATCH}/${sid}/${PENDING_FILE}`
  const t = w.files.get(from)
  if (t === undefined) return
  w.files.delete(from)
  w.files.set(`${WATCH}/${sid}/${ARMED_FILE}`, t)
}

/** An armed record as an earlier process left it: built `ageS` seconds before T0. */
function seeded(ageS: number, sid = SID_A, nonce = 'ab0c0001'): string {
  const p: PendingResume = {
    sid, nonce, block: 'STORED BLOCK ' + nonce, builtAt: T0 - ageS * 1000, measuredAt: T0 - ageS * 1000, resumePref: 'prompt.context', turnSeq: 3,
    args: { nonce, midturn: false, nonok: false, savedCopy: SAVED, prodAllow: false },
    remeasure: 'Git: main @ 1a1a1a1, 0 modified, 0 untracked', outcome: { nudged: true, continued: false, halt: false },
  }
  return JSON.stringify(pendingRecord(p, 'f0e1d2c3')) + '\n'
}

test('AT-RP-01: a main compaction persists its pending block; a session end other than /clear keeps it, with no mod_outcome row', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await w.turnStart($)
  await raiseCompact($, { trigger: 'auto' })
  const nonce = w.flag(w.callsOf('dispatch')[0], '--nonce')
  const rec = json(w, PENDING)
  expect(rec).toMatchObject({ v: 1, state: 'pending', session_id: SID_A, nonce })
  expect(typeof rec?.block).toBe('string')
  expect(rec?.built_at).toBe(T0)
  await $.session.end(EXIT as never)
  expect(w.rowsOf('mod_outcome')).toEqual([])
  expect(json(w, PENDING)?.state).toBe('pending')
})

test('AT-RP-01: /clear drops the persisted block (dropped:session-end) and the record keeps no block text', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await raiseCompact($, { trigger: 'manual' })
  await $.session.end(CLEAR as never)
  w.sid = SID_B
  expect(w.rowsOf('mod_outcome').map(r => r.resume)).toEqual(['dropped:session-end'])
  const rec = json(w, PENDING)
  expect(rec).toMatchObject({ state: 'settled', session_id: SID_A, resume: 'dropped:session-end' })
  expect(rec?.block).toBeUndefined()
  // Even if the old record were armed, the new session id never matches it.
  arm(w)
  const ctx = await $.prompt.context({ blocks: [] })
  expect(ctx.blocks.length).toBe(0)
})

test('AT-RP-02: back to the same session id after a session end: the first prompt.context delivers the armed block once, then it is settled', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await w.turnStart($)
  await raiseCompact($, { trigger: 'auto' })
  const stored = String(json(w, PENDING)?.block)
  // In-process /resume to another session and back (the same path a new process takes).
  await $.session.end(SWITCH as never)
  w.sid = SID_B
  await $.prompt.context({ blocks: [] })
  w.sid = SID_A
  arm(w)
  await w.advance(30 * 1000)
  const ctx = await $.prompt.context({ blocks: [] })
  expect(blockOf(w, ctx)).toBe(stored)
  expect(w.callsOf('claim').map(c => w.flag(c, '--channel'))).toEqual(['prompt.context'])
  expect(w.rowsOf('mod_outcome').map(r => r.resume)).toEqual(['delivered:prompt.context'])
  expect(json(w, ARMED)).toMatchObject({ state: 'settled', resume: 'delivered:prompt.context' })
  expect(json(w, ARMED)?.block).toBeUndefined()
  const again = await $.prompt.context({ blocks: [] })
  expect(again.blocks.length).toBe(0)
  expect(w.rowsOf('mod_outcome').length).toBe(1)
})

test('AT-RP-02: a new load (claude --resume) delivers an armed block built 60 s ago as stored, with its outcome', async ($, on) => {
  const w = new World()
  w.files.set(ARMED, seeded(60))
  w.install(on)
  await w.start($)
  await w.userTurn($)
  const measures = w.callsOf('measure').length
  const ctx = await $.prompt.context({ blocks: [] })
  expect(blockOf(w, ctx)).toBe('STORED BLOCK ab0c0001')
  expect(w.callsOf('measure').length).toBe(measures)
  expect(w.rowsOf('mod_outcome').map(r => [r.nonce, r.nudged, r.resume])).toEqual([['ab0c0001', true, 'delivered:prompt.context']])
  expect(json(w, ARMED)?.state).toBe('settled')
})

test('AT-RP-02: an armed block older than 600 s is re-measured at delivery (resume_remeasured)', async ($, on) => {
  const w = new World()
  w.files.set(ARMED, seeded(700))
  w.install(on)
  w.measureBlock = 'Git: main @ 9e9e9e9, 2 modified, 0 untracked\nIn flight: none listed\nEvidence: none'
  await w.start($)
  await w.userTurn($)
  const ctx = await $.prompt.context({ blocks: [] })
  const block = blockOf(w, ctx) ?? ''
  expect(block).toContain('9e9e9e9')
  expect(block).not.toContain('STORED BLOCK')
  const m = w.callsOf('measure')
  expect(w.flag(m[m.length - 1], '--nonce')).toBe('ab0c0001')
  expect(m[m.length - 1]?.args).toContain('--copy=' + SAVED)
  expect(w.rowsOf('resume_remeasured').map(r => [r.nonce, r.age_s])).toEqual([['ab0c0001', 700]])
})

test('AT-RP-03: nothing is delivered without the resume (not armed), to another session id (/clear, fork), or when another channel claimed it', async ($, on) => {
  const w = new World()
  // Not armed: the record of a session that never resumed.
  w.files.set(PENDING, seeded(60))
  // Armed under SID_B but naming SID_A (a copied folder): not this session's.
  w.files.set(`${WATCH}/${SID_B}/${ARMED_FILE}`, seeded(60, SID_A, 'ab0c0002'))
  w.install(on)
  await w.start($)
  let ctx = await $.prompt.context({ blocks: [] })
  expect(ctx.blocks.length).toBe(0)
  w.sid = SID_B
  ctx = await $.prompt.context({ blocks: [] })
  expect(ctx.blocks.length).toBe(0)
  expect(w.callsOf('claim').length).toBe(0)
  expect(w.rowsOf('mod_outcome')).toEqual([])
})

test('AT-RP-03: an armed block another process already claimed adds nothing and is settled', async ($, on) => {
  const w = new World()
  w.files.set(ARMED, seeded(60))
  w.install(on)
  w.claims.set('ab0c0001', 'prompt.context')
  await w.start($)
  const ctx = await $.prompt.context({ blocks: [] })
  expect(ctx.blocks.length).toBe(0)
  expect(json(w, ARMED)?.state).toBe('settled')
})

test('AT-RP-03: a block a turn already took is settled on disk, so a later resume has nothing to arm', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await w.turnStart($)
  await raiseCompact($, { trigger: 'auto' })
  await $.prompt.context({ blocks: [] })
  expect(json(w, PENDING)).toMatchObject({ state: 'settled', resume: 'delivered:prompt.context' })
  // A newer compaction replaces the record; the one before it was settled first.
  await w.turnEnd($)
  await w.turnStart($)
  await raiseCompact($, { trigger: 'auto' })
  expect(json(w, PENDING)).toMatchObject({ state: 'pending', nonce: w.flag(w.callsOf('dispatch')[1], '--nonce') })
})
