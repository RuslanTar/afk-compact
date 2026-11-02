// U tests through the kit: the 0.1.3 resume-text lane.
// A (owner 2026-10-30 07:52: "it's not clear if the compaction went well, as there are literally no
// messages after compaction"; usage review: median 5 tool calls before the first visible line): a
// main block opens with one code-rendered first line, `Resumed · step 1: <the summary's Step 1>`,
// else the fixed `Resumed after compaction`; never beside the handoff ack (its own one line) or the
// block again on a person's return. Subagents get no block.
// B (usage review: 38 of 72 questions after a resume timed out at 600 s, 9 asked again in a dialog
// right after): step 6 says a timed-out question is not asked again in a dialog before the
// person's next own message, and a carried question whose dialog code saw time out gets
// `[question-timeout]`.
import { describe, expect, test } from 'claude-code/testing'
import { assembleText, hasTag } from '../../hooks/lib/assemble'
import { assetText } from '../../hooks/lib/assets.gen'
import type { PendingResume } from '../../hooks/lib/deps'
import { ARMED_FILE, PENDING_FILE, RESUMED_FALLBACK, STEP1_MAX, clipStep1, pendingRecord, resumeLine, step1Of } from '../../hooks/lib/resume'
import { SID_A, T0, WATCH, World, raiseCompact } from './harness.test'

const RESUMED = hasTag('resume-context', 'resumed')
const TIMEOUT = hasTag('resume-context', 'question-timeout')
/** The `[resumed]` line's start and the text after its quoted line. */
const LEAD = 'Main session: your first line, before any tool call, is exactly "'
const TAIL = '" (no recap); any other first line asked below comes after it.'
const STEP6 = "A question whose dialog timed out or came back empty: no dialog again before the person's next own message; list it last."
const TIMED = "A question dialog timed out since the person last wrote: step 6 applies (text only, no dialog)."

type Ctx = { blocks: readonly { name: string; text: string }[] }
const blockOf = (w: World, ctx: Ctx): string | undefined => ctx.blocks.find(b => b.name === `${w.name}-resume`)?.text
async function nextBlock($: { prompt: { context: (e: never) => Promise<Ctx> } }, w: World): Promise<string | undefined> {
  return blockOf(w, await $.prompt.context({ blocks: [] } as never))
}
/** The block's `[resumed]` line, or undefined. */
const resumedLine = (block: string | undefined): string | undefined => block?.split('\n').find(l => l.startsWith(LEAD))
const lineFor = (shown: string): string => LEAD + shown + TAIL

function ask(q: string): never {
  return { tool: 'AskUserQuestion', questions: [{ question: q, options: [{ label: 'Yes', description: '' }], multiSelect: false }] } as never
}
function dialogs(w: World, how: 'timeout' | 'answered'): void {
  w.toolAnswer = tool => tool !== 'AskUserQuestion' ? { result: {} }
    : { result: { questions: [], answers: how === 'answered' ? { 'Q?': 'Yes' } : {}, ...(how === 'timeout' ? { afkTimeoutMs: 600000 } : {}) } }
}

describe('resume line (A): Step 1 as code reads it', () => {
  test('the first `Step 1:` line of `## Resume here`, without its `— for "<request>"` tail, on one line', () => {
    expect(step1Of('## Resume here\nStatus: working\nStep 1: `npm test` — for "fix the build"\nGate: none\n')).toBe('`npm test`')
    expect(step1Of('## Resume here\nStep 1:   run   the\ttests \n## Next steps: 1. Step 1: not this · todo')).toBe('run the tests')
    // A Step 1 line elsewhere is not taken; without the section none is (review of the first build: a
    // summary not in handoff form may quote a plan's Step 1 that is not the resume step).
    expect(step1Of('## Resume here\nStatus: working\n## Next steps\nStep 1: later')).toBeUndefined()
    expect(step1Of('Summary:\nStep 1: `git status`\n')).toBeUndefined()
    // The template's other tail, `— proposed…` or `| proposed`, is cut too (real copy xxxxxxxx c1).
    expect(step1Of('## Resume here\nStep 1: `catchup.py answers` — proposed: read the answers; if none, wait\n')).toBe('`catchup.py answers`')
    expect(step1Of('## Resume here\nStep 1: `make lint` | proposed\n')).toBe('`make lint`')
    expect(step1Of('## Resume here\nStep 1:\nGate: none')).toBeUndefined()
    expect(step1Of('no step here')).toBeUndefined()
  })

  test('a long Step 1 keeps its start within STEP1_MAX, `…` after it; the line names it, else the fixed form', () => {
    const s = step1Of('## Resume here\nStep 1: ' + 'x'.repeat(300) + '\n') ?? ''
    expect(s.length).toBe(STEP1_MAX)
    expect(s.endsWith('…')).toBe(true)
    expect(resumeLine('`npm test`')).toBe('Resumed · step 1: `npm test`')
    expect(resumeLine(undefined)).toBe(RESUMED_FALLBACK)
    expect(resumeLine('')).toBe('Resumed after compaction')
  })

  test('a cut Step 1 ends at a word when that keeps 60 chars, else mid-word; an open backtick is closed (review of the first build)', () => {
    const path = '`tail -c 600 /srv/u/claude/projects/-srv-u-projects-meta/00000000-0000-4000-8000-000000000000/subagents/agent-a1b2c3d4.jsonl`'
    const cut = clipStep1(path)
    expect(cut).toBe(path.slice(0, STEP1_MAX - 2) + '`…')
    expect(cut.length).toBe(STEP1_MAX)
    const words = 'when the round 3 workflow notifies, read its journal and report the verdicts of every reviewer to the user in one table'
    const w = clipStep1(words)
    expect(w).toBe('when the round 3 workflow notifies, read its journal and report the verdicts of every reviewer to…')
    expect(w.length <= STEP1_MAX).toBe(true)
    // A word cut inside backticks closes them before the `…`.
    const mixed = clipStep1('when b3 is green: `git -C repo push origin feat/x # intentional push`, then tell the user it is pushed and done')
    expect(mixed).toBe('when b3 is green: `git -C repo push origin feat/x # intentional push`, then tell the user it is…')
    const inside = clipStep1('run `' + 'aaaa '.repeat(30) + '`')
    expect(inside.endsWith('`…')).toBe(true)
    expect(inside.length <= STEP1_MAX).toBe(true)
    expect((inside.split('`').length - 1) % 2).toBe(0)
    // A text that fits is whole, on one line.
    expect(clipStep1('`npm   test`\n')).toBe('`npm test`')
  })

  test('the asset: [resumed] sits before step 1, so it is read first; without the tag no such line', () => {
    if (!RESUMED) return
    const s = assembleText(assetText('resume-context', 'afk-compact'), ['resumed', 'prod-forbid'], { resume_line: 'Resumed · step 1: `x`' })
    const lines = s.split('\n')
    const at = lines.indexOf(lineFor('Resumed · step 1: `x`'))
    expect(at > 0 && at < lines.findIndex(l => l.startsWith('1. Reconcile'))).toBe(true)
    expect(resumedLine(assembleText(assetText('resume-context', 'afk-compact'), ['prod-forbid'], {}))).toBeUndefined()
  })
})

/** An armed record of SID_A (a `claude --resume` before its next turn) whose args carry this step1. */
function seeded(step1: unknown): string {
  const nonce = 'ab0c0002'
  const p: PendingResume = {
    sid: SID_A, nonce, block: 'STORED', builtAt: T0 - 60000, measuredAt: T0 - 60000, resumePref: 'prompt.context', turnSeq: 3,
    args: { nonce, midturn: false, nonok: false, savedCopy: null, notSaved: 'x', prodAllow: false },
    remeasure: 'Git: main @ 1a1a1a1, 0 modified, 0 untracked', outcome: { nudged: false, continued: false, halt: false },
  }
  const j = pendingRecord(p, 'f0e1d2c3') as unknown as { args: Record<string, unknown> }
  return JSON.stringify({ ...j, args: { ...j.args, step1 } }) + '\n'
}

describe('resume line (A): the block', () => {
  test('a summary with a Step 1: the block opens with `Resumed · step 1: <Step 1>`', async ($, on) => {
    const w = new World().install(on)
    w.resumeHere = 'Status: working\nStep 1: `npm test -- lane` — for "fix the lane"\nGate: none\n'
    await w.start($)
    await w.userTurn($)
    await raiseCompact($, { trigger: 'auto' })
    const b = await nextBlock($, w)
    expect(b).toBeDefined()
    expect(resumedLine(b)).toBe(RESUMED ? lineFor('Resumed · step 1: `npm test -- lane`') : undefined)
  })

  test('no Step 1 line, or no summary found: the fixed `Resumed after compaction`', async ($, on) => {
    const w = new World().install(on)
    await w.start($)
    await w.userTurn($)
    await raiseCompact($, { trigger: 'auto' })
    expect(resumedLine(await nextBlock($, w))).toBe(RESUMED ? lineFor('Resumed after compaction') : undefined)
    w.summaryMode = 'missing'
    await raiseCompact($, { trigger: 'auto' })
    const b = await nextBlock($, w)
    expect(b).toBeDefined()
    expect(resumedLine(b)).toBe(RESUMED ? lineFor('Resumed after compaction') : undefined)
  })

  test('a subagent compaction gets no block (subagent behaviour unchanged)', async ($, on) => {
    const w = new World().install(on)
    w.resumeHere = 'Status: working\nStep 1: `npm test`\nGate: none\n'
    await w.start($)
    await w.userTurn($)
    await raiseCompact($, { trigger: 'auto', agentId: 'a9a00b3f363327444' })
    expect(await nextBlock($, w)).toBeUndefined()
  })

  test('a restored record keeps its Step 1 (clipped again)', async ($, on) => {
    const w = new World().install(on)
    w.resumeHere = 'Status: working\nStep 1: `make check`\nGate: none\n'
    await w.start($)
    await w.userTurn($)
    await raiseCompact($, { trigger: 'auto' })
    const rec = JSON.parse(w.files.get(`${WATCH}/${SID_A}/${PENDING_FILE}`) ?? '{}') as { args?: { step1?: string } }
    expect(rec.args?.step1).toBe('`make check`')
    await $.session.end({ reason: 'prompt_input_exit', sessionId: SID_A, resume: { id: SID_A } } as never)
    w.files.set(`${WATCH}/${SID_A}/${ARMED_FILE}`, seeded('long\n' + 'y'.repeat(300)))
    const b = await nextBlock($, w)
    expect(b).toBeDefined()
    if (RESUMED) expect(resumedLine(b)).toBe(lineFor('Resumed · step 1: long ' + 'y'.repeat(STEP1_MAX - 6) + '…'))
  })

  test('a restored record whose Step 1 is not a string is not taken (the record check, not a throw)', async ($, on) => {
    const w = new World().install(on)
    await w.start($)
    w.files.set(`${WATCH}/${SID_A}/${ARMED_FILE}`, seeded(7))
    expect(await nextBlock($, w)).toBeUndefined()
  })

  test('the same record with a string Step 1 is taken (so the refusal above is the record check)', async ($, on) => {
    const w = new World().install(on)
    await w.start($)
    w.files.set(`${WATCH}/${SID_A}/${ARMED_FILE}`, seeded('`ok`'))
    const b = await nextBlock($, w)
    expect(b).toBeDefined()
    if (RESUMED) expect(resumedLine(b)).toBe(lineFor('Resumed · step 1: `ok`'))
  })
})

describe('no re-ask after a timeout (B)', () => {
  test('step 6 carries the no-dialog rule in every block', async ($, on) => {
    const w = new World().install(on)
    await w.start($)
    await w.userTurn($)
    await raiseCompact($, { trigger: 'auto' })
    const b = await nextBlock($, w) ?? ''
    expect(b.split('\n').find(l => l.startsWith('6. '))?.endsWith(' ' + STEP6)).toBe(true)
  })

  test('a dialog that closed on the AFK timeout: [question] with [question-timeout] after it', async ($, on) => {
    const w = new World().install(on)
    dialogs(w, 'timeout')
    await w.start($)
    await w.userTurn($)
    await $.tool.call(ask('Which database?'))
    await w.turnEnd($, 'No answer came; I went on with Postgres.')
    await raiseCompact($, { trigger: 'auto' })
    const lines = (await nextBlock($, w) ?? '').split('\n')
    const q = lines.findIndex(l => l.startsWith('Open question: '))
    expect(q >= 0).toBe(true)
    if (TIMEOUT) expect(lines[q + 1]).toBe(TIMED)
  })

  test('the model asked the timed-out question again in plain text: still [question-timeout] (that turn\'s dialog timed out)', async ($, on) => {
    const w = new World().install(on)
    dialogs(w, 'timeout')
    await w.start($)
    await w.userTurn($)
    await $.tool.call(ask('Which database?'))
    await w.turnEnd($, 'The dialog timed out.\n\nWhich database should I use?')
    await raiseCompact($, { trigger: 'auto' })
    const b = await nextBlock($, w) ?? ''
    expect(b).toContain('"Which database should I use?"')
    if (TIMEOUT) expect(b).toContain(TIMED)
  })

  test('a mid-turn compaction right after the timeout carries the dialog with [question-timeout]', async ($, on) => {
    const w = new World().install(on)
    dialogs(w, 'timeout')
    await w.start($)
    await w.userTurn($)
    await $.tool.call(ask('Ship it today?'))
    await raiseCompact($, { trigger: 'auto' })
    const b = await nextBlock($, w) ?? ''
    expect(b).toContain('"Ship it today?"')
    if (TIMEOUT) expect(b).toContain(TIMED)
  })

  test('no timeout: a plain-text question, or a question after an answered dialog, has no [question-timeout]; a person\'s turn closes both', async ($, on) => {
    const w = new World().install(on)
    await w.start($)
    await w.userTurn($)
    await w.turnEnd($, 'Ready.\n\nMerge it?')
    await raiseCompact($, { trigger: 'auto' })
    let b = await nextBlock($, w) ?? ''
    expect(b).toContain('"Merge it?"')
    expect(b).not.toContain(TIMED)
    dialogs(w, 'answered')
    await w.userTurn($)
    await $.tool.call(ask('Postgres?'))
    await w.turnEnd($, 'Postgres chosen.\n\nShall I deploy?')
    await raiseCompact($, { trigger: 'auto' })
    b = await nextBlock($, w) ?? ''
    expect(b).toContain('"Shall I deploy?"')
    expect(b).not.toContain(TIMED)
    // A timed-out question stays marked through a background result's turn; the person's turn closes it.
    dialogs(w, 'timeout')
    await w.userTurn($)
    await $.tool.call(ask('Rebase first?'))
    await w.turnEnd($, 'Went on.')
    await w.userTurn($, 'background result', 'task-notification')
    await w.turnEnd($, 'The tests passed.')
    await raiseCompact($, { trigger: 'auto' })
    b = await nextBlock($, w) ?? ''
    expect(b).toContain('"Rebase first?"')
    if (TIMEOUT) expect(b).toContain(TIMED)
    await w.userTurn($, 'yes, rebase')
    await w.turnEnd($, 'Rebased.')
    await raiseCompact($, { trigger: 'auto' })
    b = await nextBlock($, w) ?? ''
    expect(b).not.toContain('Open question: ')
    expect(b).not.toContain(TIMED)
  })

  test('the record keeps the mark; a restored block carries it only beside a question', async ($, on) => {
    const w = new World().install(on)
    dialogs(w, 'timeout')
    await w.start($)
    await w.userTurn($)
    await $.tool.call(ask('Which database?'))
    await w.turnEnd($, 'Went on.')
    await raiseCompact($, { trigger: 'auto' })
    const rec = JSON.parse(w.files.get(`${WATCH}/${SID_A}/${PENDING_FILE}`) ?? '{}') as { args?: { question?: string; questionTimedOut?: boolean } }
    expect(rec.args?.question).toBe('Which database?')
    expect(rec.args?.questionTimedOut).toBe(true)
    await $.session.end({ reason: 'prompt_input_exit', sessionId: SID_A, resume: { id: SID_A } } as never)
    const raw = JSON.parse(w.files.get(`${WATCH}/${SID_A}/${PENDING_FILE}`) ?? '{}') as { args: Record<string, unknown>; nonce: string }
    w.files.set(`${WATCH}/${SID_A}/${ARMED_FILE}`, JSON.stringify({ ...raw, args: { ...raw.args, question: '' } }) + '\n')
    const b = await nextBlock($, w) ?? ''
    expect(b).not.toContain('Open question: ')
    expect(b).not.toContain(TIMED)
  })
  // Review of the first build: step 6, [question] and the resume skill's R8 tell the model to list
  // the open question last in a later turn; a turn no person started that does so re-words the
  // question, but nobody has written since the timeout, so the mark stays.
  test('a background turn that lists the timed-out question last keeps [question-timeout]', async ($, on) => {
    const w = new World().install(on)
    dialogs(w, 'timeout')
    await w.start($)
    await w.userTurn($)
    await $.tool.call(ask('Rebase first?'))
    await w.turnEnd($, 'The dialog timed out.\n\nRebase first?')
    await w.userTurn($, 'background result', 'task-notification')
    await w.turnEnd($, 'The tests passed.\n\nNeeds you: rebase first, or merge as is?')
    await raiseCompact($, { trigger: 'auto' })
    const b = await nextBlock($, w) ?? ''
    expect(b).toContain('"Needs you: rebase first, or merge as is?"')
    if (TIMEOUT) expect(b).toContain(TIMED)
  })

  test('a turn no person started that asks it again in text, after a turn that went on, keeps [question-timeout]', async ($, on) => {
    const w = new World().install(on)
    dialogs(w, 'timeout')
    await w.start($)
    await w.userTurn($)
    await $.tool.call(ask('Ship it today?'))
    await w.turnEnd($, 'Went on.')
    await w.userTurn($, 'peer says hi', 'task-notification')
    await w.turnEnd($, 'Noted.\n\nShip it today?')
    await raiseCompact($, { trigger: 'auto' })
    const b = await nextBlock($, w) ?? ''
    expect(b).toContain('"Ship it today?"')
    if (TIMEOUT) expect(b).toContain(TIMED)
  })

  test('two compactions before the person returns: the model obeys [question] in a background turn, the second block still marks it', async ($, on) => {
    const w = new World().install(on)
    dialogs(w, 'timeout')
    await w.start($)
    await w.userTurn($)
    await $.tool.call(ask('Which database?'))
    await w.turnEnd($, 'Went on.')
    await raiseCompact($, { trigger: 'auto' })
    await w.userTurn($, 'background result', 'task-notification')
    const first = await nextBlock($, w) ?? ''
    if (TIMEOUT) expect(first).toContain(TIMED)
    await w.turnEnd($, 'Resumed after compaction\nThe job finished.\n\nWhich database?')
    await raiseCompact($, { trigger: 'auto' })
    const second = await nextBlock($, w) ?? ''
    expect(second).toContain('"Which database?"')
    if (TIMEOUT) expect(second).toContain(TIMED)
  })

  test('the mark ends with the question: after the person writes, or answers a dialog, a new question is not marked', async ($, on) => {
    const w = new World().install(on)
    dialogs(w, 'timeout')
    await w.start($)
    await w.userTurn($)
    await $.tool.call(ask('Rebase first?'))
    await w.turnEnd($, 'Went on.')
    await w.userTurn($, 'merge as is')
    await w.turnEnd($, 'Merged.')
    await w.userTurn($, 'background result', 'task-notification')
    await w.turnEnd($, 'CI is green.\n\nDeploy now?')
    await raiseCompact($, { trigger: 'auto' })
    let b = await nextBlock($, w) ?? ''
    expect(b).toContain('"Deploy now?"')
    expect(b).not.toContain(TIMED)
    // A dialog times out, then an answered dialog closes it; a later turn's question is not marked.
    await w.userTurn($)
    await $.tool.call(ask('Tag the release?'))
    await w.turnEnd($, 'Went on.\n\nTag the release?')
    dialogs(w, 'answered')
    await w.userTurn($, 'background result', 'task-notification')
    await $.tool.call(ask('Tag the release?'))
    await w.turnEnd($, 'Tagged.')
    await w.userTurn($, 'background result', 'task-notification')
    await w.turnEnd($, 'Built.\n\nPublish the notes?')
    await raiseCompact($, { trigger: 'auto' })
    b = await nextBlock($, w) ?? ''
    expect(b).toContain('"Publish the notes?"')
    expect(b).not.toContain(TIMED)
  })
})
