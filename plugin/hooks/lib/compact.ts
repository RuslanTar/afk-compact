// The `session.compact` handler, steps 0–5 (MOD-SPEC §3.1), the dispatch record (§2.3) and the
// after-step (§5.2), shared with the boundary self-call path (§4).
import type { SessionCompactInput, SessionCompactResult, SessionMessage } from 'claude-code'
import type { Deps, PendingResume, RequestUsage } from './deps'
import { prefixRead, uncoveredInput } from './deps'
import type { Tag } from './assemble'
import type { Trigger } from './canary'
import type { Verdict } from './detect'
import { assemble } from './assemble'
import { keysetCanary, triggerCanary } from './canary'
import { expand } from './config'
import { countVerdict } from './cont'
import { detectSummary, isOk, lastInstrMarker } from './detect'
import type { RaceBlock } from './handoff-turn'
import { raceBlock, racedTurn } from './handoff-turn'
import type { HandoffState } from './helper'
import { checkpoint, dispatch, failClass, handoffState, handoffTurnSupersede, prevCopy, saveCopy, sweep } from './helper'
import { escalate, helperMissing, isoLocal, log, skipClass, toastOnce, vettedWatch } from './log'
import { drawNonce } from './nonce'
import { carriedQuestion } from './question'
import { byteLength, sha8 } from './normalize'
import type { BlockArgs } from './resume'
import { buildBlockWith, claimedElsewhere, claimedWhere, logLane, logOutcome, openEpisode, persistPending, prodAllowed, settleRecords } from './resume'
import type { LaneFacts } from './lane'
import { laneFacts, measuredRunning } from './lane'
import { armDigest } from './digest'
import { shadowPrepM3, startShadow } from './shadow'
import { restartMoment } from './restart'

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
  /** IC-1 D1: an idle dispatch (`idle: true`), with the gap since the last main turn end. */
  idle?: { gapS: number }
}

/** IC-1 D1: an `auto` this long after the last main turn end, with nothing running, is idle. */
export const IDLE_GAP_MS = 1500000

/**
 * Review of the second build: Claude Code installs what a `session.compact` hook hands up (the
 * kept messages, and with them the compaction boundary) once the hook has returned, and a
 * `$.ui.log` line is a transcript row at the next frame; logged inside the hook, the compaction
 * line would likely land above the boundary, among the rows the compaction hides. So a native
 * compaction's line waits this long after the hook ends (the plugin's own compactions log theirs
 * after `$.session.compact` resolved: boundary.ts settleSelf). Pending until a live check.
 */
export const COMPACT_LINE_DELAY_MS = 1000

/**
 * IC-1 D1 (MOD-SPEC §2.5 idle rule): a main `auto` dispatch is idle when no main turn runs, no
 * prompt is entering (CR-F17 counter), no plugin compaction is in flight, and the last main turn
 * ended at least 1,500 s ago. An idle dispatch is never `[midturn]`. `trigger` is the one
 * triggerCanary returned: a future `idle` trigger arrives here as `auto` (ID-1).
 */
export function idleGap(s: Deps['state'], trigger: string, now: number): number | undefined {
  if (trigger !== 'auto' || s.mainTurnRunning || s.foreignPrompts > 0 || s.busy || s.lastTurnEndAt === undefined) return undefined
  const gap = now - s.lastTurnEndAt
  return gap >= IDLE_GAP_MS ? Math.round(gap / 1000) : undefined
}

async function dispatchPath(d: Deps, sid: string, nonce: string): Promise<string | undefined> {
  const p = await d.paths()
  return p ? `${p.watch}/${sid}/dispatch/${nonce}.json` : undefined
}

function seenKey(sid: string): string {
  return `idle_seen:${sid}`
}

/**
 * Owner xxxxxxxx-17: a main compaction completed (any trigger the after-step sees: not
 * precompute), and whether it was an idle dispatch; kept in the load and in `$.store`, so the
 * 55.5-min outcome check finds it after a reload too.
 */
export async function noteCompaction(d: Deps, sid: string, idle: boolean): Promise<void> {
  const at = await d.now()
  d.state.compactedAt = { sid, at, idle }
  await d.storeSet(seenKey(sid), { at, idle })
}

/** The last main compaction of this sid at or after `since` (the plugin's own records), or undefined. */
export async function compactedSince(d: Deps, sid: string, since: number): Promise<{ at: number; idle: boolean } | undefined> {
  let c: { at: number; idle: boolean } | undefined = d.state.compactedAt?.sid === sid ? d.state.compactedAt : undefined
  if (c === undefined) {
    const v = (await d.storeGet(seenKey(sid))) as Record<string, unknown> | null | undefined
    if (v && typeof v === 'object' && typeof v.at === 'number') c = { at: v.at, idle: v.idle === true }
  }
  return c !== undefined && c.at >= since ? c : undefined
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

/**
 * MG-3 (MOD-SPEC §5.2 after-step; the A-28 thresholds of MG-5): a main compaction from this many
 * tokens up whose summarizer request read under this share of its cached prefix (`prefixRead`,
 * root ruling 2026-10-27 23:16: L3 0.925 and L1 0.999 warm, a cold L3 about 0.27) is
 * `compaction_cold`.
 */
export const COLD_SHARE = 0.5
export const COLD_MIN_TOKENS = 100000

/**
 * MG-3: `compaction_cache {nonce, prefix_read, uncovered}` for a compaction whose result carries
 * the summarizer's usage, and `compaction_cold {nonce, prefix_read}` for a cold main one (see
 * COLD_SHARE). `uncovered` is the input outside the cache: the compaction request's one cache
 * marker leaves the context after the last summarized assistant message uncached, warm or cold,
 * so it is logged apart and never makes a compaction cold (root ruling 2026-10-27 23:16, which
 * replaced the read share of all input here). A different model than the session's cannot read
 * the session's cache, so a cold prefix is the runtime sign of one.
 */
export async function cacheRows(
  d: Deps, sid: string, nonce: string, r: { usage?: RequestUsage; tokensBefore?: number }, main: boolean, actor: string,
): Promise<void> {
  if (r.usage === undefined) return
  const prefix = prefixRead(r.usage)
  await log(d, sid, 'compaction_cache', { nonce, prefix_read: prefix, uncovered: uncoveredInput(r.usage) }, actor)
  if (main && prefix !== null && prefix < COLD_SHARE && (r.tokensBefore ?? 0) >= COLD_MIN_TOKENS) {
    await log(d, sid, 'compaction_cold', { nonce, prefix_read: prefix }, actor)
  }
}

/** Writes the dispatch record through the helper, else the same JSON with `$.fs.write`. */
export async function writeDispatch(d: Deps, r: DispatchRecord): Promise<void> {
  const s = d.state
  const instrSha8 = sha8(r.text)
  const instrBytes = byteLength(r.text)
  // MG-4: the session's model as the record of what this compaction runs on (never passed on).
  const model = await d.model()
  const res = await dispatch(d, {
    sid: r.sid, nonce: r.nonce, actor: r.agentId ?? 'main', trigger: r.trigger, channel: r.channel,
    resumePref: r.resumePref, tags: r.tags, midturn: r.midturn, instrSha8, instrBytes, ccVersion: s.ccVersion, loadId: s.loadId,
    ...(r.handoffHt !== undefined ? { handoffHt: r.handoffHt } : {}),
    ...(r.idle !== undefined ? { idle: r.idle } : {}),
    ...(model !== undefined ? { model } : {}),
  })
  if (res.ok) return
  const path = await dispatchPath(d, r.sid, r.nonce)
  if (path) {
    // The helper's record keys in its order (CORE-14): `idle` and `idle_gap_s` always (a mod
    // record without the idle flag is `idle: false`, `idle_gap_s: null`), and `cc_version_src`
    // `mod` when the mod gave a version, else null.
    const rec = {
      v: 1, nonce: r.nonce, session_id: r.sid, actor: r.agentId ?? 'main', agent_id: r.agentId ?? null, trigger: r.trigger,
      channel: r.channel, resume_pref: r.resumePref, midturn: r.midturn,
      idle: r.idle !== undefined, idle_gap_s: r.idle !== undefined ? r.idle.gapS : null,
      tags: r.tags, instructions_sha8: instrSha8, instructions_bytes: instrBytes,
      cc_version: s.ccVersion, cc_version_src: s.ccVersion !== null && s.ccVersion !== '' ? 'mod' : null,
      load_id: s.loadId, pid: s.ident?.pid ?? null, pid_lstart: s.ident?.pid_lstart ?? null, ts: isoLocal(await d.now(), false),
      ...(r.handoffHt !== undefined ? { handoff_ht: r.handoffHt } : {}),
      ...(model !== undefined ? { model } : {}),
    }
    await d.write(path, JSON.stringify(rec) + '\n')
  }
  await helperMissing(d, r.sid, 'dispatch')
  await log(d, r.sid, 'dispatch', {
    nonce: r.nonce, trigger: r.trigger, agent_id: r.agentId, channel: r.channel, instructions_bytes: instrBytes,
    fallback: true, error_class: failClass(res), model: model ?? null,
  }, r.agentId ?? 'main')
}

export type MainText = { text: string; tags: Tag[] }

/**
 * The main text for a dispatch: `[midturn]` when asked, `[chain]` when `prev-copy` returns a
 * path, `[measured]` when the checkpoint returned a measured block, `[handoff]` with its path
 * when a handoff turn published one just before (MOD-SPEC §9.1; mod path only), `[queue]` when
 * `queue_cmd` is set (QA-B3, owner xxxxxxxx-11 "setting-driven, one text"; D-10 as the nudge).
 */
export async function mainText(
  d: Deps, nonce: string, midturn: boolean, prev: string | undefined, measured: string | null, handoffPath?: string,
): Promise<MainText> {
  const tags: Tag[] = []
  if (midturn) tags.push('midturn')
  if (prev !== undefined) tags.push('chain')
  if (handoffPath !== undefined) tags.push('handoff')
  if (measured !== null) tags.push('measured')
  if (d.cfg.queue_cmd !== '') tags.push('queue')
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
  // Read before any await of this handler that a turn could start in.
  const gapS = main ? idleGap(s, trigger, await d.now()) : undefined
  const nonce = await drawNonce(n => dispatchExists(d, sid, n))
  const midturn = main && (trigger === 'precompute' || (trigger === 'auto' && s.mainTurnRunning))
  const idle = gapS !== undefined && !midturn
  // MOD-SPEC §9.1 race: a native compaction while the handoff turn runs keeps the full text and
  // names the turn; §3.1: a native idle auto right after a published handoff gets `[handoff]`.
  const raced = main ? racedTurn(d, trigger) : undefined
  const after = main && trigger === 'auto' && !s.mainTurnRunning ? s.published : undefined
  const handoffHt = raced?.ht ?? after?.ht ?? undefined
  let raceState: HandoffState | undefined
  if (raced && raced.ht !== null && trigger === 'auto') raceState = await handoffState(d, sid, raced.ht)
  let text: string
  let tags: Tag[] = []
  let prodConsent: string | undefined
  if (!main) text = assemble(d.name, 'subagent-instructions', [], { nonce })
  else {
    const prev = await prevCopy(d, sid)
    let measured: string | null = null
    if (trigger === 'manual' || trigger === 'auto') {
      const wantMeasured = d.cfg.measured_block
      const cp = await checkpoint(d, sid, nonce, wantMeasured)
      if (wantMeasured && cp) measured = cp.measured_block
      prodConsent = cp?.consent['unattended_prod_reads']
    }
    const m = await mainText(d, nonce, midturn, prev, measured, after?.path)
    text = m.text
    tags = m.tags
  }
  await writeDispatch(d, {
    sid, nonce, agentId, trigger, channel: 'mod-hook', resumePref: main ? 'prompt.context' : 'none', midturn, tags, text,
    ...(handoffHt !== undefined ? { handoffHt } : {}),
    ...(idle && gapS !== undefined ? { idle: { gapS } } : {}),
  })
  // The shadow trial's M3 moment (off without its local config): a main compaction of Claude
  // Code's with no handoff turn before it; its forks start right before `next`, not awaited.
  const shadow = main && handoffHt === undefined && (trigger === 'auto' || trigger === 'manual')
    ? await shadowPrepM3(d, sid, {
      kind: idle ? 'm3-idle' : trigger === 'manual' ? 'm3-manual' : 'm3-auto', nonce, trigger,
      ...(trigger === 'manual' && e.instructions !== undefined ? { compactText: e.instructions } : {}),
    })
    : undefined
  const t0 = await d.now()
  startShadow(d, shadow)
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
  await cacheRows(d, sid, nonce, r, main, actor)
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
  // The compaction line is held here and logged once this hook has returned (COMPACT_LINE_DELAY_MS).
  const lines: string[] = []
  const hold = (t: string): void => {
    lines.push(t)
  }
  const failed = await guarded(d, sid, 'after-step', () => afterStep(d, {
    sid, nonce, agentId, midturn, resumePref: 'prompt.context', messages: r.messages, tokensBefore: r.tokensBefore, tokensAfter: r.tokensAfter,
    ...(block !== undefined ? { handoff: block } : after !== undefined ? { handoff: { published: after.path, ...(after.reported ? {} : { ack: true }) } } : {}),
    ...(raced && raced.ht !== null && block !== undefined ? { stats: { handoff_turn: 'race', handoff_ht: raced.ht } } : {}),
    ...(prodConsent !== undefined ? { prodConsent } : {}),
    ...(idle ? { idle: true } : {}),
    uiLine: hold,
  }))
  if (main && failed !== undefined) stepFailedLine(d, failed, hold)
  // Away digest phase 1 (owner 2026-10-27 12:5x, xxxxxxxx-09): a finished or blocked lane with
  // nothing running gets its digest turn right away with `idle_digest: submit` (`off`, the default
  // of this version by owner rule (c), and `return` log the skip and submit nothing).
  if (main && idle) await guarded(d, sid, 'digest', () => armDigest(d, sid, nonce))
  // SESSION-RESTART D2 (b): right after Claude Code's own idle compaction; nothing is submitted
  // after it (the new load waits at the prompt with its block, as after any idle compaction).
  if (main && idle) await guarded(d, sid, 'restart', () => restartMoment(d, sid, { cont: false }))
  if (lines.length > 0) {
    d.after(COMPACT_LINE_DELAY_MS, () => {
      for (const t of lines) d.uiLog(t)
    })
  }
  return r
}

/**
 * Runs one step; an internal error becomes one `watch_error {stage, error_class}` row, and its
 * class is returned (undefined when the step ran through).
 */
export async function guarded(d: Deps, sid: string, stage: string, fn: () => Promise<unknown>): Promise<string | undefined> {
  try {
    await fn()
    return undefined
  } catch (err) {
    const cls = (err instanceof Error ? err.name : typeof err).slice(0, 40)
    await log(d, sid, 'watch_error', { stage, error_class: cls }).catch(() => undefined)
    return cls
  }
}

/**
 * Review of the first build (owner 2026-10-30 07:52): a main after-step that threw never reached
 * its compaction line, so the user still gets one, with the error class and the status pointer.
 * `sink` takes the line in place of `d.uiLog` (a native compaction holds it: COMPACT_LINE_DELAY_MS).
 */
export function stepFailedLine(d: Deps, cls: string, sink: (text: string) => void = t => d.uiLog(t)): void {
  if (d.cfg.warn_ui) sink(`${d.name}: compaction done · plugin step failed (${cls}) · see /${d.name}:status`)
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
  /** This nonce's checkpoint `consent.unattended_prod_reads`, when a checkpoint answered. */
  prodConsent?: string
  /** An idle dispatch: the resume block gets `[idle]` (IC-1 D3). */
  idle?: boolean
  /** Takes the compaction line in place of `d.uiLog` (a native compaction holds it: COMPACT_LINE_DELAY_MS). */
  uiLine?: (text: string) => void
}

export const SUMMARY_PREFIX = 'This session is being continued'
/** How far into the installed message the prefix may start, after header lines Claude Code puts first. */
export const SUMMARY_SCAN = 4096

/**
 * The installed summary from its prefix on, or undefined: at the message's start, or at a line
 * start in its first SUMMARY_SCAN chars, after a header Claude Code puts before it (2.1.312: an
 * `<artifact-content-authored-by-others/>` line and its note, for a summary that restates
 * Artifact content). The header is not part of the summary: the PostCompact copy has none.
 * Past the start only behind such a header (a first line that is one `<.../>` tag), so a kept
 * message that quotes the prefix line is not taken for a summary.
 */
export function summaryText(text: string): string | undefined {
  if (text.startsWith(SUMMARY_PREFIX)) return text
  if (!/^<[A-Za-z][\w-]*\/>\r?\n/.test(text)) return undefined
  const at = text.slice(0, SUMMARY_SCAN).indexOf('\n' + SUMMARY_PREFIX)
  return at < 0 ? undefined : text.slice(at + 1)
}

/**
 * The hooks side's copy of this compaction (the classic PostCompact hook saves it first): this
 * session's newest main copy when its frontmatter names this nonce, with its path and verdict.
 */
async function hooksCopy(d: Deps, sid: string, nonce: string): Promise<{ path: string; verdict: Verdict } | undefined> {
  const path = await prevCopy(d, sid)
  const file = path === undefined ? undefined : expand(path, await d.home())
  const raw = file === undefined ? undefined : await d.read(file)
  const end = raw?.startsWith('---\n') ? raw.indexOf('\n---\n', 3) : -1
  if (path === undefined || raw === undefined || end < 0) return undefined
  const head = raw.slice(0, end + 1)
  const verdict = /^verdict: (\S+)$/m.exec(head)?.[1]
  if (/^nonce: (\S+)$/m.exec(head)?.[1] !== nonce || verdict === undefined || !isVerdict(verdict)) return undefined
  return { path, verdict }
}

/** MOD-SPEC §5.2: the after-step, main and subagent. */
export async function afterStep(d: Deps, a: AfterArgs): Promise<{ verdict: Verdict }> {
  const s = d.state
  const main = a.agentId === null
  const actor = a.agentId ?? 'main'
  // Owner xxxxxxxx-17: the 55.5-min idle check reads this, first, so a later failure cannot hide it.
  if (main) await noteCompaction(d, a.sid, a.idle === true)
  let text: string | undefined
  for (const m of a.messages) if (text === undefined && m.role === 'user') text = summaryText(m.text)
  let verdict: Verdict = 'unshaped'
  // A summary the mod did not find counts toward the 2-in-a-row rule only by the hooks side's verdict.
  let counted = text !== undefined
  let savedCopy: string | null = null
  let notSaved: string | undefined
  let chars = 0
  // Away digest phase 1: the lane facts of an idle compaction's summary (the model's own Status
  // and step marks, parsed; no text kept).
  let facts: LaneFacts | undefined
  // PRIV-04: the raw summary is stashed only under the watch folder the helper vetted (ident);
  // refused (null) or unknown (no helper answer) means no stash, never the options' folder.
  const stash = await vettedWatch(d, a.sid)
  const p = await d.paths()
  if (text === undefined) {
    notSaved = 'summary-not-found'
    await log(d, a.sid, 'copy_failed', { nonce: a.nonce, reason: notSaved }, actor)
    // The block's copy and verdict lines then take the hooks side's save and verdict.
    const hooks = main ? await hooksCopy(d, a.sid, a.nonce) : undefined
    if (hooks) {
      savedCopy = hooks.path
      notSaved = undefined
      verdict = hooks.verdict
      counted = true
    } else escalate(d, 'copy-failed')
  } else {
    const det = detectSummary(text, d.name, { dispatchNonce: a.nonce, scope: main ? 'main' : 'sub' })
    verdict = det.verdict
    chars = det.normalized.length
    if (main && a.idle === true) facts = laneFacts(text)
    const file = stash !== undefined ? `${stash}/${a.sid}/pending/${a.nonce}.mod.md` : undefined
    // MOD-SPEC §5.8 item 4: the orphan index marker goes first, so a stash this session leaves
    // behind is found by another session's cross-session finish. Empty; an existing one is fine.
    // The `pending/` folder stays the truth: a failed marker write does not stop the stash.
    if (file && stash !== undefined) await d.write(`${stash}/.orphans/${a.sid}`, '')
    if (!file || !(await d.write(file, text))) {
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
  // §9.3: the next eligible turn end may have its pre-compaction turn again.
  s.precompactRan = false
  const question = carriedQuestion(s)
  const blockArgs: BlockArgs = {
    nonce: a.nonce, midturn: a.midturn, nonok: !isOk(verdict), savedCopy, notSaved, ...(a.handoff !== undefined ? { handoff: a.handoff } : {}),
    prodAllow: prodAllowed(d.cfg.unattended_prod_reads, a.prodConsent),
    // Owner xxxxxxxx-25: halt mode picks the idle line's variant (checked again at delivery).
    ...(a.idle === true ? { idle: true, halt: s.halt.active, ...(facts !== undefined ? { lane: facts } : {}) } : {}),
    // Question carry (question.ts): a main turn's question no person's turn has followed yet, or
    // the running turn's timed-out dialog.
    ...(question !== undefined ? { question } : {}),
  }
  const built = await buildBlockWith(d, a.sid, blockArgs)
  // The idle episode of this compaction (a compaction that is not idle closes the one before).
  if (a.idle === true && !a.midturn) openEpisode(s, a.sid, a.nonce, blockArgs, built.remeasure, built.measuredAt)
  else s.idleLane = undefined
  if (built.lane !== undefined) await logLane(d, a.sid, a.nonce, facts, built.lane, 'build', built.running ?? 0)
  // A block still pending is replaced by this one: its outcome is settled now (no channel
  // will try it again). So is a block held for a person's return (owner xxxxxxxx-37).
  const old = s.pending
  if (old) {
    s.pending = undefined
    await logOutcome(d, old.sid, old.nonce, old.outcome, await claimedElsewhere(d, old))
  }
  // AT-RP-05: so is a record of this session id that another load left (an armed block of an
  // earlier process, not yet taken); this load never restores one after its own compaction.
  s.restoreChecked = a.sid
  await settleRecords(d, a.sid, n => claimedWhere(d, a.sid, n), a.nonce)
  s.idleAgain = undefined
  const pend: PendingResume = {
    sid: a.sid, nonce: a.nonce, block: built.block, builtAt: await d.now(), args: blockArgs, resumePref: a.resumePref, turnSeq: s.turnSeq,
    outcome: { nudged: s.nudgedThisTurn, continued: false, halt: s.halt.active, ...(a.stats !== undefined ? { handoff: a.stats } : {}) },
    ...(built.remeasure !== undefined ? { remeasure: built.remeasure } : {}),
    measuredAt: built.measuredAt,
    ...(built.lane !== undefined ? { lane: built.lane } : {}),
  }
  // AT-RP-01: on disk too, for a `claude --resume` of this session before its next turn; written
  // before the block is pending, so a channel that settles it finds the record to settle.
  pend.persisted = await persistPending(d, pend)
  s.pending = pend
  if (!isOk(verdict)) toastOnce(d, 'nonok:' + a.nonce, `${d.name}: compaction summary not in handoff format (${verdict}); the resume block adds a fallback note.`)
  if (!s.fourthToasted && (s.mainCompactions >= 4 || chars > 12000)) {
    s.fourthToasted = true
    d.toast(`${d.name}: 4 compactions in this session; consider /${d.name}:handoff and a fresh session.`)
  }
  if (counted) await countVerdict(d, a.sid, isOk(verdict))
  pend.outcome.halt = s.halt.active
  // Owner 2026-10-30 07:52 ("not clear if the compaction went well"): one dim transcript line
  // after every main compaction, whether a model turn follows or not; the model never reads it.
  // Built from what this step already measured: no new I/O.
  if (d.cfg.warn_ui) {
    const running = built.running ?? new Set([...s.agentTurns, ...measuredRunning(built.remeasure)]).size
    const line = compactLine(d.name, { ok: isOk(verdict), verdict, savedCopy, notSaved, handoff: a.handoff, running })
    if (a.uiLine !== undefined) a.uiLine(line)
    else d.uiLog(line)
  }
  return { verdict }
}

export type LineFacts = {
  ok: boolean
  verdict: Verdict
  savedCopy: string | null
  notSaved: string | undefined
  handoff: RaceBlock | undefined
  /** Units running now (agents and the measure's running tasks); 0 or unknown says nothing. */
  running: number
}

/**
 * Owner 2026-10-30 07:52: the one line the user sees after a main compaction, e.g.
 * `<name>: compaction ok · copy saved · handoff <file> · 2 jobs running`, or with `NOT` and a
 * pointer to the status skill when the summary is not in handoff format or its copy failed.
 */
export function compactLine(name: string, f: LineFacts): string {
  const parts = [f.ok ? 'compaction ok' : `compaction NOT in handoff format (${f.verdict})`]
  parts.push(f.savedCopy !== null ? 'copy saved' : `copy NOT saved (${(f.notSaved ?? 'unknown').slice(0, 40)})`)
  const h = f.handoff
  if (h && 'published' in h) parts.push(`handoff ${h.published.replace(/^.*\//, '')}`)
  else if (h) parts.push(`handoff cut off (draft ${h.draft && h.finish !== null ? 'present' : 'absent'})`)
  if (f.running > 0) parts.push(`${f.running} ${f.running === 1 ? 'job' : 'jobs'} running`)
  if (!f.ok || f.savedCopy === null) parts.push(`see /${name}:status`)
  return `${name}: ${parts.join(' · ')}`
}

const VERDICTS: readonly string[] = ['stale', 'scope-leak', 'unshaped', 'truncated', 'ok-trailer', 'ok']

function isVerdict(v: string): v is Verdict {
  return VERDICTS.includes(v)
}
