// The resume block (MOD-SPEC §3.4): built after a main compaction, delivered once by the first
// channel whose claim wins. The mod's channels are `prompt.context` (order 2) and the continue
// text (order 3, cont.ts); classic SessionStart (order 1) is the helper's.
import type { Deps } from './deps'
import type { Tag } from './assemble'
import { assemble } from './assemble'
import { claim, measure } from './helper'
import { escalate, helperMissing, isoLocal, log } from './log'

/** MOD-SPEC §3.4: total ≤5,000 chars. */
export const BLOCK_MAX = 5000

export type BlockArgs = {
  /** This compaction's dispatch nonce (the re-measure reads its evidence). */
  nonce?: string
  midturn: boolean
  nonok: boolean
  /** Path of this compaction's copy, or null with `notSaved` as the reason. */
  savedCopy: string | null
  notSaved?: string
}

export async function buildBlock(d: Deps, sid: string, a: BlockArgs): Promise<string> {
  const tags: Tag[] = []
  if (a.midturn) tags.push('midturn')
  if (a.nonok) tags.push('nonok')
  const remeasure = await measure(d, sid, a.nonce)
  const measuredAt = isoLocal(await d.now(), false)
  const saved = a.savedCopy ?? `not saved (${a.notSaved ?? 'unknown'})`
  const runtime = { session_id: sid, saved_copy: saved, measured_at: measuredAt }
  if (remeasure === undefined) return assemble(d.name, 'resume-context', tags, runtime, ['remeasure'])
  const lines = remeasure.split('\n')
  let block = assemble(d.name, 'resume-context', tags, { ...runtime, remeasure })
  for (let keep = lines.length - 1; block.length > BLOCK_MAX && keep >= 0; keep--) {
    const cut = lines.slice(0, keep).concat(`(+${lines.length - keep} lines)`).join('\n')
    block = assemble(d.name, 'resume-context', tags, { ...runtime, remeasure: cut })
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
  const c = await claim(d, sid, pend.nonce, 'prompt.context')
  s.pending = undefined
  if (c === 'TAKEN') return undefined
  if (c === 'failed') await helperMissing(d, sid, 'claim')
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
  const p = await d.paths()
  if (p && (await d.exists(`${p.watch}/${pend.sid}/resume-claimed/${pend.nonce}`))) return
  await log(d, pend.sid, 'resume_undelivered', { nonce: pend.nonce, resume_pref: pend.resumePref })
  escalate(d, 'resume-undelivered')
}
