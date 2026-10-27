// The work lane's state after an idle compaction (away digest phase 1; owner 2026-10-27 12:5x,
// xxxxxxxx-05/-06/-08/-09, AWAY-DIGEST §11). The model sets the to-do and done items and the
// lane's Status when it writes the summary; after an idle compaction the plugin reads that Status
// and re-checks it with code only where the text is unsure or contradicts what code measures:
// - `working`: a step can start, or a job runs whose result the work acts on: today's `[idle]`;
// - `finished`: every listed step done, nothing runs: the turn shows the digest, starts nothing;
// - `hard-blocked`: all that is left waits on the user and nothing runs (nothing can start);
// - `soft-blocked`: all that is left waits on the user and something still runs.
// Both blocked states act like `finished` (the digest), but the lane is not done. A result that
// unblocks a step makes the lane `working` again (the `[idle-done]` text says so; the next
// summary carries the new Status). Anything code cannot read falls back to `working`, today's
// behaviour.
import type { Deps } from './deps'

export type Lane = 'working' | 'finished' | 'hard-blocked' | 'soft-blocked'

export const LANES: readonly Lane[] = ['working', 'finished', 'hard-blocked', 'soft-blocked']

/** The summary form's Status words before the lane states (read only; never written now). */
export const LEGACY_STATUS: readonly string[] = ['active', 'blocked', 'waiting-owner', 'waiting-job', 'done']

/** What code reads from the summary text: the model's own words, parsed, no text kept. */
export type LaneFacts = {
  /** The Status word (a lane word, a legacy word), or null when there is no Status line. */
  status: string | null
  /** Next steps marked `· todo`, marked `· done`, and listed with neither mark. */
  todo: number
  done: number
  unmarked: number
  /** `Step 1:` is `none` (or missing), `proposed`, or a step to run. */
  step1: 'none' | 'proposed' | 'set'
  /** Acuity `unstable` or a `MID-STEP` checkpoint: a step is half done. */
  unstable: boolean
}

/** The state code settled on, how (the summary's Status, or the code re-check), and a plain reason. */
export type LaneResult = { lane: Lane; source: 'status' | 'recheck'; why: string }

/** What code measured at the time of the check. */
export type LaneMeasured = {
  /** Agents of this session still running (subagents, teammates, agent loops of this load). */
  running: number
  /** The compaction began mid-turn: its last step is unverified. */
  midturn: boolean
  /** The summary is not in the handoff form. */
  nonok: boolean
  /** The re-measure names an Active driver (a loop skill this session runs). */
  driver: boolean
}

const STATUS_RE = /^\s*Status:\s*([a-z][a-z-]*)/m
const ACUITY_UNSTABLE = /(?:^|· )Acuity: unstable\b/m
const MID_STEP = /checkpoint: MID-STEP\b/
const STEP1_RE = /^\s*Step 1:\s*(.*)$/m
const ITEM_RE = /^\s*\d+\.\s/
const MARK_RE = /·\s*(todo|done)\b/

/** The body of one `## <heading>` section (up to the next `## ` heading or the end marker). */
function section(text: string, heading: string): string[] {
  const lines = text.split('\n')
  const at = lines.findIndex(l => l.trim().toLowerCase().startsWith('## ' + heading))
  if (at < 0) return []
  const out: string[] = []
  // The heading line may carry the first item inline (`## Next steps: 1. …`).
  const head = lines[at] ?? ''
  const colon = head.indexOf(':')
  if (colon >= 0 && head.slice(colon + 1).trim() !== '') out.push(head.slice(colon + 1).trim())
  for (const l of lines.slice(at + 1)) {
    if (/^#{1,2} /.test(l) || l.startsWith('⟪/') || l.startsWith('</summary>')) break
    out.push(l)
  }
  return out
}

/** Reads the lane facts from a summary's text (the installed summary message or a saved copy). */
export function laneFacts(text: string): LaneFacts {
  const resume = section(text, 'resume here').join('\n')
  const where = resume !== '' ? resume : text
  const st = STATUS_RE.exec(where)
  const s1 = STEP1_RE.exec(where)
  const step = s1?.[1]?.trim() ?? ''
  const step1 = step === '' || /^`?none\b/i.test(step) ? 'none' : /\|\s*proposed\s*$/.test(step) ? 'proposed' : 'set'
  let todo = 0
  let done = 0
  let unmarked = 0
  // An item may run on after a `;` in an inline section; split the one-line form at each number.
  const steps = section(text, 'next steps').join('\n').split(/(?=(?:^|\s)\d+\.\s)/m).map(x => x.trim()).filter(x => ITEM_RE.test(x))
  for (const item of steps) {
    const m = MARK_RE.exec(item)
    if (m?.[1] === 'done') done++
    else if (m?.[1] === 'todo') todo++
    else unmarked++
  }
  return { status: st?.[1] ?? null, todo, done, unmarked, step1, unstable: ACUITY_UNSTABLE.test(where) || MID_STEP.test(where) }
}

function isLane(w: string | null): w is Lane {
  return w !== null && (LANES as readonly string[]).includes(w)
}

/**
 * The lane state. The summary's Status leads (owner xxxxxxxx-05); code overrides it only toward
 * more work or a truer blocked label, never toward a stop the text did not ask for:
 * a mid-turn compaction, a half-done step and a measured loop driver keep `working`; a finished
 * lane with a job running or a step still to do is `working`; a hard-blocked lane with a job
 * running is `soft-blocked`. No Status (or an older word, or a summary not in the handoff form):
 * the code re-check, which finds `finished` only when every listed step is marked done, Step 1 is
 * none and nothing runs, and `working` otherwise.
 */
export function laneOf(f: LaneFacts | undefined, m: LaneMeasured): LaneResult {
  if (m.midturn) return { lane: 'working', source: 'recheck', why: 'the last step before the compaction is unverified' }
  if (f === undefined) return { lane: 'working', source: 'recheck', why: 'no summary code could read' }
  if (f.unstable) return { lane: 'working', source: 'recheck', why: 'a step is half done' }
  if (m.driver) return { lane: 'working', source: 'recheck', why: 'a loop driver is active' }
  const w = m.nonok ? null : f.status
  if (!isLane(w)) {
    if (m.running > 0) return { lane: 'working', source: 'recheck', why: 'no Status code could read, and a job still runs' }
    if (f.done > 0 && f.todo === 0 && f.unmarked === 0 && f.step1 === 'none') {
      return { lane: 'finished', source: 'recheck', why: 'no Status code could read, but every listed step is marked done' }
    }
    return { lane: 'working', source: 'recheck', why: 'no Status code could read' }
  }
  if (w === 'finished') {
    if (m.running > 0) return { lane: 'working', source: 'recheck', why: 'the summary says finished, but a job still runs' }
    if (f.todo > 0 || f.step1 === 'set') return { lane: 'working', source: 'recheck', why: 'the summary says finished, but a step is still to do' }
  }
  if (w === 'hard-blocked' && m.running > 0) return { lane: 'soft-blocked', source: 'recheck', why: 'the summary says hard-blocked, but a job still runs' }
  return { lane: w, source: 'status', why: "the summary's Status line" }
}

/** The lane states that show the digest instead of continuing. */
export function showsDigest(l: Lane): boolean {
  return l !== 'working'
}

/** The agents of this session still running (the same count as idle.ts `agentsRunning`). */
export async function runningNow(d: Deps): Promise<number> {
  const ids = new Set<string>(d.state.agentTurns)
  for (const id of (await d.agentsAlive()) ?? []) ids.add(id)
  return ids.size
}

/**
 * The text of the digest turn the plugin submits right after an idle compaction with nothing
 * running (`idle_digest: submit`, the default; owner xxxxxxxx-09). The resume block follows it.
 */
export function digestLine(name: string): string {
  return `Note from the user's ${name} plugin: the session was compacted while the user was away, and the work lane reads finished or blocked. Follow the resume block below: it asks for the away digest.`
}

/**
 * The note of a later turn not of a person's in the same idle episode, when code now reads the
 * lane as finished or hard-blocked though the turn before was told otherwise (a job ended).
 */
export function laneNote(name: string, r: LaneResult): string {
  return `Note from the user's ${name} plugin: after this result code reads the work lane as ${r.lane} (${r.why}). ` +
    'A result that unblocks a step makes it working again: handle it, then continue Step 1 unless it needs the user or hits a gate. ' +
    'Else start nothing and print the away digest: the lane state and why; Done; Left (what blocks each); Running; Decided without you; ' +
    'last, Needs you (numbered, each with what it blocks) or Nothing needed from you.'
}
