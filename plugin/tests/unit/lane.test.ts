// Away digest phase 1 (owner 2026-10-27 12:5x, xxxxxxxx-05/-06/-08/-09; AWAY-DIGEST §11): the
// work lane's Status from the summary, re-checked by code; finished or blocked lanes show the
// digest instead of continuing; the digest turn right after an idle compaction with nothing
// running (`idle_digest: submit`, the default) or none (`return`); the re-check of later turns.
import { expect, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { Tag } from '../../hooks/lib/assemble'
import { assemble, hasTag } from '../../hooks/lib/assemble'
import { DEFAULTS, parseOptions } from '../../hooks/lib/config'
import type { LaneFacts } from '../../hooks/lib/lane'
import { digestLine, laneFacts, laneOf } from '../../hooks/lib/lane'
import { SID_A, WATCH, World, raiseCompact } from './harness.test'

const HAS = hasTag('resume-context', 'idle-done')
const M = { running: 0, midturn: false, nonok: false, driver: false }
const F: LaneFacts = { status: 'finished', todo: 0, done: 2, unmarked: 0, step1: 'none', unstable: false }

// ---- the parser

test('laneFacts: Status word, step marks, Step 1 and a half-done step from the summary form', () => {
  const text = [
    '# LAB-42 — retry shipped',
    '## Resume here',
    'Status: hard-blocked (blocked: all left waits on the user; soft: a job still runs) · Acuity: watch · State: x (checkpoint: clean)',
    'Step 1: `git push` — for "ship it"',
    '## Next steps',
    '1. `git push` — done when the branch is on the remote · todo; gated: ask user: push (! git push)',
    '2. run the tests — done when green · done',
    '3. tidy the notes',
  ].join('\n')
  expect(laneFacts(text)).toEqual({ status: 'hard-blocked', todo: 1, done: 1, unmarked: 1, step1: 'set', unstable: false })
  const inline = '## Resume here\nStatus: finished · Acuity: unstable · State: y\nStep 1: none\n## Next steps: 1. a — done when b · done 2. c — done when d · done\n'
  expect(laneFacts(inline)).toEqual({ status: 'finished', todo: 0, done: 2, unmarked: 0, step1: 'none', unstable: true })
  expect(laneFacts('no form here').status).toBe(null)
  expect(laneFacts('## Resume here\nStatus: working · State: z (checkpoint: MID-STEP 2, remaining 3)\nStep 1: `x` | proposed\n').step1).toBe('proposed')
  expect(laneFacts('## Resume here\nStatus: working · State: z (checkpoint: MID-STEP 2, remaining 3)\n').unstable).toBe(true)
})

// ---- the rule: the summary's Status leads, code re-checks

test('laneOf: each Status word as read, and the code corrections toward work or a truer blocked label', () => {
  expect(laneOf(F, M)).toEqual({ lane: 'finished', source: 'status', why: "the summary's Status line" })
  expect(laneOf({ ...F, status: 'working' }, M).lane).toBe('working')
  expect(laneOf({ ...F, status: 'hard-blocked' }, M).lane).toBe('hard-blocked')
  expect(laneOf({ ...F, status: 'soft-blocked' }, M).lane).toBe('soft-blocked')
  // A finished lane with a job running or a step still to do keeps working.
  expect(laneOf(F, { ...M, running: 1 })).toEqual({ lane: 'working', source: 'recheck', why: 'the summary says finished, but a job still runs' })
  expect(laneOf({ ...F, todo: 1 }, M).lane).toBe('working')
  expect(laneOf({ ...F, step1: 'set' }, M).lane).toBe('working')
  // Hard-blocked with a job running is soft-blocked (owner xxxxxxxx-06: something still runs).
  expect(laneOf({ ...F, status: 'hard-blocked' }, { ...M, running: 2 })).toEqual({ lane: 'soft-blocked', source: 'recheck', why: 'the summary says hard-blocked, but a job still runs' })
  // Never a stop the text did not ask for: mid-turn, a half-done step, a loop driver, no summary.
  expect(laneOf(F, { ...M, midturn: true }).lane).toBe('working')
  expect(laneOf({ ...F, unstable: true }, M).lane).toBe('working')
  expect(laneOf(F, { ...M, driver: true }).lane).toBe('working')
  expect(laneOf(undefined, M).lane).toBe('working')
})

test('laneOf: no Status code can read (none, an older word, not in the handoff form): the code re-check', () => {
  for (const status of [null, 'done', 'active', 'waiting-owner']) {
    // Every listed step marked done, Step 1 none, nothing running: finished.
    expect(laneOf({ ...F, status }, M)).toEqual({ lane: 'finished', source: 'recheck', why: 'no Status code could read, but every listed step is marked done' })
    // Anything else: working (today's behaviour).
    expect(laneOf({ ...F, status, unmarked: 1 }, M).lane).toBe('working')
    expect(laneOf({ ...F, status, done: 0 }, M).lane).toBe('working')
    expect(laneOf({ ...F, status }, { ...M, running: 1 }).lane).toBe('working')
  }
  expect(laneOf(F, { ...M, nonok: true }).source).toBe('recheck')
})

test('idle_digest: submit by default (owner xxxxxxxx-09); return; any other value reads as return with a note', () => {
  expect(DEFAULTS.idle_digest).toBe('submit')
  expect(parseOptions({}).idle_digest).toBe('submit')
  expect(parseOptions({ idle_digest: ' Return ' }).idle_digest).toBe('return')
  const bad = parseOptions({ idle_digest: 'later' })
  expect([bad.idle_digest, bad.notes.invalid]).toEqual(['return', ['idle_digest']])
})

// ---- through the kit

const RT = { session_id: SID_A, saved_copy: 'x', measured_at: 'x', remeasure: 'x', store: 'x', idle_used_at: 'x', lane: 'x', lane_why: 'x' }
/** The first words of the line `tag` adds to the plain block (undefined when this build lacks it). */
function head(w: World, tag: Tag): string | undefined {
  const plain = assemble(w.name, 'resume-context', ['prod-forbid'], RT).split('\n')
  const line = assemble(w.name, 'resume-context', ['prod-forbid', tag], RT).split('\n').find(l => !plain.includes(l))
  return line?.slice(0, 40)
}
const blockOf = (w: World, ctx: { blocks: readonly { name: string; text: string }[] }) => ctx.blocks.find(b => b.name === `${w.name}-resume`)?.text

/** A person's turn ends; the session sits idle 1,600 s; Claude Code compacts it (an idle dispatch). */
async function idleCompaction($: Engine, w: World): Promise<void> {
  await w.userTurn($)
  w.tokens = 150000
  await w.turnEnd($)
  await w.advance(1600 * 1000)
  await raiseCompact($, { trigger: 'auto' })
}

const FINISHED = 'Status: finished · Acuity: stable · State: done (checkpoint: clean)\nStep 1: none\n'

test('finished lane, nothing running, idle_digest submit (default): one digest turn right away with the [idle-done] block; no [idle]', async ($, on) => {
  const w = new World().install(on)
  w.resumeHere = FINISHED
  await w.start($)
  await idleCompaction($, w)
  expect(w.submits).toEqual([])
  await w.advance(5000)
  if (!HAS) return
  expect(w.submits.length).toBe(1)
  const sent = w.submits[0] ?? ''
  expect(sent.startsWith(digestLine(w.name))).toBe(true)
  expect(sent).toContain(head(w, 'idle-done') ?? '')
  expect(sent).toContain('code reads the work lane as finished')
  expect(sent).not.toContain(head(w, 'idle') ?? '')
  expect(w.rowsOf('digest_submit').map(r => [r.lane, r.result])).toEqual([['finished', 'submitted']])
  expect(w.rowsOf('lane_outcome').map(r => [r.status, r.lane, r.source, r.at])).toEqual([['finished', 'finished', 'status', 'build'], ['finished', 'finished', 'status', 'submit']])
  // The submitted turn starts: the block went with it, so prompt.context adds none.
  await w.turnStart($, sent)
  expect(blockOf(w, await $.prompt.context({ blocks: [] }))).toBe(undefined)
})

test('idle_digest return: no turn; the person\'s return gets the [idle-done] block (its pointer branch)', { options: { idle_digest: 'return' } }, async ($, on) => {
  const w = new World().install(on)
  w.resumeHere = 'Status: hard-blocked · Acuity: stable · State: waits on the push approval (checkpoint: clean)\nStep 1: `git push` — for "ship"\n'
  await w.start($)
  await idleCompaction($, w)
  await w.advance(60 * 1000)
  expect(w.submits).toEqual([])
  expect(w.rowsOf('digest_submit').map(r => r.result)).toEqual(HAS ? ['skipped:return'] : [])
  await w.userTurn($, 'back')
  const block = blockOf(w, await $.prompt.context({ blocks: [] })) ?? ''
  if (!HAS) return
  expect(block).toContain(head(w, 'idle-done') ?? '')
  expect(block).toContain('code reads the work lane as hard-blocked')
  expect(block).toContain("The user's own message opened this turn: only ≤5 lines of it")
})

test('working lane (the summary says working, or an older word): today\'s [idle] and no digest turn', async ($, on) => {
  const w = new World().install(on)
  w.resumeHere = 'Status: working · Acuity: stable · State: x (checkpoint: clean)\nStep 1: `make test` — for "go on"\n'
  await w.start($)
  await idleCompaction($, w)
  await w.advance(5000)
  expect(w.submits).toEqual([])
  expect(w.rowsOf('digest_submit')).toEqual([])
  await w.userTurn($, 'Background task finished.', 'task-notification')
  const block = blockOf(w, await $.prompt.context({ blocks: [] })) ?? ''
  const idle = head(w, 'idle')
  if (idle !== undefined) expect(block).toContain(idle)
  const done = head(w, 'idle-done')
  if (done !== undefined) expect(block).not.toContain(done)
})

test('finished but a step still marked todo: working ([idle]); the row says recheck', async ($, on) => {
  const w = new World().install(on)
  w.resumeHere = FINISHED + '## Next steps\n1. ship — done when merged · todo\n'
  await w.start($)
  await idleCompaction($, w)
  await w.advance(5000)
  expect(w.submits).toEqual([])
  expect(w.rowsOf('lane_outcome').map(r => [r.status, r.lane, r.source])).toEqual([['finished', 'working', 'recheck']])
})

test('halt mode on: [idle-halt], never [idle-done], and no digest turn', async ($, on) => {
  const w = new World().install(on)
  w.files.set(`${WATCH}/${SID_A}/halt.json`, JSON.stringify({ active: true, reason: 'thrash' }))
  w.resumeHere = FINISHED
  await w.start($)
  await w.userTurn($, 'Background task finished.', 'task-notification')
  w.tokens = 150000
  await w.turnEnd($)
  await w.advance(1600 * 1000)
  await raiseCompact($, { trigger: 'auto' })
  await w.advance(5000)
  expect(w.submits).toEqual([])
  await w.userTurn($, 'Another background task finished.', 'task-notification')
  const block = blockOf(w, await $.prompt.context({ blocks: [] })) ?? ''
  const done = head(w, 'idle-done')
  if (done !== undefined) expect(block).not.toContain(done)
  const halt = head(w, 'idle-halt')
  if (halt !== undefined) expect(block).toContain(halt)
})

test('hard-blocked with an agent running: soft-blocked, no digest turn (its result opens a turn); that turn gets [idle-done]; when the agent has ended, the next result turn gets the hard-blocked note', async ($, on) => {
  const w = new World().install(on)
  w.resumeHere = 'Status: hard-blocked · Acuity: watch · State: waits on you (checkpoint: clean)\nStep 1: none\n'
  w.agents = [{ id: 'a1', status: 'running' }, { id: 'a2', status: 'running' }]
  await w.start($)
  await idleCompaction($, w)
  await w.advance(5000)
  expect(w.submits).toEqual([])
  if (!HAS) return
  expect(w.rowsOf('digest_submit').map(r => [r.lane, r.result])).toEqual([['soft-blocked', 'skipped:running']])
  // The first agent's result: one still runs, so the lane is soft-blocked and the turn gets the digest line.
  w.agents = [{ id: 'a1', status: 'completed' }, { id: 'a2', status: 'running' }]
  await w.userTurn($, 'Agent a1 finished.', 'task-notification')
  const first = blockOf(w, await $.prompt.context({ blocks: [] })) ?? ''
  expect(first).toContain('code reads the work lane as soft-blocked')
  await w.turnEnd($)
  // The last agent's result: nothing runs now, so the note says hard-blocked.
  w.agents = [{ id: 'a1', status: 'completed' }, { id: 'a2', status: 'completed' }]
  await w.userTurn($, 'Agent a2 finished.', 'task-notification')
  const note = blockOf(w, await $.prompt.context({ blocks: [] })) ?? ''
  expect(note).toContain('code reads the work lane as hard-blocked')
  expect(note).toContain('A result that unblocks a step makes it working again')
  expect(w.rowsOf('lane_outcome').map(r => [r.lane, r.at])).toEqual([['soft-blocked', 'build'], ['soft-blocked', 'delivery'], ['hard-blocked', 'recheck']])
  await w.turnEnd($)
  // No change since: a third result turn gets nothing more.
  await w.userTurn($, 'A shell finished.', 'task-notification')
  expect(blockOf(w, await $.prompt.context({ blocks: [] }))).toBe(undefined)
  await w.turnEnd($)
  // The person is back: the episode ends; the again-block carries the [idle-done] pointer branch.
  await w.userTurn($, 'back')
  const back = blockOf(w, await $.prompt.context({ blocks: [] })) ?? ''
  expect(back).toContain('code reads the work lane as hard-blocked')
  await w.turnEnd($)
  // The episode ended with the person's turn: a later result turn gets no note.
  w.agents = []
  await w.userTurn($, 'A late shell finished.', 'task-notification')
  expect(blockOf(w, await $.prompt.context({ blocks: [] }))).toBe(undefined)
})

test('a prompt entering before the digest turn: no submit (that turn gets the block)', async ($, on) => {
  const w = new World().install(on)
  w.resumeHere = FINISHED
  await w.start($)
  await idleCompaction($, w)
  await w.userTurn($, 'back already')
  await w.advance(5000)
  expect(w.submits).toEqual([])
  if (HAS) expect(w.rowsOf('digest_submit').map(r => r.result)).toEqual(['skipped:busy'])
})

test('max_auto_continues_per_hour 0: no digest turn', { options: { max_auto_continues_per_hour: 0 } }, async ($, on) => {
  const w = new World().install(on)
  w.resumeHere = FINISHED
  await w.start($)
  await idleCompaction($, w)
  await w.advance(5000)
  expect(w.submits).toEqual([])
  if (HAS) expect(w.rowsOf('digest_submit').map(r => r.result)).toEqual(['skipped:disabled'])
})
