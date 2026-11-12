// `$.process.run` wrappers for every helper subcommand the mod calls. A call
// that rejects (cannot start, timed out) or exits non-zero is a failed call; callers fall back.
import type { Deps, RunResult } from './deps'
import type { RestartReport, RestartSetting } from './restart'

/** 2 s for helper calls. */
export const HELPER_MS = 2000
/** Checkpoint budget 10 s, plus start-up slack. */
export const CHECKPOINT_MS = 12000
/** Sweep after a main-proven compaction (the PostCompact budget is 8 s; same here). */
export const SWEEP_MS = 10000

export async function call(d: Deps, args: readonly string[], timeoutMs = HELPER_MS, stdin?: string): Promise<RunResult> {
  return stdin === undefined ? d.run([d.helper, ...args], timeoutMs) : d.run([d.helper, ...args], timeoutMs, stdin)
}

/**
 * `log --sid S --stream paths --stdin`: several rows in one spawn, one JSON object per
 * line on stdin, each appended as a row. Nothing is sent for an empty list.
 */
export async function logPaths(d: Deps, sid: string, lines: readonly string[]): Promise<RunResult | undefined> {
  if (lines.length === 0) return undefined
  return call(d, ['log', '--sid', sid, '--stream', 'paths', '--stdin'], HELPER_MS, lines.join('\n') + '\n')
}

/**
 * `usage --sid S [--stdin]` (limits.ts): the shared usage record's entries, after adding this
 * session's own reading (`own`: `{at, windows}` in epoch seconds) when given; undefined when the
 * call failed or its reply did not parse.
 */
export async function usageRecord(d: Deps, sid: string, own?: unknown): Promise<unknown[] | undefined> {
  const r = own === undefined ? await call(d, ['usage', '--sid', sid]) : await call(d, ['usage', '--sid', sid, '--stdin'], HELPER_MS, JSON.stringify(own) + '\n')
  if (!r.ok) return undefined
  try {
    const j = JSON.parse(r.stdout.trim()) as { readings?: unknown }
    return Array.isArray(j.readings) ? j.readings : undefined
  } catch {
    return undefined
  }
}

/** A short class for a failed call, for rows (never the stderr text). */
export function failClass(r: RunResult): string {
  return r.exitCode === null ? 'rejected' : 'exit-' + String(r.exitCode)
}

/**
 * `watch`: the helper's effective log folder after its unsafe-root checks, null
 * when every candidate was refused, undefined when the reply has no such key.
 */
export type Ident = {
  pid: number | null
  pid_lstart: string | null
  watch?: string | null
  /** `restart_on_update` as the helper resolved it (settings file only). */
  restart?: RestartSetting
  /** Background restarts that failed after the kill, reported once by this load. */
  restartReports?: RestartReport[]
}

export async function ident(d: Deps, sid: string): Promise<Ident | undefined> {
  const r = await call(d, ['ident', '--sid', sid])
  if (!r.ok) return undefined
  try {
    const j = JSON.parse(r.stdout.trim()) as { pid?: unknown; pid_lstart?: unknown; watch?: unknown; restart?: unknown; restart_reports?: unknown }
    const id: Ident = {
      pid: typeof j.pid === 'number' ? j.pid : null,
      pid_lstart: typeof j.pid_lstart === 'string' ? j.pid_lstart : null,
    }
    if (j.watch === null) id.watch = null
    else if (typeof j.watch === 'string' && j.watch.startsWith('/')) id.watch = j.watch
    if (j.restart === 'on' || j.restart === 'shadow' || j.restart === 'off') id.restart = j.restart
    if (Array.isArray(j.restart_reports)) {
      const reps = j.restart_reports.flatMap(x => {
        const o = (x ?? {}) as { short?: unknown; to?: unknown; code?: unknown }
        return typeof o.short === 'string' ? [{ short: o.short, to: typeof o.to === 'string' ? o.to : null, code: typeof o.code === 'string' ? o.code : 'other' }] : []
      })
      if (reps.length > 0) id.restartReports = reps
    }
    return id
  } catch {
    return undefined
  }
}

export type DispatchArgs = {
  sid: string
  nonce: string
  actor: string
  trigger: string
  channel: 'mod-hook' | 'mod-self'
  resumePref: string
  tags: readonly string[]
  midturn: boolean
  instrSha8: string
  instrBytes: number
  ccVersion: string | null
  loadId: string
  /** The handoff turn this dispatch follows or interrupts (`handoff_ht`). */
  handoffHt?: string
  /** An idle dispatch, with the seconds since the last main turn end. */
  idle?: { gapS: number }
  /** The session's model (`$.session.model()`), recorded only. */
  model?: string
}

/**
 * `dispatch … [--handoff-ht H] [--idle=true --idle-gap-s=N] [--model M]` → `ok`; exit 3 `REFUSED: nonce-exists`.
 * `--idle` is given only for an idle dispatch (absent = false), in the `=` form, which the
 * helper's parser reads alike for a value flag and a boolean one.
 */
export async function dispatch(d: Deps, a: DispatchArgs): Promise<RunResult> {
  return call(d, [
    'dispatch', '--sid', a.sid, '--nonce', a.nonce, '--actor', a.actor, '--trigger', a.trigger,
    '--channel', a.channel, '--resume-pref', a.resumePref, '--tags', a.tags.join(','),
    '--midturn', a.midturn ? 'true' : 'false', '--instr-sha8', a.instrSha8, '--instr-bytes', String(a.instrBytes),
    '--cc-version', a.ccVersion ?? '', '--load-id', a.loadId,
    ...(a.handoffHt !== undefined ? ['--handoff-ht', a.handoffHt] : []),
    ...(a.idle !== undefined ? ['--idle=true', '--idle-gap-s=' + String(a.idle.gapS)] : []),
    ...(a.model !== undefined ? ['--model=' + a.model] : []),
  ])
}

/**
 * `handoff-turn open --sid --ht --reason --max-calls --max-tokens`: `ok` (the ht record
 * was created), `EXISTS` (draw another ht), or `failed` (refused, or the call failed).
 */
export async function handoffTurnOpen(d: Deps, sid: string, ht: string, reason: string, maxCalls: number, maxTokens: number): Promise<'ok' | 'EXISTS' | 'failed'> {
  const r = await call(d, ['handoff-turn', 'open', '--sid', sid, '--ht', ht, '--reason', reason, '--max-calls', String(maxCalls), '--max-tokens', String(maxTokens)])
  const s = r.stdout.trim()
  if (r.ok && (s === 'ok' || s === 'EXISTS')) return s
  return 'failed'
}

/** `handoff-turn supersede --sid --ht --nonce` (the race): true when written or already there. */
export async function handoffTurnSupersede(d: Deps, sid: string, ht: string, nonce: string): Promise<boolean> {
  const r = await call(d, ['handoff-turn', 'supersede', '--sid', sid, '--ht', ht, '--nonce', nonce])
  return r.ok && /^(ok|EXISTS)$/.test(r.stdout.trim())
}

/**
 * `handoff-turn close --sid --ht --why cancelled`:
 * marks an ht whose handoff turn will not run, so `begin` does not bind it to a manual
 * `/handoff`. True for `ok`/`EXISTS`. A helper without `close` fails the call: the ht then stays
 * open as before (60 minutes), nothing else changes.
 */
export async function handoffTurnClose(d: Deps, sid: string, ht: string, why: 'cancelled'): Promise<boolean> {
  const r = await call(d, ['handoff-turn', 'close', '--sid', sid, '--ht', ht, '--why', why])
  return r.ok && /^(ok|EXISTS)$/.test(r.stdout.trim())
}

export type HandoffState =
  | { state: 'none' }
  | { state: 'staged'; stage: string; draft: boolean; finish: string | null }
  | { state: 'published'; path: string }
  | { state: 'superseded'; nonce: string }
  | { state: 'failed' }

/**
 * `handoff-state --sid --ht`: `none` · `staged <stage> draft=<0|1> finish=<command>` (the command
 * is everything after `finish=`; `none` when no safe one exists) · `published <path>` ·
 * `superseded <nonce>`; anything else is `failed`.
 */
export async function handoffState(d: Deps, sid: string, ht: string): Promise<HandoffState> {
  const r = await call(d, ['handoff-state', '--sid', sid, '--ht', ht])
  return r.ok ? parseHandoffState(r.stdout) : { state: 'failed' }
}

export function parseHandoffState(stdout: string): HandoffState {
  const s = stdout.replace(/\s+$/, '').split('\n')[0] ?? ''
  if (s === 'none') return { state: 'none' }
  let m: RegExpExecArray | null
  if ((m = /^published (\S.*)$/.exec(s))) return { state: 'published', path: m[1] ?? '' }
  if ((m = /^superseded ([0-9a-f]{8})$/.exec(s))) return { state: 'superseded', nonce: m[1] ?? '' }
  if ((m = /^staged (\S.*?) draft=([01]) finish=(.+)$/.exec(s))) {
    const finish = m[3] ?? 'none'
    return { state: 'staged', stage: m[1] ?? '', draft: m[2] === '1', finish: finish === 'none' ? null : finish }
  }
  return { state: 'failed' }
}

/**
 * `log --sid S --stream jobs --stdin`: one raw job or stop object per line; the helper
 * completes and appends the row, or refuses (`REFUSED: jobs-caller`, exit 3) and logs why.
 */
export async function logJobs(d: Deps, sid: string, lines: readonly string[]): Promise<RunResult | undefined> {
  if (lines.length === 0) return undefined
  return call(d, ['log', '--sid', sid, '--stream', 'jobs', '--stdin'], HELPER_MS, lines.join('\n') + '\n')
}

/** Path of this session's newest main copy, or undefined (`none`, or a failed call). */
export async function prevCopy(d: Deps, sid: string): Promise<string | undefined> {
  const r = await call(d, ['prev-copy', '--sid', sid, '--actor', 'main'])
  const p = r.stdout.trim()
  return r.ok && p !== '' && p !== 'none' ? p : undefined
}

/**
 * `consent`: the consent values the helper resolved for this checkpoint, read from the
 * settings file only; `{}` when the reply has none.
 */
export type Checkpoint = { measured_block: string | null; lane: string | null; ms: Record<string, number>; consent: Record<string, string> }

export async function checkpoint(d: Deps, sid: string, nonce: string, measured: boolean): Promise<Checkpoint | undefined> {
  const args = ['checkpoint', '--sid', sid, '--nonce', nonce, '--budget-ms', '10000']
  if (measured) args.push('--measured')
  const r = await call(d, args, CHECKPOINT_MS)
  if (!r.ok) return undefined
  try {
    const j = JSON.parse(r.stdout.trim()) as { measured_block?: unknown; lane?: unknown; checkpoint_ms?: unknown; consent?: unknown }
    const consent: Record<string, string> = {}
    if (typeof j.consent === 'object' && j.consent !== null && !Array.isArray(j.consent)) {
      for (const [k, v] of Object.entries(j.consent as Record<string, unknown>)) if (typeof v === 'string') consent[k] = v
    }
    return {
      measured_block: typeof j.measured_block === 'string' ? j.measured_block : null,
      lane: typeof j.lane === 'string' ? j.lane : null,
      ms: typeof j.checkpoint_ms === 'object' && j.checkpoint_ms !== null ? (j.checkpoint_ms as Record<string, number>) : {},
      consent,
    }
  } catch {
    return undefined
  }
}

export type SaveResult = {
  verdict: string | null
  marker_line: number | null
  sentinel_from_end: number | null
  kind: 'saved' | 'exists-match' | 'exists-differs' | 'refused' | 'failed'
  path: string | null
  reason: string | null
}

export type SaveArgs = {
  sid: string
  nonce: string
  from: string
  scope: 'main' | 'sub'
  agent?: string
  tokens?: { before: number | undefined; after: number | undefined }
}

/** `save-copy --writer mod …` and its two-line answer. */
export async function saveCopy(d: Deps, a: SaveArgs): Promise<SaveResult> {
  const args = ['save-copy', '--sid', a.sid, '--nonce', a.nonce, '--from', a.from, '--writer', 'mod', '--scope', a.scope]
  if (a.agent) args.push('--agent', a.agent)
  if (a.tokens && (a.tokens.before !== undefined || a.tokens.after !== undefined)) {
    args.push('--tokens', `${a.tokens.before ?? ''},${a.tokens.after ?? ''}`)
  }
  const r = await call(d, args, SWEEP_MS)
  return parseSave(r)
}

export function parseSave(r: RunResult): SaveResult {
  const out: SaveResult = { verdict: null, marker_line: null, sentinel_from_end: null, kind: 'failed', path: null, reason: null }
  const lines = r.stdout.split('\n').map(l => l.trim()).filter(l => l !== '')
  const v = /^VERDICT (\S+) marker_line=(\S+) sentinel_from_end=(\S+)$/.exec(lines[0] ?? '')
  if (v) {
    out.verdict = v[1] ?? null
    out.marker_line = v[2] === '-' ? null : Number(v[2])
    out.sentinel_from_end = v[3] === '-' ? null : Number(v[3])
  }
  const l2 = lines[v ? 1 : 0] ?? ''
  let m: RegExpExecArray | null
  if ((m = /^Saved copy: (.+)$/.exec(l2))) {
    out.kind = 'saved'
    out.path = m[1] ?? null
  } else if ((m = /^EXISTS: (.+) sha-(match|differs)$/.exec(l2))) {
    out.kind = m[2] === 'match' ? 'exists-match' : 'exists-differs'
    out.path = m[1] ?? null
  } else if ((m = /^REFUSED: (.+)$/.exec(l2))) {
    out.kind = 'refused'
    out.reason = (m[1] ?? '').trim()
  } else {
    out.reason = r.exitCode === null ? 'helper-missing' : 'helper-' + failClass(r)
  }
  return out
}

/** `sweep --sid --nonce`; the counts line only (the helper logs `sweep_evidence`). */
export async function sweep(d: Deps, sid: string, nonce: string): Promise<boolean> {
  const r = await call(d, ['sweep', '--sid', sid, '--nonce', nonce], SWEEP_MS)
  return r.ok
}

export type ClaimResult = 'CLAIMED' | 'TAKEN' | 'failed'

export async function claim(d: Deps, sid: string, nonce: string, channel: 'prompt.context' | 'prompt.submit'): Promise<ClaimResult> {
  return (await claimBy(d, sid, nonce, channel)).result
}

/** The claim and, for `TAKEN <channel>`, the channel that holds it (null when not given). */
export async function claimBy(d: Deps, sid: string, nonce: string, channel: 'prompt.context' | 'prompt.submit'): Promise<{ result: ClaimResult; by: string | null }> {
  const r = await call(d, ['claim', '--sid', sid, '--nonce', nonce, '--channel', channel])
  const s = r.stdout.trim()
  if (r.ok && s === 'CLAIMED') return { result: 'CLAIMED', by: channel }
  if (r.ok && s.startsWith('TAKEN')) return { result: 'TAKEN', by: channelToken(s.slice(5).trim().split(/\s+/)[0]) }
  return { result: 'failed', by: null }
}

/** A claim channel as a row value: a short token, else null (never free text). */
export function channelToken(v: string | undefined): string | null {
  return v !== undefined && /^[a-z][a-z.]{1,30}$/.test(v) ? v : null
}

/**
 * The re-measure block (`measure --sid --compact --nonce N`), or undefined. The nonce makes the
 * evidence map this compaction's (its checkpoint, else its own sweep), never a newer one's.
 * `copy`: the saved copy of this compaction's summary, whose `## Approvals` lines the
 * helper checks against this session's transcript (`Approvals (checked)` lines); without it the
 * block has no approvals line, so no approval in the summary counts as checked.
 * `budgetMs`: the helper's own budget for the whole call (`--budget-ms`), for a caller that kills
 * it sooner than the helper's default budget; without it the helper keeps its own.
 */
export async function measure(d: Deps, sid: string, nonce?: string, timeoutMs = CHECKPOINT_MS, copy?: string, budgetMs?: number): Promise<string | undefined> {
  const args = ['measure', '--sid', sid, '--compact', ...(nonce ? ['--nonce', nonce] : []), ...(copy !== undefined && copy !== '' ? ['--copy=' + copy] : []),
    ...(budgetMs !== undefined && budgetMs > 0 ? ['--budget-ms', String(Math.floor(budgetMs))] : [])]
  const r = await call(d, args, timeoutMs)
  return r.ok ? r.stdout.replace(/\s+$/, '') : undefined
}
