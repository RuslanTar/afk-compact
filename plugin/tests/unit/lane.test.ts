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
import { LANE_BASIS_MAX, LANE_WHY_MAX, asLaneFacts, digestLine, laneBasis, laneFacts, laneOf, measuredRunning, notifiedTasks, startsWork } from '../../hooks/lib/lane'
import type { PendingResume } from '../../hooks/lib/deps'
import { ARMED_FILE, pendingRecord } from '../../hooks/lib/resume'
import { SID_A, T0, WATCH, World, raiseCompact } from './harness.test'

const HAS = hasTag('resume-context', 'idle-done')
const M = { running: 0, midturn: false, nonok: false, driver: false }
const F: LaneFacts = { status: 'finished', todo: 0, done: 2, unmarked: 0, free: 0, onJob: 0, onUser: 0, elsewhere: false, listed: true, step1: 'none', gate: 'none', unstable: false }

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
  expect(laneFacts(text)).toEqual({ status: 'hard-blocked', todo: 1, done: 1, unmarked: 1, free: 0, onJob: 0, onUser: 1, elsewhere: false, listed: true, step1: 'set', gate: 'set', unstable: false })
  const inline = '## Resume here\nStatus: finished · Acuity: unstable · State: y\nStep 1: none\n## Next steps: 1. a — done when b · done 2. c — done when d · done\n'
  expect(laneFacts(inline)).toEqual({ status: 'finished', todo: 0, done: 2, unmarked: 0, free: 0, onJob: 0, onUser: 0, elsewhere: false, listed: true, step1: 'none', gate: 'missing', unstable: true })
  // An item's last mark counts, and only a mark that ends its words (`· done when` is not one); a
  // step marked todo with no gate, ask, pending answer or wait can run.
  const marks = '## Resume here\nStatus: soft-blocked\nStep 1: none\nGate: none · Don\'t: x\n## Next steps\n1. run the suite · done when green · todo\n' +
    '2. ask user: deploy (! make deploy) · todo\n3. wait for B-1 — done when it ends · todo; waits on B-1\n   if red → fix\n- pending answer: the table\n'
  expect(laneFacts(marks)).toEqual({ status: 'soft-blocked', todo: 3, done: 0, unmarked: 0, free: 1, onJob: 1, onUser: 1, elsewhere: false, listed: true, step1: 'none', gate: 'none', unstable: false })
  expect(laneFacts('## Resume here\nStatus: hard-blocked\nStep 1: ask user: push (! git push)\nGate: none\n').gate).toBe('set')
  expect(laneFacts('## Resume here\nStatus: finished\n## Next steps: see handoff\n')).toEqual(
    { status: 'finished', todo: 0, done: 0, unmarked: 0, free: 0, onJob: 0, onUser: 0, elsewhere: true, listed: true, step1: 'missing', gate: 'missing', unstable: false })
  expect(laneFacts('no form here').status).toBe(null)
  expect(laneFacts('## Resume here\nStatus: working · State: z (checkpoint: MID-STEP 2, remaining 3)\nStep 1: `x` | proposed\n').step1).toBe('proposed')
  expect(laneFacts('## Resume here\nStatus: working · State: z (checkpoint: MID-STEP 2, remaining 3)\n').unstable).toBe(true)
})

// ---- the rule: the summary's Status leads, code re-checks

test('laneOf: each Status word as read, and the code corrections toward work or a truer blocked label', () => {
  expect(laneOf(F, M)).toEqual({ lane: 'finished', source: 'status', why: "the summary's Status line" })
  expect(laneOf({ ...F, status: 'working', step1: 'set', todo: 1 }, M)).toEqual({ lane: 'working', source: 'status', why: "the summary's Status line" })
  expect(laneOf({ ...F, status: 'hard-blocked' }, M).lane).toBe('hard-blocked')
  expect(laneOf({ ...F, status: 'soft-blocked' }, { ...M, running: 1 }).lane).toBe('soft-blocked')
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
    // (soft-blocked with a unit running: with none it reads hard-blocked, below)
    expect(laneOf({ ...F, status, step1: 'set', gate: 'set', todo: 1 }, { ...M, running: status === 'soft-blocked' ? 1 : 0 }).lane).toBe(status)
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
  for (const status of statuses) for (const todo of [0, 1]) for (const free of [0, 1]) for (const unmarked of [0, 1]) for (const onJob of [0, 1])
    for (const elsewhere of [false, true]) for (const step1 of ['none', 'proposed', 'set', 'missing'] as const) for (const gate of ['none', 'job', 'set'] as const)
      for (const listed of [true, false]) for (const running of [0, 1]) for (const flag of ['', 'midturn', 'nonok', 'driver', 'superseded', 'unstable', 'result']) {
        const f: LaneFacts = { status, todo, done: 1, unmarked, free, onJob, onUser: 0, elsewhere, listed, step1, gate, unstable: flag === 'unstable' }
        const r = laneOf(f, { running, midturn: flag === 'midturn', nonok: flag === 'nonok', driver: flag === 'driver', superseded: flag === 'superseded', result: flag === 'result' })
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
  // An id with no status after it (b7) ends nothing (review of fix round 2: a Monitor's event has none).
  expect(notifiedTasks('<task-notification>\n<task-id>af63d8ad7bcf2ffd4</task-id>\n<status>completed</status>\n</task-notification>\n<task-id>b7</task-id>')).toEqual(['af63d8ad7bcf2ffd4'])
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

const RT = { session_id: SID_A, saved_copy: 'x', measured_at: 'x', remeasure: 'x', store: 'x', idle_used_at: 'x', lane: 'x', lane_why: 'x', lane_basis: 'x' }
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

/** A finished Resume here with no Next steps section yet (a test adds its own). */
const FINISHED_HEAD = 'Status: finished · Acuity: stable · State: done (checkpoint: clean)\nStep 1: none\n'
const FINISHED = FINISHED_HEAD + '## Next steps\n1. run the suite — done when green · done\n'

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
  w.resumeHere = FINISHED_HEAD + '## Next steps\n1. ship — done when merged · todo\n'
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
  // The person is back: the episode closes; the again-block beside their prompt (no lane note)
  // carries the [idle-done] pointer branch; prompt.context, asked once per conversation, adds none.
  await w.userTurn($, 'back')
  const back = w.submitContexts[w.submitContexts.length - 1] ?? []
  expect(back.length).toBe(1)
  expect(back[0]).toContain('code reads the work lane as hard-blocked')
  expect(back[0]).toContain("A background result's turn got this block at")
  expect(blockOf(w, await $.prompt.context({ blocks: [] }))).toBe(undefined)
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
  // A person's prompt ends the episode: no note beside it (the whole block again instead, as a
  // result turn took it), and none for a later result turn.
  await w.turnEnd($)
  await w.userTurn($, 'back')
  const back = w.submitContexts[w.submitContexts.length - 1] ?? []
  expect(back.length).toBe(1)
  expect(back[0]).toContain("A background result's turn got this block at")
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
  w.resumeHere = FINISHED_HEAD + '## Next steps\n1. run the suite · done when green · todo\n'
  await w.start($)
  await idleCompaction($, w)
  await w.advance(5000)
  expect(w.submits).toEqual([])
  expect(w.rowsOf('lane_outcome').map(r => r.lane)).toEqual(['working'])
})

test('M3: finished with a step that has no todo or done mark keeps the lane working', async ($, on) => {
  await staysWorking($, new World().install(on), FINISHED_HEAD + '## Next steps\n1. open the MR — done when CI is green\n')
})

test('M3: finished with `## Next steps: see handoff` keeps the lane working (the steps are in a file code does not read)', async ($, on) => {
  await staysWorking($, new World().install(on), FINISHED_HEAD + '## Next steps: see handoff\n')
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

// ---- review of fix round 1 (fix round 2): each test failed on 1735256

/** The step-5 clause of the main session's [idle] line (AWAY-DIGEST phase 1 item 5, Q5). */
const STEP5 = 'Step 5 finds none left, or all left waits on the user: instead, print the away digest'
const SOFT = 'Status: soft-blocked · Acuity: watch · State: waits on you (checkpoint: clean)\nStep 1: none\n'
/** The measure's git line (measure.pm `git_lines`): 1 file changed, 2 commits not pushed. */
const GIT = 'git: branch main · HEAD 3f9c2e1 · 1 changed · ahead 2 behind 0'
/** The `HH:MM` of a block's `Measured facts (<stamp>; …)` line: when its measure was taken. */
const stampOf = (block: string): string => /Measured facts \(\d{4}-\d\d-\d\dT(\d\d:\d\d):/.exec(block)?.[1] ?? 'no stamp'

test('Q5 (phase 1 item 5): at the plugin\'s idle compaction a step waits on the agent\'s result, so the lane reads working; the result turn\'s [idle] block asks for the digest once nothing is left', async ($, on) => {
  const w = new World().install(on)
  w.resumeHere = 'Status: working · Acuity: watch · State: waits for B-1 (checkpoint: clean)\nStep 1: `read B-1 output` — for "review"\nGate: none · Don\'t: x\n' +
    '## Next steps\n1. `read B-1 output` — done when read · todo\n'
  w.agents = [{ id: 'a1', status: 'running' }]
  await w.start($)
  await idleCompaction($, w)
  await w.advance(5000)
  expect(w.submits).toEqual([])
  w.agents = [{ id: 'a1', status: 'completed' }]
  const block = (await resultTurn($, w, notif('a1'))).block ?? ''
  const idle = head(w, 'idle')
  if (idle === undefined) return
  expect(block).toContain(idle)
  expect(block).toContain(STEP5)
  expect(block).toContain('Then stop; after one digest, later turns say what changed in one line.')
  // Only the main session's [idle] line carries it: never a block without it (a subagent's, an
  // attended compaction's), [idle-halt] (halt beats done) or [idle-done] (it asks for the digest itself).
  for (const tags of [['prod-forbid'], ['prod-forbid', 'midturn'], ['prod-forbid', 'idle-halt'], ['prod-forbid', 'idle-done']] as Tag[][]) {
    expect(assemble(w.name, 'resume-context', tags, RT)).not.toContain(STEP5)
  }
})

test('owner 2026-10-27 22:32: the step-5 digest of [idle] carries the Basis line code renders when the block goes out', async ($, on) => {
  const w = new World().install(on)
  w.resumeHere = 'Status: working · Acuity: watch · State: waits for B-1 (checkpoint: clean)\nStep 1: `read B-1 output` — for "review"\nGate: none · Don\'t: x\n' +
    '## Next steps\n1. run the suite — done when green · done\n2. `read B-1 output` — done when read · todo\n'
  w.measureBlock = GIT + '\nIn flight: none listed\nEvidence: none'
  w.agents = [{ id: 'a1', status: 'running' }]
  await w.start($)
  await idleCompaction($, w)
  await w.advance(5000)
  w.agents = [{ id: 'a1', status: 'completed' }]
  const block = (await resultTurn($, w, notif('a1'))).block ?? ''
  const idle = head(w, 'idle')
  if (idle === undefined) return
  expect(block).toContain(idle)
  expect(block).toContain(STEP5)
  // The model writes the digest; code fills the Basis when the block goes out (a step still todo
  // keeps the lane working, so this is [idle], not [idle-done]).
  expect(block).toContain('lane state and why; Basis: 1 of 2 listed steps marked done; 0 units running; git: 2 commits not pushed, 1 file changed (by code, as is); Done;')
  expect(block).not.toContain('@lane_basis@')
  expect(block).not.toContain('code reads the work lane as')
})

test('M7: the Basis line code renders: the listed steps marked done, the units running, the commits not pushed and files changed the measure shows', () => {
  const f = laneFacts('## Resume here\nStatus: hard-blocked\nStep 1: none\n## Next steps\n1. a — done when b · done\n2. c — done when d · todo; ask user: x\n3. e\n')
  expect(laneBasis(f, 1, GIT + '\nIn flight: none listed')).toBe('1 of 3 listed steps marked done; 1 unit running; git: 2 commits not pushed, 1 file changed')
  expect(laneBasis({ ...F, done: 1 }, 0, 'git: branch x · HEAD - · 0 changed · ahead 1 behind 3 · rebase in progress'))
    .toBe('1 of 1 listed step marked done; 0 units running; git: 1 commit not pushed, 0 files changed')
  expect(laneBasis(undefined, 0, undefined)).toBe('no steps code could read; 0 units running; git: not measured')
  expect(laneBasis({ ...F, elsewhere: true }, 2, 'git: not measured (timeout)')).toBe('the steps are in the handoff file; 2 units running; git: not measured')
  expect(laneBasis({ ...F, listed: false, done: 0 }, 0, undefined)).toBe('no Next steps listed; 0 units running; git: not measured')
  // Within the value tools/assemble budgets with (the longest is a branch with no upstream: R3-2).
  const worst = laneBasis({ ...F, done: 5000, todo: 5000 }, 5000, 'git: branch b · HEAD h · 5000 changed · ahead 5000 behind 0')
  expect(worst).toBe('999+ of 999+ listed steps marked done; 999+ units running; git: 999+ commits not pushed, 999+ files changed')
  expect(worst.length <= LANE_BASIS_MAX).toBe(true)
})

test('M7: the [idle-done] block and a later lane note carry the Basis line, rendered when each goes out', async ($, on) => {
  const w = new World().install(on)
  w.resumeHere = 'Status: hard-blocked · Acuity: watch · State: waits on you (checkpoint: clean)\nStep 1: none\n' +
    '## Next steps\n1. run the suite — done when green · done\n2. `git push` — done when pushed · todo; gated: ask user: push (! git push)\n'
  w.measureBlock = GIT + '\nIn flight: none listed\nEvidence: none'
  w.agents = [{ id: 'a1', status: 'running' }, { id: 'a2', status: 'running' }]
  await w.start($)
  await idleCompaction($, w)
  await w.advance(5000)
  if (!HAS) return
  w.agents = [{ id: 'a1', status: 'completed' }, { id: 'a2', status: 'running' }]
  const first = (await resultTurn($, w, notif('a1'))).block ?? ''
  expect(first).toContain('code reads the work lane as soft-blocked')
  expect(first).toContain('Basis: 1 of 2 listed steps marked done; 1 unit running; git: 2 commits not pushed, 1 file changed (by code, as is)')
  expect(first).toContain('Left (each listed step not done, what blocks it; commits not pushed)')
  await w.turnEnd($)
  w.agents = [{ id: 'a1', status: 'completed' }, { id: 'a2', status: 'completed' }]
  // The note's git facts are the measure the block went out with: their time is the block's (R3-3).
  expect((await resultTurn($, w, notif('a2'))).ctx)
    .toContain(`the lane is now hard-blocked (Basis: 1 of 2 listed steps marked done; 0 units running; git as of ${stampOf(first)}: 2 commits not pushed, 1 file changed)`)
})

test('M7: a note that asks for the first digest carries the Basis line too', async ($, on) => {
  const w = new World().install(on)
  w.resumeHere = 'Status: working · Acuity: watch · State: waits for B-1, B-2 (checkpoint: clean)\nStep 1: none\n## Next steps\n1. read the B-1 and B-2 results — done when read · done\n'
  w.measureBlock = GIT + '\nIn flight: none listed\nEvidence: none'
  w.agents = [{ id: 'a1', status: 'running' }, { id: 'a2', status: 'running' }]
  await w.start($)
  await idleCompaction($, w)
  await w.advance(5000)
  if (!HAS) return
  w.agents = [{ id: 'a1', status: 'completed' }, { id: 'a2', status: 'running' }]
  const first = (await resultTurn($, w, notif('a1'))).block ?? ''
  await w.turnEnd($)
  w.agents = [{ id: 'a1', status: 'completed' }, { id: 'a2', status: 'completed' }]
  const note = (await resultTurn($, w, notif('a2'))).ctx
  expect(note).toContain('print the away digest')
  expect(note).toContain(`Basis: 1 of 1 listed step marked done; 0 units running; git as of ${stampOf(first)}: 2 commits not pushed, 1 file changed (by code, as is)`)
})

test('soft-blocked with nothing running reads hard-blocked (owner xxxxxxxx-06: soft means something still runs)', () => {
  expect(laneOf({ ...F, status: 'soft-blocked' }, M)).toEqual({ lane: 'hard-blocked', source: 'recheck', why: 'the summary says soft-blocked, but nothing runs' })
  expect(laneOf({ ...F, status: 'soft-blocked' }, { ...M, running: 1 })).toEqual({ lane: 'soft-blocked', source: 'status', why: "the summary's Status line" })
  // A step that can run still keeps it working.
  expect(laneOf({ ...F, status: 'soft-blocked', todo: 1, free: 1 }, M).lane).toBe('working')
})

test('soft-blocked summary written with nothing running: the digest turn reads hard-blocked', async ($, on) => {
  const w = new World().install(on)
  w.resumeHere = SOFT
  await w.start($)
  await idleCompaction($, w)
  await w.advance(5000)
  if (!HAS) return
  expect(w.submits.length).toBe(1)
  expect(w.submits[0] ?? '').toContain('code reads the work lane as hard-blocked (the summary says soft-blocked, but nothing runs)')
  expect(w.rowsOf('digest_submit').map(r => [r.lane, r.result])).toEqual([['hard-blocked', 'submitted']])
})

test('soft-blocked summary, two agents: the first result turn gets the soft-blocked digest; when the last ends, the note says hard-blocked', async ($, on) => {
  const w = new World().install(on)
  w.resumeHere = SOFT
  w.agents = [{ id: 'a1', status: 'running' }, { id: 'a2', status: 'running' }]
  await w.start($)
  await idleCompaction($, w)
  await w.advance(5000)
  expect(w.submits).toEqual([])
  if (!HAS) return
  w.agents = [{ id: 'a1', status: 'completed' }, { id: 'a2', status: 'running' }]
  expect((await resultTurn($, w, notif('a1'))).block ?? '').toContain('code reads the work lane as soft-blocked')
  await w.turnEnd($)
  w.agents = [{ id: 'a1', status: 'completed' }, { id: 'a2', status: 'completed' }]
  const note = (await resultTurn($, w, notif('a2'))).ctx
  expect(note).toContain('code reads the work lane as hard-blocked (the summary says soft-blocked, but nothing runs)')
  expect(note).toContain('the away digest went out already: say in one line')
  expect(w.rowsOf('lane_outcome').map(r => [r.lane, r.at])).toEqual([['soft-blocked', 'build'], ['soft-blocked', 'delivery'], ['hard-blocked', 'recheck']])
})

test('soft-blocked summary, one agent: its result turn reads hard-blocked', async ($, on) => {
  const w = new World().install(on)
  w.resumeHere = SOFT
  w.agents = [{ id: 'a1', status: 'running' }]
  await w.start($)
  await idleCompaction($, w)
  await w.advance(5000)
  expect(w.submits).toEqual([])
  if (!HAS) return
  w.agents = [{ id: 'a1', status: 'completed' }]
  expect((await resultTurn($, w, notif('a1'))).block ?? '').toContain('code reads the work lane as hard-blocked')
})

test('a finished Status with no Next steps section (a summary cut near its size cap can lose it) keeps the lane working; `## Next steps: none` does not', async ($, on) => {
  expect(laneOf(laneFacts('## Resume here\nStatus: finished\nStep 1: none\nGate: none\n'), M))
    .toEqual({ lane: 'working', source: 'recheck', why: 'the summary says finished, but has no Next steps' })
  expect(laneOf(laneFacts('## Resume here\nStatus: finished\nStep 1: none\nGate: none\n## Next steps: none\n'), M).lane).toBe('finished')
  // Lane facts restored from a record written before `listed` was read: never finished.
  const { listed: _, ...old } = F
  expect(asLaneFacts(old)?.listed).toBe(false)
  await staysWorking($, new World().install(on), FINISHED_HEAD)
})

test('a notification counts its task as ended only with an ending status (completed, failed, killed)', async ($, on) => {
  expect(notifiedTasks('<task-notification>\n<task-id>b1</task-id>\n<status>running</status>\n</task-notification>')).toEqual([])
  expect(notifiedTasks('<task-notification><task-id>b1</task-id><status>failed</status></task-notification><task-notification><task-id>b2</task-id>' +
    '<status>progress</status></task-notification><task-notification><task-id>b3</task-id><status>killed</status></task-notification>')).toEqual(['b1', 'b3'])
  // No status ends nothing (R3-4).
  expect(notifiedTasks('<task-notification>\n<task-id>b4</task-id>\n<summary>x</summary>\n</task-notification>')).toEqual([])
  // Through the kit: the shell the measure lists runs on after a notification about it that ends nothing.
  const w = new World().install(on)
  w.resumeHere = FINISHED
  w.measureBlock = shell('b7')
  await w.start($)
  await idleCompaction($, w)
  await w.advance(5000)
  if (!HAS) return
  const t = await resultTurn($, w, '<task-notification>\n<task-id>b7</task-id>\n<status>running</status>\n<summary>still going</summary>\n</task-notification>')
  expect(t.block ?? '').not.toContain('code reads the work lane as finished')
  expect(w.rowsOf('lane_outcome').map(r => [r.lane, r.at]).slice(-1)).toEqual([['working', 'delivery']])
})

test('a step that waits, awaits, is blocked on something or needs an approval or the user is held, not free', () => {
  for (const words of ['waiting for review', 'awaiting approval', 'awaits the reviewer', 'blocked on the API key', 'blocked by LAB-7', 'needs approval', 'needs the user', 'waiting on B-2']) {
    const f = laneFacts(`## Resume here\nStatus: hard-blocked\nStep 1: none\nGate: none\n## Next steps\n1. merge — done when merged · todo; ${words}\n`)
    expect([words, f.free]).toEqual([words, 0])
    expect(laneOf(f, M).lane).toBe('hard-blocked')
  }
  // A step naming none of them can run.
  expect(laneFacts('## Resume here\nStatus: hard-blocked\nStep 1: none\n## Next steps\n1. tidy the notes — done when tidy · todo\n').free).toBe(1)
  // Step 1's `— for "…"` tail is the user's words: a wait named there does not gate the step.
  const s1 = laneFacts('## Resume here\nStatus: hard-blocked\nStep 1: `npm test` — for "fix it while the MR is waiting for review"\nGate: none\n')
  expect([s1.gate, laneOf(s1, M).lane]).toEqual(['none', 'working'])
})

test('a block restored after `claude --resume`: the background tasks its measure lists ran in the ended process, so only agents count as running', async ($, on) => {
  const w = new World().install(on)
  const nonce = 'ab0c0002'
  const p: PendingResume = {
    sid: SID_A, nonce, block: 'x', builtAt: T0 - 60000, measuredAt: T0 - 60000, resumePref: 'prompt.context', turnSeq: 3,
    args: { nonce, midturn: false, nonok: false, savedCopy: '~/s.md', prodAllow: false, idle: true, halt: false, lane: laneFacts('## Resume here\n' + FINISHED) },
    remeasure: shell('b9'), outcome: { nudged: false, continued: false, halt: false },
  }
  w.files.set(`${WATCH}/${SID_A}/${ARMED_FILE}`, JSON.stringify(pendingRecord(p, 'f0e1d2c3')) + '\n')
  await w.start($)
  if (!HAS) return
  expect((await resultTurn($, w, 'A shell finished.')).block ?? '').toContain('code reads the work lane as finished')
})

test('a lane note whose prompt does not enter (a hook beneath drops it) goes to the next turn of the episode', async ($, on) => {
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
  // The last agent's notification is dropped beneath the plugin: its note never reaches the model.
  w.dropIf = t => (t.includes('<task-id>a2</task-id>') ? 'held' : undefined)
  const r = (await $.prompt.submit({ text: notif('a2'), origin: { kind: 'task-notification' } } as never)) as { drop?: string }
  expect(r.drop).toBe('held')
  expect(ctxOf(w)).toContain('code reads the work lane as hard-blocked')
  w.dropIf = undefined
  // The next turn not of a person's gets it.
  expect((await resultTurn($, w, 'A shell finished.')).ctx).toContain('code reads the work lane as hard-blocked')
})

// ---- review of fix round 2 (fix round 3): each test failed on 25d7ccb

/** The measure's git line on a branch with no upstream (measure.pm `git_lines`): this branch's own, as the review measured it. */
const NO_UP = 'git: branch v012-digest · HEAD 25d7ccbe891c · 0 changed · no upstream'

test('R3-2: a branch with no upstream (a new local or worktree branch, a detached HEAD) or a gone one: the Basis says commits not pushed are unknown, never 0', () => {
  const f = { ...F, done: 1 }
  expect(laneBasis(f, 0, NO_UP + '\nIn flight: none listed')).toBe('1 of 1 listed step marked done; 0 units running; git: no upstream, unpushed unknown, 0 files changed')
  expect(laneBasis(f, 0, 'git: branch (detached) · HEAD 25d7ccbe891c · 3 changed · no upstream · rebase in progress'))
    .toBe('1 of 1 listed step marked done; 0 units running; git: no upstream, unpushed unknown, 3 files changed')
  expect(laneBasis(f, 1, 'git: branch feat/x · HEAD 25d7ccbe891c · 1 changed · upstream gone'))
    .toBe('1 of 1 listed step marked done; 1 unit running; git: no upstream, unpushed unknown, 1 file changed')
  // With an upstream the count stays.
  expect(laneBasis(f, 0, GIT)).toBe('1 of 1 listed step marked done; 0 units running; git: 2 commits not pushed, 1 file changed')
  // The longest Basis is this one: the value tools/assemble budgets with.
  const worst = laneBasis({ ...F, done: 5000, todo: 5000 }, 5000, 'git: branch b · HEAD h · 5000 changed · no upstream')
  expect(worst).toBe('999+ of 999+ listed steps marked done; 999+ units running; git: no upstream, unpushed unknown, 999+ files changed')
  expect(worst.length).toBe(LANE_BASIS_MAX)
})

test('R3-2: through the kit, the digest turn of a finished lane on a branch with no upstream prints the unknown, not 0 commits not pushed', async ($, on) => {
  const w = new World().install(on)
  w.resumeHere = FINISHED
  w.measureBlock = NO_UP + '\nIn flight: none listed\nEvidence: none'
  await w.start($)
  await idleCompaction($, w)
  await w.advance(5000)
  if (!HAS) return
  expect(w.submits.length).toBe(1)
  const sent = w.submits[0] ?? ''
  expect(sent).toContain('Basis: 1 of 1 listed step marked done; 0 units running; git: no upstream, unpushed unknown, 0 files changed (by code, as is)')
  expect(sent).not.toContain('0 commits not pushed')
})

test('R3-3: a later turn\'s note says how old its git facts are: the time of the measure its block went out with, not now', async ($, on) => {
  const w = new World().install(on)
  w.resumeHere = HARD + '## Next steps\n1. run the suite — done when green · done\n'
  w.measureBlock = GIT + '\nIn flight: none listed\nEvidence: none'
  w.agents = [{ id: 'a1', status: 'running' }]
  await w.start($)
  await idleCompaction($, w)
  await w.advance(5000)
  if (!HAS) return
  // The first result turn gets the block (soft-blocked while a1 runs on a notification that ends nothing).
  const first = (await resultTurn($, w, '<task-notification>\n<task-id>a1</task-id>\n<status>progress</status>\n</task-notification>')).block ?? ''
  const at = stampOf(first)
  expect(at).toMatch(/^\d\d:\d\d$/)
  await w.turnEnd($)
  // Ten minutes on, the agent ends: the note's git facts are still the block's.
  await w.advance(10 * 60 * 1000)
  w.agents = [{ id: 'a1', status: 'completed' }]
  const note = (await resultTurn($, w, notif('a1'))).ctx
  expect(note).toContain('code reads the work lane as hard-blocked')
  expect(note).toContain(`git as of ${at}: 2 commits not pushed, 1 file changed`)
})

test('R3-4: a notification with no status (a Monitor\'s event while it runs on) ends nothing: the shell the measure lists still runs', async ($, on) => {
  // The shape Claude Code sends for a Monitor event: a task id, a summary and the event, no status.
  const event = '<task-notification>\n<task-id>b7</task-id>\n<summary>Monitor event: "build log"</summary>\n<event>step 3 of 9</event>\n</task-notification>'
  expect(notifiedTasks(event)).toEqual([])
  const w = new World().install(on)
  w.resumeHere = FINISHED
  w.measureBlock = shell('b7')
  await w.start($)
  await idleCompaction($, w)
  await w.advance(5000)
  if (!HAS) return
  const t = await resultTurn($, w, event)
  expect(t.block ?? '').not.toContain('code reads the work lane as finished')
  expect(w.rowsOf('lane_outcome').map(r => [r.lane, r.at]).slice(-1)).toEqual([['working', 'delivery']])
})

// ---- owner 2026-10-28 digest rules (a)/(b): a step held on a job's result; the re-check at that result turn's end

/** A blocked Resume here whose push waits on the user, with this step first in Next steps. */
const onJob = (step: string, status = 'soft-blocked'): string =>
  `Status: ${status} · Acuity: stable · State: the timer runs; the push waits on you (checkpoint: clean)\nStep 1: \`git push\` — for "ship"\n` +
  `Gate: protected-branch push · Don't: x\n## Next steps\n1. ${step} · todo\n2. \`git push\` — done when pushed · todo; gated: ask user: push (! git push)\n`
/** Trigger wordings of a step whose only trigger is a running job's result (rule (a)). */
const TRIGGERS = [
  'On the timer notification, reply with one line acknowledging it',
  'Wait for the timer notification, then reply with one line',
  'when CI finishes, report the result',
  'after the build ends, tag the release',
  'once the B-1 result arrives, summarise it',
  'when the timer fires, check its log',
  'upon the workflow notification, read its output',
  'after the agent result, merge the findings',
  'On the B-2 shell result, read the log — done when read',
  'waiting on B-2, then read its log',
  'as soon as the pipeline passes, merge',
  'On the result of the run, write it up',
  "After the agent's output comes back, merge it",
  'Then, when the build is green, push the tag',
  'once the results arrive, summarise them',
  'Wait for Jenkins build, then read its log',
  // A capitalised job word right after the wait is the job, not a named person (review 3).
  'Wait for Build 42 to finish',
  'Wait for Agent B to finish',
  'Wait for Agents to return',
  'Wait for Pipeline 7',
  'Wait for Timer',
  'Wait for Workflow wf_1 to end',
  // Wider job and end words (review 3): till, tests, pass, reports back, succeeds, after a job alone, a return.
  'wait till CI passes',
  'When the tests finish, report',
  'After the tests pass, merge',
  'When the agent reports back, merge',
  'When the build succeeds, tag',
  'After the run, commit',
  "Upon the agent's return, merge",
  // A person after the wait's own clause, or one the build follows, is no person the wait is on.
  'Wait for the timer notification, then reply to the user with one line',
  'wait for CI to email me',
  'wait for the client build to finish',
]
/**
 * Ordinary work that only mentions a job, its end or a result, with no trigger leading its clause
 * (review of digest rules (a)): free work, so a blocked Status still reads working (-08, M1).
 */
const NOT_TRIGGERS = [
  'add a test for when the task completes',
  'handle the case when the job fails (retry)',
  'log a message when the build is done',
  'On completion, commit the change',
  'after the results are reviewed, write the summary',
  'until CI passes, fix the failures',
  'on the results page, add a filter',
  'reply once the timer fires',
  'commit the notes; when the build is green, push the tag',
  'After fixing the build, commit',
]
/**
 * A wait on something that is not a job (a person, an approval): held on the user, never on a job,
 * even when a job word follows the person (review 2 of digest rules (a)), when the person is a
 * pronoun or a group, or when the person or an ask of the user comes after the job (review 3).
 * The plugin's helper case AD-11 reads TRIGGERS, NOT_TRIGGERS and USER_WAITS from this file and
 * checks that the saved copy's status (copies.pm `_hold_of`) gives each the same hold.
 */
const USER_WAITS = [
  "Wait for the reviewer's result",
  'awaiting approval of the run',
  'wait for review of CI',
  'Wait for the user to run the build',
  'wait for you to run the tests',
  'wait for the user to build',
  'wait for the owner to rerun the CI job',
  'wait for me to start the run',
  'waiting on the reviewer to finish the run',
  'awaiting the approver to pass the pipeline',
  'wait until the maintainer runs the build',
  'Wait for Anna to run the build',
  'wait for them to run the build',
  'wait for him to run the tests',
  'wait for someone to run the build',
  'wait for a human to run the build',
  'wait for the team to run the pipeline',
  'wait for QA to run the build',
  'wait for the client to run the job',
  'wait for us to run CI',
  'wait for the build and the user, then merge',
  'Wait for the agent, then ask the user',
]

test('rule (a): a step whose only trigger is a running job\'s result is held on the job under a blocked Status, whatever the wording', () => {
  for (const step of TRIGGERS) {
    const f = laneFacts('## Resume here\n' + onJob(step))
    expect([step, f.todo, f.free, f.onJob, f.onUser]).toEqual([step, 2, 0, 1, 1])
    // While the job runs the model's soft-blocked stands; with nothing running it reads hard-blocked.
    expect([step, laneOf(f, { ...M, running: 1 }).lane]).toEqual([step, 'soft-blocked'])
    expect([step, laneOf(f, M).lane]).toEqual([step, 'hard-blocked'])
    // The turn the job's result comes with: the step it unblocks can run (xxxxxxxx-06).
    expect([step, laneOf(f, { ...M, result: true })]).toEqual([step, { lane: 'working', source: 'recheck', why: 'the summary says soft-blocked, but a result unblocks a step', byResult: true }])
    expect([step, laneOf(laneFacts('## Resume here\n' + onJob(step, 'hard-blocked')), { ...M, running: 1 }).lane]).toEqual([step, 'soft-blocked'])
  }
  // The AD2 wording and its "Wait for" twin read the same at every moment (no flip on wording).
  const on = laneFacts('## Resume here\n' + onJob('On the timer notification, reply with one line'))
  const wait = laneFacts('## Resume here\n' + onJob('Wait for the timer notification, then reply with one line'))
  for (const m of [{ ...M, running: 1 }, M, { ...M, result: true }]) expect(laneOf(on, m)).toEqual(laneOf(wait, m))
})

test('rule (a): not held under a working (or finished) Status; a step that only names a build or a result, or a done criterion, stays free work', () => {
  for (const step of TRIGGERS) {
    expect([step, laneOf(laneFacts('## Resume here\n' + onJob(step, 'working')), M).lane]).toEqual([step, 'working'])
    expect([step, laneOf(laneFacts('## Resume here\n' + onJob(step, 'working')), { ...M, result: true }).lane]).toEqual([step, 'working'])
    expect([step, laneOf(laneFacts('## Resume here\n' + onJob(step, 'finished')), M).lane]).toEqual([step, 'working'])
  }
  for (const step of ['fix the build script', 'work on the results table', 'run the suite — done when the run finishes', 'rerun the failed CI job', 'tidy the notes after review', ...NOT_TRIGGERS]) {
    const f = laneFacts('## Resume here\n' + onJob(step))
    expect([step, f.free, f.onJob]).toEqual([step, 1, 0])
    expect([step, laneOf(f, { ...M, running: 1 }).lane]).toEqual([step, 'working'])
    expect([step, laneOf(f, M).lane]).toEqual([step, 'working'])
  }
  // A wait on a person or an approval holds the step on the user: a job's result does not unblock it.
  for (const step of USER_WAITS) {
    const f = laneFacts('## Resume here\n' + onJob(step))
    expect([step, f.free, f.onJob, f.onUser]).toEqual([step, 0, 0, 2])
    expect([step, laneOf(f, { ...M, result: true }).lane]).toEqual([step, 'hard-blocked'])
  }
  // A step that needs the user after the job too is held on the user.
  const both = laneFacts('## Resume here\n' + onJob('after CI finishes, deploy — gated: ask user: deploy'))
  expect([both.onJob, both.onUser]).toEqual([0, 2])
  expect(laneOf(both, { ...M, result: true }).lane).toBe('hard-blocked')
  // A result on a blocked lane with no step held on a job changes nothing.
  expect(laneOf({ ...F, status: 'soft-blocked', todo: 1, onUser: 1 }, { ...M, result: true }).lane).toBe('hard-blocked')
})

test('rule (a): Step 1 held on a job with `Gate: none` is not a free Step 1: blocked while the job runs, working in its result turn', () => {
  const f = laneFacts('## Resume here\nStatus: soft-blocked\nStep 1: On the timer notification, reply — for "go"\nGate: none · Don\'t: x\n## Next steps\n1. `git push` · todo; gated: ask user: push\n')
  expect([f.step1, f.gate, f.free, f.onJob, f.onUser]).toEqual(['set', 'job', 0, 0, 1])
  expect(laneOf(f, { ...M, running: 1 }).lane).toBe('soft-blocked')
  expect(laneOf(f, { ...M, result: true }).lane).toBe('working')
  // A record of lane facts written before the holds were told apart reads every held step as the user's.
  const { onJob: _j, onUser: _u, ...old } = { ...F, status: 'hard-blocked', todo: 2, free: 1 }
  expect(asLaneFacts(old)).toEqual({ ...F, status: 'hard-blocked', todo: 2, free: 1, onJob: 0, onUser: 1 })
  expect(asLaneFacts({ ...F, onJob: -1 })).toBe(undefined)
  expect(asLaneFacts({ ...F, gate: 'job' })?.gate).toBe('job')
})

/** The AD2 shape: an idle compaction while the timer shell b7 runs; the summary's only free-looking step waits on its result. */
async function ad2($: Engine, w: World, step: string): Promise<void> {
  w.resumeHere = onJob(step)
  w.measureBlock = shell('b7')
  await w.start($)
  await idleCompaction($, w)
  await w.advance(5000)
  expect(w.submits).toEqual([])
}

for (const step of ['On the timer notification, reply with one line acknowledging it', 'Wait for the timer notification, then reply with one line']) {
  test(`rule (b) "${step.slice(0, 8)}": the result turn reads working ([idle]); its end reads hard-blocked and submits one digest turn; nothing repeats it`, async ($, on) => {
    const w = new World().install(on)
    await ad2($, w, step)
    if (!HAS) return
    expect(w.rowsOf('digest_submit').map(r => [r.lane, r.result])).toEqual([['soft-blocked', 'skipped:running']])
    // The timer's result: the step it unblocks can run, so the block is today's [idle].
    const t = await resultTurn($, w, notif('b7'))
    expect(t.block ?? '').toContain(head(w, 'idle') ?? '')
    expect(t.block ?? '').not.toContain(head(w, 'idle-done') ?? '')
    await w.turnEnd($, 'The timer ended; nothing new started.')
    await w.advance(5000)
    expect(w.submits.length).toBe(1)
    const sent = w.submits[0] ?? ''
    expect(sent).toContain('code now reads the work lane as hard-blocked (the summary says soft-blocked, but nothing runs)')
    expect(sent).toContain('print the away digest')
    expect(sent).toContain('Basis: 0 of 2 listed steps marked done; 0 units running; git: not measured (by code, as is)')
    expect(sent.endsWith('or Nothing needed from you.')).toBe(true)
    expect(w.rowsOf('digest_submit').map(r => [r.lane, r.result])).toEqual([['soft-blocked', 'skipped:running'], ['hard-blocked', 'submitted']])
    expect(w.rowsOf('lane_outcome').map(r => [r.lane, r.source, r.at])).toEqual([
      ['soft-blocked', 'status', 'build'], ['working', 'recheck', 'delivery'], ['hard-blocked', 'recheck', 'recheck'], ['hard-blocked', 'recheck', 'submit'],
    ])
    // The digest turn runs and ends: no second one, and a later turn not of a person's gets no note.
    await w.turnStart($, sent)
    await w.turnEnd($, 'Stopped: waiting on you.\n\nNeeds you:\n1. Approve the push.')
    await w.advance(5000)
    const cron = await resultTurn($, w, 'A scheduled check ran.')
    expect(cron.ctx).toBe('')
    await w.turnEnd($)
    await w.advance(5000)
    expect(w.submits.length).toBe(1)
    // The person is back: the [idle-again] block reads the lane again, hard-blocked ([idle-done]'s pointer branch).
    await w.userTurn($, 'back')
    const back = ctxOf(w)
    expect(back).toContain("A background result's turn got this block at")
    expect(back).toContain('code reads the work lane as hard-blocked')
  })
}

test('rule (b) with idle_digest return: no digest turn at the result turn\'s end; the person\'s return gets the hard-blocked [idle-done] block', { options: { idle_digest: 'return' } }, async ($, on) => {
  const w = new World().install(on)
  await ad2($, w, 'On the timer notification, reply with one line acknowledging it')
  if (!HAS) return
  await resultTurn($, w, notif('b7'))
  await w.turnEnd($)
  await w.advance(5000)
  expect(w.submits).toEqual([])
  expect(w.rowsOf('digest_submit').map(r => [r.lane, r.result])).toEqual([['soft-blocked', 'skipped:return'], ['hard-blocked', 'skipped:return']])
  await w.userTurn($, 'back')
  const back = ctxOf(w)
  expect(back).toContain('code reads the work lane as hard-blocked')
  expect(back).toContain("The user's own message opened this turn: only ≤5 lines of it")
})

test('rule (b): the result turn already printed the digest ([idle] step 5): no second one', async ($, on) => {
  const w = new World().install(on)
  await ad2($, w, 'On the timer notification, reply with one line acknowledging it')
  if (!HAS) return
  await resultTurn($, w, notif('b7'))
  await w.turnEnd($, 'Stopped: waiting on you. Basis: 0 of 2 listed steps marked done.\n\n**Needs you:**\n1. Approve the push. Blocks: step 2.')
  await w.advance(5000)
  expect(w.submits).toEqual([])
  expect(w.rowsOf('lane_outcome').map(r => [r.lane, r.at]).slice(-1)).toEqual([['hard-blocked', 'recheck']])
  // A later turn not of a person's gets no note either: the lane was told.
  expect((await resultTurn($, w, 'A scheduled check ran.')).ctx).toBe('')
})

test('rule (b): two jobs, a step on each: the first result turn ends soft-blocked (no digest); the last one\'s end gives hard-blocked and one digest turn', async ($, on) => {
  const w = new World().install(on)
  w.resumeHere = 'Status: soft-blocked · Acuity: stable · State: two shells run (checkpoint: clean)\nStep 1: none\n' +
    '## Next steps\n1. when B-1 ends, read its log · todo\n2. when B-2 ends, read its log · todo\n3. `git push` · todo; gated: ask user: push\n'
  w.measureBlock = 'Git: main @ 3f9c2e1, 0 modified, 0 untracked\nIn flight (sidecar 2026-10-21 14:00 +0300):\n  b1 · shell · running\n  b2 · shell · running\nEvidence: none'
  await w.start($)
  await idleCompaction($, w)
  await w.advance(5000)
  if (!HAS) return
  await resultTurn($, w, notif('b1'))
  await w.turnEnd($)
  await w.advance(5000)
  expect(w.submits).toEqual([])
  // The second result: still working by its result (no note), then its end reads hard-blocked.
  expect((await resultTurn($, w, notif('b2'))).ctx).toBe('')
  await w.turnEnd($)
  await w.advance(5000)
  expect(w.submits.length).toBe(1)
  expect(w.submits[0] ?? '').toContain('code now reads the work lane as hard-blocked')
  expect(w.rowsOf('lane_outcome').map(r => [r.lane, r.at])).toEqual([
    ['soft-blocked', 'build'], ['working', 'delivery'], ['hard-blocked', 'recheck'], ['hard-blocked', 'submit'],
  ])
})

test('rule (b): one digest per episode: a turn already told the soft-blocked digest, so the result turn\'s end submits none; the next turn still gets the one-line change note', async ($, on) => {
  const w = new World().install(on)
  await ad2($, w, 'On the timer notification, reply with one line acknowledging it')
  if (!HAS) return
  // A scheduled turn takes the block while the timer runs: the soft-blocked digest.
  expect((await resultTurn($, w, 'A scheduled check ran.')).block ?? '').toContain('code reads the work lane as soft-blocked')
  await w.turnEnd($)
  // The timer's result reads working (no note); its end reads hard-blocked; the digest went out already.
  expect((await resultTurn($, w, notif('b7'))).ctx).toBe('')
  await w.turnEnd($)
  await w.advance(5000)
  expect(w.submits).toEqual([])
  expect(w.rowsOf('lane_outcome').map(r => [r.lane, r.at])).toEqual([
    ['soft-blocked', 'build'], ['soft-blocked', 'delivery'], ['working', 'recheck'], ['hard-blocked', 'recheck'],
  ])
  // The change is not swallowed: the next turn not of a person's says what changed in one line, once.
  const note = (await resultTurn($, w, 'A scheduled check ran.')).ctx
  expect(note).toContain('code reads the work lane as hard-blocked (the summary says soft-blocked, but nothing runs)')
  expect(note).toContain('the away digest went out already: say in one line that the lane is now hard-blocked')
  await w.turnEnd($)
  expect((await resultTurn($, w, 'A scheduled check ran.')).ctx).toBe('')
  await w.turnEnd($)
  await w.advance(5000)
  expect(w.submits).toEqual([])
})

test('rule (b): work the result turn starts supersedes the lane: no digest at its end', async ($, on) => {
  const w = new World().install(on)
  await ad2($, w, 'On the timer notification, reply with one line acknowledging it')
  if (!HAS) return
  await resultTurn($, w, notif('b7'))
  await $.tool.call({ tool: 'Agent', description: 'next step', prompt: 'do it', mode: 'standard' } as never)
  await w.turnEnd($)
  await w.advance(5000)
  expect(w.submits).toEqual([])
})
