// Shared U-test harness (a *.test.ts file because the kit loads only those; its one self-test
// runs in every file that imports it). A World stands for the engine beneath the plugin:
// test hooks answer every `$` call the mod makes, and a fake helper answers `$.process.run`
// by subcommand, with the stdout forms of BUILD-PLAN §3.1. Synthetic values only.
import type { On, SessionCompactResult, SessionMessage } from 'claude-code'
import type { Engine, MockClock } from 'claude-code/testing'
import { expect, mock, test } from 'claude-code/testing'
import { CLOSE, OPEN, detectSummary, markerText, sentinelText } from '../../hooks/lib/detect'

export const HOME = '/hh/u'
export const ROOT = HOME + '/.claude/handoffs'
export const WATCH = ROOT + '/.watch'
export const SID_A = '5e55a001-0c0f-4f1e-9a00-00000000a001'
export const SID_B = '5e55a002-0c0f-4f1e-9a00-00000000a002'
export const AGENT = 'a9a00b3f363327444'
/** 2026-10-21T14:05:12+03:00 */
export const T0 = 1792580712000

export type Call = { sub: string; args: string[]; env: Record<string, string>; stdin?: string }
export type Reply = { exitCode: number; stdout: string } | 'reject'
export type Row = Record<string, unknown> & { ev: string }

/** `cc311`: an ok summary in the Claude Code 2.1.311 installed form (the tools-used block in a
 * closed `<system-reminder>` block before `Summary:`, no summary tags, the engine trailers). */
export type SummaryMode = 'ok' | 'unshaped' | 'missing' | 'truncated' | 'cc311'

export class World {
  sid = SID_A
  tokens: number | undefined = 100000
  window = 1000000
  version: { version: string; base?: string } = { version: '2.1.306' }
  policy: Record<string, unknown> = {}
  /** Every `$.settings.read` rejects (IA-2: native idle then reads `unknown`). */
  settingsThrow = false
  /** `$.agent.list()` (owner xxxxxxxx-38); undefined: the call rejects. */
  agents: { id: string; status: string }[] | undefined = []
  files = new Map<string, string>()
  writes: string[] = []
  calls: Call[] = []
  rows: Row[] = []
  pathRows: Row[] = []
  /** Raw lines the mod sent to `log --stream jobs` (Dev-1), and the reply that stream gives. */
  jobLines: Record<string, unknown>[] = []
  jobsReply: Reply = { exitCode: 0, stdout: '' }
  /** `$.session.cwd()`. */
  cwd = '/w/repo'
  /** `handoff-state` line per ht (`*` for any); default `none`, or `published` once `<ht>.published` exists. */
  htStates = new Map<string, string>()
  toasts: string[] = []
  submits: string[] = []
  /** Instructions each compaction reached the bottom with (self-calls and raised ones). */
  compacts: { instructions: string | undefined; trigger: string | undefined; agentId: string | undefined }[] = []
  /** How the bottom answers `session.compact`. */
  compactMode: 'ok' | 'reject' | { skip: string } = 'ok'
  /** `session.start`'s `isInteractive` (false: a `claude -p` or SDK session). */
  interactive = true
  /**
   * How the bottom answers `$.command.run({ command: 'compact' })`: `run` raises a manual
   * compaction through every `session.compact` hook (ours included), as Claude Code's `/compact`
   * does, and answers `{}`, or `Not compacted · <skip>` for a skip; `unclaimed` compacts beneath
   * our hook only (it never sees it); `{ text }` answers that text (a failed `/compact`);
   * `reject` makes the call reject (the kit passes no message of a test hook's through: the
   * plugin reads the kit's own text, a class `other` failure).
   */
  commandMode: 'run' | 'unclaimed' | 'reject' | { text: string } = 'run'
  /**
   * The bottom opens a main turn (`/compact`) before a `/compact` run's compaction, as Claude
   * Code may run that command inside a turn; the test ends that turn (`turnEnd`) after the run.
   */
  commandTurn = false
  /** Every `command.run` that reached the bottom. */
  commandRuns: { command: string; args: string; origin: unknown }[] = []
  /** The test's engine, kept at `start` (a `/compact` raises its compaction through it). */
  engine: Engine | undefined
  summaryMode: SummaryMode = 'ok'
  claims = new Map<string, string>()
  prevCopy = 'none'
  measured: string | null = null
  measureBlock = 'Git: main @ 3f9c2e1, 0 modified, 0 untracked\nIn flight: none listed\nEvidence: none'
  /** The second line `save-copy` prints, or undefined for `Saved copy: <path>`. */
  saveLine: string | undefined
  /** The classic PostCompact hook saved this compaction's copy first, from the PostCompact form
   * (`<summary>…</summary>`) of the same summary: `save-copy` (with no `saveLine`) answers
   * `EXISTS … sha-match` or `sha-differs` by the normalized sha256 of the stash against it. */
  postCompactSaved = false
  helperDown = false
  /** The effective watch folder `ident` reports (null: the helper refused every log folder). */
  identWatch: string | null = WATCH
  name = ''
  /** `$.plugin.root`, read off the helper path. */
  root = ''
  clock!: MockClock
  /** Called at the bottom of every `session.compact`, before it answers. */
  atCompact: (() => void) | undefined
  /** Overrides by subcommand. */
  replies: Record<string, (args: string[]) => Reply> = {}
  /** Awaited before the fake helper answers a call (a race inside one helper spawn). */
  atHelper: ((sub: string, args: string[]) => Promise<void>) | undefined
  /** How the bottom answers `$.prompt.submit`: `{ drop }` with this reason when set. */
  submitDrop: string | undefined
  /** Awaited at the bottom of every `$.prompt.submit`, before it answers (a race beside a submit). */
  atSubmit: ((text: string) => Promise<void>) | undefined
  /** After `atSubmit`: `{ drop }` with the reason this returns for the text (a hook beneath that refuses one prompt). */
  dropIf: ((text: string) => string | undefined) | undefined
  /** A peer hook beneath the plugin that rewrites the text (`next({ ...e, text })`). */
  rewrite: ((text: string) => string | undefined) | undefined
  /** The origin of every `prompt.submit` that reached the bottom. */
  submitOrigins: unknown[] = []
  /** Awaited at the bottom of every `session.compact` before it answers (a compaction that runs a while). */
  compactGate: Promise<void> | undefined
  /**
   * `$.session.usage().rateLimits` (empty: no subscription reading, IC-1 `ttl-5m`). Only a
   * `five_hour` or `seven_day` window shows the one-hour cache (D15); a window without a kind is none.
   */
  rateLimits: { kind?: string; percentUsed: number }[] = []
  /** Environment variables the plugin reads beside HOME (`$.env.get`), read when asked. */
  env: Record<string, string> = {}
  /** `$.session.model()` (MG-4); undefined: the call rejects. */
  model: string | undefined = 'claude-test-model'
  /** MG-2 spy: the argument keys of every `session.compact` and `prompt.submit` reaching the bottom. */
  compactKeys: string[][] = []
  submitKeys: string[][] = []
  /** The summarizer usage a compaction result carries (MG-3); undefined: none. */
  compactUsage: { input_tokens: number; output_tokens: number; cache_read_input_tokens: number; cache_creation_input_tokens: number } | undefined
  /** The usage a `turn.step` result carries (MG-3); null: none. */
  stepUsage: { input_tokens: number; output_tokens: number; cache_read_input_tokens: number; cache_creation_input_tokens: number; model: string } | null = null
  /** The turn ids `$.turn.abort` was called with (OT-2). */
  aborts: string[] = []
  /** `$.turn.abort` rejects (the turn is not the running one). */
  abortThrow = false
  /** While set, a `prompt.submit` reaching the bottom is not recorded (the person's own prompts of `userTurn`). */
  private quiet = false

  constructor(init: Partial<Pick<World, 'sid' | 'tokens' | 'window' | 'version'>> = {}) {
    Object.assign(this, init)
  }

  /** Registers every engine-side hook; call before the first `$` call of the test. */
  install(on: On, store: Record<string, unknown> = {}): this {
    const world = this
    this.clock = mock.clock(on, { now: T0 })
    // The plugin's store, kept here as mock.store keeps it (JSON values), so a test can write a key
    // as another process would (`storeSet`) and read what it holds (`storeGet`).
    for (const [k, v] of Object.entries(store)) this.storeMem.set(k, json(v))
    on('store.get', (_$, e) => ({ value: json(this.storeMem.get(e.key)) }))
    on('store.set', (_$, e) => {
      this.storeMem.set(e.key, json(e.value))
      return { value: undefined }
    })
    on('store.delete', (_$, e) => {
      this.storeMem.delete(e.key)
      return { value: undefined }
    })
    on('store.keys', () => ({ value: [...this.storeMem.keys()] }))
    // The environment the plugin reads: HOME, and the test's own variables, read when asked.
    on('env.get', (_$, e) => ({ value: e.name === 'HOME' ? HOME : this.env[e.name] }))
    on('session.id', () => ({ value: this.sid }))
    on('session.usage', () => ({ value: { startedAt: T0, rateLimits: this.rateLimits as never, context: { tokens: this.tokens, window: this.window } } }))
    on('session.version', () => ({ value: this.version }))
    on('session.cwd', () => ({ value: this.cwd }))
    on('settings.read', () => {
      if (this.settingsThrow) throw new Error('settings unreadable')
      return { value: this.policy }
    })
    on('agent.list', () => {
      if (this.agents === undefined) throw new Error('no agent list')
      return { value: this.agents.map(a => ({ id: a.id, description: 'job', type: 'general-purpose', status: a.status })) as never }
    })
    on('ui.toast', (_$, e) => {
      this.toasts.push(e.text)
      return { value: undefined }
    })
    on('fs.write', (_$, e) => {
      this.writes.push(e.path)
      this.files.set(e.path, e.text)
      return { value: undefined }
    })
    on('fs.read', (_$, e) => {
      const t = this.files.get(e.path)
      return t === undefined ? { deny: 'missing' } : { value: t }
    })
    on('fs.exists', (_$, e) => ({ value: this.files.has(e.path) }))
    on('process.run', async (_$, e) => {
      if (this.atHelper) await this.atHelper(e.argv[1] ?? '', e.argv.slice(2))
      const r = this.helper([...e.argv], { ...(e.init?.env ?? {}) }, e.init?.stdin)
      if (r === 'reject') return { deny: 'cannot start' }
      return { value: { exitCode: r.exitCode, stdout: r.stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
    })
    on('session.model', () => {
      if (this.model === undefined) throw new Error('no model')
      return { value: this.model }
    })
    on('turn.step', async function* (this: void, _$, e) {
      return { turnId: e.turnId, index: e.index, answer: '', toolUses: [], stopReason: 'end_turn' as const, usage: world.stepUsage }
    })
    on('prompt.submit', async (_$, e) => {
      if (this.quiet) return { text: e.text }
      this.submitKeys.push(Object.keys(e).sort())
      this.submitOrigins.push(e.origin)
      if (this.submitDrop !== undefined) return { drop: this.submitDrop }
      this.submits.push(e.text)
      if (this.atSubmit) await this.atSubmit(e.text)
      const why = this.dropIf?.(e.text)
      if (why !== undefined) return { drop: why }
      return { text: this.rewrite?.(e.text) ?? e.text }
    })
    on('command.run', async (_$, e) => {
      this.commandRuns.push({ command: e.command, args: e.args, origin: e.origin })
      const m = this.commandMode
      if (m === 'reject') throw new Error('rejected')
      if (typeof m === 'object') return { text: m.text }
      if (e.command !== 'compact') return { text: 'no such command here' }
      if (m === 'unclaimed') {
        this.compacts.push({ instructions: e.args || undefined, trigger: 'manual', agentId: undefined })
        return {}
      }
      if (!this.engine) throw new Error('World.start was not called')
      if (this.commandTurn) await this.turnStart(this.engine, '/compact')
      const r = await this.engine.session.compact({ trigger: 'manual', messages: [KEPT], ...(e.args ? { instructions: e.args } : {}) } as never)
      return r.skip !== undefined ? { text: 'Not compacted · ' + r.skip } : {}
    })
    on('session.compact', async (_$, e) => {
      this.compacts.push({ instructions: e.instructions, trigger: e.trigger, agentId: e.agentId })
      this.compactKeys.push(Object.keys(e).sort())
      this.atCompact?.()
      if (this.compactGate) await this.compactGate
      if (this.compactMode === 'reject') throw new Error('a turn is running')
      if (typeof this.compactMode === 'object') return { skip: this.compactMode.skip }
      return {
        messages: this.summaryMessages(e.instructions), tokensBefore: this.tokens ?? 0, tokensAfter: 40000,
        ...(this.compactUsage !== undefined ? { usage: this.compactUsage } : {}),
      }
    })
    on('session.start', (_$, e) => ({ cwd: e.cwd }))
    on('session.end', (_$, e) => ({ sessionId: e.sessionId }))
    on('turn.abort', (_$, e) => {
      this.aborts.push(e.turnId)
      if (this.abortThrow) throw new Error(`turn ${e.turnId} is not the running turn`)
      return { value: undefined }
    })
    on('turn.start', (_$, e) => ({ turnId: e.turnId }))
    on('turn.complete', () => ({ text: '' }))
    on('prompt.context', (_$, e) => ({ blocks: e.blocks }))
    on('prompt.edit', (_$, e) => ({ text: e.text.slice(0, e.start) + e.inputText + e.text.slice(e.end), cursor: e.start + e.inputText.length }))
    on('prompt.change', (_$, e) => ({ text: e.text }))
    on('tool.call', (_$, e) => this.toolAnswer(String(e.tool)) as never)
    return this
  }

  /** How the bottom answers a tool call (a promise holds the call open). */
  toolAnswer: (tool: string) => unknown = () => ({ result: {} })

  // ---- driving the session as the engine would

  async start($: Engine): Promise<void> {
    this.engine = $
    await $.session.start({ cwd: '/w', surface: this.interactive ? 'terminal' : null, isInteractive: this.interactive })
  }

  private turnNo = 0

  /** The person types one character into the prompt box (`prompt.edit`, D11; the kit raises it, its 2.1.305 types do not list it). */
  async edit($: Engine): Promise<void> {
    await (($ as unknown as PromptBoxEngine).prompt.edit({ origin: { kind: 'composer' }, text: '', cursor: 0, start: 0, end: 0, inputText: 'x' }))
  }

  /** The prompt box changes by `origin` (`history`, `clear`, `undo`, `engine`, `plugin`, `app`; D11). */
  async change($: Engine, origin: string): Promise<void> {
    const o = origin === 'plugin' ? { kind: 'plugin', name: 'other' } : { kind: origin }
    await (($ as unknown as PromptBoxEngine).prompt.change({ text: 'an earlier prompt', cursor: 0, origin: o }))
  }

  /** The plugin's `$.store` (one file for every process in real life). */
  private storeMem = new Map<string, unknown>()

  /** Another process writes this key of the shared store (undefined: removes it). */
  storeSet(key: string, value: unknown): void {
    if (value === undefined) this.storeMem.delete(key)
    else this.storeMem.set(key, json(value))
  }

  /** The key as the shared store holds it now (undefined: unset). */
  storeGet(key: string): unknown {
    return json(this.storeMem.get(key))
  }

  /** Every key the shared store holds now (what a next process over the same store reads). */
  storeAll(): Record<string, unknown> {
    return Object.fromEntries([...this.storeMem.keys()].map(k => [k, this.storeGet(k)]))
  }

  /** A main turn starts (a user prompt, or our own continue when `text` says so). */
  async turnStart($: Engine, text = 'next step please'): Promise<void> {
    this.turnNo++
    await $.turn.start({ text, turnId: 't' + String(this.turnNo) })
  }

  /**
   * A main turn a person's prompt opens: the prompt enters with this origin kind (IC-1 D6:
   * `composer`, `bridge` and `sdk` are human, so the turn clears halt; `task-notification`,
   * `scheduled-trigger` and the like are not), then its turn starts. The prompt is not recorded in
   * `submits`.
   */
  async userTurn($: Engine, text = 'next step please', kind = 'composer'): Promise<void> {
    this.quiet = true
    try {
      await $.prompt.submit({ text, origin: { kind } } as never)
    } finally {
      this.quiet = false
    }
    await this.turnStart($, text)
  }

  async turnEnd($: Engine, answer = 'Done with that step.', reason: 'answer' | 'aborted' = 'answer'): Promise<void> {
    await $.turn.complete({ answer, durationMs: 1000, isAborted: reason === 'aborted', turnId: 't' + String(this.turnNo), reason })
  }

  /** One model request (`turn.step`) of the current main turn, at `index`; its result usage is `stepUsage`. */
  async step($: Engine, index = 0): Promise<void> {
    const s = $.turn.step({ turnId: 't' + String(this.turnNo), index, model: this.model ?? 'x', messageCount: 1 } as never)
    for await (const _ of s) void _
    await s.result
  }

  /** One main tool call; returns its result as the model would read it. */
  async tool($: Engine, agentId?: string): Promise<{ context?: readonly string[]; deny?: string }> {
    const e = { tool: 'Bash', command: 'ls', ...(agentId ? { agentId } : {}) }
    return (await $.tool.call(e as never)) as { context?: readonly string[]; deny?: string }
  }

  /** The summary message a compliant (or not) summarizer would install for these instructions. */
  summaryMessages(instructions: string | undefined): SessionMessage[] {
    const kept: SessionMessage = { role: 'assistant', text: 'kept', toolUses: [] }
    if (this.summaryMode === 'missing') return [{ role: 'user', text: 'something else', toolUses: [] }, kept]
    const re = markerRe(this.name)
    let nonce = '00000000'
    let scope = 'main'
    for (const m of (instructions ?? '').matchAll(re)) {
      nonce = m[1] ?? nonce
      scope = m[2] ?? scope
    }
    const continued = 'This session is being continued from a previous conversation that ran out of context.\n\n'
    const body = this.summaryBody(nonce, scope)
    if (this.summaryMode === 'cc311') {
      const head = continued + '<system-reminder>\n<tools-used-before-summary>Bash, Read</tools-used-before-summary>\n</system-reminder>\nSummary:\n'
      const tail = '\nIf you need specific details from before compaction (like exact code snippets), read the full transcript at: /tmp/t.jsonl\n' +
        'Continue the conversation from where it left off without asking the user any further questions.\n\n' +
        'The messages after this summary are the most recent messages from before compaction, kept verbatim.\n'
      return [{ role: 'user', text: head + body + tail, toolUses: [] }, kept]
    }
    return [{ role: 'user', text: continued + 'Summary:\n<summary>\n' + body + '</summary>', toolUses: [] }, kept]
  }

  /** The summary body (between the summary tags) for this nonce and scope. */
  summaryBody(nonce: string, scope: string): string {
    return this.summaryMode === 'unshaped'
      ? '# LAB-42 retry work\nNo marker here.\n'
      : markerText(this.name, nonce, scope === 'sub' ? 'sub' : 'main') + '\n# LAB-42 — retry in progress\n## Resume here\nStatus: active\n' +
          (this.summaryMode === 'truncated' ? '' : sentinelText(this.name, nonce) + '\n')
  }

  /** The fake helper: one answer per subcommand, the stdout forms of BUILD-PLAN §3.1. */
  helper(argv: string[], env: Record<string, string>, stdin?: string): Reply {
    const bin = argv[0] ?? ''
    const m = /^(.*)\/scripts\/(.+)-store$/.exec(bin)
    if (m && m[1] !== undefined && m[2]) {
      this.root = m[1]
      this.name = m[2]
    }
    const sub = argv[1] ?? ''
    const args = argv.slice(2)
    this.calls.push(stdin === undefined ? { sub, args, env } : { sub, args, env, stdin })
    if (this.helperDown) return 'reject'
    const own = this.replies[sub]
    if (own) return own(args)
    const flag = (k: string) => {
      const i = args.indexOf(k)
      return i >= 0 ? (args[i + 1] ?? '') : ''
    }
    const ok = (stdout = '') => ({ exitCode: 0, stdout })
    const sid = flag('--sid')
    switch (sub) {
      case 'ident':
        return ok(JSON.stringify({ pid: 43210, pid_lstart: 'Tue Oct 21 14:00:00 2026', execpath_version: null, watch: this.identWatch }) + '\n')
      case 'log': {
        // `--stdin` (F2-6): one JSON object per line, each appended as a row.
        const rows = args.includes('--stdin')
          ? (stdin ?? '').split('\n').filter(l => l !== '').map(l => JSON.parse(l) as Row)
          : [JSON.parse(flag('--json')) as Row]
        if (flag('--stream') === 'jobs') {
          this.jobLines.push(...rows)
          return this.jobsReply
        }
        if (flag('--stream') === 'paths') this.pathRows.push(...rows)
        else this.rows.push(...rows)
        return ok()
      }
      case 'handoff-turn': {
        // D-18 B8 (core): `open` exclusive-creates <ht>.json; `supersede` writes the write-once twin.
        const ht = flag('--ht')
        const rec = `${WATCH}/${sid}/handoff-turn/${ht}.json`
        if (args[0] === 'open') {
          if (this.files.has(rec)) return ok('EXISTS\n')
          this.files.set(rec, JSON.stringify({ v: 1, ht, session_id: sid, reason: flag('--reason'), max_calls: Number(flag('--max-calls')), max_tokens: Number(flag('--max-tokens')) }) + '\n')
          return ok('ok\n')
        }
        if (args[0] === 'close') {
          // BL-2 as asked of core (mod-to-core item 5): exclusive-creates <ht>.closed.
          if (!this.files.has(rec)) return { exitCode: 3, stdout: 'REFUSED: no-ht\n' }
          const closed = `${WATCH}/${sid}/handoff-turn/${ht}.closed`
          if (this.files.has(closed)) return ok('EXISTS\n')
          this.files.set(closed, flag('--why') + '\n')
          return ok('ok\n')
        }
        if (args[0] === 'supersede') {
          if (!this.files.has(rec)) return { exitCode: 3, stdout: 'REFUSED: no-ht\n' }
          const twin = `${WATCH}/${sid}/handoff-turn/${ht}.superseded`
          if (this.files.has(twin)) return ok('EXISTS\n')
          this.files.set(twin, flag('--nonce') + '\n')
          return ok('ok\n')
        }
        return { exitCode: 64, stdout: '' }
      }
      case 'handoff-state': {
        const ht = flag('--ht')
        const pub = this.files.get(`${WATCH}/${sid}/handoff-turn/${ht}.published`)
        if (pub !== undefined) return ok(`published ${pub.trim()}\n`)
        return ok((this.htStates.get(ht) ?? this.htStates.get('*') ?? 'none') + '\n')
      }
      case 'dispatch': {
        const nonce = flag('--nonce')
        const path = `${WATCH}/${sid}/dispatch/${nonce}.json`
        if (this.files.has(path)) return { exitCode: 3, stdout: 'REFUSED: nonce-exists\n' }
        this.files.set(path, JSON.stringify({ nonce, channel: flag('--channel'), resume_pref: flag('--resume-pref'), actor: flag('--actor') }))
        return ok('ok\n')
      }
      case 'prev-copy':
        return ok(this.prevCopy + '\n')
      case 'checkpoint':
        return ok(JSON.stringify({ measured_block: this.measured, lane: null, gsd: [], inventory: [], evidence_map: [], checkpoint_ms: { total: 12 }, timeouts: [] }) + '\n')
      case 'save-copy': {
        const nonce = flag('--nonce')
        const text = this.files.get(flag('--from')) ?? ''
        const scope = flag('--scope') === 'sub' ? 'sub' : 'main'
        const det = detectSummary(text, this.name, { dispatchNonce: nonce, scope })
        const l1 = `VERDICT ${det.verdict} marker_line=${det.marker_line ?? '-'} sentinel_from_end=${det.sentinel_from_end ?? '-'}`
        const copy = `~/.claude/handoffs/r/LAB-42/compact/2026-10-21_14-05-12_5e55a001_c1-${nonce.slice(0, 6)}.md`
        const post = this.postCompactSaved ? detectSummary(`<summary>\n${this.summaryBody(nonce, scope)}</summary>`, this.name, { dispatchNonce: nonce, scope }) : undefined
        const l2 = this.saveLine ?? (post ? `EXISTS: ${copy} sha-${post.sha256 === det.sha256 ? 'match' : 'differs'}` : `Saved copy: ${copy}`)
        return { exitCode: l2.startsWith('REFUSED') ? 3 : 0, stdout: `${l1}\n${l2}\n` }
      }
      case 'sweep':
        return ok('TOTAL copied=0 dup=0 ref_only=0 redacted=0 withheld=0 referenced_budget=0\n')
      case 'claim': {
        const nonce = flag('--nonce')
        const taken = this.claims.get(nonce)
        if (taken) return ok(`TAKEN ${taken}\n`)
        this.claims.set(nonce, flag('--channel'))
        this.files.set(`${WATCH}/${sid}/resume-claimed/${nonce}`, flag('--channel'))
        return ok('CLAIMED\n')
      }
      case 'measure':
        return ok(this.measureBlock + '\n')
      // The local shadow trial without its config (BT-05 records the real helper's answers).
      case 'trial-measure':
        return ok('{"state":"absent","why":null}\n')
      case 'trial-save':
        return ok('{"why":"absent","written":false}\n')
      case 'notice': {
        // W-BETA A (core): `notice claim --id I` exclusive-creates <watch>/notice/<I>.shown.
        const id = flag('--id')
        if (args[0] !== 'claim' || !/^[a-z0-9-]{1,40}$/.test(id)) return { exitCode: 64, stdout: '' }
        const marker = `${WATCH}/notice/${id}.shown`
        if (this.files.has(marker)) return ok('seen\n')
        this.files.set(marker, '')
        return ok('show\n')
      }
      default:
        return { exitCode: 64, stdout: '' }
    }
  }

  // ---- reads over what the plugin did

  callsOf(sub: string): Call[] {
    return this.calls.filter(c => c.sub === sub)
  }

  rowsOf(ev: string): Row[] {
    return this.rows.filter(r => r.ev === ev)
  }

  /** The ht of the newest `handoff-turn open` call. */
  lastHt(): string | undefined {
    const opens = this.callsOf('handoff-turn').filter(c => c.args[0] === 'open')
    return this.flag(opens[opens.length - 1], '--ht')
  }

  /** The skill published the handoff of this ht (as `publish` writes `<ht>.published`). */
  publish(ht: string, path: string): void {
    this.files.set(`${WATCH}/${this.sid}/handoff-turn/${ht}.published`, path + '\n')
  }

  flag(c: Call | undefined, k: string): string | undefined {
    if (!c) return undefined
    const i = c.args.indexOf(k)
    return i >= 0 ? c.args[i + 1] : undefined
  }

  /** Lets timers due now run and the plugin's pending work settle. */
  async settle(rounds = 20): Promise<void> {
    for (let i = 0; i < rounds; i++) await this.clock.settle()
  }

  /** Moves the clock on and lets what came due run. */
  async advance(ms: number): Promise<void> {
    await this.clock.advance(ms)
    await this.settle()
  }
}

/** A store value as `$.store` keeps it: `JSON.parse(JSON.stringify(value))`. */
function json(v: unknown): unknown {
  return v === undefined ? undefined : JSON.parse(JSON.stringify(v))
}

/** The prompt-box events the kit raises (Claude Code 2.1.311) beyond the 2.1.305 `Engine` type. */
type PromptBoxEngine = { prompt: { edit: (e: unknown) => Promise<unknown>; change: (e: unknown) => Promise<unknown> } }

/** The nonce of the last marker of ours in instruction text. */
export function markerNonce(w: World, text: string | undefined): string | undefined {
  const re = markerRe(w.name)
  let n: string | undefined
  for (const m of (text ?? '').matchAll(re)) n = m[1]
  return n
}

/** Our instruction-marker pattern for a plugin name (global). */
export function markerRe(name: string): RegExp {
  return new RegExp(OPEN + name.replace(/[.*+?^$()|[\]\\]/g, '\\$&') + ' v1 n=([0-9a-f]{8}) s=(main|sub)' + CLOSE, 'g')
}

export const KEPT: SessionMessage = { role: 'user', text: 'hello', toolUses: [] }

/** Raises a compaction from the test (as core or another plugin would). */
export async function raiseCompact(
  $: { session: { compact: (e: never) => Promise<SessionCompactResult> } },
  e: { trigger: string; agentId?: string; instructions?: string },
): Promise<SessionCompactResult> {
  return $.session.compact({ messages: [KEPT], ...e } as never)
}

test('harness: the fake helper answers ident and claim', () => {
  const w = new World()
  const bin = '/p/scripts/x' + '-store'
  const r = w.helper([bin, 'claim', '--sid', SID_A, '--nonce', '1a2b3c4d', '--channel', 'prompt.context'], {})
  expect(r).toEqual({ exitCode: 0, stdout: 'CLAIMED\n' })
  expect(w.helper([bin, 'claim', '--sid', SID_A, '--nonce', '1a2b3c4d', '--channel', 'prompt.submit'], {})).toEqual({ exitCode: 0, stdout: 'TAKEN prompt.context\n' })
  expect(w.name).toBe('x')
})
