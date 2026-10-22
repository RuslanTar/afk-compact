// The resume block (MOD-SPEC §3.4): built after a main compaction, delivered once by the first
// channel whose claim wins. The mod's channels are `prompt.context` (order 2) and the continue
// text (order 3, cont.ts); classic SessionStart (order 1) is the helper's.
import type { Deps, Outcome, PendingResume } from './deps'
import { storeWord } from './deps'
import type { Runtime, Tag } from './assemble'
import { assemble } from './assemble'
import type { RaceBlock } from './handoff-turn'
import { channelToken, claimBy, measure } from './helper'
import { escalate, helperMissing, isoLocal, log } from './log'

/** MOD-SPEC §3.4: total ≤6,000 chars (DP-8; never >10,000, the SessionStart cutoff). */
export const BLOCK_MAX = 6000

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
}

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

export async function buildBlock(d: Deps, sid: string, a: BlockArgs): Promise<string> {
  const tags: Tag[] = []
  if (a.midturn) tags.push('midturn')
  if (a.nonok) tags.push('nonok')
  // Exactly one of the two step-4 lines (BLD-04 exclusive group).
  tags.push(a.prodAllow === true ? 'prod-allow' : 'prod-forbid')
  const remeasure = await measure(d, sid, a.nonce)
  const measuredAt = isoLocal(await d.now(), false)
  const saved = a.savedCopy ?? `not saved (${a.notSaved ?? 'unknown'})`
  const store = storeRuntime(d)
  const runtime: Runtime = { session_id: sid, saved_copy: saved, measured_at: measuredAt, ...store.runtime }
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
  if (remeasure === undefined) return assemble(d.name, 'resume-context', tags, runtime, ['remeasure', ...store.drop])
  const lines = remeasure.split('\n')
  let block = assemble(d.name, 'resume-context', tags, { ...runtime, remeasure }, store.drop)
  for (let keep = lines.length - 1; block.length > BLOCK_MAX && keep >= 0; keep--) {
    const cut = lines.slice(0, keep).concat(`(+${lines.length - keep} lines)`).join('\n')
    block = assemble(d.name, 'resume-context', tags, { ...runtime, remeasure: cut }, store.drop)
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
  const pend = s.pending
  if (!pend || pend.sid !== sid || pend.resumePref === 'none') return undefined
  const c = await claimBy(d, sid, pend.nonce, 'prompt.context')
  s.pending = undefined
  if (c.result === 'TAKEN') {
    await logOutcome(d, pend.sid, pend.nonce, pend.outcome, 'delivered:' + (c.by ?? 'unknown'))
    return undefined
  }
  if (c.result === 'failed') await helperMissing(d, sid, 'claim')
  await logOutcome(d, pend.sid, pend.nonce, pend.outcome, 'delivered:prompt.context')
  return pend.block
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
