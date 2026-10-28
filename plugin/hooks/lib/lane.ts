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
  /** Of the steps marked todo, those whose text names no gate, ask, pending answer, wait or job trigger: a step that can run. */
  free: number
  /**
   * Of the steps marked todo, those held on a job: their only trigger is a running job's result
   * (`On the timer notification, reply …`, `when CI finishes, report …`, `wait for the B-1
   * result`; owner 2026-10-28 digest rules (a)). Such a step runs once that result is in (-06).
   */
  onJob: number
  /** Of the steps marked todo, those held on the user (a gate, an ask, a pending answer, a needed approval) or on another named wait (a reviewer). */
  onUser: number
  /** Next steps says `see handoff`: the steps are in a handoff file, so code cannot count them all. */
  elsewhere: boolean
  /**
   * The summary has a Next steps section (`## Next steps: none` included). A summary cut near its
   * size cap can lose it (AWAY-DIGEST §4.3), so a finished Status without one is not believed.
   */
  listed: boolean
  /** `Step 1:` is `none`, `proposed`, a step to run, or there is no Step 1 line. */
  step1: 'none' | 'proposed' | 'set' | 'missing'
  /**
   * The `Gate:` line says `none` (and Step 1 names no ask, wait or job trigger), says `none` while
   * Step 1 is held on a job (`job`: it runs once the job's result is in), names a blocker, or is missing.
   */
  gate: 'none' | 'job' | 'set' | 'missing'
  /** Acuity `unstable` or a `MID-STEP` checkpoint: a step is half done. */
  unstable: boolean
}

/**
 * The state code settled on, how (the summary's Status, or the code re-check), and a plain reason.
 * `byResult`: working only because the job's result that came with this turn unblocks a step held
 * on that job (owner 2026-10-28 digest rules (a)); that turn's end reads the lane again (rule (b)).
 */
export type LaneResult = { lane: Lane; source: 'status' | 'recheck'; why: string; byResult?: true }

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
  /**
   * A job's result came with this turn's prompt (a notification that reported a task ended): a
   * step held on a job can run in this turn (owner 2026-10-28 digest rules (a), xxxxxxxx-06).
   */
  result?: boolean
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
/**
 * A step that cannot run now: it is gated, asks the user, holds a pending answer, waits on
 * something (`waits for`, `waiting on`, `awaiting`, `blocked on`/`by`) or needs an approval or the
 * user. A wait on CI or a reviewer counts too: under a blocked Status the model's word leads
 * (owner xxxxxxxx-05), and code moves a stop toward work only on a step that names no wait at all.
 * A wait on a running job, and any other step whose trigger is a job's result, is held on that
 * job (`JOB_RE`, owner 2026-10-28 digest rules (a)), whatever the wording (`Wait for …` or `On …`).
 */
const HELD_RE = /\b(?:gated|ask user|pending answer|wait(?:s|ing)? (?:on|for)|await(?:s|ing)?|blocked (?:on|by)|needs? (?:an? )?(?:approval|the user|user|owner|you|your))\b/i
/** The part of `HELD_RE` that holds a step on the user: a gate, an ask, a pending answer, a needed approval or the user. */
const USER_RE = /\b(?:gated|ask user|pending answer|needs? (?:an? )?(?:approval|the user|user|owner|you|your))\b/i
/** Up to four words between a trigger and what it names. */
const WORDS = "(?:[\\w.#/'\"`-]+\\s+){0,4}?"
/** A job's result as a step names it. */
const RESULT_NOUN = '(?:notifications?|results?|outputs?|completion)'
/** A running job (or its result) as a step names it: `B-n` is the summary form's id of a background job. */
const JOB_NOUN = `(?:${RESULT_NOUN}|jobs?|builds?|CI|pipelines?|timers?|agents?|subagents?|workflows?|shells?|runs?|tasks?|B-\\d+)`
/** A job that ends or a result that comes in. */
const FINISH = '(?:finish(?:es|ed)?|ends?|ended|completes?|completed|arrives?|arrived|returns?|returned|comes? (?:in|back)|fires?|fired|exits?|exited|passes|passed|fails|failed|is (?:done|in|back|green|red))'
/**
 * A step whose trigger is a running job's result (owner 2026-10-28 digest rules (a)): `On the
 * timer notification, reply …` (on, upon or after at the start of a clause, then the result);
 * `when CI finishes`, `after the build ends`, `once the result arrives` (a trigger, a job, its
 * end); `wait for the timer notification`, `waits on B-1`, `awaiting the build` (a wait on a job).
 * Each needs a trigger word and a job or result named after it, so a step that only mentions a
 * build or a result (`fix the build script`, `work on the results table`) stays free work: code
 * never turns a summary toward a stop its own words do not ask for.
 */
const JOB_RE = new RegExp(
  `(?:^(?:\\d+\\.\\s+)?|[;:,(—]\\s*)(?:on|upon|after)\\s+${WORDS}${RESULT_NOUN}\\b` +
    `|\\b(?:when|after|once|until|as soon as)\\s+${WORDS}${JOB_NOUN}\\s+(?:[\\w.#/'-]+\\s+){0,2}?${FINISH}\\b` +
    `|\\b(?:wait(?:s|ing)?\\s+(?:on|for|until)|await(?:s|ing)?)\\s+(?:[\\w.#/'-]+\\s+){0,2}?${JOB_NOUN}\\b`,
  'i',
)
/** A step's done criterion (`— done when the run finishes`, up to its mark or next clause): not a trigger. */
const CRITERION_RE = /\bdone when\b[^·;]*/gi
/**
 * What holds a step (Step 1's text, or a Next steps item): the user (a gate, an ask, a pending
 * answer, a needed approval, or another named wait such as a reviewer), a running job's result
 * (owner 2026-10-28 digest rules (a): it runs once the result is in), or nothing (it can run).
 * The user wins over a job: a step that needs both still needs the user after the job ends.
 */
function holdOf(text: string): 'user' | 'job' | undefined {
  if (USER_RE.test(text)) return 'user'
  if (JOB_RE.test(text.replace(CRITERION_RE, ''))) return 'job'
  return HELD_RE.test(text) ? 'user' : undefined
}
const ELSEWHERE_RE = /\bsee handoff\b/i
/** Step 1's `— for "<the user's latest request>"` tail (and what follows it). */
const FOR_TAIL = /\s+—\s+for\s+".*$/

/** The body of one `## <heading>` section (up to the next `## ` heading or the end marker); undefined when there is none. */
function section(text: string, heading: string): string[] | undefined {
  const lines = text.split('\n')
  const at = lines.findIndex(l => l.trim().toLowerCase().startsWith('## ' + heading))
  if (at < 0) return undefined
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
  const resume = (section(text, 'resume here') ?? []).join('\n')
  const where = resume !== '' ? resume : text
  const st = STATUS_RE.exec(where)
  const s1 = STEP1_RE.exec(where)
  const step = s1?.[1]?.trim() ?? ''
  const step1 = s1 === null || step === '' ? 'missing' : /^`?none\b/i.test(step) ? 'none' : /\|\s*proposed\s*$/.test(step) ? 'proposed' : 'set'
  const g = GATE_RE.exec(where)?.[1]?.trim()
  // A Step 1 that itself asks the user or waits is behind a gate, whatever the Gate line says (its
  // `— for "<the user's request>"` tail is the user's words, not the step's).
  const held = /^`?none\b/i.test(g ?? '') ? holdOf(step.replace(FOR_TAIL, '')) : 'user'
  const gate = g === undefined || g === '' ? 'missing' : held === undefined ? 'none' : held === 'job' ? 'job' : 'set'
  const found = section(text, 'next steps')
  const next = found ?? []
  let todo = 0
  let done = 0
  let unmarked = 0
  let free = 0
  let onJob = 0
  let onUser = 0
  for (const item of items(next)) {
    const m = lastMark(item)
    if (m === 'done') done++
    else if (m === 'todo') {
      todo++
      const h = holdOf(item)
      if (h === 'job') onJob++
      else if (h === 'user') onUser++
      else free++
    } else unmarked++
  }
  return {
    status: st?.[1] ?? null, todo, done, unmarked, free, onJob, onUser, elsewhere: ELSEWHERE_RE.test(next.join('\n')), listed: found !== undefined, step1, gate,
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
  if (!['none', 'proposed', 'set', 'missing'].includes(o.step1 as string) || !['none', 'job', 'set', 'missing'].includes(o.gate as string)) return undefined
  // A record written before the holds were told apart has no `onJob` or `onUser`: every held step
  // counts as held on the user (it was read so then).
  if ((o.onJob !== undefined && !n('onJob')) || (o.onUser !== undefined && !n('onUser'))) return undefined
  const todo = o.todo as number
  const free = o.free as number
  const onJob = o.onJob === undefined ? 0 : (o.onJob as number)
  // A record without `listed` (written before it was read) counts as one with no Next steps: never finished.
  return {
    status: o.status as string | null, todo, done: o.done as number, unmarked: o.unmarked as number, free,
    onJob, onUser: o.onUser === undefined ? Math.max(0, todo - free - onJob) : (o.onUser as number),
    elsewhere: o.elsewhere, listed: o.listed === true, step1: o.step1 as LaneFacts['step1'], gate: o.gate as LaneFacts['gate'], unstable: o.unstable,
  }
}

/** Every `why` below is at most this long: tools/assemble fills `@lane_why@` with one this long for the budgets. */
export const LANE_WHY_MAX = 63

/**
 * The longest Basis `laneBasis` gives without a time (the block's): tools/assemble fills
 * `@lane_basis@` with one this long for the budgets. A note's Basis adds its `as of HH:MM`.
 */
export const LANE_BASIS_MAX = 113

/**
 * The measure's git line (measure.pm `git_lines`): files changed, then commits ahead of the
 * upstream, or `no upstream` / `upstream gone` when there is none to count against.
 */
const GIT_RE = /^git: branch .*? · HEAD \S+ · (\d+) changed · (?:ahead (\d+) behind \d+|no upstream|upstream gone)/m

function count(n: number, one: string, many: string): string {
  return `${n > 999 ? '999+' : String(n)} ${n === 1 ? one : many}`
}

/**
 * The digest's Basis line, rendered by code when its block or note goes out (AWAY-DIGEST §3.1,
 * §8 "invented or stale facts"; review of fix round 1, M7): how many of the listed steps the
 * summary marks done, the units running now, and the commits not pushed and files changed the
 * measure shows. The model prints it as it is; the rest of the digest is the model's (owner
 * xxxxxxxx-05: the model sets the done and to-do items).
 * A branch with no upstream (a new local or worktree branch, a detached HEAD) or a gone one has
 * its commits not pushed unknown, never 0 (review of fix round 2). `asOf` (a note's, `HH:MM`) is
 * when the measure was taken: a later turn's note reuses the one its block went out with.
 */
export function laneBasis(f: LaneFacts | undefined, running: number, remeasure: string | undefined, asOf?: string): string {
  const steps = f === undefined ? 'no steps code could read'
    : f.elsewhere ? 'the steps are in the handoff file'
    : !f.listed ? 'no Next steps listed'
    : `${f.done > 999 ? '999+' : String(f.done)} of ${count(f.done + f.todo + f.unmarked, 'listed step', 'listed steps')} marked done`
  const g = GIT_RE.exec(remeasure ?? '')
  const files = g ? count(Number(g[1]), 'file', 'files') + ' changed' : ''
  const git = !g ? 'git: not measured'
    : `git${asOf !== undefined ? ` as of ${asOf}` : ''}: ` +
      (g[2] === undefined ? `no upstream, unpushed unknown, ${files}` : `${count(Number(g[2]), 'commit', 'commits')} not pushed, ${files}`)
  return `${steps}; ${count(running, 'unit', 'units')} running; ${git}`
}

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
 *   or missing, the steps are in a handoff file (`see handoff`), or there is no Next steps
 *   section (a summary cut near its size cap can lose it: AWAY-DIGEST §4.3);
 * - a blocked Status is working while a step can run (marked todo, naming no gate or wait; or
 *   Step 1 set with `Gate: none`: owner xxxxxxxx-08, non-blocking work keeps the lane going);
 *   a step held on a job is not such a step: the model's blocked word stands while the job runs,
 *   and only the turn its result comes with reads working (`byResult`; owner 2026-10-28 digest
 *   rules (a), xxxxxxxx-06: the result unblocks that step); that turn's end reads the lane again
 *   without the result (rule (b), digest.ts `laneTurnEnd`), so the step it did no longer counts;
 *   `hard-blocked` with a unit running is `soft-blocked`, and `soft-blocked` with none is
 *   `hard-blocked` (owner xxxxxxxx-06: soft means something still runs);
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
    if (!f.listed) return recheck('working', 'the summary says finished, but has no Next steps')
    return { lane: 'finished', source: 'status', why: "the summary's Status line" }
  }
  if (w === 'hard-blocked' || w === 'soft-blocked') {
    if (f.free > 0) return recheck('working', `the summary says ${w}, but a step with no gate is to do`)
    if (f.step1 === 'set' && f.gate === 'none') return recheck('working', `the summary says ${w}, but Step 1 has no gate`)
    if (m.result === true && (f.onJob > 0 || (f.step1 === 'set' && f.gate === 'job'))) {
      return { ...recheck('working', `the summary says ${w}, but a result unblocks a step`), byResult: true }
    }
    if (w === 'hard-blocked' && m.running > 0) return recheck('soft-blocked', 'the summary says hard-blocked, but a job still runs')
    if (w === 'soft-blocked' && m.running === 0) return recheck('hard-blocked', 'the summary says soft-blocked, but nothing runs')
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

/**
 * The statuses a notification ends its task with (Claude Code's UserMessageTask: `completed`,
 * `failed` or `killed`; `stopped` and `cancelled` read the same).
 */
const ENDED_RE = /^(?:completed|failed|killed|stopped|cancell?ed)$/i

/**
 * The task ids a background-task notification reports ended (`<task-id>…</task-id>`; several in a
 * batch). Each id takes the `<status>` that follows it inside its own notification, before the
 * next id: only an ending word counts the task as ended. No status, or another word, leaves it
 * running: a Monitor's event comes as a notification with a task id, a summary and an event but
 * no status while the monitor runs on, and every ended task's notification seen in the session
 * records carries its status (review of fix round 2). Missing an end keeps the lane working,
 * the safe side.
 */
export function notifiedTasks(text: string): string[] {
  const out: string[] = []
  for (const part of text.split(/<\/?task-notification>/)) {
    const ids = [...part.matchAll(/<task-id>\s*([A-Za-z0-9._:/-]{1,128})\s*<\/task-id>/g)]
    ids.forEach((m, i) => {
      const end = ids[i + 1]?.index ?? part.length
      const status = /<status>\s*([^<]*?)\s*<\/status>/.exec(part.slice((m.index ?? 0) + m[0].length, end))?.[1]
      if (m[1] && status !== undefined && ENDED_RE.test(status)) out.push(m[1])
    })
  }
  return out
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
 * the note asks for one line on the new state, not a second digest. `basis` is `laneBasis` now.
 */
export function laneNote(name: string, r: LaneResult, basis: string, again = false): string {
  return `Note from the user's ${name} plugin: after this result code reads the work lane as ${r.lane} (${r.why}). ` +
    'A result that unblocks a step makes it working again: handle it, then continue Step 1 unless it needs the user or hits a gate. ' +
    'A cron or Monitor turn: do its iteration first. ' +
    (again
      ? `Else start nothing; the away digest went out already: say in one line that the lane is now ${r.lane} (Basis: ${basis}), then last, Needs you (numbered, each with what it blocks) or Nothing needed from you.`
      : `Else start nothing and print the away digest: the lane state and why; Basis: ${basis} (by code, as is); Done (listed steps marked done); ` +
        'Left (each listed step not done, what blocks it; commits not pushed); Running; Decided without you; ' +
        'last, Needs you (numbered, each with what it blocks) or Nothing needed from you.')
}

/**
 * The text of the digest turn the plugin submits after a result's turn did the step that result
 * unblocked and the lane now reads finished or hard-blocked (owner 2026-10-28 digest rules (b);
 * digest.ts `laneTurnEnd`). `basis` is `laneBasis` now.
 */
export function resultDigestLine(name: string, r: LaneResult, basis: string): string {
  return `Note from the user's ${name} plugin: the user is still away. The last turn handled a background result; code now reads the work lane as ${r.lane} (${r.why}). ` +
    'A step that can still run without the user: continue it, unless it hits a gate. ' +
    `Else start nothing and print the away digest: the lane state and why; Basis: ${basis} (by code, as is); Done (listed steps marked done, and what the last turn did); ` +
    'Left (each listed step not done, what blocks it; commits not pushed); Running; Decided without you; ' +
    'last, Needs you (numbered, each with what it blocks) or Nothing needed from you.'
}

/**
 * A turn's answer that already ends with the digest's last section (`Needs you` or `Nothing
 * needed from you` opening a line): the `[idle]` block's step 5 asks for the digest when all
 * that is left waits on the user, so a result's turn may have printed it; no second one follows.
 */
export const DIGEST_END_RE = /^[^\w\n]*(?:Needs you\b|Nothing needed from you\b)/m
