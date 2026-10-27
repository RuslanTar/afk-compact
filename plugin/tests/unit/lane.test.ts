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
import { LANE_WHY_MAX, digestLine, laneFacts, laneOf, measuredRunning, notifiedTasks, startsWork } from '../../hooks/lib/lane'
import type { PendingResume } from '../../hooks/lib/deps'
import { ARMED_FILE, pendingRecord } from '../../hooks/lib/resume'
import { SID_A, T0, WATCH, World, raiseCompact } from './harness.test'

const HAS = hasTag('resume-context', 'idle-done')
const M = { running: 0, midturn: false, nonok: false, driver: false }
const F: LaneFacts = { status: 'finished', todo: 0, done: 2, unmarked: 0, free: 0, elsewhere: false, step1: 'none', gate: 'none', unstable: false }

// ---- the parser

test('laneFacts: Status word, step marks, Step 1 and a half-done step from the summary form', () => {
  const text = [
    '# LAB-42 — retry shipped',
    '## Resume here',
    'Status: hard-blocked (blocked: all left waits on the user; soft: a job still runs) · Acuity: watch · State: x (checkpoint: clean)',
    'Step 1: `git push` — for "ship it"',
    'Gate: protected-branch push · Don\'t: x',
    '## Next steps',
    '1. `git push` — done when the branch is on the remote · todo; gated: ask user: push (! git push)',
    '2. run the tests — done when green · done',
    '3. tidy the notes',
  ].join('\n')
  expect(laneFacts(text)).toEqual({ status: 'hard-blocked', todo: 1, done: 1, unmarked: 1, free: 0, elsewhere: false, step1: 'set', gate: 'set', unstable: false })
  const inline = '## Resume here\nStatus: finished · Acuity: unstable · State: y\nStep 1: none\n## Next steps: 1. a — done when b · done 2. c — done when d · done\n'
  expect(laneFacts(inline)).toEqual({ status: 'finished', todo: 0, done: 2, unmarked: 0, free: 0, elsewhere: false, step1: 'none', gate: 'missing', unstable: true })
  // An item's last mark counts, and only a mark that ends its words (`· done when` is not one); a
  // step marked todo with no gate, ask, pending answer or wait can run.
  const marks = '## Resume here\nStatus: soft-blocked\nStep 1: none\nGate: none · Don\'t: x\n## Next steps\n1. run the suite · done when green · todo\n' +
    '2. ask user: deploy (! make deploy) · todo\n3. wait for B-1 — done when it ends · todo; waits on B-1\n   if red → fix\n- pending answer: the table\n'
  expect(laneFacts(marks)).toEqual({ status: 'soft-blocked', todo: 3, done: 0, unmarked: 0, free: 1, elsewhere: false, step1: 'none', gate: 'none', unstable: false })
  expect(laneFacts('## Resume here\nStatus: hard-blocked\nStep 1: ask user: push (! git push)\nGate: none\n').gate).toBe('set')
  expect(laneFacts('## Resume here\nStatus: finished\n## Next steps: see handoff\n')).toEqual(
    { status: 'finished', todo: 0, done: 0, unmarked: 0, free: 0, elsewhere: true, step1: 'missing', gate: 'missing', unstable: false })
  expect(laneFacts('no form here').status).toBe(null)
  expect(laneFacts('## Resume here\nStatus: working · State: z (checkpoint: MID-STEP 2, remaining 3)\nStep 1: `x` | proposed\n').step1).toBe('proposed')
  expect(laneFacts('## Resume here\nStatus: working · State: z (checkpoint: MID-STEP 2, remaining 3)\n').unstable).toBe(true)
})

// ---- the rule: the summary's Status leads, code re-checks

test('laneOf: each Status word as read, and the code corrections toward work or a truer blocked label', () => {
  expect(laneOf(F, M)).toEqual({ lane: 'finished', source: 'status', why: "the summary's Status line" })
  expect(laneOf({ ...F, status: 'working', step1: 'set', todo: 1 }, M)).toEqual({ lane: 'working', source: 'status', why: "the summary's Status line" })
  expect(laneOf({ ...F, status: 'hard-blocked' }, M).lane).toBe('hard-blocked')
  expect(laneOf({ ...F, status: 'soft-blocked' }, M).lane).toBe('soft-blocked')
  // A finished lane with a job running or a step still to do keeps working.
  expect(laneOf(F, { ...M, running: 1 })).toEqual({ lane: 'working', source: 'recheck', why: 'the summary says finished, but a job still runs' })
  expect(laneOf({ ...F, todo: 1 }, M).lane).toBe('working')
  expect(laneOf({ ...F, step1: 'set' }, M).lane).toBe('working')
  // Hard-blocked with a job running is soft-blocked (owner xxxxxxxx-06: something still runs).
  expect(laneOf({ ...F, status: 'hard-blocked' }, { ...M, running: 2 })).toEqual({ lane: 'soft-blocked', source: 'recheck', why: 'the summary says hard-blocked, but a job still runs' })
  // Never a stop the text did not ask for: mid-turn, a half-done step, a loop driver, no summary,
  // a summary not in the handoff form, work started after the block went out.
  expect(laneOf(F, { ...M, midturn: true }).lane).toBe('working')
  expect(laneOf({ ...F, unstable: true }, M).lane).toBe('working')
  expect(laneOf(F, { ...M, driver: true }).lane).toBe('working')
  expect(laneOf(undefined, M).lane).toBe('working')
  expect(laneOf(F, { ...M, nonok: true })).toEqual({ lane: 'working', source: 'recheck', why: 'the summary is not in the handoff form' })
  expect(laneOf({ ...F, status: 'hard-blocked' }, { ...M, superseded: true })).toEqual({ lane: 'working', source: 'recheck', why: 'work started after the summary' })
  // Finished needs every listed step marked done, Step 1 none (or proposed), the steps in the summary.
  expect(laneOf({ ...F, unmarked: 1 }, M).lane).toBe('working')
  expect(laneOf({ ...F, step1: 'missing' }, M).lane).toBe('working')
  expect(laneOf({ ...F, elsewhere: true }, M).lane).toBe('working')
  expect(laneOf({ ...F, step1: 'proposed' }, M).lane).toBe('finished')
  // A blocked Status with a step that can run is working (owner xxxxxxxx-08); Step 1 behind a gate is not.
  for (const status of ['hard-blocked', 'soft-blocked']) {
    expect(laneOf({ ...F, status, todo: 1, free: 1 }, M).lane).toBe('working')
    expect(laneOf({ ...F, status, step1: 'set', gate: 'none' }, M).lane).toBe('working')
    expect(laneOf({ ...F, status, step1: 'set', gate: 'set', todo: 1 }, M).lane).toBe(status)
  }
  // Working with every listed step marked done, Step 1 none and nothing running: finished (a
  // Status written while agents ran); with a unit running or a step left, working.
  expect(laneOf({ ...F, status: 'working' }, M)).toEqual({ lane: 'finished', source: 'recheck', why: 'the summary says working, but all steps are done, none runs' })
  expect(laneOf({ ...F, status: 'working' }, { ...M, running: 1 })).toEqual({ lane: 'working', source: 'status', why: "the summary's Status line" })
  expect(laneOf({ ...F, status: 'working', todo: 1 }, M).lane).toBe('working')
})

test('laneOf: every reason fits the @lane_why@ size tools/assemble budgets with', () => {
  let longest = ''
  const statuses = [null, 'working', 'finished', 'hard-blocked', 'soft-blocked', 'done', 'other']
  for (const status of statuses) for (const todo of [0, 1]) for (const free of [0, 1]) for (const unmarked of [0, 1])
    for (const elsewhere of [false, true]) for (const step1 of ['none', 'proposed', 'set', 'missing'] as const) for (const gate of ['none', 'set'] as const)
      for (const running of [0, 1]) for (const flag of ['', 'midturn', 'nonok', 'driver', 'superseded', 'unstable']) {
        const f: LaneFacts = { status, todo, done: 1, unmarked, free, elsewhere, step1, gate, unstable: flag === 'unstable' }
        const r = laneOf(f, { running, midturn: flag === 'midturn', nonok: flag === 'nonok', driver: flag === 'driver', superseded: flag === 'superseded' })
        if (r.why.length > longest.length) longest = r.why
      }
  expect(laneOf(undefined, M).why.length <= LANE_WHY_MAX).toBe(true)
  expect(longest.length <= LANE_WHY_MAX).toBe(true)
})

test('measuredRunning, notifiedTasks, startsWork: the units a measure lists, the tasks a notification ends, the calls that start work', () => {
  const m = 'Git: x\nIn flight (sidecar 2026-10-21 14:00 +0300):\n  b1 · shell · running\n  b2 · shell · completed\n  a1 · subagent · running\n' +
    '  w1 · workflow · pending · output /tmp/w1 (exists)\n  m1 · monitor · running\n  c1 · cron · scheduled\nEvidence (automatic copies):\n  x · y · running\n'
  expect(measuredRunning(m)).toEqual(['b1', 'w1'])
  expect(measuredRunning(undefined)).toEqual([])
  expect(notifiedTasks('<task-notification>\n<task-id>af63d8ad7bcf2ffd4</task-id>\n<status>completed</status>\n</task-notification>\n<task-id>b7</task-id>')).toEqual(['af63d8ad7bcf2ffd4', 'b7'])
  expect(notifiedTasks('no ids')).toEqual([])
  expect([startsWork('Agent', {}), startsWork('Workflow', {}), startsWork('Bash', { backgroundTaskId: 'b1' }), startsWork('Bash', { stdout: '' }), startsWork('Read', {})])
    .toEqual([true, true, true, false, false])
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
  // The last agent's result: nothing runs now, so the note beside its prompt says hard-blocked.
  w.agents = [{ id: 'a1', status: 'completed' }, { id: 'a2', status: 'completed' }]
  const note = await resultTurn($, w, 'Agent a2 finished.')
  expect(note.block).toBe(undefined)
  expect(note.ctx).toContain('code reads the work lane as hard-blocked')
  expect(note.ctx).toContain('A result that unblocks a step makes it working again')
  expect(w.rowsOf('lane_outcome').map(r => [r.lane, r.at])).toEqual([['soft-blocked', 'build'], ['soft-blocked', 'delivery'], ['hard-blocked', 'recheck']])
  await w.turnEnd($)
  // No change since: a third result turn gets nothing more.
  const third = await resultTurn($, w, 'A shell finished.')
  expect([third.ctx, third.block]).toEqual(['', undefined])
  await w.turnEnd($)
  // The person is back: the episode closes; the again-block carries the [idle-done] pointer branch.
  await w.userTurn($, 'back')
  expect(ctxOf(w)).toBe('')
  const back = blockOf(w, await $.prompt.context({ blocks: [] })) ?? ''
  expect(back).toContain('code reads the work lane as hard-blocked')
  await w.turnEnd($)
  // The episode ended with the person's turn: a later result turn gets no note.
  w.agents = []
  const late = await resultTurn($, w, 'A late shell finished.')
  expect([late.ctx, late.block]).toEqual(['', undefined])
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

// ---- review of the first build (fix round 1): each test failed on that build

/** What the model read beside the prompt of the newest turn (the plugin's `prompt.submit` context). */
const ctxOf = (w: World): string => (w.submitContexts[w.submitContexts.length - 1] ?? []).join('\n')
/** A background task's notification, as Claude Code words it (its `<task-id>` names the task). */
const notif = (id: string): string =>
  `<task-notification>\n<task-id>${id}</task-id>\n<status>completed</status>\n<summary>Agent "job" finished</summary>\n</task-notification>`
/**
 * A later turn not of a person's: what the plugin attached beside its prompt, and what a
 * `prompt.context` asked again would add (in a live session it is asked once per conversation).
 */
async function resultTurn($: Engine, w: World, text: string): Promise<{ ctx: string; block: string | undefined }> {
  await w.userTurn($, text, 'task-notification')
  const ctx = ctxOf(w)
  return { ctx, block: blockOf(w, await $.prompt.context({ blocks: [] })) }
}
const HARD = 'Status: hard-blocked · Acuity: watch · State: waits on you (checkpoint: clean)\nStep 1: none\n'
const shell = (id: string, status = 'running'): string =>
  `Git: main @ 3f9c2e1, 0 modified, 0 untracked\nIn flight (sidecar 2026-10-21 14:00 +0300):\n  ${id} · shell · ${status}\nEvidence: none`

test('H1: the note of a later result turn goes beside its prompt (prompt.submit context), since prompt.context is asked once per conversation', async ($, on) => {
  const w = new World().install(on)
  w.resumeHere = HARD
  w.agents = [{ id: 'a1', status: 'running' }, { id: 'a2', status: 'running' }]
  await w.start($)
  await idleCompaction($, w)
  await w.advance(5000)
  if (!HAS) return
  w.agents = [{ id: 'a1', status: 'completed' }, { id: 'a2', status: 'running' }]
  const first = await resultTurn($, w, notif('a1'))
  expect(first.block ?? '').toContain('code reads the work lane as soft-blocked')
  await w.turnEnd($)
  w.agents = [{ id: 'a1', status: 'completed' }, { id: 'a2', status: 'completed' }]
  const second = await resultTurn($, w, notif('a2'))
  expect(second.ctx).toContain('code reads the work lane as hard-blocked')
  expect(second.block).toBe(undefined)
  // A person's prompt ends the episode: no note beside it, and none for a later result turn.
  await w.turnEnd($)
  await w.userTurn($, 'back')
  expect(ctxOf(w)).toBe('')
  await w.turnEnd($)
  expect((await resultTurn($, w, notif('a9'))).ctx).toBe('')
})

test('H2: Status working at the compaction (agents ran then); every step marked done, Step 1 none; the last agent ends: the digest, not [idle]', async ($, on) => {
  const w = new World().install(on)
  w.resumeHere = 'Status: working · Acuity: watch · State: waits for B-1, B-2 (checkpoint: clean)\nStep 1: none\n## Next steps\n1. read the B-1 and B-2 results — done when read · done\n'
  w.agents = [{ id: 'a1', status: 'running' }, { id: 'a2', status: 'running' }]
  await w.start($)
  await idleCompaction($, w)
  await w.advance(5000)
  expect(w.submits).toEqual([])
  if (!HAS) return
  // One agent still runs: today's [idle].
  w.agents = [{ id: 'a1', status: 'completed' }, { id: 'a2', status: 'running' }]
  const first = await resultTurn($, w, notif('a1'))
  expect(first.block ?? '').toContain(head(w, 'idle') ?? '')
  await w.turnEnd($)
  // The last one ended: the lane reads finished, and the note asks for the digest.
  w.agents = [{ id: 'a1', status: 'completed' }, { id: 'a2', status: 'completed' }]
  const second = await resultTurn($, w, notif('a2'))
  expect(second.ctx).toContain('code reads the work lane as finished')
  expect(second.ctx).toContain('print the away digest')
})

test('H2: the same summary when the last agent\'s result opens the first turn: that block is [idle-done]', async ($, on) => {
  const v = new World().install(on)
  v.resumeHere = 'Status: working · Acuity: watch · State: waits for B-1 (checkpoint: clean)\nStep 1: none\n## Next steps\n1. read the B-1 result — done when read · done\n'
  v.agents = [{ id: 'b1', status: 'running' }]
  await v.start($)
  await idleCompaction($, v)
  await v.advance(5000)
  if (!HAS) return
  v.agents = [{ id: 'b1', status: 'completed' }]
  expect((await resultTurn($, v, notif('b1'))).block ?? '').toContain('code reads the work lane as finished')
})

test('H3: work started after a blocked or finished block supersedes the summary\'s Status: when it ends, no "start nothing" note', async ($, on) => {
  const w = new World().install(on)
  w.resumeHere = HARD
  w.agents = [{ id: 'a1', status: 'running' }]
  await w.start($)
  await idleCompaction($, w)
  await w.advance(5000)
  if (!HAS) return
  w.agents = [{ id: 'a1', status: 'completed' }]
  const first = await resultTurn($, w, notif('a1'))
  expect(first.block ?? '').toContain('code reads the work lane as hard-blocked')
  // The result unblocked a step: the model launches two agents.
  await $.tool.call({ tool: 'Agent', description: 'next step', prompt: 'do it', mode: 'standard' } as never)
  w.agents = [{ id: 'a1', status: 'completed' }, { id: 'a2', status: 'running' }, { id: 'a3', status: 'running' }]
  await w.turnEnd($)
  w.agents = [{ id: 'a1', status: 'completed' }, { id: 'a2', status: 'completed' }, { id: 'a3', status: 'running' }]
  const second = await resultTurn($, w, notif('a2'))
  await w.turnEnd($)
  w.agents = [{ id: 'a1', status: 'completed' }, { id: 'a2', status: 'completed' }, { id: 'a3', status: 'completed' }]
  const third = await resultTurn($, w, notif('a3'))
  for (const t of [second, third]) expect(t.ctx + (t.block ?? '')).not.toContain('start nothing')
})

test('H3: a finished lane whose kept messages held a new request: the model starts a background shell; its result gets no "start nothing" note', async ($, on) => {
  const v = new World().install(on)
  v.resumeHere = FINISHED
  await v.start($)
  await idleCompaction($, v)
  await v.advance(5000)
  if (!HAS) return
  expect(v.submits.length).toBe(1)
  await v.turnStart($, v.submits[0])
  v.toolAnswer = () => ({ result: { backgroundTaskId: 'b5' } })
  await v.tool($)
  await v.turnEnd($)
  expect((await resultTurn($, v, notif('b5'))).ctx).not.toContain('start nothing')
  // The shell's result turn reads the lane again: working, since work started after the summary.
  expect(v.rowsOf('lane_outcome').map(r => [r.lane, r.at]).slice(-1)).toEqual([['working', 'recheck']])
})

test('H3: a finished lane\'s digest, then a new request: the model starts two agents; when the last ends, no "start nothing" note', { options: { idle_digest: 'return' } }, async ($, on) => {
  const w = new World().install(on)
  w.resumeHere = FINISHED
  await w.start($)
  await idleCompaction($, w)
  await w.advance(5000)
  if (!HAS) return
  const first = await resultTurn($, w, 'A shell finished.')
  expect(first.block ?? '').toContain('code reads the work lane as finished')
  await $.tool.call({ tool: 'Agent', description: 'new request', prompt: 'do it', mode: 'standard' } as never)
  w.agents = [{ id: 'a2', status: 'running' }, { id: 'a3', status: 'running' }]
  await w.turnEnd($)
  w.agents = [{ id: 'a2', status: 'completed' }, { id: 'a3', status: 'running' }]
  const second = await resultTurn($, w, notif('a2'))
  await w.turnEnd($)
  w.agents = [{ id: 'a2', status: 'completed' }, { id: 'a3', status: 'completed' }]
  const third = await resultTurn($, w, notif('a3'))
  for (const t of [second, third]) expect(t.ctx + (t.block ?? '')).not.toContain('start nothing')
})

/** A summary of this Resume here, compacted while idle with nothing running: no digest turn, and the lane reads working. */
async function staysWorking($: Engine, w: World, resumeHere: string): Promise<void> {
  w.resumeHere = resumeHere
  await w.start($)
  await idleCompaction($, w)
  await w.advance(5000)
  expect(w.submits).toEqual([])
  expect(w.rowsOf('lane_outcome').map(r => r.lane)).toEqual(['working'])
}

test('M1: a blocked Status with Step 1 set and `Gate: none` keeps the lane working (non-blocking work goes on)', async ($, on) => {
  await staysWorking($, new World().install(on), 'Status: hard-blocked · Acuity: stable · State: x (checkpoint: clean)\nStep 1: `npm test` — for "finish"\nGate: none · Don\'t: x\n## Next steps\n1. `npm test` — done when green · todo\n')
})

test('M1: a blocked Status with an ungated step marked todo keeps the lane working, though Step 1 is gated', async ($, on) => {
  await staysWorking($, new World().install(on), 'Status: soft-blocked · Acuity: stable · State: x (checkpoint: clean)\nStep 1: `git push` — for "ship"\nGate: protected-branch push · Don\'t: x\n' +
    '## Next steps\n1. `git push` — done when pushed · todo; gated: ask user: push (! git push)\n2. tidy the notes — done when tidy · todo\n')
})

test('M2: the last step mark counts ("· done when" is not a mark): a step still to do keeps a finished Status working', async ($, on) => {
  const w = new World().install(on)
  w.resumeHere = FINISHED + '## Next steps\n1. run the suite · done when green · todo\n'
  await w.start($)
  await idleCompaction($, w)
  await w.advance(5000)
  expect(w.submits).toEqual([])
  expect(w.rowsOf('lane_outcome').map(r => r.lane)).toEqual(['working'])
})

test('M3: finished with a step that has no todo or done mark keeps the lane working', async ($, on) => {
  await staysWorking($, new World().install(on), FINISHED + '## Next steps\n1. open the MR — done when CI is green\n')
})

test('M3: finished with `## Next steps: see handoff` keeps the lane working (the steps are in a file code does not read)', async ($, on) => {
  await staysWorking($, new World().install(on), FINISHED + '## Next steps: see handoff\n')
})

test('M3: a number inside a step of the one-line form is not a new step', () => {
  const f = laneFacts('## Resume here\nStatus: finished\nStep 1: none\n## Next steps: 1. bump to 2. then ship · done 2. c · done\n')
  expect([f.done, f.todo, f.unmarked]).toEqual([2, 0, 0])
})

test('M4: a summary not in the handoff form never reads finished, whatever its steps say (today\'s behaviour)', async ($, on) => {
  const w = new World().install(on)
  w.summaryMode = 'truncated'
  w.resumeHere = 'Status: working · Acuity: watch · State: B-1 shell runs (checkpoint: clean)\nStep 1: none\n## Next steps\n1. build — done when green · done\n'
  await w.start($)
  await idleCompaction($, w)
  await w.advance(5000)
  expect(w.submits).toEqual([])
  expect(w.rowsOf('lane_outcome').map(r => [r.lane, r.source])).toEqual([['working', 'recheck']])
  // No Step 1 line is not `none`.
  expect(laneOf(laneFacts('## Next steps\n1. a — done when b · done\n'), M).lane).toBe('working')
})

test('M5: a background shell the measure lists as running counts as running until its notification', async ($, on) => {
  const w = new World().install(on)
  w.resumeHere = FINISHED
  w.measureBlock = shell('b7')
  await w.start($)
  await idleCompaction($, w)
  await w.advance(5000)
  // No digest turn while the shell runs (its result opens a turn) and no digest label.
  expect(w.submits).toEqual([])
  expect(w.rowsOf('lane_outcome').map(r => [r.lane, r.agents])).toEqual([['working', 1]])
  if (!HAS) return
  // The shell's result: the stored measure still lists it, the notification says it ended.
  expect((await resultTurn($, w, notif('b7'))).block ?? '').toContain('code reads the work lane as finished')
})

test('M6: a background result\'s own turn counts its task as ended, even while the agent list still shows it running', async ($, on) => {
  const w = new World().install(on)
  w.resumeHere = FINISHED
  w.agents = [{ id: 'a1', status: 'running' }]
  await w.start($)
  await idleCompaction($, w)
  await w.advance(5000)
  expect(w.submits).toEqual([])
  if (!HAS) return
  expect((await resultTurn($, w, notif('a1'))).block ?? '').toContain('code reads the work lane as finished')
})

test('L1: one full digest per episode: a soft-blocked digest, then the hard-blocked note asks for a one-line change of state', async ($, on) => {
  const w = new World().install(on)
  w.resumeHere = HARD
  w.agents = [{ id: 'a1', status: 'running' }, { id: 'a2', status: 'running' }]
  await w.start($)
  await idleCompaction($, w)
  await w.advance(5000)
  if (!HAS) return
  w.agents = [{ id: 'a1', status: 'completed' }, { id: 'a2', status: 'running' }]
  await resultTurn($, w, notif('a1'))
  await w.turnEnd($)
  w.agents = [{ id: 'a1', status: 'completed' }, { id: 'a2', status: 'completed' }]
  const note = (await resultTurn($, w, notif('a2'))).ctx
  expect(note).toContain('code reads the work lane as hard-blocked')
  expect(note).toContain('the away digest went out already: say in one line')
  expect(note).not.toContain('print the away digest')
})

test('L4: a block restored after `claude --resume` opens its idle episode, so a later result turn is re-checked', async ($, on) => {
  const w = new World().install(on)
  const nonce = 'ab0c0001'
  const p: PendingResume = {
    sid: SID_A, nonce, block: 'x', builtAt: T0 - 60000, measuredAt: T0 - 60000, resumePref: 'prompt.context', turnSeq: 3,
    args: { nonce, midturn: false, nonok: false, savedCopy: '~/s.md', prodAllow: false, idle: true, halt: false, lane: laneFacts('## Resume here\n' + HARD) },
    remeasure: 'Git: main @ 1a1a1a1, 0 modified, 0 untracked', outcome: { nudged: false, continued: false, halt: false },
  }
  w.files.set(`${WATCH}/${SID_A}/${ARMED_FILE}`, JSON.stringify(pendingRecord(p, 'f0e1d2c3')) + '\n')
  w.agents = [{ id: 'a1', status: 'running' }, { id: 'a2', status: 'running' }]
  await w.start($)
  if (!HAS) return
  w.agents = [{ id: 'a1', status: 'completed' }, { id: 'a2', status: 'running' }]
  expect((await resultTurn($, w, notif('a1'))).block ?? '').toContain('code reads the work lane as soft-blocked')
  await w.turnEnd($)
  w.agents = [{ id: 'a1', status: 'completed' }, { id: 'a2', status: 'completed' }]
  expect((await resultTurn($, w, notif('a2'))).ctx).toContain('code reads the work lane as hard-blocked')
})

test('L4: the loop-driver flag follows the measure the block went out with, not the one taken at the compaction', async ($, on) => {
  const w = new World().install(on)
  w.resumeHere = HARD
  w.agents = [{ id: 'a1', status: 'running' }, { id: 'a2', status: 'running' }]
  await w.start($)
  await idleCompaction($, w)
  await w.advance(5000)
  if (!HAS) return
  // Delivered past 600 s: the fresh measure names this session's Active driver, so the lane is working.
  await w.advance(700 * 1000)
  w.measureBlock = 'Git: main @ 3f9c2e1, 0 modified, 0 untracked\nActive driver: gsd (re-enter: /gsd:next)\nIn flight: none listed'
  w.agents = [{ id: 'a1', status: 'completed' }, { id: 'a2', status: 'running' }]
  expect((await resultTurn($, w, notif('a1'))).block ?? '').toContain(head(w, 'idle') ?? '')
  await w.turnEnd($)
  // The last agent ends: still the driver's lane, so no note asks it to stop.
  w.agents = [{ id: 'a1', status: 'completed' }, { id: 'a2', status: 'completed' }]
  expect((await resultTurn($, w, notif('a2'))).ctx).toBe('')
})
