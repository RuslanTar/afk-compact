// The `session.compact` handler, steps 0–5 (MOD-SPEC §3.1), the dispatch record (§2.3) and the
// after-step (§5.2), shared with the boundary self-call path (§4).
import type { SessionCompactInput, SessionCompactResult, SessionMessage } from 'claude-code'
import type { Deps, PendingResume } from './deps'
import type { Tag } from './assemble'
import type { Trigger } from './canary'
import type { Verdict } from './detect'
import { assemble } from './assemble'
import { keysetCanary, triggerCanary } from './canary'
import { countVerdict } from './cont'
import { detectSummary, isOk, lastInstrMarker } from './detect'
import type { RaceBlock } from './handoff-turn'
import { raceBlock, racedTurn } from './handoff-turn'
import type { HandoffState } from './helper'
import { checkpoint, dispatch, failClass, handoffState, handoffTurnSupersede, prevCopy, saveCopy, sweep } from './helper'
import { escalate, helperMissing, isoLocal, log, skipClass, toastOnce, vettedWatch } from './log'
import { drawNonce } from './nonce'
import { byteLength, sha8 } from './normalize'
import { buildBlock, claimedElsewhere, logOutcome } from './resume'

export type ResumePref = 'prompt.context' | 'sessionstart' | 'prompt.submit' | 'none'

export type DispatchRecord = {
  sid: string
  nonce: string
  agentId: string | null
  trigger: Trigger
  channel: 'mod-hook' | 'mod-self'
  resumePref: ResumePref
  midturn: boolean
  tags: readonly Tag[]
  text: string
  /** MOD-SPEC §2.3: the handoff turn this dispatch follows or interrupts. */
  handoffHt?: string
}

async function dispatchPath(d: Deps, sid: string, nonce: string): Promise<string | undefined> {
  const p = await d.paths()
  return p ? `${p.watch}/${sid}/dispatch/${nonce}.json` : undefined
}

/** A dispatch record with this nonce exists (the nonce redraw check). */
export async function dispatchExists(d: Deps, sid: string, nonce: string): Promise<boolean> {
  if (d.state.selfNonces.has(nonce)) return true
  const path = await dispatchPath(d, sid, nonce)
  return path !== undefined && (await d.exists(path))
}

/** The nonce has a `mod-self` record: this load's own, or one on disk. */
export async function isSelfDispatch(d: Deps, sid: string, nonce: string): Promise<boolean> {
  if (d.state.selfNonces.has(nonce)) return true
  const path = await dispatchPath(d, sid, nonce)
  if (!path) return false
  const t = await d.read(path)
  if (t === undefined) return false
  try {
    return (JSON.parse(t) as { channel?: unknown }).channel === 'mod-self'
  } catch {
    return false
  }
}

/** Writes the dispatch record through the helper, else the same JSON with `$.fs.write`. */
export async function writeDispatch(d: Deps, r: DispatchRecord): Promise<void> {
  const s = d.state
  const instrSha8 = sha8(r.text)
  const instrBytes = byteLength(r.text)
  const res = await dispatch(d, {
    sid: r.sid, nonce: r.nonce, actor: r.agentId ?? 'main', trigger: r.trigger, channel: r.channel,
    resumePref: r.resumePref, tags: r.tags, midturn: r.midturn, instrSha8, instrBytes, ccVersion: s.ccVersion, loadId: s.loadId,
    ...(r.handoffHt !== undefined ? { handoffHt: r.handoffHt } : {}),
  })
  if (res.ok) return
  const path = await dispatchPath(d, r.sid, r.nonce)
  if (path) {
    const rec = {
      v: 1, nonce: r.nonce, session_id: r.sid, actor: r.agentId ?? 'main', agent_id: r.agentId, trigger: r.trigger,
      channel: r.channel, resume_pref: r.resumePref, midturn: r.midturn, tags: r.tags, instructions_sha8: instrSha8,
      instructions_bytes: instrBytes, cc_version: s.ccVersion, load_id: s.loadId, pid: s.ident?.pid ?? null,
      pid_lstart: s.ident?.pid_lstart ?? null, ts: isoLocal(await d.now(), false),
      ...(r.handoffHt !== undefined ? { handoff_ht: r.handoffHt } : {}),
    }
    await d.write(path, JSON.stringify(rec) + '\n')
  }
  await helperMissing(d, r.sid, 'dispatch')
  await log(d, r.sid, 'dispatch', {
    nonce: r.nonce, trigger: r.trigger, agent_id: r.agentId, channel: r.channel, instructions_bytes: instrBytes,
    fallback: true, error_class: failClass(res),
  }, r.agentId ?? 'main')
}

export type MainText = { text: string; tags: Tag[] }

/**
 * The main text for a dispatch: `[midturn]` when asked, `[chain]` when `prev-copy` returns a
 * path, `[measured]` when the checkpoint returned a measured block, `[handoff]` with its path
 * when a handoff turn published one just before (MOD-SPEC §9.1; mod path only).
 */
export async function mainText(
  d: Deps, nonce: string, midturn: boolean, prev: string | undefined, measured: string | null, handoffPath?: string,
): Promise<MainText> {
  const tags: Tag[] = []
  if (midturn) tags.push('midturn')
  if (prev !== undefined) tags.push('chain')
  if (handoffPath !== undefined) tags.push('handoff')
  if (measured !== null) tags.push('measured')
  const runtime = {
    nonce, previous_copy: prev, measured_at: isoLocal(await d.now(), false), measured_facts: measured ?? undefined, handoff_path: handoffPath,
  }
  return { text: assemble(d.name, 'handoff-instructions', tags, runtime), tags }
}

type Next = (e: SessionCompactInput) => Promise<SessionCompactResult>

/**
 * CR-F19: a main compaction other than ours (not `precompute`) counts as running from the moment
 * its `session.compact` hook is entered, before any await, to the end of our handling of it.
 * Meanwhile a post-handoff compaction waits (boundary.ts); the last one to end hands it back to
 * the scheduler, where `nativeCompactSeq` decides whether it is a second one.
 */
export async function trackNative(d: Deps, e: SessionCompactInput, run: () => Promise<SessionCompactResult>): Promise<SessionCompactResult> {
  const s = d.state
  if (e.agentId !== undefined || e.trigger === 'precompute') return run()
  s.nativeCompacting++
  try {
    return await run()
  } finally {
    s.nativeCompacting = Math.max(0, s.nativeCompacting - 1)
    if (s.nativeCompacting === 0) {
      const resume = s.afterNative
      s.afterNative = undefined
      resume?.()
    }
  }
}

/** MOD-SPEC §3.1: the `session.compact` handler. */
export async function onCompact(d: Deps, sid: string, e: SessionCompactInput, next: Next): Promise<SessionCompactResult> {
  const s = d.state
  // Step 0: our marker with a mod-self record = our own self-call reached our hook. The row is
  // a drift canary, once per Claude Code version (kept in $.store across loads).
  const mark = lastInstrMarker(e.instructions, d.name)
  if (mark && (await isSelfDispatch(d, sid, mark.nonce))) {
    const v = s.ccVersion ?? 'unknown'
    if (!s.selfCallLoggedFor.has(v) && (await d.storeGet('selfcall:' + v)) === undefined) {
      s.selfCallLoggedFor.add(v)
      await d.storeSet('selfcall:' + v, true)
      await log(d, sid, 'self_call_hook_ran', { nonce: mark.nonce })
      escalate(d, 'self-call-hook-ran')
    }
    return next(e)
  }
  const trigger = await triggerCanary(d, sid, e.trigger)
  await keysetCanary(d, sid, e)
  const agentId = e.agentId ?? null
  const main = agentId === null
  const actor = agentId ?? 'main'
  const nonce = await drawNonce(n => dispatchExists(d, sid, n))
  const midturn = main && (trigger === 'precompute' || (trigger === 'auto' && s.mainTurnRunning))
  // MOD-SPEC §9.1 race: a native compaction while the handoff turn runs keeps the full text and
  // names the turn; §3.1: a native idle auto right after a published handoff gets `[handoff]`.
  const raced = main ? racedTurn(d, trigger) : undefined
  const after = main && trigger === 'auto' && !s.mainTurnRunning ? s.published : undefined
  const handoffHt = raced?.ht ?? after?.ht ?? undefined
  let raceState: HandoffState | undefined
  if (raced && raced.ht !== null && trigger === 'auto') raceState = await handoffState(d, sid, raced.ht)
  let text: string
  let tags: Tag[] = []
  if (!main) text = assemble(d.name, 'subagent-instructions', [], { nonce })
  else {
    const prev = await prevCopy(d, sid)
    let measured: string | null = null
    if (trigger === 'manual' || trigger === 'auto') {
      const wantMeasured = d.cfg.measured_block
      const cp = await checkpoint(d, sid, nonce, wantMeasured)
      if (wantMeasured && cp) measured = cp.measured_block
    }
    const m = await mainText(d, nonce, midturn, prev, measured, after?.path)
    text = m.text
    tags = m.tags
  }
  await writeDispatch(d, {
    sid, nonce, agentId, trigger, channel: 'mod-hook', resumePref: main ? 'prompt.context' : 'none', midturn, tags, text,
    ...(handoffHt !== undefined ? { handoffHt } : {}),
  })
  const t0 = await d.now()
  const r = await next({ ...e, instructions: [e.instructions, text].filter(Boolean).join('\n\n') })
  if (r.skip !== undefined) {
    await log(d, sid, 'compacted', { nonce, skip: skipClass(r.skip), tokens_before: null, tokens_after: null, usage_present: false, ms: (await d.now()) - t0 }, actor)
    return r
  }
  if (trigger === 'precompute') {
    await log(d, sid, 'precompute_dispatched', { nonce }, actor)
    return r
  }
  // The post-handoff compaction scheduled before this one is now a second one (boundary.ts).
  if (main) s.nativeCompactSeq++
  await log(d, sid, 'compacted', {
    nonce, skip: null, tokens_before: r.tokensBefore ?? null, tokens_after: r.tokensAfter ?? null,
    usage_present: r.usage !== undefined, ms: (await d.now()) - t0, ...(handoffHt !== undefined ? { handoff_ht: handoffHt } : {}),
  }, actor)
  // §9.1: a compaction after the nudge already shrank the context the handoff turn would use.
  if (main && s.mainTurnRunning && s.nudgedThisTurn) s.compactedInTurn = s.turnSeq
  let block: RaceBlock | undefined
  if (raced && raced.ht !== null && raceState) {
    // The plugin compaction for this ht is dropped; the next window gets the finish command.
    raced.race = { nonce, trigger }
    await handoffTurnSupersede(d, sid, raced.ht, nonce)
    await log(d, sid, 'handoff_race', {
      trigger, draft: raceState.state === 'staged' && raceState.draft, published: raceState.state === 'published', ht: raced.ht,
    })
    block = await raceBlock(d, raceState)
  }
  await guarded(d, sid, 'after-step', () => afterStep(d, {
    sid, nonce, agentId, midturn, resumePref: 'prompt.context', messages: r.messages, tokensBefore: r.tokensBefore, tokensAfter: r.tokensAfter,
    ...(block !== undefined ? { handoff: block } : after !== undefined ? { handoff: { published: after.path } } : {}),
    ...(raced && raced.ht !== null && block !== undefined ? { stats: { handoff_turn: 'race', handoff_ht: raced.ht } } : {}),
  }))
  return r
}

/** Runs one step; an internal error becomes one `watch_error {stage, error_class}` row. */
export async function guarded(d: Deps, sid: string, stage: string, fn: () => Promise<unknown>): Promise<void> {
  try {
    await fn()
  } catch (err) {
    const cls = err instanceof Error ? err.name : typeof err
    await log(d, sid, 'watch_error', { stage, error_class: cls.slice(0, 40) }).catch(() => undefined)
  }
}

export type AfterArgs = {
  sid: string
  nonce: string
  agentId: string | null
  midturn: boolean
  resumePref: ResumePref
  messages: readonly SessionMessage[]
  tokensBefore: number | undefined
  tokensAfter: number | undefined
  /** The resume block's `[handoff]` path, or `[handoff-partial]` after a race (MOD-SPEC §3.4). */
  handoff?: RaceBlock
  /** The handoff-turn rollup fields for this compaction's `mod_outcome` row (MOD-SPEC §2.5). */
  stats?: Record<string, string | number | null>
}

export const SUMMARY_PREFIX = 'This session is being continued'

/** MOD-SPEC §5.2: the after-step, main and subagent. */
export async function afterStep(d: Deps, a: AfterArgs): Promise<{ verdict: Verdict }> {
  const s = d.state
  const main = a.agentId === null
  const actor = a.agentId ?? 'main'
  const summary = a.messages.find(m => m.role === 'user' && m.text.startsWith(SUMMARY_PREFIX))
  let verdict: Verdict = 'unshaped'
  let savedCopy: string | null = null
  let notSaved: string | undefined
  let chars = 0
  // PRIV-04: the raw summary is stashed only under the watch folder the helper vetted (ident);
  // refused (null) or unknown (no helper answer) means no stash, never the options' folder.
  const stash = await vettedWatch(d, a.sid)
  const p = await d.paths()
  if (!summary) {
    notSaved = 'summary-not-found'
    await log(d, a.sid, 'copy_failed', { nonce: a.nonce, reason: notSaved }, actor)
    escalate(d, 'copy-failed')
  } else {
    const det = detectSummary(summary.text, d.name, { dispatchNonce: a.nonce, scope: main ? 'main' : 'sub' })
    verdict = det.verdict
    chars = det.normalized.length
    const file = stash !== undefined ? `${stash}/${a.sid}/pending/${a.nonce}.mod.md` : undefined
    // MOD-SPEC §5.8 item 4: the orphan index marker goes first, so a stash this session leaves
    // behind is found by another session's cross-session finish. Empty; an existing one is fine.
    // The `pending/` folder stays the truth: a failed marker write does not stop the stash.
    if (file && stash !== undefined) await d.write(`${stash}/.orphans/${a.sid}`, '')
    if (!file || !(await d.write(file, summary.text))) {
      notSaved = file ? 'pending-write-failed' : s.ident?.watch === null ? 'unsafe-root' : 'helper-missing'
      await log(d, a.sid, 'copy_failed', { nonce: a.nonce, reason: notSaved }, actor)
      escalate(d, 'copy-failed')
    } else {
      const sr = await saveCopy(d, {
        sid: a.sid, nonce: a.nonce, from: file, scope: main ? 'main' : 'sub', agent: a.agentId ?? undefined,
        tokens: { before: a.tokensBefore, after: a.tokensAfter },
      })
      if (sr.verdict !== null && isVerdict(sr.verdict)) verdict = sr.verdict
      if (sr.kind === 'saved') savedCopy = sr.path
      else if (sr.kind === 'exists-match') {
        savedCopy = sr.path
        await log(d, a.sid, 'copy_exists', { nonce: a.nonce }, actor)
      } else if (sr.kind === 'exists-differs') {
        savedCopy = sr.path
        await log(d, a.sid, 'copy_mismatch', { nonce: a.nonce }, actor)
        escalate(d, 'copy-mismatch')
      } else {
        notSaved = sr.reason ?? 'unknown'
        await log(d, a.sid, 'copy_failed', { nonce: a.nonce, reason: notSaved.slice(0, 40) }, actor)
        escalate(d, 'copy-failed')
        if (sr.kind === 'failed') await helperMissing(d, a.sid, 'save-copy')
      }
    }
    if (main && p && !(await d.exists(`${p.watch}/${a.sid}/swept/${a.nonce.slice(0, 6)}`))) await sweep(d, a.sid, a.nonce)
  }
  if (!main) {
    await logOutcome(d, a.sid, a.nonce, { nudged: false, continued: false, halt: s.halt.active }, 'none-subagent', actor)
    return { verdict }
  }
  if (s.mainCompactionsSid !== a.sid) {
    s.mainCompactionsSid = a.sid
    s.mainCompactions = 0
    s.fourthToasted = false
  }
  s.mainCompactions++
  // A published handoff names the next window's compaction once (MOD-SPEC §3.1).
  s.published = undefined
  const block = await buildBlock(d, a.sid, {
    nonce: a.nonce, midturn: a.midturn, nonok: !isOk(verdict), savedCopy, notSaved, ...(a.handoff !== undefined ? { handoff: a.handoff } : {}),
  })
  // A block still pending is replaced by this one: its outcome is settled now (no channel
  // will try it again).
  const old = s.pending
  if (old) {
    s.pending = undefined
    await logOutcome(d, old.sid, old.nonce, old.outcome, await claimedElsewhere(d, old))
  }
  const pend: PendingResume = {
    sid: a.sid, nonce: a.nonce, block, resumePref: a.resumePref, turnSeq: s.turnSeq,
    outcome: { nudged: s.nudgedThisTurn, continued: false, halt: s.halt.active, ...(a.stats !== undefined ? { handoff: a.stats } : {}) },
  }
  s.pending = pend
  if (!isOk(verdict)) toastOnce(d, 'nonok:' + a.nonce, `${d.name}: compaction summary not in handoff format (${verdict}); the resume block adds a fallback note.`)
  if (!s.fourthToasted && (s.mainCompactions >= 4 || chars > 12000)) {
    s.fourthToasted = true
    d.toast(`${d.name}: 4 compactions in this session; consider /${d.name}:handoff and a fresh session.`)
  }
  await countVerdict(d, a.sid, isOk(verdict))
  pend.outcome.halt = s.halt.active
  return { verdict }
}

const VERDICTS: readonly string[] = ['stale', 'scope-leak', 'unshaped', 'truncated', 'ok-trailer', 'ok']

function isVerdict(v: string): v is Verdict {
  return VERDICTS.includes(v)
}
