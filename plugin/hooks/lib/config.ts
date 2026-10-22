// Options (MOD-SPEC §1.2), the threshold clamp, and the paths the mod writes under. Options are
// the only configuration source (no environment reads for configuration).
import type { PluginOptions } from 'claude-code'
import type { Deps } from './deps'
import { specValue } from './detect'
import { log } from './log'

export type Config = {
  handoff_root: string
  log_dir: string
  disposable_root: string
  triggers: boolean
  compact_target_tokens: number
  compact_soft_max_tokens: number
  native_window_tokens: number
  boundary_delay_ms: number
  cooldown_ms: number
  max_auto_continues_per_hour: number
  measured_block: boolean
  auto_evidence: boolean
  warn_ui: boolean
  /** `halt`: a last cycle gets a handoff turn before its compaction (MOD-SPEC §9.1); `off`: none. */
  handoff_turn: 'halt' | 'off'
  handoff_turn_max_tokens: number
  /** The queue tool (MOD-SPEC §10.3); empty = off. The mod only reads whether it is set. */
  queue_cmd: string
  /** `model`: a handoff turn before a turn-end compaction (MOD-SPEC §9.3); `code`: checkpoint only. */
  precompact_turn: 'model' | 'code'
  /** `allow` keeps the resume block's `[prod-allow]` line when the checkpoint agrees (text tag only, §3.4). */
  unattended_prod_reads: 'forbid' | 'allow'
  /** `on`: a handoff turn about 49 min into an idle episode (MOD-SPEC §9.4); `off`: none. */
  idle_handoff_turn: 'off' | 'on'
  /** No pre-idle handoff turn below this context size. */
  idle_handoff_min_tokens: number
  /** Values replaced while parsing: `config_invalid` keys and `config_clamped` rows (logged once per load). */
  notes: { invalid: string[]; clamped: { key: string; configured: number; effective: number }[] }
}

export const DEFAULTS: Config = {
  handoff_root: '~/.claude/handoffs',
  log_dir: '',
  disposable_root: '~/.claude/trash-staging',
  triggers: true,
  compact_target_tokens: 400000,
  compact_soft_max_tokens: 600000,
  native_window_tokens: 0,
  boundary_delay_ms: 2000,
  cooldown_ms: 30000,
  max_auto_continues_per_hour: 6,
  measured_block: false,
  auto_evidence: true,
  warn_ui: true,
  handoff_turn: 'halt',
  handoff_turn_max_tokens: 64000,
  queue_cmd: '',
  precompact_turn: 'code',
  unattended_prod_reads: 'forbid',
  idle_handoff_turn: 'off',
  idle_handoff_min_tokens: 200000,
  notes: { invalid: [], clamped: [] },
}

/** MOD-SPEC §1.2 `handoff_turn_max_tokens` bounds. */
export const HANDOFF_TOKENS_MIN = 20000
export const HANDOFF_TOKENS_MAX = 150000
/** MOD-SPEC §1.2 `idle_handoff_min_tokens` bounds (the native idle floor, IC-1 F3). */
export const IDLE_TOKENS_MIN = 100000
export const IDLE_TOKENS_MAX = 1000000

/** Empty values and unsubstituted `${user_config.…` count as unset (MOD-SPEC §2.6). */
function unset(v: unknown): boolean {
  return v === undefined || v === null || (typeof v === 'string' && (v.trim() === '' || v.startsWith('${user_config.')))
}

function str(o: PluginOptions, k: keyof Config, d: string): string {
  const v = o[k]
  return unset(v) || typeof v !== 'string' ? d : v
}

function num(o: PluginOptions, k: keyof Config, d: number): number {
  const v = o[k]
  if (unset(v)) return d
  const n = typeof v === 'number' ? v : typeof v === 'string' ? Number(v) : NaN
  return Number.isFinite(n) ? n : d
}

function bool(o: PluginOptions, k: keyof Config, d: boolean): boolean {
  const v = o[k]
  if (typeof v === 'boolean') return v
  if (v === 'true') return true
  if (v === 'false') return false
  return d
}

/** `halt` or `off` (trimmed, case-folded); anything else is the default plus a `config_invalid` note. */
function handoffTurn(o: PluginOptions, notes: Config['notes']): Config['handoff_turn'] {
  const v = o['handoff_turn']
  if (unset(v)) return DEFAULTS.handoff_turn
  const t = typeof v === 'string' ? v.trim().toLowerCase() : ''
  if (t === 'halt' || t === 'off') return t
  notes.invalid.push('handoff_turn')
  return DEFAULTS.handoff_turn
}

/**
 * A string option with a fixed value set: trimmed and case-folded; unset gives the default; any
 * other value gives `invalid` (which need not be the default) plus a `config_invalid` note.
 */
function choice<T extends string>(o: PluginOptions, k: keyof Config, values: readonly T[], dflt: T, invalid: T, notes: Config['notes']): T {
  const v = o[k]
  if (unset(v)) return dflt
  const t = typeof v === 'string' ? v.trim().toLowerCase() : ''
  const hit = values.find(x => x === t)
  if (hit !== undefined) return hit
  notes.invalid.push(k)
  return invalid
}

/** A number option clamped to [min, max] (floored), with a `config_clamped` note when it moved. */
function bounded(o: PluginOptions, k: keyof Config, dflt: number, min: number, max: number, notes: Config['notes']): number {
  const n = Math.floor(num(o, k, dflt))
  const c = Math.max(min, Math.min(max, n))
  if (c !== n) notes.clamped.push({ key: k, configured: n, effective: c })
  return c
}

/**
 * `native_window_tokens`: 0 (or less) means `context.window`; 1–99,999 count as 100,000, the
 * smallest window Claude Code applies (`--autocompact` floor, P5-FOLD A3), with `config_clamped`.
 */
function nativeWindow(o: PluginOptions, notes: Config['notes']): number {
  const n = num(o, 'native_window_tokens', DEFAULTS.native_window_tokens)
  if (!(n > 0)) return 0
  const floor = CLAMP.window_floor
  if (n >= floor) return n
  notes.clamped.push({ key: 'native_window_tokens', configured: n, effective: floor })
  return floor
}

function handoffTokens(o: PluginOptions, notes: Config['notes']): number {
  const n = Math.floor(num(o, 'handoff_turn_max_tokens', DEFAULTS.handoff_turn_max_tokens))
  const c = Math.max(HANDOFF_TOKENS_MIN, Math.min(HANDOFF_TOKENS_MAX, n))
  if (c !== n) notes.clamped.push({ key: 'handoff_turn_max_tokens', configured: n, effective: c })
  return c
}

export function parseOptions(o: PluginOptions): Config {
  const notes: Config['notes'] = { invalid: [], clamped: [] }
  return {
    handoff_root: str(o, 'handoff_root', DEFAULTS.handoff_root),
    log_dir: str(o, 'log_dir', DEFAULTS.log_dir),
    disposable_root: str(o, 'disposable_root', DEFAULTS.disposable_root),
    triggers: bool(o, 'triggers', DEFAULTS.triggers),
    compact_target_tokens: num(o, 'compact_target_tokens', DEFAULTS.compact_target_tokens),
    compact_soft_max_tokens: num(o, 'compact_soft_max_tokens', DEFAULTS.compact_soft_max_tokens),
    native_window_tokens: nativeWindow(o, notes),
    boundary_delay_ms: num(o, 'boundary_delay_ms', DEFAULTS.boundary_delay_ms),
    cooldown_ms: num(o, 'cooldown_ms', DEFAULTS.cooldown_ms),
    max_auto_continues_per_hour: Math.max(0, Math.min(10, Math.floor(num(o, 'max_auto_continues_per_hour', DEFAULTS.max_auto_continues_per_hour)))),
    measured_block: bool(o, 'measured_block', DEFAULTS.measured_block),
    auto_evidence: bool(o, 'auto_evidence', DEFAULTS.auto_evidence),
    warn_ui: bool(o, 'warn_ui', DEFAULTS.warn_ui),
    handoff_turn: handoffTurn(o, notes),
    handoff_turn_max_tokens: handoffTokens(o, notes),
    queue_cmd: str(o, 'queue_cmd', DEFAULTS.queue_cmd).trim(),
    // Any other value is `code`, the as-built path with no extra turn (S-SETTINGS D).
    precompact_turn: choice(o, 'precompact_turn', ['model', 'code'] as const, DEFAULTS.precompact_turn, 'code', notes),
    unattended_prod_reads: choice(o, 'unattended_prod_reads', ['forbid', 'allow'] as const, 'forbid', 'forbid', notes),
    idle_handoff_turn: choice(o, 'idle_handoff_turn', ['off', 'on'] as const, 'off', 'off', notes),
    idle_handoff_min_tokens: bounded(o, 'idle_handoff_min_tokens', DEFAULTS.idle_handoff_min_tokens, IDLE_TOKENS_MIN, IDLE_TOKENS_MAX, notes),
    notes,
  }
}

/**
 * The clamp constants (MOD-SPEC §1.2, P5-FOLD A3), one shared source with the helper and the
 * watcher's fallback clamp: the spec-literals `clamp` object when it holds all five numbers,
 * else these values (the same numbers; a parity test checks the two agree once the object ships).
 * - `native_offset`: the native trigger estimate (800K → ≈767K lab reading; probe P-10).
 * - `min_target`: below this effective target, plugin compactions and the nudge are disabled.
 * - `reserve_base`: `reserve` below the native trigger: one oversized nudge-carrying result
 *   25,000 + the checkpoint turn 12,000 + a margin of 15,000, plus the handoff turn's allowance.
 * - `reserve_no_handoff`: `reserve` when `handoff_turn` is off.
 * - `window_floor`: the smallest window Claude Code applies.
 */
export type ClampConstants = { native_offset: number; min_target: number; reserve_base: number; reserve_no_handoff: number; window_floor: number }
export const CLAMP_DEFAULTS: ClampConstants = { native_offset: 33000, min_target: 120000, reserve_base: 52000, reserve_no_handoff: 100000, window_floor: 100000 }

export function clampConstants(v: unknown = specValue('clamp')): ClampConstants {
  if (typeof v !== 'object' || v === null) return CLAMP_DEFAULTS
  const o = v as Record<string, unknown>
  const keys = Object.keys(CLAMP_DEFAULTS) as (keyof ClampConstants)[]
  if (!keys.every(k => typeof o[k] === 'number' && Number.isFinite(o[k]))) return CLAMP_DEFAULTS
  return Object.fromEntries(keys.map(k => [k, o[k] as number])) as ClampConstants
}

export const CLAMP: ClampConstants = clampConstants()
export const NATIVE_OFFSET = CLAMP.native_offset
export const MIN_TARGET = CLAMP.min_target
export const RESERVE_BASE = CLAMP.reserve_base
export const RESERVE_NO_HANDOFF = CLAMP.reserve_no_handoff

export function reserve(cfg: Config): number {
  return cfg.handoff_turn === 'halt' ? RESERVE_BASE + cfg.handoff_turn_max_tokens : RESERVE_NO_HANDOFF
}

export type Effective = {
  window: number
  native_trigger: number
  /** The computed thresholds (the raw values: negative on a tiny window; read only when enabled). */
  soft_max: number
  target: number
  /** Why plugin compactions and the nudge are off, or null when on. */
  disabled: 'triggers-off' | 'trigger-disabled-small-window' | null
  /** The computed target is below `min_target` (also computed with triggers off). */
  small_window: boolean
  /** The smallest window that stays enabled under these settings, or `never`. */
  min_window: number | 'never'
  clamped: { key: string; configured: number; effective: number }[]
}

/**
 * MOD-SPEC §1.2 `min_window`: target ≥ `min_target` needs soft max ≥ 1.5 × `min_target`
 * (180,000), so `window − native_offset − reserve` and `0.8 × window` must reach it:
 * `max(213,000 + reserve, 225,000)` with the defaults (329,000; `handoff_turn` off 313,000).
 * Configured values below those floors can never enable: `never`.
 */
export function minWindow(cfg: Config): number | 'never' {
  const soft = Math.ceil((MIN_TARGET * 3) / 2)
  if (cfg.compact_soft_max_tokens < soft || cfg.compact_target_tokens < MIN_TARGET) return 'never'
  return Math.max(soft + NATIVE_OFFSET + reserve(cfg), Math.ceil(soft / 0.8))
}

/**
 * MOD-SPEC §1.2 clamp. `contextWindow` is `$.session.usage().context.window`. With `triggers`
 * false the thresholds, the clamped list, `small_window` and `min_window` are computed as with
 * triggers on (P5-FOLD A3), so the row shows what triggers-on would do.
 */
export function clamp(cfg: Config, contextWindow: number): Effective {
  const window = cfg.native_window_tokens > 0 ? cfg.native_window_tokens : contextWindow
  const native_trigger = window - NATIVE_OFFSET
  const soft_max = Math.min(cfg.compact_soft_max_tokens, native_trigger - reserve(cfg), Math.floor(0.8 * window))
  const target = Math.min(cfg.compact_target_tokens, Math.floor((soft_max * 2) / 3))
  const clamped: Effective['clamped'] = []
  if (soft_max < cfg.compact_soft_max_tokens) clamped.push({ key: 'soft_max', configured: cfg.compact_soft_max_tokens, effective: soft_max })
  if (target < cfg.compact_target_tokens) clamped.push({ key: 'target', configured: cfg.compact_target_tokens, effective: target })
  const small_window = target < MIN_TARGET
  const disabled = !cfg.triggers ? 'triggers-off' : small_window ? 'trigger-disabled-small-window' : null
  return { window, native_trigger, soft_max, target, disabled, small_window, min_window: minWindow(cfg), clamped }
}

/** Expands a leading `~` with the home folder; undefined when it cannot. */
export function expand(path: string, home: string | undefined): string | undefined {
  if (path === '~') return home
  if (path.startsWith('~/')) return home === undefined ? undefined : home.replace(/\/+$/, '') + path.slice(1)
  return path
}

export type Paths = { root: string; watch: string }

/** `<root>` and `<watch>` (MOD-SPEC conventions); undefined when `~` cannot be expanded. */
export function paths(cfg: Config, home: string | undefined): Paths | undefined {
  const root = expand(cfg.handoff_root, home)
  if (root === undefined) return undefined
  const watch = cfg.log_dir === '' ? root.replace(/\/+$/, '') + '/.watch' : expand(cfg.log_dir, home)
  if (watch === undefined) return undefined
  return { root: root.replace(/\/+$/, ''), watch: watch.replace(/\/+$/, '') }
}

/**
 * The options as `CLAUDE_PLUGIN_OPTION_<KEY>` variables for helper calls, so the helper resolves
 * the same settings the mod runs with (MOD-SPEC §2.6 settings order, second step).
 */
export function optionEnv(o: PluginOptions): Record<string, string> {
  const env: Record<string, string> = {}
  for (const [k, v] of Object.entries(o)) {
    if (v === undefined || v === null) continue
    env['CLAUDE_PLUGIN_OPTION_' + k.toUpperCase()] = Array.isArray(v) ? v.join(',') : String(v)
  }
  return env
}

/**
 * Computes the effective thresholds once per load (a `/config` change reloads the module) and
 * logs `config_effective`, one `config_clamped` per clamped value, one `config_invalid` per
 * replaced value, and `triggers_off` or `trigger_disabled_small_window`.
 */
export async function effective(d: Deps, sid: string): Promise<Effective> {
  if (d.state.eff) return d.state.eff
  let window = 0
  try {
    window = (await d.usage()).window
  } catch {
    window = 0
  }
  const eff = clamp(d.cfg, window)
  d.state.eff = eff
  // Disabled: the thresholds are null and the computed values go in the `_raw` fields, which no
  // reader takes as thresholds (they can be negative, P5-FOLD A3).
  const off = eff.disabled !== null
  await log(d, sid, 'config_effective', {
    window: eff.window,
    native_offset: NATIVE_OFFSET,
    native_trigger: eff.native_trigger,
    reserve: reserve(d.cfg),
    soft_max: off ? null : eff.soft_max,
    target: off ? null : eff.target,
    soft_max_raw: eff.soft_max,
    target_raw: eff.target,
    disabled: eff.disabled,
    small_window: eff.small_window,
    min_window: eff.min_window,
    clamped: eff.clamped.map(c => c.key),
  })
  for (const c of [...d.cfg.notes.clamped, ...eff.clamped]) await log(d, sid, 'config_clamped', { key: c.key, configured: c.configured, effective: c.effective })
  for (const key of d.cfg.notes.invalid) await log(d, sid, 'config_invalid', { key })
  if (eff.disabled === 'triggers-off') await log(d, sid, 'triggers_off', {})
  if (eff.disabled === 'trigger-disabled-small-window') await log(d, sid, 'trigger_disabled_small_window', { target: eff.target, window: eff.window })
  return eff
}
