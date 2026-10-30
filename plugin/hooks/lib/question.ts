// Question carry (0.1.2; investigation wf_c3788b4f-00e, fix 1): a main turn that ends on a
// question to the user leaves it open until a person's turn starts (alive.ts), and a main
// compaction in between carries its text in the resume block's `[question]` line (compact.ts,
// resume.ts), so the question is in front of the user when they return. Session xxxxxxxx: an
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
function oneLine(s: string): string {
  return s.replace(/[\s\u0000-\u001f\u007f]+/g, ' ').trim()
}

/**
 * The text on one line within QUESTION_MAX: `end` keeps its end (an answer's question is its last
 * line) behind `…`, `start` its start (a dialog's first asks) before `…`. A surrogate pair is
 * never cut.
 */
export function clipQuestion(text: string, keep: 'start' | 'end'): string {
  const t = oneLine(text)
  if (t.length <= QUESTION_MAX) return t
  const cps = Array.from(t)
  if (keep === 'end') cps.reverse()
  const out: string[] = []
  let n = 1
  for (const c of cps) {
    if (n + c.length > QUESTION_MAX) break
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
 * ask (session xxxxxxxx: "The plan is checked, but … Which scope?").
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
export function noteDialog(s: Pick<LoadState, 'askTimedOut' | 'openQuestion'>, input: unknown, r: { isError?: true; result?: unknown }): void {
  if (r.isError !== true && timedOut(r.result)) {
    s.askTimedOut = dialogQuestions(input) ?? s.askTimedOut
    return
  }
  if (!personAnswered(r)) return
  s.askTimedOut = undefined
  s.openQuestion = undefined
}

/**
 * Main `turn.complete`: a turn that answered (not aborted: a person pressed Esc) and ended on a
 * question, or with a dialog that timed out, leaves that question open; its plain-text question
 * wins (the model's latest ask). A turn with neither keeps an earlier one open (a background
 * result's turn), which only a person's turn or the session's end closes (alive.ts).
 */
export function turnQuestion(s: Pick<LoadState, 'askTimedOut' | 'openQuestion'>, t: { reason: string; answer: string }): void {
  const q = t.reason === 'answer' ? (answerQuestion(t.answer) ?? s.askTimedOut) : undefined
  s.askTimedOut = undefined
  if (q !== undefined) s.openQuestion = q
}

/**
 * The question a main compaction carries: while the main turn runs, its dialog that closed on the
 * AFK timeout (newer than any earlier turn's question; that turn may compact before it ends), else
 * the question an earlier turn left open.
 */
export function carriedQuestion(s: Pick<LoadState, 'askTimedOut' | 'openQuestion' | 'mainTurnRunning'>): string | undefined {
  return (s.mainTurnRunning ? s.askTimedOut : undefined) ?? s.openQuestion
}
