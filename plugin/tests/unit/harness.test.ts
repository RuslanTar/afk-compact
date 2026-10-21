// Shared U-test harness (a *.test.ts file because the kit loads only those; its one self-test
// runs in every file that imports it). A World stands for the engine beneath the plugin:
// test hooks answer every `$` call the mod makes, and a fake helper answers `$.process.run`
// by subcommand, with the stdout forms of BUILD-PLAN §3.1. Synthetic values only.
import type { On, SessionCompactResult, SessionMessage } from 'claude-code'
import type { MockClock } from 'claude-code/testing'
import { expect, mock, test } from 'claude-code/testing'
import { detectSummary } from '../../hooks/lib/detect'

export const HOME = '/hh/u'
export const ROOT = HOME + '/.claude/handoffs'
export const WATCH = ROOT + '/.watch'
export const SID_A = '5e55a001-0c0f-4f1e-9a00-00000000a001'
export const SID_B = '5e55a002-0c0f-4f1e-9a00-00000000a002'
export const AGENT = 'a9a00b3f363327444'
/** 2026-10-21T14:05:12+03:00 */
export const T0 = 1792580712000

export type Call = { sub: string; args: string[]; env: Record<string, string> }
export type Reply = { exitCode: number; stdout: string } | 'reject'
export type Row = Record<string, unknown> & { ev: string }

export type SummaryMode = 'ok' | 'unshaped' | 'missing' | 'truncated'

export class World {
  sid = SID_A
  tokens: number | undefined = 100000
  window = 1000000
  version: { version: string; base?: string } = { version: '2.1.306' }
  policy: Record<string, unknown> = {}
  files = new Map<string, string>()
  writes: string[] = []
  calls: Call[] = []
  rows: Row[] = []
  pathRows: Row[] = []
  toasts: string[] = []
  submits: string[] = []
  /** Instructions each compaction reached the bottom with (self-calls and raised ones). */
  compacts: { instructions: string | undefined; trigger: string | undefined; agentId: string | undefined }[] = []
  /** How the bottom answers `session.compact`. */
  compactMode: 'ok' | 'reject' | { skip: string } = 'ok'
  summaryMode: SummaryMode = 'ok'
  claims = new Map<string, string>()
  prevCopy = 'none'
  measured: string | null = null
  measureBlock = 'Git: main @ 3f9c2e1, 0 modified, 0 untracked\nIn flight: none listed\nEvidence: none'
  /** The second line `save-copy` prints, or undefined for `Saved copy: <path>`. */
  saveLine: string | undefined
  helperDown = false
  name = ''
  clock!: MockClock
  /** Called at the bottom of every `session.compact`, before it answers. */
  atCompact: (() => void) | undefined
  /** Overrides by subcommand. */
  replies: Record<string, (args: string[]) => Reply> = {}

  constructor(init: Partial<Pick<World, 'sid' | 'tokens' | 'window' | 'version'>> = {}) {
    Object.assign(this, init)
  }

  /** Registers every engine-side hook; call before the first `$` call of the test. */
  install(on: On, store: Record<string, unknown> = {}): this {
    this.clock = mock.clock(on, { now: T0 })
    mock.store(on, store)
    mock.env(on, { HOME })
    on('session.id', () => ({ value: this.sid }))
    on('session.usage', () => ({ value: { startedAt: T0, rateLimits: [], context: { tokens: this.tokens, window: this.window } } }))
    on('session.version', () => ({ value: this.version }))
    on('settings.read', () => ({ value: this.policy }))
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
    on('process.run', (_$, e) => {
      const r = this.helper([...e.argv], { ...(e.init?.env ?? {}) })
      if (r === 'reject') return { deny: 'cannot start' }
      return { value: { exitCode: r.exitCode, stdout: r.stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
    })
    on('prompt.submit', (_$, e) => {
      this.submits.push(e.text)
      return { text: e.text }
    })
    on('session.compact', (_$, e) => {
      this.compacts.push({ instructions: e.instructions, trigger: e.trigger, agentId: e.agentId })
      this.atCompact?.()
      if (this.compactMode === 'reject') throw new Error('a turn is running')
      if (typeof this.compactMode === 'object') return { skip: this.compactMode.skip }
      return { messages: this.summaryMessages(e.instructions), tokensBefore: this.tokens ?? 0, tokensAfter: 40000 }
    })
    on('session.start', (_$, e) => ({ cwd: e.cwd }))
    on('turn.start', (_$, e) => ({ turnId: e.turnId }))
    on('turn.complete', () => ({ text: '' }))
    on('prompt.context', (_$, e) => ({ blocks: e.blocks }))
    return this
  }

  /** The summary message a compliant (or not) summarizer would install for these instructions. */
  summaryMessages(instructions: string | undefined): SessionMessage[] {
    const kept: SessionMessage = { role: 'assistant', text: 'kept', toolUses: [] }
    if (this.summaryMode === 'missing') return [{ role: 'user', text: 'something else', toolUses: [] }, kept]
    const re = new RegExp(`⟪${this.name.replace(/[-]/g, '\\-')} v1 n=([0-9a-f]{8}) s=(main|sub)⟫`, 'g')
    let nonce = '00000000'
    let scope = 'main'
    for (const m of (instructions ?? '').matchAll(re)) {
      nonce = m[1] ?? nonce
      scope = m[2] ?? scope
    }
    const head = 'This session is being continued from a previous conversation that ran out of context.\n\nSummary:\n<summary>\n'
    const body =
      this.summaryMode === 'unshaped'
        ? '# LAB-42 retry work\nNo marker here.\n'
        : `⟪${this.name} v1 n=${nonce} s=${scope}⟫\n# LAB-42 — retry in progress\n## Resume here\nStatus: active\n` +
          (this.summaryMode === 'truncated' ? '' : `⟪/${this.name} n=${nonce}⟫\n`)
    return [{ role: 'user', text: head + body + '</summary>', toolUses: [] }, kept]
  }

  /** The fake helper: one answer per subcommand, the stdout forms of BUILD-PLAN §3.1. */
  helper(argv: string[], env: Record<string, string>): Reply {
    const bin = argv[0] ?? ''
    const m = /\/bin\/(.+)-store$/.exec(bin)
    if (m && m[1]) this.name = m[1]
    const sub = argv[1] ?? ''
    const args = argv.slice(2)
    this.calls.push({ sub, args, env })
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
        return ok('{"pid":43210,"pid_lstart":"Tue Oct 21 14:00:00 2026","execpath_version":null}\n')
      case 'log': {
        const row = JSON.parse(flag('--json')) as Row
        if (flag('--stream') === 'paths') this.pathRows.push(row)
        else this.rows.push(row)
        return ok()
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
        const l2 = this.saveLine ?? `Saved copy: ~/.claude/handoffs/r/LAB-42/compact/2026-10-21_14-05-12_5e55a001_c1-${nonce.slice(0, 6)}.md`
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

/** The nonce of the last marker of ours in instruction text. */
export function markerNonce(w: World, text: string | undefined): string | undefined {
  const re = new RegExp(`⟪${w.name} v1 n=([0-9a-f]{8}) s=(main|sub)⟫`, 'g')
  let n: string | undefined
  for (const m of (text ?? '').matchAll(re)) n = m[1]
  return n
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
  const r = w.helper(['/p/bin/x-store', 'claim', '--sid', SID_A, '--nonce', '1a2b3c4d', '--channel', 'prompt.context'], {})
  expect(r).toEqual({ exitCode: 0, stdout: 'CLAIMED\n' })
  expect(w.helper(['/p/bin/x-store', 'claim', '--sid', SID_A, '--nonce', '1a2b3c4d', '--channel', 'prompt.submit'], {})).toEqual({ exitCode: 0, stdout: 'TAKEN prompt.context\n' })
  expect(w.name).toBe('x')
})
