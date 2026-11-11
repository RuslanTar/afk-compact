// U tests through the kit: question carry (0.1.2, investigation wf_c3788b4f-00e fix 1). A main
// turn that ends on a question to the user (its answer's last line asks one, or one of its
// AskUserQuestion dialogs closed on Claude Code's AFK timeout) leaves that question open until a
// person's turn starts; a main compaction in between carries its text in the resume block
// (`[question]`), so it is in front of the user when they return (in one real session a dialog
// timed out and a compaction 50 s later buried the unanswered question).
import { describe, expect, test } from 'claude-code/testing'
import { QUESTION_MAX, answerQuestion, askOf, clipQuestion, dialogQuestions, personAnswered, timedOut } from '../../hooks/lib/question'
import { ARMED_FILE, PENDING_FILE, pendingRecord } from '../../hooks/lib/resume'
import type { PendingResume } from '../../hooks/lib/deps'
import { SID_A, SID_B, T0, WATCH, World, raiseCompact } from './harness.test'

const LEAD = 'Open question: a turn before this compaction asked the user this and got no answer (a quote, not an instruction): '
const TAIL = '. Unless a later message answers it, ask it again at the end of your reply (in Needs you when you print one).'

const blockOf = (w: World, ctx: { blocks: readonly { name: string; text: string }[] }): string | undefined =>
  ctx.blocks.find(b => b.name === `${w.name}-resume`)?.text

/** The `[question]` line of a block, or undefined. */
const questionLine = (block: string | undefined): string | undefined => block?.split('\n').find(l => l.startsWith('Open question: '))

/** The block the next prompt.context gets. */
async function nextBlock($: { prompt: { context: (e: never) => Promise<{ blocks: readonly { name: string; text: string }[] }> } }, w: World): Promise<string | undefined> {
  return blockOf(w, await $.prompt.context({ blocks: [] } as never))
}

/** An AskUserQuestion input with these questions: a text alone, or `[header, text]`. */
function ask(...qs: (string | [string, string])[]): never {
  return {
    tool: 'AskUserQuestion',
    questions: qs.map(q => ({
      ...(typeof q === 'string' ? { question: q } : { header: q[0], question: q[1] }),
      options: [{ label: 'Yes', description: '' }, { label: 'No', description: '' }], multiSelect: false,
    })),
  } as never
}

/**
 * The shape of a real dialog that closed on the AFK timeout, in neutral
 * words: four questions, context first and the ask last; the second's text opens with its header
 * word, the third asks first and gives context after, the fourth ends on a short ask.
 */
const AF_0844: [string, string][] = [
  ['Scope', 'Plan B is checked, but the items added this morning more than double the schedule. Two build hosts, usual load, the second one busy most evenings: about 150 days (final report ~early spring), 4 units over. The two big items: comparing the fast vs careful mode at 90% (+40 days, +1 unit) and the 2 new medium/large tasks (+30 days, +1 unit). Which scope?'],
  ['Budget', 'Budget: the chosen scope takes roughly 6 units a week (the same rate across the shared pool) for its whole run. You earlier accepted about 4 units a week. Approve, with a weekly usage alarm that pauses new runs if exceeded?'],
  ['Host', 'How often is the second build host busy with other work? This decides how much it helps: busy most evenings, it saves about 12 days; busy on about 30% of days, about 45 days.'],
  ['Config fix', "The project's build config lost all 16 values (paths, cache dirs, retry limits) to '<blank>' placeholders in an earlier restore by another job. A script copies just that block back from last week's backup, keeping a copy of the current file first. Run it?"],
]
const AF_0844_ASKS = 'Scope: Which scope? / Budget: Approve, with a weekly usage alarm that pauses new runs if exceeded? / Host: How often is the second build host busy with other work? / Config fix: Run it?'

/** The bottom answers every AskUserQuestion: auto-resolved on the AFK timeout, or by a person. */
function dialogs(w: World, how: 'timeout' | 'answered'): void {
  w.toolAnswer = tool => tool !== 'AskUserQuestion' ? { result: {} }
    : { result: { questions: [], answers: how === 'answered' ? { 'Q?': 'Yes' } : {}, ...(how === 'timeout' ? { afkTimeoutMs: 600000 } : {}) } }
}

describe('question carry: the text', () => {
  test('a plain-text question: the last paragraph of an answer whose last non-blank line ends in "?", on one line', () => {
    expect(answerQuestion('Built and tested.\n\nShould I push the branch now?\n\n')).toBe('Should I push the branch now?')
    expect(answerQuestion('Done.\n\n## Needs you\n1. Approve the migration?\n2.  Push   to main?')).toBe('1. Approve the migration? 2. Push to main?')
    expect(answerQuestion('Done. Pushed?\n\nAll green.')).toBeUndefined()
    expect(answerQuestion('')).toBeUndefined()
    expect(answerQuestion('\n  \n')).toBeUndefined()
  })
  test('clipped to QUESTION_MAX: a long answer keeps its end (the question), a dialog its start; control characters go', () => {
    const long = answerQuestion('x'.repeat(500) + '\nwhich one do you want?')
    expect(long?.length).toBe(QUESTION_MAX)
    expect(long?.startsWith('…')).toBe(true)
    expect(long?.endsWith(' which one do you want?')).toBe(true)
    const head = clipQuestion('Which one? ' + 'y'.repeat(500), 'start')
    expect(head.length).toBe(QUESTION_MAX)
    expect(head.startsWith('Which one? ')).toBe(true)
    expect(head.endsWith('…')).toBe(true)
    expect(clipQuestion('a\u0000b\tc\r\nd\u001b[0me?', 'end')).toBe('a b c d [0me?')
    // A surrogate pair is never cut in half.
    const emoji = clipQuestion('🙋'.repeat(300) + '?', 'end')
    expect(emoji.length <= QUESTION_MAX).toBe(true)
    expect(/[\ud800-\udbff](?![\udc00-\udfff])|(?<![\ud800-\udbff])[\udc00-\udfff]/.test(emoji)).toBe(false)
  })
  test('a dialog\'s questions joined with " / "; an AFK-timeout result only', () => {
    expect(dialogQuestions({ questions: [{ question: 'Which DB?' }, { question: 'Ship\nnow?' }] })).toBe('Which DB? / Ship now?')
    expect(dialogQuestions({ questions: [] })).toBeUndefined()
    expect(dialogQuestions({ questions: [{ header: 'x' }, 'no'] })).toBeUndefined()
    expect(dialogQuestions({})).toBeUndefined()
    expect(timedOut({ answers: {}, afkTimeoutMs: 600000 })).toBe(true)
    expect(timedOut({ answers: { 'Q?': 'Yes' } })).toBe(false)
    expect(timedOut(undefined)).toBe(false)
  })
  test('a person answered: no error, not on the AFK timeout, and some answer, typed text or another round', () => {
    expect(personAnswered({ result: { answers: { 'Q?': 'Yes' } } })).toBe(true)
    expect(personAnswered({ result: { answers: {}, response: 'use the second one' } })).toBe(true)
    expect(personAnswered({ result: { answers: {}, followUp: true } })).toBe(true)
    expect(personAnswered({ result: { answers: { 'Q?': 'Yes' }, afkTimeoutMs: 600000 } })).toBe(false)
    expect(personAnswered({ isError: true, result: { answers: { 'Q?': 'Yes' } } })).toBe(false)
    expect(personAnswered({ result: { answers: { 'Q?': '  ' }, response: '' } })).toBe(false)
    expect(personAnswered({ result: {} })).toBe(false)
    expect(personAnswered({ result: 'closed' })).toBe(false)
  })
  test('a dialog question gives its ask: its last sentence ending in "?", else its last sentence', () => {
    expect(askOf('Context first. More (a, b). Which scope?')).toBe('Which scope?')
    expect(askOf('How often is the PC used? This decides how much it helps.')).toBe('How often is the PC used?')
    expect(askOf('Keep the 5 tasks, or add 2–3 more, e.g. medium ones? Claims cover tested tasks only.')).toBe('Keep the 5 tasks, or add 2–3 more, e.g. medium ones?')
    expect(askOf('It ran "fine." Ship it?')).toBe('Ship it?')
    expect(askOf('Some context. Pick the\ndeploy target.')).toBe('Pick the deploy target.')
    expect(askOf('  ')).toBe('')
    // The dot of e.g., i.e., vs. or cf. ends no sentence, before a digit or a dash too; etc. still does.
    expect(askOf('The cap is 120 now. What would a lower one (e.g. 90) do?')).toBe('What would a lower one (e.g. 90) do?')
    expect(askOf('Two flags set it (e.g. --preset 75), which rule picks the plan?')).toBe('Two flags set it (e.g. --preset 75), which rule picks the plan?')
    expect(askOf('Context. Keep A (i.e. 3 hosts) vs. B (cf. Table 2)?')).toBe('Keep A (i.e. 3 hosts) vs. B (cf. Table 2)?')
    expect(askOf('Logs, caches, etc. Which ones go?')).toBe('Which ones go?')
  })
  test('a real timed-out dialog: each question\'s ask after its header, every question kept; over the cap without headers, then clipped', () => {
    expect(dialogQuestions({ questions: AF_0844.map(([header, question]) => ({ header, question })) })).toBe(AF_0844_ASKS)
    // A header the ask starts with is not repeated; a blank one is left out.
    expect(dialogQuestions({ questions: [{ header: 'Merge', question: 'Ready. Merge now?' }, { header: ' ', question: 'Push?' }] })).toBe('Merge now? / Push?')
    const long = Array.from({ length: 6 }, (_, i) => ({ header: `Topic ${i}`, question: `Context ${i}. Should the run number ${i} use the slow lane with its longer cap?` }))
    const out = dialogQuestions({ questions: long }) ?? ''
    expect(out.length).toBe(QUESTION_MAX)
    expect(out.startsWith('Should the run number 0 use the slow lane with its longer cap? / Should the run number 1')).toBe(true)
    expect(out.includes('Topic')).toBe(false)
    expect(out.endsWith('…')).toBe(true)
  })
})

describe('question carry: the flow', () => {
  test('a turn ending on a question, then a compaction: the block carries the question as a quote', async ($, on) => {
    const w = new World().install(on)
    await w.start($)
    await w.userTurn($, 'finish the release')
    await w.turnEnd($, 'Built and tested.\n\nShould I push the branch now?')
    await raiseCompact($, { trigger: 'auto' })
    const b = await nextBlock($, w)
    expect(questionLine(b)).toBe(LEAD + '"Should I push the branch now?"' + TAIL)
    // Placed before the Measured facts, after the protocol.
    expect((b ?? '').indexOf('Open question: ') < (b ?? '').indexOf('Measured facts (')).toBe(true)
    expect((b ?? '').indexOf('6. No recap') < (b ?? '').indexOf('Open question: ')).toBe(true)
  })

  test('a real timed-out dialog: a dialog that closed on the AFK timeout, an answer ending on a Coming up line: every question\'s ask is carried', async ($, on) => {
    const w = new World().install(on)
    dialogs(w, 'timeout')
    await w.start($)
    await w.userTurn($)
    await $.tool.call(ask(...AF_0844))
    await w.turnEnd($, 'Went on with the defaults.\n\n⏳ Coming up: the stage-0 results.')
    await raiseCompact($, { trigger: 'auto' })
    expect(questionLine(await nextBlock($, w))).toBe(LEAD + '"' + AF_0844_ASKS + '"' + TAIL)
  })

  test('a dialog that closed on the AFK timeout, an answer with no question: the dialog\'s questions are carried', async ($, on) => {
    const w = new World().install(on)
    dialogs(w, 'timeout')
    await w.start($)
    await w.userTurn($)
    await $.tool.call(ask('Which database?', 'Ship it today?'))
    await w.turnEnd($, 'No answer came; I went on with Postgres.')
    await raiseCompact($, { trigger: 'auto' })
    expect(questionLine(await nextBlock($, w))).toBe(LEAD + '"Which database? / Ship it today?"' + TAIL)
  })

  test('the plain-text question wins over a timed-out dialog of the same turn (the model asked it again)', async ($, on) => {
    const w = new World().install(on)
    dialogs(w, 'timeout')
    await w.start($)
    await w.userTurn($)
    await $.tool.call(ask('Which database?'))
    await w.turnEnd($, 'The dialog timed out.\n\nWhich database should I use, Postgres or MySQL?')
    await raiseCompact($, { trigger: 'auto' })
    expect(questionLine(await nextBlock($, w))).toBe(LEAD + '"Which database should I use, Postgres or MySQL?"' + TAIL)
  })

  test('nothing open: an answered dialog, a turn with no question, an aborted turn: no [question] line', async ($, on) => {
    const w = new World().install(on)
    dialogs(w, 'answered')
    await w.start($)
    await w.userTurn($)
    await $.tool.call(ask('Which database?'))
    await w.turnEnd($, 'Postgres it is. Done.')
    await raiseCompact($, { trigger: 'auto' })
    expect(questionLine(await nextBlock($, w))).toBeUndefined()
    await w.userTurn($)
    await w.turnEnd($, 'Should I go on?', 'aborted')
    await raiseCompact($, { trigger: 'auto' })
    const b = await nextBlock($, w)
    expect(b).toBeDefined()
    expect(questionLine(b)).toBeUndefined()
  })

  test('a background result\'s turn keeps the question open; a person\'s turn closes it', async ($, on) => {
    const w = new World().install(on)
    await w.start($)
    await w.userTurn($)
    await w.turnEnd($, 'Ready.\n\nMerge it?')
    await w.userTurn($, 'background result', 'task-notification')
    await w.turnEnd($, 'The tests passed.')
    await raiseCompact($, { trigger: 'auto' })
    expect(questionLine(await nextBlock($, w))).toBe(LEAD + '"Merge it?"' + TAIL)
    // Still open at a second compaction before the person is back.
    await raiseCompact($, { trigger: 'auto' })
    expect(questionLine(await nextBlock($, w))).toBe(LEAD + '"Merge it?"' + TAIL)
    await w.userTurn($, 'yes, merge')
    await w.turnEnd($, 'Merged.')
    await raiseCompact($, { trigger: 'auto' })
    expect(questionLine(await nextBlock($, w))).toBeUndefined()
  })

  test('a compaction inside the person\'s next turn carries nothing; a later question replaces an earlier one', async ($, on) => {
    const w = new World().install(on)
    await w.start($)
    await w.userTurn($)
    await w.turnEnd($, 'Merge it?')
    await w.userTurn($, 'not yet')
    await raiseCompact($, { trigger: 'auto' })
    expect(questionLine(await nextBlock($, w))).toBeUndefined()
    await w.turnEnd($, 'Fine.\n\nShall I rebase first?')
    await w.userTurn($, 'background result', 'task-notification')
    await w.turnEnd($, 'Then: deploy to staging?')
    await raiseCompact($, { trigger: 'auto' })
    expect(questionLine(await nextBlock($, w))).toBe(LEAD + '"Then: deploy to staging?"' + TAIL)
  })

  test('a /clear drops the open question: the next conversation\'s block has none', async ($, on) => {
    const w = new World().install(on)
    await w.start($)
    await w.userTurn($)
    await w.turnEnd($, 'Merge it?')
    await $.session.end({ reason: 'clear', sessionId: SID_A, resume: { id: SID_A } } as never)
    w.sid = SID_B
    await raiseCompact($, { trigger: 'auto' })
    const b = await nextBlock($, w)
    expect(b).toBeDefined()
    expect(questionLine(b)).toBeUndefined()
  })

  test('a dialog times out, then a mid-turn compaction in the same turn: the dialog is carried, newer than an open question', async ($, on) => {
    const w = new World().install(on)
    dialogs(w, 'timeout')
    await w.start($)
    await w.userTurn($)
    await $.tool.call(ask('Which database?'))
    await raiseCompact($, { trigger: 'auto' })
    expect(questionLine(await nextBlock($, w))).toBe(LEAD + '"Which database?"' + TAIL)
    await w.turnEnd($, 'Went on with Postgres.')
    // An earlier question open, then a background result's turn whose dialog times out.
    await w.userTurn($)
    await w.turnEnd($, 'Merge it?')
    await w.userTurn($, 'background result', 'task-notification')
    await raiseCompact($, { trigger: 'auto' })
    expect(questionLine(await nextBlock($, w))).toBe(LEAD + '"Merge it?"' + TAIL)
    await $.tool.call(ask('Ship it today?'))
    await raiseCompact($, { trigger: 'auto' })
    expect(questionLine(await nextBlock($, w))).toBe(LEAD + '"Ship it today?"' + TAIL)
    // The turn ends with no question: the dialog is the open question from then on.
    await w.turnEnd($, 'The tests passed.')
    await raiseCompact($, { trigger: 'auto' })
    expect(questionLine(await nextBlock($, w))).toBe(LEAD + '"Ship it today?"' + TAIL)
  })

  test('a person answering a dialog in a background result\'s turn closes an earlier open question', async ($, on) => {
    const w = new World().install(on)
    dialogs(w, 'answered')
    await w.start($)
    await w.userTurn($)
    await w.turnEnd($, 'Merge it?')
    await w.userTurn($, 'background result', 'task-notification')
    await $.tool.call(ask('Merge now?'))
    await w.turnEnd($, 'Merged.')
    await raiseCompact($, { trigger: 'auto' })
    const b = await nextBlock($, w)
    expect(b).toBeDefined()
    expect(questionLine(b)).toBeUndefined()
  })

  test('a dialog that errored or closed with nothing chosen closes no question: no person answered', async ($, on) => {
    const w = new World().install(on)
    await w.start($)
    await w.userTurn($)
    await w.turnEnd($, 'Merge it?')
    await w.userTurn($, 'background result', 'task-notification')
    w.toolAnswer = () => ({ isError: true, result: 'dialog failed', text: 'dialog failed' })
    await $.tool.call(ask('Merge now?'))
    w.toolAnswer = () => ({ result: { questions: [], answers: {} } })
    await $.tool.call(ask('Merge now?'))
    await w.turnEnd($, 'The tests passed.')
    await raiseCompact($, { trigger: 'auto' })
    expect(questionLine(await nextBlock($, w))).toBe(LEAD + '"Merge it?"' + TAIL)
  })

  test('a subagent\'s dialog and question never count', async ($, on) => {
    const w = new World().install(on)
    dialogs(w, 'timeout')
    await w.start($)
    await w.userTurn($)
    await $.tool.call({ ...(ask('Sub asks?') as object), agentId: 'a9a00b3f363327444' } as never)
    await $.turn.complete({ answer: 'Which one?', durationMs: 1, isAborted: false, turnId: 'x', reason: 'answer', agentId: 'a9a00b3f363327444' } as never)
    await w.turnEnd($, 'Done.')
    await raiseCompact($, { trigger: 'auto' })
    expect(questionLine(await nextBlock($, w))).toBeUndefined()
  })
})

describe('question carry: the persisted block', () => {
  const SAVED = '~/.claude/handoffs/r/LAB-42/compact/2026-10-21_14-05-12_5e55a001_c1-ab0c00.md'
  const PENDING = `${WATCH}/${SID_A}/${PENDING_FILE}`
  const ARMED = `${WATCH}/${SID_A}/${ARMED_FILE}`

  function seeded(question: unknown): string {
    const nonce = 'ab0c0001'
    const p: PendingResume = {
      sid: SID_A, nonce, block: 'STORED', builtAt: T0 - 60000, measuredAt: T0 - 60000, resumePref: 'prompt.context', turnSeq: 3,
      args: { nonce, midturn: false, nonok: false, savedCopy: SAVED, prodAllow: false },
      remeasure: 'Git: main @ 1a1a1a1, 0 modified, 0 untracked', outcome: { nudged: false, continued: false, halt: false },
    }
    const j = pendingRecord(p, 'f0e1d2c3') as unknown as { args: Record<string, unknown> }
    return JSON.stringify({ ...j, args: { ...j.args, question } }) + '\n'
  }

  test('the record keeps the question; a restored block carries it, clipped again; a question not a string: no block', async ($, on) => {
    const w = new World().install(on)
    await w.start($)
    await w.userTurn($)
    await w.turnEnd($, 'Merge it?')
    await raiseCompact($, { trigger: 'auto' })
    const rec = JSON.parse(w.files.get(PENDING) ?? '{}') as { args?: { question?: string } }
    expect(rec.args?.question).toBe('Merge it?')
    await $.session.end({ reason: 'prompt_input_exit', sessionId: SID_A, resume: { id: SID_A } } as never)
    w.files.set(ARMED, seeded('Ship\n' + 'z'.repeat(400) + '?'))
    const b = await nextBlock($, w)
    const line = questionLine(b) ?? ''
    expect(line.startsWith(LEAD + '"…')).toBe(true)
    expect(line.endsWith('z?"' + TAIL)).toBe(true)
    expect(line.length).toBe(LEAD.length + QUESTION_MAX + 2 + TAIL.length)
  })

  test('a restored record whose question is not a string is not taken (the record check, not a throw)', async ($, on) => {
    const w = new World().install(on)
    await w.start($)
    w.files.set(ARMED, seeded(42))
    // Nothing throws on the way (restorePending drops a question that is not a string): without
    // the record check this record would restore, as the one with a string question above does.
    expect(await nextBlock($, w)).toBeUndefined()
  })
})
