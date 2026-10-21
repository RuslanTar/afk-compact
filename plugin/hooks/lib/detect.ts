// Marker/sentinel detector, verdict table (MOD-SPEC §5.1) and the unanchored instruction-marker
// search (MOD-SPEC §2.2). Literals come from the spec-literals block (spec.gen.ts); until that
// block exists the grammar falls back to MOD-SPEC §2.2 with the run-time plugin name.
import { SPEC } from './spec.gen'
import { strip } from './normalize'
import { sha256 } from './normalize'

export type Verdict = 'stale' | 'scope-leak' | 'unshaped' | 'truncated' | 'ok-trailer' | 'ok'
export type Scope = 'main' | 'sub' | 'manual'

/** Reads one key of the spec-literals block, or undefined when the block or key is absent. */
export function specValue(key: string): unknown {
  return (SPEC as unknown as Record<string, unknown>)[key]
}

function specString(key: string): string | undefined {
  const v = specValue(key)
  return typeof v === 'string' && v !== '' ? v : undefined
}

function specStrings(key: string): string[] {
  const v = specValue(key)
  return Array.isArray(v) ? v.filter((x): x is string => typeof x === 'string') : []
}

function esc(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

export type Grammar = {
  /** Anchored summary marker; group 1 nonce, group 2 scope. */
  marker: RegExp
  /** Anchored sentinel; group 1 nonce. */
  sentinel: RegExp
  /** Unanchored instruction marker source; group 1 nonce, group 2 scope. */
  instr: string
}

export function grammar(plugin: string): Grammar {
  const p = esc(plugin)
  const marker = specString('marker_re') ?? `^⟪${p} v1 n=([0-9a-f]{8}) s=(main|sub|manual)⟫$`
  const sentinel = specString('sentinel_re') ?? `^⟪/${p} n=([0-9a-f]{8})⟫$`
  const instr = specString('instr_marker_re') ?? `⟪${p} v1 n=([0-9a-f]{8}) s=(main|sub)⟫`
  return { marker: new RegExp(marker), sentinel: new RegExp(sentinel), instr }
}

/**
 * The main form's Resume-here heading literal: from the spec block (`sections_main`, the entry
 * after the title), else the CONSISTENCY §1 literal until the block exists.
 */
function resumeHeading(): string {
  return specStrings('sections_main').find(h => h.startsWith('## Resume')) ?? '## Resume here'
}

export type DetectContext = {
  /** The dispatch this compaction belongs to, when known. */
  dispatchNonce?: string
  /** Proven scope of the compaction (mod path: always known). */
  scope?: 'main' | 'sub'
  /** Boundary `precomputed: true`. */
  precomputed?: boolean
  /** PostCompact with no preceding dispatch at all. */
  noDispatch?: boolean
}

export type Detection = {
  verdict: Verdict
  /** 1-based body line of the marker, or null. */
  marker_line: number | null
  /** 1 = last non-blank line, or null. */
  sentinel_from_end: number | null
  nonce: string | null
  scope: Scope | null
  normalized: string
  sha256: string
}

/** Detector of MOD-SPEC §5.1 over one summary text. */
export function detectSummary(raw: string, plugin: string, ctx: DetectContext = {}): Detection {
  const g = grammar(plugin)
  const { lines, body } = strip(raw, specStrings('copy_trailers'))
  let markerLine: number | null = null
  let nonce: string | null = null
  let scope: Scope | null = null
  for (let i = 0; i < Math.min(5, lines.length); i++) {
    const m = g.marker.exec(lines[i] ?? '')
    if (m) {
      markerLine = i + 1
      nonce = m[1] ?? null
      scope = (m[2] as Scope | undefined) ?? null
      break
    }
  }
  let sentinelFromEnd: number | null = null
  let sentinelNonce: string | null = null
  let k = 0
  for (let i = lines.length - 1; i >= 0 && k < 3; i--) {
    const line = lines[i] ?? ''
    if (line.trim() === '') continue
    k++
    const m = g.sentinel.exec(line)
    if (m) {
      sentinelFromEnd = k
      sentinelNonce = m[1] ?? null
      break
    }
  }
  const verdict = judge()
  return {
    verdict,
    marker_line: markerLine,
    sentinel_from_end: sentinelFromEnd,
    nonce,
    scope,
    normalized: body,
    sha256: sha256(body),
  }

  function judge(): Verdict {
    if (ctx.precomputed) return 'stale'
    if (nonce !== null && ctx.noDispatch) return 'stale'
    if (nonce !== null && ctx.dispatchNonce !== undefined && nonce !== ctx.dispatchNonce) return 'stale'
    if (ctx.scope === 'sub' && (scope === 'main' || (scope === null && hasResumeHeading()))) return 'scope-leak'
    if (ctx.scope === 'main' && scope === 'sub') return 'scope-leak'
    if (nonce === null) return 'unshaped'
    if (sentinelFromEnd === null || sentinelNonce !== nonce) return 'truncated'
    if (sentinelFromEnd > 1) return 'ok-trailer'
    return 'ok'
  }

  function hasResumeHeading(): boolean {
    const h = resumeHeading()
    return lines.some(l => l.startsWith(h))
  }
}

/** A verdict readers treat as ok (CONSISTENCY §1). */
export function isOk(v: Verdict): boolean {
  return v === 'ok' || v === 'ok-trailer'
}

export type InstrMarker = { nonce: string; scope: 'main' | 'sub' }

/**
 * The last unanchored marker in instruction text (MOD-SPEC §2.2). Whether it is "ours for this
 * dispatch" depends on a dispatch record, which the caller checks.
 */
export function lastInstrMarker(text: string | undefined, plugin: string): InstrMarker | undefined {
  if (!text) return undefined
  const re = new RegExp(grammar(plugin).instr, 'g')
  let last: InstrMarker | undefined
  for (let m = re.exec(text); m !== null; m = re.exec(text)) {
    if (m[1] && (m[2] === 'main' || m[2] === 'sub')) last = { nonce: m[1], scope: m[2] }
    if (m[0] === '') re.lastIndex++
  }
  return last
}
