// U tests through the kit: idle compaction and the pre-idle handoff turn (IC-1; MOD-SPEC §2.5
// idle rule, §3.4 delivery rule, §9 halt and /clear guards, §9.4). Cases that run the pre-idle
// turn need the `[submit-idle]` lines of handoff-turn.txt; a build without them answers
// `no-asset`, and those cases check that instead.
import { expect, test as kitTest } from 'claude-code/testing'
import type { Engine, TestBody, TestOptions } from 'claude-code/testing'
import type { Tag } from '../../hooks/lib/assemble'
import { assemble, hasTag } from '../../hooks/lib/assemble'
import { storeWord } from '../../hooks/lib/deps'
import { maxCalls, submitText } from '../../hooks/lib/handoff-turn'
import { isoLocal } from '../../hooks/lib/log'
import { HOME, SID_A, SID_B, T0, WATCH, World, markerNonce, raiseCompact } from './harness.test'

const IDLE = hasTag('handoff-turn', 'submit-idle')
// IA-1..3 (idle D3, owner 2026-10-23 02:4x): `auto` arms the pre-idle turn only while Claude
// Code's own idle compaction is off, read from the settings (`idleCompaction`, `autoCompactEnabled`).
const ON = { idle_handoff_turn: 'auto', precompact_turn: 'code' }

/**
 * A kit test with `idle_digest: submit` unless its options name a value: the `[idle]` cases here
 * pin the line as built for `submit` and `return`; owner rule (c) (2026-10-28) makes `off` the
 * default of 0.1.1, whose `[idle-off]` line lane.test.ts covers.
 */
function test(name: string, ...rest: readonly [TestBody] | readonly [TestOptions, TestBody]): void {
  const [o, body]: [TestOptions, TestBody] = rest.length === 1 ? [{}, rest[0]] : [rest[0], rest[1]]
  kitTest(name, { ...o, options: { idle_digest: 'submit', ...o.options } }, body)
}
// IDLE-COMPACT D2: with `"idleCompaction": false` at 200K and more the plugin's own idle
// compaction replaces the 49-min turn; the turn's own cases switch it off (`idle_compact: off`).
const TURN = { ...ON, idle_compact: 'off' }
// Lane B (owner Q2): with native idle on and silent, the 55.5-min check compacts at 200K and more
// instead of running the turn; the check's turn cases switch the plugin's compaction off the same way.
const NATIVE_OFF: Record<string, unknown> = { idleCompaction: false }
const MIN = 60000
// D15: only a five-hour or seven-day window shows the one-hour cache.
const LIMITS = [{ kind: 'five_hour', percentUsed: 12 }, { kind: 'seven_day', percentUsed: 30 }]
const PUBLISHED = HOME + '/.claude/handoffs/r/LAB-42/2026-10-21_15-00-00_5e55a001_handoff.md'
const SHOWN = '~/.claude/handoffs/r/LAB-42/2026-10-21_15-00-00_5e55a001_handoff.md'

const idleText = (w: World, min = '49'): string | undefined =>
  submitText(w.name, 'idle', { max_calls: String(maxCalls()), idle_min: min, store: storeWord(w.root, w.name) ?? '' })
const idleSkips = (w: World) => w.rowsOf('handoff_skipped').filter(r => r.reason === 'idle').map(r => r.why)
const dispatchFlag = (w: World, i: number, k: string) => w.flag(w.callsOf('dispatch')[i], k)
const hasIdleFlag = (w: World, i: number) => (w.callsOf('dispatch')[i]?.args ?? []).includes('--idle=true')

/** A person's turn that ends `answer` at `tokens` (an idle episode starts at its end). */
async function humanTurn($: Engine, w: World, tokens = 260000, answer = 'Done with that step.'): Promise<void> {
  await w.userTurn($)
  w.tokens = tokens
  await w.turnEnd($, answer)
}

// ---- IC-1 D1: the idle predicate on the dispatch

test('AT-IC-01: auto, no turn, no prompt entering, gap 1,600 s → idle (no [midturn]); 1,400 s → not idle', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await humanTurn($, w, 150000)
  await w.advance(1600 * 1000)
  await raiseCompact($, { trigger: 'auto' })
  expect([hasIdleFlag(w, 0), dispatchFlag(w, 0, '--midturn'), w.callsOf('dispatch')[0]?.args.includes('--idle-gap-s=1600')]).toEqual([true, 'false', true])
  expect(w.compacts[0]?.instructions).not.toContain('This began mid-turn')
  await humanTurn($, w, 150000)
  await w.advance(1400 * 1000)
  await raiseCompact($, { trigger: 'auto' })
  expect(hasIdleFlag(w, 1)).toBe(false)
})

test('AT-IC-01: a prompt entering, a running turn (midturn), and manual / plugin / precompute triggers are never idle', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await humanTurn($, w, 150000)
  await w.advance(1600 * 1000)
  for (const trigger of ['manual', 'plugin', 'precompute']) await raiseCompact($, { trigger })
  // A prompt that entered and has not started its turn.
  let open!: () => void
  const gate = new Promise<void>(r => { open = r })
  w.atSubmit = async () => { await gate }
  const held = $.prompt.submit({ text: 'hello again', origin: { kind: 'composer' } } as never)
  await w.settle()
  await raiseCompact($, { trigger: 'auto' })
  open()
  await held
  w.atSubmit = undefined
  await w.turnStart($, 'hello again')
  await raiseCompact($, { trigger: 'auto' })
  const n = w.callsOf('dispatch').length
  expect(n).toBe(5)
  for (let i = 0; i < n; i++) expect(hasIdleFlag(w, i)).toBe(false)
  expect(dispatchFlag(w, 4, '--midturn')).toBe('true')
})

// ID-1 (owner D2, 2026-10-23; SPEC-DELTAS AT-ID-01): Claude Code's future `idle` trigger.
test('AT-ID-01: a dispatch with trigger idle is handled like auto: no trigger_unknown, dispatch --trigger auto, the idle predicate, checkpoint and after-step; mid-turn like auto', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await humanTurn($, w, 150000)
  await w.advance(1600 * 1000)
  await raiseCompact($, { trigger: 'idle' })
  expect(w.rowsOf('trigger_unknown').length).toBe(0)
  expect(w.toasts.filter(t => t.includes('trigger'))).toEqual([])
  expect([dispatchFlag(w, 0, '--trigger'), hasIdleFlag(w, 0), dispatchFlag(w, 0, '--midturn')]).toEqual(['auto', true, 'false'])
  expect(w.callsOf('checkpoint').length).toBe(1)
  expect(w.callsOf('save-copy').length).toBe(1)
  expect(w.rowsOf('compacted').length).toBe(1)
  // Not idle by the predicate (gap 1,400 s): not an idle dispatch, as for auto.
  await humanTurn($, w, 150000)
  await w.advance(1400 * 1000)
  await raiseCompact($, { trigger: 'idle' })
  expect(hasIdleFlag(w, 1)).toBe(false)
  // During a running main turn: [midturn], as for auto.
  await w.turnStart($)
  await raiseCompact($, { trigger: 'idle' })
  expect(dispatchFlag(w, 2, '--midturn')).toBe('true')
  expect(w.callsOf('checkpoint').length).toBe(3)
})

test('AT-IC-01 (core-to-mod §17): helper down, the fs fallback record of an idle dispatch has idle true and idle_gap_s', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await humanTurn($, w, 150000)
  await w.advance(1600 * 1000)
  w.helperDown = true
  await raiseCompact($, { trigger: 'auto' })
  const nonce = markerNonce(w, w.compacts[0]?.instructions) ?? ''
  const rec = JSON.parse(w.files.get(`${WATCH}/${SID_A}/dispatch/${nonce}.json`) ?? '{}') as Record<string, unknown>
  expect([rec.nonce, rec.idle, rec.idle_gap_s, rec.midturn]).toEqual([nonce, true, 1600, false])
})

// ---- IC-1 D3: [idle] and the delivery-time re-measure

test('AT-IC-03: an idle dispatch gets [idle] in its resume block (when this build has the line), never with [midturn]', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await humanTurn($, w, 150000)
  await w.advance(1600 * 1000)
  await raiseCompact($, { trigger: 'auto' })
  const ctx = await $.prompt.context({ blocks: [] })
  const block = ctx.blocks.find(b => b.name === `${w.name}-resume`)?.text ?? ''
  const plain = assemble(w.name, 'resume-context', ['prod-forbid'], { session_id: SID_A, saved_copy: 'x', measured_at: 'x', remeasure: 'x', store: 'x' })
  const line = lineOf(w, ['idle'])
  expect(line === undefined).toBe(!hasTag('resume-context', 'idle'))
  if (line !== undefined) expect(block).toContain(line)
  const mid = assemble(w.name, 'resume-context', ['prod-forbid', 'midturn'], { session_id: SID_A, saved_copy: 'x', measured_at: 'x', remeasure: 'x', store: 'x' })
  const midLine = mid.split('\n').find(l => !plain.split('\n').includes(l))
  if (midLine !== undefined) expect(block).not.toContain(midLine)
  // Owner xxxxxxxx-18 ("Add the check line"): the kept messages are checked before Step 1.
  if (line !== undefined) expect(line).toContain('check the messages kept after the summary first; skip what is already done')
  const halt = lineOf(w, ['idle-halt'])
  if (halt !== undefined) expect(block).not.toContain(halt)
})

// Owner xxxxxxxx-25 ("Stop in halt"; SPEC-DELTAS AT-IB-03): while halt mode is on, the idle line
// says to handle the background result, then stop and wait for the user.
const RT = { session_id: SID_A, saved_copy: 'x', measured_at: 'x', remeasure: 'x', store: 'x', idle_used_at: 'x' }
/**
 * The lines `tags` add to the plain block (`base` kept in both), joined; undefined when none. They
 * end before the step-5 digest's Basis, which code renders from the block's own facts (owner
 * 2026-10-27 22:32; lane.test.ts checks it).
 */
function lineOf(w: World, tags: Tag[], base: Tag[] = [], rt: Record<string, string> = RT): string | undefined {
  const r = { lane_basis: BASIS_CUT, ...rt }
  const plain = assemble(w.name, 'resume-context', ['prod-forbid', ...base], r).split('\n')
  const added = assemble(w.name, 'resume-context', ['prod-forbid', ...base, ...tags], r).split('\n').filter(l => !plain.includes(l))
  return added.length > 0 ? added.join('\n').split(BASIS_CUT)[0] : undefined
}
const BASIS_CUT = '\u0002'
const blockOf = (w: World, ctx: { blocks: readonly { name: string; text: string }[] }) => ctx.blocks.find(b => b.name === `${w.name}-resume`)?.text
/** What the model read beside the prompt of the newest turn (the plugin's prompt.submit context). */
const ctxOf = (w: World): string => (w.submitContexts[w.submitContexts.length - 1] ?? []).join('\n')
/** The `Measured facts (<stamp>;` head a block's measure was taken at (IC-1 D3: the stamp shows the facts' age). */
const measuredHead = (at: number) => `Measured facts (${isoLocal(at, false)};`

test('AT-IB-03: halt on at an idle compaction: a task-notification turn gets [idle-halt] (handle it, then stop and wait for the user), not [idle]; the person\'s return clears halt and gets [idle]', async ($, on) => {
  const w = new World().install(on)
  w.files.set(`${WATCH}/${SID_A}/halt.json`, JSON.stringify({ active: true, reason: 'thrash' }))
  await w.start($)
  // A background result's turn (not a person: halt stays on) ends; the session then sits idle.
  await w.userTurn($, 'Background task finished.', 'task-notification')
  w.tokens = 150000
  await w.turnEnd($)
  await w.advance(1600 * 1000)
  await raiseCompact($, { trigger: 'auto' })
  await w.userTurn($, 'Another background task finished.', 'task-notification')
  const block = blockOf(w, await $.prompt.context({ blocks: [] })) ?? ''
  const idle = lineOf(w, ['idle'])
  const halt = lineOf(w, ['idle-halt'])
  expect(halt === undefined).toBe(!hasTag('resume-context', 'idle-halt'))
  if (halt !== undefined) {
    expect(halt).toContain('handle it, then stop and wait for the user')
    expect(block).toContain(halt)
    if (idle !== undefined) expect(block).not.toContain(idle)
  }
  await w.turnEnd($)
  await w.advance(120 * 1000)
  // The person comes back: their turn clears halt, so the block they get again (beside their
  // prompt, built before that turn starts) says [idle].
  await w.userTurn($, 'back')
  expect(w.rowsOf('halt').map(r => r.active)).toEqual([false])
  const back = ctxOf(w)
  expect(blockOf(w, await $.prompt.context({ blocks: [] }))).toBe(undefined)
  if (idle !== undefined) expect(back).toContain(idle)
  if (halt !== undefined) expect(back).not.toContain(halt)
})

// Owner 2026-10-26 [driver] (GSD re-entry per session; review of the first build): a halted idle
// block never carries the re-enter line, though its re-measure names an Active driver (EXCLUSIVE
// in tools/assemble); the person's return, which clears halt, gets it.
test('AT-GR-06: halt on at an idle compaction: the [idle-halt] block keeps the Active driver fact but not the [driver] re-enter line; the person\'s return gets it', async ($, on) => {
  const w = new World().install(on)
  w.files.set(`${WATCH}/${SID_A}/halt.json`, JSON.stringify({ active: true, reason: 'thrash' }))
  await w.start($)
  w.measureBlock = 'Git: main @ 3f9c2e1, 0 modified, 0 untracked\n' +
    'Active driver: /phase-loop (Skill, 2026-10-26 14:25 +0300) · re-enter: /phase-loop --ws workstream-a\nIn flight: none listed\nEvidence: none'
  await w.userTurn($, 'Background task finished.', 'task-notification')
  w.tokens = 150000
  await w.turnEnd($)
  await w.advance(1600 * 1000)
  await raiseCompact($, { trigger: 'auto' })
  await w.userTurn($, 'Another background task finished.', 'task-notification')
  const block = blockOf(w, await $.prompt.context({ blocks: [] })) ?? ''
  const driver = lineOf(w, ['driver'])
  expect(driver === undefined).toBe(!hasTag('resume-context', 'driver'))
  expect(block).toContain('Active driver: /phase-loop')
  if (driver !== undefined) expect(block).not.toContain(driver)
  await w.turnEnd($)
  await w.advance(120 * 1000)
  await w.userTurn($, 'back')
  const back = ctxOf(w)
  expect(back).toContain('Active driver: /phase-loop')
  if (driver !== undefined) expect(back).toContain(driver)
})

test('AT-IB-03: halt starts right after the idle block was built (its compaction is the second bad summary): the block goes out with [idle-halt], rebuilt from its stored measure (no new measure call) under that measure\'s stamp', async ($, on) => {
  const w = new World().install(on)
  w.summaryMode = 'unshaped'
  await w.start($)
  await raiseCompact($, { trigger: 'manual' })
  await $.prompt.context({ blocks: [] })
  await humanTurn($, w, 150000)
  await w.advance(1600 * 1000)
  const builtAt = w.clock.now()
  await raiseCompact($, { trigger: 'auto' })
  expect(w.rowsOf('halt').map(r => [r.reason, r.active])).toEqual([['2-nonok', true]])
  const measures = w.callsOf('measure').length
  await w.advance(500 * 1000)
  await w.userTurn($, 'Background task finished.', 'task-notification')
  const block = blockOf(w, await $.prompt.context({ blocks: [] })) ?? ''
  expect(w.callsOf('measure').length).toBe(measures)
  expect(block).toContain('3f9c2e1')
  expect(block).toContain(measuredHead(builtAt))
  const halt = lineOf(w, ['idle-halt'])
  const idle = lineOf(w, ['idle'])
  if (halt !== undefined) expect(block).toContain(halt)
  if (idle !== undefined && halt !== undefined) expect(block).not.toContain(idle)
})

test('AT-IC-04: a block delivered 601 s after it was built is rebuilt with one fresh measure (resume_remeasured); 599 s: no call', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await raiseCompact($, { trigger: 'manual' })
  const built = w.callsOf('measure').length
  await w.advance(601 * 1000)
  w.measureBlock = 'Git: main @ 9e9e9e9, 2 modified, 0 untracked\nIn flight: none listed\nEvidence: none'
  const ctx = await $.prompt.context({ blocks: [] })
  const block = ctx.blocks.find(b => b.name === `${w.name}-resume`)?.text ?? ''
  expect(w.callsOf('measure').length).toBe(built + 1)
  expect(block).toContain('9e9e9e9')
  expect(w.rowsOf('resume_remeasured').map(r => [r.age_s, typeof r.ms])).toEqual([[601, 'number']])
})

// Review of the third build: the delivery-time re-measure has a short budget; when its GSD step
// runs out of time, the stored measure's GSD and driver lines stay in the block (and so does
// [driver]), in place of `GSD: not measured (timeout)`.
test('AT-GR-07: a fresh re-measure whose GSD step timed out keeps the stored GSD and Active driver lines, and the [driver] line', async ($, on) => {
  const w = new World().install(on)
  const gsd = 'GSD (this session): workstream workstream-a · /r/.planning/workstreams/workstream-a/STATE.md: status executing · phase 2'
  const active = 'Active driver: /phase-loop (Skill, 2026-10-26 14:25 +0300) · re-enter: /phase-loop --ws workstream-a'
  w.measureBlock = `Git: main @ 3f9c2e1, 0 modified, 0 untracked\n${gsd}\n${active}\nIn flight: none listed\nEvidence: none`
  await w.start($)
  await raiseCompact($, { trigger: 'manual' })
  await w.advance(601 * 1000)
  w.measureBlock = 'Git: main @ 9e9e9e9, 2 modified, 0 untracked\nGSD: not measured (timeout)\nIn flight: none listed\nEvidence: none'
  const block = (await $.prompt.context({ blocks: [] })).blocks.find(b => b.name === `${w.name}-resume`)?.text ?? ''
  expect(w.rowsOf('resume_remeasured').length).toBe(1)
  expect(block).toContain('9e9e9e9')
  expect(block).toContain(gsd)
  expect(block).toContain(active)
  expect(block).not.toContain('GSD: not measured (timeout)')
  const driver = lineOf(w, ['driver'])
  expect(driver === undefined).toBe(!hasTag('resume-context', 'driver'))
  if (driver !== undefined) expect(block).toContain(driver)
})

// Owner xxxxxxxx-37 ("Full block again on return", replaces ID-3's [idle-return] line; SPEC-DELTAS
// AT-ID-03): the first human prompt after a background result's turn took an idle compaction's
// block gets the full block again, re-measured, with [idle-again] naming when it went out first.
// It goes beside that prompt (its prompt.submit context): prompt.context is asked once per
// conversation, at the turn that took the block, so a live session never asks it at the person's
// prompt (v012-digest H1). The cases ask prompt.context there too: it must add nothing.
const AGAIN = hasTag('resume-context', 'idle-again')
/** When the notification turn of `idleTakenByNotification` took the block. */
const USED_AT = T0 + 2600 * 1000

/** An idle dispatch at +1,600 s whose block a task-notification turn takes at +2,600 s; returns that block. */
async function idleTakenByNotification($: Engine, w: World): Promise<string> {
  await w.start($)
  await humanTurn($, w, 150000)
  await w.advance(1600 * 1000)
  await raiseCompact($, { trigger: 'auto' })
  await w.advance(1000 * 1000)
  await w.userTurn($, 'Background task finished.', 'task-notification')
  const ctx = await $.prompt.context({ blocks: [] })
  await w.turnEnd($, 'Handled the result.')
  expect(ctx.blocks.map(b => b.name)).toEqual([`${w.name}-resume`])
  return blockOf(w, ctx) ?? ''
}

/** A person's prompt and its turn: the block beside it, and what a prompt.context asked then would add. */
async function personTurn($: Engine, w: World, text: string): Promise<{ ctx: string; block: string | undefined }> {
  await w.userTurn($, text)
  const ctx = ctxOf(w)
  return { ctx, block: blockOf(w, await $.prompt.context({ blocks: [] })) }
}

const againLine = (w: World, base: Tag = 'idle') => lineOf(w, ['idle-again'], [base], { ...RT, idle_used_at: isoLocal(USED_AT, false) })
const dispatchNonce = (w: World) => w.flag(w.callsOf('dispatch')[0], '--nonce')

test('AT-ID-03: a composer prompt 300 s after a task-notification turn took the idle block gets the full block again beside it: re-measured, with [idle-again]; the next prompt none', async ($, on) => {
  const w = new World().install(on)
  const first = await idleTakenByNotification($, w)
  const note = againLine(w)
  expect(note === undefined).toBe(!AGAIN)
  if (note !== undefined) {
    expect(first).not.toContain(note)
    expect(note).toContain(isoLocal(USED_AT, false))
  }
  await w.advance(300 * 1000)
  w.measureBlock = 'Git: main @ 7a7a7a7, 1 modified, 0 untracked\nIn flight: none listed\nEvidence: none'
  const measures = w.callsOf('measure').length
  let t = await personTurn($, w, 'back again')
  expect(t.block).toBe(undefined)
  const again = t.ctx
  expect(w.callsOf('measure').length).toBe(measures + 1)
  expect(w.callsOf('measure').some(c => c.args.includes('--brief'))).toBe(false)
  expect(again).toContain(SID_A)
  expect(again).toContain('7a7a7a7')
  if (note !== undefined) expect(again).toContain(note)
  const idle = lineOf(w, ['idle'])
  if (idle !== undefined) expect(again).toContain(idle)
  expect(w.rowsOf('idle_return').map(r => [r.nonce, r.age_s, r.remeasured])).toEqual([[dispatchNonce(w), 300, true]])
  await w.turnEnd($)
  await w.advance(700 * 1000)
  t = await personTurn($, w, 'and again')
  expect([t.ctx, t.block]).toEqual(['', undefined])
  expect(w.rowsOf('idle_return').length).toBe(1)
})

test('AT-ID-03: a young block (the notification 60 s after the compaction, the person 60 s later) still goes again re-measured, whatever its age', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await humanTurn($, w, 150000)
  await w.advance(1600 * 1000)
  await raiseCompact($, { trigger: 'auto' })
  await w.advance(60 * 1000)
  let measures = w.callsOf('measure').length
  await w.userTurn($, 'Background task finished.', 'task-notification')
  expect(blockOf(w, await $.prompt.context({ blocks: [] })) === undefined).toBe(false)
  expect(w.callsOf('measure').length).toBe(measures)
  await w.turnEnd($)
  await w.advance(60 * 1000)
  measures = w.callsOf('measure').length
  w.measureBlock = 'Git: main @ 6b6b6b6, 0 modified, 0 untracked\nIn flight: none listed\nEvidence: none'
  const again = (await personTurn($, w, 'back')).ctx
  expect(w.callsOf('measure').length).toBe(measures + 1)
  expect(again).toContain('6b6b6b6')
  expect(w.rowsOf('idle_return').map(r => [r.age_s, r.remeasured])).toEqual([[60, true]])
})

test('AT-ID-03: the re-measure fails: the block goes again with the measure the first delivery had and its stamp (resume_remeasure_failed), idle_return remeasured false', async ($, on) => {
  const w = new World().install(on)
  const first = await idleTakenByNotification($, w)
  expect(first).toContain(measuredHead(USED_AT))
  w.replies.measure = () => 'reject'
  await w.advance(7200 * 1000)
  const again = (await personTurn($, w, 'back')).ctx
  expect(again).toContain('3f9c2e1')
  // The facts are those measured at the first delivery, two hours ago: the stamp says so.
  expect(again).toContain(measuredHead(USED_AT))
  const note = againLine(w)
  if (note !== undefined) expect(again).toContain(note)
  expect(w.rowsOf('resume_remeasure_failed').length).toBe(1)
  expect(w.rowsOf('idle_return').map(r => r.remeasured)).toEqual([false])
})

test('AT-ID-03: a second task-notification turn gets nothing; the person still gets the block again after it', async ($, on) => {
  const w = new World().install(on)
  await idleTakenByNotification($, w)
  await w.advance(60 * 1000)
  await w.userTurn($, 'Another background task finished.', 'task-notification')
  expect(ctxOf(w)).toBe('')
  expect((await $.prompt.context({ blocks: [] })).blocks).toEqual([])
  await w.turnEnd($)
  await w.advance(60 * 1000)
  const t = await personTurn($, w, 'back')
  expect([t.ctx === '', t.block]).toEqual([false, undefined])
  expect(w.rowsOf('idle_return').map(r => r.age_s)).toEqual([120])
})

test('AT-ID-03: a person\'s prompt that does not enter (a hook beneath drops it) hands the block back: their next prompt gets it, one idle_return row', async ($, on) => {
  const w = new World().install(on)
  await idleTakenByNotification($, w)
  await w.advance(60 * 1000)
  w.submitDrop = 'a hook beneath refused it'
  await $.prompt.submit({ text: 'back', origin: { kind: 'composer' } } as never)
  expect(ctxOf(w)).toContain(SID_A)
  expect(w.rowsOf('idle_return')).toEqual([])
  w.submitDrop = undefined
  await w.advance(60 * 1000)
  const t = await personTurn($, w, 'back, again')
  expect(t.ctx).toContain(SID_A)
  expect(w.rowsOf('idle_return').map(r => r.age_s)).toEqual([120])
})

test('AT-ID-03: a prompt delivered into the running result turn by a person (typed over it) carries the block; the turn after it none', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await humanTurn($, w, 150000)
  await w.advance(1600 * 1000)
  await raiseCompact($, { trigger: 'auto' })
  await w.advance(1000 * 1000)
  await w.userTurn($, 'Background task finished.', 'task-notification')
  expect(blockOf(w, await $.prompt.context({ blocks: [] })) === undefined).toBe(false)
  await w.advance(30 * 1000)
  await $.prompt.submit({ text: 'what happened?', origin: { kind: 'composer' }, turnId: 't2' } as never)
  expect(ctxOf(w)).toContain(SID_A)
  expect(w.rowsOf('idle_return').map(r => r.age_s)).toEqual([30])
  await w.turnEnd($)
  const t = await personTurn($, w, 'thanks')
  expect([t.ctx, t.block]).toEqual(['', undefined])
})

test('AT-ID-03: a person\'s turn takes the idle block itself: nothing again later; a non-idle block a notification took: nothing either; a newer compaction drops the held block', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await humanTurn($, w, 150000)
  await w.advance(1600 * 1000)
  await raiseCompact($, { trigger: 'auto' })
  await w.userTurn($, 'hello')
  expect(blockOf(w, await $.prompt.context({ blocks: [] })) === undefined).toBe(false)
  await w.turnEnd($)
  // The person's next prompt, with no compaction in between: nothing again.
  await w.advance(700 * 1000)
  let t = await personTurn($, w, 'next')
  expect([t.ctx, t.block]).toEqual(['', undefined])
  expect(w.rowsOf('idle_return').length).toBe(0)
  await w.turnEnd($)
  await raiseCompact($, { trigger: 'manual' })
  await w.userTurn($, 'Background task finished.', 'task-notification')
  await $.prompt.context({ blocks: [] })
  await w.turnEnd($)
  await w.advance(700 * 1000)
  t = await personTurn($, w, 'back')
  expect([t.ctx, t.block]).toEqual(['', undefined])
  await w.turnEnd($)
  // An idle block a notification took, then a newer (manual) compaction: the person gets the newer
  // block, once, with no [idle-again].
  await w.advance(1600 * 1000)
  await raiseCompact($, { trigger: 'auto' })
  await w.userTurn($, 'Background task finished.', 'task-notification')
  await $.prompt.context({ blocks: [] })
  await w.turnEnd($)
  await raiseCompact($, { trigger: 'manual' })
  t = await personTurn($, w, 'back again')
  const newer = t.block ?? ''
  const note = lineOf(w, ['idle-again'], ['idle'], { ...RT, idle_used_at: '\u0001' })
  expect([newer === '', t.ctx]).toEqual([false, ''])
  if (note !== undefined) expect(newer).not.toContain(note.slice(0, note.indexOf('\u0001')))
  expect(w.rowsOf('idle_return').length).toBe(0)
})

test('AT-IC-04: the re-measure fails (3 s budget) → the stored block goes out, resume_remeasure_failed; a 599 s old block makes no call', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await raiseCompact($, { trigger: 'manual' })
  await w.advance(599 * 1000)
  const before = w.callsOf('measure').length
  let ctx = await $.prompt.context({ blocks: [] })
  expect(w.callsOf('measure').length).toBe(before)
  expect(ctx.blocks.length).toBe(1)
  await w.advance(60000)
  await raiseCompact($, { trigger: 'manual' })
  await w.advance(700 * 1000)
  w.replies.measure = () => 'reject'
  ctx = await $.prompt.context({ blocks: [] })
  const block = ctx.blocks.find(b => b.name === `${w.name}-resume`)?.text ?? ''
  expect(block).toContain('3f9c2e1')
  expect(w.rowsOf('resume_remeasure_failed').map(r => r.age_s)).toEqual([700])
  const last = w.callsOf('measure')[w.callsOf('measure').length - 1]
  expect(last?.args.includes('--compact')).toBe(true)
  // Review of the second build: only this delivery-time re-measure, killed at 3 s, gives the
  // helper the short budget; the re-measure at compaction keeps the helper's own (7 s).
  expect(last?.args.join(' ')).toContain('--budget-ms 2700')
  expect(w.callsOf('measure')[0]?.args.includes('--budget-ms')).toBe(false)
})

// ---- IC-1 D5: the pre-idle handoff turn (§9.4)

test('AT-IC-05: on, a turn ends answer at 260K with rate limits → due at 49 min; at fire: handoff-turn open --reason idle and one [submit-idle] submit; at its end no compaction, no continue', { options: TURN }, async ($, on) => {
  const w = new World().install(on)
  w.policy = NATIVE_OFF
  w.rateLimits = LIMITS
  await w.start($)
  await humanTurn($, w)
  await w.advance(49 * MIN - 1)
  expect(w.submits.length + w.rowsOf('handoff_skipped').length).toBe(0)
  await w.advance(1)
  if (!IDLE) {
    expect(idleSkips(w)).toEqual(['no-asset'])
    expect(w.submits.length).toBe(0)
    return
  }
  expect(w.submits).toEqual([idleText(w)])
  expect(w.callsOf('handoff-turn').filter(c => c.args[0] === 'open').map(c => w.flag(c, '--reason'))).toEqual(['idle'])
  await w.turnStart($, '')
  expect(w.rowsOf('handoff_turn_start').map(r => [r.reason, r.gap_s])).toEqual([['idle', 49 * 60]])
  w.publish(w.lastHt() ?? '', PUBLISHED)
  await w.turnEnd($, 'Handoff written.')
  await w.advance(10 * MIN)
  expect(w.compacts.length).toBe(0)
  expect(w.submits.length).toBe(1)
  expect(w.rowsOf('handoff_turn_end').map(r => [r.handoff_turn, r.reason, r.compaction, r.cache_read_share])).toEqual([['published', 'idle', false, null]])
})

test('AT-IC-05: a main turn.start before the due cancels the timer', { options: TURN }, async ($, on) => {
  const w = new World().install(on)
  w.policy = NATIVE_OFF
  w.rateLimits = LIMITS
  await w.start($)
  await humanTurn($, w)
  await w.advance(30 * MIN)
  await w.userTurn($)
  await w.advance(30 * MIN)
  expect(w.submits.length + w.rowsOf('handoff_skipped').length).toBe(0)
})

test('AT-IC-06: off arms no timer: no submit and no row (native idle on as well)', { options: { idle_handoff_turn: 'off' } }, async ($, on) => {
  const w = new World().install(on)
  w.rateLimits = LIMITS
  await w.start($)
  await humanTurn($, w)
  await w.advance(120 * MIN)
  expect([w.submits.length, w.rowsOf('handoff_skipped').length]).toEqual([0, 0])
})

const SKIPS: { why: string; options?: Record<string, unknown>; world?: Partial<{ window: number }>; store?: Record<string, unknown>; setup?: (w: World) => void; tokens?: number; aborted?: boolean; limits?: World['rateLimits'] }[] = [
  { why: 'triggers-off', options: { triggers: false } },
  { why: 'small-window', world: { window: 200000 } },
  { why: 'session-changed', setup: w => { w.sid = SID_B } },
  { why: 'small', tokens: 150000 },
  { why: 'ttl-5m', setup: w => { w.rateLimits = [] } },
  // D15: a Claude gateway reports only its spend limit, and its cache is the five-minute one.
  { why: 'ttl-5m', limits: [{ kind: 'spend_limit', percentUsed: 10 }] },
  // Only with idle_handoff_near_limit `skip`; the default `run` runs the turn (below).
  { why: 'near-limit', options: { idle_handoff_near_limit: 'skip' }, setup: w => { w.rateLimits = [{ kind: 'five_hour', percentUsed: 12 }, { kind: 'seven_day', percentUsed: 95 }] } },
  { why: 'aborted', aborted: true },
  { why: 'cap', store: { ['ht:' + SID_A]: [T0 + 10 * MIN] } },
]
for (const c of SKIPS) {
  test(`AT-IC-06 (${c.why}${c.limits ? ', spend limit only' : ''}): one handoff_skipped {why: ${c.why}, reason: idle}, no submit`, { options: { ...TURN, ...(c.options ?? {}) } }, async ($, on) => {
    const w = new World(c.world ?? {}).install(on, c.store ?? {})
    w.policy = NATIVE_OFF
    w.rateLimits = c.limits ?? LIMITS
    await w.start($)
    await w.userTurn($)
    w.tokens = c.tokens ?? 260000
    await w.turnEnd($, 'Done.', c.aborted ? 'aborted' : 'answer')
    await w.advance(48 * MIN)
    c.setup?.(w)
    await w.advance(1 * MIN)
    expect(idleSkips(w)).toEqual([c.why])
    expect(w.submits.length).toBe(0)
  })
}

// Owner xxxxxxxx (2026-10-30, "I want the handoff anyway"): idle_handoff_near_limit `run`, the
// default, runs the turn at any usage share; a spend limit with no reading (NaN) does not stop it.
for (const c of [
  { name: 'a seven-day window at 95%', limits: [{ kind: 'five_hour', percentUsed: 12 }, { kind: 'seven_day', percentUsed: 95 }] },
  { name: 'a spend limit with no share (NaN) beside a plan window', limits: [{ kind: 'five_hour', percentUsed: 12 }, { kind: 'spend_limit', percentUsed: NaN }] },
]) {
  test(`AT-IC-06 (near-limit, idle_handoff_near_limit run, the default): ${c.name}: no near-limit skip, the turn runs`, { options: TURN }, async ($, on) => {
    const w = new World().install(on)
    w.policy = NATIVE_OFF
    w.rateLimits = LIMITS
    await w.start($)
    await w.userTurn($)
    w.tokens = 260000
    await w.turnEnd($, 'Done.')
    await w.advance(48 * MIN)
    w.rateLimits = c.limits
    await w.advance(1 * MIN)
    if (!IDLE) {
      expect(idleSkips(w)).toEqual(['no-asset'])
      return
    }
    expect(idleSkips(w)).toEqual([])
    expect(w.submits).toEqual([idleText(w)])
  })
}

test('AT-IC-06 (busy): a plugin compaction in flight at the due: busy', { options: TURN }, async ($, on) => {
  const w = new World().install(on)
  w.policy = NATIVE_OFF
  w.rateLimits = LIMITS
  await w.start($)
  let release!: () => void
  w.compactGate = new Promise<void>(r => { release = r })
  await humanTurn($, w, 410000)
  await w.advance(2000)
  expect(w.compacts.length).toBe(1)
  await w.advance(49 * MIN)
  expect(idleSkips(w)).toEqual(['busy'])
  release()
  await w.settle()
})

test('AT-IC-06 (episode), AT-IC-07: no human turn ended since the last pre-idle turn: episode; a task-notification turn neither ends nor starts one; a composer turn starts a new one', { options: TURN }, async ($, on) => {
  const w = new World().install(on)
  w.policy = NATIVE_OFF
  w.rateLimits = LIMITS
  await w.start($)
  await humanTurn($, w)
  await w.advance(49 * MIN)
  if (!IDLE) return
  expect(w.submits.length).toBe(1)
  await w.turnStart($, '')
  await w.turnEnd($, 'Handoff written.')
  await w.advance(5 * MIN)
  // A background result opens a turn: not a person, so the episode goes on (done).
  await w.userTurn($, 'Background task finished.', 'task-notification')
  await w.turnEnd($, 'Noted.')
  await w.advance(50 * MIN)
  expect(idleSkips(w).length > 0 && idleSkips(w).every(x => x === 'episode')).toBe(true)
  expect(w.submits.length).toBe(1)
  // The person comes back: a new episode starts at that turn's end; once the hourly slot is free
  // the next due runs a turn again.
  await w.advance(20 * MIN)
  await humanTurn($, w)
  await w.advance(49 * MIN)
  expect(w.submits.length).toBe(2)
})

test('AT-IC-06 (published): a handoff published since the last human-origin turn: published', { options: { ...TURN, max_auto_continues_per_hour: 0 } }, async ($, on) => {
  const w = new World().install(on)
  w.policy = NATIVE_OFF
  w.rateLimits = LIMITS
  await w.start($)
  // A last cycle (continue-off): its handoff turn publishes, the compaction follows.
  await w.userTurn($)
  w.tokens = 610000
  await w.tool($)
  w.tokens = 640000
  await w.turnEnd($, 'Checkpoint: clean · Step 1: run the tests')
  await w.advance(2000)
  if (w.submits.length === 0) return
  await w.turnStart($, '')
  w.publish(w.lastHt() ?? '', PUBLISHED)
  w.tokens = 260000
  await w.turnEnd($, 'Handoff written.')
  await w.advance(61 * MIN)
  expect(idleSkips(w)).toEqual(['published'])
})

test('AT-IC-08: halt + a task-notification turn.start → halt kept; composer / bridge / sdk → cleared', async ($, on) => {
  const w = new World().install(on)
  w.files.set(`${WATCH}/${SID_A}/halt.json`, JSON.stringify({ active: true, reason: 'thrash' }))
  await w.start($)
  await w.userTurn($, 'Background task finished.', 'task-notification')
  await w.turnEnd($)
  await w.userTurn($, 'A scheduled run.', 'scheduled-trigger')
  await w.turnEnd($)
  await w.turnStart($, 'a turn with no prompt seen')
  await w.turnEnd($)
  expect(w.rowsOf('halt').length).toBe(0)
  await w.userTurn($, 'I am back.', 'sdk')
  expect(w.rowsOf('halt').map(r => r.active)).toEqual([false])
})

test('AT-IC-08: composer and bridge prompts clear halt too', async ($, on) => {
  const w = new World().install(on)
  w.files.set(`${WATCH}/${SID_A}/halt.json`, JSON.stringify({ active: true, reason: 'cap' }))
  await w.start($)
  await w.userTurn($, 'hi', 'bridge')
  expect(w.rowsOf('halt').map(r => r.active)).toEqual([false])
})

// ---- IC-1 D7: nothing the ended session scheduled reaches the conversation after /clear

const CLEAR = { reason: 'clear', sessionId: SID_A, resume: { id: SID_A } }

test('AT-IC-09: session.end {clear} during boundary_delay_ms of a last cycle: no submit, no compaction', { options: { max_auto_continues_per_hour: 0, precompact_turn: 'code' } }, async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await w.userTurn($)
  w.tokens = 610000
  await w.tool($)
  w.tokens = 640000
  await w.turnEnd($, 'Checkpoint: clean · Step 1: run the tests')
  await w.advance(1000)
  await $.session.end(CLEAR as never)
  w.sid = SID_B
  await w.advance(60000)
  expect([w.submits.length, w.compacts.length]).toEqual([0, 0])
})

test('AT-IC-09: session.end {clear} between a plugin compaction and its continue: no continue; the pending block is dropped (mod_outcome dropped:session-end)', { options: { precompact_turn: 'code' } }, async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await w.userTurn($)
  w.tokens = 610000
  await w.tool($)
  await w.turnEnd($, 'Checkpoint: clean · Step 1: run the tests')
  let ended = false
  w.atHelper = async sub => {
    if (sub !== 'sweep' || ended) return
    ended = true
    await $.session.end(CLEAR as never)
    w.sid = SID_B
  }
  await w.advance(500)
  await w.advance(60000)
  expect(ended).toBe(true)
  expect(w.compacts.length).toBe(1)
  expect(w.submits.length).toBe(0)
  const ctx = await $.prompt.context({ blocks: [] })
  expect(ctx.blocks.length).toBe(0)
})

test('AT-IC-09: the session id changed with no session.end seen: the continue is not submitted (submit_dropped session-changed)', { options: { precompact_turn: 'code' } }, async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await w.userTurn($)
  w.tokens = 610000
  await w.tool($)
  await w.turnEnd($, 'Checkpoint: clean · Step 1: run the tests')
  w.atHelper = async sub => {
    if (sub === 'sweep') w.sid = SID_B
  }
  await w.advance(500)
  await w.advance(60000)
  expect(w.submits.length).toBe(0)
  expect(w.rowsOf('submit_dropped').map(r => [r.why, r.site])).toEqual([['session-changed', 'continue']])
  // The pending block is not claimed for prompt.submit (the rollup reads the claim file first,
  // so a claim would report a delivery that never happened); mod_outcome says dropped.
  expect(w.callsOf('claim').map(c => w.flag(c, '--channel'))).toEqual([])
  expect([...w.files.keys()].filter(k => k.includes('/resume-claimed/'))).toEqual([])
  expect(w.rowsOf('mod_outcome').map(r => r.resume)).toEqual(['dropped:session-end'])
})

test('AT-IC-09 (pending): session.end drops a pending block: mod_outcome resume dropped:session-end, nothing at the next prompt.context', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await raiseCompact($, { trigger: 'manual' })
  await $.session.end(CLEAR as never)
  w.sid = SID_B
  const ctx = await $.prompt.context({ blocks: [] })
  expect(ctx.blocks.length).toBe(0)
  expect(w.rowsOf('mod_outcome').map(r => r.resume)).toEqual(['dropped:session-end'])
})

test('AT-IC-13: after a published pre-idle handoff and no main turn, a native auto (idle) dispatch gets [handoff] with the path', { options: TURN }, async ($, on) => {
  const w = new World().install(on)
  w.policy = NATIVE_OFF
  w.rateLimits = LIMITS
  await w.start($)
  await humanTurn($, w)
  await w.advance(49 * MIN)
  if (!IDLE) return
  await w.turnStart($, '')
  w.publish(w.lastHt() ?? '', PUBLISHED)
  await w.turnEnd($, 'Handoff written.')
  await w.advance(30 * MIN)
  await raiseCompact($, { trigger: 'auto' })
  const d = w.callsOf('dispatch')[0]
  expect(w.flag(d, '--tags')?.split(',')).toContain('handoff')
  expect(hasIdleFlag(w, 0)).toBe(true)
  const text = assemble(w.name, 'handoff-instructions', ['handoff'], { nonce: w.flag(d, '--nonce') ?? '', handoff_path: SHOWN, measured_at: '' })
  if (text.includes(SHOWN)) expect(w.compacts[0]?.instructions).toContain(SHOWN)
})

test('AT-IC-14: a persisted idle_due in the future re-arms at load; one in the past, or for another sid, is ignored', { options: ON }, async ($, on) => {
  const w = new World().install(on, {
    ['idle_due:' + SID_A]: { due: T0 + 10 * MIN, sid: SID_A, episode: { since: T0 - 39 * MIN, done: false } },
  })
  w.policy = NATIVE_OFF
  w.rateLimits = LIMITS
  w.tokens = 260000
  await w.start($)
  await w.advance(10 * MIN)
  expect(idleSkips(w).length + w.submits.length).toBe(1)
})

test('AT-IC-14: a past due and another sid\'s due arm nothing', { options: ON }, async ($, on) => {
  const w = new World().install(on, {
    ['idle_due:' + SID_A]: { due: T0 - MIN, sid: SID_A, episode: null },
    ['idle_due:' + SID_B]: { due: T0 + 10 * MIN, sid: SID_B, episode: null },
  })
  w.policy = NATIVE_OFF
  w.rateLimits = LIMITS
  await w.start($)
  await w.advance(120 * MIN)
  expect(idleSkips(w).length + w.submits.length).toBe(0)
})

// §9.4: a main turn.start, a prompt entering and session.end cancel the timer and clear the
// persisted due, so a reload of the same sid re-arms nothing the session already cancelled. Every
// clear is a tombstone (IDLE-COMPACT §3.1), never null: a missing record means a lost write.
/** The last value the mod stored for this sid's due (undefined: never written). */
function watchDue(on: Parameters<World['install']>[0]): () => unknown {
  let last: unknown
  // Registered before World.install, so it stands outside mock.store (first is outermost).
  on('store.set', { key: 'idle_due:' + SID_A }, (_$, e, next) => {
    last = e.value ?? null
    return next(e)
  })
  return () => last
}
/** A tombstone: the record was cleared (§3.1). */
const cleared = (v: unknown): boolean => typeof v === 'object' && v !== null && (v as Record<string, unknown>).cancelled === true

test('AT-IC-14: a main turn.start clears the persisted idle_due (a tombstone)', { options: ON }, async ($, on) => {
  const dueOf = watchDue(on)
  const w = new World().install(on)
  w.policy = NATIVE_OFF
  await w.start($)
  await humanTurn($, w)
  expect(dueOf()).toBeTruthy()
  await w.turnStart($)
  expect(cleared(dueOf())).toBe(true)
})

test('AT-IC-14: a prompt entering clears the persisted idle_due (a tombstone)', { options: ON }, async ($, on) => {
  const dueOf = watchDue(on)
  const w = new World().install(on)
  w.policy = NATIVE_OFF
  await w.start($)
  await humanTurn($, w)
  expect(dueOf()).toBeTruthy()
  await $.prompt.submit({ text: 'back again', origin: { kind: 'composer' } } as never)
  expect(cleared(dueOf())).toBe(true)
})

test('AT-IC-14: session.end clears the persisted idle_due (a tombstone)', { options: ON }, async ($, on) => {
  const dueOf = watchDue(on)
  const w = new World().install(on)
  w.policy = NATIVE_OFF
  await w.start($)
  await humanTurn($, w)
  expect(dueOf()).toBeTruthy()
  await $.session.end(CLEAR as never)
  expect(cleared(dueOf())).toBe(true)
})

// ---- A fresh load re-arms the due with no turn end of its own: a background session moved to a
// new version by the supervisor (no SessionEnd), or a `claude respawn` or signal end (SessionEnd
// `other`, which keeps the due), then resumed under its id; probe P4 2026-10-27 skipped the 49-min
// turn as `aborted` there. The `aborted` and `published` checks and `gap_s` read the armed turn
// from the persisted due.
const moved = (kind: 'turn' | 'check', answer?: boolean, published?: boolean) => ({
  ['idle_due:' + SID_A]: {
    due: T0 + 10 * MIN, sid: SID_A, episode: { since: T0 - (kind === 'turn' ? 39 : 45.5) * MIN, done: false }, kind,
    end: T0 - (kind === 'turn' ? 39 : 45.5) * MIN, ...(answer === undefined ? {} : { answer }), ...(published === undefined ? {} : { published }),
  },
})

test('BG-IDLE-01: a moved session re-arms the 49-min due of an answered turn: the turn runs, not skipped aborted', { options: ON }, async ($, on) => {
  const w = new World().install(on, moved('turn', true))
  w.policy = NATIVE_OFF
  w.rateLimits = LIMITS
  w.tokens = 260000
  await w.start($)
  await w.advance(10 * MIN)
  expect(idleSkips(w)).not.toContain('aborted')
  if (!IDLE) {
    expect(idleSkips(w)).toEqual(['no-asset'])
    return
  }
  expect(w.submits).toEqual([idleText(w)])
  // gap_s counts from the armed turn's end, not null.
  await w.turnStart($, '')
  expect(w.rowsOf('handoff_turn_start').map(r => [r.reason, r.gap_s])).toEqual([['idle', 49 * 60]])
})

test('BG-IDLE-02: a moved session re-arms the 55.5-min check of an answered turn: the check runs the turn, not skipped aborted', { options: TURN }, async ($, on) => {
  const w = new World().install(on, moved('check', true))
  w.rateLimits = LIMITS
  w.tokens = 260000
  await w.start($)
  await w.advance(10 * MIN)
  expect(w.rowsOf('idle_silent').length).toBe(1)
  expect(idleSkips(w)).not.toContain('aborted')
  if (!IDLE) {
    expect(idleSkips(w)).toEqual(['no-asset'])
    return
  }
  expect(w.submits).toEqual([idleText(w, '55')])
})

for (const [name, answer] of [['an aborted turn', false], ['a record written before the answer field', undefined]] as const) {
  test(`BG-IDLE-03: a re-armed due of ${name} still skips aborted`, { options: ON }, async ($, on) => {
    const w = new World().install(on, moved('turn', answer))
    w.policy = NATIVE_OFF
    w.rateLimits = LIMITS
    w.tokens = 260000
    await w.start($)
    await w.advance(10 * MIN)
    expect(idleSkips(w)).toEqual(['aborted'])
    expect(w.submits.length).toBe(0)
  })
}

test('BG-IDLE-04: the persisted due records how the armed turn ended (answer true, aborted false)', { options: ON }, async ($, on) => {
  let last: Record<string, unknown> | undefined
  on('store.set', { key: 'idle_due:' + SID_A }, (_$, e, next) => {
    last = (e.value ?? undefined) as Record<string, unknown> | undefined
    return next(e)
  })
  const w = new World().install(on)
  w.policy = NATIVE_OFF
  await w.start($)
  await humanTurn($, w)
  expect(last?.answer).toBe(true)
  await w.turnStart($)
  await w.turnEnd($, 'Stopped.', 'aborted')
  expect(last?.answer).toBe(false)
})

test('BG-IDLE-05: session.end {other} (claude respawn, a signal) keeps the persisted idle_due; {prompt_input_exit} clears it (a tombstone)', { options: ON }, async ($, on) => {
  const dueOf = watchDue(on)
  const w = new World().install(on)
  w.policy = NATIVE_OFF
  await w.start($)
  await humanTurn($, w)
  const armed = dueOf()
  expect(armed).toBeTruthy()
  await $.session.end({ ...CLEAR, reason: 'other' } as never)
  expect(dueOf()).toBe(armed)
  await w.advance(60 * MIN)
  expect(w.submits.length + idleSkips(w).length).toBe(0)
  await w.start($)
  await humanTurn($, w)
  expect(dueOf()).toBeTruthy()
  await $.session.end({ ...CLEAR, reason: 'prompt_input_exit' } as never)
  expect(cleared(dueOf())).toBe(true)
})

test('BG-IDLE-06: a re-armed due of a session that published a handoff since the last human turn skips published', { options: ON }, async ($, on) => {
  const w = new World().install(on, moved('turn', true, true))
  w.policy = NATIVE_OFF
  w.rateLimits = LIMITS
  w.tokens = 260000
  await w.start($)
  await w.advance(10 * MIN)
  expect(idleSkips(w)).toEqual(['published'])
  expect(w.submits.length).toBe(0)
})

test('BG-IDLE-07: the turn that publishes a handoff marks the due it armed published', { options: { ...ON, max_auto_continues_per_hour: 0 } }, async ($, on) => {
  let last: Record<string, unknown> | undefined
  on('store.set', { key: 'idle_due:' + SID_A }, (_$, e, next) => {
    last = (e.value ?? undefined) as Record<string, unknown> | undefined
    return next(e)
  })
  const w = new World().install(on)
  w.policy = NATIVE_OFF
  w.rateLimits = LIMITS
  await w.start($)
  await w.userTurn($)
  w.tokens = 610000
  await w.tool($)
  w.tokens = 640000
  await w.turnEnd($, 'Checkpoint: clean · Step 1: run the tests')
  expect(last?.published).toBe(false)
  await w.advance(2000)
  if (w.submits.length === 0) return
  await w.turnStart($, '')
  w.publish(w.lastHt() ?? '', PUBLISHED)
  w.tokens = 260000
  await w.turnEnd($, 'Handoff written.')
  expect(last?.published).toBe(true)
})

test('BG-IDLE-08: a due another process on the same sid fired or cancelled (a resumed copy) does nothing here: no row, no submit', { options: ON }, async ($, on) => {
  let gone = false
  // That process's fire or cancel left its tombstone (IDLE-COMPACT §3.1, G1 held-elsewhere).
  const tomb = { cancelled: true, sid: SID_A, load: 'other-load', due: T0 + 10 * MIN, at: T0 + 5 * MIN }
  on('store.get', { key: 'idle_due:' + SID_A }, (_$, e, next) => (gone ? { value: tomb } : next(e)))
  const w = new World().install(on, moved('turn', true))
  w.policy = NATIVE_OFF
  w.rateLimits = LIMITS
  w.tokens = 260000
  await w.start($)
  await w.advance(5 * MIN)
  gone = true
  await w.advance(5 * MIN)
  expect(idleSkips(w).length + w.submits.length).toBe(0)
})

test('BG-IDLE-08 (lost write): a due the store lost (no record, no tombstone) is one due-missing row, not a silent takeover; no submit', { options: ON }, async ($, on) => {
  let gone = false
  on('store.get', { key: 'idle_due:' + SID_A }, (_$, e, next) => (gone ? { value: undefined } : next(e)))
  const w = new World().install(on, moved('turn', true))
  w.policy = NATIVE_OFF
  w.rateLimits = LIMITS
  w.tokens = 260000
  await w.start($)
  await w.advance(5 * MIN)
  gone = true
  await w.advance(5 * MIN)
  expect(w.rowsOf('handoff_skipped').map(r => [r.why, r.kind])).toEqual([['due-missing', 'turn']])
  expect(w.submits.length).toBe(0)
})

// ---- IA-1..3 (idle D3, owner 2026-10-23 02:4x): `auto` = the plugin's pre-idle turn only while
// Claude Code's own idle compaction is off; a failed settings read counts as on (O-9 provisional).
const idleModes = (w: World) => w.rowsOf('idle_mode').map(r => `${String(r.native)}/${String(r.plugin_turn)}`)

test('AT-IA-02: auto with idleCompaction false arms the timer; idle_mode vetoed/on', { options: TURN }, async ($, on) => {
  const w = new World().install(on)
  w.policy = NATIVE_OFF
  w.rateLimits = LIMITS
  await w.start($)
  await humanTurn($, w)
  await w.advance(49 * MIN)
  expect(w.submits.length + idleSkips(w).length).toBe(1)
  expect(idleModes(w)).toEqual(['vetoed/on'])
})

test('AT-IA-02: auto with autoCompactEnabled false: compaction-off (idle never fires without auto-compact), the 49-min turn armed', { options: ON }, async ($, on) => {
  const w = new World().install(on)
  w.policy = { autoCompactEnabled: false }
  w.rateLimits = LIMITS
  await w.start($)
  await humanTurn($, w)
  await w.advance(49 * MIN)
  expect(w.submits.length + idleSkips(w).length).toBe(1)
  expect(idleModes(w)).toEqual(['compaction-off/on'])
})

// Owner xxxxxxxx-17 ("Check outcome at 55.5m"; D3 reworded "off when native actually compacts",
// O-9 "unreadable means check what happened"): native on or unreadable arms the outcome check.
for (const c of [{ name: 'idleCompaction true', policy: { idleCompaction: true } }, { name: 'the key absent', policy: {} }]) {
  test(`AT-IA-02: auto with ${c.name}: native on, no turn at 49 min, the 55.5-min check armed; idle_mode on/check`, { options: TURN }, async ($, on) => {
    const w = new World().install(on)
    w.policy = c.policy
    w.rateLimits = LIMITS
    await w.start($)
    await humanTurn($, w)
    await w.advance(55 * MIN)
    expect([w.submits.length, idleSkips(w).length]).toEqual([0, 0])
    await w.advance(MIN)
    expect(w.submits.length + idleSkips(w).length).toBe(1)
    expect(idleModes(w)).toEqual(['on/check'])
  })
}

test('AT-IA-02: the settings read throws: native unknown, the 55.5-min check armed (O-9: check what happened)', { options: TURN }, async ($, on) => {
  const w = new World().install(on)
  w.settingsThrow = true
  w.rateLimits = LIMITS
  await w.start($)
  await humanTurn($, w)
  await w.advance(55 * MIN)
  expect([w.submits.length, idleSkips(w).length]).toEqual([0, 0])
  await w.advance(MIN)
  expect(w.submits.length + idleSkips(w).length).toBe(1)
  expect(idleModes(w)).toEqual(['unknown/check'])
})

test('AT-IA-03: armed while native off; native idle switched on before the fire: handoff_skipped {native-on, idle} at 49 min, then the outcome check at 55.5 min', { options: TURN }, async ($, on) => {
  const w = new World().install(on)
  w.policy = NATIVE_OFF
  w.rateLimits = LIMITS
  await w.start($)
  await humanTurn($, w)
  await w.advance(30 * MIN)
  w.policy = { idleCompaction: true }
  await w.advance(19 * MIN)
  expect(idleSkips(w)).toEqual(['native-on'])
  expect(w.submits.length).toBe(0)
  expect(idleModes(w)).toEqual(['vetoed/on', 'on/check'])
  await w.advance(7 * MIN)
  expect(w.rowsOf('idle_silent').length).toBe(1)
  if (IDLE) expect(w.submits).toEqual([idleText(w, '55')])
  else expect(idleSkips(w)).toEqual(['native-on', 'no-asset'])
})

test('AT-IA-04: idle_mode is written once per change, not per turn; off reads native and arms nothing', { options: TURN }, async ($, on) => {
  const w = new World().install(on)
  w.policy = NATIVE_OFF
  w.rateLimits = LIMITS
  await w.start($)
  await humanTurn($, w)
  await humanTurn($, w)
  await humanTurn($, w)
  expect(idleModes(w)).toEqual(['vetoed/on'])
  w.policy = {}
  await humanTurn($, w)
  await humanTurn($, w)
  expect(idleModes(w)).toEqual(['vetoed/on', 'on/check'])
  // The 49-min turn armed by the earlier turn ends gave way to the 55.5-min check.
  await w.advance(49 * MIN)
  expect([w.submits.length, idleSkips(w).length]).toEqual([0, 0])
  await w.advance(7 * MIN)
  expect(w.submits.length + idleSkips(w).length).toBe(1)
})

test('AT-IC-06 / IA-1: off arms nothing even with native idle off', { options: { ...TURN, idle_handoff_turn: 'off' } }, async ($, on) => {
  const w = new World().install(on)
  w.policy = NATIVE_OFF
  w.rateLimits = LIMITS
  await w.start($)
  await humanTurn($, w)
  await w.advance(120 * MIN)
  expect([w.submits.length, idleSkips(w).length]).toEqual([0, 0])
  expect(idleModes(w)).toEqual(['vetoed/off'])
})

// ---- Owner xxxxxxxx-17 ("Check outcome at 55.5m"): with native idle on or unreadable, the plugin
// checks its own records about 55.5 min after the turn end and runs the handoff turn while the
// cache is warm when native did not compact; owner xxxxxxxx-38 ("Measure more first"): not while
// agents run. SPEC-DELTAS AT-IS-01..AT-IS-07.
const silentRows = (w: World) => w.rowsOf('idle_silent').map(r => [r.gap_s, r.tokens, r.agents, r.served_hint ?? null])
const opens = (w: World) => w.callsOf('handoff-turn').filter(c => c.args[0] === 'open').map(c => w.flag(c, '--reason'))
const served = (mode: string) => JSON.stringify({ numStartups: 3, cachedGrowthBookFeatures: { tengu_other: true, tengu_sunny_locket: { mode } } })

test('AT-IS-01: native on, no compaction since the turn end: nothing at 49 min; at 55.5 min one idle_silent row and the handoff turn (idle for 55 minutes); no compaction or continue after it', { options: TURN }, async ($, on) => {
  const w = new World().install(on)
  w.rateLimits = LIMITS
  await w.start($)
  await humanTurn($, w)
  await w.advance(55 * MIN)
  expect(w.submits.length + idleSkips(w).length + w.rowsOf('idle_silent').length).toBe(0)
  await w.advance(30 * 1000)
  expect(silentRows(w)).toEqual([[3330, 260000, 0, null]])
  if (!IDLE) {
    expect(idleSkips(w)).toEqual(['no-asset'])
    return
  }
  expect(w.submits).toEqual([idleText(w, '55')])
  expect(opens(w)).toEqual(['idle'])
  await w.turnStart($, '')
  expect(w.rowsOf('handoff_turn_start').map(r => [r.reason, r.gap_s])).toEqual([['idle', 3330]])
  w.publish(w.lastHt() ?? '', PUBLISHED)
  await w.turnEnd($, 'Handoff written.')
  await w.advance(10 * MIN)
  expect([w.compacts.length, w.submits.length]).toEqual([0, 1])
})

test('AT-IS-02: an idle compaction at 54 min: handoff_skipped native-fired at 55.5 min, no submit, no idle_silent row', { options: ON }, async ($, on) => {
  const w = new World().install(on)
  w.rateLimits = LIMITS
  await w.start($)
  await humanTurn($, w)
  await w.advance(54 * MIN)
  await raiseCompact($, { trigger: 'auto' })
  expect(hasIdleFlag(w, 0)).toBe(true)
  await w.advance(2 * MIN)
  expect(idleSkips(w)).toEqual(['native-fired'])
  expect([w.submits.length, w.rowsOf('idle_silent').length]).toEqual([0, 0])
})

test('AT-IS-02: another main compaction since the turn end (manual): compacted; one before the turn end does not count', { options: TURN }, async ($, on) => {
  const w = new World().install(on)
  w.rateLimits = LIMITS
  await w.start($)
  await raiseCompact($, { trigger: 'manual' })
  await w.advance(MIN)
  await humanTurn($, w)
  await w.advance(10 * MIN)
  await raiseCompact($, { trigger: 'manual' })
  await w.advance(46 * MIN)
  expect(idleSkips(w)).toEqual(['compacted'])
  expect(w.submits.length).toBe(0)
  await humanTurn($, w)
  await w.advance(56 * MIN)
  expect(w.rowsOf('idle_silent').length).toBe(1)
  expect(w.submits.length + idleSkips(w).length).toBe(2)
})

// Owner 2026-10-27 03:4x ("Compact (Recommended)", replaces xxxxxxxx-38 "Measure more first"):
// while agents run (native never compacts then) the check compacts the session itself: the
// same self-call as the plugin's other compactions, an idle dispatch record and resume block,
// no continue. SPEC-DELTAS AT-IS-03, AT-IS-08..AT-IS-10.
const idleCompacts = (w: World) => w.rowsOf('idle_compact').map(r => [r.gap_s, r.tokens, r.agents])
const RUNNING = [{ id: 'sub-1', status: 'running' }, { id: 'sub-0', status: 'completed' }]

test('AT-IS-03: agents running at the check (a listed subagent, or a workflow agent\'s turn the list does not show): idle_silent with the count, then one idle_compact row and the plugin\'s own idle compaction (mod-self, idle dispatch), no submit; ended agents do not count', { options: ON }, async ($, on) => {
  const w = new World().install(on)
  w.rateLimits = LIMITS
  w.agents = RUNNING
  await w.start($)
  await humanTurn($, w)
  await w.advance(56 * MIN)
  expect(silentRows(w)).toEqual([[3330, 260000, 1, null]])
  expect(idleCompacts(w)).toEqual([[3330, 260000, 1]])
  expect(idleSkips(w)).toEqual([])
  expect(w.compacts.length).toBe(1)
  const d = w.callsOf('dispatch')[0]
  expect([w.flag(d, '--channel'), w.flag(d, '--trigger'), w.flag(d, '--midturn'), hasIdleFlag(w, 0), d?.args.includes('--idle-gap-s=3330')])
    .toEqual(['mod-self', 'plugin', 'false', true, true])
  // Shaped: the plugin's own instructions, with the dispatch's nonce.
  expect(markerNonce(w, w.compacts[0]?.instructions)).toBe(w.flag(d, '--nonce'))
  expect(w.rowsOf('compacted').map(r => r.skip)).toEqual([null])
  expect(w.submits.length).toBe(0)
  // A workflow's agent: only its turn shows it; the list cannot be read at all here.
  w.agents = undefined
  await $.turn.start({ text: 'work', turnId: 'wf-t1', agentId: 'wf-agent-1' } as never)
  await humanTurn($, w)
  await w.advance(56 * MIN)
  expect(idleCompacts(w).map(r => r[2])).toEqual([1, 1])
  expect(w.rowsOf('idle_silent').map(r => r.agents)).toEqual([1, 1])
  expect(w.compacts.length).toBe(2)
  // Its turn ends: with no agent left the next check compacts all the same at 200K and more (lane
  // B, owner Q2: instead of the handoff turn), with agents 0.
  await $.turn.complete({ answer: 'done', durationMs: 1, isAborted: false, turnId: 'wf-t1', reason: 'answer', agentId: 'wf-agent-1' } as never)
  w.agents = [{ id: 'sub-1', status: 'completed' }]
  await w.advance(10 * MIN)
  await humanTurn($, w)
  await w.advance(56 * MIN)
  expect(w.rowsOf('idle_silent').map(r => r.agents)).toEqual([1, 1, 0])
  expect([w.compacts.length, idleCompacts(w).map(r => r[2])]).toEqual([3, [1, 1, 0]])
  expect(w.submits.length + idleSkips(w).length).toBe(0)
})

test('AT-IS-08: after the idle compaction while agents run: no continue; the turn an agent\'s result opens gets the idle resume block; not counted for the thrash rule', { options: ON }, async ($, on) => {
  const w = new World().install(on)
  w.rateLimits = LIMITS
  w.agents = RUNNING
  await w.start($)
  await humanTurn($, w)
  await w.advance(56 * MIN)
  expect(w.compacts.length).toBe(1)
  await w.advance(10 * MIN)
  expect([w.submits.length, w.rowsOf('continue').length]).toEqual([0, 0])
  await w.userTurn($, 'Agent sub-1 finished.', 'task-notification')
  const block = blockOf(w, await $.prompt.context({ blocks: [] })) ?? ''
  expect(block).toContain(SID_A)
  const idle = lineOf(w, ['idle'])
  expect(idle === undefined).toBe(!hasTag('resume-context', 'idle'))
  if (idle !== undefined) expect(block).toContain(idle)
  // Two turns that end at the target, with a plugin compaction between them: had the idle
  // compaction counted, both would read as refilled and make a thrash halt.
  w.tokens = 610000
  await w.turnEnd($)
  await w.advance(5000)
  expect(w.compacts.length).toBe(2)
  await w.turnStart($)
  await w.turnEnd($)
  expect(w.rowsOf('thrash').length).toBe(0)
})

test('AT-IS-09: the idle compaction refused (a turn running, or a headless host): one compact_rejected row, no retry, no submit; the next try needs another turn end', { options: ON }, async ($, on) => {
  const w = new World().install(on)
  w.rateLimits = LIMITS
  w.agents = RUNNING
  w.compactMode = 'reject'
  await w.start($)
  await humanTurn($, w)
  await w.advance(56 * MIN)
  expect([w.compacts.length, w.rowsOf('compact_rejected').map(r => r.attempt)]).toEqual([1, [1]])
  await w.advance(120 * MIN)
  expect([w.compacts.length, w.rowsOf('compact_rejected').length, w.submits.length, idleCompacts(w).length]).toEqual([1, 1, 0, 1])
  // A hook-side skip is logged the same way and not retried either.
  w.compactMode = { skip: 'not available in a headless session' }
  await w.userTurn($, 'Agent sub-1 progress.', 'task-notification')
  w.tokens = 260000
  await w.turnEnd($)
  await w.advance(56 * MIN)
  expect([w.compacts.length, w.rowsOf('compacted').filter(r => r.skip !== null).length]).toEqual([2, 1])
  await w.advance(120 * MIN)
  expect([w.compacts.length, w.submits.length]).toEqual([2, 0])
})

// The idle compaction's own guards (AT-IS-10): below Claude Code's idle floor, `triggers` false,
// halt mode, and native idle off in the settings (the 49-min path, no check) compact nothing.
const AGENT_SKIPS: { name: string; why: string | null; tokens?: number; origin?: string; options?: Record<string, unknown>; setup?: (w: World) => void; silent: number }[] = [
  { name: 'below 200K', why: 'small', tokens: 150000, silent: 0 },
  { name: 'triggers off', why: 'triggers-off', options: { triggers: false }, silent: 1 },
  // A person's turn clears halt: here a background result's turn ends the last one.
  { name: 'halt', why: 'halted', origin: 'task-notification', setup: w => { w.files.set(`${WATCH}/${SID_A}/halt.json`, JSON.stringify({ active: true, reason: 'thrash' })) }, silent: 1 },
  { name: 'native off', why: null, options: { idle_compact: 'off' }, setup: w => { w.policy = NATIVE_OFF }, silent: 0 },
]
for (const c of AGENT_SKIPS) {
  test(`AT-IS-10 (${c.name}): agents running, ${c.why === null ? 'the 49-min turn path' : `handoff_skipped {why: ${c.why}, reason: idle}`}: no idle_compact row, no compaction`, { options: { ...ON, ...(c.options ?? {}) } }, async ($, on) => {
    const w = new World().install(on)
    w.rateLimits = LIMITS
    w.agents = RUNNING
    c.setup?.(w)
    await w.start($)
    await w.userTurn($, 'next step please', c.origin ?? 'composer')
    w.tokens = c.tokens ?? 260000
    await w.turnEnd($)
    await w.advance(56 * MIN)
    if (c.why !== null) expect(idleSkips(w)).toEqual([c.why])
    expect([w.compacts.length, idleCompacts(w).length, w.rowsOf('idle_silent').length]).toEqual([0, 0, c.silent])
  })
}

test('AT-IS-04: the served hint (2b) is logged in idle_mode and idle_silent, never decides: mode off or compact, the check runs the same', { options: TURN }, async ($, on) => {
  const w = new World().install(on)
  w.rateLimits = LIMITS
  w.files.set(HOME + '/.claude.json', served('off'))
  await w.start($)
  await humanTurn($, w)
  expect(w.rowsOf('idle_mode').map(r => [r.native, r.plugin_turn, r.served_hint])).toEqual([['on', 'check', 'off']])
  w.files.set(HOME + '/.claude.json', served('compact'))
  await humanTurn($, w)
  await humanTurn($, w)
  expect(w.rowsOf('idle_mode').map(r => r.served_hint)).toEqual(['off', 'compact'])
  // The cache reads `off` when the check fires: logged, and the handoff turn runs all the same.
  w.files.set(HOME + '/.claude.json', served('off'))
  await w.advance(56 * MIN)
  expect(silentRows(w)).toEqual([[3330, 260000, 0, 'off']])
  if (IDLE) expect([w.submits, idleSkips(w)]).toEqual([[idleText(w, '55')], []])
  else expect([w.submits.length, idleSkips(w)]).toEqual([0, ['no-asset']])
  // A file that is not JSON, or a mode that is not one short word, gives no hint.
  w.files.set(HOME + '/.claude.json', '{"cachedGrowthBookFeatures": ')
  await w.advance(10 * MIN)
  await humanTurn($, w)
  expect(w.rowsOf('idle_mode').map(r => r.served_hint ?? null)).toEqual(['off', 'compact', null])
  w.files.set(HOME + '/.claude.json', served('Compact Now'))
  await humanTurn($, w)
  expect(w.rowsOf('idle_mode').length).toBe(3)
})

test('AT-IS-05: below 200K no idle_silent row (native would not compact there either): handoff_skipped small', { options: ON }, async ($, on) => {
  const w = new World().install(on)
  w.rateLimits = LIMITS
  await w.start($)
  await humanTurn($, w, 150000)
  await w.advance(56 * MIN)
  expect(w.rowsOf('idle_silent').length).toBe(0)
  expect(idleSkips(w)).toEqual(['small'])
})

test('AT-IS-06: a persisted check re-arms at load and reads the persisted compaction record: native-fired; without one it runs', { options: ON }, async ($, on) => {
  const w = new World().install(on, {
    ['idle_due:' + SID_A]: { due: T0 + 10 * MIN, sid: SID_A, episode: { since: T0 - 46 * MIN, done: false }, kind: 'check', end: T0 - 45.5 * MIN },
    ['idle_seen:' + SID_A]: { at: T0 - 2 * MIN, idle: true },
  })
  w.rateLimits = LIMITS
  w.tokens = 260000
  await w.start($)
  await w.advance(10 * MIN)
  expect(idleSkips(w)).toEqual(['native-fired'])
})

test('AT-IS-06: a persisted check with an older compaction record: native silent, one idle_silent row', { options: ON }, async ($, on) => {
  const w = new World().install(on, {
    ['idle_due:' + SID_A]: { due: T0 + 10 * MIN, sid: SID_A, episode: { since: T0 - 46 * MIN, done: false }, kind: 'check', end: T0 - 45.5 * MIN },
    ['idle_seen:' + SID_A]: { at: T0 - 50 * MIN, idle: true },
  })
  w.rateLimits = LIMITS
  w.tokens = 260000
  await w.start($)
  await w.advance(10 * MIN)
  expect(silentRows(w)).toEqual([[3330, 260000, 0, null]])
  expect(idleSkips(w).includes('native-fired')).toBe(false)
})

test('AT-IS-07: native off keeps the 49-min turn (no check, no idle_silent); a person\'s prompt cancels the check', { options: TURN }, async ($, on) => {
  const w = new World().install(on)
  w.policy = NATIVE_OFF
  w.rateLimits = LIMITS
  await w.start($)
  await humanTurn($, w)
  await w.advance(49 * MIN)
  expect(w.submits.length + idleSkips(w).length).toBe(1)
  expect(w.rowsOf('idle_silent').length).toBe(0)
  w.policy = {}
  await humanTurn($, w)
  await w.advance(30 * MIN)
  await w.userTurn($, 'back')
  await w.advance(30 * MIN)
  expect(w.rowsOf('idle_silent').length).toBe(0)
})

test('AT-IS-02: an idle compaction still running at 55.5 min (a slow summary call): busy, no idle_silent row, no submit', { options: ON }, async ($, on) => {
  const w = new World().install(on)
  w.rateLimits = LIMITS
  await w.start($)
  await humanTurn($, w)
  await w.advance(54 * MIN)
  let release!: () => void
  w.compactGate = new Promise<void>(r => { release = r })
  const running = raiseCompact($, { trigger: 'auto' })
  await w.advance(2 * MIN)
  expect(idleSkips(w)).toEqual(['busy'])
  expect([w.submits.length, w.rowsOf('idle_silent').length]).toEqual([0, 0])
  release()
  await running
  await w.settle()
})

// The check's own guards (AT-IS-02): a changed session and a busy session are no idle break (no
// idle_silent row); `triggers` false stands it down after the row.
const CHECK_SKIPS: { why: string; options?: Record<string, unknown>; setup?: (w: World) => void; silent: number }[] = [
  { why: 'session-changed', setup: w => { w.sid = SID_B }, silent: 0 },
  { why: 'triggers-off', options: { triggers: false }, silent: 1 },
]
for (const c of CHECK_SKIPS) {
  test(`AT-IS-02 (${c.why}): native on, the 55.5-min check: handoff_skipped {why: ${c.why}, reason: idle}, no submit`, { options: { ...ON, ...(c.options ?? {}) } }, async ($, on) => {
    const w = new World().install(on)
    w.rateLimits = LIMITS
    await w.start($)
    await humanTurn($, w)
    await w.advance(55 * MIN)
    c.setup?.(w)
    await w.advance(MIN)
    expect(idleSkips(w)).toEqual([c.why])
    expect([w.submits.length, w.rowsOf('idle_silent').length]).toEqual([0, c.silent])
  })
}

test('AT-IS-02 (busy): a plugin compaction still preparing at 55.5 min (its checkpoint running, no compaction entered yet): busy, no idle_silent row, no submit', { options: ON }, async ($, on) => {
  const w = new World().install(on)
  w.rateLimits = LIMITS
  await w.start($)
  let release!: () => void
  const gate = new Promise<void>(r => { release = r })
  w.atHelper = async sub => {
    if (sub === 'checkpoint') await gate
  }
  await humanTurn($, w, 410000)
  await w.advance(2000)
  expect(w.callsOf('checkpoint').length + w.compacts.length).toBe(0)
  await w.advance(56 * MIN)
  expect(w.compacts.length).toBe(0)
  expect(idleSkips(w)).toEqual(['busy'])
  expect([w.submits.length, w.rowsOf('idle_silent').length]).toEqual([0, 0])
  w.atHelper = undefined
  release()
  await w.settle()
})
