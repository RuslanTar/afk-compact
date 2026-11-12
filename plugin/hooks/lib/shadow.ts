// The local shadow trial (dual handoffs):
// at each real moment (M1 handoff, M2 plugin handoff turn, M3 compaction with no handoff turn
// before it) two tool-less forks of the session start together from the same point: the `old`
// arm answers an older handoff skill through the plugin's adapter, the `native` arm answers
// Claude Code's own compaction prompt. Both texts come from the user's local files at run time
// (the helper checks them against the sha256 lists of the local trial config); no hook awaits a
// fork; the helper saves both replies, secret-scanned and redacted, with one content-free moment
// record, in the trial folder outside the handoff root.
//
// Everything here is off unless `<home>/.cache/<plugin>-trial/trial.json` exists: without it the
// only work is one `fs.exists` at a main turn end. Every entry point runs after the plugin's own
// logic, in its own try/catch, so a failure here never changes a compaction, a turn or a hook.
import type { Deps } from './deps'
import type { HandoffTurn } from './handoff-turn'
import { assemble, hasAsset } from './assemble'
import { call } from './helper'
import { NEAR_LIMIT_PCT, limitWindows } from './idle'
import { isoLocal, zoneOf } from './log'
import { randomHex } from './nonce'
import { sha256 } from './normalize'

/** A fork with no result after this long is `lost` (it cannot be cancelled; a late result is still saved). */
export const LOST_MS = 15 * 60 * 1000
/**
 * Skipped when the last main request (a main step's start, else the last main turn end) is older
 * than this, whether or not a turn runs: a fork still starts before the 1-hour cache lapses.
 */
export const COLD_MS = 58 * 60 * 1000
/** The M2 facts measure runs inside `openAndSubmit` under this cap (old arm `skipped:facts-timeout` past it). */
export const M2_MEASURE_MS = 3000
/** The off-hook measure after a main turn end. */
export const TURN_MEASURE_MS = 8000
/** `trial-save` (the secret scan of two replies). */
export const SAVE_MS = 20000
/** The last reply and a typed prompt are kept to this many characters (their end). */
export const TAIL_MAX = 16000
/** Claude Code's separator before a `/compact` text (`pJ`): the only engine string here. */
export const COMPACT_TEXT_SEP = '\n\nAdditional Instructions:\n'

export type MomentKind =
  | 'm1-owner' | 'm1-self' | 'm2-halt' | 'm2-precompact' | 'm2-idle' | 'm3-idle' | 'm3-auto' | 'm3-manual' | 'm3-plugin'

/** What `trial-measure` answers (the helper's JSON line). */
export type Measure = {
  state: 'absent' | 'off' | 'bad' | 'on'
  why?: string | null
  skip?: string | null
  m3?: boolean
  native_tail?: boolean
  facts?: {
    text: string; repo: string; ticket: string; worktree?: string | null; branch?: string | null; head?: string | null
    dirty?: number | null; old_chain_flagged?: number; measured_at?: string
  }
  old?: { status: string; why?: string; skill?: string; template?: string; sums?: Record<string, string>; filled_sha256?: string }
  native?: {
    status: string; why?: string; head?: string; tail?: string; head_sha256?: string; tail_sha256?: string; cc_version?: string | null
    prompt_arm?: string; arm_source?: string; cache_prefix_flag?: boolean; transcript_flag?: number; precompact_hooks?: boolean
  }
}

/** One fork's outcome, content-free but for `text`, which only `trial-save` sees. */
export type ArmResult = {
  status: string
  text?: string
  usage?: { input_tokens: number; output_tokens: number; cache_read_input_tokens: number; cache_creation_input_tokens: number }
  httpStatus?: number | null
  error?: string
  startedAt: number
  endedAt?: number
}

export type FireSpec = {
  kind: MomentKind
  /** The ht (M2), a fresh turn nonce (M1) or the dispatch nonce (M3): the moment id's second half. */
  idPart: string
  trigger?: string
  nonce?: string
  ht?: string
  /** The main turn the moment falls in (M1 model-called, M3 mid-turn), for the record's `turn_id`. */
  turnId?: string
  /** A `/compact` text of the user's: added to the native prompt as the engine adds it. */
  compactText?: string
  /** A prompt typed now (M1, typed by the person): part of the supplied tail. */
  typed?: string
}

type Kept = { sid: string; at: number; m: Measure }

/** A moment ready to fire: everything awaited is done; `startShadow` is synchronous. */
export type Prepared = {
  sid: string
  spec: FireSpec
  skip?: string
  /** A `near-limit` skip's windows (idle.ts `limitWindows`), in its record. */
  windows?: string[]
  m?: Measure
  oldPrompt?: string
  oldStatus?: string
  nativePrompt?: string
  nativeStatus?: string
  tailSupplied: boolean
  compactTextAdded: boolean
  tokens: number | null
  factsAge: number | null
  model: string | null
  position: number
  openedAt: number
  ccVersion: string | null
}

type Moment = {
  p: Prepared
  id: string
  old?: ArmResult
  native?: ArmResult
  oldP?: Promise<ArmResult>
  nativeP?: Promise<ArmResult>
  pluginSide: 'submitted' | 'cancelled' | 'pending' | 'n/a'
  htRerun?: string
  lostFired: boolean
  saved: boolean
  lostTimer?: { cancel: () => void }
}

type ShadowLoad = {
  present: boolean
  kept: Kept | undefined
  lastAnswer: string | undefined
  /** M1: the main turn (`turnSeq`) whose forks fired; the person-typed one marks the turn about to start. */
  firedTurnSeq: number
  firedNonces: Set<string>
  /** When the last main step (one model request) started, on the session's clock: the cold rule's input. */
  lastStepAt: number | undefined
  positions: Map<string, number>
  moments: WeakMap<HandoffTurn, Moment>
  inflight: Set<Promise<unknown>>
}

const LOADS = new WeakMap<Deps['state'], ShadowLoad>()

function load(d: Deps): ShadowLoad {
  let s = LOADS.get(d.state)
  if (!s) {
    s = {
      present: false, kept: undefined, lastAnswer: undefined, firedTurnSeq: -1, firedNonces: new Set(), lastStepAt: undefined,
      positions: new Map(),
      moments: new WeakMap(), inflight: new Set(),
    }
    LOADS.set(d.state, s)
  }
  return s
}

function track(sh: ShadowLoad, p: Promise<unknown>): void {
  const q = p.catch(() => undefined).finally(() => sh.inflight.delete(q))
  sh.inflight.add(q)
}

/** For tests: resolves once every background step of the trial in this load has ended. */
export async function shadowSettled(state: Deps['state']): Promise<void> {
  const sh = LOADS.get(state)
  while (sh && sh.inflight.size > 0) await Promise.all([...sh.inflight])
}

/** The trial config's fixed path for this plugin name, or undefined without a home. */
export function trialPath(home: string | undefined, name: string): string | undefined {
  const h = home?.replace(/\/+$/, '')
  return h ? `${h}/.cache/${name}-trial/trial.json` : undefined
}

/** The trial config was there at the last main turn end (synchronous; false without it). */
export function shadowPresent(d: Deps): boolean {
  return LOADS.get(d.state)?.present === true
}

/**
 * A main `turn.step` starts (its request goes out): stamped for the cold rule while the trial
 * config is there; nothing at all without it. Not awaited; never throws.
 */
export function shadowStep(state: Deps['state'], deps: () => Deps): void {
  const sh = LOADS.get(state)
  if (sh?.present !== true) return
  track(sh, deps().now().then(t => {
    sh.lastStepAt = t
  }))
}

/** The trial ran a measure for this session that says on (cheap and synchronous: a hot-path test). */
function on(d: Deps, sid?: string): boolean {
  const k = LOADS.get(d.state)?.kept
  return k !== undefined && k.m.state === 'on' && (sid === undefined || k.sid === sid)
}

// ---------------------------------------------------------------- measure

/** Parses `trial-measure`'s line; undefined when it is not one. */
export function parseMeasure(stdout: string): Measure | undefined {
  try {
    const j = JSON.parse(stdout.trim()) as Measure
    return j && typeof j === 'object' && ['absent', 'off', 'bad', 'on'].includes(j.state) ? j : undefined
  } catch {
    return undefined
  }
}

/**
 * One `trial-measure` call, `timeout` once `timeoutMs` passed on the session's clock (the child
 * gets the same limit, so it does not outlive it).
 */
async function measure(d: Deps, sid: string, timeoutMs: number): Promise<Measure | 'timeout' | undefined> {
  const args = ['trial-measure', '--sid', sid, '--budget-ms', String(Math.max(500, timeoutMs - 500))]
  const cwd = await d.cwd()
  if (cwd) args.push('--cwd', cwd)
  if (d.state.ccVersion) args.push('--cc-version', d.state.ccVersion)
  let timer: { cancel: () => void } | undefined
  const late = new Promise<'timeout'>(resolve => {
    timer = d.after(timeoutMs, () => resolve('timeout'))
  })
  const r = await Promise.race([call(d, args, timeoutMs), late])
  timer?.cancel()
  if (r === 'timeout') return 'timeout'
  return r.ok ? parseMeasure(r.stdout) : undefined
}

/**
 * After a main turn end (started, not awaited): whether the trial config exists, and while it
 * does, one off-hook measure kept for the M1 and M3 fire points.
 */
export function shadowTurnEnd(d: Deps, sid: string, answer: string): void {
  const sh = load(d)
  track(sh, (async () => {
    try {
      const path = trialPath(await d.home(), d.name)
      sh.present = path !== undefined && (await d.exists(path))
      if (!sh.present) {
        sh.kept = undefined
        sh.lastAnswer = undefined
        return
      }
      sh.lastAnswer = answer.length > TAIL_MAX ? answer.slice(-TAIL_MAX) : answer
      const m = await measure(d, sid, TURN_MEASURE_MS)
      sh.kept = m === undefined || m === 'timeout' ? undefined : { sid, at: await d.now(), m }
    } catch {
      sh.kept = undefined
    }
  })())
}

// ---------------------------------------------------------------- prepare and start

function tailText(sh: ShadowLoad, spec: FireSpec): string | undefined {
  const parts: string[] = []
  if (sh.lastAnswer) parts.push('Last reply:\n' + sh.lastAnswer)
  if (spec.typed) parts.push('Typed now:\n' + (spec.typed.length > TAIL_MAX ? spec.typed.slice(-TAIL_MAX) : spec.typed))
  return parts.length > 0 ? parts.join('\n\n') : undefined
}

/** The old arm's prompt: the adapter asset with the skill, template, facts and tail filled in. */
export function oldPrompt(name: string, m: Measure, tail: string | undefined): string | undefined {
  const o = m.old
  if (!hasAsset('trial-old-handoff') || o?.status !== 'ok' || o.skill === undefined || o.template === undefined || !m.facts) return undefined
  return assemble(name, 'trial-old-handoff', tail ? ['trial-tail'] : [], {
    old_skill: o.skill, old_template: o.template, trial_facts: m.facts.text, ...(tail ? { trial_tail: tail } : {}),
  })
}

/** The native arm's prompt: [tail line + tail] + head + [separator + `/compact` text] + tail of the engine's text. */
export function nativePrompt(name: string, m: Measure, compactText: string | undefined, tail: string | undefined): string | undefined {
  const n = m.native
  if (n?.status !== 'ok' || n.head === undefined || n.tail === undefined) return undefined
  const lead = tail && m.native_tail === true && hasAsset('trial-native-tail')
    ? assemble(name, 'trial-native-tail', [], { trial_tail: tail }) + '\n' : ''
  const extra = compactText !== undefined && compactText.trim() !== '' ? COMPACT_TEXT_SEP + compactText : ''
  return lead + n.head + extra + n.tail
}

/** The adapter's own hash (`old.adapter`), as built for this plugin name. */
export function adapterSha(name: string): string | undefined {
  return hasAsset('trial-old-handoff') ? sha256(assemble(name, 'trial-old-handoff', ['trial-tail'], {})) : undefined
}

async function prepare(d: Deps, sid: string, spec: FireSpec, m: Measure | undefined, factsTimeout = false): Promise<Prepared | undefined> {
  const sh = load(d)
  if (!m || m.state !== 'on') return undefined
  const now = await d.now()
  const base: Prepared = {
    sid, spec, m, tailSupplied: false, compactTextAdded: false, tokens: null, factsAge: null, model: null,
    position: (await position(d, sid)) + 1, openedAt: now, ccVersion: d.state.ccVersion,
  }
  if (m.skip) return { ...base, skip: m.skip }
  if (spec.kind.startsWith('m3-') && m.m3 !== true) return { ...base, skip: 'm3-off' }
  let u: Awaited<ReturnType<Deps['usage']>> | undefined
  try {
    u = await d.usage()
  } catch {
    u = undefined
  }
  const limits = u?.rateLimits ?? []
  if (limits.length === 0) return { ...base, skip: 'no-limits' }
  if (limits.some(l => !(l.percentUsed < NEAR_LIMIT_PCT))) return { ...base, skip: 'near-limit', windows: limitWindows(limits) }
  // The cold rule on the last main request, mid-turn too: a step's start, else the turn end.
  const last = Math.max(d.state.lastTurnEndAt ?? -Infinity, sh.lastStepAt ?? -Infinity)
  if (!Number.isFinite(last) || now - last > COLD_MS) return { ...base, skip: 'cold' }
  const tail = tailText(sh, spec)
  const kept = sh.kept
  const old = factsTimeout ? undefined : oldPrompt(d.name, m, tail)
  const native = nativePrompt(d.name, m, spec.compactText, tail)
  return {
    ...base,
    tokens: u?.tokens ?? null,
    factsAge: kept && kept.m === m ? Math.round((now - kept.at) / 1000) : 0,
    model: (await d.model()) ?? null,
    ...(old !== undefined ? { oldPrompt: old } : { oldStatus: factsTimeout ? 'skipped:facts-timeout' : 'no-old-skill' }),
    ...(native !== undefined ? { nativePrompt: native } : { nativeStatus: 'no-native-prompt' }),
    tailSupplied: native !== undefined && tail !== undefined && m.native_tail === true,
    compactTextAdded: native !== undefined && spec.compactText !== undefined && spec.compactText.trim() !== '',
  }
}

async function position(d: Deps, sid: string): Promise<number> {
  const sh = load(d)
  const mem = sh.positions.get(sid)
  if (mem !== undefined) return mem
  const v = await d.storeGet('shadow_pos:' + sid)
  return typeof v === 'number' && Number.isFinite(v) ? v : 0
}

/** Maps one `$.model.fork` answer (or its rejection) to an arm status. */
export function armOf(r: unknown, startedAt: number, endedAt: number): ArmResult {
  const x = r as { isAnswered?: unknown; text?: unknown; reason?: unknown; usage?: unknown; status?: unknown; error?: unknown } | null
  if (!x || typeof x !== 'object' || typeof x.isAnswered !== 'boolean') return { status: 'rejected', startedAt, endedAt }
  const usage = usageOf(x.usage)
  const u = usage ? { usage } : {}
  if (x.isAnswered) {
    if (typeof x.text !== 'string') return { status: 'rejected', startedAt, endedAt }
    return x.text.trim() === '' ? { status: 'empty', ...u, startedAt, endedAt } : { status: 'ok', text: x.text, ...u, startedAt, endedAt }
  }
  switch (x.reason) {
    case 'nothing-to-fork': return { status: 'nothing-to-fork', startedAt, endedAt }
    case 'empty-reply': return { status: 'empty', ...u, startedAt, endedAt }
    case 'aborted': return { status: 'aborted', ...u, startedAt, endedAt }
    case 'api-error':
      return {
        status: 'api-error', ...u, startedAt, endedAt,
        httpStatus: typeof x.status === 'number' ? x.status : null,
        ...(typeof x.error === 'string' && /^[a-z_]{1,40}$/.test(x.error) ? { error: x.error } : {}),
      }
    default: return { status: 'rejected', startedAt, endedAt }
  }
}

/** A rejected `$.model.fork`: a hook's `{ deny }` (the engine's HooksError) is `denied`, anything else `rejected`. */
export function armOfError(err: unknown, startedAt: number, endedAt: number): ArmResult {
  const denied = err instanceof Error && err.name === 'HooksError'
  return { status: denied ? 'denied' : 'rejected', startedAt, endedAt }
}

function usageOf(u: unknown): ArmResult['usage'] | undefined {
  const x = u as Record<string, unknown> | null | undefined
  if (!x || typeof x !== 'object') return undefined
  const n = (k: string) => (typeof x[k] === 'number' && Number.isFinite(x[k] as number) ? (x[k] as number) : 0)
  return {
    input_tokens: n('input_tokens'), output_tokens: n('output_tokens'),
    cache_read_input_tokens: n('cache_read_input_tokens'), cache_creation_input_tokens: n('cache_creation_input_tokens'),
  }
}

/** Starts one fork now (the `$` call is made before this returns); never rejects. */
function fork(d: Deps, prompt: string, startedAt: number): Promise<ArmResult> {
  let p: Promise<unknown>
  try {
    p = d.fork(prompt)
  } catch (err) {
    return Promise.resolve(armOfError(err, startedAt, startedAt))
  }
  return p.then(
    async r => armOf(r, startedAt, await d.now()),
    async err => armOfError(err, startedAt, await d.now()),
  )
}

/**
 * Starts the moment: both forks one after the other with no await between them, or
 * nothing but the skip record. Synchronous: the caller calls it right before the plugin's own
 * submit or compaction. Never throws.
 */
export function startShadow(d: Deps, p: Prepared | undefined): Moment | undefined {
  if (!p) return undefined
  try {
    const sh = load(d)
    sh.positions.set(p.sid, p.position)
    track(sh, d.storeSet('shadow_pos:' + p.sid, p.position))
    const mo: Moment = {
      p, id: p.sid.slice(0, 8) + '-' + p.spec.idPart, pluginSide: p.spec.kind.startsWith('m2-') ? 'pending' : 'n/a',
      lostFired: false, saved: false,
    }
    if (p.skip !== undefined) {
      track(sh, saveSkip(d, mo))
      return mo
    }
    if (p.oldPrompt !== undefined) mo.oldP = fork(d, p.oldPrompt, p.openedAt)
    if (p.nativePrompt !== undefined) mo.nativeP = fork(d, p.nativePrompt, p.openedAt)
    mo.lostTimer = d.after(LOST_MS, () => {
      mo.lostFired = true
      track(sh, finish(d, mo))
    })
    const arm = (k: 'old' | 'native', q: Promise<ArmResult> | undefined) => {
      if (!q) return
      track(sh, q.then(async r => {
        if (mo.saved) {
          // A late result after the record was written with this arm `lost`.
          if (mo[k]?.status === 'lost') await saveLate(d, mo, k, r)
          return
        }
        mo[k] = r
        await finish(d, mo)
      }))
    }
    arm('old', mo.oldP)
    arm('native', mo.nativeP)
    if (!mo.oldP && !mo.nativeP) track(sh, finish(d, mo))
    return mo
  } catch {
    return undefined
  }
}

/** The record is written once both arms ended (or were `lost`) and an M2 plugin side is known (or 15 min passed). */
async function finish(d: Deps, mo: Moment): Promise<void> {
  if (mo.saved) return
  const pending = (q: Promise<ArmResult> | undefined, r: ArmResult | undefined) => q !== undefined && r === undefined
  if (!mo.lostFired && (pending(mo.oldP, mo.old) || pending(mo.nativeP, mo.native) || mo.pluginSide === 'pending')) return
  if (mo.lostFired) {
    if (pending(mo.oldP, mo.old)) mo.old = { status: 'lost', startedAt: mo.p.openedAt }
    if (pending(mo.nativeP, mo.native)) mo.native = { status: 'lost', startedAt: mo.p.openedAt }
  }
  mo.saved = true
  mo.lostTimer?.cancel()
  const input = saveInput(d, mo, await zoneOf(d))
  const r = await call(d, ['trial-save', '--sid', mo.p.sid], SAVE_MS, JSON.stringify(input) + '\n')
  if (r.ok) return
  // A second, minimal call (no reply, so no scan and no shadow).
  const strip = (a: Record<string, unknown>) => {
    const { reply: _reply, ...rest } = a
    return rest
  }
  await call(d, ['trial-save', '--sid', mo.p.sid], SAVE_MS, JSON.stringify({
    kind: 'failed', moment_id: input['moment_id'],
    moment: { ...(input['moment'] as Record<string, unknown>), status: 'save-failed' },
    old: strip(input['old'] as Record<string, unknown>), native: strip(input['native'] as Record<string, unknown>),
  }) + '\n')
}

function armRecord(r: ArmResult | undefined, fallback: string, tokens: number | null, zone: string | undefined): Record<string, unknown> {
  if (!r) return { status: fallback }
  const u = r.usage
  const read = u?.cache_read_input_tokens ?? 0
  const total = u ? u.input_tokens + read + u.cache_creation_input_tokens : 0
  return {
    status: r.status,
    started_at: isoLocal(r.startedAt, false, zone),
    ...(r.endedAt !== undefined ? { ended_at: isoLocal(r.endedAt, false, zone) } : {}),
    ...(u ? { ...u, read_share: total > 0 ? Math.round((read / total) * 1000) / 1000 : null } : {}),
    ...(u && tokens !== null && tokens > 0 ? { reads_est: Math.round((read / tokens) * 100) / 100 } : {}),
    ...(r.httpStatus !== undefined ? { http_status: r.httpStatus } : {}),
    ...(r.error !== undefined ? { error: r.error } : {}),
    ...(r.status === 'ok' && r.text !== undefined ? { reply: r.text } : {}),
  }
}

/** The content-free moment fields; the replies ride only in the arms' `reply`. */
export function momentFields(mo: { p: Prepared; pluginSide: string; htRerun?: string }, zone: string | undefined): Record<string, unknown> {
  const p = mo.p
  const f = p.m?.facts
  return {
    kind: p.spec.kind,
    position: p.position,
    opened_at: isoLocal(p.openedAt, false, zone),
    plugin_side: mo.pluginSide,
    cc_version: p.ccVersion,
    ...(p.spec.trigger !== undefined ? { trigger: p.spec.trigger } : {}),
    ...(p.spec.ht !== undefined ? { ht: p.spec.ht } : {}),
    ...(p.spec.turnId !== undefined ? { turn_id: p.spec.turnId } : {}),
    ...(mo.htRerun !== undefined ? { ht_rerun: mo.htRerun } : {}),
    ...(p.spec.nonce !== undefined ? { nonce: p.spec.nonce } : {}),
    ...(p.model !== null ? { model: p.model } : {}),
    ...(p.tokens !== null ? { tokens: p.tokens } : {}),
    ...(p.factsAge !== null ? { facts_age_s: p.factsAge } : {}),
    ...(p.windows !== undefined ? { windows: p.windows } : {}),
    ...(f ? {
      worktree: f.worktree ?? null, branch: f.branch ?? null, head: f.head ?? null, dirty: f.dirty ?? null,
      old_chain_flagged: f.old_chain_flagged ?? 0,
    } : {}),
  }
}

function saveInput(d: Deps, mo: Moment, zone: string | undefined): Record<string, unknown> {
  const p = mo.p
  const m = p.m
  const n = m?.native
  const adapter = adapterSha(d.name)
  return {
    kind: 'moment',
    moment_id: mo.id,
    repo: m?.facts?.repo,
    ticket: m?.facts?.ticket,
    moment: momentFields(mo, zone),
    old: {
      ...armRecord(mo.old, p.oldStatus ?? 'rejected', p.tokens, zone),
      ...(m?.old?.sums ? { skill_sha256: m.old.sums } : {}),
      ...(m?.old?.filled_sha256 ? { filled_sha256: m.old.filled_sha256 } : {}),
      ...(adapter ? { adapter_sha256: adapter } : {}),
    },
    native: {
      ...armRecord(mo.native, p.nativeStatus ?? 'rejected', p.tokens, zone),
      cc_version: n?.cc_version ?? p.ccVersion,
      ...(n?.head_sha256 ? { head_sha256: n.head_sha256, tail_sha256: n.tail_sha256 } : {}),
      ...(n?.prompt_arm ? { prompt_arm: n.prompt_arm, arm_source: n.arm_source } : {}),
      cache_prefix_flag: n?.cache_prefix_flag ?? null,
      ...(n?.transcript_flag !== undefined ? { transcript_flag: n.transcript_flag } : {}),
      precompact_hooks: n?.precompact_hooks ?? null,
      tail_supplied: p.tailSupplied,
      compact_text_added: p.compactTextAdded,
    },
  }
}

async function saveSkip(d: Deps, mo: Moment): Promise<void> {
  mo.saved = true
  const zone = await zoneOf(d)
  const input = { kind: 'skip', moment_id: mo.id, moment: { ...momentFields(mo, zone), status: 'skipped:' + (mo.p.skip ?? 'unknown') } }
  await call(d, ['trial-save', '--sid', mo.p.sid], SAVE_MS, JSON.stringify(input) + '\n')
}

async function saveLate(d: Deps, mo: Moment, arm: 'old' | 'native', r: ArmResult): Promise<void> {
  const m = mo.p.m
  const zone = await zoneOf(d)
  const input = {
    kind: 'late', arm, moment_id: mo.id, repo: m?.facts?.repo, ticket: m?.facts?.ticket, moment: momentFields(mo, zone),
    [arm]: { ...armRecord(r, 'lost', mo.p.tokens, zone), late: true },
  }
  await call(d, ['trial-save', '--sid', mo.p.sid], SAVE_MS, JSON.stringify(input) + '\n')
}

// ---------------------------------------------------------------- fire points

/** M1, person-typed: `prompt.submit` of this plugin's typed handoff command, before `next(e)`. Never throws. */
export async function shadowOwnerHandoff(d: Deps, args: string, text: string): Promise<void> {
  try {
    if (!on(d)) return
    const sid = await d.sessionId()
    const sh = load(d)
    if (!on(d, sid)) return
    // The turn this prompt starts: a model-called Skill in it fires nothing more.
    sh.firedTurnSeq = d.state.turnSeq + 1
    const p = await prepare(d, sid, { kind: 'm1-owner', idPart: randomHex(8), typed: text || args }, sh.kept?.m)
    startShadow(d, p)
  } catch {
    // the trial never changes the prompt
  }
}

/**
 * M1, model-called: a main `tool.call` of the Skill tool for this plugin's handoff skill, only while no
 * handoff turn is submitted or running (the plugin's own handoff turn calls this skill) and
 * once per main turn. Never throws.
 */
export async function shadowSelfHandoff(d: Deps, sid: string, tool: string, input: Record<string, unknown>): Promise<void> {
  try {
    if (tool !== 'Skill' || !on(d, sid)) return
    const skill = input['skill']
    if (skill !== d.name + ':handoff') return
    const s = d.state
    const h = s.handoffTurn
    if (h && (h.phase === 'submitted' || h.phase === 'running')) return
    const sh = load(d)
    if (sh.firedTurnSeq === s.turnSeq) return
    sh.firedTurnSeq = s.turnSeq
    const turnId = s.turnId ?? undefined
    startShadow(d, await prepare(d, sid, { kind: 'm1-self', idPart: randomHex(8), ...(turnId !== undefined ? { turnId } : {}) }, sh.kept?.m))
  } catch {
    // the trial never changes the tool call
  }
}

/**
 * M2, inside `openAndSubmit` before its last cancel check: the capped facts measure and the
 * prepared moment, or undefined (trial off, or this handoff turn already fired: a re-run after a
 * dropped submit fires nothing). Never throws.
 */
export async function shadowPrepM2(d: Deps, sid: string, h: HandoffTurn, ht: string): Promise<Prepared | undefined> {
  try {
    const sh = load(d)
    if (!sh.present || h.shadowFired) return undefined
    // The turn end before this handoff turn measured off, ended or not valid: no measure here (the
    // config is re-read at the next turn end).
    const k = sh.kept
    if (k !== undefined && k.sid === sid && k.m.state !== 'on') return undefined
    const fresh = await measure(d, sid, M2_MEASURE_MS)
    const timeout = fresh === 'timeout'
    // Past the cap with no kept facts (nor the native text that comes with them): one
    // `skipped:facts-timeout` record for the moment.
    const m = fresh !== undefined && fresh !== 'timeout' ? fresh
      : timeout ? (on(d, sid) ? sh.kept?.m : { state: 'on' as const, skip: 'facts-timeout' }) : undefined
    if (m && m.state === 'on' && fresh !== 'timeout' && fresh !== undefined) sh.kept = { sid, at: await d.now(), m }
    const kind: MomentKind = h.reason === 'precompact' ? 'm2-precompact' : h.reason === 'idle' ? 'm2-idle' : 'm2-halt'
    return await prepare(d, sid, { kind, idPart: ht, ht }, m, timeout)
  } catch {
    return undefined
  }
}

/**
 * M2, synchronous, right before `h.phase = 'submitted'`: starts the prepared moment and marks
 * the handoff turn, or, on a re-run of a turn that already fired, moves its pending record to
 * the new ht (`ht_rerun`). Never throws.
 */
export function shadowStartM2(d: Deps, h: HandoffTurn, p: Prepared | undefined, ht: string): void {
  try {
    const sh = load(d)
    if (h.shadowFired) {
      const mo = sh.moments.get(h)
      if (mo && mo.p.spec.ht !== ht) mo.htRerun = ht
      return
    }
    if (!p) return
    const mo = startShadow(d, p)
    if (!mo) return
    h.shadowFired = true
    sh.moments.set(h, mo)
  } catch {
    // nothing
  }
}

/** The M2 plugin side: its prompt was submitted, or the handoff turn ended for good without it. */
export function shadowPluginSide(d: Deps, h: HandoffTurn | undefined, side: 'submitted' | 'cancelled'): void {
  try {
    if (!h) return
    const sh = LOADS.get(d.state)
    const mo = sh?.moments.get(h)
    if (!sh || !mo || mo.pluginSide !== 'pending') return
    mo.pluginSide = side
    track(sh, finish(d, mo))
  } catch {
    // nothing
  }
}

/**
 * M3: a main compaction with no handoff turn before it (Claude Code's `auto`, idle or `manual`
 * trigger in `onCompact`, or the plugin's own in `boundary`), prepared after its dispatch record
 * is written; `startShadow` runs right before the compaction call. Never throws.
 */
export async function shadowPrepM3(
  d: Deps, sid: string, a: { kind: 'm3-idle' | 'm3-auto' | 'm3-manual' | 'm3-plugin'; nonce: string; trigger: string; compactText?: string },
): Promise<Prepared | undefined> {
  try {
    if (!on(d, sid)) return undefined
    const sh = load(d)
    if (sh.firedNonces.has(a.nonce)) return undefined
    sh.firedNonces.add(a.nonce)
    const turnId = d.state.mainTurnRunning && d.state.turnId !== null ? d.state.turnId : undefined
    return await prepare(d, sid, {
      kind: a.kind, idPart: a.nonce, nonce: a.nonce, trigger: a.trigger, ...(turnId !== undefined ? { turnId } : {}), ...(a.compactText !== undefined ? { compactText: a.compactText } : {}),
    }, sh.kept?.m)
  } catch {
    return undefined
  }
}
