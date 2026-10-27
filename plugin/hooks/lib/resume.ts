// The resume block (MOD-SPEC §3.4): built after a main compaction, delivered once by the first
// channel whose claim wins. The mod's channels are `prompt.context` (order 2) and the continue
// text (order 3, cont.ts); classic SessionStart (order 1) is the helper's. One exception (owner
// xxxxxxxx-37, "Full block again on return"): when a background result's turn took an idle
// compaction's block, the first human-origin prompt gets the full block again, re-measured, with
// `[idle-again]` noting the earlier use.
import type { Deps, Outcome, PendingResume } from './deps'
import { isHuman, storeWord } from './deps'
import type { Runtime, Tag } from './assemble'
import { assemble } from './assemble'
import type { RaceBlock } from './handoff-turn'
import { channelToken, claimBy, measure } from './helper'
import { escalate, helperMissing, isoLocal, log } from './log'

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
  /** `[handoff]` (a published handoff of this window) or `[handoff-partial]` (a raced handoff turn). */
  handoff?: RaceBlock
  /** `[prod-allow]` instead of `[prod-forbid]` (see `prodAllowed`). */
  prodAllow?: boolean
  /** An idle compaction: `[idle]` (IC-1 D3), never with `[midturn]`. */
  idle?: boolean
  /** Owner xxxxxxxx-25 ("Stop in halt"): halt mode is on, so an idle block gets `[idle-halt]` instead of `[idle]`. */
  halt?: boolean
  /** Owner xxxxxxxx-37: a background result's turn took this idle block at this time; `[idle-again]` says so. */
  again?: number
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
): Promise<{ block: string; remeasure: string | undefined; measuredAt: number }> {
  const tags: Tag[] = []
  if (a.midturn) tags.push('midturn')
  if (a.nonok) tags.push('nonok')
  // Owner xxxxxxxx-25: in halt mode the idle line stops after the background result.
  if (a.idle === true && !a.midturn) tags.push(a.halt === true ? 'idle-halt' : 'idle')
  if (a.idle === true && !a.midturn && a.again !== undefined) tags.push('idle-again')
  // Exactly one of the two step-4 lines (BLD-04 exclusive group).
  tags.push(a.prodAllow === true ? 'prod-allow' : 'prod-forbid')
  // AP-5: the saved copy goes with the re-measure, so the summary's approvals are checked.
  const remeasure = fresh === null ? undefined : fresh ?? (await measure(d, sid, a.nonce, undefined, a.savedCopy ?? undefined))
  // Owner 2026-10-26 (GSD re-entry per session): the re-enter line only beside a measured driver,
  // never in a halted idle block ([idle-halt] stops and waits for the user; EXCLUSIVE in tools/assemble).
  if (remeasure !== undefined && DRIVER_LINE.test(remeasure) && !tags.includes('idle-halt')) tags.push('driver')
  const measuredAt = at ?? (await d.now())
  const saved = a.savedCopy ?? `not saved (${a.notSaved ?? 'unknown'})`
  const store = storeRuntime(d)
  const runtime: Runtime = { session_id: sid, saved_copy: saved, measured_at: isoLocal(measuredAt, false), ...store.runtime }
  if (a.again !== undefined) runtime.idle_used_at = isoLocal(a.again, false)
  const h = a.handoff
  if (h && 'published' in h) {
    tags.push('handoff')
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
  return { block, remeasure, measuredAt }
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
  const again = await againBlock(d, sid)
  if (again !== undefined) return again
  const pend = s.pending
  if (!pend || pend.sid !== sid || pend.resumePref === 'none') return undefined
  const c = await claimBy(d, sid, pend.nonce, 'prompt.context')
  s.pending = undefined
  if (c.result === 'TAKEN') {
    await logOutcome(d, pend.sid, pend.nonce, pend.outcome, 'delivered:' + (c.by ?? 'unknown'))
    return undefined
  }
  if (c.result === 'failed') await helperMissing(d, sid, 'claim')
  const args = haltNow(d, pend.args)
  const out = await freshBlock(d, pend, args)
  await logOutcome(d, pend.sid, pend.nonce, pend.outcome, 'delivered:prompt.context')
  // Owner xxxxxxxx-37: a background result (not a person) took an idle compaction's block; the
  // first human-origin prompt gets it again.
  if (pend.args.idle === true && !isHuman(s.turnOrigin)) {
    s.idleAgain = { sid, pend: { ...pend, args }, usedAt: await d.now(), remeasure: out.remeasure, measuredAt: out.measuredAt }
  }
  return out.block
}

/** Owner xxxxxxxx-25 ("Stop in halt"): an idle block's halt variant follows halt mode at delivery. */
function haltNow(d: Deps, a: BlockArgs): BlockArgs {
  return a.idle === true ? { ...a, halt: d.state.halt.active } : a
}

/**
 * Owner xxxxxxxx-37 ("Full block again on return", replaces the ID-3 `[idle-return]` line): after
 * a turn not of a person's took an idle compaction's resume block, the first human-origin turn
 * gets the full block again, always re-measured (3 s budget; when that fails, with the measure the
 * earlier delivery had and its stamp), with `[idle-again]` naming when it went out first. One
 * `idle_return {nonce, age_s, remeasured}` row. A turn not of a person's leaves it held; a newer
 * main compaction (afterStep) or the session's end drops it.
 */
async function againBlock(d: Deps, sid: string): Promise<string | undefined> {
  const s = d.state
  const r = s.idleAgain
  if (!r || !isHuman(s.turnOrigin)) return undefined
  s.idleAgain = undefined
  if (r.sid !== sid) return undefined
  const out = await freshBlock(d, { ...r.pend, remeasure: r.remeasure, measuredAt: r.measuredAt }, { ...haltNow(d, r.pend.args), again: r.usedAt }, true)
  await log(d, sid, 'idle_return', { nonce: r.pend.nonce, age_s: Math.round(((await d.now()) - r.usedAt) / 1000), remeasured: out.remeasured })
  return out.block
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
): Promise<{ block: string; remeasure: string | undefined; measuredAt: number; remeasured: boolean }> {
  const t0 = await d.now()
  const ageS = Math.round((t0 - pend.builtAt) / 1000)
  const changed = (args.halt === true) !== (pend.args.halt === true) || args.again !== pend.args.again
  const at = pend.measuredAt ?? pend.builtAt
  const stored = async () => changed
    ? { ...(await buildBlockWith(d, pend.sid, args, pend.remeasure ?? null, at)), remeasured: false }
    : { block: pend.block, remeasure: pend.remeasure, measuredAt: at, remeasured: false }
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
  const pend = s.pending
  if (!pend || pend.turnSeq >= s.turnSeq) return
  s.pending = undefined
  const where = await claimedElsewhere(d, pend)
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
  const p = await d.paths()
  const path = p ? `${p.watch}/${pend.sid}/resume-claimed/${pend.nonce}` : undefined
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
}
