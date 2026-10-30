// The resume block (MOD-SPEC §3.4): built after a main compaction, delivered once by the first
// channel whose claim wins. The mod's channels are `prompt.context` (order 2) and the continue
// text (order 3, cont.ts); classic SessionStart (order 1) is the helper's. One exception (owner
// xxxxxxxx-37, "Full block again on return"): when a background result's turn took an idle
// compaction's block, the first human-origin prompt gets the full block again, re-measured, with
// `[idle-again]` noting the earlier use, beside that prompt (`prompt.submit` context: `againFor`).
import type { Deps, IdleLane, LoadState, Outcome, PendingResume } from './deps'
import { isHuman, storeWord } from './deps'
import type { Runtime, Tag } from './assemble'
import { assemble } from './assemble'
import type { RaceBlock } from './handoff-turn'
import { channelToken, claimBy, measure } from './helper'
import { escalate, helperMissing, isoLocal, log, vettedWatch } from './log'
import type { Lane, LaneFacts, LaneResult } from './lane'
import { LANES, LEGACY_STATUS, asLaneFacts, laneBasis, laneNote, laneOf, notifiedTasks, runningUnits, showsDigest } from './lane'

/**
 * MOD-SPEC §3.4: soft total 6,500 chars (compaction-rem-6, T-TEXT E3: a 3,000-char protocol beside
 * a 3,000-byte measured block); soft since the owner overturned ratify xxxxxxxx#R3 (2026-10-23,
 * SPEC-DELTAS RP-2/RP-4): a block over it logs `resume_block_over_soft`. The hard cap is 9,500,
 * under the 10,000-char SessionStart cutoff: over it whole re-measure lines are cut first.
 */
export const BLOCK_MAX = 9500
export const BLOCK_SOFT = 6500

/** `@handoff_finish@` when a raced draft has no safe finish command (its line says draft absent). */
export const NO_FINISH = '(none)'

export type BlockArgs = {
  /** This compaction's dispatch nonce (the re-measure reads its evidence). */
  nonce?: string
  midturn: boolean
  nonok: boolean
  /** Path of this compaction's copy, or null with `notSaved` as the reason. */
  savedCopy: string | null
  notSaved?: string
  /**
   * `[handoff]` (a published handoff of this window, with `[handoff-ack]` when its report was not
   * sent) or `[handoff-partial]` (a raced handoff turn).
   */
  handoff?: RaceBlock
  /** `[prod-allow]` instead of `[prod-forbid]` (see `prodAllowed`). */
  prodAllow?: boolean
  /** An idle compaction: `[idle]` (IC-1 D3), never with `[midturn]`. */
  idle?: boolean
  /** Owner xxxxxxxx-25 ("Stop in halt"): halt mode is on, so an idle block gets `[idle-halt]` instead of `[idle]`. */
  halt?: boolean
  /** Owner xxxxxxxx-37: a background result's turn took this idle block at this time; `[idle-again]` says so. */
  again?: number
  /**
   * Away digest phase 1 (owner 2026-10-27 12:5x): an idle block's lane facts from its summary. At
   * every build the lane is read again with the agents running then (lane.ts): a finished or
   * blocked lane gets `[idle-done]` instead of `[idle]`.
   */
  lane?: LaneFacts
}

/** The helper's `Active driver:` line (lib/gsd.pm) in a re-measure: `[driver]` is kept. */
export const DRIVER_LINE = /^Active driver: /m
/** The helper's GSD and driver lines (lib/gsd.pm) in a re-measure. */
const GSD_LINES = /^(?:GSD \(this session\)|GSD re-entry \(new session only\)|Active driver|Paused driver|Was driving): .*$/gm
const GSD_TIMEOUT = /^GSD: not measured \(timeout\)$/m

/**
 * Review of the third build: a delivery-time re-measure whose GSD step ran out of time keeps the
 * stored measure's GSD and driver lines in its place, so the block does not lose this session's
 * Active driver (and its `[driver]` line) to a slow `git status`.
 */
export function keepGsdLines(fresh: string, stored: string | undefined): string {
  if (stored === undefined || !GSD_TIMEOUT.test(fresh)) return fresh
  const kept = stored.match(GSD_LINES)
  // A replacer function: the kept lines carry STATE.md text, whose `$&` or `$'` must stay literal.
  return kept && kept.length > 0 ? fresh.replace(GSD_TIMEOUT, () => kept.join('\n')) : fresh
}

/** IC-1 D3: a block delivered later than this after it was built is built again. */
export const REMEASURE_AFTER_MS = 600000
/** The re-measure's budget at delivery (one helper call). */
export const REMEASURE_MS = 3000
/** The helper's own budget for that call (`--budget-ms`): under the kill, with room to print. */
export const REMEASURE_HELPER_MS = REMEASURE_MS - 300

/**
 * MOD-SPEC §3.4 step 4 (S-SETTINGS B): `[prod-allow]` only when the mod's own option and the
 * checkpoint of this nonce (`consent.unattended_prod_reads`, the helper's settings-file value)
 * both say `allow`; the stricter view wins, so a missing checkpoint keeps `[prod-forbid]`.
 */
export function prodAllowed(option: string, consent: string | undefined): boolean {
  return option === 'allow' && consent === 'allow'
}

/**
 * `@store@` for a text the mod assembles (PKG-RUNTIME A.1, A.2): the launcher word, or, for a
 * root no quoting can carry, the `store_path_unquotable` escalation and a `drop` of the lines
 * that hold it (no line names a command it cannot spell).
 */
export function storeRuntime(d: Deps): { runtime: Runtime; drop: string[] } {
  const w = storeWord(d.root, d.name)
  if (w !== undefined) return { runtime: { store: w }, drop: [] }
  escalate(d, 'store_path_unquotable')
  return { runtime: {}, drop: ['store'] }
}

/** The resume block; `fresh` is a measure already taken (the delivery-time re-measure), else one is taken now. */
export async function buildBlock(d: Deps, sid: string, a: BlockArgs, fresh?: string): Promise<string> {
  return (await buildBlockWith(d, sid, a, fresh)).block
}

/**
 * `buildBlock`, with the measure it was built from (undefined when the measure failed) and when
 * that measure was taken. `fresh` null: no measure is taken (a rebuild whose stored measure is
 * missing renders without one). `at`: when a stored measure was taken, so a rebuild that takes no
 * new one keeps its `@measured_at@` (IC-1 D3: the stamp shows the facts' age); else now.
 */
export async function buildBlockWith(
  d: Deps, sid: string, a: BlockArgs, fresh?: string | null, at?: number,
): Promise<{ block: string; remeasure: string | undefined; measuredAt: number; lane?: LaneResult; running?: number }> {
  // AP-5: the saved copy goes with the re-measure, so the summary's approvals are checked.
  const remeasure = fresh === null ? undefined : fresh ?? (await measure(d, sid, a.nonce, undefined, a.savedCopy ?? undefined))
  const driver = remeasure !== undefined && DRIVER_LINE.test(remeasure)
  const idle = a.idle === true && !a.midturn
  // Away digest phase 1: an idle block outside halt mode reads the work lane now (lane.ts), with
  // the units running now: agents, the measure's running rows (none for a block restored after
  // `claude --resume`: they ran in the process that ended), less what this episode's
  // notifications reported ended, with the work the model started since its block went out, and
  // with whether a job's result came with this turn's prompt (owner 2026-10-28 digest rules (a)).
  const ep = episodeOf(d.state, sid, a.nonce)
  const running = idle && a.halt !== true ? await runningUnits(d, ep?.restored === true ? undefined : remeasure, ep?.ended ?? new Set()) : undefined
  const lane = running !== undefined
    ? laneOf(a.lane, { running, midturn: a.midturn, nonok: a.nonok, driver, superseded: ep?.superseded === true, result: ep?.result === true })
    : undefined
  const tags: Tag[] = []
  if (a.midturn) tags.push('midturn')
  if (a.nonok) tags.push('nonok')
  // Owner xxxxxxxx-25: in halt mode the idle line stops after the background result; a finished
  // or blocked lane shows the digest instead of continuing (owner 2026-10-27 12:5x). Under
  // `idle_digest: off` (owner rule (c), 2026-10-28) the same lines ask for one line on the lane
  // state in place of the digest: `[idle-off]` and `[idle-done-off]`.
  const off = d.cfg.idle_digest === 'off'
  if (idle) {
    tags.push(a.halt === true ? 'idle-halt'
      : lane !== undefined && showsDigest(lane.lane) ? (off ? 'idle-done-off' : 'idle-done')
      : off ? 'idle-off' : 'idle')
  }
  if (idle && a.again !== undefined) tags.push('idle-again')
  // Exactly one of the two step-4 lines (BLD-04 exclusive group).
  tags.push(a.prodAllow === true ? 'prod-allow' : 'prod-forbid')
  // Owner 2026-10-26 (GSD re-entry per session): the re-enter line only beside a measured driver,
  // never in a halted idle block ([idle-halt] stops and waits for the user; EXCLUSIVE in tools/assemble).
  // A measured driver keeps the lane working (lane.ts), so it never meets [idle-done] (or its off
  // variant) either.
  if (driver && !tags.includes('idle-halt') && !tags.includes('idle-done') && !tags.includes('idle-done-off')) tags.push('driver')
  const measuredAt = at ?? (await d.now())
  const saved = a.savedCopy ?? `not saved (${a.notSaved ?? 'unknown'})`
  const store = storeRuntime(d)
  const runtime: Runtime = { session_id: sid, saved_copy: saved, measured_at: isoLocal(measuredAt, false), ...store.runtime }
  if (a.again !== undefined) runtime.idle_used_at = isoLocal(a.again, false)
  if (lane !== undefined) {
    runtime.lane = lane.lane
    runtime.lane_why = lane.why
    // The digest's Basis line, rendered by code now (review of fix round 1, M7): [idle-done]'s, and
    // the step-5 digest's of [idle] (owner 2026-10-27 22:32).
    runtime.lane_basis = laneBasis(a.lane, running ?? 0, remeasure)
  }
  const h = a.handoff
  if (h && 'published' in h) {
    tags.push('handoff')
    if (h.ack === true) tags.push('handoff-ack')
    runtime.handoff_path = h.published
  } else if (h) {
    // Never together with `[handoff]`; a draft without a safe finish command counts as absent.
    const present = h.draft && h.finish !== null
    tags.push('handoff-partial')
    runtime.draft_state = present ? 'present' : 'absent'
    runtime.handoff_finish = present ? '`' + (h.finish ?? '') + '`' : NO_FINISH
  }
  const block = remeasure === undefined
    ? assemble(d.name, 'resume-context', tags, runtime, ['remeasure', ...store.drop])
    : fitBlock(m => assemble(d.name, 'resume-context', tags, { ...runtime, remeasure: m }, store.drop), remeasure)
  if (block.length > BLOCK_SOFT) await log(d, sid, 'resume_block_over_soft', { nonce: a.nonce ?? null, chars: block.length })
  return { block, remeasure, measuredAt, ...(lane !== undefined ? { lane, running } : {}) }
}

/**
 * The block within `BLOCK_MAX`: whole re-measure lines are cut from the end, with a
 * `(+N lines)` note, only while the rendered block is over the total.
 */
export function fitBlock(render: (remeasure: string) => string, remeasure: string, max = BLOCK_MAX): string {
  const lines = remeasure.split('\n')
  let block = render(remeasure)
  for (let keep = lines.length - 1; block.length > max && keep >= 0; keep--) {
    block = render(lines.slice(0, keep).concat(`(+${lines.length - keep} lines)`).join('\n'))
  }
  return block
}

/** The `prompt.context` block name (`<plugin>-resume`). */
export function blockName(name: string): string {
  return `${name}-resume`
}

/**
 * `prompt.context`: sets ctxSeen; when a block is pending for this session, claims the channel
 * and adds the block, else leaves the blocks as they are (nothing pending, nothing added).
 */
export async function contextBlock(d: Deps, sid: string): Promise<string | undefined> {
  const s = d.state
  s.ctxSeen = true
  const human = isHuman(s.turnOrigin)
  // AT-RP-02: once per session id in this load, a block the classic SessionStart(resume) armed.
  if (!s.pending && s.restoreChecked !== sid) {
    s.restoreChecked = sid
    const r = await restorePending(d, sid)
    // A main compaction of this load while the record was read has a newer block; its after-step
    // settled the record as replaced. A restored idle block opens its idle episode (away digest).
    if (!s.pending && r) {
      s.pending = r
      if (r.args.idle === true && !r.args.midturn) openEpisode(s, sid, r.nonce, r.args, r.remeasure, r.measuredAt, true)
    }
  }
  const pend = s.pending
  // Later turns of an idle episode get their lane note beside their prompt (`laneRecheck`, from
  // `prompt.submit`): `prompt.context` is asked once per conversation, so a note here would not
  // reach them.
  if (!pend || pend.sid !== sid || pend.resumePref === 'none') return undefined
  const c = await claimBy(d, sid, pend.nonce, 'prompt.context')
  s.pending = undefined
  // A continue that claimed the block and was dropped for a user prompt (cont.ts) holds it for this
  // turn. One whose submit is still in flight logs its own outcome, or is dropped and puts it back.
  if (c.result === 'TAKEN' && c.by === 'prompt.submit' && s.contSubmitting && pend.heldClaim !== true) return undefined
  if (c.result === 'TAKEN' && !(pend.heldClaim === true && c.by === 'prompt.submit')) {
    await logOutcome(d, pend.sid, pend.nonce, pend.outcome, 'delivered:' + (c.by ?? 'unknown'))
    return undefined
  }
  if (c.result === 'failed') await helperMissing(d, sid, 'claim')
  const args = haltNow(d, pend.args)
  const out = await freshBlock(d, pend, args)
  if (pend.args.idle === true) await laneShown(d, pend, out, human)
  await logOutcome(d, pend.sid, pend.nonce, pend.outcome, 'delivered:prompt.context')
  // Owner xxxxxxxx-37: a background result (not a person) took an idle compaction's block; the
  // first human-origin prompt gets it again, beside that prompt (`againFor`).
  if (pend.args.idle === true && !isHuman(s.turnOrigin)) {
    s.idleAgain = { sid, pend: { ...pend, args }, usedAt: await d.now(), remeasure: out.remeasure, measuredAt: out.measuredAt }
  }
  return out.block
}

/**
 * One `lane_outcome {nonce, status, lane, source, agents, at}` row (enum values and a count only);
 * `agents` is the units counted running (agents and the measure's running background tasks).
 */
export async function logLane(
  d: Deps, sid: string, nonce: string, facts: LaneFacts | undefined, r: LaneResult, at: 'build' | 'delivery' | 'recheck' | 'submit', units: number,
): Promise<void> {
  // The model's word only when it is one of the known Status words (rows stay content-free).
  const w = facts?.status ?? null
  const status = w === null ? 'none' : (LANES as readonly string[]).includes(w) || LEGACY_STATUS.includes(w) ? w : 'other'
  await log(d, sid, 'lane_outcome', { nonce, status, lane: r.lane, source: r.source, agents: units, at })
}

/**
 * Opens the idle episode of an idle block (away digest phase 1): from its after-step, or from its
 * record restored after `claude --resume` (`restored`; no turn has got the block yet).
 */
export function openEpisode(
  s: LoadState, sid: string, nonce: string, a: BlockArgs, remeasure: string | undefined, measuredAt: number | undefined, restored = false,
): void {
  s.idleLane = {
    sid, nonce, facts: a.lane, nonok: a.nonok, driver: remeasure !== undefined && DRIVER_LINE.test(remeasure), shown: undefined,
    remeasure, measuredAt, ended: new Set(), superseded: false, closed: false, restored, result: false, unblocked: false, digested: false,
  }
}

/** The open idle episode of this block, or undefined. */
function episodeOf(s: LoadState, sid: string, nonce: string | undefined): IdleLane | undefined {
  const l = s.idleLane
  return l && l.sid === sid && l.nonce === nonce ? l : undefined
}

/**
 * An idle block went out to a turn (away digest phase 1): the lane state it told that turn, and
 * the measure it was built with, are what later turns of the episode are re-checked against; a
 * person's turn ends the episode.
 */
async function laneShown(
  d: Deps, pend: PendingResume, out: { remeasure: string | undefined; measuredAt: number; lane?: LaneResult; running?: number }, human: boolean,
): Promise<void> {
  const s = d.state
  if (out.lane !== undefined) await logLane(d, pend.sid, pend.nonce, pend.args.lane, out.lane, 'delivery', out.running ?? 0)
  const l = episodeOf(s, pend.sid, pend.nonce)
  if (!l) return
  if (human) {
    s.idleLane = undefined
    return
  }
  l.shown = out.lane?.lane ?? 'working'
  if (showsDigest(l.shown)) l.digested = true
  // Owner 2026-10-28 digest rules (b): working only because this turn's result unblocks a step
  // held on its job: this turn's end reads the lane again.
  if (out.lane?.byResult === true) l.unblocked = true
  // The measure this turn's block went out with (re-measured past 600 s): its rows and its driver.
  l.remeasure = out.remeasure
  l.measuredAt = out.measuredAt
  l.driver = out.remeasure !== undefined && DRIVER_LINE.test(out.remeasure)
}

/**
 * Away digest phase 1, the re-check channel (AWAY-DIGEST §2.1, owner 2026-10-27 12:5x), from
 * `prompt.submit` before the prompt enters, for every prompt not of this plugin's: the lane note
 * goes beside the prompt (its `context`), the channel Claude Code names for text that changes from
 * turn to turn. A person's prompt closes the episode once a turn got its block (one still pending
 * goes to that prompt's turn, which ends it). A notification's task ids count as ended from now
 * on. A later prompt not of a person's, after a turn got the block, reads the lane again with the
 * units running now (no helper call: the facts are the summary's, the in-flight rows the stored
 * measure's): when it turned finished or hard-blocked, the note asks for the digest, or for one
 * line on the new state when an earlier turn already got a finished or blocked lane. No change,
 * or a change toward work: nothing is added. The note carries the Basis code renders now
 * (`laneBasis`). A prompt that then does not enter (dropped, or its hook chain threw) hands the
 * note back with `laneNoteLost`, so the next turn of the episode gets it.
 * A notification that reports a task ended is a job's result: in its turn a step held on that job
 * can run, so the lane reads working (owner 2026-10-28 digest rules (a)), and that turn's end
 * reads it again (rule (b), digest.ts `laneTurnEnd`). Once any turn of the episode was told a
 * finished or blocked lane, a note asks for one line on the new state, never a second digest.
 */
export async function laneRecheck(d: Deps, kind: string, text: string): Promise<LaneNoteSent | undefined> {
  const s = d.state
  const l = s.idleLane
  if (!l || l.closed || (await d.sessionId()) !== l.sid) return undefined
  if (isHuman(kind)) {
    l.result = false
    l.unblocked = false
    if (l.shown !== undefined) l.closed = true
    return undefined
  }
  const ended = kind === 'task-notification' ? notifiedTasks(text) : []
  for (const id of ended) l.ended.add(id)
  if (ended.length > 0) l.result = true
  if (l.shown === undefined || s.halt.active) return undefined
  const running = await runningUnits(d, l.restored ? undefined : l.remeasure, l.ended)
  const r = laneOf(l.facts, { running, midturn: false, nonok: l.nonok, driver: l.driver, superseded: l.superseded, result: l.result })
  if (r.byResult === true) l.unblocked = true
  if (r.lane === l.shown) return undefined
  const was = l.shown
  l.shown = r.lane
  await logLane(d, l.sid, l.nonce, l.facts, r, 'recheck', running)
  if (r.lane !== 'finished' && r.lane !== 'hard-blocked') return undefined
  const digested = l.digested
  l.digested = true
  // The git facts are the stored measure's (no helper call here): the Basis says when it was taken.
  const asOf = l.measuredAt !== undefined ? isoLocal(l.measuredAt, false).slice(11, 16) : undefined
  const basis = laneBasis(l.facts, running, l.remeasure, asOf)
  return { text: laneNote(d.name, r, basis, showsDigest(was) || digested, d.cfg.idle_digest === 'off'), nonce: l.nonce, was, now: r.lane, digested }
}

/** A lane note `laneRecheck` put beside a prompt: the state it told, the one before, and whether a digest had gone out before it. */
export type LaneNoteSent = { text: string; nonce: string; was: Lane | undefined; now: Lane; digested?: boolean }

/** The prompt that carried this note did not enter: the episode reads as before it, so a later turn gets the note. */
export function laneNoteLost(s: LoadState, n: LaneNoteSent): void {
  const l = s.idleLane
  if (l && l.nonce === n.nonce && !l.closed && l.shown === n.now) {
    l.shown = n.was
    if (n.digested !== undefined) l.digested = n.digested
  }
}

/**
 * A main tool call that started work (lane.ts `startsWork`) after a turn got the episode's block:
 * the summary's Status no longer describes the lane (owner xxxxxxxx-06, "cleared/superseded"), so
 * the rest of the episode reads it as working and asks for no stop.
 */
export function laneWorkStarted(s: LoadState): void {
  const l = s.idleLane
  if (l && l.shown !== undefined && !l.closed) l.superseded = true
}

/** An agent loop starts again (a message woke it): a task a notification ended runs once more. */
export function laneAgentStarted(s: LoadState, agentId: string): void {
  s.idleLane?.ended.delete(agentId)
}

/** Owner xxxxxxxx-25 ("Stop in halt"): an idle block's halt variant follows halt mode at delivery. */
function haltNow(d: Deps, a: BlockArgs): BlockArgs {
  return a.idle === true ? { ...a, halt: d.state.halt.active } : a
}

/** The held `[idle-again]` block `againFor` put beside a person's prompt, and its `idle_return` row. */
export type AgainSent = {
  text: string
  held: NonNullable<LoadState['idleAgain']>
  row: { nonce: string; age_s: number; remeasured: boolean }
}

/**
 * Owner xxxxxxxx-37 ("Full block again on return", replaces the ID-3 `[idle-return]` line): after
 * a turn not of a person's took an idle compaction's resume block, the first prompt of a person's
 * gets the full block again, always re-measured (3 s budget; when that fails, with the measure the
 * earlier delivery had and its stamp), with `[idle-again]` naming when it went out first. It goes
 * beside that prompt (`prompt.submit` context, from the hook before the prompt enters):
 * `prompt.context` is asked once per conversation, and the turn that took the block was that
 * conversation's first, so it never sees the person's prompt. A prompt not of a person's leaves it
 * held; a newer main compaction (afterStep) or the session's end drops it. The prompt that carries
 * it then logs one `idle_return {nonce, age_s, remeasured}` row and ends the idle episode
 * (`againSent`); one that does not enter hands it back (`againLost`).
 */
export async function againFor(d: Deps, kind: string, startsTurn: boolean): Promise<AgainSent | undefined> {
  const s = d.state
  const r = s.idleAgain
  if (!r || !isHuman(kind)) return undefined
  s.idleAgain = undefined
  try {
    if ((await d.sessionId()) !== r.sid) return undefined
    // Owner xxxxxxxx-25: the halt variant follows halt mode when the block is read. A person's
    // prompt that starts its own turn clears halt at that turn's start (IC-1 D6), after this hook;
    // one typed into a running turn does not.
    const args = startsTurn ? { ...r.pend.args, ...(r.pend.args.idle === true ? { halt: false } : {}) } : haltNow(d, r.pend.args)
    const out = await freshBlock(d, { ...r.pend, remeasure: r.remeasure, measuredAt: r.measuredAt }, { ...args, again: r.usedAt }, true)
    return { text: out.block, held: r, row: { nonce: r.pend.nonce, age_s: Math.round(((await d.now()) - r.usedAt) / 1000), remeasured: out.remeasured } }
  } catch {
    // Nothing went beside the prompt: the next prompt of a person's gets it.
    if (s.idleAgain === undefined) s.idleAgain = r
    return undefined
  }
}

/** The prompt that carried the block entered: its `idle_return` row; a person is back, so the idle episode ends. */
export async function againSent(d: Deps, a: AgainSent): Promise<void> {
  d.state.idleLane = undefined
  await log(d, a.held.sid, 'idle_return', a.row)
}

/** The prompt that carried the block did not enter: it stays held for the next prompt of a person's. */
export function againLost(s: LoadState, a: AgainSent): void {
  if (s.idleAgain === undefined) s.idleAgain = a.held
}

/**
 * IC-1 D3 delivery rule: a block built more than 600 s ago (an idle block is read hours later)
 * is built again with a fresh `measure --compact` (3 s budget): `resume_remeasured`; on a
 * timeout or failure the stored block goes out: `resume_remeasure_failed`. Its
 * `@measured_at@` stamp shows the age either way. `force` re-measures at any age (owner
 * xxxxxxxx-37). When `args` differ from what the block was built with (owner xxxxxxxx-25: halt
 * came or went; xxxxxxxx-37: the `[idle-again]` note), it is built again in any case, with the
 * stored measure and its own stamp when no fresh one is taken or the fresh one fails.
 */
async function freshBlock(
  d: Deps, pend: PendingResume, args: BlockArgs, force = false,
): Promise<{ block: string; remeasure: string | undefined; measuredAt: number; remeasured: boolean; lane?: LaneResult; running?: number }> {
  const t0 = await d.now()
  const ageS = Math.round((t0 - pend.builtAt) / 1000)
  // Away digest phase 1: an idle block is built again at delivery (from its stored measure, no
  // helper call), so its lane is read with the agents running now, whatever its age.
  const changed = (args.halt === true) !== (pend.args.halt === true) || args.again !== pend.args.again || args.idle === true
  const at = pend.measuredAt ?? pend.builtAt
  const stored = async () => changed
    ? { ...(await buildBlockWith(d, pend.sid, args, pend.remeasure ?? null, at)), remeasured: false }
    : { block: pend.block, remeasure: pend.remeasure, measuredAt: at, remeasured: false, ...(pend.lane !== undefined ? { lane: pend.lane } : {}) }
  if (!force && t0 - pend.builtAt <= REMEASURE_AFTER_MS) return stored()
  const fresh = await measure(d, pend.sid, pend.nonce, REMEASURE_MS, args.savedCopy ?? undefined, REMEASURE_HELPER_MS)
  if (fresh === undefined) {
    await log(d, pend.sid, 'resume_remeasure_failed', { nonce: pend.nonce, age_s: ageS })
    return stored()
  }
  const built = await buildBlockWith(d, pend.sid, args, keepGsdLines(fresh, pend.remeasure))
  await log(d, pend.sid, 'resume_remeasured', { nonce: pend.nonce, age_s: ageS, ms: (await d.now()) - t0 })
  return { ...built, remeasured: true }
}

/**
 * At a main `turn.complete`: a block still pending after a whole turn, which no channel
 * claimed, logs `resume_undelivered` and toasts.
 */
export async function undeliveredCheck(d: Deps, sid: string): Promise<void> {
  const s = d.state
  if (s.restoreClosed !== sid) {
    s.restoreClosed = sid
    // AT-RP-05: a record of this session id that the load's first main turn did not take (armed
    // after its prompt.context, or left pending by an earlier load) is never delivered later.
    await settleRecords(d, sid, n => claimedWhere(d, sid, n), s.pending?.nonce)
  }
  const pend = s.pending
  if (!pend || pend.turnSeq >= s.turnSeq) return
  s.pending = undefined
  // A block a dropped continue claimed and held for prompt.context, which did not take it.
  const claimed = await claimedElsewhere(d, pend)
  const where = pend.heldClaim === true && claimed === 'delivered:prompt.submit' ? 'undelivered' : claimed
  if (where === 'undelivered') {
    await log(d, pend.sid, 'resume_undelivered', { nonce: pend.nonce, resume_pref: pend.resumePref })
    escalate(d, 'resume-undelivered')
  }
  await logOutcome(d, pend.sid, pend.nonce, pend.outcome, where)
}

/**
 * Where a block that no mod channel delivered went: `delivered:<channel>` when a claim exists
 * (the classic SessionStart won it), else `undelivered`.
 */
export async function claimedElsewhere(d: Deps, pend: PendingResume): Promise<string> {
  return claimedWhere(d, pend.sid, pend.nonce)
}

/** `claimedElsewhere` for a session id and nonce. */
export async function claimedWhere(d: Deps, sid: string, nonce: string): Promise<string> {
  const p = await d.paths()
  const path = p ? `${p.watch}/${sid}/resume-claimed/${nonce}` : undefined
  if (!path || !(await d.exists(path))) return 'undelivered'
  const t = await d.read(path)
  return 'delivered:' + (channelToken(t?.trim().split(/\s+/)[0]) ?? 'unknown')
}

/**
 * F2-3: the mod's part of the rollup, one append-only row per compaction, written once its
 * resume block has settled (subagent compactions at once, `none-subagent`). Readers join it to
 * the rollup row by nonce; nothing is rewritten.
 */
export async function logOutcome(d: Deps, sid: string, nonce: string, o: Outcome, resume: string, actor = 'main'): Promise<void> {
  await log(d, sid, 'mod_outcome', { nonce, nudged: o.nudged, continued: o.continued, halt: o.halt, resume, ...(o.handoff ?? {}) }, actor)
  // A main block that settled is never delivered again after a restart (AT-RP-03).
  if (actor === 'main') await settlePersisted(d, sid, nonce, resume)
}

/**
 * Owner 2026-10-27 ("Fix in 0.1.1", VERSION-REFRESH tier 1): the pending main block also lives on
 * disk, so a session that exits or restarts between a compaction and its next turn gets it after
 * `claude --resume` of the same session id. The after-step writes `<watch>/<sid>/resume-pending.json`
 * (the helper's vetted watch only, as the summary stash; kept with the session's folder): the
 * facts the block is built from, not its text. The classic SessionStart with `source=resume`
 * renames a pending record of its own session id to `resume-armed.json` when no other process of
 * that session id runs (one process wins the rename). The first `prompt.context` of that session
 * id in a load takes an armed record as the pending block, built again by this load (its assets,
 * its `<store>` path, the stricter `[prod-*]` view): the usual claim, the 600 s re-measure rule and
 * one `mod_outcome` row. Every settle (delivered, replaced by a newer compaction, undelivered,
 * dropped by `/clear`) rewrites the record as settled, which drops the measured facts; the first
 * main turn end of a load settles a record it did not take, so it never reaches a later turn. A
 * `/clear` or a fork has another session id, so it never matches.
 */
export const PENDING_FILE = 'resume-pending.json'
export const ARMED_FILE = 'resume-armed.json'

/** The record a pending block is persisted as (AT-RP-01). Times in `$.clock.now()` milliseconds. */
export type PendingRecord = {
  v: 1
  state: 'pending'
  session_id: string
  nonce: string
  built_at: number
  measured_at: number | null
  load_id: string
  args: BlockArgs
  remeasure: string | null
  outcome: Outcome
}

/** The record for a pending block (the one shape the after-step writes and a restore reads). */
export function pendingRecord(p: PendingResume, loadId: string): PendingRecord {
  return {
    v: 1, state: 'pending', session_id: p.sid, nonce: p.nonce, built_at: p.builtAt, measured_at: p.measuredAt ?? null, load_id: loadId,
    args: p.args, remeasure: p.remeasure ?? null, outcome: p.outcome,
  }
}

async function recordPath(d: Deps, sid: string, file: string): Promise<string | undefined> {
  const w = await vettedWatch(d, sid)
  return w === undefined ? undefined : `${w}/${sid}/${file}`
}

/** Writes this pending block's record; false when there is no vetted watch or the write failed. */
export async function persistPending(d: Deps, p: PendingResume): Promise<boolean> {
  const path = await recordPath(d, p.sid, PENDING_FILE)
  return path !== undefined && (await d.write(path, JSON.stringify(pendingRecord(p, d.state.loadId)) + '\n'))
}

function parseRecord(t: string | undefined): Record<string, unknown> | undefined {
  if (t === undefined) return undefined
  try {
    const j = JSON.parse(t) as unknown
    return j !== null && typeof j === 'object' && !Array.isArray(j) ? (j as Record<string, unknown>) : undefined
  } catch {
    return undefined
  }
}

/** Rewrites a still-pending record of this nonce (pending or armed) as settled: no measured facts are kept. */
export async function settlePersisted(d: Deps, sid: string, nonce: string, resume: string): Promise<void> {
  for (const file of [PENDING_FILE, ARMED_FILE]) {
    const path = await recordPath(d, sid, file)
    if (path === undefined) return
    const j = parseRecord(await d.read(path))
    if (!j || j.state !== 'pending' || j.nonce !== nonce) continue
    await d.write(path, JSON.stringify({ v: 1, state: 'settled', session_id: sid, nonce, resume, ts: isoLocal(await d.now(), false) }) + '\n')
  }
}

/**
 * Settles every still-pending record of this session id (pending and armed) whose nonce is not
 * `except`, with one `mod_outcome` row each (`resume(nonce)` names how it settled): a newer
 * compaction replaced it, a `/clear` dropped it, or a turn end passed it by.
 */
export async function settleRecords(d: Deps, sid: string, resume: (nonce: string) => Promise<string>, except?: string): Promise<void> {
  const done = new Set<string>()
  for (const file of [PENDING_FILE, ARMED_FILE]) {
    const path = await recordPath(d, sid, file)
    if (path === undefined) return
    const j = parseRecord(await d.read(path))
    if (!j || j.state !== 'pending' || j.session_id !== sid) continue
    const nonce = j.nonce
    if (typeof nonce !== 'string' || !NONCE_RE.test(nonce) || nonce === except || done.has(nonce)) continue
    done.add(nonce)
    const o = isOutcome(j.outcome) ? j.outcome : { nudged: false, continued: false, halt: false }
    await logOutcome(d, sid, nonce, o, await resume(nonce))
  }
}

const NONCE_RE = /^[0-9a-f]{8}$/

function isArgs(a: unknown): a is BlockArgs {
  if (a === null || typeof a !== 'object') return false
  const o = a as Record<string, unknown>
  return typeof o.midturn === 'boolean' && typeof o.nonok === 'boolean' && (o.savedCopy === null || typeof o.savedCopy === 'string')
    && (o.notSaved === undefined || typeof o.notSaved === 'string')
    && (o.handoff === undefined || (o.handoff !== null && typeof o.handoff === 'object'))
}

function isOutcome(o: unknown): o is Outcome {
  if (o === null || typeof o !== 'object') return false
  const r = o as Record<string, unknown>
  return typeof r.nudged === 'boolean' && typeof r.continued === 'boolean' && typeof r.halt === 'boolean'
}

/**
 * The armed record of this session id as a pending block (AT-RP-02), or undefined: none, settled,
 * another session's, or not of the shape `pendingRecord` writes. Its age counts from `built_at`.
 * The block is built again here from the stored facts (no new measure; the stored `@measured_at@`),
 * so a restart that picked up a plugin update never gets the old version's text or `<store>`
 * path, and `[prod-allow]` stays only when this load's option still allows it (MOD-SPEC §3.4
 * step 4: the stricter view wins).
 */
export async function restorePending(d: Deps, sid: string): Promise<PendingResume | undefined> {
  const path = await recordPath(d, sid, ARMED_FILE)
  if (path === undefined) return undefined
  const j = parseRecord(await d.read(path))
  if (!j || j.v !== 1 || j.state !== 'pending' || j.session_id !== sid) return undefined
  const { nonce, built_at: builtAt, measured_at: measuredAt, args, remeasure, outcome } = j
  if (typeof nonce !== 'string' || !NONCE_RE.test(nonce) || typeof builtAt !== 'number') return undefined
  if (!isArgs(args) || !isOutcome(outcome) || args.nonce !== nonce) return undefined
  // Lane facts not of the shape this build reads (an older or damaged record): none (the lane reads working).
  const facts = asLaneFacts(args.lane)
  const a: BlockArgs = { ...args, prodAllow: args.prodAllow === true && d.cfg.unattended_prod_reads === 'allow' }
  if (facts !== undefined) a.lane = facts
  else delete a.lane
  const at = typeof measuredAt === 'number' ? measuredAt : builtAt
  const built = await buildBlockWith(d, sid, a, typeof remeasure === 'string' ? remeasure : null, at)
  return {
    sid, nonce, block: built.block, builtAt, args: a, resumePref: 'prompt.context', turnSeq: d.state.turnSeq, outcome, persisted: true,
    ...(built.remeasure !== undefined ? { remeasure: built.remeasure } : {}),
    measuredAt: at,
  }
}
