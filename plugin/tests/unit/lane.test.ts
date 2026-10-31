// Away digest phase 1 (owner 2026-10-27 12:5x, xxxxxxxx-05/-06/-08/-09; AWAY-DIGEST §11): the
// work lane's Status from the summary, re-checked by code; finished or blocked lanes show the
// digest instead of continuing; the digest turn right after an idle compaction with nothing
// running (`idle_digest: submit`) or none (`return`, `off`); the re-check of later turns. Owner
// rule (c) (2026-10-28) makes `off` the default of 0.1.1: no digest turn and no text asks for the
// full digest. The tests here pin `submit` unless they name a value (`test` below); the `off`
// tests at the end name it, or take the shipped default (`kitTest`).
import { expect, test as kitTest } from 'claude-code/testing'
import type { Engine, TestBody, TestOptions } from 'claude-code/testing'
import type { Tag } from '../../hooks/lib/assemble'
import { assemble, hasTag } from '../../hooks/lib/assemble'
import { DEFAULTS, parseOptions } from '../../hooks/lib/config'
import type { LaneFacts } from '../../hooks/lib/lane'
import { DIGEST_END_RE, LANE_BASIS_MAX, LANE_WHY_MAX, OFF_LINE_END_RE, asLaneFacts, digestLine, laneBasis, laneFacts, laneNote, laneOf, measuredRunning, notifiedTasks, resultDigestLine, startsWork } from '../../hooks/lib/lane'
import type { PendingResume } from '../../hooks/lib/deps'
import { ARMED_FILE, pendingRecord } from '../../hooks/lib/resume'
import { SID_A, T0, WATCH, World, raiseCompact } from './harness.test'

/**
 * A kit test with `idle_digest: submit` unless its options name a value: these tests pin the
 * digest as built for `submit` and `return` (owner xxxxxxxx-09), unchanged by the `off` default.
 */
function test(name: string, ...rest: readonly [TestBody] | readonly [TestOptions, TestBody]): void {
  const [o, body]: [TestOptions, TestBody] = rest.length === 1 ? [{}, rest[0]] : [rest[0], rest[1]]
  kitTest(name, { ...o, options: { idle_digest: 'submit', ...o.options } }, body)
}

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
  // A wait on a job is held on the user, as on release-0.1.1b (the known limit of 0.1.1).
  expect(laneFacts(marks)).toEqual({ status: 'soft-blocked', todo: 3, done: 0, unmarked: 0, free: 1, onJob: 0, onUser: 2, elsewhere: false, listed: true, step1: 'none', gate: 'none', unstable: false })
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

test('idle_digest: off by default (owner rule (c), 2026-10-28); submit; return; any other value reads as off with a note', () => {
  expect(DEFAULTS.idle_digest).toBe('off')
  expect(parseOptions({}).idle_digest).toBe('off')
  expect(parseOptions({ idle_digest: ' Submit ' }).idle_digest).toBe('submit')
  expect(parseOptions({ idle_digest: ' Return ' }).idle_digest).toBe('return')
  expect(parseOptions({ idle_digest: 'OFF' }).idle_digest).toBe('off')
  expect(parseOptions({ idle_digest: 'submit' }).notes.invalid).toEqual([])
  const bad = parseOptions({ idle_digest: 'later' })
  expect([bad.idle_digest, bad.notes.invalid]).toEqual(['off', ['idle_digest']])
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

test('finished lane, nothing running, idle_digest submit: one digest turn right away with the [idle-done] block; no [idle]', async ($, on) => {
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

test('H1: a recheck whose lane_outcome row cannot be written still puts its note beside the prompt, once; the episode marks it told', async ($, on) => {
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
  // The recheck reads the agent list last before its row: the next clock read (that row's
  // stamp) rejects, once.
  const list = [{ id: 'a1', status: 'completed' }, { id: 'a2', status: 'completed' }]
  let armed = false
  Object.defineProperty(w, 'agents', { configurable: true, get: () => ((armed = true), list) })
  w.nowFails = () => {
    const f = armed
    armed = false
    return f
  }
  const second = await resultTurn($, w, notif('a2')).catch((e: unknown) => ({ ctx: 'threw: ' + String(e), block: undefined }))
  w.nowFails = undefined
  expect(second.ctx).toContain('code reads the work lane as hard-blocked')
  expect(w.rowsOf('lane_outcome').filter(r => r.at === 'recheck')).toEqual([])
  // Told once: a later result turn of the episode gets no second note.
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
/*
 * The wordings below are every wording of the earlier test lists and of the review tables (review 5
 * and 6: the fix table and the user lens, 571 in all), each in the one list its hold puts it in. A
 * few hold a no-break space between two words (it reads as a plain space for the job reading in
 * both copies). The helper case AD-11 reads these five lists from this file and checks that the
 * saved copy's status (copies.pm `_hold_of`) gives each the same hold.
 */
/** A job trigger leading the step, no user-wins word: held on the job (rule (a)). */
const TRIGGERS = [
  // From the earlier TRIGGERS list.
  'On the timer notification, reply with one line acknowledging it',
  'when CI finishes, report the result',
  'after the build ends, tag the release',
  'once the B-1 result arrives, summarise it',
  'when the timer fires, check its log',
  'upon the workflow notification, read its output',
  'after the agent result, merge the findings',
  'On the B-2 shell result, read the log — done when read',
  'as soon as the pipeline passes, merge',
  'On the result of the run, write it up',
  "After the agent's output comes back, merge it",
  'Then, when the build is green, push the tag',
  'once the results arrive, summarise each',
  'When the tests finish, report',
  'After the tests pass, merge',
  'When the agent reports back, merge',
  'When the build succeeds, tag',
  'After the run, commit',
  "Upon the agent's return, merge",
  'When the timer fires, answer with one line',
  'after the build ends, reply and tag the release',
  'When the build finishes, post the summary in the log',
  'Once the agent returns, merge its branch',
  'After the tests pass, push the tag',
  "On the agent's output, update the notes",
  'As soon as the pipeline completes, rerun the flaky suite',
  'When the run fails, open an issue',
  'Once the workflow is green, tag the release',
  'Upon the build, deploy to staging',
  'When the tests are green, update the changelog',
  'When the timer fires, check the queue length',
  'Then, when CI finishes, reply with the result',
  'When the build finishes, upload the user-facing docs',
  'When the build finishes, deploy to us-east-1',
  'Once the build passes, merge to main',
  'When the build finishes, push the tag',
  'When CI passes, merge the branch',
  'Once the pipeline completes, deploy to staging',
  'After the tests pass, bump the version',
  'When the agent returns, summarise its findings',
  'On the build result, fix any failures',
  "Upon the subagent's output, collate the list",
  'After B-2, rerun the linter',
  'As soon as the workflow ends, write the changelog',
  'When the timer fires, check the deploy',
  'Once the tests are green, open the PR',
  'When the Jenkins build finishes, record the artifact hash',
  'When the GitHub Actions run completes, read the logs',
  'After the CircleCI pipeline passes, cut the release',
  'Once the nightly builds finish, compare timings',
  'When the subagents report back, dedupe the results',
  'After the shell exits, check the exit code',
  'Once the test suite fails, bisect the change',
  'On the CI notification, rebase onto main',
  "On B-3's result, update the table",
  "When CI's result comes in, triage failures",
  'When the build is done, run it again',
  'When the timer notification arrives, ping the channel',
  'After the run: commit the snapshot',
  'after the build; tag it',
  'Then, when CI finishes, deploy',
  'WHEN THE BUILD FINISHES, DEPLOY',
  'When the build finishes—deploy',
  'When the build has finished, deploy',
  'When the builds have completed, deploy',
  'When the build is complete, deploy',
  'When the build succeeds, deploy',
  'Once the job is finished, archive the logs',
  'When the agents are done, merge notes',
  'After the build fails, open an issue',
  'When the npm test run finishes, publish',
  'When the CI run is green, ship it',
  'When the build and tests finish, tag',
  'When the cron job fires, rotate keys',
  'After the notification, resume the migration',
  "Upon the run's completion, clean up",
  'On completion of the build, deploy',
  'When the agent returns, merge the team-config changes',
  'When the build finishes , deploy',
  'When the build finishes: deploy',
  'On the B-12 notification, close the loop',
  'After the job, commit',
  'When the build finishes, deploy',
  'When the build finishes, reply in the log',
  'When the build finishes, run i18n checks',
  // Review 6, the user lens (all.tsv).
  'When the build finishes, push to main',
  'Once CI is green, merge the PR',
  'After the test run completes, update the changelog',
  'On the timer notification, reply with one line',
  'When the agent returns, merge its branch',
  'After the build, commit the notes',
  'Upon CI, rerun the flaky test',
  'When the shell exits, read its log',
  'As soon as the workflow completes, close the issue',
  'When the build fails, retry once',
]
/**
 * The known limit of 0.1.1: a wait on a job (`Wait for the timer notification, then reply`, `Wait
 * for CI, then merge`) is held on the user, as release-0.1.1b reads every wait (its `HELD_RE`);
 * a job's result does not unblock it. Planned for 0.1.2: an explicit `waits: job` / `waits: you`
 * mark in the summary's steps, read by code instead of the wording.
 */
const KNOWN_LIMITS = [
  // From the earlier TRIGGERS list.
  'Wait for the timer notification, then reply with one line',
  'waiting on B-2, then read its log',
  'Wait for Jenkins build, then read its log',
  'Wait for Build 42 to finish',
  'Wait for Agent B to finish',
  'Wait for Agents to return',
  'Wait for Pipeline 7',
  'Wait for Timer',
  'Wait for Workflow wf_1 to end',
  'Wait for the build — then reply',
  'Wait for the build—reply with status',
  'Wait for the nightly build to finish, then tag it',
  'Wait for B-3, then commit',
  'Wait for the tests to finish, then summarise the failures',
  'Wait for the build to finish, then publish the docs',
  'Wait for CI, then merge',
  'Waiting on the pipeline; then tag v2',
  "Awaiting the agent's output before writing the summary",
  'wait for B-4 then rerun',
  'Wait for the deploy job to finish, then smoke-test',
  'Wait for the Docker build',
  'Wait for the webpack build to finish',
  'Wait for Bazel tests to pass',
  'Wait for the e2e suite.',
  'Wait for the build(s) to finish',
  'Wait for the builds/tests to finish',
  'Wait for the `make` build',
  'Wait for "nightly" build',
  'Wait for the build to finish, then tag',
  'Wait for the build before merging',
  'Wait for CI, then merge the PR',
  'Wait for the build to be done, then tag',
  'When the build finishes, wait for the tests to pass, then merge',
  'Wait for the build—then tag',
  'Wait for the build - then tag',
  'Wait for the build (B-2), then tag',
  'Wait for the build to finish — done when tagged',
  // Review 6, the user lens (all.tsv).
  'Wait for CI, then push the tag',
  'Wait for the tests, then deploy to staging',
  'Wait on B-12, then tag v1.2',
  'Awaiting the workflow, then open a PR',
  'Wait for the pipeline to finish, then rebase',
  "Wait for the subagent's output, then summarise it",
  // Reviews 5 and 6, the fix table (table.txt).
  '1. Wait for the build',
]
/** release-0.1.1b reads these held (its `HELD_RE`): held on the user, exactly as there. */
const NO_REGRESSION_USER = [
  // From the earlier USER_WAITS list.
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
  'Wait for the timer notification, then reply to the user with one line',
  'wait for CI to email me',
  'wait for the client build to finish',
  'Wait for the build and tell the user',
  'Wait for the build and ping me',
  'Wait for CI and notify the owner',
  'Await the build and ping them',
  'Wait for the build, then tell me',
  'wait for anna to run CI',
  'Wait for Anna, then run the build',
  // From the earlier APPROVAL_WAITS list.
  'Wait for approval to run the build',
  'Wait for approval to run the tests',
  'Await approval to run the deploy job',
  'Wait for permission to run the pipeline',
  'Wait for the go-ahead to run the build',
  'Wait for go ahead to run the build',
  'Wait for confirmation to run CI',
  'Wait for OK to run the tests',
  'Wait for an okay to rerun the job',
  'Wait for clearance to run the agents',
  'Await sign-off to run the pipeline',
  'Wait for sign-off to run the release job',
  'Wait for sign off on the build',
  'Wait for sign-off on build 42',
  'Wait for go-ahead on build 7',
  'Wait for feedback on build 42',
  'Wait for the answer to build',
  'Wait for review to run the suite',
  'Wait for a review to run the suite',
  'Wait for a reply on the build',
  'Wait for a decision on the pipeline',
  'Wait for a yes to run the deploy job',
  'Wait for consent to run the workflow',
  'Wait for LGTM on the build',
  'Wait for merge request approval, then run the pipeline',
  'Wait for the build approval',
  'Wait for CI approval',
  'Wait for test sign-off',
  'Wait for the pipeline review',
  'Wait for the release build sign-off',
  'Wait for the run approval, then merge',
  'Wait for the build to be approved',
  'On the build result, wait for the go-ahead',
  // From the earlier USER_PARTS list.
  'Wait for the build, then ask Anna whether to deploy',
  'After the build, wait for the stakeholder to accept the change',
  'When the tests pass, wait for my manager to merge',
  'Wait for the build; she will decide on the deploy',
  'Wait for CI and a nod from Anna',
  "Wait for CI and Anna's thumbs-up",
  'Wait for the build, then wait for input',
  'Wait for the build and a manual check',
  'Wait for the build and authorization to deploy',
  'Wait for the build and authorisation to deploy',
  'When the build finishes, wait for a response',
  'Wait for the build to be signed off',
  'Wait for the build to be accepted by product',
  'Wait for the build to be reviewed',
  'Wait for the build; answer pending',
  'Wait for the build and replies from the mailing list',
  'Wait for the build and answers to the open questions',
  'Wait for the pipeline and the green light',
  'Wait for the pipeline and a thumbs up',
  'Wait for the pipeline and the say-so to ship',
  'Wait for the pipeline and his acknowledgement',
  'Wait for the pipeline and their verdict',
  "Wait for CI, then get the CTO's blessing",
  'Wait for CI, then the manager merges',
  "Wait for CI and legal's sign off",
  'After the run, await instructions',
  'After the run, await direction from product',
  'Wait for the build plus a go/no-go call',
  'Wait for the build and a vote',
  'Wait for the build and the CAB to approve',
  'Wait for CI and an ack',
  'When CI is green, ping Bob and wait for his OK',
  'When CI is green, ping Bob and wait for his nod',
  "Wait for the release build and the user's ok",
  'Wait for CI. Then: Anna merges',
  'Wait for the build — Anna has the final say',
  'Wait for CI, then ask for approval',
  'Wait for CI, reply pending from the owner',
  'Wait for build 42 to be greenlit',
  "Wait for the deploy job; then get Ops' consent",
  'Wait for the deploy job; then Ops must agree',
  'Wait for the deploy job; needs a human eye',
  'Wait for the deploy job; needs eyes from SRE',
  'Wait for the deploy job and a reviewer',
  'Once the build completes, wait for whoever owns the repo',
  'Wait for the build, then answer: which tag?',
  'Wait for Zoë to run the build',
  'Wait for the build, then ask José',
  "wait for the build and Øyvind's OK",
  'Wait for the 🚀 build, then ask the user',
  "Wait for the build: answer Fran's question",
  'Wait for the user’s build',
  'Wait for the Müller build, then ask Müller',
  "Wait for André's build",
  'Wait for the naïve build and the reviewer',
  "Wait for the pipeline's manual gate",
  'Wait for the manual test run',
  'Wait for the build to be accepted',
  'Wait for the build to be greenlit',
  'Wait for the build to get a thumbs-up',
  "Wait for the CI run and Sam's ack",
  'Wait for the build, then for my go',
  'When the build finishes, wait for my call',
  'When the tests pass, wait for the stakeholder',
  'When the tests pass, wait for the product manager',
  'When the tests pass, wait for the designer',
  'When the tests pass, wait for legal',
  'When the tests pass, wait for the on-call engineer',
  'Wait for the build, then have Dana merge it',
  'Wait for the deploy pipeline to be unblocked by ops',
  'Wait for the build from the release manager',
  'When CI passes, wait for the merge window to be approved by Sam',
  'When the build finishes, wait for the CAB vote',
  'When CI passes, wait for authorization to deploy',
  'When CI passes, wait for the verdict',
  'When CI passes, wait for Sam to approve',
  'When CI passes, wait for the human-in-the-loop step',
  'When CI passes, wait for the user’s go',
  'Wait for the build; we decide then',
  'Wait for the build, then wait for our go',
  'When the build finishes, wait for input',
  'When the build finishes, wait for instructions',
  'Wait for the build and a vote',
  'Wait for the build before Anna merges',
  'Wait for the build to be merged',
  'Wait for the build plus the tests and the owner',
  'Wait for the build: reply pending',
  'When the build finishes, wait for the tests and Sam',
  'wait for the café build, then deploy',
  'Wait for the build, the approval and the tag',
  // From the earlier TRADE_OFFS list.
  'Wait for CI. Merge the PR',
  'Wait for the café build',
  // From the earlier inline checks.
  'Wait for the user',
  'Wait for the build plus the tests',
  'after CI finishes, deploy — gated: ask user: deploy',
  // Review 6, the user lens (all.tsv).
  'Wait for CI; merge when the boss says so',
  'Wait for the build; the director must sign it',
  'Wait for CI, then merge once compliance clears it',
  'Wait for CI, then merge if the boss is happy',
  'Wait for the tests, then the boss merges',
  'Wait for the build, then merge once the boss has signed',
  'Wait for the build, then merge when change control signs',
  'Wait for the build, then deploy in the window the boss picks',
  'Wait for the CI run, then merge only with a sanction from security',
  'Wait for the agent result, then stop for the boss',
  "Wait for the agent's result, then hold until the boss weighs in",
  'Wait for the build to pass, then wait for the boss',
  'Wait for the build, then await the boss',
  "Wait for the build and the boss's go",
  'Wait for CI and a nod from the lead',
  "Wait for the reviewer's build",
  'Wait for the test results, then ask Fran',
  'Wait for the build, then ask',
  'Wait for the build — answer pending',
  'Wait on B-3, then the boss deploys',
  'Wait on B-3; the boss deploys',
  'Wait on B-3: boss to deploy',
  'Wait for the pipeline, then go when the boss says go',
  "Wait for the pipeline, then merge on the boss's word",
  "Wait for the subagent's output, then await a human",
  'Wait for CI, then merge after a manual check',
  'Wait for CI, then merge after the 4-eyes check',
  'Wait for CI, then merge after a four-eyes check by security',
  'Wait for the job, then the steward merges',
  'Wait for CI, then Ünal merges',
  'Wait for CI, then ünal merges',
  'Wait for CI, then the business merges',
  'Wait for CI, then the board decides',
  'Wait for CI, then the board weighs in',
  'Wait for CI, then the customer success folks weigh in',
  'Wait for CI, then the higher-ups weigh in',
  'Wait for CI, then hold for the higher-ups',
  'Wait for CI, then hold for sign-off',
  'Wait for CI, then hold for the security sign',
  "Wait for the build, then merge if the boss doesn't object",
  'Wait for the build, then merge unless the boss objects',
  'Wait for the build, then merge unless security vetoes',
  'Wait for the build, then merge after a veto period',
  'Wait for CI, then merge once okayed',
  'Wait for CI, then merge once OKed',
  'Wait for CI, then merge once LGTMed',
  "Wait for CI, then merge once LGTM'd",
  'Wait for CI, then merge once approved-by is set',
  'Wait for CI, then merge once reviewed-by is set',
  'Wait for CI, then merge once signed-off-by is set',
  'Wait for CI, then merge when sign-off-ready',
  'Wait for CI, then merge once green-lit-by-ops',
  'Wait for CI, then merge if go-ahead-given',
  'Wait for CI, then query the boss',
  'Wait for CI, then sync with the boss',
  'Wait for CI, then raise it at standup and hold',
  'Wait for the build, then hold for a go/no-go',
  'Wait for the build, then hold for a thumbs up',
  'Wait for the build, then hold for an approval stamp',
  'Wait for the build, then hold for the stamp',
  'Wait for the build, then hold for a rubber stamp',
  'Wait for the build, then hold for a signature',
  'Wait for the build, then hold for a countersign',
  'Wait for the build, then hold for a waiver',
  'Wait for the build, then hold for an exception from security',
  'Wait for the build, then hold for a ruling',
  'Wait for the build, then hold for a call from the boss',
  'Wait for the build, then hold for a word from the boss',
  'Wait for the build, then hold for a green from the boss',
  'Wait for the build, then hold until legal clears it',
  'Wait for the build, then hold until the boss returns',
  "Wait for the build, then hold off until Monday's meeting",
  "Wait for the build, then hold off until monday's meeting",
  'Wait for the build, then pause for the boss',
  'Wait for the build, then pause for an okay',
  'Wait for the build, then pause for an O.K.',
  'Wait for the build, then pause till the boss is back',
  'Wait for the build, then pause till the boss is in',
  "Wait for the build, then the boss's ok",
  "Wait for the build, then the boss's call",
  'Wait for CI, then mgr merges',
  'Wait for CI, then the lead dev merges',
  'Wait for CI, then the tech lead merges',
  'Wait for CI, then the TL merges',
  'Wait for CI, then the EM merges',
  'Wait for CI, then the release manager merges',
  'Wait for CI, then the release mgr merges',
  'Wait for CI, then security merges',
  'Wait for CI, then the security folks merge',
  'Wait for CI, then the infra folks merge',
  'Wait for CI, then the DBA merges',
  'Wait for CI, then the DBA runs the migration',
  'Wait for CI, then the DBAs run the migration',
  'Wait for CI, then the sysadmin deploys',
  'Wait for CI, then the admin deploys',
  'Wait for CI, then the on call deploys',
  'Wait for CI, then the oncall deploys',
  'Wait for CI, then the on-call deploys',
  'Wait for CI, then QA-approve',
  'Wait for CI; needs-approval label',
  'Wait for CI, then reapprove',
  'Wait for CI, then re-review',
  'Wait for CI, then pre-approval',
  "Upon the workflow's result, wait on the boss",
]
/**
 * release-0.1.1b reads these free; a job trigger leads them and no user-wins word stands in them (a
 * name, a role or a say outside the word lists, a question mark are none): held on the job, which
 * stops sooner than 0.1.1b's free reading, never later.
 */
const NO_REGRESSION_JOB = [
  // From the earlier USER_PARTS list.
  'When CI passes, wait until Sam says go',
  'When CI finishes, Anna merges',
  'After the run, have Dana merge it',
  // From the earlier TRADE_OFFS list.
  'When the build finishes, run the Lead-time report',
  'When CI finishes, push to GitHub',
  // Review 6, the user lens (all.tsv).
  'When CI passes, merge after a +1',
  'When CI passes, merge after a 👍 from security',
  'When the build completes, seek an endorsement from security',
  'When the build completes, ratify with the board',
  'Once the build is green, get the boss to o.k. it',
  'Once the build is green, the boss merges',
  'When the pipeline finishes, the director signs and then deploy',
  'When CI passes, get @anna to merge',
  'When CI finishes, hand the boss the diff and stop',
  'When CI finishes, the boss tags the release',
  'When CI finishes, boss tags the release',
  'When CI finishes, the CISO tags the release',
  'When CI finishes, the release captain merges',
  'After the build, the release captain merges',
  'After the build: the release captain merges',
  'When the build finishes, merge or revert?',
  'When CI finishes, which branch to merge?',
  'When CI finishes, merge to main or to dev?',
  'After the build result, proceed?',
  'When the build is in, the boss is in, merge',
  'On the agent notification, forward it to the boss',
  'On the agent notification, forward it upstairs',
  'On the agent notification, escalate',
  'On the agent notification, escalate and hold',
  "Upon the workflow's result, defer to the boss",
  'When the subagent returns, the boss has the final word',
  'When the subagent returns, the boss has the last word',
  'Once the timer fires, the boss picks a slot',
  'Once the timer fires, the boss picks',
  "Once the timer fires, y'all pick",
  'Once the timer fires, u pick',
  'Once the timer fires, ye pick',
  // Reviews 5 and 6, the fix table (table.txt).
  'When CI finishes, anna merges',
]
/**
 * release-0.1.1b reads these free, and no job trigger leads them with no user-wins word: free work,
 * exactly as there (a step that only mentions a job, a trigger later in the step, a user-wins word
 * next to a trigger, a wait 0.1.1b reads no wait in: `wait till`, `wait until`).
 */
const NO_REGRESSION_FREE = [
  // From the earlier TRIGGERS list.
  'wait till CI passes',
  'Wait till CI passes, then deploy',
  'Wait till the tests pass, then commit',
  'Wait until the workflow completes, then archive logs',
  // From the earlier NOT_TRIGGERS list.
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
  // From the earlier USER_WAITS list.
  'wait until the maintainer runs the build',
  'On the timer notification, reply to the user',
  'when CI finishes, report to the team',
  'once the results arrive, summarise them',
  // From the earlier APPROVAL_WAITS list.
  'When the build passes and it is approved, merge',
  'after CI finishes, confirm the deploy',
  // From the earlier USER_PARTS list.
  'When the build finishes, ask whether to deploy',
  'Once CI passes, check with the manager before merging',
  'When CI finishes, wait until they merge it',
  'After the build, prompt for input on the release name',
  'Once the build is green, we decide whether to ship',
  'Once the build is green, the PO picks the release name',
  'When the tests finish, the product owner chooses the option',
  'On the build result, ask: deploy now or wait?',
  'On the build result, question for the stakeholder: ship?',
  'When the agent returns, check in with the designer',
  'When the agent returns, hand the diff to the designer for sign-off',
  'Once the tests pass, request a merge from the maintainers',
  'Once the tests pass, request merge permission',
  'When the build passes, let Anna decide',
  'When the build passes, the user decides',
  "On the timer notification, answer the reviewer's question",
  'Then, after the build finishes, approval is needed',
  'After the run, Approve the plan?',
  'After the run, choose between A and B (ask)',
  "When CI finishes, pending: Anna's input",
  'when ci finishes, ask what to name the tag',
  'Once the build completes, double-check with whoever owns the repo',
  'When the build finishes, and answers come back, merge',
  "When the build finishes, get Renée's sign-off",
  'When the build finishes, ask Jürgen',
  "When the tests pass, answer Ünal's question",
  'When CI passes, get the release signed off',
  'When the build finishes, get a nod from Sam',
  "When the build finishes, get the vendor's blessing",
  'When CI passes, wait to be allowed to deploy',
  'When CI passes, I need the go/no-go',
  'When the timer fires, ask Sam whether to ship',
  'After the build passes, ask the lead dev',
  'When the build finishes, check with Sam',
  'When the build finishes, request approving',
  'after the build ends; reply to Sam',
  'When the build finishes, reply to Sam',
  'When the build finishes, reply to the thread',
  'When the agent returns, I deploy',
  'When the agent returns, we deploy',
  // From the earlier TRADE_OFFS list.
  'When the agent finishes, collect the reviews',
  "When the build finishes, record the build's output in OK.md",
  'When the build finishes, copy the outputs to /tmp/yes',
  'When the build finishes, update the lead time metric',
  'When the tests finish, update the review queue script',
  'After the build result, refresh the reply templates',
  'After the run: replies go to the log',
  'When all agents return, merge their notes',
  'Once the notifications arrive, process them',
  'When the build finishes, check if the deploy is OK',
  'When the build finishes, answer the open lint question in the notes',
  'When the build finishes, update the review checklist file',
  'When the test suite passes, write the decision log entry',
  'When CI finishes, run yes | ./install.sh',
  'When the build finishes, push to the users table migration',
  // From the earlier FREE_GAPS list.
  'When the café build finishes, deploy',
  'When the naïve build finishes, merge',
  'On the café build result, reply',
  'After B-٣, rerun the linter',
  "When Zoë's build finishes, ask Zoë",
  "When the job's done, open a PR",
  "When the build's finished, deploy",
  'When the build’s result comes in, deploy',
  'When CI goes green, merge',
  'When the timer elapses, check the deploy',
  'When the test run times out, retry',
  'When the pipeline errors, roll back',
  'When the deploy finishes, verify the site',
  'When the PR checks pass, merge',
  'Once GitHub Actions finishes, merge',
  // From the earlier inline checks.
  'fix the build script',
  'work on the results table',
  'run the suite — done when the run finishes',
  'rerun the failed CI job',
  'tidy the notes after review',
  'write the reply to the reviewer',
  'Ask Anna for approval',
  // Review 6, the user lens (all.tsv).
  'After the build finishes, hand over to the security team',
  'When the build finishes, ask the boss',
  'When the build finishes, check with the boss',
  'When the build passes, merge after Priya approves',
  "When the build passes, merge after the PO's thumbs-up",
  'When the tests pass, merge once I say so',
  'When the tests pass, merge once we agree',
  'On the build notification, get sign off from QA',
  'On the CI result, escalate to the on-call',
  "Upon the agent's return, run it by the client",
  'After the run, go over it with the stakeholders',
  'After the workflow ends, let the owner pick',
  'As soon as the build is green, ping the owner for the merge',
  'When the job finishes, the human merges',
  'When the job finishes, a person merges',
  'Once the tests pass, get approval',
  'Once the tests pass, get the go-ahead',
  'Once the tests pass, get permission to deploy',
  'Once the tests pass, get clearance to deploy',
  'Once the tests pass, get an OK to deploy',
  'Once the tests pass, get confirmation',
  'Once the tests pass, get a yes',
  'Once the tests pass, get consent',
  'Once the tests pass, LGTM then merge',
  'When CI is green, merge the merge request approval',
  'When the build is done, get the decision',
  'When CI finishes, get feedback',
  'When CI finishes, get a review',
  'When CI finishes, the SecOps lead signs',
  'On the agent notification, forward it for approval',
  "Upon the workflow's result, defer to legal",
  'When the subagent returns, the boss has the final say',
  'Once the timer fires, they pick',
  'Once the timer fires, thee decides',
]
/** Every wording above. */
const NO_REGRESSION = [...TRIGGERS, ...KNOWN_LIMITS, ...NO_REGRESSION_USER, ...NO_REGRESSION_JOB, ...NO_REGRESSION_FREE]
/**
 * release-0.1.1b's `HELD_RE`, kept here as a fixture: what that release read held (on the user);
 * any other step it read free.
 */
const OLD_HELD_RE = /\b(?:gated|ask user|pending answer|wait(?:s|ing)? (?:on|for)|await(?:s|ing)?|blocked (?:on|by)|needs? (?:an? )?(?:approval|the user|user|owner|you|your))\b/i
/**
 * The user-wins words as the owner's tie-break states them, kept apart from lane.ts (spelled out
 * word by word, not as lane.ts's stems) so the test does not only read the code back: a person or
 * a pronoun, a person's say in any form (review 5: the class, not its instances), a gate. A reply
 * or an answer with no object that opens the step or a clause after `,`, `—` or `then` is the
 * session's own.
 */
const SPEC_WORDS = [
  'I', 'me', 'my', 'mine', 'myself', 'we', 'us', 'our', 'ours', 'you', 'your', 'yours', 'he', 'him', 'his', 'she', 'her', 'hers',
  'they', 'them', 'their', 'theirs', 'someone', 'somebody', 'anyone', 'anybody', 'everyone', 'everybody', 'nobody', 'who', 'whom', 'whoever',
  'user', 'users', 'owner', 'owners', 'human', 'humans', 'people', 'person', 'reviewer', 'reviewers', 'approver', 'maintainer', 'team',
  'teammate', 'colleague', 'client', 'customer', 'vendor', 'stakeholder', 'manager', 'designer', 'engineer', 'developer', 'lead', 'QA',
  'PM', 'PO', 'CTO', 'CEO', 'SRE', 'ops', 'on-call', 'CAB', 'legal', 'operator', 'admin',
  'approve', 'approves', 'approved', 'approving', 'approval', 'accept', 'accepted', 'acceptance', 'permission', 'permit', 'permitted',
  'authorize', 'authorise', 'authorized', 'authorization', 'authorisation', 'allow', 'allowed', 'go-ahead', 'go ahead', 'go/no-go',
  'green light', 'greenlit', 'say-so', 'final say', 'thumbs-up', 'thumbs up', 'nod', 'blessing', 'ack', 'vote', 'verdict', 'consent',
  'clearance', 'sign-off', 'sign off', 'signed off', 'LGTM', 'OK', 'okay', 'yes', 'confirm', 'confirmation', 'review', 'reviewed',
  'feedback', 'answer', 'answers', 'reply', 'replies', 'response', 'respond', 'input', 'instructions', 'direction', 'guidance',
  'decide', 'decides', 'decision', 'choose', 'chooses', 'choice', 'question', 'questions', 'ask', 'asks', 'request', 'agree', 'agrees',
  'check with', 'check in with', 'pending', 'need', 'needs', 'needed', 'manual', 'gate', 'gated',
]
const SPEC_USER_WINS = (step: string): boolean =>
  new RegExp(`\\b(?:${SPEC_WORDS.join('|')})(?![\\w-])`, 'i')
    .test(step.replace(/\s/g, ' ').replace(/(^|[,—]|\bthen\b)(\s*)(?:repl(?:y|ies)|answers?)(?=\s*(?:$|[,.;·—]|with\b|and\b|in\b))/gi, '$1$2'))
/** The hold lane.ts reads for one step, through laneFacts: `job`, `user` or `free`. */
const holdVia = (step: string): 'job' | 'user' | 'free' => {
  const f = laneFacts('## Resume here\n' + onJob(step))
  return f.onJob === 1 ? 'job' : f.onUser === 2 ? 'user' : 'free'
}

test('rule (a): a step a job trigger leads is held on the job under a blocked Status, whatever the trigger\'s wording', () => {
  for (const step of [...TRIGGERS, ...NO_REGRESSION_JOB]) {
    const f = laneFacts('## Resume here\n' + onJob(step))
    expect([step, f.todo, f.free, f.onJob, f.onUser]).toEqual([step, 2, 0, 1, 1])
    // While the job runs the model's soft-blocked stands; with nothing running it reads hard-blocked.
    expect([step, laneOf(f, { ...M, running: 1 }).lane]).toEqual([step, 'soft-blocked'])
    expect([step, laneOf(f, M).lane]).toEqual([step, 'hard-blocked'])
    // The turn the job's result comes with: the step it unblocks can run (xxxxxxxx-06).
    expect([step, laneOf(f, { ...M, result: true })]).toEqual([step, { lane: 'working', source: 'recheck', why: 'the summary says soft-blocked, but a result unblocks a step', byResult: true }])
    expect([step, laneOf(laneFacts('## Resume here\n' + onJob(step, 'hard-blocked')), { ...M, running: 1 }).lane]).toEqual([step, 'soft-blocked'])
  }
})

test('rule (a): not held under a working (or finished) Status; a step 0.1.1b reads free and no job trigger leads stays free work', () => {
  for (const step of [...TRIGGERS, ...NO_REGRESSION_JOB]) {
    expect([step, laneOf(laneFacts('## Resume here\n' + onJob(step, 'working')), M).lane]).toEqual([step, 'working'])
    expect([step, laneOf(laneFacts('## Resume here\n' + onJob(step, 'working')), { ...M, result: true }).lane]).toEqual([step, 'working'])
    expect([step, laneOf(laneFacts('## Resume here\n' + onJob(step, 'finished')), M).lane]).toEqual([step, 'working'])
  }
  for (const step of NO_REGRESSION_FREE) {
    const f = laneFacts('## Resume here\n' + onJob(step))
    expect([step, f.free, f.onJob]).toEqual([step, 1, 0])
    expect([step, laneOf(f, { ...M, running: 1 }).lane]).toEqual([step, 'working'])
    expect([step, laneOf(f, M).lane]).toEqual([step, 'working'])
  }
  // A step 0.1.1b reads held is held on the user: a job's result does not unblock it.
  for (const step of [...KNOWN_LIMITS, ...NO_REGRESSION_USER]) {
    const f = laneFacts('## Resume here\n' + onJob(step))
    expect([step, f.free, f.onJob, f.onUser]).toEqual([step, 0, 0, 2])
    expect([step, laneOf(f, { ...M, result: true }).lane]).toEqual([step, 'hard-blocked'])
  }
  // A result on a blocked lane with no step held on a job changes nothing.
  expect(laneOf({ ...F, status: 'soft-blocked', todo: 1, onUser: 1 }, { ...M, result: true }).lane).toBe('hard-blocked')
})

test('rule (a): Step 1 held on a job with `Gate: none` is not a free Step 1: blocked while the job runs, working in its result turn', () => {
  const f = laneFacts('## Resume here\nStatus: soft-blocked\nStep 1: On the timer notification, reply — for "go"\nGate: none · Don\'t: x\n## Next steps\n1. `git push` · todo; gated: ask user: push\n')
  expect([f.step1, f.gate, f.free, f.onJob, f.onUser]).toEqual(['set', 'job', 0, 0, 1])
  expect(laneOf(f, { ...M, running: 1 }).lane).toBe('soft-blocked')
  expect(laneOf(f, { ...M, result: true }).lane).toBe('working')
  // A Step 1 that waits on the job is gated, as on 0.1.1b.
  const w = laneFacts('## Resume here\nStatus: soft-blocked\nStep 1: Wait for the timer notification, then reply — for "go"\nGate: none · Don\'t: x\n')
  expect([w.gate, laneOf(w, { ...M, result: true }).lane]).toEqual(['set', 'hard-blocked'])
  // A record of lane facts written before the holds were told apart reads every held step as the user's.
  const { onJob: _j, onUser: _u, ...old } = { ...F, status: 'hard-blocked', todo: 2, free: 1 }
  expect(asLaneFacts(old)).toEqual({ ...F, status: 'hard-blocked', todo: 2, free: 1, onJob: 0, onUser: 1 })
  expect(asLaneFacts({ ...F, onJob: -1 })).toBe(undefined)
  expect(asLaneFacts({ ...F, gate: 'job' })?.gate).toBe('job')
})

test('rule (a), no regression from release-0.1.1b: held there, held on the user here; free there, a job hold or free here; never a job hold with a user-wins word', () => {
  expect(NO_REGRESSION.length).toBe(571)
  expect(new Set(NO_REGRESSION).size).toBe(NO_REGRESSION.length)
  for (const step of NO_REGRESSION) {
    const now = holdVia(step)
    if (OLD_HELD_RE.test(`1. ${step} · todo`)) expect([step, now]).toEqual([step, 'user'])
    else expect([step, now === 'job' || now === 'free']).toEqual([step, true])
    if (SPEC_USER_WINS(step)) expect([step, now]).not.toEqual([step, 'job'])
  }
  for (const step of [...TRIGGERS, ...NO_REGRESSION_JOB]) expect([step, holdVia(step)]).toEqual([step, 'job'])
  for (const step of [...KNOWN_LIMITS, ...NO_REGRESSION_USER]) expect([step, holdVia(step)]).toEqual([step, 'user'])
  for (const step of NO_REGRESSION_FREE) expect([step, holdVia(step)]).toEqual([step, 'free'])
  // The AD2 kit wording names no person: held on the timer's job; its `reply to the user` twin is free, as on 0.1.1b.
  expect(holdVia('On the timer notification, reply with one line acknowledging it')).toBe('job')
  expect(holdVia('On the timer notification, reply to the user')).toBe('free')
  // A step that needs the user after the job too is held on the user.
  expect(holdVia('after CI finishes, deploy — gated: ask user: deploy')).toBe('user')
})

test('rule (a), the known limit of 0.1.1: a wait on a job reads held on the user, as on 0.1.1b; its result turn reads hard-blocked', () => {
  expect(KNOWN_LIMITS.length).toBeGreaterThanOrEqual(40)
  for (const step of KNOWN_LIMITS) {
    expect([step, OLD_HELD_RE.test(`1. ${step} · todo`), holdVia(step)]).toEqual([step, true, 'user'])
    const f = laneFacts('## Resume here\n' + onJob(step))
    expect([step, laneOf(f, { ...M, running: 1 }).lane, laneOf(f, { ...M, result: true }).lane]).toEqual([step, 'soft-blocked', 'hard-blocked'])
  }
  // The AD2 wording and its `Wait for` twin read apart: only the leading trigger is a job hold.
  const on = laneFacts('## Resume here\n' + onJob('On the timer notification, reply with one line'))
  const wait = laneFacts('## Resume here\n' + onJob('Wait for the timer notification, then reply with one line'))
  expect([on.onJob, on.onUser, wait.onJob, wait.onUser]).toEqual([1, 1, 0, 2])
  expect([laneOf(on, { ...M, result: true }).lane, laneOf(wait, { ...M, result: true }).lane]).toEqual(['working', 'hard-blocked'])
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

// The AD2 kit wording; its `Wait for` twin is the known limit of 0.1.1 (the test after this one).
for (const step of ['On the timer notification, reply with one line acknowledging it']) {
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

test('rule (b), the known limit of 0.1.1: with `Wait for the timer notification, then reply`, the result turn already reads hard-blocked ([idle-done]); no digest turn follows at its end', async ($, on) => {
  const w = new World().install(on)
  await ad2($, w, 'Wait for the timer notification, then reply with one line')
  if (!HAS) return
  const t = await resultTurn($, w, notif('b7'))
  expect(t.block ?? '').toContain(head(w, 'idle-done') ?? '')
  expect(t.block ?? '').toContain('code reads the work lane as hard-blocked')
  await w.turnEnd($)
  await w.advance(5000)
  expect(w.submits).toEqual([])
})

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

// ---- idle_digest off (owner rule (c), 2026-10-28: the away digest ships on only after a live
// PASS, else off; the default of 0.1.1). No digest turn is submitted, and no text asks for the
// full digest: a finished or blocked lane still starts nothing and gets one line on its state with
// the code-rendered Basis, then Needs you or Nothing needed from you.

/** The full digest's section names and its request, none of which an `off` text may carry. */
const FULL_DIGEST = ['away digest', 'Done (', 'Done;', 'Left (', 'Running;', 'Decided without you']
const ENDING = 'Needs you (numbered, each with what it blocks) or Nothing needed from you'
function noDigest(text: string): void {
  for (const words of FULL_DIGEST) expect([words, text.includes(words)]).toEqual([words, false])
}
const OFF = { options: { idle_digest: 'off' } }

test('off: the [idle-done-off] and [idle-off] lines ask for the one-line form, never the digest; [idle-done] and [idle] are unchanged', () => {
  const RTB = { ...RT, lane: 'hard-blocked', lane_basis: 'B0' }
  const plain = assemble('p', 'resume-context', ['prod-forbid'], RTB).split('\n')
  const added = (tag: Tag) => assemble('p', 'resume-context', ['prod-forbid', tag], RTB).split('\n').filter(l => !plain.includes(l)).join('\n')
  expect(hasTag('resume-context', 'idle-done-off')).toBe(true)
  expect(hasTag('resume-context', 'idle-off')).toBe(true)
  const doneOff = added('idle-done-off')
  noDigest(doneOff)
  expect(doneOff).toContain('Else start nothing; say in one line that the lane is hard-blocked (Basis: B0, by code, as is), then last, ' + ENDING + '.')
  expect(doneOff).toContain("The user's own message opened this turn: that line first, then answer them, Needs you last.")
  // The rest of the line is [idle-done]'s: a new request or an unblocking result works again.
  expect(doneOff).toContain('the lane is working again; handle it, then continue Step 1 unless it needs the user or hits a gate (step 4)')
  const idleOff = added('idle-off')
  noDigest(idleOff)
  expect(idleOff).toContain('Step 5 finds none left, or all left waits on the user: instead, start nothing; say in one line the lane state (Basis: B0, by code, as is), then last, Needs you')
  expect(idleOff).toContain('Nothing needed from you. Then stop; later turns say what changed in one line.')
  expect(idleOff).toContain('handle it, then continue Step 1 unless it needs the user or hits an explicit gate (step 4)')
  // submit and return keep their texts.
  expect(added('idle-done')).toContain('Else start nothing and print the away digest (step 6 allows it)')
  expect(added('idle')).toContain('instead, print the away digest (step 6 allows it)')
  // Never two idle lines in one block.
  expect(added('idle-done-off')).not.toContain(added('idle-done'))
})

test('off: laneNote and resultDigestLine give the one-line form; submit\'s texts are unchanged', () => {
  const r = laneOf({ ...F, status: 'hard-blocked' }, M)
  for (const again of [false, true]) {
    const note = laneNote('p', r, 'B1', again, true)
    noDigest(note)
    expect(note).toContain('Else start nothing: say in one line that the lane is now hard-blocked (Basis: B1), then last, ' + ENDING + '.')
    expect(note).toContain('A result that unblocks a step makes it working again')
  }
  const line = resultDigestLine('p', r, 'B2', true)
  noDigest(line)
  expect(line.endsWith('Else start nothing: say in one line that the lane is now hard-blocked (Basis: B2), then last, ' + ENDING + '.')).toBe(true)
  expect(laneNote('p', r, 'B1')).toContain('Else start nothing and print the away digest: the lane state and why; Basis: B1 (by code, as is); Done')
  expect(laneNote('p', r, 'B1', true)).toContain('Else start nothing; the away digest went out already: say in one line that the lane is now hard-blocked (Basis: B1)')
  expect(resultDigestLine('p', r, 'B2')).toContain('Else start nothing and print the away digest')
})

kitTest('off (the shipped default): a finished lane, nothing running: no digest turn (digest_submit skipped:off); the person\'s return gets [idle-done-off], one line, no digest', async ($, on) => {
  const w = new World().install(on)
  w.resumeHere = FINISHED
  await w.start($)
  await idleCompaction($, w)
  await w.advance(60 * 1000)
  expect(w.submits).toEqual([])
  expect(hasTag('resume-context', 'idle-done-off')).toBe(true)
  expect(w.rowsOf('digest_submit').map(r => [r.lane, r.result])).toEqual([['finished', 'skipped:off']])
  await w.userTurn($, 'back')
  const block = blockOf(w, await $.prompt.context({ blocks: [] })) ?? ''
  expect(block).toContain('code reads the work lane as finished')
  expect(block).toContain('Else start nothing; say in one line that the lane is finished (Basis: ')
  expect(block).toContain(ENDING)
  expect(block).toContain("The user's own message opened this turn: that line first")
  noDigest(block)
})

test('off: hard-blocked with an agent running: no digest turn; the result turns get [idle-done-off] and then the one-line note, never the digest', OFF, async ($, on) => {
  const w = new World().install(on)
  w.resumeHere = HARD
  w.agents = [{ id: 'a1', status: 'running' }, { id: 'a2', status: 'running' }]
  await w.start($)
  await idleCompaction($, w)
  await w.advance(5000)
  expect(w.submits).toEqual([])
  expect(hasTag('resume-context', 'idle-done-off')).toBe(true)
  expect(w.rowsOf('digest_submit').map(r => [r.lane, r.result])).toEqual([['soft-blocked', 'skipped:off']])
  w.agents = [{ id: 'a1', status: 'completed' }, { id: 'a2', status: 'running' }]
  const first = await resultTurn($, w, 'Agent a1 finished.')
  expect(first.block ?? '').toContain('code reads the work lane as soft-blocked')
  expect(first.block ?? '').toContain('Else start nothing; say in one line that the lane is soft-blocked (Basis: ')
  noDigest(first.block ?? '')
  await w.turnEnd($)
  w.agents = [{ id: 'a1', status: 'completed' }, { id: 'a2', status: 'completed' }]
  const note = await resultTurn($, w, 'Agent a2 finished.')
  expect(note.ctx).toContain('code reads the work lane as hard-blocked')
  expect(note.ctx).toContain('Else start nothing: say in one line that the lane is now hard-blocked (Basis: ')
  expect(note.ctx).toContain(ENDING)
  noDigest(note.ctx)
  await w.turnEnd($)
  await w.advance(5000)
  expect(w.submits).toEqual([])
})

test('off: a working lane\'s result turn gets [idle-off] (its step 5 asks for the one line); rule (b) at its end submits no digest turn (skipped:off); the next turn gets the one-line note', OFF, async ($, on) => {
  const w = new World().install(on)
  await ad2($, w, 'On the timer notification, reply with one line acknowledging it')
  expect(hasTag('resume-context', 'idle-off')).toBe(true)
  expect(w.rowsOf('digest_submit').map(r => [r.lane, r.result])).toEqual([['soft-blocked', 'skipped:off']])
  const t = await resultTurn($, w, notif('b7'))
  const block = t.block ?? ''
  expect(block).toContain('Step 5 finds none left, or all left waits on the user: instead, start nothing; say in one line the lane state (Basis: ')
  noDigest(block)
  await w.turnEnd($, 'The timer ended; nothing new started.')
  await w.advance(5000)
  expect(w.submits).toEqual([])
  expect(w.rowsOf('digest_submit').map(r => [r.lane, r.result])).toEqual([['soft-blocked', 'skipped:off'], ['hard-blocked', 'skipped:off']])
  const cron = await resultTurn($, w, 'A scheduled check ran.')
  expect(cron.ctx).toContain('Else start nothing: say in one line that the lane is now hard-blocked (Basis: ')
  noDigest(cron.ctx)
  await w.turnEnd($)
  await w.advance(5000)
  expect(w.submits).toEqual([])
})

// The one-line answers of `off`: DIGEST_END_RE (every setting, as on base) never takes them; OFF_LINE_END_RE (off only) does.
const ONE_LINE = ['Lane hard-blocked (Basis: 0 of 2 listed steps marked done). ✅ Nothing needed from you', 'Lane finished (Basis: b). Nothing needed from you.\nmore',
  'Lane finished. Nothing needed from you**', 'Ran the step; the lane is finished. Nothing needed from you.',
  'Lane hard-blocked (Basis: 0 of 2 listed steps marked done). Needs you: 1. approve the push (blocks the release).',
  'Lane hard-blocked. **Needs you:** 1) approve the push']
const NEITHER = ['The timer ended; nothing new started.', 'If nothing needed from you was said, ask.', 'This needs you to approve the push.',
  'Lane finished; Nothing needed from you yet, but the push waits.', 'say Nothing needed from you or not', 'Lane: Needs you later; step 21. waits',
  'Lane hard-blocked; it needs you\n1. approve']

test('DIGEST_END_RE (every setting, the base pattern): Needs you or Nothing needed from you opening a line only', () => {
  for (const s of ['Needs you:\n1. Approve the push.', 'x\n**Needs you:**\n1. y', '✅ Nothing needed from you', 'x\n- Nothing needed from you.'])
    expect([s, DIGEST_END_RE.test(s)]).toEqual([s, true])
  for (const s of [...ONE_LINE, ...NEITHER]) expect([s, DIGEST_END_RE.test(s)]).toEqual([s, false])
})

test('OFF_LINE_END_RE (idle_digest off only): Nothing needed from you closing a line, or Needs you with its 1. on the same line', () => {
  for (const s of ONE_LINE) expect([s, OFF_LINE_END_RE.test(s)]).toEqual([s, true])
  for (const s of NEITHER) expect([s, OFF_LINE_END_RE.test(s)]).toEqual([s, false])
})

test('rule (b) under submit: an answer whose line ends with Nothing needed from you is no digest; the digest turn still goes out', async ($, on) => {
  const w = new World().install(on)
  await ad2($, w, 'On the timer notification, reply with one line acknowledging it')
  expect(HAS).toBe(true)
  await resultTurn($, w, notif('b7'))
  await w.turnEnd($, 'Ran the step; the lane is finished. Nothing needed from you.')
  await w.advance(5000)
  expect(w.submits.length).toBe(1)
  expect(w.submits[0] ?? '').toContain('print the away digest')
  expect(w.rowsOf('digest_submit').map(r => [r.lane, r.result])).toEqual([['soft-blocked', 'skipped:running'], ['hard-blocked', 'submitted']])
})

test('rule (b) under return: an answer whose line ends with Nothing needed from you is no digest; the next background turn gets the full-digest note', { options: { idle_digest: 'return' } }, async ($, on) => {
  const w = new World().install(on)
  await ad2($, w, 'On the timer notification, reply with one line acknowledging it')
  expect(HAS).toBe(true)
  await resultTurn($, w, notif('b7'))
  await w.turnEnd($, 'Ran the step; the lane is finished. Nothing needed from you.')
  await w.advance(5000)
  expect(w.submits).toEqual([])
  const cron = await resultTurn($, w, 'A scheduled check ran.')
  expect(cron.ctx).toContain('Else start nothing and print the away digest')
})

test('off: a hard-blocked one-line answer with its Needs you list on the same line: the lane counts as told; no note on the next turn', OFF, async ($, on) => {
  const w = new World().install(on)
  await ad2($, w, 'On the timer notification, reply with one line acknowledging it')
  expect(hasTag('resume-context', 'idle-off')).toBe(true)
  await resultTurn($, w, notif('b7'))
  await w.turnEnd($, 'Lane hard-blocked (Basis: 0 of 2 listed steps marked done). Needs you: 1. approve the push (blocks the release).')
  await w.advance(5000)
  expect(w.submits).toEqual([])
  expect(w.rowsOf('digest_submit').map(r => [r.lane, r.result])).toEqual([['soft-blocked', 'skipped:off']])
  expect((await resultTurn($, w, 'A scheduled check ran.')).ctx).toBe('')
})

test('off: the result turn\'s answer gives the one line with Nothing needed from you at its end: no row, no note on the next turn', OFF, async ($, on) => {
  const w = new World().install(on)
  await ad2($, w, 'On the timer notification, reply with one line acknowledging it')
  expect(hasTag('resume-context', 'idle-off')).toBe(true)
  await resultTurn($, w, notif('b7'))
  await w.turnEnd($, 'Lane hard-blocked (Basis: 0 of 2 listed steps marked done). ✅ Nothing needed from you')
  await w.advance(5000)
  expect(w.submits).toEqual([])
  expect(w.rowsOf('digest_submit').map(r => [r.lane, r.result])).toEqual([['soft-blocked', 'skipped:off']])
  expect(w.rowsOf('lane_outcome').map(r => [r.lane, r.at]).slice(-1)).toEqual([['hard-blocked', 'recheck']])
  // The lane was told in that line: a later turn not of a person's gets no note repeating it.
  expect((await resultTurn($, w, 'A scheduled check ran.')).ctx).toBe('')
  await w.turnEnd($)
  await w.advance(5000)
  expect(w.submits).toEqual([])
})
