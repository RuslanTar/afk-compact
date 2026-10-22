// Deps: everything a handler needs from the engine, as one interface, plus the real `$`-backed
// implementation. Handlers take Deps, never `$`, so a test can run them through the kit (where
// test hooks answer `$`) or with a fake Deps.
import type { EngineInterface, PluginOptions, SessionCompactResult } from 'claude-code'
import type { Config, Effective, Paths } from './config'
import type { HandoffTurn, HaltReason, Published } from './handoff-turn'
import { optionEnv, parseOptions, paths } from './config'

export type RunResult = {
  /** True when the command ran and exited 0. */
  ok: boolean
  /** Exit code, or null when the call rejected (could not start, or timed out). */
  exitCode: number | null
  stdout: string
  /** `rejected: <message>` when the call rejected, else the child's stderr. */
  error: string
}

export type Usage = { tokens: number | undefined; window: number }
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
  /** `$.session.compact`; rejects while a turn runs. */
  compact(instructions: string): Promise<SessionCompactResult>
  submit(text: string): Promise<void>
  /** `$.process.run` with rejections caught; `stdin` is written to the child, then closed. */
  run(argv: readonly string[], timeoutMs: number, stdin?: string): Promise<RunResult>
  /** Whole-file write; false when it failed. */
  write(path: string, text: string): Promise<boolean>
  exists(path: string): Promise<boolean>
  read(path: string): Promise<string | undefined>
  storeGet(key: string): Promise<unknown>
  storeSet(key: string, value: unknown): Promise<void>
  now(): Promise<number>
  after(ms: number, fn: () => void): { cancel: () => void }
  toast(text: string): void
  policy(): Promise<{ mods_managed_only: boolean; hooks_managed_only: boolean }>
  /** `<root>` and `<watch>`, or undefined when `~` could not be expanded. */
  paths(): Promise<Paths | undefined>
}

/** What one module load keeps in memory (a reload starts a fresh one). */
export type LoadState = {
  loadId: string
  initDone: boolean
  eff: Effective | undefined
  ident: { pid: number | null; pid_lstart: string | null; watch?: string | null } | undefined
  ccVersion: string | null
  helperMissingLogged: boolean
  /** Main turn bookkeeping. */
  mainTurnRunning: boolean
  turnSeq: number
  turnId: string | null
  askOpen: number
  askedThisTurn: boolean
  nudgedThisTurn: boolean
  /** A nudge-driven compaction should auto-continue (MOD-SPEC §9). */
  resumeAfter: boolean
  /** The last main turn ended on a user-owned question. */
  lastTurnAsksUser: boolean
  /** The next main turn.start comes from our own `$.prompt.submit`. */
  ourSubmitPending: boolean
  /** The text of that submit: it tells our turn from a prompt that entered beside it (CR-F17). */
  ourSubmitText: string | undefined
  /** Prompts of others (the user, another plugin) entering an idle session whose turn has not started yet. */
  foreignPrompts: number
  /** Our handoff-turn prompt still queued after a user turn cancelled that turn: its turn gets no nudge. */
  orphanSubmit: boolean
  /** Our handoff-turn `$.prompt.submit` call is in flight: our own `prompt.submit` hook drops it when a user prompt came first. */
  handoffSubmitting: boolean
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
  /** Nonces of this load's mod-self dispatches (the self-call check, §3.1 step 0). */
  selfNonces: Set<string>
  /** The pending main resume block for prompt.context or the continue text. */
  pending: PendingResume | undefined
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
}

export type PendingResume = {
  sid: string
  nonce: string
  block: string
  resumePref: 'prompt.context' | 'sessionstart' | 'prompt.submit' | 'none'
  /** Main turn count when it became pending (an undelivered block survives a whole turn). */
  turnSeq: number
  /** What the mod decided for this compaction, logged as `mod_outcome` once the block settles. */
  outcome: Outcome
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
    ourSubmitPending: false,
    ourSubmitText: undefined,
    foreignPrompts: 0,
    orphanSubmit: false,
    handoffSubmitting: false,
    afterForeign: undefined,
    timer: undefined,
    busy: false,
    lastPluginCompactAt: undefined,
    pluginCompactions: [],
    consecutiveNonOk: 0,
    halt: { active: false, reason: null },
    haltToasted: false,
    ctxSeen: false,
    selfNonces: new Set(),
    pending: undefined,
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
  }
}

/** The real Deps over the engine's `$`. */
export function realDeps($: EngineInterface, options: PluginOptions, state: LoadState): Deps {
  const cfg = parseOptions(options)
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
      return { tokens: u.context.tokens, window: u.context.window }
    },
    async version() {
      const v = await $.session.version()
      return { version: v.version, base: v.base, builtAt: v.builtAt }
    },
    compact: instructions => $.session.compact({ instructions }),
    async submit(text) {
      // A hook or the engine refuses a submit with a resolved `{ drop }`: that is a failed
      // submit too, so the caller's `submit-failed` path runs and `ourSubmitPending` is reset.
      const r = await $.prompt.submit({ text })
      if (r.drop !== undefined) throw new Error('dropped: ' + String(r.drop))
    },
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
    now: () => $.clock.now(),
    after: (ms, fn) => $.clock.after(ms, fn),
    toast(text) {
      if (cfg.warn_ui) $.ui.toast(text)
    },
    async policy() {
      try {
        const p = await $.settings.read({ source: 'policy' })
        return { mods_managed_only: p['allowManagedModsOnly'] === true, hooks_managed_only: p['allowManagedHooksOnly'] === true }
      } catch {
        return { mods_managed_only: false, hooks_managed_only: false }
      }
    },
    paths() {
      if (!state.pathsMemo) {
        state.pathsMemo = (async () => {
          let home: string | undefined
          try {
            home = await $.env.get('HOME')
          } catch {
            home = undefined
          }
          return paths(cfg, home)
        })()
      }
      return state.pathsMemo.then(p => withHelperWatch(p, state.ident))
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

export function errText(err: unknown): string {
  if (err instanceof Error) return err.message.slice(0, 120)
  return String(err).slice(0, 120)
}

/** Before our `$.prompt.submit`: the next main turn.start is ours (MOD-SPEC §9, §9.1 step 3). */
export function submitPending(s: LoadState, text: string): void {
  s.ourSubmitPending = true
  s.ourSubmitText = text
  s.orphanSubmit = false
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
  const foreign = s.foreignPrompts > 0
  const ours = s.ourSubmitPending && (!foreign || isOurText(turnText, s.ourSubmitText))
  if (ours) submitSettled(s)
  else if (foreign) s.foreignPrompts--
  return ours
}

/** `prompt.submit` of a prompt entering an idle session (no `turnId`): its turn starts next. */
export function promptEntering(s: LoadState): void {
  s.foreignPrompts++
}

/**
 * That prompt did not enter (`{ drop }` or a failed chain): no turn of its own will start. A
 * handoff turn it deferred (CR-F17) runs its delay again once no other prompt is entering.
 */
export function promptNotEntered(s: LoadState): void {
  if (s.foreignPrompts > 0) s.foreignPrompts--
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
 * Our own handoff-turn submit reaching our `prompt.submit` hook after a user prompt came first
 * (a main turn started, or a prompt entered whose turn has not started): it is dropped there,
 * so it never runs after that turn as a plain one (CR-F17, CR-F25).
 */
export function refuseOwnSubmit(s: LoadState): boolean {
  return s.handoffSubmitting && (s.mainTurnRunning || s.foreignPrompts > 0)
}
