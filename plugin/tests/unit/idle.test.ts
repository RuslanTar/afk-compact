// U tests through the kit: idle compaction and the pre-idle handoff turn (IC-1; MOD-SPEC §2.5
// idle rule, §3.4 delivery rule, §9 halt and /clear guards, §9.4). Cases that run the pre-idle
// turn need the `[submit-idle]` lines of handoff-turn.txt; a build without them answers
// `no-asset`, and those cases check that instead.
import { expect, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import { assemble, hasTag, leftovers, tagOnly } from '../../hooks/lib/assemble'
import { storeWord } from '../../hooks/lib/deps'
import { maxCalls, submitText } from '../../hooks/lib/handoff-turn'
import { HOME, SID_A, SID_B, T0, WATCH, World, markerNonce, raiseCompact } from './harness.test'

const IDLE = hasTag('handoff-turn', 'submit-idle')
// IA-1..3 (idle D3, owner 2026-10-23 02:4x): `auto` arms the pre-idle turn only while Claude
// Code's own idle compaction is off, read from the settings (`idleCompaction`, `autoCompactEnabled`).
const ON = { idle_handoff_turn: 'auto', precompact_turn: 'code' }
const NATIVE_OFF: Record<string, unknown> = { idleCompaction: false }
const MIN = 60000
const LIMITS = [{ percentUsed: 12 }, { percentUsed: 30 }]
const PUBLISHED = HOME + '/.claude/handoffs/r/LAB-42/2026-10-21_15-00-00_5e55a001_handoff.md'
const SHOWN = '~/.claude/handoffs/r/LAB-42/2026-10-21_15-00-00_5e55a001_handoff.md'

const idleText = (w: World): string | undefined =>
  submitText(w.name, 'idle', { max_calls: String(maxCalls()), idle_min: '49', store: storeWord(w.root, w.name) ?? '' })
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
  const idle = assemble(w.name, 'resume-context', ['prod-forbid', 'idle'], { session_id: SID_A, saved_copy: 'x', measured_at: 'x', remeasure: 'x', store: 'x' })
  const line = idle.split('\n').find(l => !plain.split('\n').includes(l))
  expect(line === undefined).toBe(!hasTag('resume-context', 'idle'))
  if (line !== undefined) expect(block).toContain(line)
  const mid = assemble(w.name, 'resume-context', ['prod-forbid', 'midturn'], { session_id: SID_A, saved_copy: 'x', measured_at: 'x', remeasure: 'x', store: 'x' })
  const midLine = mid.split('\n').find(l => !plain.split('\n').includes(l))
  if (midLine !== undefined) expect(block).not.toContain(midLine)
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

// ID-3 (owner D2, 2026-10-23; SPEC-DELTAS AT-ID-03): a person coming back after a background
// result took an idle compaction's block gets one [idle-return] line on its own.
const BRIEF = 'git: main @ 9e9e9e9, dirty 2 · in flight: 0 running, 1 ended'
const RETURN = hasTag('resume-context', 'idle-return')

/** An idle dispatch whose block a task-notification turn takes; returns the block names it got. */
async function idleTakenByNotification($: Engine, w: World): Promise<string[]> {
  await w.start($)
  await humanTurn($, w, 150000)
  await w.advance(1600 * 1000)
  await raiseCompact($, { trigger: 'auto' })
  await w.userTurn($, 'Background task finished.', 'task-notification')
  const ctx = await $.prompt.context({ blocks: [] })
  await w.turnEnd($, 'Handled the result.')
  w.replies.measure = args => ({ exitCode: 0, stdout: (args.includes('--brief') ? BRIEF : w.measureBlock) + '\n' })
  return ctx.blocks.map(b => b.name)
}

const briefCalls = (w: World) => w.callsOf('measure').filter(c => c.args.includes('--brief'))

test('AT-ID-03: a composer prompt 700 s after a task-notification turn took the idle block gets one [idle-return] line (measure --compact --brief), as its own block; the next prompt none', async ($, on) => {
  const w = new World().install(on)
  expect(await idleTakenByNotification($, w)).toEqual([`${w.name}-resume`])
  await w.advance(700 * 1000)
  await w.userTurn($, 'back again')
  let ctx = await $.prompt.context({ blocks: [] })
  const line = tagOnly(w.name, 'resume-context', 'idle-return', { idle_return: BRIEF })
  expect(line === undefined).toBe(!RETURN)
  expect(briefCalls(w).length).toBe(1)
  if (line !== undefined) {
    expect(ctx.blocks).toEqual([{ name: `${w.name}-idle-return`, text: line }])
    expect(line).toContain(BRIEF)
    expect(leftovers(line)).toEqual([])
  }
  expect(w.rowsOf('idle_return').map(r => [r.age_s, r.sent])).toEqual([[700, line !== undefined]])
  await w.turnEnd($)
  await w.advance(700 * 1000)
  await w.userTurn($, 'and again')
  ctx = await $.prompt.context({ blocks: [] })
  expect(ctx.blocks).toEqual([])
  expect(briefCalls(w).length).toBe(1)
})

test('AT-ID-03: 500 s later: no [idle-return] and no brief measure; that human turn settles it (none 700 s after it either)', async ($, on) => {
  const w = new World().install(on)
  await idleTakenByNotification($, w)
  await w.advance(500 * 1000)
  await w.userTurn($, 'back soon')
  expect((await $.prompt.context({ blocks: [] })).blocks).toEqual([])
  await w.turnEnd($)
  await w.advance(700 * 1000)
  await w.userTurn($, 'later')
  expect((await $.prompt.context({ blocks: [] })).blocks).toEqual([])
  expect(briefCalls(w).length).toBe(0)
  expect(w.rowsOf('idle_return').length).toBe(0)
})

test('AT-ID-03: the brief measure fails: no line, one idle_return row with sent false', async ($, on) => {
  const w = new World().install(on)
  await idleTakenByNotification($, w)
  w.replies.measure = () => 'reject'
  await w.advance(700 * 1000)
  await w.userTurn($, 'back')
  expect((await $.prompt.context({ blocks: [] })).blocks).toEqual([])
  expect(w.rowsOf('idle_return').map(r => r.sent)).toEqual([false])
})

test('AT-ID-03: a person\'s turn takes the idle block itself: no [idle-return] later; a non-idle block taken by a notification: none either', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await humanTurn($, w, 150000)
  await w.advance(1600 * 1000)
  await raiseCompact($, { trigger: 'auto' })
  await w.userTurn($, 'hello')
  await $.prompt.context({ blocks: [] })
  await w.turnEnd($)
  await raiseCompact($, { trigger: 'manual' })
  await w.userTurn($, 'Background task finished.', 'task-notification')
  await $.prompt.context({ blocks: [] })
  await w.turnEnd($)
  await w.advance(700 * 1000)
  await w.userTurn($, 'back')
  expect((await $.prompt.context({ blocks: [] })).blocks).toEqual([])
  expect(briefCalls(w).length).toBe(0)
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
})

// ---- IC-1 D5: the pre-idle handoff turn (§9.4)

test('AT-IC-05: on, a turn ends answer at 260K with rate limits → due at 49 min; at fire: handoff-turn open --reason idle and one [submit-idle] submit; at its end no compaction, no continue', { options: ON }, async ($, on) => {
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

test('AT-IC-05: a main turn.start before the due cancels the timer', { options: ON }, async ($, on) => {
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

test('AT-IC-06: off arms no timer: no submit and no row', async ($, on) => {
  const w = new World().install(on)
  w.rateLimits = LIMITS
  await w.start($)
  await humanTurn($, w)
  await w.advance(120 * MIN)
  expect([w.submits.length, w.rowsOf('handoff_skipped').length]).toEqual([0, 0])
})

const SKIPS: { why: string; options?: Record<string, unknown>; world?: Partial<{ window: number }>; store?: Record<string, unknown>; setup?: (w: World) => void; tokens?: number; aborted?: boolean }[] = [
  { why: 'triggers-off', options: { triggers: false } },
  { why: 'small-window', world: { window: 200000 } },
  { why: 'session-changed', setup: w => { w.sid = SID_B } },
  { why: 'small', tokens: 150000 },
  { why: 'ttl-5m', setup: w => { w.rateLimits = [] } },
  { why: 'near-limit', setup: w => { w.rateLimits = [{ percentUsed: 12 }, { percentUsed: 95 }] } },
  { why: 'aborted', aborted: true },
  { why: 'cap', store: { ['ht:' + SID_A]: [T0 + 10 * MIN] } },
]
for (const c of SKIPS) {
  test(`AT-IC-06 (${c.why}): one handoff_skipped {why: ${c.why}, reason: idle}, no submit`, { options: { ...ON, ...(c.options ?? {}) } }, async ($, on) => {
    const w = new World(c.world ?? {}).install(on, c.store ?? {})
    w.policy = NATIVE_OFF
    w.rateLimits = LIMITS
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

test('AT-IC-06 (busy): a plugin compaction in flight at the due: busy', { options: ON }, async ($, on) => {
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

test('AT-IC-06 (episode), AT-IC-07: no human turn ended since the last pre-idle turn: episode; a task-notification turn neither ends nor starts one; a composer turn starts a new one', { options: ON }, async ($, on) => {
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

test('AT-IC-06 (published): a handoff published since the last human-origin turn: published', { options: { ...ON, max_auto_continues_per_hour: 0 } }, async ($, on) => {
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

test('AT-IC-13: after a published pre-idle handoff and no main turn, a native auto (idle) dispatch gets [handoff] with the path', { options: ON }, async ($, on) => {
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

// §9.4: a main turn.start, a prompt entering and session.end cancel the timer and forget the
// persisted due, so a reload of the same sid re-arms nothing the session already cancelled.
/** The last value the mod stored for this sid's due (null: forgotten; undefined: never written). */
function watchDue(on: Parameters<World['install']>[0]): () => unknown {
  let last: unknown
  // Registered before World.install, so it stands outside mock.store (first is outermost).
  on('store.set', { key: 'idle_due:' + SID_A }, (_$, e, next) => {
    last = e.value ?? null
    return next(e)
  })
  return () => last
}

test('AT-IC-14: a main turn.start forgets the persisted idle_due', { options: ON }, async ($, on) => {
  const dueOf = watchDue(on)
  const w = new World().install(on)
  w.policy = NATIVE_OFF
  await w.start($)
  await humanTurn($, w)
  expect(dueOf()).toBeTruthy()
  await w.turnStart($)
  expect(dueOf()).toBe(null)
})

test('AT-IC-14: a prompt entering forgets the persisted idle_due', { options: ON }, async ($, on) => {
  const dueOf = watchDue(on)
  const w = new World().install(on)
  w.policy = NATIVE_OFF
  await w.start($)
  await humanTurn($, w)
  expect(dueOf()).toBeTruthy()
  await $.prompt.submit({ text: 'back again', origin: { kind: 'composer' } } as never)
  expect(dueOf()).toBe(null)
})

test('AT-IC-14: session.end forgets the persisted idle_due', { options: ON }, async ($, on) => {
  const dueOf = watchDue(on)
  const w = new World().install(on)
  w.policy = NATIVE_OFF
  await w.start($)
  await humanTurn($, w)
  expect(dueOf()).toBeTruthy()
  await $.session.end(CLEAR as never)
  expect(dueOf()).toBe(null)
})

// ---- IA-1..3 (idle D3, owner 2026-10-23 02:4x): `auto` = the plugin's pre-idle turn only while
// Claude Code's own idle compaction is off; a failed settings read counts as on (O-9 provisional).
const idleModes = (w: World) => w.rowsOf('idle_mode').map(r => `${String(r.native)}/${String(r.plugin_turn)}`)

test('AT-IA-02: auto with idleCompaction false arms the timer; idle_mode off/on', { options: ON }, async ($, on) => {
  const w = new World().install(on)
  w.policy = NATIVE_OFF
  w.rateLimits = LIMITS
  await w.start($)
  await humanTurn($, w)
  await w.advance(49 * MIN)
  expect(w.submits.length + idleSkips(w).length).toBe(1)
  expect(idleModes(w)).toEqual(['off/on'])
})

test('AT-IA-02: auto with autoCompactEnabled false: native off (idle never fires without auto-compact), armed', { options: ON }, async ($, on) => {
  const w = new World().install(on)
  w.policy = { autoCompactEnabled: false }
  w.rateLimits = LIMITS
  await w.start($)
  await humanTurn($, w)
  await w.advance(49 * MIN)
  expect(w.submits.length + idleSkips(w).length).toBe(1)
  expect(idleModes(w)).toEqual(['off/on'])
})

for (const c of [{ name: 'idleCompaction true', policy: { idleCompaction: true } }, { name: 'the key absent', policy: {} }]) {
  test(`AT-IA-02: auto with ${c.name}: native on, no timer, idle_mode on/off`, { options: ON }, async ($, on) => {
    const w = new World().install(on)
    w.policy = c.policy
    w.rateLimits = LIMITS
    await w.start($)
    await humanTurn($, w)
    await w.advance(120 * MIN)
    expect([w.submits.length, idleSkips(w).length]).toEqual([0, 0])
    expect(idleModes(w)).toEqual(['on/off'])
  })
}

test('AT-IA-02: the settings read throws: native unknown, no timer (counts as on)', { options: ON }, async ($, on) => {
  const w = new World().install(on)
  w.settingsThrow = true
  w.rateLimits = LIMITS
  await w.start($)
  await humanTurn($, w)
  await w.advance(120 * MIN)
  expect([w.submits.length, idleSkips(w).length]).toEqual([0, 0])
  expect(idleModes(w)).toEqual(['unknown/off'])
})

test('AT-IA-03: armed while native off; native idle switched on before the fire: handoff_skipped {native-on, idle}, no submit', { options: ON }, async ($, on) => {
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
  expect(idleModes(w)).toEqual(['off/on', 'on/off'])
})

test('AT-IA-04: idle_mode is written once per change, not per turn; off reads native and arms nothing', { options: ON }, async ($, on) => {
  const w = new World().install(on)
  w.policy = NATIVE_OFF
  w.rateLimits = LIMITS
  await w.start($)
  await humanTurn($, w)
  await humanTurn($, w)
  await humanTurn($, w)
  expect(idleModes(w)).toEqual(['off/on'])
  w.policy = {}
  await humanTurn($, w)
  await humanTurn($, w)
  expect(idleModes(w)).toEqual(['off/on', 'on/off'])
  // The timer armed by the earlier turn ends was dropped when native idle came on.
  await w.advance(120 * MIN)
  expect([w.submits.length, idleSkips(w).length]).toEqual([0, 0])
})

test('AT-IC-06 / IA-1: off arms nothing even with native idle off', { options: { ...ON, idle_handoff_turn: 'off' } }, async ($, on) => {
  const w = new World().install(on)
  w.policy = NATIVE_OFF
  w.rateLimits = LIMITS
  await w.start($)
  await humanTurn($, w)
  await w.advance(120 * MIN)
  expect([w.submits.length, idleSkips(w).length]).toEqual([0, 0])
  expect(idleModes(w)).toEqual(['off/off'])
})
