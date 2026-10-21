// `$.process.run` wrappers for every helper subcommand the mod calls (BUILD-PLAN §3.1). A call
// that rejects (cannot start, timed out) or exits non-zero is a failed call; callers fall back.
import type { Deps, RunResult } from './deps'

/** MOD-SPEC §2.3: 2 s for helper calls. */
export const HELPER_MS = 2000
/** MOD-SPEC §10: checkpoint budget 10 s, plus start-up slack. */
export const CHECKPOINT_MS = 12000
/** Sweep after a main-proven compaction (the PostCompact budget is 8 s; same here). */
export const SWEEP_MS = 10000

export async function call(d: Deps, args: readonly string[], timeoutMs = HELPER_MS, stdin?: string): Promise<RunResult> {
  return stdin === undefined ? d.run([d.helper, ...args], timeoutMs) : d.run([d.helper, ...args], timeoutMs, stdin)
}

/**
 * `log --sid S --stream paths --stdin` (F2-6): several rows in one spawn, one JSON object per
 * line on stdin, each appended as a row. Nothing is sent for an empty list.
 */
export async function logPaths(d: Deps, sid: string, lines: readonly string[]): Promise<RunResult | undefined> {
  if (lines.length === 0) return undefined
  return call(d, ['log', '--sid', sid, '--stream', 'paths', '--stdin'], HELPER_MS, lines.join('\n') + '\n')
}

/** A short class for a failed call, for rows (never the stderr text). */
export function failClass(r: RunResult): string {
  return r.exitCode === null ? 'rejected' : 'exit-' + String(r.exitCode)
}

/**
 * `watch`: the helper's effective log folder after its unsafe-root checks (MOD-SPEC §1.2), null
 * when every candidate was refused, undefined when the reply has no such key.
 */
export type Ident = { pid: number | null; pid_lstart: string | null; watch?: string | null }

export async function ident(d: Deps, sid: string): Promise<Ident | undefined> {
  const r = await call(d, ['ident', '--sid', sid])
  if (!r.ok) return undefined
  try {
    const j = JSON.parse(r.stdout.trim()) as { pid?: unknown; pid_lstart?: unknown; watch?: unknown }
    const id: Ident = {
      pid: typeof j.pid === 'number' ? j.pid : null,
      pid_lstart: typeof j.pid_lstart === 'string' ? j.pid_lstart : null,
    }
    if (j.watch === null) id.watch = null
    else if (typeof j.watch === 'string' && j.watch.startsWith('/')) id.watch = j.watch
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
}

/** `dispatch …` → `ok`; exit 3 `REFUSED: nonce-exists`. */
export async function dispatch(d: Deps, a: DispatchArgs): Promise<RunResult> {
  return call(d, [
    'dispatch', '--sid', a.sid, '--nonce', a.nonce, '--actor', a.actor, '--trigger', a.trigger,
    '--channel', a.channel, '--resume-pref', a.resumePref, '--tags', a.tags.join(','),
    '--midturn', a.midturn ? 'true' : 'false', '--instr-sha8', a.instrSha8, '--instr-bytes', String(a.instrBytes),
    '--cc-version', a.ccVersion ?? '', '--load-id', a.loadId,
  ])
}

/** Path of this session's newest main copy, or undefined (`none`, or a failed call). */
export async function prevCopy(d: Deps, sid: string): Promise<string | undefined> {
  const r = await call(d, ['prev-copy', '--sid', sid, '--actor', 'main'])
  const p = r.stdout.trim()
  return r.ok && p !== '' && p !== 'none' ? p : undefined
}

export type Checkpoint = { measured_block: string | null; lane: string | null; ms: Record<string, number> }

export async function checkpoint(d: Deps, sid: string, nonce: string, measured: boolean): Promise<Checkpoint | undefined> {
  const args = ['checkpoint', '--sid', sid, '--nonce', nonce, '--budget-ms', '10000']
  if (measured) args.push('--measured')
  const r = await call(d, args, CHECKPOINT_MS)
  if (!r.ok) return undefined
  try {
    const j = JSON.parse(r.stdout.trim()) as { measured_block?: unknown; lane?: unknown; checkpoint_ms?: unknown }
    return {
      measured_block: typeof j.measured_block === 'string' ? j.measured_block : null,
      lane: typeof j.lane === 'string' ? j.lane : null,
      ms: typeof j.checkpoint_ms === 'object' && j.checkpoint_ms !== null ? (j.checkpoint_ms as Record<string, number>) : {},
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
 */
export async function measure(d: Deps, sid: string, nonce?: string): Promise<string | undefined> {
  const r = await call(d, ['measure', '--sid', sid, '--compact', ...(nonce ? ['--nonce', nonce] : [])], CHECKPOINT_MS)
  return r.ok ? r.stdout.replace(/\s+$/, '') : undefined
}
