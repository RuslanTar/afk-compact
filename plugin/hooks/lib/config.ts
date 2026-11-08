// Options (MOD-SPEC §1.2), the threshold clamp, and the paths the mod writes under. Options are
// the only configuration source (no environment reads for configuration).
import type { PluginOptions } from 'claude-code'
import type { CompactWindow, Deps } from './deps'
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
  /**
   * `auto`: a handoff turn about 49 min into an idle episode (MOD-SPEC §9.4) while Claude Code's own
   * idle compaction is off (IA-1..3, idle D3: owner 2026-10-23 02:4x); `off`: none.
   */
  idle_handoff_turn: 'auto' | 'off'
  /** No pre-idle handoff turn below this context size. */
  idle_handoff_min_tokens: number
  /**
   * Owner xxxxxxxx (2026-10-30, "I want the handoff anyway"): `run` runs the idle handoff turn at
   * any usage share; `skip` skips it while a rate-limit window is at NEAR_LIMIT_PCT or more (idle.ts
   * `near-limit`); `skip-spend` (0.1.2) skips it only while a gateway's spend limit (a money cap)
   * is there, and runs it near a plan's five-hour or seven-day window. The plugin's idle compaction
   * keeps its own near-limit skip, any window, under every value.
   */
  idle_handoff_near_limit: 'run' | 'skip-spend' | 'skip'
  /**
   * `auto`: while Claude Code's own idle compaction is off in the settings (`"idleCompaction":
   * false`) and automatic compaction is on, the plugin compacts an idle main session itself about
   * 54 minutes after its last request (idle.ts, kind `compact`); while Claude Code's own is on or
   * unreadable, it compacts at the 55.5-min check when that one stayed silent (lane B; owner Q2);
   * `off`: never (the pre-idle handoff turn runs in its place).
   */
  idle_compact: 'auto' | 'off'
  /**
   * Away digest phase 1 (owner 2026-10-27 12:5x, xxxxxxxx-09): after an idle compaction whose work
   * lane is finished or blocked with nothing running, `submit` sends the digest turn right away;
   * `return` waits for the next turn (a person's return gets a short pointer first). `off` (owner
   * rule (c), 2026-10-28: the digest ships on only after a live PASS): no digest turn, and no text
   * asks for the full digest; a finished or blocked lane still starts nothing and gets one line on
   * the lane state with its Basis, then Needs you or Nothing needed from you.
   */
  idle_digest: 'submit' | 'return' | 'off'
  /**
   * Keep-warm (D-14, 2026-10-30; keepwarm.ts): while the main session is idle and one of its own
   * background jobs (an agent, a workflow, a background shell) is still open, the plugin keeps its
   * one-hour prompt cache warm with a hidden fork ping, for up to this many hours of the idle gap,
   * then hands over to the idle path (the handoff turn or the compaction) while the cache is warm.
   * `0`: off.
   */
  keep_warm_hours: number
  /** `watcher` reads as `off` (false, or the old `off`; SWITCH): no first-run notice. */
  watcher_off: boolean
  /**
   * Values replaced while parsing: `config_invalid` keys and `config_clamped` rows (logged once per
   * load); `noted` (present only when not empty): `config_note` rows for a value read another way
   * (IA-1: the old `idle_handoff_turn: on` reads as `auto`; D-72: a SWITCH key's word before 0.1.6).
   */
  notes: { invalid: string[]; clamped: { key: string; configured: number; effective: number }[]; noted?: { key: string; note: string }[] }
}

export const DEFAULTS: Config = {
  // STATE-ROOT (0.1.2): both out of ~/.claude, whose writes get Claude Code's protected-path prompt (helper
  // lib/paths.pm); NAME_TOKEN is the plugin's name (parseOptions), so a rename needs no edit here
  handoff_root: '~/.local/state/<plugin>/handoffs',
  log_dir: '',
  disposable_root: '~/.local/state/<plugin>/disposable',
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
  // Owner xxxxxxxx-18 (2026-10-23 01:48): `model`, E-1 checks it (PT-1); one value with the manifest.
  precompact_turn: 'model',
  unattended_prod_reads: 'forbid',
  idle_handoff_turn: 'auto',
  idle_handoff_min_tokens: 200000,
  // Owner xxxxxxxx (2026-10-30): "I want the handoff anyway"; skipping is the option.
  idle_handoff_near_limit: 'run',
  // Owner Q3 (2026-10-27 18:54, "auto ig. will set myself"); the release note says it.
  idle_compact: 'auto',
  // Owner xxxxxxxx-09 (2026-10-27 12:5x): "default setting: submit right away"; owner rule (c)
  // (2026-10-28): the away digest ships on only after a live PASS, else off. The live AD2 probe
  // failed the digest's text format, so 0.1.1 ships `off`; a later build flips this one value.
  idle_digest: 'off',
  // D-14 (2026-10-30): the decision model's cutoff, warm to 6 h then compact while warm.
  keep_warm_hours: 6,
  watcher_off: false,
  notes: { invalid: [], clamped: [] },
}

/** MOD-SPEC §1.2 `idle_handoff_min_tokens` bounds (the native idle floor, IC-1 F3). */
export const IDLE_TOKENS_MIN = 100000
export const IDLE_TOKENS_MAX = 1000000
/** `keep_warm_hours` bounds (0 = off; a day at most). */
export const KEEP_WARM_HOURS_MIN = 0
export const KEEP_WARM_HOURS_MAX = 24

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

/**
 * D-72 (0.1.6; owner 2026-11-08): the seven on/off options take `true` or `false` (userConfig
 * `options`, so /config opens a picker that shows the description; a boolean flips in place there).
 * In the plugin each still runs as its word before 0.1.6: SWITCH gives [the word `true` reads as,
 * the word `false` reads as]. A stored word of a release before 0.1.6 keeps its meaning: either word,
 * and for the two idle keys IDLE_AUTO_WORDS and IDLE_OFF_WORDS, with a `config_note` (`legacy-word`;
 * Claude Code reads such a value as unset, so this is for a value passed as it is stored). Never the
 * opposite, never an unknown word as true or false. settings.pm %SWITCH holds the same table.
 */
export const SWITCH = {
  handoff_turn: ['halt', 'off'], precompact_turn: ['model', 'code'], watcher: ['shadow', 'off'],
  unattended_prod_reads: ['allow', 'forbid'], idle_handoff_turn: ['auto', 'off'], idle_compact: ['auto', 'off'],
  resume_proceed: ['auto', 'confirm'],
} as const
type SwitchKey = keyof typeof SWITCH

/**
 * The SWITCH word a value reads as (trimmed, case-folded; a JSON boolean or number as its text), with
 * a `config_note` when it is not exactly `true` or `false`; undefined when unset; null for any other
 * value, which the key's own rule reads.
 */
function switchWord<K extends SwitchKey>(o: PluginOptions, k: K, notes: Config['notes']): (typeof SWITCH)[K][number] | null | undefined {
  const v = o[k]
  if (unset(v)) return undefined
  const t = typeof v === 'string' ? v.trim().toLowerCase() : typeof v === 'boolean' || typeof v === 'number' ? String(v) : ''
  const [on, off] = SWITCH[k]
  const idle = k === 'idle_handoff_turn' || k === 'idle_compact'
  const w = t === 'true' ? on : t === 'false' ? off : t === on || t === off ? t
    : idle && IDLE_AUTO_WORDS.includes(t) ? on : idle && IDLE_OFF_WORDS.includes(t) ? off : null
  if (w !== null && v !== 'true' && v !== 'false') {
    const note = k === 'idle_handoff_turn' && t === 'on' ? 'legacy-on' : 'legacy-word'
    notes.noted = [...(notes.noted ?? []), { key: k, note }]
  }
  return w as (typeof SWITCH)[K][number] | null
}

/** true or false (or a word before 0.1.6, SWITCH); anything else is the default plus a `config_invalid` note. */
function handoffTurn(o: PluginOptions, notes: Config['notes']): Config['handoff_turn'] {
  const w = switchWord(o, 'handoff_turn', notes)
  if (w === undefined) return DEFAULTS.handoff_turn
  if (w !== null) return w
  notes.invalid.push('handoff_turn')
  return DEFAULTS.handoff_turn
}

/** A SWITCH option: its word; unset gives the default; any other value gives `invalid` plus a `config_invalid` note. */
function switched<K extends 'precompact_turn' | 'unattended_prod_reads'>(o: PluginOptions, k: K, dflt: Config[K], invalid: Config[K], notes: Config['notes']): Config[K] {
  const w = switchWord(o, k, notes)
  if (w === undefined) return dflt
  if (w !== null) return w as Config[K]
  notes.invalid.push(k)
  return invalid
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
function bounded(o: PluginOptions, k: keyof Config, dflt: number, min: number, max: number, notes: Config['notes'], whole = true): number {
  const v = num(o, k, dflt)
  const n = whole ? Math.floor(v) : v
  const c = Math.max(min, Math.min(max, n))
  if (c !== n) notes.clamped.push({ key: k, configured: n, effective: c })
  return c
}

/**
 * `native_window_tokens`: 0 (or less) means the compaction window Claude Code settled (0.1.4
 * T-11, its summary context breakdown), else its `autoCompactWindow` setting when set (0.1.3,
 * settingWindow), else `context.window`; 1–99,999 count as 100,000, the
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

/**
 * Owner xxxxxxxx-13 (2026-10-26, "Off + common words"; SPEC-DELTAS IA-1 / AT-IA-01): an
 * `idle_handoff_turn` of `false`, `no`, `none`, `disabled` or `0` reads as `off`; `true`, `yes`, `1`
 * or `on` as `auto`; any other value reads as IDLE_INVALID_READS_AS, the value with no extra plugin
 * action, as for the other keys (`precompact_turn: code`, `unattended_prod_reads: forbid`).
 * settings.pm `@IDLE_OFF_WORDS`, `@IDLE_AUTO_WORDS` and `$IDLE_INVALID` hold the same lists and value.
 */
export const IDLE_OFF_WORDS: readonly string[] = ['off', 'false', 'no', 'none', 'disabled', '0']
export const IDLE_AUTO_WORDS: readonly string[] = ['auto', 'true', 'yes', '1', 'on']
export const IDLE_INVALID_READS_AS: Config['idle_handoff_turn'] = 'off'

/**
 * `idle_handoff_turn` (IA-1) and `idle_compact`: true or false, and the words before 0.1.6
 * (switchWord: the old `on` notes `legacy-on`); any other value is IDLE_INVALID_READS_AS plus
 * `config_invalid` (the owner's words switch the plugin turn off only when native idle is on, which
 * idle.ts checks; there is no forced on). settings.pm reads both the same way.
 */
function idleSwitch(o: PluginOptions, k: 'idle_handoff_turn' | 'idle_compact', notes: Config['notes']): Config['idle_handoff_turn'] {
  const w = switchWord(o, k, notes)
  if (w === undefined) return DEFAULTS[k]
  if (w !== null) return w
  notes.invalid.push(k)
  return IDLE_INVALID_READS_AS
}

function handoffTokens(o: PluginOptions, notes: Config['notes']): number {
  const n = Math.floor(num(o, 'handoff_turn_max_tokens', DEFAULTS.handoff_turn_max_tokens))
  const c = Math.max(HANDOFF_TOKENS_MIN, Math.min(HANDOFF_TOKENS_MAX, n))
  if (c !== n) notes.clamped.push({ key: 'handoff_turn_max_tokens', configured: n, effective: c })
  return c
}

/** The token in DEFAULTS.handoff_root and DEFAULTS.disposable_root that stands for the plugin's name (STATE-ROOT). */
export const NAME_TOKEN = '<plugin>'

/**
 * The options as the mod reads them. `name` (the plugin's, `$.plugin.name`, else `plugin` as in the
 * helper's ctx::brand) fills NAME_TOKEN in the handoff_root and disposable_root defaults; a load fills the manifest's
 * default in itself, so this is the fallback.
 */
export function parseOptions(o: PluginOptions, name?: string): Config {
  const notes: Config['notes'] = { invalid: [], clamped: [] }
  const root = DEFAULTS.handoff_root.split(NAME_TOKEN).join(name || 'plugin')
  const disposable = DEFAULTS.disposable_root.split(NAME_TOKEN).join(name || 'plugin')
  return {
    handoff_root: str(o, 'handoff_root', root),
    log_dir: str(o, 'log_dir', DEFAULTS.log_dir),
    disposable_root: str(o, 'disposable_root', disposable),
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
    precompact_turn: switched(o, 'precompact_turn', DEFAULTS.precompact_turn, 'code', notes),
    unattended_prod_reads: switched(o, 'unattended_prod_reads', 'forbid', 'forbid', notes),
    idle_handoff_turn: idleSwitch(o, 'idle_handoff_turn', notes),
    idle_handoff_min_tokens: bounded(o, 'idle_handoff_min_tokens', DEFAULTS.idle_handoff_min_tokens, IDLE_TOKENS_MIN, IDLE_TOKENS_MAX, notes),
    // Any other value is the default `run` (no legacy words); settings.pm reads it the same way.
    idle_handoff_near_limit: choice(o, 'idle_handoff_near_limit', ['run', 'skip-spend', 'skip'] as const, DEFAULTS.idle_handoff_near_limit, DEFAULTS.idle_handoff_near_limit, notes),
    idle_compact: idleSwitch(o, 'idle_compact', notes),
    // Any other value is `off`, the value with no extra plugin turn and no digest (rule (c)).
    idle_digest: choice(o, 'idle_digest', ['submit', 'return', 'off'] as const, DEFAULTS.idle_digest, 'off', notes),
    // Hours, fractions as given (1.5 is an hour and a half; /status reads the same value).
    keep_warm_hours: bounded(o, 'keep_warm_hours', DEFAULTS.keep_warm_hours, KEEP_WARM_HOURS_MIN, KEEP_WARM_HOURS_MAX, notes, false),
    watcher_off: switchWord(o, 'watcher', notes) === 'off',
    notes,
  }
}

/**
 * The clamp constants (MOD-SPEC §1.2, P5-FOLD A3, spec §16), one shared source with the helper's
 * `/status` and the watcher's fallback clamp: each key from the spec-literals `clamp` object when
 * it is a positive number there (`target_num`/`target_den` positive integers), else these values
 * (the same numbers; a parity test checks the two agree once the object ships).
 * - `native_offset`: the native trigger estimate (800K → ≈767K lab reading; probe P-10).
 * - `min_target`: below this effective target, plugin compactions and the nudge are disabled.
 * - `reserve_base`: `reserve` below the native trigger: one oversized nudge-carrying result
 *   25,000 + the checkpoint turn 12,000 + a margin of 15,000, plus the handoff turn's allowance.
 * - `reserve_no_handoff`: `reserve` when `handoff_turn` is off.
 * - `window_floor`: the smallest window Claude Code applies.
 * - `soft_ratio`: soft max ≤ ⌊`soft_ratio` × window⌋.
 * - `target_num` / `target_den`: target ≤ ⌊soft max × num / den⌋, two integers because a float
 *   2/3 gives 119,999 at soft max 180,000.
 * - `handoff_tokens_min` / `handoff_tokens_max`: the `handoff_turn_max_tokens` bounds.
 */
export type ClampConstants = {
  native_offset: number; min_target: number; reserve_base: number; reserve_no_handoff: number; window_floor: number
  soft_ratio: number; target_num: number; target_den: number; handoff_tokens_min: number; handoff_tokens_max: number
}
export const CLAMP_DEFAULTS: ClampConstants = {
  native_offset: 33000, min_target: 120000, reserve_base: 52000, reserve_no_handoff: 100000, window_floor: 100000,
  soft_ratio: 0.8, target_num: 2, target_den: 3, handoff_tokens_min: 20000, handoff_tokens_max: 150000,
}

export function clampConstants(v: unknown = specValue('clamp')): ClampConstants {
  if (typeof v !== 'object' || v === null || Array.isArray(v)) return CLAMP_DEFAULTS
  const o = v as Record<string, unknown>
  const k = { ...CLAMP_DEFAULTS }
  for (const key of Object.keys(CLAMP_DEFAULTS) as (keyof ClampConstants)[]) {
    const x = o[key]
    if (typeof x !== 'number' || !Number.isFinite(x) || x <= 0) continue
    if ((key === 'target_num' || key === 'target_den') && !Number.isInteger(x)) continue
    k[key] = x
  }
  return k
}

export const CLAMP: ClampConstants = clampConstants()
export const NATIVE_OFFSET = CLAMP.native_offset
export const MIN_TARGET = CLAMP.min_target
export const RESERVE_BASE = CLAMP.reserve_base
export const RESERVE_NO_HANDOFF = CLAMP.reserve_no_handoff
/** MOD-SPEC §1.2 `handoff_turn_max_tokens` bounds (the clamp object's `handoff_tokens_min`/`_max`). */
export const HANDOFF_TOKENS_MIN = CLAMP.handoff_tokens_min
export const HANDOFF_TOKENS_MAX = CLAMP.handoff_tokens_max

export function reserve(cfg: Config, k: ClampConstants = CLAMP): number {
  return cfg.handoff_turn === 'halt' ? k.reserve_base + cfg.handoff_turn_max_tokens : k.reserve_no_handoff
}

/** ⌊soft × `target_num` / `target_den`⌋ in integer steps (never a float 2/3). */
export function targetOf(soft: number, k: ClampConstants = CLAMP): number {
  return Math.floor((soft * k.target_num) / k.target_den)
}

/** ⌊`soft_ratio` × window⌋. */
export function softCap(window: number, k: ClampConstants = CLAMP): number {
  return Math.floor(k.soft_ratio * window)
}

export type Effective = {
  window: number
  native_trigger: number
  /**
   * 0.1.4 T-11: where the window came from: `option` (native_window_tokens), `breakdown` (Claude
   * Code's own compaction window, CompactWindow), `setting` (autoCompactWindow) or `context`
   * (the model's window); `autocompact_source` is the breakdown's autocompactSource, else null.
   */
  window_from: 'option' | 'breakdown' | 'setting' | 'context'
  autocompact_source: string | null
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
export function minWindow(cfg: Config, k: ClampConstants = CLAMP): number | 'never' {
  // The smallest soft max whose target reaches min_target, then the smallest window whose
  // soft cap gives it: integer steps from a close start, with the clamp's own expressions.
  let soft = Math.ceil((k.min_target * k.target_den) / k.target_num)
  while (soft > 0 && targetOf(soft - 1, k) >= k.min_target) soft--
  while (targetOf(soft, k) < k.min_target) soft++
  if (cfg.compact_soft_max_tokens < soft || cfg.compact_target_tokens < k.min_target) return 'never'
  let w = Math.ceil(soft / k.soft_ratio)
  while (w > 0 && softCap(w - 1, k) >= soft) w--
  while (softCap(w, k) < soft) w++
  return Math.max(soft + k.native_offset + reserve(cfg, k), w)
}

/**
 * 0.1.3: the window Claude Code's `autoCompactWindow` setting names, for a `native_window_tokens`
 * left unset (0): the floor applies as to the option, and Claude Code never compacts past the
 * model's own window, so a larger setting gives `contextWindow` (when known). Undefined when the
 * setting is unset or not a positive number.
 */
export function settingWindow(setting: number | undefined, contextWindow: number, k: ClampConstants = CLAMP): number | undefined {
  if (typeof setting !== 'number' || !Number.isFinite(setting) || setting <= 0) return undefined
  const w = Math.max(k.window_floor, Math.floor(setting))
  return contextWindow > 0 ? Math.min(w, contextWindow) : w
}

/**
 * MOD-SPEC §1.2 clamp. `contextWindow` is `$.session.usage().context.window`; `setting` is Claude
 * Code's `autoCompactWindow`, the window when `native_window_tokens` is unset (0.1.3; an option set
 * wins). `bd` (0.1.4 T-11), the compaction window Claude Code itself settled, comes before the
 * setting: its window is used as it is, and its threshold, when one is given at or below that
 * window, is the native trigger (else window − native_offset). With `triggers` false the
 * thresholds, the clamped list, `small_window` and `min_window` are computed as with triggers on
 * (P5-FOLD A3), so the row shows what triggers-on would do.
 */
export function clamp(cfg: Config, contextWindow: number, k: ClampConstants = CLAMP, setting?: number, bd?: CompactWindow): Effective {
  const sw = settingWindow(setting, contextWindow, k)
  const window_from: Effective['window_from'] = cfg.native_window_tokens > 0 ? 'option' : bd && bd.window > 0 ? 'breakdown' : sw !== undefined ? 'setting' : 'context'
  const window = window_from === 'option' ? cfg.native_window_tokens : window_from === 'breakdown' ? bd!.window : sw ?? contextWindow
  const t = window_from === 'breakdown' ? bd!.threshold : undefined
  const native_trigger = t !== undefined && t > 0 && t <= window ? t : window - k.native_offset
  const autocompact_source = window_from === 'breakdown' ? bd!.source ?? null : null
  const soft_max = Math.min(cfg.compact_soft_max_tokens, native_trigger - reserve(cfg, k), softCap(window, k))
  const target = Math.min(cfg.compact_target_tokens, targetOf(soft_max, k))
  const clamped: Effective['clamped'] = []
  if (soft_max < cfg.compact_soft_max_tokens) clamped.push({ key: 'soft_max', configured: cfg.compact_soft_max_tokens, effective: soft_max })
  if (target < cfg.compact_target_tokens) clamped.push({ key: 'target', configured: cfg.compact_target_tokens, effective: target })
  const small_window = target < k.min_target
  const disabled = !cfg.triggers ? 'triggers-off' : small_window ? 'trigger-disabled-small-window' : null
  return { window, native_trigger, window_from, autocompact_source, soft_max, target, disabled, small_window, min_window: minWindow(cfg, k), clamped }
}

/** Expands a leading `~` with the home folder; undefined when it cannot. */
export function expand(path: string, home: string | undefined): string | undefined {
  if (path === '~') return home
  if (path.startsWith('~/')) return home === undefined ? undefined : home.replace(/\/+$/, '') + path.slice(1)
  return path
}

export type Paths = { root: string; watch: string }

/** Where the handoff_root default sits below the home folder (STATE-ROOT): `$XDG_STATE_HOME` stands for it. */
const STATE_HOME_DEFAULT = '~/.local/state'

/**
 * The handoff root a value names, `~` expanded (STATE-ROOT). The default (DEFAULTS.handoff_root with
 * `name`, else `plugin`) reads under `stateHome` (`$XDG_STATE_HOME`) when that is an absolute path, as
 * the helper's paths::state_default does: the XDG Base Directory rule ignores a relative value. Any
 * other value is returned as it is; undefined when `~` cannot be expanded.
 */
export function stateRoot(value: string, home: string | undefined, stateHome?: string, name?: string): string | undefined {
  const root = expand(value, home)
  if (root === undefined || stateHome === undefined || !stateHome.startsWith('/')) return root
  const def = DEFAULTS.handoff_root.split(NAME_TOKEN).join(name || 'plugin')
  if (!def.startsWith(STATE_HOME_DEFAULT + '/')) return root
  const norm = (p: string | undefined) => p?.replace(/\/+/g, '/').replace(/(.)\/$/, '$1')
  if (norm(root) !== norm(expand(def, home))) return root
  return stateHome.replace(/\/+$/, '') + def.slice(STATE_HOME_DEFAULT.length)
}

/**
 * `<root>` and `<watch>` (MOD-SPEC conventions); undefined when `~` cannot be expanded. `state` gives
 * `$XDG_STATE_HOME` and the plugin's name for the default root (stateRoot).
 */
export function paths(cfg: Config, home: string | undefined, state?: { home?: string; name?: string }): Paths | undefined {
  const root = stateRoot(cfg.handoff_root, home, state?.home, state?.name)
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
  // 0.1.4 T-11: an unset native_window_tokens follows the compaction window Claude Code settled
  // (the summary breakdown); without one, its autoCompactWindow setting (0.1.3).
  let setting: number | undefined
  let bd: CompactWindow | undefined
  if (!(d.cfg.native_window_tokens > 0)) {
    try {
      bd = await d.compactWindow?.()
    } catch {
      bd = undefined
    }
    if (bd === undefined) {
      try {
        setting = await d.compactWindowSetting?.()
      } catch {
        setting = undefined
      }
    }
  }
  const eff = clamp(d.cfg, window, CLAMP, setting, bd)
  d.state.eff = eff
  // Disabled: the thresholds are null and the computed values go in the `_raw` fields, which no
  // reader takes as thresholds (they can be negative, P5-FOLD A3).
  const off = eff.disabled !== null
  await log(d, sid, 'config_effective', {
    window: eff.window,
    window_from: eff.window_from,
    autocompact_source: eff.autocompact_source,
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
  for (const n of d.cfg.notes.noted ?? []) await log(d, sid, 'config_note', { key: n.key, note: n.note })
  if (eff.disabled === 'triggers-off') await log(d, sid, 'triggers_off', {})
  if (eff.disabled === 'trigger-disabled-small-window') await log(d, sid, 'trigger_disabled_small_window', { target: eff.target, window: eff.window })
  return eff
}
