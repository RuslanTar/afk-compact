// Question carry (0.1.2): a main turn that ends on a
// question to the user leaves it open until a person's turn starts (alive.ts), and a main
// compaction in between carries its text in the resume block's `[question]` line (compact.ts,
// resume.ts), so the question is in front of the user when they return. In one real session an
// AskUserQuestion dialog closed on Claude Code's AFK timeout, the model asked again in plain text,
// and the compaction 50 s later buried the unanswered question. The open question is the turn's
// plain-text one (its answer's last line ends in `?`, as `endsWithQuestion` reads it), else the
// questions of a dialog of that turn that closed on the AFK timeout. An answered dialog is not
// open, and a person answering one closes an earlier open question too (they are back). A dialog
// question opens with context and ends on its ask, so each question gives its ask (its last
// sentence, after its header) to the quote. A mid-turn compaction after a timed-out dialog of the
// running turn carries that dialog (`carriedQuestion`). The text is the model's own, on one line
// and clipped, quoted in the block as such.
import type { LoadState } from './deps'

/** The longest question text the resume block carries (UTF-16 units, as the block caps count). */
export const QUESTION_MAX = 240

/** Whitespace runs (line breaks too) and control characters as one space, trimmed. */
export function oneLine(s: string): string {
  return s.replace(/[\s\u0000-\u001f\u007f]+/g, ' ').trim()
}

/**
 * The text on one line within `max` (QUESTION_MAX unless given): `end` keeps its end (an answer's
 * question is its last line) behind `…`, `start` its start (a dialog's first asks) before `…`. A
 * surrogate pair is never cut.
 */
export function clipQuestion(text: string, keep: 'start' | 'end', max = QUESTION_MAX): string {
  const t = oneLine(text)
  if (t.length <= max) return t
  const cps = Array.from(t)
  if (keep === 'end') cps.reverse()
  const out: string[] = []
  let n = 1
  for (const c of cps) {
    if (n + c.length > max) break
    out.push(c)
    n += c.length
  }
  if (keep === 'end') return '…' + out.reverse().join('').trimStart()
  return out.join('').trimEnd() + '…'
}

/**
 * The question an answer ends on: its last paragraph (the non-blank lines before its last
 * non-blank one, up to a blank line or a Markdown heading, which is left out) when that last line
 * ends in `?`, else undefined.
 */
export function answerQuestion(answer: string): string | undefined {
  const lines = answer.split('\n').map(l => l.trim())
  let end = lines.length - 1
  while (end >= 0 && lines[end] === '') end--
  if (end < 0 || !(lines[end] ?? '').endsWith('?')) return undefined
  let start = end
  while (start > 0 && lines[start - 1] !== '' && !/^#{1,6}\s/.test(lines[start - 1] ?? '')) start--
  const q = clipQuestion(lines.slice(start, end + 1).join('\n'), 'end')
  return q === '' ? undefined : q
}

/**
 * A sentence's end before the next one: `.`, `!` or `?` (closing quotes or brackets after it), a
 * space, then no lowercase letter (not "e.g. the"); the dot of `e.g.`, `i.e.`, `vs.` or `cf.` is no
 * end ("(e.g. 90) do?"). `etc.` often ends a sentence, so its dot still does.
 */
const SENTENCE_END = /(?:[!?]|(?<!\b(?:[eE]\.g|[iI]\.e|[vV]s|[cC]f))\.)["'\u201d\u2019)\]]*\s+(?=[^\p{Ll}])/gu

/**
 * A dialog question's ask, on one line: its last sentence that ends in `?` (the text after that
 * `?` is left out), else its last sentence. A dialog question opens with context and ends on the
 * ask (for example "The plan is checked, but … Which scope?").
 */
export function askOf(question: string): string {
  const t = oneLine(question)
  const q = t.lastIndexOf('?')
  const head = q >= 0 ? t.slice(0, q + 1) : t
  let start = 0
  for (const m of head.matchAll(SENTENCE_END)) start = m.index + m[0].length
  return head.slice(start).trim()
}

/**
 * An AskUserQuestion input's asks (`askOf`), each after its header (`Scope: Which scope?`, the
 * header left out when the ask starts with it), joined with ` / `; without the headers when that
 * is over QUESTION_MAX, then clipped at the end. Undefined when it names no question.
 */
export function dialogQuestions(input: unknown): string | undefined {
  const qs = input !== null && typeof input === 'object' ? (input as Record<string, unknown>)['questions'] : undefined
  if (!Array.isArray(qs)) return undefined
  const parts: { header: string; ask: string }[] = []
  for (const q of qs) {
    if (q === null || typeof q !== 'object') continue
    const o = q as Record<string, unknown>
    const text = o['question']
    if (typeof text !== 'string') continue
    const ask = askOf(text)
    if (ask === '') continue
    const h = typeof o['header'] === 'string' ? oneLine(o['header']) : ''
    parts.push({ header: h !== '' && !ask.toLowerCase().startsWith(h.toLowerCase()) ? h : '', ask })
  }
  if (parts.length === 0) return undefined
  const full = parts.map(p => (p.header !== '' ? `${p.header}: ${p.ask}` : p.ask)).join(' / ')
  return full.length <= QUESTION_MAX ? full : clipQuestion(parts.map(p => p.ask).join(' / '), 'start')
}

/** An AskUserQuestion result Claude Code auto-resolved on its AFK timeout (`afkTimeoutMs`): no person answered. */
export function timedOut(result: unknown): boolean {
  return result !== null && typeof result === 'object' && typeof (result as Record<string, unknown>)['afkTimeoutMs'] === 'number'
}

/**
 * An AskUserQuestion call a person answered: not denied, no error, not closed on the AFK timeout
 * (a numeric `afkTimeoutMs`), and some answer, typed text or a request for another round. The one
 * rule for both 0.1.2 uses: only a dialog left unanswered makes the turn one that asks the user
 * (register.ts), and only an answered one closes an open question (`noteDialog`). A dialog that
 * errored or closed with nothing chosen tells nothing about the person.
 */
export function personAnswered(r: { deny?: string; isError?: true; result?: unknown }): boolean {
  if (r.deny !== undefined || r.isError === true || timedOut(r.result)) return false
  const o = r.result
  if (typeof o !== 'object' || o === null) return false
  const v = o as { followUp?: unknown; response?: unknown; answers?: unknown }
  if (v.followUp === true) return true
  if (typeof v.response === 'string' && v.response.trim() !== '') return true
  const a = v.answers
  if (typeof a !== 'object' || a === null) return false
  return Object.values(a).some(x => (typeof x === 'string' ? x.trim() !== '' : x !== undefined && x !== null))
}

/**
 * A main AskUserQuestion call that was not denied: one that closed on the AFK timeout leaves its
 * questions open for this turn's end; one a person answered (`personAnswered`) closes an earlier
 * one of the turn, and the question an earlier turn left open (a person is back, as at their
 * prompt); any other (an error, nothing chosen) changes nothing.
 */
export function noteDialog(s: Pick<LoadState, 'askTimedOut' | 'askPersonSince' | 'openQuestion'>, input: unknown, r: { isError?: true; result?: unknown }): void {
  if (r.isError !== true && timedOut(r.result)) {
    s.askTimedOut = dialogQuestions(input) ?? s.askTimedOut
    // A dialog that timed out after the person typed into this turn is a new timeout.
    s.askPersonSince = false
    return
  }
  if (!personAnswered(r)) return
  s.askTimedOut = undefined
  s.askPersonSince = false
  s.openQuestion = undefined
}

/**
 * 0.1.4: the context line a main AskUserQuestion result that closed on the AFK timeout gets
 * (register.ts `tool.call`), so the no-dialog rule of the resume block's step 6 reaches a session
 * that never compacts too, at the moment Claude Code's own result says the question can be asked
 * again later (0.1.3 usage review: 9 of 38 timed-out questions were asked again in a dialog, in
 * later turns no person started). Undefined for any other result.
 */
export function timeoutNote(name: string, r: { isError?: true; result?: unknown }): string | undefined {
  if (r.isError === true || !timedOut(r.result)) return undefined
  return `Note from the user's ${name} plugin: the dialog timed out: ask it again only in text, at the end of your reply, until the person writes.`
}

/**
 * 0.1.4 (review of the 0.1.3 follow-up: an interjection kept the mark): a person's prompt typed
 * into the running turn. They wrote since the dialog timed out, so a block built in this turn
 * carries the question without `[question-timeout]`, and so does the turn's end; the question
 * stays listed.
 */
export function personTyped(s: Pick<LoadState, 'askTimedOut' | 'askPersonSince' | 'openTimedOut'>): void {
  if (s.askTimedOut !== undefined) s.askPersonSince = true
  s.openTimedOut = false
}

/**
 * Main `turn.complete`: a turn that answered (not aborted: a person pressed Esc) and ended on a
 * question, or with a dialog that timed out, leaves that question open; its plain-text question
 * wins (the model's latest ask). A turn with neither keeps an earlier one open (a background
 * result's turn), which only a person's turn or the session's end closes (alive.ts).
 */
export function turnQuestion(s: Pick<LoadState, 'askTimedOut' | 'askPersonSince' | 'openQuestion' | 'openTimedOut'>, t: { reason: string; answer: string }): void {
  const q = t.reason === 'answer' ? (answerQuestion(t.answer) ?? s.askTimedOut) : undefined
  // 0.1.3 resume-text B: a dialog of this turn closed on the AFK timeout, whichever text is carried
  // (the model often asks the timed-out dialog's question again in plain text). The mark stays while
  // a question is open: a later turn no person started (a task notification, a peer message) that
  // lists it last, as step 6 and `[question]` ask, re-words the question but nobody has answered
  // (review of the first build: 3 of the 6 real compactions after a timeout had such turns).
  // 0.1.4: not when the person typed into this turn after the timeout (`personTyped`).
  const timed = s.askTimedOut !== undefined && !s.askPersonSince
  s.askTimedOut = undefined
  s.askPersonSince = false
  if (q !== undefined) {
    s.openTimedOut = timed || (s.openQuestion !== undefined && s.openTimedOut)
    s.openQuestion = q
  }
}

/**
 * The question a main compaction carries: while the main turn runs, its dialog that closed on the
 * AFK timeout (newer than any earlier turn's question; that turn may compact before it ends), else
 * the question an earlier turn left open.
 */
export function carriedQuestion(s: Pick<LoadState, 'askTimedOut' | 'openQuestion' | 'mainTurnRunning'>): string | undefined {
  return (s.mainTurnRunning ? s.askTimedOut : undefined) ?? s.openQuestion
}

/**
 * 0.1.3 resume-text B (usage review: 38 of 72 questions after a resume timed out at 600 s, and 9
 * were asked again in a dialog right after): a dialog closed on the AFK timeout since the person
 * last wrote, the running turn's or one of a turn that left the question `carriedQuestion` gives
 * open (or an earlier wording of it), so `[question-timeout]` says not to ask it in a dialog again.
 * `openTimedOut` is read only beside an open question: `turnQuestion` sets both together, and
 * whatever clears the question (a person's turn, the session's end, an answered dialog) leaves the
 * flag unread and ends it. 0.1.4: a person's prompt typed into the running turn after the
 * timeout ends the mark too (`personTyped`); the question stays carried.
 */
export function carriedTimedOut(s: Pick<LoadState, 'askTimedOut' | 'askPersonSince' | 'openQuestion' | 'openTimedOut' | 'mainTurnRunning'>): boolean {
  if (s.mainTurnRunning && s.askTimedOut !== undefined) return !s.askPersonSince
  return s.openQuestion !== undefined && s.openTimedOut
}
