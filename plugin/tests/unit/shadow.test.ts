// U tests through the kit: the local shadow trial (TRIAL-DUAL-HANDOFF, P-DH-TEST, owner 2026-10-26
// 21:2x "dual handoffs"): nothing without the local trial config; the fire points M1 (typed and
// model-called), M2 (the plugin's handoff turn) and M3 (a compaction with no handoff turn before
// it); the guards (90% windows, no limits, the 58-minute cold rule, the config's own skips); the
// fork outcomes; and the content-free shape of what reaches `trial-save`. Synthetic texts only.
import type { On } from 'claude-code'
import { expect, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import { hasAsset, hasTag } from '../../hooks/lib/assemble'
import type { Measure } from '../../hooks/lib/shadow'
import { COMPACT_TEXT_SEP, LOST_MS, armOf, armOfError, nativePrompt, oldPrompt, parseMeasure, trialPath } from '../../hooks/lib/shadow'
import { HOME, SID_A, SID_B, World, raiseCompact } from './harness.test'

const OLD = hasAsset('trial-old-handoff')
const PRE = hasTag('handoff-turn', 'submit-pre')
const LIMITS = [{ kind: 'five_hour', percentUsed: 12 }, { kind: 'seven_day', percentUsed: 30 }]
const USAGE = { input_tokens: 900, output_tokens: 2500, cache_read_input_tokens: 300000, cache_creation_input_tokens: 100 }
const HEAD = 'ENGINE-HEAD: summarise the conversation.'
const TAIL = '\nENGINE-TAIL: text only.'

function measureOn(extra: Partial<Measure> = {}): Measure {
  return {
    state: 'on', skip: null, m3: true, native_tail: false,
    facts: { text: 'Repository: r\nTicket bucket: LAB-42', repo: 'r', ticket: 'LAB-42', worktree: '/w/repo', branch: 'LAB-42-x', head: 'abc1234', dirty: 2, old_chain_flagged: 1 },
    old: { status: 'ok', skill: '# Old skill (synthetic)\nStep 1: gather.', template: '# Template (synthetic)', sums: { 'create-handoff/SKILL.md': 'a'.repeat(64) }, filled_sha256: 'b'.repeat(64) },
    native: {
      status: 'ok', head: HEAD, tail: TAIL, head_sha256: 'c'.repeat(64), tail_sha256: 'd'.repeat(64), cc_version: '2.1.306',
      prompt_arm: 'control', arm_source: 'default', cache_prefix_flag: false, transcript_flag: 1, precompact_hooks: false,
    },
    ...extra,
  }
}

type Fork = { prompt: string; compactsBefore: number; submitsBefore: number }

/**
 * The trial on this World: the config file exists, `trial-measure` answers `m`, `trial-save`
 * answers ok, and every `$.model.fork` is recorded and answered by `answer` (by call order).
 */
function trialOn(on: On, w: World, m: Measure | (() => Measure) = measureOn(), answer: (prompt: string, i: number) => unknown = () => ({
  value: { isAnswered: true, text: 'shadow reply', usage: USAGE },
})): Fork[] {
  const forks: Fork[] = []
  w.replies['trial-measure'] = () => ({ exitCode: 0, stdout: JSON.stringify(typeof m === 'function' ? m() : m) + '\n' })
  w.replies['trial-save'] = () => ({ exitCode: 0, stdout: '{"written":true}\n' })
  on('model.fork', (_$, e) => {
    forks.push({ prompt: e.prompt, compactsBefore: w.compacts.length, submitsBefore: w.submits.length })
    return answer(e.prompt, forks.length - 1) as never
  })
  return forks
}

/** The config file at its fixed path (the plugin name is known once the helper was called). */
function placeConfig(w: World): void {
  w.files.set(trialPath(HOME, w.name) ?? '', '{}')
}

type Save = { kind: string; moment_id: string; repo?: string; ticket?: string; moment: Record<string, unknown>; old?: Record<string, unknown>; native?: Record<string, unknown> }

function saves(w: World): Save[] {
  return w.callsOf('trial-save').map(c => JSON.parse(c.stdin ?? '{}') as Save)
}

/** A person's turn that ends with an answer, the trial's measure kept after it. */
async function turn($: Engine, w: World, answer = 'Step done.'): Promise<void> {
  await w.userTurn($)
  await w.turnEnd($, answer)
  await w.settle()
}

async function started($: Engine, w: World): Promise<void> {
  w.rateLimits = LIMITS
  await w.start($)
  placeConfig(w)
}

// ---- nothing without the config

test('AT-DH-01: no trial config: turns, a typed handoff, a Skill call, compactions and a handoff turn never measure, fork or save', { options: { precompact_turn: 'true' } }, async ($, on) => {
  const w = new World().install(on)
  const forks = trialOn(on, w)
  w.rateLimits = LIMITS
  await w.start($)
  await turn($, w)
  await $.prompt.submit({ text: '/' + w.name + ':handoff', origin: { kind: 'composer' }, command: { name: w.name + ':handoff', args: '' } } as never)
  await w.turnStart($, '/' + w.name + ':handoff')
  await $.tool.call({ tool: 'Skill', skill: w.name + ':handoff' } as never)
  await w.turnEnd($)
  await raiseCompact($, { trigger: 'auto' })
  await raiseCompact($, { trigger: 'manual', instructions: 'keep the SQL' })
  w.tokens = 410000
  await turn($, w)
  await w.advance(5000)
  expect([forks.length, w.callsOf('trial-measure').length, w.callsOf('trial-save').length]).toEqual([0, 0, 0])
})

for (const state of ['absent', 'off', 'bad'] as const) {
  test(`AT-DH-02: a config the helper reads as ${state}: no fork and no record`, async ($, on) => {
    const w = new World().install(on)
    const forks = trialOn(on, w, { state, why: 'x' })
    await started($, w)
    await turn($, w)
    await raiseCompact($, { trigger: 'auto' })
    expect([w.callsOf('trial-measure').length, forks.length, w.callsOf('trial-save').length]).toEqual([1, 0, 0])
  })
}

// ---- M3

test('AT-DH-03: M3 auto: one old and one native fork, both started before the compaction reaches core; one moment record joined by the dispatch nonce', async ($, on) => {
  const w = new World().install(on)
  const forks = trialOn(on, w)
  await started($, w)
  await turn($, w, 'Status: tests pass.')
  await raiseCompact($, { trigger: 'auto' })
  await w.settle()
  expect(forks.map(f => f.compactsBefore)).toEqual([0, 0])
  const nonce = w.flag(w.callsOf('dispatch')[0], '--nonce') ?? ''
  const s = saves(w)
  expect(s.length).toBe(1)
  expect([s[0]?.kind, s[0]?.moment_id, s[0]?.repo, s[0]?.ticket]).toEqual(['moment', SID_A.slice(0, 8) + '-' + nonce, 'r', 'LAB-42'])
  expect([s[0]?.moment.kind, s[0]?.moment.trigger, s[0]?.moment.nonce, s[0]?.moment.position, s[0]?.moment.plugin_side]).toEqual(['m3-auto', 'auto', nonce, 1, 'n/a'])
  expect([s[0]?.old?.status, s[0]?.native?.status]).toEqual(OLD ? ['ok', 'ok'] : ['no-old-skill', 'ok'])
  expect(s[0]?.native?.reply).toBe('shadow reply')
  expect([s[0]?.native?.reads_est, s[0]?.native?.read_share]).toEqual([3, 0.997])
  // The native arm is the engine's text with nothing of the plugin's added.
  expect(forks[forks.length - 1]?.prompt).toBe(HEAD + TAIL)
  // The plugin's own compaction is unchanged by the trial.
  expect(w.compacts[0]?.instructions).toContain(w.name)
})

test('AT-DH-04: the moment record is content-free: replies only inside the arms, no prompt, fact or tail text anywhere else', async ($, on) => {
  const w = new World().install(on)
  trialOn(on, w)
  await started($, w)
  await turn($, w, 'SECRET-ANSWER-TEXT')
  await raiseCompact($, { trigger: 'auto' })
  await w.settle()
  const s = saves(w)[0]
  const outside = JSON.stringify({ ...s, old: { ...s?.old, reply: undefined }, native: { ...s?.native, reply: undefined } })
  for (const t of ['SECRET-ANSWER-TEXT', 'Old skill', 'Template (synthetic)', 'Ticket bucket', 'ENGINE-HEAD', 'shadow reply']) expect(outside.includes(t)).toBe(false)
  expect(Object.keys(s?.moment ?? {}).sort()).toEqual([
    'branch', 'cc_version', 'dirty', 'facts_age_s', 'head', 'kind', 'model', 'nonce', 'old_chain_flagged', 'opened_at', 'plugin_side', 'position',
    'tokens', 'trigger', 'worktree',
  ])
})

test('AT-DH-05: M3 forks: none for precompute, a subagent compaction, or with m3 off (one skipped:m3-off record)', async ($, on) => {
  const w = new World().install(on)
  const forks = trialOn(on, w, measureOn({ m3: false }))
  await started($, w)
  await turn($, w)
  await raiseCompact($, { trigger: 'precompute' })
  await raiseCompact($, { trigger: 'auto', agentId: 'a9a00b3f363327444' })
  expect(saves(w).length).toBe(0)
  await raiseCompact($, { trigger: 'auto' })
  await w.settle()
  expect(forks.length).toBe(0)
  expect(saves(w).map(s => [s.kind, s.moment.status, s.moment.kind])).toEqual([['skip', 'skipped:m3-off', 'm3-auto']])
})

test('AT-DH-06: M3 manual /compact: the user\'s text joins the native head and tail with the engine\'s separator, byte for byte; the plugin\'s text never', async ($, on) => {
  const w = new World().install(on)
  const forks = trialOn(on, w)
  await started($, w)
  await turn($, w)
  await raiseCompact($, { trigger: 'manual', instructions: 'keep the SQL' })
  await w.settle()
  expect(forks[forks.length - 1]?.prompt).toBe(HEAD + COMPACT_TEXT_SEP + 'keep the SQL' + TAIL)
  const s = saves(w)[0]
  expect([s?.moment.kind, s?.native?.compact_text_added, s?.native?.tail_supplied]).toEqual(['m3-manual', true, false])
})

test('AT-DH-07: M3 for the plugin\'s own compaction with no handoff turn: two forks before the call, kind m3-plugin', { options: { precompact_turn: 'false' } }, async ($, on) => {
  const w = new World().install(on)
  const forks = trialOn(on, w)
  await started($, w)
  w.tokens = 700000
  await turn($, w)
  await w.advance(5000)
  expect(w.compacts.length).toBe(1)
  expect(forks.map(f => f.compactsBefore)).toEqual([0, 0])
  expect(saves(w).map(s => [s.moment.kind, s.moment.trigger])).toEqual([['m3-plugin', 'plugin']])
})

// The plugin's own idle compaction is the idle moment (m3-idle), as Claude Code's is: under
// "idleCompaction": false it takes native's place at the same moment; trigger plugin says who.
// keep_warm_hours 0: this test's fork hook answers every fork, keep-warm's ping too (D-14), and
// keep-warm would hold the check while the agent runs (keepwarm.test.ts covers that path).
test('AT-DH-07 (idle): the plugin\'s own idle compaction at 54 min (native vetoed) is an m3-idle moment with trigger plugin, not m3-plugin; so is the 55.5-min check\'s', { options: { precompact_turn: 'false', keep_warm_hours: 0 } }, async ($, on) => {
  const w = new World().install(on)
  const forks = trialOn(on, w)
  w.policy = { idleCompaction: false }
  await started($, w)
  w.tokens = 260000
  await turn($, w)
  await w.advance(54 * 60000)
  await w.settle()
  expect(w.rowsOf('idle_compact').map(r => r.at)).toEqual(['timer'])
  expect(forks.map(f => f.compactsBefore)).toEqual([0, 0])
  expect(saves(w).map(s => [s.moment.kind, s.moment.trigger])).toEqual([['m3-idle', 'plugin']])
  w.policy = {}
  w.agents = [{ id: 'sub-1', status: 'running' }]
  await w.advance(60000)
  w.tokens = 260000
  await turn($, w)
  await w.advance(56 * 60000)
  await w.settle()
  expect(w.rowsOf('handoff_skipped').map(r => [r.why, r.kind])).toEqual([])
  expect(w.rowsOf('idle_compact').map(r => r.at)).toEqual(['timer', 'check'])
  expect(saves(w).map(s => [s.moment.kind, s.moment.trigger])).toEqual([['m3-idle', 'plugin'], ['m3-idle', 'plugin']])
})

// ---- guards

test('AT-DH-08b (D-80): the trial stays at 90: a plan window at 93 skips near-limit though plugin idle compaction\'s band would let it run (an agent at work, a fresh reading, a measured change of 1)', async ($, on) => {
  const w = new World().install(on)
  const forks = trialOn(on, w)
  await started($, w)
  w.agents = [{ id: 'sub-1', status: 'running' }]
  w.storeSet('limit_deltas', { five_hour: [1] })
  await turn($, w)
  w.rateLimits = [{ kind: 'five_hour', percentUsed: 93 }, { kind: 'seven_day', percentUsed: 30 }]
  await $.session.measure({ context: { tokens: w.tokens, window: 1000000 }, rateLimits: w.rateLimits, changed: ['rateLimits'] } as never)
  await raiseCompact($, { trigger: 'manual' })
  await w.settle()
  expect(forks.length).toBe(0)
  expect(saves(w).map(s => [s.moment.status, s.moment.windows])).toEqual([['skipped:near-limit', ['five_hour:93', 'seven_day:30']]])
})

test('AT-DH-08: guards cover both forks with one record each: no limits, a window at 90%, a cold prefix (58 min); no count cap', async ($, on) => {
  const w = new World().install(on)
  const forks = trialOn(on, w)
  await started($, w)
  await turn($, w)
  w.rateLimits = []
  await raiseCompact($, { trigger: 'manual' })
  w.rateLimits = [{ kind: 'five_hour', percentUsed: 10 }, { kind: 'seven_day', percentUsed: 90 }]
  await raiseCompact($, { trigger: 'manual' })
  w.rateLimits = LIMITS
  await w.advance(58 * 60000 + 1000)
  await raiseCompact($, { trigger: 'manual' })
  await w.settle()
  expect(forks.length).toBe(0)
  expect(saves(w).map(s => s.moment.status)).toEqual(['skipped:no-limits', 'skipped:near-limit', 'skipped:cold'])
  // D-76: the near-limit skip record names the windows read; the other two have none.
  expect(saves(w).map(s => s.moment.windows ?? 'none')).toEqual(['none', ['five_hour:10', 'seven_day:90'], 'none'])
  // No cap: every eligible moment fires.
  for (let i = 0; i < 6; i++) {
    await turn($, w)
    await raiseCompact($, { trigger: 'manual' })
  }
  await w.settle()
  expect(forks.length).toBe(12)
  expect(saves(w).slice(3).map(s => s.moment.position)).toEqual([4, 5, 6, 7, 8, 9])
})

for (const skip of ['not-owner-config', 'cc-version', 'repo-skipped']) {
  test(`AT-DH-09: the config's own skip ${skip} passes through as one record a moment, no fork`, async ($, on) => {
    const w = new World().install(on)
    const forks = trialOn(on, w, { state: 'on', skip, why: 'x' })
    await started($, w)
    await turn($, w)
    await raiseCompact($, { trigger: 'auto' })
    await w.settle()
    expect(forks.length).toBe(0)
    expect(saves(w).map(s => [s.kind, s.moment.status])).toEqual([['skip', 'skipped:' + skip]])
  })
}

// ---- M1

test('AT-DH-10: M1 typed handoff command: two forks before its turn starts, the typed line in the old arm\'s tail; a Skill call in that turn fires nothing more', async ($, on) => {
  const w = new World().install(on)
  const forks = trialOn(on, w)
  await started($, w)
  await turn($, w, 'Last answer before the handoff.')
  // The prompt enters (its turn has not started: the World starts it below).
  await $.prompt.submit({ text: '/' + w.name + ':handoff LAB-42', origin: { kind: 'composer' }, command: { name: w.name + ':handoff', args: 'LAB-42' } } as never)
  expect(forks.length).toBe(2)
  await w.turnStart($, '/' + w.name + ':handoff LAB-42')
  await $.tool.call({ tool: 'Skill', skill: w.name + ':handoff' } as never)
  await w.turnEnd($)
  await w.settle()
  expect(forks.length).toBe(2)
  if (OLD) {
    expect(forks[0]?.prompt).toContain('Last answer before the handoff.')
    expect(forks[0]?.prompt).toContain(w.name + ':handoff LAB-42')
  }
  expect(saves(w).map(s => s.moment.kind)).toEqual(['m1-owner'])
})

test('AT-DH-11: M1 model-called Skill: once a main turn; another skill, a subagent\'s call and a second call in the turn fire nothing', async ($, on) => {
  const w = new World().install(on)
  const forks = trialOn(on, w)
  await started($, w)
  await turn($, w)
  await w.userTurn($)
  await $.tool.call({ tool: 'Skill', skill: 'other:handoff' } as never)
  await $.tool.call({ tool: 'Skill', skill: w.name + ':handoff', agentId: 'a9a00b3f363327444' } as never)
  expect(forks.length).toBe(0)
  await $.tool.call({ tool: 'Skill', skill: w.name + ':handoff' } as never)
  await $.tool.call({ tool: 'Skill', skill: w.name + ':handoff' } as never)
  await w.turnEnd($)
  await w.settle()
  expect(forks.length).toBe(2)
  expect(saves(w).map(s => s.moment.kind)).toEqual(['m1-self'])
  expect(saves(w)[0]?.moment.turn_id).toBe('t2')
})

// ---- M2

test('AT-DH-12: M2 pre-compaction handoff turn: exactly one old and one native fork, right before the submit; the model\'s Skill call inside the turn and the compaction after it fire nothing more', { options: { precompact_turn: 'true' } }, async ($, on) => {
  const w = new World().install(on)
  const forks = trialOn(on, w)
  await started($, w)
  await turn($, w)
  w.tokens = 410000
  await turn($, w)
  await w.advance(2000)
  if (!PRE) return
  expect(w.submits.length).toBe(1)
  expect(forks.map(f => f.submitsBefore)).toEqual([0, 0])
  await w.turnStart($, '')
  const ht = w.lastHt() ?? ''
  await $.tool.call({ tool: 'Skill', skill: w.name + ':handoff' } as never)
  w.tokens = 450000
  await w.turnEnd($, 'Handoff written.')
  await w.advance(1000)
  expect(w.compacts.length).toBe(1)
  expect(forks.length).toBe(2)
  const s = saves(w).filter(x => x.kind === 'moment')
  expect(s.map(x => [x.moment.kind, x.moment.ht, x.moment.plugin_side, x.moment_id])).toEqual([['m2-precompact', ht, 'submitted', SID_A.slice(0, 8) + '-' + ht]])
})

/** Our handoff-turn submit meets a user prompt entering as it goes in (CR-F17), which is then dropped or not. */
function userEntersAtSubmit($: Engine, w: World, userDropped: boolean): { held: () => Promise<unknown> | undefined; open: () => void } {
  const USER = 'the user typed this'
  let held: Promise<unknown> | undefined
  let reached!: () => void
  const atBottom = new Promise<void>(r => { reached = r })
  let open!: () => void
  const gate = new Promise<void>(r => { open = r })
  let first = true
  w.atSubmit = async text => {
    if (text === USER) {
      reached()
      await gate
      return
    }
    if (held !== undefined) return
    held = $.prompt.submit({ text: USER, origin: { kind: 'composer' } } as never)
    await atBottom
  }
  w.dropIf = text => {
    if (text === USER) return userDropped ? 'refused by a guard' : undefined
    if (!first) return undefined
    first = false
    return 'a user prompt came first'
  }
  return { held: () => held, open }
}

test('AT-DH-13: M2 submit dropped because a user prompt came first, and that turn starts: the forks fired once, the record says cancelled', { options: { precompact_turn: 'true' } }, async ($, on) => {
  const w = new World().install(on)
  const forks = trialOn(on, w)
  await started($, w)
  await turn($, w)
  w.tokens = 410000
  await turn($, w)
  if (!PRE) return
  const u = userEntersAtSubmit($, w, false)
  await w.advance(2000)
  const ht = w.lastHt() ?? ''
  expect(forks.length).toBe(2)
  u.open()
  await u.held()
  await w.turnStart($, 'the user typed this')
  await w.settle()
  const s = saves(w).filter(x => x.kind === 'moment')
  expect(s.map(x => [x.moment.ht, x.moment.plugin_side, x.moment.ht_rerun])).toEqual([[ht, 'cancelled', undefined]])
})

test('AT-DH-13 (re-run): the user prompt is dropped too, the delay runs again: still two forks and one record, moved to the new ht', { options: { precompact_turn: 'true' } }, async ($, on) => {
  const w = new World().install(on)
  const forks = trialOn(on, w)
  await started($, w)
  await turn($, w)
  w.tokens = 410000
  await turn($, w)
  if (!PRE) return
  const u = userEntersAtSubmit($, w, true)
  await w.advance(2000)
  const first = w.lastHt() ?? ''
  u.open()
  await u.held()
  await w.settle()
  await w.advance(2000)
  const second = w.lastHt() ?? ''
  expect(second).not.toBe(first)
  expect(forks.length).toBe(2)
  await w.settle()
  const s = saves(w).filter(x => x.kind === 'moment')
  expect(s.map(x => [x.moment.ht, x.moment.ht_rerun, x.moment.plugin_side, x.moment_id])).toEqual([[first, second, 'submitted', SID_A.slice(0, 8) + '-' + first]])
})

test('AT-DH-14: M2 facts measure past 3 s: old arm skipped:facts-timeout, the native fork still starts, and the handoff turn is submitted', { options: { precompact_turn: 'true' } }, async ($, on) => {
  const w = new World().install(on)
  const forks = trialOn(on, w)
  await started($, w)
  await turn($, w)
  w.tokens = 410000
  await turn($, w)
  if (!PRE) return
  let release: () => void = () => undefined
  w.atHelper = async sub => {
    if (sub === 'trial-measure') await new Promise<void>(r => (release = r))
  }
  await w.advance(2000)
  await w.advance(3000)
  release()
  w.atHelper = undefined
  await w.settle()
  expect(w.submits.length).toBe(1)
  expect(forks.length).toBe(1)
  expect(forks[0]?.prompt).toBe(HEAD + TAIL)
  await w.turnStart($, '')
  await w.settle()
  const s = saves(w).filter(x => x.kind === 'moment')
  expect(s.map(x => x.old?.status)).toEqual(['skipped:facts-timeout'])
})

// ---- fork outcomes

test('AT-DH-15: fork outcomes per arm: denied, api-error with its status, nothing-to-fork, empty, aborted, a non-result answer rejected', async ($, on) => {
  const answers: unknown[] = [
    { deny: 'policy says no' },
    { value: { isAnswered: false, reason: 'api-error', status: 529, error: 'overloaded', usage: USAGE } },
    { value: { isAnswered: false, reason: 'nothing-to-fork' } },
    { value: { isAnswered: false, reason: 'empty-reply', usage: USAGE } },
    { value: { isAnswered: false, reason: 'aborted', usage: USAGE } },
    { value: { nope: 1 } },
  ]
  const w = new World().install(on)
  trialOn(on, w, measureOn(), (_p, i) => answers[i % answers.length])
  await started($, w)
  for (let i = 0; i < 3; i++) {
    await turn($, w)
    await raiseCompact($, { trigger: 'manual' })
    await w.settle()
  }
  const s = saves(w)
  expect(s.map(x => [x.old?.status, x.native?.status])).toEqual(OLD
    ? [['denied', 'api-error'], ['nothing-to-fork', 'empty'], ['aborted', 'rejected']]
    : [['no-old-skill', 'denied'], ['no-old-skill', 'api-error'], ['no-old-skill', 'nothing-to-fork']])
  if (OLD) expect([s[0]?.native?.http_status, s[0]?.native?.error]).toEqual([529, 'overloaded'])
  for (const x of s) expect([x.old?.reply, x.native?.reply]).toEqual([undefined, undefined])
})

test('AT-DH-16: a fork with no result after 15 minutes is lost (the record is written); its late result is saved apart', async ($, on) => {
  let finish: (v: unknown) => void = () => undefined
  const w = new World().install(on)
  trialOn(on, w, measureOn({ old: { status: 'no-old-skill', why: 'not-configured' } }), () => new Promise(r => (finish = r)))
  await started($, w)
  await turn($, w)
  await raiseCompact($, { trigger: 'manual' })
  await w.settle()
  expect(saves(w).length).toBe(0)
  await w.advance(LOST_MS)
  expect(saves(w).map(s => [s.kind, s.native?.status, s.old?.status])).toEqual([['moment', 'lost', 'no-old-skill']])
  finish({ value: { isAnswered: true, text: 'late reply', usage: USAGE } })
  await w.settle()
  const late = saves(w)[1]
  expect([late?.kind, late?.native?.status, late?.native?.late, late?.native?.reply]).toEqual(['late', 'ok', true, 'late reply'])
})

test('AT-DH-17: a trial branch that fails (the measure line is not JSON, the save fails) leaves the compaction exactly as without the trial', async ($, on) => {
  const w = new World().install(on)
  const forks = trialOn(on, w)
  w.replies['trial-measure'] = () => ({ exitCode: 0, stdout: 'not json\n' })
  w.replies['trial-save'] = () => 'reject'
  w.rateLimits = LIMITS
  await w.start($)
  await turn($, w)
  await raiseCompact($, { trigger: 'auto' })
  placeConfig(w)
  await turn($, w)
  await raiseCompact($, { trigger: 'auto' })
  await w.settle()
  const strip = (t: string | undefined) => (t ?? '').replace(/[0-9a-f]{8}/g, 'N')
  expect(w.callsOf('trial-measure').length).toBe(1)
  expect(forks.length).toBe(0)
  expect(w.compacts.length).toBe(2)
  expect(strip(w.compacts[1]?.instructions)).toBe(strip(w.compacts[0]?.instructions))
})

test('AT-DH-19: no hook awaits the trial: a turn end while its measure hangs, and a compaction and a typed handoff while their forks hang, all return', async ($, on) => {
  const w = new World().install(on)
  const forks = trialOn(on, w, measureOn(), () => new Promise(() => undefined))
  await started($, w)
  await turn($, w)
  let release: () => void = () => undefined
  w.atHelper = async sub => {
    if (sub === 'trial-measure') await new Promise<void>(r => (release = r))
  }
  await w.userTurn($)
  // The turn end returns while the measure it started is still held.
  await w.turnEnd($)
  expect(w.callsOf('trial-measure').length).toBe(1)
  w.atHelper = undefined
  release()
  await w.settle()
  expect(w.callsOf('trial-measure').length).toBe(2)
  await raiseCompact($, { trigger: 'manual' })
  expect(w.compacts.length).toBe(1)
  await $.prompt.submit({ text: '/' + w.name + ':handoff', origin: { kind: 'composer' }, command: { name: w.name + ':handoff', args: '' } } as never)
  expect(forks.length).toBe(OLD ? 4 : 2)
  expect(saves(w).length).toBe(0)
})

// ---- pure parts

test('AT-DH-18: parseMeasure, armOf and armOfError map every answer; the old prompt carries the skill, template, facts and the tail only when there is one', () => {
  expect(parseMeasure('{"state":"absent"}\n')).toEqual({ state: 'absent' })
  expect([parseMeasure('nope'), parseMeasure('{"state":"maybe"}')]).toEqual([undefined, undefined])
  expect(armOf({ isAnswered: true, text: '  ', usage: USAGE }, 1, 2).status).toBe('empty')
  expect(armOf({ isAnswered: true, text: 'x' }, 1, 2)).toEqual({ status: 'ok', text: 'x', startedAt: 1, endedAt: 2 })
  expect(armOf(null, 1, 2).status).toBe('rejected')
  const he = new Error('x')
  he.name = 'HooksError'
  expect([armOfError(he, 1, 2).status, armOfError(new TypeError('no model'), 1, 2).status]).toEqual(['denied', 'rejected'])
  const m = measureOn()
  const n = 'plug'
  expect(nativePrompt(n, m, undefined, 'tail text')).toBe(HEAD + TAIL)
  expect(nativePrompt(n, { ...m, native: { status: 'no-native-prompt' } }, undefined, undefined)).toBe(undefined)
  if (hasAsset('trial-native-tail')) {
    const p = nativePrompt(n, { ...m, native_tail: true }, ' ', 'TAIL-TEXT') ?? ''
    expect([p.includes('TAIL-TEXT'), p.endsWith(HEAD + TAIL), p.includes(COMPACT_TEXT_SEP)]).toEqual([true, true, false])
  }
  if (!OLD) return
  const o = oldPrompt(n, m, undefined) ?? ''
  for (const t of ['# Old skill (synthetic)', '# Template (synthetic)', 'Ticket bucket: LAB-42', '=== OLD-HANDOFF START', '=== OLD-HANDOFF END ===']) expect(o).toContain(t)
  expect(o.includes('@')).toBe(o.replace(/@/g, '').length < o.length)
  const withTail = oldPrompt(n, m, 'Last reply:\nTAIL-ANSWER') ?? ''
  expect([withTail.includes('TAIL-ANSWER'), o.includes('TAIL-ANSWER')]).toEqual([true, false])
  expect(oldPrompt(n, { ...m, old: { status: 'no-old-skill' } }, undefined)).toBe(undefined)
})

// ---- review fixes (2026-10-27)

test('AT-DH-26: the cold rule holds mid-turn on the last main step\'s start: a compaction 30 min after it fires (with the turn id), one 59 min after it is skipped:cold', async ($, on) => {
  const w = new World().install(on)
  const forks = trialOn(on, w)
  await started($, w)
  await turn($, w)
  await w.userTurn($)
  await w.step($)
  await w.advance(30 * 60000)
  await raiseCompact($, { trigger: 'auto' })
  await w.settle()
  expect(forks.length).toBe(2)
  await w.advance(29 * 60000)
  await raiseCompact($, { trigger: 'auto' })
  await w.settle()
  expect(forks.length).toBe(2)
  const s = saves(w)
  expect(s.map(x => [x.kind, x.moment.status, x.moment.turn_id])).toEqual([['moment', undefined, 't2'], ['skip', 'skipped:cold', 't2']])
})

test('AT-DH-27: a trial-save that fails gets one minimal save-failed call: the arm statuses, no reply', async ($, on) => {
  const w = new World().install(on)
  trialOn(on, w)
  let n = 0
  w.replies['trial-save'] = () => (n++ === 0 ? { exitCode: 1, stdout: '' } : { exitCode: 0, stdout: '{"written":true}\n' })
  await started($, w)
  await turn($, w)
  await raiseCompact($, { trigger: 'manual' })
  await w.settle()
  const s = saves(w)
  expect(s.map(x => [x.kind, x.moment.status])).toEqual([['moment', undefined], ['failed', 'save-failed']])
  expect([s[1]?.moment_id, s[1]?.native?.status, s[1]?.native?.reply, s[1]?.old?.reply]).toEqual([s[0]?.moment_id, 'ok', undefined, undefined])
})

test('AT-DH-28: M2 facts measure past 3 s with no kept facts: one skipped:facts-timeout record, no fork, the handoff turn still submitted', { options: { precompact_turn: 'true' } }, async ($, on) => {
  const w = new World().install(on)
  const forks = trialOn(on, w)
  let k = 0
  w.replies['trial-measure'] = () => ({ exitCode: 0, stdout: k++ === 0 ? 'not json\n' : JSON.stringify(measureOn()) + '\n' })
  await started($, w)
  await turn($, w)
  w.tokens = 410000
  if (!PRE) return
  let release: () => void = () => undefined
  w.atHelper = async sub => {
    if (sub === 'trial-measure') await new Promise<void>(r => (release = r))
  }
  await turn($, w)
  await w.advance(2000)
  await w.advance(3000)
  release()
  w.atHelper = undefined
  await w.settle()
  expect(w.submits.length).toBe(1)
  expect(forks.length).toBe(0)
  expect(saves(w).map(x => [x.kind, x.moment.status, x.moment.kind])).toEqual([['skip', 'skipped:facts-timeout', 'm2-precompact']])
})

test('AT-DH-29: a turn end that measured the trial off: the handoff turn after it runs no measure of its own', { options: { precompact_turn: 'true' } }, async ($, on) => {
  const w = new World().install(on)
  trialOn(on, w, { state: 'off', why: 'off' })
  await started($, w)
  await turn($, w)
  w.tokens = 410000
  await turn($, w)
  await w.advance(2000)
  if (!PRE) return
  expect(w.submits.length).toBe(1)
  expect(w.callsOf('trial-measure').length).toBe(2)
})

test('AT-DH-30: IC-1 D7 (ii) runs again after the M2 measure: a session that changed while it ran gets no submit and no fork', { options: { precompact_turn: 'true' } }, async ($, on) => {
  const w = new World().install(on)
  const forks = trialOn(on, w)
  await started($, w)
  await turn($, w)
  w.tokens = 410000
  await turn($, w)
  if (!PRE) return
  let release: () => void = () => undefined
  w.atHelper = async sub => {
    if (sub === 'trial-measure') await new Promise<void>(r => (release = r))
  }
  await w.advance(2000)
  w.sid = SID_B
  release()
  w.atHelper = undefined
  await w.settle()
  expect([w.submits.length, forks.length]).toEqual([0, 0])
})

test('AT-DH-31: what the mod sends passes the helper\'s field classes: a [1m] model id and the local times (trial.pm $MODEL, $TIME)', async ($, on) => {
  const w = new World().install(on)
  trialOn(on, w)
  w.model = 'claude-opus-5-5[1m]'
  await started($, w)
  await turn($, w)
  await raiseCompact($, { trigger: 'manual' })
  await w.settle()
  const s = saves(w)[0]
  // The same patterns as plugin/helper/lib/trial.pm ($TIME, $MODEL); AT-DH-24 checks the helper keeps them.
  const TIME = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?(?:Z|[+-]\d{2}:\d{2})$/
  const MODEL = /^[a-z][a-z0-9._-]{0,63}(?:\[[0-9a-z]{1,8}\])?$/
  expect(s?.moment.model).toBe('claude-opus-5-5[1m]')
  expect(MODEL.test(String(s?.moment.model))).toBe(true)
  for (const t of [s?.moment.opened_at, s?.old?.started_at, s?.old?.ended_at, s?.native?.started_at, s?.native?.ended_at]) expect(TIME.test(String(t))).toBe(true)
})
