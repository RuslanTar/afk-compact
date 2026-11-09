// Deps: everything a handler needs from the engine, as one interface, plus the real `$`-backed
// implementation. Handlers take Deps, never `$`, so a test can run them through the kit (where
// test hooks answer `$`) or with a fake Deps.
import type { EngineInterface, PluginOptions, SessionCompactResult } from 'claude-code'
import type { ResumePref } from './compact'
import type { Config, Effective, Paths } from './config'
import type { HandoffTurn, HaltReason, Published } from './handoff-turn'
import type { BgTasks, KeepWarm } from './keepwarm'
import type { BlockArgs } from './resume'
import type { Lane, LaneFacts, LaneResult } from './lane'
import type { RestartEnv, RestartReport, RestartRun, RestartSetting } from './restart'
import { optionEnv, parseOptions, paths } from './config'
import { launchDir } from './launch.gen'
import { zoneOfPath } from './log'

export type RunResult = {
  /** True when the command ran and exited 0. */
  ok: boolean
  /** Exit code, or null when the call rejected (could not start, or timed out). */
  exitCode: number | null
  stdout: string
  /** `rejected: <message>` when the call rejected, else the child's stderr. */
  error: string
}

/**
 * `rateLimits` keeps each window's `kind` (`five_hour`, `seven_day`, a gateway's `spend_limit`;
 * `''` when the engine gave none): only a plan window is evidence of the one-hour cache (D15).
 */
export type Usage = { tokens: number | undefined; window: number; rateLimits: { kind: string; percentUsed: number }[] }
/**
 * 0.1.4 T-11: the compaction window as Claude Code settled it, from the `summary` context breakdown
 * (`$.session.usage({ breakdown: 'summary' })`, estimated locally: no token-count request):
 * `window` its `rawMaxTokens`, `threshold` its `autoCompactThreshold` (absent while auto-compaction
 * is off), `source` its `autocompactSource` (env, settings, clientdata, experiment, model-default,
 * unknown-model or auto: the model's own limit).
 */
export type CompactWindow = { window: number; threshold?: number; source?: string }

/** Claude Code's own native idle compaction as the merged settings and its environment say (§1.1). */
export type NativeIdle = 'on' | 'vetoed' | 'compaction-off' | 'unknown'

/**
 * The environment the idle timers read once per load (§5): Claude Code's own
 * `CLAUDE_CODE_IDLE_COMPACT_MIN_TOKENS` (`compactMin`, as native parses it), the test seam
 * `STORE_TEST_IDLE_CACHE_S` (`cacheS`, 120–3600, else undefined), the `DISABLE_PROMPT_CACHING*`
 * names native's cache check reads (`cacheOff`) and Claude Code's prompt-cache TTL switches for
 * the main conversation (`ttl`, TtlEnv).
 */
export type IdleEnv = { compactMin: number; cacheS: number | undefined; cacheOff: boolean; ttl: TtlEnv }

/** A prompt-cache TTL as Claude Code names one (`promptCacheTtl`, `CLAUDE_CODE_PROMPT_CACHE_TTL`). */
export type CacheTtl = '5m' | '1h'

/**
 * The main conversation's prompt-cache TTL switches in Claude Code's environment, in its own order
 * (2.1.311, the TTL pick for the main thread): `first` is `5m` when `FORCE_PROMPT_CACHING_5M` is
 * set, else `CLAUDE_CODE_PROMPT_CACHE_TTL` (`5m` or `1h`); both outrank the `promptCacheTtl`
 * setting. `enable1h` (`ENABLE_PROMPT_CACHING_1H`) ranks below the setting. `messages5m`
 * (`CLAUDE_CODE_MESSAGES_PROMPT_CACHE_TTL` `5m`) makes the conversation's own cache five minutes
 * whatever the others say.
 */
export type TtlEnv = { first: CacheTtl | undefined; enable1h: boolean; messages5m: boolean }

/** No TTL switch set: the TTL is Claude Code's automatic one. */
export const TTL_ENV_NONE: TtlEnv = { first: undefined, enable1h: false, messages5m: false }

/** An env TTL value as Claude Code's enum read takes one: trimmed, one of `words` exactly, else undefined. */
function ttlWord(v: string | undefined, words: readonly CacheTtl[]): CacheTtl | undefined {
  const t = (v ?? '').trim()
  return words.find(w => w === t)
}

/** TtlEnv from the four variables' raw values (undefined: unset). */
export function ttlEnvOf(v: { force5m?: string; ttl?: string; enable1h?: string; messages?: string }): TtlEnv {
  return {
    first: envTruthy(v.force5m) ? '5m' : ttlWord(v.ttl, ['5m', '1h']),
    enable1h: envTruthy(v.enable1h),
    messages5m: ttlWord(v.messages, ['5m']) === '5m',
  }
}

/**
 * The main conversation's cache TTL as Claude Code picks it from its switches and the merged
 * `promptCacheTtl` setting (`setting`, any value: only `5m` and `1h` count), or undefined when
 * none is set (automatic: one hour on a subscription within its limits, five minutes otherwise).
 */
export function cacheTtlOf(t: TtlEnv, setting: unknown): CacheTtl | undefined {
  const s = setting === '5m' || setting === '1h' ? setting : undefined
  const v = t.first ?? s ?? (t.enable1h ? '1h' : undefined)
  return t.messages5m ? '5m' : v
}

/** Native `IXt`: no idle compaction below this context size by default, and never below the floor. */
export const IDLE_COMPACT_MIN_DEFAULT = 200000
export const IDLE_COMPACT_MIN_FLOOR = 100000
/** D10: the test seam's bounds, in seconds of a simulated prompt-cache hour. */
export const IDLE_CACHE_S_MIN = 120
export const IDLE_CACHE_S_MAX = 3600

/** An environment flag as Claude Code reads one: trimmed, case-folded `1`, `true`, `yes` or `on`. */
export function envTruthy(v: string | undefined): boolean {
  return v !== undefined && ['1', 'true', 'yes', 'on'].includes(v.trim().toLowerCase())
}

/** `CLAUDE_CODE_IDLE_COMPACT_MIN_TOKENS` (native `IXt`): a positive integer gives max(100,000, v), else 200,000. */
export function compactMinOf(v: string | undefined): number {
  const t = (v ?? '').trim()
  if (!/^[0-9]+$/.test(t)) return IDLE_COMPACT_MIN_DEFAULT
  const n = Number(t)
  return Number.isSafeInteger(n) && n > 0 ? Math.max(IDLE_COMPACT_MIN_FLOOR, n) : IDLE_COMPACT_MIN_DEFAULT
}

/** `STORE_TEST_IDLE_CACHE_S` (D10): an integer from 120 to 3600, else undefined (ignored). */
export function cacheSOf(v: string | undefined): number | undefined {
  const t = (v ?? '').trim()
  if (!/^[0-9]+$/.test(t)) return undefined
  const n = Number(t)
  return n >= IDLE_CACHE_S_MIN && n <= IDLE_CACHE_S_MAX ? n : undefined
}

/** The four token counts of one model request (`ModelUsage`), as far as this module reads them. */
export type RequestUsage = { input_tokens: number; cache_read_input_tokens: number; cache_creation_input_tokens: number }

/** A token count of a usage as a non-negative number (anything else counts 0). */
const tokensOf = (x: unknown): number => (typeof x === 'number' && Number.isFinite(x) && x > 0 ? x : 0)

/**
 * MG-3: the share of a request's input the prompt cache served, `cache_read_input_tokens` over
 * all input tokens (uncached + read + written), to 3 places; null with no usage or no input. A
 * request on another model than the session's cannot read the session's cache, so a low share
 * at a large context is the observable sign of one. A main request's cache marker sits on its
 * last message, so its uncached input is small; a compaction's is not (see `prefixRead`).
 */
export function readShare(u: RequestUsage | null | undefined): number | null {
  if (!u) return null
  const read = tokensOf(u.cache_read_input_tokens)
  const total = tokensOf(u.input_tokens) + read + tokensOf(u.cache_creation_input_tokens)
  return total > 0 ? Math.round((read / total) * 1000) / 1000 : null
}

/**
 * The cold test of a compaction (root ruling 2026-10-27 23:16, after the L3 probe; replaces the
 * read share there): the share of the cached prefix the summarizer request read rather than wrote,
 * `cache_read_input_tokens / (cache_read_input_tokens + cache_creation_input_tokens)`, to 3 places;
 * null with no usage or no cache tokens. Claude Code's compaction request puts its one message
 * cache marker on the last summarized assistant message, so everything after it is uncached input
 * whatever the cache state (`uncoveredInput`): L3 read 0.045 of its input warm, but 0.925 of its
 * prefix. A warm cache reads about 0.9 or more of the prefix, a cold one about 0.3 or less.
 */
export function prefixRead(u: RequestUsage | null | undefined): number | null {
  if (!u) return null
  const read = tokensOf(u.cache_read_input_tokens)
  const prefix = read + tokensOf(u.cache_creation_input_tokens)
  return prefix > 0 ? Math.round((read / prefix) * 1000) / 1000 : null
}

/** The input tokens outside the cache (`input_tokens`): logged beside the prefix read, never part of the cold test. */
export function uncoveredInput(u: RequestUsage | null | undefined): number | null {
  return u ? tokensOf(u.input_tokens) : null
}
export type Version = { version: string; base?: string; builtAt?: string }

/** The launcher's folder under the plugin root (PKG-RUNTIME A.1): this spelling lives here only. */
export const LAUNCHER_DIR = 'scripts'

/** The launcher's absolute path, `<root>/scripts/` + the name + `-store` (an argv element, no quoting). */
export function launcherPath(root: string, name: string): string {
  return root + '/' + LAUNCHER_DIR + '/' + name + '-store'
}

/**
 * The launcher as one shell word for text the model or the user types (PKG-RUNTIME A.1, A.2):
 * the absolute path in double quotes; in single quotes when it holds `"`, `$`, a backquote or
 * `\`; `undefined` (refused: the caller raises `store_path_unquotable`) when it also holds `'`.
 * `ctx::store_cmd()` builds the same word on the helper side (parity test).
 */
export function storeWord(root: string, name: string): string | undefined {
  const p = launcherPath(root, name)
  if (!/["$`\\]/.test(p)) return '"' + p + '"'
  if (!p.includes("'")) return "'" + p + "'"
  return undefined
}

export interface Deps {
  /** `$.plugin.name`: the brand at run time (never a literal in code). */
  readonly name: string
  /** `$.plugin.root`: the plugin's folder (shipped assets live under it). */
  readonly root: string
  /** `launcherPath($.plugin.root, $.plugin.name)`: the launcher under `<root>/scripts/`. */
  readonly helper: string
  readonly cfg: Config
  readonly state: LoadState
  sessionId(): Promise<string>
  /** `$.session.cwd()`: the directory the session runs in (read inside the hook that needs it). */
  cwd(): Promise<string | undefined>
  /** `HOME`, for `~`-abbreviated paths in texts; undefined when it cannot be read. */
  home(): Promise<string | undefined>
  usage(): Promise<Usage>
  version(): Promise<Version>
  /**
   * MG-4 (ratify R4 kept with a tested guard, owner xxxxxxxx-18): `$.session.model()`, the main
   * loop's model as `/model` shows it, for the `dispatch` and `handoff_turn_start` rows;
   * undefined when it cannot be read. Read only to record it: no call of the mod names a model.
   */
  model(): Promise<string | undefined>
  /** `$.session.compact`; rejects while a turn runs, and always in a headless session. */
  compact(instructions: string): Promise<SessionCompactResult>
  /**
   * `$.command.run({ command: 'compact' })`, a bare `/compact` queued as if typed, run once the
   * session is idle: a headless session's way to compact (its compaction runs only as a
   * `/compact` input there). It runs through our own `session.compact` hook (trigger `manual`),
   * which shapes it (`ownCompact`). Resolves to the command's output: `undefined` when it
   * compacted, else Claude Code's reason (a failed `/compact` resolves, it does not reject).
   * Rejects for an unknown command, inside a hook the turn waits on, or past the host's input.
   */
  compactCommand(): Promise<{ text: string | undefined }>
  submit(text: string): Promise<void>
  /**
   * `$.ui.invalidate('prompt.context')`: the engine asks `prompt.context` again for the next turn
   * (its answer otherwise stands once read), so a block left pending for it is still sent.
   */
  invalidateContext(): void
  /**
   * OT-2 (owner xxxxxxxx-06, 2026-10-22): `$.turn.abort({ turnId })`, ending the running main
   * turn (its tools stopped, no interruption marker); rejects when `turnId` is not the running one.
   */
  abortTurn(turnId: string): Promise<void>
  /** `$.process.run` with rejections caught; `stdin` is written to the child, then closed. */
  run(argv: readonly string[], timeoutMs: number, stdin?: string): Promise<RunResult>
  /** Whole-file write; false when it failed. */
  write(path: string, text: string): Promise<boolean>
  exists(path: string): Promise<boolean>
  read(path: string): Promise<string | undefined>
  storeGet(key: string): Promise<unknown>
  storeSet(key: string, value: unknown): Promise<void>
  /** `$.store.delete`: removes the key (a tombstone past its life, idle.ts). */
  storeDelete(key: string): Promise<void>
  now(): Promise<number>
  /**
   * 0.1.2 log-tz: the system's IANA zone now, read again at each call (the engine keeps the zone
   * it read at load, stale once the system zone changes under a running session). Undefined, or
   * absent, means the engine's own zone: `TZ` set, even empty (UTC; the engine and every helper
   * read that), or no `/etc/localtime` leading into a zoneinfo tree the engine knows.
   */
  zone?(): Promise<string | undefined>
  after(ms: number, fn: () => void): { cancel: () => void }
  toast(text: string): void
  /** `$.ui.toast` for the one-time notice: shown whatever `warn_ui` says (W-BETA A). */
  notice(text: string, timeoutMs: number): void
  policy(): Promise<{ mods_managed_only: boolean; hooks_managed_only: boolean }>
  /**
   * IA-2 (idle D3), split by the plugin's idle compaction (§1.1): Claude Code's own idle
   * compaction as the merged settings and its environment say, first match wins.
   * `compaction-off`: `DISABLE_COMPACT` or `DISABLE_AUTO_COMPACT` set, or `autoCompactEnabled`
   * `false` (native's gate order puts `compaction_off` first; the plugin never compacts against
   * it). `vetoed`: `idleCompaction` `false` (only native idle is off; the plugin compacts idle
   * sessions itself). `unknown` when a read throws; else `on`. The server can still keep native
   * idle off while the setting allows it (IC-1 F2), so `on` and `unknown` arm the 55.5-min outcome
   * check (owner xxxxxxxx-17, O-9: "unreadable means check what happened").
   */
  nativeIdle(): Promise<NativeIdle>
  /** The idle timers' environment (IdleEnv), read once per load (`idleEnvMemo`). */
  idleEnv(): Promise<IdleEnv>
  /**
   * The merged `promptCacheTtl` setting (`5m` or `1h`), read when asked (a settings change takes
   * effect at once); undefined when unset, any other value, or the read throws.
   */
  promptCacheTtl(): Promise<CacheTtl | undefined>
  /**
   * 0.1.3: the merged `autoCompactWindow` setting (the window Claude Code compacts within), read
   * with the thresholds once per load (config.ts effective) while `native_window_tokens` is unset;
   * undefined when unset, not a positive number, or the read throws.
   */
  compactWindowSetting?(): Promise<number | undefined>
  /**
   * 0.1.4 T-11: the compaction window from the `summary` context breakdown (CompactWindow), read
   * with the thresholds once per load (config.ts effective) while `native_window_tokens` is unset;
   * undefined when the reply has no breakdown (an older Claude Code, no session bound), its window
   * is not a positive number, or the call throws. Then compactWindowSetting is read, as in 0.1.3.
   */
  compactWindow?(): Promise<CompactWindow | undefined>
  /**
   * Owner xxxxxxxx-17 (2b): the idle mode Claude Code last cached from its server
   * (`cachedGrowthBookFeatures.tengu_sunny_locket.mode` in `<config dir>/.claude.json`), as a
   * logged hint only: the plugin never decides on it (an internal cache shared by all processes
   * that flips between fetches). Undefined when it cannot be read.
   */
  servedHint(): Promise<string | undefined>
  /**
   * Owner xxxxxxxx-38 ("Measure more first"): subagents and teammates of this session that have
   * not ended (`$.agent.list()`, any status but completed, failed or killed), by id; undefined
   * when the list cannot be read. A workflow's agents are not listed: `agentTurns` counts them.
   */
  agentsAlive(): Promise<string[] | undefined>
  /**
   * D-82 (owner 2026-11-09, session xxxxxxxx: 22 idle teammates read as 22 open jobs): the listed
   * agents of this session at work now, by id: `agentsAlive` less a teammate that waits for a
   * message (`idle`, Claude Code 2.1.319 sets it at each TeammateIdle) or for a plan approval
   * (`waiting`). Its next turn comes only when someone writes to it, so no result is on its way.
   * Undefined when the list cannot be read.
   */
  agentsWorking(): Promise<string[] | undefined>
  /** `<root>` and `<watch>`, or undefined when `~` could not be expanded. */
  paths(): Promise<Paths | undefined>
  /**
   * `$.model.fork({ prompt })`, the shadow trial's one model call (TRIAL-DUAL-HANDOFF §4.1): the
   * engine's answer as given; rejects on a hook's `{ deny }`. Called only while the user's local
   * trial config is on (shadow.ts), and for keep-warm's ping (keepwarm.ts, D-14).
   */
  fork(prompt: string): Promise<unknown>
  /**
   * SESSION-RESTART §4.2: `$.ui.log`, one dim transcript line the model does not read (the
   * restart notice before and after); a failure is ignored.
   */
  uiLog(text: string): void
  /**
   * SESSION-RESTART §3.4 step 4: `$.command.run({ command })`, the command queued as if typed and
   * run once the session is idle (`exit` never resolves when it ends the session). Rejects an
   * unknown name, inside a hook the turn waits on, or past a Stop (F1, F2).
   */
  commandRun(command: string): Promise<{ text: string | undefined }>
  /** G8: the prompt box's draft (`$.prompt.read`), undefined when it cannot be read. */
  promptDraft(): Promise<string | undefined>
  /** G9, G3b: `$.session.surfaces()`, undefined when the call throws. */
  surfaces(): Promise<readonly string[] | undefined>
  /**
   * SESSION-RESTART §2.1, §3.2: the literal env reads of restart on update: the session kind,
   * the background backend and job folder, and the restart launcher's launch folder (launch.gen.ts).
   */
  restartEnv(): Promise<RestartEnv>
  /**
   * 0.1.4 R-3: CLAUDE_CODE_ENTRYPOINT (`$.env.get`), which Claude Code sets per host: `cli`, `sdk-cli`
   * for `-p` (probe 2026-11-03 on 2.1.317: `cli` in a terminal load, `sdk-cli` in 7 `-p` loads),
   * `claude-desktop`, `claude-vscode`, `sdk-ts`, `sdk-py`; undefined when unset, empty or unreadable.
   */
  entrypoint(): Promise<string | undefined>
}

/** What one module load keeps in memory (a reload starts a fresh one). */
export type LoadState = {
  loadId: string
  initDone: boolean
  eff: Effective | undefined
  ident: { pid: number | null; pid_lstart: string | null; watch?: string | null; restart?: RestartSetting; restartReports?: RestartReport[] } | undefined
  ccVersion: string | null
  helperMissingLogged: boolean
  /** Main turn bookkeeping. */
  mainTurnRunning: boolean
  turnSeq: number
  turnId: string | null
  askOpen: number
  /** An AskUserQuestion call of this main turn closed unanswered (an answered one never sets it). */
  askedThisTurn: boolean
  nudgedThisTurn: boolean
  /** A nudge-driven compaction should auto-continue (MOD-SPEC §9). */
  resumeAfter: boolean
  /** The last main turn ended on a user-owned question. */
  lastTurnAsksUser: boolean
  /**
   * Question carry (question.ts): the question a main turn ended on, on one line and clipped, open
   * until a person's turn starts or the session ends; a main compaction carries it (`[question]`).
   */
  openQuestion: string | undefined
  /** This main turn's AskUserQuestion dialog that closed on the AFK timeout: its questions (question.ts). */
  askTimedOut: string | undefined
  /**
   * 0.1.4 R-7: a person's prompt entered this running turn after `askTimedOut` was set (question.ts
   * `personTyped`): the question stays carried, its timeout mark does not.
   */
  askPersonSince: boolean
  /**
   * 0.1.3 resume-text B: the turn that left `openQuestion` open had a dialog that closed on the AFK
   * timeout (question.ts `turnQuestion`); read only while `openQuestion` is set (`carriedTimedOut`).
   */
  openTimedOut: boolean
  /** The next main turn.start comes from our own `$.prompt.submit`. */
  ourSubmitPending: boolean
  /** The text of that submit: it tells our turn from a prompt that entered beside it (CR-F17). */
  ourSubmitText: string | undefined
  /** Prompts of others (the user, another plugin) entering an idle session whose turn has not started yet. */
  foreignPrompts: number
  /** Our handoff-turn prompt still queued after a user turn cancelled that turn: its turn is aborted (OT-1). */
  orphanSubmit: boolean
  /** The ht that cancelled handoff turn had (closed), for the `handoff_orphan_aborted` row; null when none. */
  orphanHt: string | null
  /** Our handoff-turn `$.prompt.submit` call is in flight: our own `prompt.submit` hook drops it when a user prompt came first. */
  handoffSubmitting: boolean
  /** Our auto-continue's `$.prompt.submit` call is in flight: dropped there the same way (cont.ts). */
  contSubmitting: boolean
  /** The handoff turn deferred for a prompt that entered but has not started its turn: run again if it never does (CR-F17). */
  afterForeign: (() => void) | undefined
  /** Boundary scheduler. */
  timer: { cancel: () => void } | undefined
  busy: boolean
  lastPluginCompactAt: number | undefined
  /** Plugin compactions for the thrash rule: the main turn they ended, and whether refilled. */
  pluginCompactions: { turnSeq: number; refilled: boolean | null }[]
  consecutiveNonOk: number
  halt: { active: boolean; reason: string | null }
  haltToasted: boolean
  /** prompt.context ran in this load (MOD-SPEC §3.4 ctxSeen). */
  ctxSeen: boolean
  /**
   * 0.1.5 D-1: a `prompt.context` call of another loop passed the pending block over (resume.ts
   * `otherLoopContext`); the next main prompt not of ours carries it (`passedBlockFor`). `restored`:
   * that call restored the block's record (a person's prompt then gets no timeout mark).
   */
  ctxPassed: { restored: boolean } | undefined
  /** Nonces of this load's mod-self dispatches (the self-call check, §3.1 step 0). */
  selfNonces: Set<string>
  /** The pending main resume block for prompt.context or the continue text. */
  pending: PendingResume | undefined
  /** The session id whose armed resume record this load has looked for (AT-RP-02); reset at session.end. */
  restoreChecked: string | undefined
  /** The session id whose resume records this load's first main turn end has closed (AT-RP-05); reset at session.end. */
  restoreClosed: string | undefined
  mainCompactions: number
  fourthToasted: boolean
  selfCallLoggedFor: Set<string>
  keysetLoggedFor: Set<string>
  /** Temp paths already recorded for this session (MOD §10). */
  recordedPaths: Set<string>
  /** Background work a test awaits (boundary runs from a timer). */
  inflight: Promise<unknown> | undefined
  /** Temp-path recording running beside the tool calls (nudge.ts trackPaths). */
  pathsInflight: Promise<unknown> | undefined
  /** `<root>`/`<watch>` from the options, resolved once per load (see `paths()`). */
  pathsMemo: Promise<Paths | undefined> | undefined
  /** Main compactions per session id (the fourth-compaction toast). */
  mainCompactionsSid: string | null
  /** Escalation kinds already toasted in this load. */
  toasted: Set<string>
  /** The nudged main turn's last-cycle reason (MOD-SPEC §9.1), set at the nudge, read at its end. */
  lastCycle: HaltReason | null
  /** The nonce the nudge named (`@queue_add@`); the compaction of that cycle uses it. */
  nudgeNonce: string | undefined
  /** The handoff turn from its scheduling to its end (MOD-SPEC §9.1). */
  handoffTurn: HandoffTurn | undefined
  /** Main turn (`turnSeq`) in which a main compaction other than ours ran after the nudge, or -1. */
  compactedInTurn: number
  /** The handoff a handoff turn published, while no later main turn or compaction has run. */
  published: Published | undefined
  /** Main compactions other than ours that completed in this load (the post-handoff check). */
  nativeCompactSeq: number
  /** Main compactions other than ours running now (not `precompute`). */
  nativeCompacting: number
  /** The post-handoff compaction waiting for a running native one to end (CR-F19). */
  afterNative: (() => void) | undefined
  /** A pre-compaction turn ran since this load's last main compaction (§9.3 `again`). */
  precompactRan: boolean
  /** Origin kinds of the prompts counted in `foreignPrompts`, oldest first (IC-1 D6). */
  enteringKinds: string[]
  /**
   * Prompts of others queued while a main turn ran (`turnId` set), oldest first: the origin kind,
   * the text that entered and the turn it was queued over. One delivered into that turn starts
   * none; one that starts its own turn after it is told by its text there (`claimTurn`).
   * `passed`: the main turns started since it was queued that were not its own.
   */
  queuedKinds: { kind: string; text: string; over: string; passed: number }[]
  /** The origin kind of the prompt that opened the current main turn: `plugin` for ours, undefined when none was seen. */
  turnOrigin: string | undefined
  /** When the last main turn ended, and whether it ended `answer` (§9.4, the idle predicate). */
  lastTurnEndAt: number | undefined
  lastTurnAnswer: boolean
  /** When the last main-thread model request (`turn.step`) started: the idle compaction's anchor (D3). */
  lastMainReqAt: number | undefined
  /** How many main-thread model requests (`turn.step`) this load has seen: keep-warm's fork-miss reads a new one. */
  mainReqs: number
  /**
   * D11: the last sign of a person at the prompt (a `prompt.edit`, a `prompt.change` of theirs, an
   * interactive `session.start`); the idle compaction skips `present` for a minute after it.
   */
  lastInputAt: number | undefined
  /** D7: the plugin's idle compactions that failed in a row in this load (a success resets it). */
  idleCompactFails: number
  /** D7 (`failed`, two in a row) and D8 (`queued`, lane B1): the idle compaction is off for the load. */
  idleCompactOff: 'failed' | 'queued' | undefined
  /** The persisted idle due this load runs was adopted from another load or process (§3.4, D6). */
  idleAdopted: boolean
  /** `idleEnv()` once per load. */
  idleEnvMemo: Promise<IdleEnv> | undefined
  /** The pre-idle timer (§9.4). */
  idleTimer: { cancel: () => void } | undefined
  /**
   * D12 (lane B): bumped by every cancel of the idle timer, synchronously, so a tick that was
   * reading the clock when a turn started, a prompt entered or the session ended re-arms nothing.
   */
  idleGen: number
  /** The `atLoad` of the timer `schedule` armed last (§3.4): a prompt a hook drops re-arms it alike (`resumeIdle`). */
  idleAtLoad: boolean
  /** Fires of this load's idle timer under way (a count): `resumeIdle` arms no second timer beside one. */
  idleFiring: number
  /**
   * The sid whose `idle_due` this load wrote or re-armed and has not cleared yet. Kept apart
   * from `idleTimer`: the hooks cancel the timer synchronously before `cancelIdle` runs.
   */
  idleDueSid: string | undefined
  /**
   * Per session id, the one pending delete of the tombstone this load wrote last (§3.1): a newer
   * tombstone or record of that sid cancels it, so turn starts do not pile up hour-long waits.
   */
  idleTombDeletes: Map<string, { cancel: () => void }>
  /** The idle episode: from a human-origin turn's end to the next human-origin turn.start (§9.4). */
  idleEpisode: { since: number; done: boolean } | undefined
  /** A handoff turn published since the last human-origin turn (§9.4 `published`). */
  publishedSinceHuman: boolean
  /**
   * The session id and policy tuple (native, plugin_turn, plugin_compact, compact_min,
   * served_hint, cache_s) of the last `idle_mode` row this load wrote (IA-3, owner xxxxxxxx-17;
   * §1.2: one per session id, so a `/clear` gets its own), undefined before the first.
   */
  idleMode: { sid: string; tuple: string } | undefined
  /**
   * Owner xxxxxxxx-37 ("Full block again on return"): a turn not of a person's (a background
   * result) took an idle compaction's resume block at `usedAt`; the first human-origin turn gets
   * the full block again, re-measured, with `[idle-again]`. `remeasure` is the measure that turn's
   * block was built with, taken at `measuredAt` (used, with that stamp, when the new measure fails).
   */
  idleAgain: { sid: string; pend: PendingResume; usedAt: number; remeasure: string | undefined; measuredAt: number } | undefined
  /**
   * Away digest phase 1 (owner 2026-10-27 12:5x): the open idle episode of the last main idle
   * compaction (or of its block restored after `claude --resume`), from its after-step to the
   * first human-origin prompt once a turn got the block: the lane facts its summary gave, the
   * lane state the last turn was told (`shown`, undefined until a turn got the block), the measure
   * the block went out with (its running in-flight rows count until a notification ends them),
   * the task ids this episode's notifications reported ended, and whether the model started work
   * after the block went out (`superseded`: the summary's Status no longer describes the lane).
   * Every later prompt not of a person's re-checks the lane (resume.ts `laneRecheck`) and carries a
   * note beside it when the lane turned finished or hard-blocked. A person's prompt closes it; the
   * `[idle-again]` block that prompt's turn may get still reads it, then drops it.
   */
  idleLane: IdleLane | undefined
  /**
   * Owner xxxxxxxx-17: the end of this load's last main compaction (any trigger but precompute),
   * and whether it was an idle dispatch; the 55.5-min check stands down when it is after the turn
   * end it was armed for. Also kept in `$.store` (`idle_seen:<sid>`), so a reload keeps it.
   */
  compactedAt: { sid: string; at: number; idle: boolean } | undefined
  /**
   * Owner xxxxxxxx-38: agent loops (subagents, teammates, a workflow's agents) whose turn started
   * and has not completed in this load, by agent id.
   */
  agentTurns: Set<string>
  /**
   * A headless load (`claude -p`, the Agent SDK, or an app or editor built on it):
   * `session.start` said no person is at the prompt, or `$.session.compact` rejected as not
   * available there. Claude Code rejects a plugin's compaction call in such a session, so the
   * plugin neither nudges nor starts one; the plugin leaves Claude Code's own compactions alone
   * and shapes the ones that run, as usual.
   */
  headless: boolean
  /** The session id the last `headless` row was logged for (one row per session id, so after a `/clear`). */
  headlessSid: string | undefined
  /**
   * How a headless load compacts: `command` runs `/compact` (`compactCommand`) at a turn end at
   * or above the target, shaped by our own hook; `none` once that failed twice in a row or
   * cannot work in this host (no `/compact` command, the host's input ended): from then on no
   * plugin compaction in this load, as before the fallback.
   */
  headlessCompact: 'command' | 'none'
  /** Our `/compact` in flight: our `session.compact` hook claims the next main `manual` one. */
  ownCompact: OwnCompact | undefined
  /**
   * The running main turn is the one our `/compact` runs in (it started with `/compact` while
   * ours was in flight): its turn end starts no plugin compaction.
   */
  ownCompactTurn: boolean
  /**
   * Our `/compact` runs that failed in a row (two make `headlessCompact` `none`); anything but
   * a compaction our hook shaped counts, a skipped or unclaimed one too.
   */
  commandFails: number
  /** SESSION-RESTART: the restart this load armed, from its arm to its end (one at a time). */
  restart: RestartRun | undefined
  /** `<why>|<to>` of the `refresh_skipped` and `refresh_would` rows this load wrote (once each). */
  restartLogged: Set<string>
  /** G9, G10: what this load saw that a restart cannot carry (`session-rules`, `session-dirs`, `remote`, `worktree`). */
  restartBlocks: Set<string>
  /** G3b: `session.attach` minus `session.detach` in this load. */
  attached: number
  /** `session.end` has begun (set first, synchronously): the exit watchdog stands down. */
  ending: boolean
  /** G5: the installed version `claude --version` gave (null: unknown) and when, cached 30 minutes. */
  drift: { at: number; installed: string | null } | undefined
  /** The `version_drift` rows this load wrote, by target. */
  driftLogged: Set<string>
  /** §2.1: this load's session ran another Claude Code version before (versionCanary), for `refresh_done {route: supervisor}`. */
  versionMoved: { from: string; to: string } | undefined
  /** D10: the newest permission_mode a main hook input carried in this load (Stop, UserPromptSubmit, PermissionRequest), and when. */
  modeSeen: { mode: string; at: number } | undefined
  /** D10: when the last main turn of this load started. */
  lastMainTurnAt: number | undefined
  /** D10: when this load's `session.start` ran (once per load; never for a `/clear`). */
  sessionStartAt: number | undefined
  /** Keep-warm (D-14, keepwarm.ts): the current idle gap's warming, undefined between a turn start and the next turn end. */
  keepWarm: KeepWarm | undefined
  /** The ping timer, and its generation (bumped by every cancel, as `idleGen`). */
  keepWarmTimer: { cancel: () => void } | undefined
  keepWarmGen: number
  /** The last gap handed over to the idle path: no warming until a turn not of the plugin's own starts. */
  keepWarmSpent: boolean
  /**
   * A keep-warm ping that missed the main prefix (keepwarm.ts `fork-miss`): no ping for this session
   * until a main request after `reqs` (the `mainReqs` before that fork).
   */
  keepWarmForkMiss: { sid: string; reqs: number } | undefined
  /** The background tasks the main session's last Stop listed as in flight (Monitors and crons left out). */
  bgTasks: BgTasks | undefined
  /** Task ids a background-task notification reported ended (keepwarm.ts `noteEndedTasks`); cleared at session end. */
  endedTasks: Set<string>
}

/**
 * One plugin compaction run as a `/compact` command in a headless session: what the boundary
 * prepared (dispatch record written, `mod-self`), handed to our `session.compact` hook, which
 * appends `text` and runs the after-step there (it needs the summary messages).
 */
export type OwnCompact = {
  nonce: string
  text: string
  pref: ResumePref
  prodConsent?: string
  /** The `ht` of a handoff turn this compaction follows (none in a headless session today). */
  ht?: string
  /** When the dispatch record was written (the `compacted` row's `ms`). */
  t0: number
  /** Our hook took this compaction as ours. */
  claimed: boolean
  /** The compaction's result, once our hook has it. */
  result?: SessionCompactResult
}

export type PendingResume = {
  sid: string
  nonce: string
  block: string
  /** When the block was built, and what it was built from: a block delivered more than 600 s later is built again with a fresh measure (IC-1 D3). */
  builtAt: number
  args: BlockArgs
  /** The measure the block was built with (owner xxxxxxxx-25: a halt change rebuilds it without a new helper call). */
  remeasure?: string
  /** When that measure was taken (`@measured_at@` of a rebuild that takes no new one; `builtAt` when absent). */
  measuredAt?: number
  resumePref:'prompt.context' | 'sessionstart' | 'prompt.submit' | 'none'
  /** Main turn count when it became pending (an undelivered block survives a whole turn). */
  turnSeq: number
  /** What the mod decided for this compaction, logged as `mod_outcome` once the block settles. */
  outcome: Outcome
  /** Its record is on disk (`resume-pending.json`, AT-RP-01): a session end other than `/clear` keeps it for a resume. */
  persisted?: boolean
  /** An idle block's work lane as code read it when the block was built (away digest phase 1). */
  lane?: LaneResult
  /** Our continue claimed it for `prompt.submit` and was dropped for a user prompt: `prompt.context` still delivers it. */
  heldClaim?: boolean
  /**
   * 0.1.6: the tasks a notification reported ended while the block waited (resume.ts
   * `pendingNotified`; its delivering prompt's): a block with no idle episode shows their rows ended.
   */
  notified?: Set<string>
}

/** The open idle episode of away digest phase 1 (`LoadState.idleLane`). */
export type IdleLane = {
  sid: string
  nonce: string
  facts: LaneFacts | undefined
  nonok: boolean
  driver: boolean
  shown: Lane | undefined
  remeasure: string | undefined
  /** When `remeasure` was measured (epoch ms): a lane note's Basis says how old its git facts are. */
  measuredAt: number | undefined
  ended: Set<string>
  superseded: boolean
  /** A person's prompt came after a turn got the block: no more re-checks (the held `[idle-again]` block still reads it). */
  closed: boolean
  /**
   * The episode of a block restored after `claude --resume`: the background tasks its measures list
   * ran in the process that ended, and no notification of this load will end them, so only agents
   * count as running (review of fix round 1).
   */
  restored: boolean
  /** A job's result came with the prompt of the turn now running (a notification that reported a task ended); cleared at its end. */
  result: boolean
  /**
   * The turn now running read the lane working only because that result unblocks a step held on
   * its job (owner 2026-10-28 digest rules (a)): its end reads the lane again (rule (b), digest.ts
   * `laneTurnEnd`); cleared there.
   */
  unblocked: boolean
  /**
   * A turn of this episode was told a finished or blocked lane (its block, the digest turn, or a
   * note that asks for the digest or a one-line change): later notes ask for one line, never a
   * second digest, and the end of a result's turn submits none.
   */
  digested: boolean
}

/**
 * The mod's part of the rollup (MOD-SPEC §2.5, F2-3): `nudged` = a nudge was given in the main
 * turn this compaction ended or interrupted; `continued` = an auto-continue was submitted after
 * it; `halt` = halt mode was on once the mod had handled it.
 */
export type Outcome = {
  nudged: boolean
  continued: boolean
  halt: boolean
  /** The handoff turn this compaction followed or interrupted (MOD-SPEC §2.5 rollup fields). */
  handoff?: Record<string, string | number | null>
}

export function newState(loadId: string): LoadState {
  return {
    loadId,
    initDone: false,
    eff: undefined,
    ident: undefined,
    ccVersion: null,
    helperMissingLogged: false,
    mainTurnRunning: false,
    turnSeq: 0,
    turnId: null,
    askOpen: 0,
    askedThisTurn: false,
    nudgedThisTurn: false,
    resumeAfter: false,
    lastTurnAsksUser: false,
    openQuestion: undefined,
    askTimedOut: undefined,
    askPersonSince: false,
    openTimedOut: false,
    ourSubmitPending: false,
    ourSubmitText: undefined,
    foreignPrompts: 0,
    orphanSubmit: false,
    orphanHt: null,
    handoffSubmitting: false,
    contSubmitting: false,
    afterForeign: undefined,
    timer: undefined,
    busy: false,
    lastPluginCompactAt: undefined,
    pluginCompactions: [],
    consecutiveNonOk: 0,
    halt: { active: false, reason: null },
    haltToasted: false,
    ctxSeen: false,
    ctxPassed: undefined,
    selfNonces: new Set(),
    pending: undefined,
    restoreChecked: undefined,
    restoreClosed: undefined,
    mainCompactions: 0,
    fourthToasted: false,
    selfCallLoggedFor: new Set(),
    keysetLoggedFor: new Set(),
    recordedPaths: new Set(),
    inflight: undefined,
    pathsInflight: undefined,
    pathsMemo: undefined,
    mainCompactionsSid: null,
    toasted: new Set(),
    lastCycle: null,
    nudgeNonce: undefined,
    handoffTurn: undefined,
    compactedInTurn: -1,
    published: undefined,
    nativeCompactSeq: 0,
    nativeCompacting: 0,
    afterNative: undefined,
    precompactRan: false,
    enteringKinds: [],
    queuedKinds: [],
    turnOrigin: undefined,
    lastTurnEndAt: undefined,
    lastTurnAnswer: false,
    lastMainReqAt: undefined,
    mainReqs: 0,
    lastInputAt: undefined,
    idleCompactFails: 0,
    idleCompactOff: undefined,
    idleAdopted: false,
    idleEnvMemo: undefined,
    idleTimer: undefined,
    idleGen: 0,
    idleAtLoad: false,
    idleFiring: 0,
    idleDueSid: undefined,
    idleTombDeletes: new Map(),
    idleEpisode: undefined,
    publishedSinceHuman: false,
    idleMode: undefined,
    idleAgain: undefined,
    idleLane: undefined,
    compactedAt: undefined,
    agentTurns: new Set(),
    headless: false,
    headlessSid: undefined,
    headlessCompact: 'command',
    ownCompact: undefined,
    ownCompactTurn: false,
    commandFails: 0,
    restart: undefined,
    restartLogged: new Set(),
    restartBlocks: new Set(),
    attached: 0,
    ending: false,
    drift: undefined,
    driftLogged: new Set(),
    versionMoved: undefined,
    modeSeen: undefined,
    lastMainTurnAt: undefined,
    sessionStartAt: undefined,
    keepWarm: undefined,
    keepWarmTimer: undefined,
    keepWarmGen: 0,
    keepWarmSpent: false,
    keepWarmForkMiss: undefined,
    bgTasks: undefined,
    endedTasks: new Set(),
  }
}

/** The real Deps over the engine's `$`. */
export function realDeps($: EngineInterface, options: PluginOptions, state: LoadState): Deps {
  const cfg = parseOptions(options, $.plugin.name)
  const env = optionEnv(options)
  return {
    name: $.plugin.name,
    root: $.plugin.root,
    helper: launcherPath($.plugin.root, $.plugin.name),
    cfg,
    state,
    sessionId: () => $.session.id(),
    async cwd() {
      try {
        return await $.session.cwd()
      } catch {
        return undefined
      }
    },
    async home() {
      try {
        return await $.env.get('HOME')
      } catch {
        return undefined
      }
    },
    async usage() {
      const u = await $.session.usage()
      return {
        tokens: u.context.tokens, window: u.context.window,
        rateLimits: (u.rateLimits ?? []).map(l => ({ kind: typeof l.kind === 'string' ? l.kind : '', percentUsed: l.percentUsed })),
      }
    },
    async version() {
      const v = await $.session.version()
      return { version: v.version, base: v.base, builtAt: v.builtAt }
    },
    async model() {
      try {
        const m = await $.session.model()
        return typeof m === 'string' && m !== '' ? m : undefined
      } catch {
        return undefined
      }
    },
    compact: instructions => $.session.compact({ instructions }),
    async compactCommand() {
      const r = await $.command.run({ command: 'compact' })
      return { text: typeof r.text === 'string' && r.text.trim() !== '' ? r.text : undefined }
    },
    async submit(text) {
      // A hook or the engine refuses a submit with a resolved `{ drop }`: that is a failed
      // submit too, so the caller's `submit-failed` path runs and `ourSubmitPending` is reset.
      const r = await $.prompt.submit({ text })
      if (r.drop !== undefined) throw new Error('dropped: ' + String(r.drop))
    },
    invalidateContext() {
      try {
        $.ui.invalidate('prompt.context')
      } catch {
        // Not asked again: the block stays pending, and the turn end reports it undelivered.
      }
    },
    abortTurn: turnId => $.turn.abort({ turnId }),
    async run(argv, timeoutMs, stdin) {
      try {
        const r = await $.process.run(argv, stdin === undefined ? { timeoutMs, env } : { timeoutMs, env, stdin })
        return { ok: r.exitCode === 0, exitCode: r.exitCode, stdout: r.stdout, error: r.stderr }
      } catch (err) {
        return { ok: false, exitCode: null, stdout: '', error: 'rejected: ' + errText(err) }
      }
    },
    async write(path, text) {
      try {
        await $.fs.write(path, text)
        return true
      } catch {
        return false
      }
    },
    async exists(path) {
      try {
        return await $.fs.exists(path)
      } catch {
        return false
      }
    },
    async read(path) {
      try {
        const t = await $.fs.read(path)
        return typeof t === 'string' ? t : undefined
      } catch {
        return undefined
      }
    },
    storeGet: key => $.store.get(key),
    storeSet: (key, value) => $.store.set(key, value),
    storeDelete: key => $.store.delete(key),
    now: () => $.clock.now(),
    async zone() {
      try {
        if ((await $.env.get('TZ')) !== undefined) return undefined
        return zoneOfPath((await $.fs.stat('/etc/localtime', { resolve: true })).realPath)
      } catch {
        return undefined
      }
    },
    after: (ms, fn) => $.clock.after(ms, fn),
    toast(text) {
      if (cfg.warn_ui) $.ui.toast(text)
    },
    notice(text, timeoutMs) {
      $.ui.toast(text, { timeoutMs })
    },
    async policy() {
      try {
        const p = await $.settings.read({ source: 'policy' })
        return { mods_managed_only: p['allowManagedModsOnly'] === true, hooks_managed_only: p['allowManagedHooksOnly'] === true }
      } catch {
        return { mods_managed_only: false, hooks_managed_only: false }
      }
    },
    async nativeIdle() {
      try {
        // `$.env.get` takes literal names only (the engine lists what a module reads).
        if (envTruthy(await $.env.get('DISABLE_COMPACT')) || envTruthy(await $.env.get('DISABLE_AUTO_COMPACT'))) return 'compaction-off'
        if ((await $.settings.read({ key: 'autoCompactEnabled' })) === false) return 'compaction-off'
        return (await $.settings.read({ key: 'idleCompaction' })) === false ? 'vetoed' : 'on'
      } catch {
        return 'unknown'
      }
    },
    idleEnv() {
      if (!state.idleEnvMemo) {
        state.idleEnvMemo = (async (): Promise<IdleEnv> => {
          const get = async (read: () => Promise<string | undefined>): Promise<string | undefined> => {
            try {
              return await read()
            } catch {
              return undefined
            }
          }
          // Literal names (the engine lists what a module reads): native's cache check (`lce`,
          // Claude Code 2.1.311) reads these six; any one set counts as no one-hour cache.
          const caching = await Promise.all([
            get(() => $.env.get('DISABLE_PROMPT_CACHING')),
            get(() => $.env.get('DISABLE_PROMPT_CACHING_HAIKU')),
            get(() => $.env.get('DISABLE_PROMPT_CACHING_SONNET')),
            get(() => $.env.get('DISABLE_PROMPT_CACHING_OPUS')),
            get(() => $.env.get('DISABLE_PROMPT_CACHING_FABLE')),
            get(() => $.env.get('DISABLE_PROMPT_CACHING_MYTHOS')),
          ])
          return {
            compactMin: compactMinOf(await get(() => $.env.get('CLAUDE_CODE_IDLE_COMPACT_MIN_TOKENS'))),
            cacheS: cacheSOf(await get(() => $.env.get('STORE_TEST_IDLE_CACHE_S'))),
            cacheOff: caching.some(envTruthy),
            // Claude Code 2.1.311's TTL switches for the main conversation (TtlEnv).
            ttl: ttlEnvOf({
              force5m: await get(() => $.env.get('FORCE_PROMPT_CACHING_5M')),
              ttl: await get(() => $.env.get('CLAUDE_CODE_PROMPT_CACHE_TTL')),
              enable1h: await get(() => $.env.get('ENABLE_PROMPT_CACHING_1H')),
              messages: await get(() => $.env.get('CLAUDE_CODE_MESSAGES_PROMPT_CACHE_TTL')),
            }),
          }
        })()
      }
      return state.idleEnvMemo
    },
    async promptCacheTtl() {
      try {
        const v = await $.settings.read({ key: 'promptCacheTtl' })
        return v === '5m' || v === '1h' ? v : undefined
      } catch {
        return undefined
      }
    },
    async compactWindowSetting() {
      try {
        const v = await $.settings.read({ key: 'autoCompactWindow' })
        return typeof v === 'number' && Number.isFinite(v) && v > 0 ? v : undefined
      } catch {
        return undefined
      }
    },
    async compactWindow() {
      try {
        const b = (await $.session.usage({ breakdown: 'summary' })).context.breakdown
        const pos = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v) && v > 0
        if (!b || !pos(b.rawMaxTokens)) return undefined
        return {
          window: Math.floor(b.rawMaxTokens),
          ...(pos(b.autoCompactThreshold) ? { threshold: Math.floor(b.autoCompactThreshold) } : {}),
          ...(typeof b.autocompactSource === 'string' && /^[a-z-]{1,32}$/.test(b.autocompactSource) ? { source: b.autocompactSource } : {}),
        }
      } catch {
        return undefined
      }
    },
    async servedHint() {
      // `$.env.get` takes literal names only (the engine lists what a module reads).
      let dir: string | undefined
      try {
        dir = (await $.env.get('CLAUDE_CONFIG_DIR')) || undefined
      } catch {
        dir = undefined
      }
      try {
        dir ??= (await $.env.get('HOME')) || undefined
        if (!dir) return undefined
        const t = await $.fs.read(dir.replace(/\/+$/, '') + '/' + SERVED_FILE)
        return typeof t === 'string' ? servedMode(t) : undefined
      } catch {
        return undefined
      }
    },
    async agentsAlive() {
      try {
        const list = await $.agent.list()
        return list.filter(a => !AGENT_ENDED.includes(a.status)).map(a => a.id)
      } catch {
        return undefined
      }
    },
    async agentsWorking() {
      try {
        const list = await $.agent.list()
        return list.filter(a => !AGENT_ENDED.includes(a.status) && !AGENT_RESTING.includes(a.status)).map(a => a.id)
      } catch {
        return undefined
      }
    },
    paths() {
      if (!state.pathsMemo) {
        state.pathsMemo = (async () => {
          let home: string | undefined
          let stateHome: string | undefined
          try {
            home = await $.env.get('HOME')
          } catch {
            home = undefined
          }
          try {
            stateHome = (await $.env.get('XDG_STATE_HOME')) || undefined
          } catch {
            stateHome = undefined
          }
          return paths(cfg, home, { home: stateHome, name: $.plugin.name })
        })()
      }
      return state.pathsMemo.then(p => withHelperWatch(p, state.ident))
    },
    fork: prompt => $.model.fork({ prompt }),
    uiLog(text) {
      try {
        $.ui.log(text)
      } catch {
        // the line is a notice only
      }
    },
    async commandRun(command) {
      const r = await $.command.run({ command })
      return { text: typeof r.text === 'string' && r.text.trim() !== '' ? r.text : undefined }
    },
    async promptDraft() {
      try {
        const b = await $.prompt.read()
        return typeof b.text === 'string' ? b.text : undefined
      } catch {
        return undefined
      }
    },
    async surfaces() {
      try {
        return [...(await $.session.surfaces())].map(String)
      } catch {
        return undefined
      }
    },
    async restartEnv() {
      // `$.env.get` takes literal names only (the engine lists what a module reads).
      const get = async (read: () => Promise<string | undefined>): Promise<string | undefined> => {
        try {
          const v = await read()
          return typeof v === 'string' && v !== '' ? v : undefined
        } catch {
          return undefined
        }
      }
      return {
        kind: await get(() => $.env.get('CLAUDE_CODE_SESSION_KIND')),
        backend: await get(() => $.env.get('CLAUDE_BG_BACKEND')),
        jobDir: await get(() => $.env.get('CLAUDE_JOB_DIR')),
        launch: await get(() => launchDir($)),
      }
    },
    async entrypoint() {
      try {
        const v = await $.env.get('CLAUDE_CODE_ENTRYPOINT')
        return typeof v === 'string' && v !== '' ? v : undefined
      } catch {
        return undefined
      }
    },
  }
}

/**
 * The mod writes where the helper does (MOD-SPEC §1.2 unsafe roots): the helper's effective watch
 * from `ident` when it gave one, nothing at all when it refused every log folder (null), and the
 * folders from the options only while no helper answer is known (the helper-missing fallback).
 */
export function withHelperWatch(p: Paths | undefined, id: LoadState['ident']): Paths | undefined {
  const w = id?.watch
  if (w === undefined || p === undefined) return p
  if (w === null) return undefined
  return { root: p.root, watch: w.replace(/\/+$/, '') }
}

/** Owner xxxxxxxx-17 (2b): Claude Code's own cache file, in `CLAUDE_CONFIG_DIR` or else `HOME`. */
export const SERVED_FILE = '.claude.json'
/** A cache file larger than this is not read for the hint. */
export const SERVED_MAX_CHARS = 8000000

/**
 * The served idle mode in Claude Code's cache file text (`off`, `log`, `compact`,
 * `compact_on_return`, ...), or undefined: a short lowercase word only, nothing else of the file.
 */
export function servedMode(text: string): string | undefined {
  if (text.length > SERVED_MAX_CHARS) return undefined
  try {
    const j = JSON.parse(text) as { cachedGrowthBookFeatures?: { tengu_sunny_locket?: { mode?: unknown } } }
    const m = j?.cachedGrowthBookFeatures?.tengu_sunny_locket?.mode
    return typeof m === 'string' && /^[a-z][a-z0-9_-]{0,31}$/.test(m) ? m : undefined
  } catch {
    return undefined
  }
}

/** `AgentStatus` values of an agent that ended (owner xxxxxxxx-38: every other status counts as running). */
export const AGENT_ENDED: readonly string[] = ['completed', 'failed', 'killed']
/**
 * D-82: `AgentStatus` values of a live agent at rest: a teammate that waits for a message (`idle`)
 * or for a plan approval (`waiting`). It stays alive (a restart would end it) but is no open job.
 */
export const AGENT_RESTING: readonly string[] = ['idle', 'waiting']

export function errText(err: unknown): string {
  if (err instanceof Error) return err.message.slice(0, 120)
  return String(err).slice(0, 120)
}

/**
 * A `$.session.compact` rejection as a row value: Claude Code's own error text on one line,
 * control characters dropped, at most 160 characters (the local stream only; the export drops it).
 */
export function rejectText(err: unknown): string {
  const raw = err instanceof Error ? err.message : String(err)
  return raw.replace(/[\u0000-\u001f\u007f]+/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 160)
}

/**
 * The class of a `$.session.compact` rejection: `headless` when Claude Code says the call is not
 * available in a headless (`-p` / SDK) session, `turn-running` while a turn runs, else `other`.
 */
export function rejectClass(text: string): 'headless' | 'turn-running' | 'other' {
  if (/headless|-p \/ SDK|\bSDK session\b/i.test(text)) return 'headless'
  if (/\bturn\b.*\brun(s|ning)?\b/i.test(text)) return 'turn-running'
  return 'other'
}

/**
 * The class of a failed `/compact` run (its rejection or its output text): `no-command` (no
 * `/compact` here, as with compaction turned off), `input-ended` (the host ended its input or a
 * limit, as at the end of a single-prompt `claude -p`), `in-hook` (called where a turn waits),
 * `not-enough` (too few messages), else `other`. The first two cannot work later in the load.
 */
export function commandClass(text: string): 'no-command' | 'input-ended' | 'in-hook' | 'not-enough' | 'other' {
  if (/no command named|unknown command/i.test(text)) return 'no-command'
  if (/ended its input|input (has )?ended|host'?s limits?|past a stop/i.test(text)) return 'input-ended'
  if (/inside a hook|hook the turn waits/i.test(text)) return 'in-hook'
  if (/not enough messages/i.test(text)) return 'not-enough'
  return 'other'
}

/** A headless load whose plugin compaction is off (no `/compact` path left): no nudge, no boundary. */
export function pluginCompactOff(s: LoadState): boolean {
  return s.headless && s.headlessCompact === 'none'
}

/**
 * At our `session.compact` hook, before any await: our `/compact` in flight takes the first main
 * `manual` compaction that reaches the hook as ours (once). A person's or the host's own
 * `/compact` queued just before ours would be taken too; it then gets our instructions after
 * its own, and ours runs as a plain manual one after it.
 */
export function claimOwnCompact(s: LoadState, e: { trigger: string; agentId?: string }): OwnCompact | undefined {
  const own = s.ownCompact
  if (!own || own.claimed || e.agentId !== undefined || e.trigger !== 'manual') return undefined
  own.claimed = true
  return own
}

/** Before our `$.prompt.submit`: the next main turn.start is ours (MOD-SPEC §9, §9.1 step 3). */
export function submitPending(s: LoadState, text: string): void {
  s.ourSubmitPending = true
  s.ourSubmitText = text
  s.orphanSubmit = false
  s.orphanHt = null
}

/** Our submit failed, or its turn has started. */
export function submitSettled(s: LoadState): void {
  s.ourSubmitPending = false
  s.ourSubmitText = undefined
}

/** The turn text is the one we submitted (framed or bare; whitespace at the ends aside). */
export function isOurText(turnText: string, sent: string | undefined): boolean {
  const b = sent?.trim() ?? ''
  const a = turnText.trim()
  return b !== '' && (a === b || a.includes(b))
}

/**
 * At a main turn.start, before any await: whether it is the turn of our pending submit. With no
 * other prompt entering, the first turn to start is ours, as before. When a prompt of the user
 * (or of another plugin) entered beside ours, only a turn that carries our text is ours, and
 * the other turn leaves our submit pending for the turn still to come (CR-F17).
 */
export function claimTurn(s: LoadState, turnText: string): boolean {
  // A prompt queued over an earlier turn whose own turn this is: its turn carries exactly its
  // text (xxxxxxxx, xxxxxxxx: 5 of 5), so a turn that only contains it (a task notification
  // quoting a short "y") is not taken for it.
  const t = turnText.trim()
  const q = t === '' ? -1 : s.queuedKinds.findIndex(k => k.text.trim() === t)
  const foreign = s.foreignPrompts > 0 || q >= 0
  const ours = s.ourSubmitPending && (!foreign || isOurText(turnText, s.ourSubmitText))
  if (ours) {
    submitSettled(s)
    s.turnOrigin = 'plugin'
  } else if (q >= 0) {
    // A prompt typed while a turn ran starts its own turn after it (xxxxxxxx 2026-10-30): its
    // origin kind was kept when it was queued, never counted as entering.
    s.turnOrigin = s.queuedKinds.splice(q, 1)[0]?.kind
  } else {
    if (s.foreignPrompts > 0) s.foreignPrompts--
    // A prompt queued beside a turn of ours starts its turn after that turn's end, where the
    // entering count was reset (a bound): its origin kind is still the oldest one kept.
    s.turnOrigin = s.enteringKinds.shift()
  }
  // Other turns (task notifications, ...) may start first: a queued prompt is kept until its
  // turn starts, or until MAX_ENTERING later turns have started (then it went into its turn).
  for (const k of s.queuedKinds) k.passed++
  s.queuedKinds = s.queuedKinds.filter(k => k.passed <= MAX_ENTERING)
  return ours
}

/** IC-1 D6: the origin kinds of a person's prompt (typed, remote bridge, SDK). */
export const HUMAN_ORIGINS: readonly string[] = ['composer', 'bridge', 'sdk']

export function isHuman(kind: string | undefined): boolean {
  return kind !== undefined && HUMAN_ORIGINS.includes(kind)
}

/** `prompt.submit` of a prompt entering an idle session (no `turnId`): its turn starts next. */
export function promptEntering(s: LoadState, kind = 'unknown', text?: string): void {
  s.foreignPrompts++
  // A prompt kept as queued with this same text is not the one whose turn starts next: this
  // entering one is, and it takes the entering origin kind (no stale kind left behind).
  const t = text?.trim() ?? ''
  if (t !== '') s.queuedKinds = s.queuedKinds.filter(k => k.text.trim() !== t)
  s.enteringKinds.push(kind)
  // A bound, as for the count: a kind whose prompt never started a turn is not kept for long.
  if (s.enteringKinds.length > MAX_ENTERING) s.enteringKinds.shift()
}

/** The origin kinds kept for prompts that entered and have not started their turns. */
export const MAX_ENTERING = 4

/**
 * `prompt.submit` of another's prompt queued while main turn `over` ran (`turnId` set), once it
 * entered: delivered into that turn, or its own turn starts after it (`claimTurn` tells which by
 * its text). Not counted in `foreignPrompts`: no turn of its own may follow.
 */
export function promptQueued(s: LoadState, kind: string, text: string, over: string): void {
  if (text.trim() === '') return
  s.queuedKinds.push({ kind, text, over, passed: 0 })
  if (s.queuedKinds.length > MAX_ENTERING) s.queuedKinds.shift()
}

/**
 * That prompt did not enter (`{ drop }` or a failed chain): no turn of its own will start. A
 * handoff turn it deferred (CR-F17) runs its delay again once no other prompt is entering.
 */
export function promptNotEntered(s: LoadState, kind = 'unknown'): void {
  if (s.foreignPrompts > 0) s.foreignPrompts--
  const i = s.enteringKinds.lastIndexOf(kind)
  if (i >= 0) s.enteringKinds.splice(i, 1)
  else s.enteringKinds.pop()
  const again = s.afterForeign
  if (s.foreignPrompts > 0 || again === undefined || s.mainTurnRunning) return
  s.afterForeign = undefined
  again()
}

/**
 * A `prompt.submit` of ours: its origin is this plugin's own (`{ kind: 'plugin', name }`, which
 * no hook can change), so it is told from a user's prompt by origin, never by its text, which a
 * peer hook may rewrite (CR-F17). The engine skips only the calling hook, so this hook sees it.
 */
export function isOwnOrigin(origin: { kind: string; name?: string }, name: string): boolean {
  return origin.kind === 'plugin' && origin.name === name
}

/**
 * Our own handoff-turn submit reaching our `prompt.submit` hook after another prompt came first
 * (a main turn started, or a prompt entered whose turn has not started), or our auto-continue
 * after a person's (`userFirst`): it is dropped there, so it never runs after that turn as a
 * plain one (CR-F17, CR-F25), nor takes the resume block that turn should get. A continue behind
 * a task notification's entering prompt still runs after that turn, as before.
 */
export function refuseOwnSubmit(s: LoadState): boolean {
  return (s.handoffSubmitting && (s.mainTurnRunning || s.foreignPrompts > 0)) || (s.contSubmitting && userFirst(s))
}

/**
 * A main turn runs, or a person's prompt (IC-1 D6 origin) entered and its turn has not started.
 * A task notification's or another plugin's entering prompt stops neither a continue nor a
 * compaction, as before: a last cycle's compaction dropped for it would not come again while halt
 * stays on, and the continue still runs after its turn.
 */
export function userFirst(s: LoadState): boolean {
  return s.mainTurnRunning || (s.foreignPrompts > 0 && s.enteringKinds.some(isHuman))
}
