// The work lane's state after an idle compaction (away digest phase 1; owner 2026-10-27 12:5x,
// xxxxxxxx-05/-06/-08/-09, AWAY-DIGEST §11). The model sets the to-do and done items and the
// lane's Status when it writes the summary; after an idle compaction the plugin reads that Status
// and re-checks it with code only where the text is unsure or contradicts what code measures:
// - `working`: a step can start, or a job runs whose result the work acts on: today's `[idle]`;
// - `finished`: every listed step done, nothing runs: the turn shows the digest, starts nothing;
// - `hard-blocked`: all that is left waits on the user and nothing runs (nothing can start);
// - `soft-blocked`: all that is left waits on the user and something still runs.
// Both blocked states act like `finished` (the digest), but the lane is not done. A result that
// unblocks a step makes the lane `working` again (the `[idle-done]` text says so), and work the
// model starts after the block went out supersedes the summary's Status for the rest of the idle
// episode (owner xxxxxxxx-06). Anything code cannot read falls back to `working`, today's
// behaviour; code never turns a summary toward a stop its own words do not ask for.
import type { Deps } from './deps'

export type Lane = 'working' | 'finished' | 'hard-blocked' | 'soft-blocked'

export const LANES: readonly Lane[] = ['working', 'finished', 'hard-blocked', 'soft-blocked']

/** The summary form's Status words before the lane states (read only; never written now). */
export const LEGACY_STATUS: readonly string[] = ['active', 'blocked', 'waiting-owner', 'waiting-job', 'done']

/** What code reads from the summary text: the model's own words, parsed, no text kept. */
export type LaneFacts = {
  /** The Status word (a lane word, a legacy word), or null when there is no Status line. */
  status: string | null
  /** Next steps marked `· todo`, marked `· done`, and listed with neither mark (an item's last mark counts). */
  todo: number
  done: number
  unmarked: number
  /** Of the steps marked todo, those whose text names no gate, ask, pending answer or wait: a step that can run. */
  free: number
  /** Next steps says `see handoff`: the steps are in a handoff file, so code cannot count them all. */
  elsewhere: boolean
  /** `Step 1:` is `none`, `proposed`, a step to run, or there is no Step 1 line. */
  step1: 'none' | 'proposed' | 'set' | 'missing'
  /** The `Gate:` line says `none` (and Step 1 names no ask or wait), names a blocker, or is missing. */
  gate: 'none' | 'set' | 'missing'
  /** Acuity `unstable` or a `MID-STEP` checkpoint: a step is half done. */
  unstable: boolean
}

/** The state code settled on, how (the summary's Status, or the code re-check), and a plain reason. */
export type LaneResult = { lane: Lane; source: 'status' | 'recheck'; why: string }

/** What code measured at the time of the check. */
export type LaneMeasured = {
  /** Units of this session still running: agents, and the background tasks the measure lists (`runningUnits`). */
  running: number
  /** The compaction began mid-turn: its last step is unverified. */
  midturn: boolean
  /** The summary is not in the handoff form. */
  nonok: boolean
  /** The re-measure names an Active driver (a loop skill this session runs). */
  driver: boolean
  /** The model started work (an agent, a workflow, a background shell) after a turn got the idle block. */
  superseded?: boolean
}

const STATUS_RE = /^\s*Status:\s*([a-z][a-z-]*)/m
const ACUITY_UNSTABLE = /(?:^|· )Acuity: unstable\b/m
const MID_STEP = /checkpoint: MID-STEP\b/
const STEP1_RE = /^\s*Step 1:[ \t]*(.*)$/m
const GATE_RE = /^\s*Gate:[ \t]*([^·\n]*)/m
const ITEM_RE = /^\s*\d+\.\s/
/**
 * A step mark: `· todo` or `· done` that ends the item's own words (the line end, a `;`, `,`, `.`
 * or `)`, or the next item of a one-line section), so `· done when green` is not one.
 */
const MARK_SRC = '·\\s*(todo|done)(?=\\s*$|\\s*[;,.)]|\\s+\\d+\\.\\s)'
/** A step that cannot run now: it is gated, asks the user, holds a pending answer or waits on something. */
const HELD_RE = /\b(?:gated|ask user|pending answer|waits? (?:on|for))\b/i
const ELSEWHERE_RE = /\bsee handoff\b/i

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

/** The item's last step mark, or undefined. */
function lastMark(item: string): 'todo' | 'done' | undefined {
  let mark: 'todo' | 'done' | undefined
  for (const m of item.matchAll(new RegExp(MARK_SRC, 'gm'))) mark = m[1] === 'done' ? 'done' : 'todo'
  return mark
}

/**
 * The items of a Next steps section: one per line that starts with `N. `; a line holding several
 * (the one-line form, `1. a · done 2. b · todo`) is split before the next number in sequence, and
 * only once the item before it carries its mark, so `bump to 2. then ship` stays one item.
 * Continuation lines (`if … → …`, `- pending answer: …`) belong to no item.
 */
function items(lines: string[]): string[] {
  const out: string[] = []
  for (const raw of lines) {
    const line = raw.trim()
    const first = /^(\d+)\.\s/.exec(line)
    if (!first) continue
    let next = Number(first[1]) + 1
    let start = 0
    for (const m of line.matchAll(/\s(\d+)\.\s/g)) {
      if (Number(m[1]) !== next || m.index === undefined) continue
      const cur = line.slice(start, m.index)
      if (lastMark(cur) === undefined) continue
      out.push(cur.trim())
      start = m.index + 1
      next++
    }
    out.push(line.slice(start).trim())
  }
  return out.filter(x => ITEM_RE.test(x))
}

/** Reads the lane facts from a summary's text (the installed summary message or a saved copy). */
export function laneFacts(text: string): LaneFacts {
  const resume = section(text, 'resume here').join('\n')
  const where = resume !== '' ? resume : text
  const st = STATUS_RE.exec(where)
  const s1 = STEP1_RE.exec(where)
  const step = s1?.[1]?.trim() ?? ''
  const step1 = s1 === null || step === '' ? 'missing' : /^`?none\b/i.test(step) ? 'none' : /\|\s*proposed\s*$/.test(step) ? 'proposed' : 'set'
  const g = GATE_RE.exec(where)?.[1]?.trim()
  // A Step 1 that itself asks the user or waits is behind a gate, whatever the Gate line says.
  const gate = g === undefined || g === '' ? 'missing' : /^`?none\b/i.test(g) && !HELD_RE.test(step) ? 'none' : 'set'
  const next = section(text, 'next steps')
  let todo = 0
  let done = 0
  let unmarked = 0
  let free = 0
  for (const item of items(next)) {
    const m = lastMark(item)
    if (m === 'done') done++
    else if (m === 'todo') {
      todo++
      if (!HELD_RE.test(item)) free++
    } else unmarked++
  }
  return {
    status: st?.[1] ?? null, todo, done, unmarked, free, elsewhere: ELSEWHERE_RE.test(next.join('\n')), step1, gate,
    unstable: ACUITY_UNSTABLE.test(where) || MID_STEP.test(where),
  }
}

/** Lane facts read back from a record on disk (a restored block): the shape `laneFacts` gives, else undefined. */
export function asLaneFacts(x: unknown): LaneFacts | undefined {
  if (x === null || typeof x !== 'object') return undefined
  const o = x as Record<string, unknown>
  const n = (k: string) => typeof o[k] === 'number' && Number.isInteger(o[k]) && (o[k] as number) >= 0
  if (!(o.status === null || typeof o.status === 'string') || !['todo', 'done', 'unmarked', 'free'].every(n)) return undefined
  if (typeof o.elsewhere !== 'boolean' || typeof o.unstable !== 'boolean') return undefined
  if (!['none', 'proposed', 'set', 'missing'].includes(o.step1 as string) || !['none', 'set', 'missing'].includes(o.gate as string)) return undefined
  return {
    status: o.status as string | null, todo: o.todo as number, done: o.done as number, unmarked: o.unmarked as number, free: o.free as number,
    elsewhere: o.elsewhere, step1: o.step1 as LaneFacts['step1'], gate: o.gate as LaneFacts['gate'], unstable: o.unstable,
  }
}

/** Every `why` below is at most this long: tools/assemble fills `@lane_why@` with one this long for the budgets. */
export const LANE_WHY_MAX = 63

function recheck(lane: Lane, why: string): LaneResult {
  return { lane, source: 'recheck', why }
}

/**
 * The lane state. The summary's Status leads (owner xxxxxxxx-05); code overrides it where the
 * text is unsure or contradicts it, toward more work or a truer blocked label, and toward a stop
 * only when the summary's own marks ask for one:
 * - working, whatever the Status: a mid-turn compaction, a summary not in the handoff form, a
 *   half-done step, a measured loop driver, or work started after the block went out;
 * - `finished` is working while a unit runs, a step is marked todo or has no mark, Step 1 is set
 *   or missing, or the steps are in a handoff file (`see handoff`);
 * - a blocked Status is working while a step can run (marked todo, naming no gate or wait; or
 *   Step 1 set with `Gate: none`: owner xxxxxxxx-08, non-blocking work keeps the lane going);
 *   `hard-blocked` with a unit running is `soft-blocked`;
 * - `working`, an older word or none: `finished` once nothing runs, every listed step is marked
 *   done and Step 1 is none (a Status written while agents ran, as at the plugin's idle
 *   compaction); else working.
 */
export function laneOf(f: LaneFacts | undefined, m: LaneMeasured): LaneResult {
  if (m.midturn) return recheck('working', 'the last step before the compaction is unverified')
  if (f === undefined) return recheck('working', 'no summary code could read')
  if (m.nonok) return recheck('working', 'the summary is not in the handoff form')
  if (f.unstable) return recheck('working', 'a step is half done')
  if (m.driver) return recheck('working', 'a loop driver is active')
  if (m.superseded === true) return recheck('working', 'work started after the summary')
  const w = f.status
  if (w === 'finished') {
    if (m.running > 0) return recheck('working', 'the summary says finished, but a job still runs')
    if (f.todo > 0 || f.step1 === 'set') return recheck('working', 'the summary says finished, but a step is still to do')
    if (f.unmarked > 0) return recheck('working', 'the summary says finished, but a step has no done mark')
    if (f.step1 === 'missing') return recheck('working', 'the summary says finished, but has no Step 1 line')
    if (f.elsewhere) return recheck('working', 'the summary says finished, but its steps are in a handoff')
    return { lane: 'finished', source: 'status', why: "the summary's Status line" }
  }
  if (w === 'hard-blocked' || w === 'soft-blocked') {
    if (f.free > 0) return recheck('working', `the summary says ${w}, but a step with no gate is to do`)
    if (f.step1 === 'set' && f.gate === 'none') return recheck('working', `the summary says ${w}, but Step 1 has no gate`)
    if (w === 'hard-blocked' && m.running > 0) return recheck('soft-blocked', 'the summary says hard-blocked, but a job still runs')
    return { lane: w, source: 'status', why: "the summary's Status line" }
  }
  const allDone = f.done > 0 && f.todo === 0 && f.unmarked === 0 && !f.elsewhere && f.step1 === 'none'
  if (w === 'working') {
    if (m.running === 0 && allDone) return recheck('finished', 'the summary says working, but all steps are done, none runs')
    return { lane: 'working', source: 'status', why: "the summary's Status line" }
  }
  if (m.running > 0) return recheck('working', 'no Status code could read, and a job still runs')
  if (allDone) return recheck('finished', 'no Status code could read, but every listed step is marked done')
  return recheck('working', 'no Status code could read')
}

/** The lane states that show the digest instead of continuing. */
export function showsDigest(l: Lane): boolean {
  return l !== 'working'
}

/** The in-flight rows of a measure (`In flight (sidecar …):`, measure.pm `inflight_lines`): id, type, status. */
const INFLIGHT_ROW = /^\s+(\S+) · ([^·]+?) · (\S+)/
/** Types that are not a unit of work here: agents are counted live, a Monitor or a cron only watches (AWAY-DIGEST §2.1). */
const NOT_UNIT = /^(?:subagent|local_agent|cron)$|monitor/i

/**
 * The background tasks (shells, workflows, other kinds) a measure lists as running or pending:
 * the newest sidecar slot, written at the last turn's end, which the agent list does not show.
 */
export function measuredRunning(remeasure: string | undefined): string[] {
  const out: string[] = []
  let inside = false
  for (const line of (remeasure ?? '').split('\n')) {
    if (/^In flight\b/.test(line)) {
      inside = true
      continue
    }
    if (!inside) continue
    const m = INFLIGHT_ROW.exec(line)
    if (!m) {
      if (!/^\s/.test(line)) inside = false
      continue
    }
    const [, id = '', type = '', status = ''] = m
    if (/^(?:running|pending)$/i.test(status) && !NOT_UNIT.test(type.trim())) out.push(id)
  }
  return out
}

/**
 * The units of this session running now: its agents (the same set as idle.ts `agentsRunning`)
 * and the background tasks `remeasure` lists as running, less every task a notification of this
 * idle episode reported ended (AWAY-DIGEST §2.1 interim rule until probe P-AD-1: a background
 * result's own turn counts its task as ended, whatever the agent list or the sidecar still says).
 */
export async function runningUnits(d: Deps, remeasure: string | undefined, ended: ReadonlySet<string>): Promise<number> {
  const ids = new Set<string>(d.state.agentTurns)
  for (const id of (await d.agentsAlive()) ?? []) ids.add(id)
  for (const id of measuredRunning(remeasure)) ids.add(id)
  for (const id of ended) ids.delete(id)
  return ids.size
}

/** The task ids a background-task notification names (`<task-id>…</task-id>`; several in a batch). */
export function notifiedTasks(text: string): string[] {
  return [...text.matchAll(/<task-id>\s*([A-Za-z0-9._:/-]{1,128})\s*<\/task-id>/g)].map(m => m[1] ?? '').filter(x => x !== '')
}

/** A main-session tool call that started work: an agent, a workflow, or a shell sent to the background. */
export function startsWork(tool: string, result: unknown): boolean {
  if (tool === 'Agent' || tool === 'Task' || tool === 'Workflow') return true
  if (tool !== 'Bash' || result === null || typeof result !== 'object') return false
  const id = (result as Record<string, unknown>)['backgroundTaskId']
  return typeof id === 'string' && id !== ''
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
 * lane as finished or hard-blocked though the turn before was told otherwise (a job ended). When
 * an earlier turn of the episode already got a finished or blocked lane (its digest went out),
 * the note asks for one line on the new state, not a second digest.
 */
export function laneNote(name: string, r: LaneResult, again = false): string {
  return `Note from the user's ${name} plugin: after this result code reads the work lane as ${r.lane} (${r.why}). ` +
    'A result that unblocks a step makes it working again: handle it, then continue Step 1 unless it needs the user or hits a gate. ' +
    'A cron or Monitor turn: do its iteration first. ' +
    (again
      ? `Else start nothing; the away digest went out already: say in one line that the lane is now ${r.lane}, then last, Needs you (numbered, each with what it blocks) or Nothing needed from you.`
      : 'Else start nothing and print the away digest: the lane state and why; Done; Left (what blocks each); Running; Decided without you; ' +
        'last, Needs you (numbered, each with what it blocks) or Nothing needed from you.')
}
