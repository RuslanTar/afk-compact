// U tests through the kit: the pending resume block across a restart (since 0.1.1). The
// after-step persists the block as
// `<watch>/<sid>/resume-pending.json`; a session end other than `/clear` keeps it; the classic
// SessionStart(resume) renames it to `resume-armed.json` (helper case AT-RP-04); the first
// prompt.context of the same session id in a load delivers it once, built again by that load and
// re-measured past 600 s. A newer compaction, the load's first turn end and /clear settle a record
// that was not taken, so it never reaches a later turn or process.
import { expect, test } from 'claude-code/testing'
import { hasTag } from '../../hooks/lib/assemble'
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

/** A record with a `block` text, as an older build wrote it: the text is never sent. */
function withText(rec: string, nonce = 'ab0c0001'): string {
  return JSON.stringify({ ...(JSON.parse(rec) as Record<string, unknown>), block: 'STORED BLOCK ' + nonce }) + '\n'
}

/** A seeded record with other block arguments. */
function seededWith(ageS: number, args: Record<string, unknown>): string {
  const j = JSON.parse(seeded(ageS)) as Record<string, unknown>
  return JSON.stringify({ ...j, args: { ...(j.args as Record<string, unknown>), ...args } }) + '\n'
}

test('AT-RP-01: a main compaction persists its pending block; a session end other than /clear keeps it, with no mod_outcome row', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await w.turnStart($)
  await raiseCompact($, { trigger: 'auto' })
  const nonce = w.flag(w.callsOf('dispatch')[0], '--nonce')
  const rec = json(w, PENDING)
  expect(rec).toMatchObject({ v: 1, state: 'pending', session_id: SID_A, nonce })
  // The facts the block is built from, not its text.
  expect(typeof rec?.remeasure).toBe('string')
  expect(rec?.block).toBeUndefined()
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
  const nonce = String(json(w, PENDING)?.nonce)
  const measures = w.callsOf('measure').length
  // In-process /resume to another session and back (the same path a new process takes).
  await $.session.end(SWITCH as never)
  w.sid = SID_B
  await $.prompt.context({ blocks: [] })
  w.sid = SID_A
  arm(w)
  await w.advance(30 * 1000)
  const ctx = await $.prompt.context({ blocks: [] })
  // Built again from the stored measure: no new helper measure, the compaction's own facts.
  expect(blockOf(w, ctx)).toContain('3f9c2e1')
  expect(blockOf(w, ctx)).toContain(SID_A)
  expect(w.callsOf('measure').length).toBe(measures)
  expect(w.flag(w.callsOf('claim')[0], '--nonce')).toBe(nonce)
  expect(w.callsOf('claim').map(c => w.flag(c, '--channel'))).toEqual(['prompt.context'])
  expect(w.rowsOf('mod_outcome').map(r => r.resume)).toEqual(['delivered:prompt.context'])
  expect(json(w, ARMED)).toMatchObject({ state: 'settled', resume: 'delivered:prompt.context' })
  expect(json(w, ARMED)?.block).toBeUndefined()
  const again = await $.prompt.context({ blocks: [] })
  expect(again.blocks.length).toBe(0)
  expect(w.rowsOf('mod_outcome').length).toBe(1)
})

test('AT-RP-02: a new load (claude --resume) delivers an armed block built 60 s ago from its stored facts, with its outcome', async ($, on) => {
  const w = new World()
  w.files.set(ARMED, withText(seeded(60)))
  w.install(on)
  await w.start($)
  await w.userTurn($)
  const measures = w.callsOf('measure').length
  const ctx = await $.prompt.context({ blocks: [] })
  const block = blockOf(w, ctx) ?? ''
  // This load's text and <store> path, the stored measure and its stamp; never an older version's text.
  expect(block).toContain('1a1a1a1')
  expect(block).toContain(SAVED)
  expect(w.root).not.toBe('')
  expect(block).toContain(`${w.root}/scripts/`)
  expect(block).not.toContain('STORED BLOCK')
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

test('AT-RP-05: a compaction of the resumed load before its first prompt replaces the armed block: only the new one goes out, the old one is settled', async ($, on) => {
  const w = new World()
  w.files.set(ARMED, seeded(60))
  w.install(on)
  await w.start($)
  await raiseCompact($, { trigger: 'manual' })
  const n2 = w.flag(w.callsOf('dispatch')[0], '--nonce')
  expect(json(w, ARMED)).toMatchObject({ state: 'settled', nonce: 'ab0c0001', resume: 'undelivered' })
  await w.userTurn($)
  const first = await $.prompt.context({ blocks: [] })
  expect(blockOf(w, first)).toContain(SID_A)
  await w.turnEnd($)
  await w.userTurn($)
  const second = await $.prompt.context({ blocks: [] })
  expect(second.blocks.length).toBe(0)
  expect(w.callsOf('claim').map(c => w.flag(c, '--nonce'))).toEqual([n2])
  expect(w.rowsOf('mod_outcome').map(r => [r.nonce, r.resume])).toEqual([['ab0c0001', 'undelivered'], [n2, 'delivered:prompt.context']])
  // A later resume (the helper arms nothing settled) has nothing to deliver.
  await $.session.end(EXIT as never)
  arm(w)
  await $.prompt.context({ blocks: [] })
  const later = await $.prompt.context({ blocks: [] })
  expect(later.blocks.length).toBe(0)
  expect(w.rowsOf('mod_outcome').length).toBe(2)
})

test('AT-RP-05: armed after the load\'s first prompt.context: the first turn end settles it, so no later turn or resume gets it', async ($, on) => {
  const w = new World()
  w.files.set(PENDING, seeded(60))
  w.install(on)
  await w.start($)
  await w.userTurn($)
  const c1 = await $.prompt.context({ blocks: [] })
  arm(w)
  await w.turnEnd($)
  expect(c1.blocks.length).toBe(0)
  expect(json(w, ARMED)).toMatchObject({ state: 'settled', nonce: 'ab0c0001', resume: 'undelivered' })
  expect(w.rowsOf('mod_outcome').map(r => [r.nonce, r.resume])).toEqual([['ab0c0001', 'undelivered']])
  await $.session.end(EXIT as never)
  const c2 = await $.prompt.context({ blocks: [] })
  expect(c2.blocks.length).toBe(0)
  expect(w.callsOf('claim').length).toBe(0)
})

test('AT-RP-05: a turn end keeps the block of a compaction inside that turn pending for the next one', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await w.turnStart($)
  await raiseCompact($, { trigger: 'auto' })
  const nonce = w.flag(w.callsOf('dispatch')[0], '--nonce')
  await w.turnEnd($)
  expect(json(w, PENDING)).toMatchObject({ state: 'pending', nonce })
  expect(w.rowsOf('mod_outcome')).toEqual([])
})

test('AT-RP-06: /clear before the resumed load\'s first prompt drops the armed block of the old session id', async ($, on) => {
  const w = new World()
  w.files.set(ARMED, seeded(60))
  w.install(on)
  await w.start($)
  await $.session.end(CLEAR as never)
  expect(w.rowsOf('mod_outcome').map(r => [r.nonce, r.resume])).toEqual([['ab0c0001', 'dropped:session-end']])
  expect(json(w, ARMED)).toMatchObject({ state: 'settled', resume: 'dropped:session-end' })
  expect(json(w, ARMED)?.remeasure).toBeUndefined()
})

test('AT-RP-06: a session end after another channel delivered the block settles its record with that channel', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await raiseCompact($, { trigger: 'manual' })
  const nonce = String(w.flag(w.callsOf('dispatch')[0], '--nonce'))
  // The classic SessionStart(compact) won the claim.
  w.claims.set(nonce, 'sessionstart')
  w.files.set(`${WATCH}/${SID_A}/resume-claimed/${nonce}`, 'sessionstart')
  await $.session.end(EXIT as never)
  expect(w.rowsOf('mod_outcome').map(r => [r.nonce, r.resume])).toEqual([[nonce, 'delivered:sessionstart']])
  expect(json(w, PENDING)).toMatchObject({ state: 'settled', resume: 'delivered:sessionstart' })
})

test('AT-RP-07: a compaction while the first prompt.context reads the armed record keeps the new block (the read never clears it)', async ($, on) => {
  const w = new World()
  let release: () => void = () => undefined
  const gate = new Promise<void>(r => {
    release = r
  })
  let identCalls = 0
  w.atHelper = async sub => {
    if (sub === 'ident' && ++identCalls === 1) await gate
  }
  w.install(on)
  const pc = $.prompt.context({ blocks: [] })
  await w.settle()
  await raiseCompact($, { trigger: 'auto' })
  const n2 = w.flag(w.callsOf('dispatch')[0], '--nonce')
  release()
  const ctx = await pc
  expect(blockOf(w, ctx)).toContain(SID_A)
  expect(w.rowsOf('mod_outcome').map(r => [r.nonce, r.resume])).toEqual([[n2, 'delivered:prompt.context']])
  expect(json(w, PENDING)).toMatchObject({ state: 'settled', nonce: n2 })
})

// Claude Code 2.1.322 on `claude --resume`: the engine builds the first message's context at
// start-up, so prompt.context is raised beside session.start, and a context breakdown
// (`$.session.usage({ breakdown })`) waits for that build (its memory-file rows read the
// instruction files the build resolves), which waits for every prompt.context hook.

/** The compaction window of the breakdown, apart from the World's usage window (1,000,000). */
const BREAKDOWN = { rawMaxTokens: 800000, autocompactSource: 'model-default' }

test('BG-RESUME-01: a resumed load\'s first prompt.context, raised before session.start read the thresholds, settles: the hook never awaits the breakdown that waits for its own context', async ($, on) => {
  const w = new World()
  w.files.set(ARMED, seeded(60))
  w.install(on)
  w.breakdown = BREAKDOWN
  let ctx: { blocks: readonly { name: string; text: string }[] } | undefined
  const pc = $.prompt.context({ blocks: [] })
  w.atBreakdown = () => pc
  void pc.then(c => {
    ctx = c
  })
  await w.settle()
  expect(ctx).toBeDefined()
  // The armed block still goes out with that context, once.
  expect(blockOf(w, ctx ?? { blocks: [] })).toContain('1a1a1a1')
  await w.start($)
  await w.settle()
  expect(w.rowsOf('mod_outcome').map(r => [r.nonce, r.resume])).toEqual([['ab0c0001', 'delivered:prompt.context']])
  // The thresholds still come from the breakdown, read once that context was built: one row.
  expect(w.rowsOf('config_effective').map(r => [r.window, r.window_from])).toEqual([[800000, 'breakdown']])
})

test('BG-RESUME-01: session.start first, its threshold read waiting on the context build: the first prompt.context and then session.start settle', async ($, on) => {
  const w = new World().install(on)
  w.breakdown = BREAKDOWN
  let built: () => void = () => undefined
  const building = new Promise<void>(r => {
    built = r
  })
  w.atBreakdown = () => building
  let started = false
  void w.start($).then(() => {
    started = true
  })
  await w.settle()
  let settled = false
  void $.prompt.context({ blocks: [] }).then(() => {
    settled = true
    built()
  })
  await w.settle()
  expect(settled).toBe(true)
  expect(started).toBe(true)
  expect(w.rowsOf('config_effective').map(r => [r.window, r.window_from])).toEqual([[800000, 'breakdown']])
})

test('BG-RESUME-02: session.start first on a resume, its threshold read waiting on the context build: the first prompt.context builds the restored idle block only after halt.json was read ([idle-halt])', async ($, on) => {
  const w = new World()
  w.files.set(`${WATCH}/${SID_A}/halt.json`, JSON.stringify({ active: true, reason: 'thrash' }))
  w.files.set(ARMED, seededWith(60, { idle: true }))
  w.install(on)
  w.breakdown = BREAKDOWN
  let built: () => void = () => undefined
  const building = new Promise<void>(r => {
    built = r
  })
  w.atBreakdown = () => building
  let started = false
  void w.start($).then(() => {
    started = true
  })
  await w.settle()
  let ctx: { blocks: readonly { name: string; text: string }[] } | undefined
  void $.prompt.context({ blocks: [] }).then(c => {
    ctx = c
    built()
  })
  await w.settle()
  expect(ctx).toBeDefined()
  expect(started).toBe(true)
  const block = blockOf(w, ctx ?? { blocks: [] }) ?? ''
  expect(block).toContain(SID_A)
  // Halt mode the earlier process left: the restored idle block stops after the background result.
  if (hasTag('resume-context', 'idle-halt')) expect(block).toContain('handle it, then stop and wait for the user')
  expect(w.rowsOf('mod_outcome').map(r => [r.nonce, r.resume])).toEqual([['ab0c0001', 'delivered:prompt.context']])
})

for (const ageS of [60, 700]) {
  test(`AT-RP-08: a restored block keeps [prod-allow] only when this load's option allows it (built ${ageS} s ago)`, async ($, on) => {
    const w = new World()
    w.files.set(ARMED, seededWith(ageS, { prodAllow: true }))
    w.install(on)
    await w.start($)
    await w.userTurn($)
    const block = blockOf(w, await $.prompt.context({ blocks: [] })) ?? ''
    expect(block).not.toContain('your setting allows it')
    expect(block).toContain('production or self-modifying actions')
  })
}

/** Raise a classic hook event the way the engine does (the mod's observe-only hooks). */
async function classic($: unknown, ev: 'Stop' | 'UserPromptSubmit', e: Record<string, unknown>): Promise<void> {
  await ($ as { classic: Record<string, (e: unknown) => Promise<unknown>> }).classic[ev]?.(e)
}

const AUTO_LINE = "Auto mode: its classifier blocks a force-push, history rewrite, branch or tag delete or external write that step 4's approval covers"

// The 0.1.2 classifier probe: in auto permission mode a carried approval
// does not pass the classifier, so the block keeps [auto-mode] (ask first); the mode is the newest
// main hook input's (restart.ts noteMode), and the record keeps it for a block restored later.
for (const mode of ['auto', 'default'] as const) {
  test(`auto mode: a compaction after a main prompt in ${mode} mode ${mode === 'auto' ? 'keeps' : 'has no'} [auto-mode] (block and record)`, async ($, on) => {
    const w = new World().install(on)
    await w.start($)
    await classic($, 'UserPromptSubmit', { prompt: 'x', permission_mode: mode })
    await w.settle()
    await w.turnStart($)
    await raiseCompact($, { trigger: 'auto' })
    // The record before delivery (delivery settles it).
    expect(json(w, PENDING)).toMatchObject({ state: 'pending' })
    expect((json(w, PENDING)?.args as Record<string, unknown> | undefined)?.autoMode).toBe(mode === 'auto' ? true : undefined)
    const block = blockOf(w, await $.prompt.context({ blocks: [] })) ?? ''
    expect(block).toContain('Approvals: act on one the summary records')
    expect(block.includes(AUTO_LINE)).toBe(mode === 'auto')
  })
}

for (const seen of [undefined, 'acceptEdits'] as const) {
  test(`auto mode: a restored block recorded in auto mode ${seen === undefined ? 'keeps [auto-mode] while this load has seen no main mode' : 'drops [auto-mode] once this load saw ' + seen}`, async ($, on) => {
    const w = new World()
    w.files.set(ARMED, seededWith(60, { autoMode: true }))
    w.install(on)
    await w.start($)
    if (seen !== undefined) {
      await classic($, 'UserPromptSubmit', { prompt: 'x', permission_mode: seen })
      await w.settle()
    }
    await w.userTurn($)
    const block = blockOf(w, await $.prompt.context({ blocks: [] })) ?? ''
    expect(block).toContain('Approvals: act on one the summary records')
    expect(block.includes(AUTO_LINE)).toBe(seen === undefined)
  })
}
