// U tests through the kit: restart on update (SESSION-RESTART §7.1, AT-RS-01..19, the mod's part).
// The helper's `restart` command is faked by the World (gate, arm, set, claim, respawn); its real
// behaviour is the helper cases RS-*. A plugin compaction at a turn end (nudged, so a continue
// would follow) or an idle compaction opens the restart moment; the session runs 2.1.311 and
// `claude --version` says 2.1.312.
import { expect, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import { continueLine } from '../../hooks/lib/cont'
import { LAUNCH_ENV } from '../../hooks/lib/launch.gen'
import { DRIFT_TTL_MS, EXIT_WINDOW_MS, RESPAWN_WATCH_MS, RESTART_GRACE_MS, launchNote, parseVersion, vcmp } from '../../hooks/lib/restart'
import type { RestartRun } from '../../hooks/lib/restart'
import type { PendingResume } from '../../hooks/lib/deps'
import { ARMED_FILE, pendingRecord } from '../../hooks/lib/resume'
import { SID_A, T0, WATCH, World, raiseCompact } from './harness.test'

const LAUNCH = '/rt/x-501/L-0123456789abcdef'
const JOB = '/jobs/job1'
const CARRY = `${WATCH}/${SID_A}/restart.json`
const EXIT = { reason: 'prompt_input_exit', sessionId: SID_A, resume: { id: SID_A } }

type Opts = { setting?: string; route?: 'fg' | 'bg'; installed?: string }

/** A session on 2.1.311 that opted in, a minute after its start (no person present). */
async function session($: Engine, on: Parameters<World['install']>[0], o: Opts = {}): Promise<World> {
  const w = new World({ version: { version: '2.1.311' } }).install(on)
  w.restartSetting = o.setting ?? 'on'
  w.claudeVersion = `${o.installed ?? '2.1.312'} (Claude Code)`
  w.env = o.route === 'bg'
    ? { CLAUDE_CODE_SESSION_KIND: 'bg', CLAUDE_BG_BACKEND: 'daemon', CLAUDE_JOB_DIR: JOB }
    : { [LAUNCH_ENV]: LAUNCH }
  await w.start($)
  await w.advance(61000)
  return w
}

/** A person's turn that crosses the soft max, ends with `answer` and compacts at 500 ms (a continue is due). */
async function nudgedTurn($: Engine, w: World): Promise<void> {
  await w.userTurn($)
  w.tokens = 610000
  await w.tool($)
  await w.advance(61000)
  await w.turnEnd($, 'Checkpoint: clean · Step 1: run the tests')
  await w.advance(500)
}

/** Our pending continue's turn runs and ends (so the next moment finds no submit pending). */
async function runContinue($: Engine, w: World): Promise<void> {
  const t = w.submits[w.submits.length - 1]
  if (t === undefined) return
  await w.turnStart($, t)
  await w.turnEnd($, 'ok')
}

/** The `restart` calls other than the load's claim. */
const acts = (w: World): string[] => w.restartCalls().map(c => c.args[0] ?? '').filter(x => x !== 'claim')

const carry = (w: World): Record<string, unknown> | undefined => {
  const t = w.files.get(CARRY)
  return t === undefined ? undefined : (JSON.parse(t) as Record<string, unknown>)
}
const states = (w: World): (string | undefined)[] => w.restartCalls('set').map(c => w.flag(c, '--state'))
const whys = (w: World, ev: string): unknown[] => w.rowsOf(ev).map(r => r.why)

test('AT-RS-01: versions: x.y.z from `claude --version`; newer drifts; equal, older, a dev build or other text does not', () => {
  expect(parseVersion('2.1.311 (Claude Code)')).toBe('2.1.311')
  expect(parseVersion('2.1.312-dev (Claude Code)')).toBeUndefined()
  expect(parseVersion('')).toBeUndefined()
  expect(parseVersion('Claude Code 2.1.311')).toBeUndefined()
  expect(vcmp('2.1.312', '2.1.311')).toBe(1)
  expect(vcmp('2.1.311', '2.1.311')).toBe(0)
  expect(vcmp('2.1.310', '2.1.311')).toBe(-1)
  expect(vcmp('2.2.0', '2.1.999')).toBe(1)
})

test('AT-RS-03 (G1): off: no version probe, no helper restart call, the continue as before', async ($, on) => {
  const w = await session($, on, { setting: 'off' })
  await nudgedTurn($, w)
  expect(w.callsOf('claude').length).toBe(0)
  expect(acts(w)).toEqual([])
  expect(w.submits.length).toBe(1)
  expect(w.rowsOf('refresh_start')).toEqual([])
})

test('AT-RS-03 (shadow): every gate, one refresh_would, nothing armed; the continue runs as usual', async ($, on) => {
  const w = await session($, on, { setting: 'shadow' })
  await nudgedTurn($, w)
  expect(acts(w)).toEqual(['gate'])
  expect(w.rowsOf('refresh_would')).toEqual([expect.objectContaining({ route: 'fg', from: '2.1.311', to: '2.1.312', continue: true })])
  expect(w.rowsOf('version_drift')).toEqual([expect.objectContaining({ running: '2.1.311', installed: '2.1.312' })])
  expect(w.submits.length).toBe(1)
  expect(w.uiLogs).toEqual([])
})

test('AT-RS-03 (on, fg): gate passes: armed, the transcript line, refresh_start, the continue deferred; the gate gets the launch folder, the model and the compaction start', async ($, on) => {
  const w = await session($, on)
  await nudgedTurn($, w)
  const gate = w.restartCalls('gate')[0]
  expect(w.flag(gate, '--route')).toBe('fg')
  expect(w.flag(gate, '--launch')).toBe(LAUNCH)
  expect(w.flag(gate, '--model')).toBe('claude-test-model')
  expect(Number(w.flag(gate, '--since'))).toBeLessThanOrEqual(Number(w.flag(gate, '--now-ms')))
  const arm = w.restartCalls('arm')[0]
  expect([w.flag(arm, '--continue'), w.flag(arm, '--mode'), w.flag(arm, '--effort'), w.flag(arm, '--to')]).toEqual(['1', 'acceptEdits', 'high', '2.1.312'])
  expect(w.flag(arm, '--nonce')).toMatch(/^[0-9a-f]{16}$/)
  expect(carry(w)).toMatchObject({ route: 'fg', state: 'armed', continue: true })
  expect(w.uiLogs).toEqual([expect.stringContaining('Claude Code 2.1.312 is installed; restarting this session on it in 5 s (same session). Type anything to stop.')])
  expect(w.rowsOf('refresh_start')).toEqual([expect.objectContaining({ route: 'fg', from: '2.1.311', to: '2.1.312', continue: true })])
  expect(w.submits.length).toBe(0)
  expect(w.commandRuns.filter(c => c.command === 'exit').length).toBe(0)
})

test('AT-RS-03 (helper gate fails): refresh_skipped {why, to} and the continue as usual; RS-P1 ship gate fg-not-shipped the same way', async ($, on) => {
  const w = await session($, on)
  w.restartGate = { ok: false, why: 'fg-not-shipped' }
  await nudgedTurn($, w)
  expect(w.rowsOf('refresh_skipped')).toEqual([expect.objectContaining({ why: 'fg-not-shipped', route: 'fg', to: '2.1.312' })])
  expect(w.restartCalls('arm').length).toBe(0)
  expect(w.submits.length).toBe(1)
})

test('AT-RS-03 (G7 from the helper): background-work names the task types, never more', async ($, on) => {
  const w = await session($, on)
  w.restartGate = { ok: false, why: 'background-work', types: ['shell', 'monitor'] }
  await nudgedTurn($, w)
  expect(w.rowsOf('refresh_skipped')[0]).toMatchObject({ why: 'background-work', types: ['shell', 'monitor'] })
})

const LIVE: { why: string; name: string; set: (w: World) => void }[] = [
  { why: 'draft', name: 'a draft in the prompt box', set: w => { w.draft = 'half a prompt' } },
  { why: 'remote', name: 'a remote surface', set: w => { w.surfaceList = ['terminal', 'mobile'] } },
  { why: 'remote', name: 'surfaces unreadable', set: w => { w.surfaceList = undefined } },
  { why: 'agents', name: 'a running agent', set: w => { w.agents = [{ id: 'a1', status: 'running' }] } },
]
for (const c of LIVE) {
  test(`AT-RS-03 (in memory): ${c.name} skips ${c.why} before the helper gate; the continue as usual`, async ($, on) => {
    const w = await session($, on)
    c.set(w)
    await nudgedTurn($, w)
    expect(whys(w, 'refresh_skipped')).toEqual([c.why])
    expect(acts(w)).toEqual([])
    expect(w.submits.length).toBe(1)
  })
}

test('AT-RS-03 (G1): the setting lowered to shadow since the load: the gate\'s reading wins (refresh_would, nothing armed)', async ($, on) => {
  const w = await session($, on)
  // ident said `on` at the load; the gate reads the settings file again and finds `shadow`.
  w.restartGate = { setting: 'shadow' }
  await nudgedTurn($, w)
  expect(acts(w)).toEqual(['gate'])
  expect(w.rowsOf('refresh_would')).toEqual([expect.objectContaining({ route: 'fg', from: '2.1.311', to: '2.1.312' })])
  expect([w.rowsOf('refresh_start').length, w.uiLogs.length, w.submits.length]).toEqual([0, 0, 1])
  await w.advance(RESTART_GRACE_MS + EXIT_WINDOW_MS)
  expect(w.commandRuns.filter(c => c.command === 'exit').length).toBe(0)
})

test('AT-RS-03 (G11): the resume block not on disk: block-not-saved before the helper gate, the continue as usual', async ($, on) => {
  const w = await session($, on)
  w.writeDeny = p => p.endsWith('/resume-pending.json')
  await nudgedTurn($, w)
  expect(whys(w, 'refresh_skipped')).toEqual(['block-not-saved'])
  expect(acts(w)).toEqual([])
  expect(w.submits.length).toBe(1)
})

test('AT-RS-03 (G3a, mod part): a model that starts with - is note-pattern before the gate (the launcher would refuse it)', async ($, on) => {
  const w = await session($, on)
  w.model = '-x'
  await nudgedTurn($, w)
  expect(whys(w, 'refresh_skipped')).toEqual(['note-pattern'])
  expect(acts(w)).toEqual([])
})

/** Claude Code's own idle compaction 26 min after a turn that ended with `answer` (the D2b moment). */
async function idleMoment($: Engine, w: World, answer = 'Done with that step.', reason: 'answer' | 'aborted' = 'answer', kind = 'composer'): Promise<void> {
  await w.userTurn($, 'next step please', kind)
  w.tokens = 300000
  await w.turnEnd($, answer, reason)
  await w.advance(26 * 60000)
  await raiseCompact(w.engine as never, { trigger: 'auto' })
}

const G6: { why: string; name: string; before?: (w: World) => void; answer?: string; reason?: 'aborted'; kind?: string }[] = [
  { why: 'aborted', name: 'the last turn aborted', reason: 'aborted' },
  { why: 'asks-user', name: 'the last turn asks the user', answer: 'Should I run the migration now?' },
  // A task's turn (a person's prompt would clear halt, IC-1 D6).
  { why: 'halted', name: 'halt mode on', kind: 'task-notification', before: w => { w.files.set(`${WATCH}/${SID_A}/halt.json`, JSON.stringify({ active: true, reason: 'thrash' })) } },
  { why: 'headless', name: 'a headless load (G2)', before: w => { w.interactive = false } },
]
for (const c of G6) {
  test(`AT-RS-03 (in memory): ${c.name} skips ${c.why} before the helper gate`, async ($, on) => {
    const w = new World({ version: { version: '2.1.311' } }).install(on)
    w.restartSetting = 'on'
    w.claudeVersion = '2.1.312 (Claude Code)'
    w.env = { [LAUNCH_ENV]: LAUNCH }
    c.before?.(w)
    await w.start($)
    await w.advance(61000)
    await idleMoment($, w, c.answer, c.reason, c.kind)
    expect(whys(w, 'refresh_skipped')).toEqual([c.why])
    expect(acts(w)).toEqual([])
  })
}

test('AT-RS-03 (G6 busy, at the grace): a compaction running when the grace ends: busy, cancelled, the continue once', async ($, on) => {
  const w = await session($, on)
  await nudgedTurn($, w)
  w.compactGate = new Promise(() => undefined)
  raiseCompact(w.engine as never, { trigger: 'manual' }).catch(() => undefined)
  await w.settle()
  await w.advance(RESTART_GRACE_MS)
  expect(whys(w, 'refresh_skipped')).toEqual(['busy'])
  expect(states(w)).toEqual(['cancelled'])
  expect(w.commandRuns.filter(c => c.command === 'exit').length).toBe(0)
})

for (const why of ['mode-changed', 'mode-unknown', 'bypass-not-available']) {
  test(`AT-RS-19 (mod part): the gate's ${why}: one refresh_skipped row, nothing armed, the continue as usual`, async ($, on) => {
    const w = await session($, on)
    w.restartGate = { ok: false, why }
    await nudgedTurn($, w)
    expect([whys(w, 'refresh_skipped'), w.restartCalls('arm').length, w.submits.length]).toEqual([[why], 0, 1])
  })
}

test('AT-RS-19 (mod part): the note\'s mode and effort are the gate\'s fresh values', async ($, on) => {
  const w = await session($, on)
  w.restartGate = { mode: 'plan', effort: 'max' }
  await nudgedTurn($, w)
  const arm = w.restartCalls('arm')[0]
  expect([w.flag(arm, '--mode'), w.flag(arm, '--effort')]).toEqual(['plan', 'max'])
})

test('AT-RS-03 (G8 present): a keystroke in the last minute skips present', async ($, on) => {
  const w = await session($, on)
  await w.userTurn($)
  w.tokens = 610000
  await w.tool($)
  await w.edit($)
  await w.turnEnd($, 'Checkpoint: clean · Step 1: run the tests')
  await w.advance(500)
  expect(whys(w, 'refresh_skipped')).toEqual(['present'])
})

test('AT-RS-02, AT-RS-04: the version probe runs at most once per 30 min; a failed probe is version-unknown once; skips log once per (why, to)', async ($, on) => {
  const w = await session($, on)
  w.claudeVersion = 'reject'
  w.draft = 'x'
  await nudgedTurn($, w)
  await runContinue($, w)
  await nudgedTurn($, w)
  await runContinue($, w)
  expect(w.callsOf('claude').length).toBe(1)
  expect(whys(w, 'refresh_skipped')).toEqual(['version-unknown'])
  w.claudeVersion = '2.1.312 (Claude Code)'
  await w.advance(DRIFT_TTL_MS)
  await nudgedTurn($, w)
  await runContinue($, w)
  await nudgedTurn($, w)
  expect(w.callsOf('claude').length).toBe(2)
  expect(whys(w, 'refresh_skipped')).toEqual(['version-unknown', 'draft'])
  expect(acts(w)).toEqual([])
})

for (const inst of ['2.1.311', '2.1.310', '2.1.312-dev']) {
  test(`AT-RS-01 (no drift): installed ${inst}: no row at all, no gate`, async ($, on) => {
    const w = await session($, on, { installed: inst })
    await nudgedTurn($, w)
    expect([w.rowsOf('version_drift').length, w.rowsOf('refresh_skipped').length, acts(w)]).toEqual([0, 0, []])
    expect(w.submits.length).toBe(1)
  })
}

test('AT-RS-05: after the 5 s grace the plugin sends /exit; our hook sees it fresh and sets both notes exiting', async ($, on) => {
  const w = await session($, on)
  w.exitGate = new Promise(() => undefined)
  await nudgedTurn($, w)
  await w.advance(RESTART_GRACE_MS - 1)
  expect(w.commandRuns.filter(c => c.command === 'exit').length).toBe(0)
  await w.advance(1)
  expect(states(w)).toEqual(['exiting'])
  expect(w.commandRuns.filter(c => c.command === 'exit').map(c => c.origin)).toEqual([expect.objectContaining({ kind: 'plugin' })])
  const set = w.restartCalls('set')[0]
  expect(w.flag(set, '--launch')).toBe(LAUNCH)
  expect(w.flag(set, '--exiting-at')).toMatch(/^[0-9]+$/)
  expect(carry(w)).toMatchObject({ state: 'exiting' })
})

test('AT-RS-05: a draft typed during the grace: cancelled, refresh_skipped draft, the continue once', async ($, on) => {
  const w = await session($, on)
  await nudgedTurn($, w)
  w.draft = 'wait'
  await w.advance(RESTART_GRACE_MS)
  expect(states(w)).toEqual(['cancelled'])
  expect(whys(w, 'refresh_skipped')).toEqual(['draft'])
  expect(w.submits.length).toBe(1)
  expect(w.commandRuns.filter(c => c.command === 'exit').length).toBe(0)
})

test('AT-RS-05: a prompt entering during the grace stops it at once; no continue (the person took over)', async ($, on) => {
  const w = await session($, on)
  await nudgedTurn($, w)
  await w.userTurn($, 'actually, one more thing')
  expect(states(w)).toEqual(['cancelled'])
  expect(whys(w, 'refresh_skipped')).toEqual(['busy'])
  await w.advance(RESTART_GRACE_MS)
  expect(w.commandRuns.filter(c => c.command === 'exit').length).toBe(0)
  expect(w.submits.length).toBe(0)
})

test('AT-RS-06: our own /exit seen by our hook: passed on while fresh; vetoed with our text once the window passed', async ($, on) => {
  const w = await session($, on)
  w.exitGate = new Promise(() => undefined)
  await nudgedTurn($, w)
  await w.advance(RESTART_GRACE_MS)
  const run = (e: unknown) => (w.engine as unknown as { command: { run: (e: unknown) => Promise<{ text?: string }> } }).command.run(e)
  // Held open below (exitGate), as a real /exit that ends the process never resolves.
  run({ command: 'exit', args: '', origin: { kind: 'plugin', name: w.name } }).catch(() => undefined)
  await w.settle()
  expect(w.commandRuns.filter(c => c.command === 'exit').length).toBeGreaterThanOrEqual(1)
  const n = w.commandRuns.length
  await w.advance(EXIT_WINDOW_MS)
  const r = await run({ command: 'exit', args: '', origin: { kind: 'plugin', name: w.name } })
  expect(r.text).toContain('restart cancelled; this session stays open.')
  expect(w.commandRuns.length).toBe(n)
})

test('AT-RS-06: own /exit with no armed restart: our answer text, no command runs; quit the same', async ($, on) => {
  const w = await session($, on)
  for (const command of ['exit', 'quit']) {
    const r = await (w.engine as unknown as { command: { run: (e: unknown) => Promise<{ text?: string }> } }).command.run({ command, args: '', origin: { kind: 'plugin', name: w.name } })
    expect(r.text).toContain('restart cancelled; this session stays open.')
  }
  expect(w.commandRuns.length).toBe(0)
  expect(whys(w, 'refresh_skipped')).toEqual(['stale-exit', 'stale-exit'])
})

test('AT-RS-06: a /exit typed while armed: both notes cancelled, the command runs; nothing relaunches', async ($, on) => {
  const w = await session($, on)
  await nudgedTurn($, w)
  await (w.engine as unknown as { command: { run: (e: unknown) => Promise<unknown> } }).command.run({ command: 'exit', args: '', origin: { kind: 'composer' } })
  expect(w.commandRuns.map(c => c.command)).toEqual(['exit'])
  expect(states(w)).toEqual(['cancelled'])
  await w.advance(RESTART_GRACE_MS)
  expect(w.commandRuns.length).toBe(1)
})

test('AT-RS-07: session.end prompt_input_exit within 5 s of exiting: the go write is the first helper call, with exiting_at', async ($, on) => {
  const w = await session($, on)
  w.exitGate = new Promise(() => undefined)
  await nudgedTurn($, w)
  await w.advance(RESTART_GRACE_MS)
  await w.advance(1000)
  const before = w.calls.length
  await $.session.end(EXIT as never)
  const after = w.calls.slice(before)
  expect(after[0]?.sub).toBe('restart')
  expect(after[0]?.args[0]).toBe('set')
  expect(w.flag(after[0], '--state')).toBe('go')
  expect(w.flag(after[0], '--exiting-at')).toBe(w.flag(w.restartCalls('set')[0], '--exiting-at'))
  expect(carry(w)).toMatchObject({ state: 'go' })
  // The persisted block is kept for the resume (not settled as dropped).
  expect(w.rowsOf('mod_outcome').map(r => r.resume)).not.toContain('dropped:session-end')
})

for (const [wait, reason] of [[EXIT_WINDOW_MS + 1000, 'prompt_input_exit'], [1000, 'other']] as const) {
  test(`AT-RS-07: an end ${reason} ${wait} ms after exiting relaunches nothing (both notes cancelled)`, async ($, on) => {
    const w = await session($, on)
    w.exitGate = new Promise(() => undefined)
    await nudgedTurn($, w)
    await w.advance(RESTART_GRACE_MS)
    await w.advance(wait)
    await $.session.end({ ...EXIT, reason } as never)
    expect(states(w)).toEqual(['exiting', 'cancelled'])
  })
}

test('AT-RS-08: still alive 5 s after exiting: both notes cancelled first, then exit-not-run and the continue once', async ($, on) => {
  const w = await session($, on)
  w.exitGate = new Promise(() => undefined)
  await nudgedTurn($, w)
  await w.advance(RESTART_GRACE_MS)
  await w.advance(EXIT_WINDOW_MS)
  expect(states(w)).toEqual(['exiting', 'cancelled'])
  expect(w.rowsOf('refresh_failed')).toEqual([expect.objectContaining({ route: 'fg', why: 'exit-not-run', to: '2.1.312' })])
  expect(w.submits.length).toBe(1)
  expect(w.storeGet(`cont:${SID_A}`)).toHaveLength(1)
})

test('AT-RS-08: an end that began stands the watchdog down', async ($, on) => {
  const w = await session($, on)
  w.exitGate = new Promise(() => undefined)
  await nudgedTurn($, w)
  await w.advance(RESTART_GRACE_MS)
  await $.session.end(EXIT as never)
  await w.advance(EXIT_WINDOW_MS)
  expect(w.rowsOf('refresh_failed')).toEqual([])
  expect(w.submits.length).toBe(0)
})

/** The fake helper's `restart` replies with the `set` reply of `state` changed by `patch`. */
function setReplyFor(w: World, state: string, patch: Record<string, unknown> | 'reject'): void {
  w.replies.restart = args => {
    const r = w.restartReply(args, SID_A)
    const i = args.indexOf('--state')
    if (args[0] !== 'set' || args[i + 1] !== state) return { exitCode: 0, stdout: JSON.stringify(r) + '\n' }
    return patch === 'reject' ? 'reject' : { exitCode: 0, stdout: JSON.stringify({ ...r, ...patch }) + '\n' }
  }
}

test('AT-RS-07: the helper wrote no go (the launch note gone, another nonce\'s, ended): nothing written over it, one refresh_failed row', async ($, on) => {
  const w = await session($, on)
  w.exitGate = new Promise(() => undefined)
  await nudgedTurn($, w)
  await w.advance(RESTART_GRACE_MS)
  setReplyFor(w, 'go', { l: 'mismatch' })
  await $.session.end(EXIT as never)
  expect(w.files.has(`${LAUNCH}/restart.note`)).toBe(false)
  expect(w.rowsOf('refresh_failed')).toEqual([expect.objectContaining({ route: 'fg', why: 'helper-failed', code: 'launch-mismatch' })])
})

test('AT-RS-07: the go call fails: the mod writes the launch note itself; at - floor(exiting_at / 1000) within the launcher\'s 0 to 5', async ($, on) => {
  const w = await session($, on)
  w.exitGate = new Promise(() => undefined)
  await nudgedTurn($, w)
  await w.advance(RESTART_GRACE_MS)
  await w.advance(EXIT_WINDOW_MS - 1)
  setReplyFor(w, 'go', 'reject')
  await $.session.end(EXIT as never)
  const note = w.files.get(`${LAUNCH}/restart.note`) ?? ''
  const v = Object.fromEntries(note.trim().split('\n').map(l => l.split('=') as [string, string]))
  expect(v.state).toBe('go')
  const gap = Number(v.at) - Math.floor(Number(v.exiting_at) / 1000)
  expect(gap >= 0 && gap <= 5).toBe(true)
  expect(w.rowsOf('refresh_failed')).toEqual([])
})

test('AT-RS-12: after a restart the block arrives once, at prompt.context of the continue\'s turn; the continue is the bare line', async ($, on) => {
  const w = new World({ version: { version: '2.1.312' } })
  const p: PendingResume = {
    sid: SID_A, nonce: 'ab0c0001', block: 'STORED BLOCK', builtAt: T0 - 20000, measuredAt: T0 - 20000, resumePref: 'prompt.context', turnSeq: 3,
    args: { nonce: 'ab0c0001', midturn: false, nonok: false, savedCopy: null, prodAllow: false },
    remeasure: 'Git: main @ 1a1a1a1, 0 modified, 0 untracked', outcome: { nudged: true, continued: false, halt: false },
  }
  // As the classic SessionStart(resume) leaves it: the old load's record, armed.
  w.files.set(`${WATCH}/${SID_A}/${ARMED_FILE}`, JSON.stringify(pendingRecord(p, 'f0e1d2c3')) + '\n')
  w.install(on)
  w.restartSetting = 'on'
  w.env = { [LAUNCH_ENV]: LAUNCH }
  w.files.set(CARRY, JSON.stringify({ v: 1, route: 'fg', state: 'go', sid: SID_A }) + '\n')
  w.restartClaimReply = { claimed: true, why: null, route: 'fg', from: '2.1.311', to: '2.1.312', continue: true, at: 1 }
  await w.start($)
  await w.advance(2000)
  expect(w.submits).toEqual([continueLine(w.name)])
  await w.turnStart($, w.submits[0])
  const ctx = await $.prompt.context({ blocks: [] })
  expect(ctx.blocks.filter(b => b.name === `${w.name}-resume`).length).toBe(1)
  expect(w.rowsOf('mod_outcome').map(r => r.resume)).toEqual(['delivered:prompt.context'])
  const again = await $.prompt.context({ blocks: [] })
  expect(again.blocks.length).toBe(0)
  expect(w.rowsOf('mod_outcome').length).toBe(1)
})

test('AT-RS-09: $.command.run rejects: exit-refused, cancelled, the continue', async ($, on) => {
  const w = await session($, on)
  await nudgedTurn($, w)
  w.commandMode = 'reject'
  await w.advance(RESTART_GRACE_MS)
  expect(whys(w, 'refresh_failed')).toEqual(['exit-refused'])
  expect(states(w)).toContain('cancelled')
  expect(w.submits.length).toBe(1)
})

test('AT-RS-08: a hook above swallows our /exit: exit-not-run after the window and the continue', async ($, on) => {
  const w = await session($, on)
  await nudgedTurn($, w)
  w.commandMode = { text: 'swallowed' }
  await w.advance(RESTART_GRACE_MS)
  await w.advance(EXIT_WINDOW_MS)
  expect(whys(w, 'refresh_failed')).toEqual(['exit-not-run'])
  expect(w.submits.length).toBe(1)
})

test('AT-RS-13: bg route: the grace, then one respawn helper call (never an /exit); a refusal while alive: respawn-refused with the code and the continue', async ($, on) => {
  const w = await session($, on, { route: 'bg' })
  await nudgedTurn($, w)
  const gate = w.restartCalls('gate')[0]
  expect([w.flag(gate, '--route'), w.flag(gate, '--job-dir')]).toEqual(['bg', JOB])
  expect(w.uiLogs[0]).toContain('restarting this background session on it in 5 s')
  await w.advance(RESTART_GRACE_MS)
  const r = w.restartCalls('respawn')
  expect(r.length).toBe(1)
  expect([w.flag(r[0], '--short'), w.flag(r[0], '--to')]).toEqual(['job1', '2.1.312'])
  expect(w.commandRuns.length).toBe(0)
  const nonce = w.flag(r[0], '--nonce')
  w.files.set(`${WATCH}/${SID_A}/restart-respawn.json`, JSON.stringify({ nonce, rc: 1, code: 'job_respawn_kill_unconfirmed', at: 1 }) + '\n')
  await w.advance(2000)
  expect(w.rowsOf('refresh_failed')).toEqual([expect.objectContaining({ route: 'bg', why: 'respawn-refused', code: 'job_respawn_kill_unconfirmed' })])
  expect(states(w)).toEqual(['failed'])
  expect(w.submits.length).toBe(1)
})

test('AT-RS-13: bg: alive 60 s after the start with no result: respawn-cancel first, then not-respawned and the continue', async ($, on) => {
  const w = await session($, on, { route: 'bg' })
  await nudgedTurn($, w)
  await w.advance(RESTART_GRACE_MS)
  await w.advance(RESPAWN_WATCH_MS)
  const subs = w.restartCalls().map(c => c.args[0])
  expect(subs.slice(-2)).toEqual(['respawn-cancel', 'set'])
  expect(whys(w, 'refresh_failed')).toEqual(['not-respawned'])
  expect(w.submits.length).toBe(1)
})

test('AT-RS-13: bg: a prompt during the wait: respawn-cancel before anything else, the note cancelled, no continue', async ($, on) => {
  const w = await session($, on, { route: 'bg' })
  await nudgedTurn($, w)
  await w.advance(RESTART_GRACE_MS)
  const n = w.calls.length
  await w.userTurn($, 'stop that')
  const next = w.calls.slice(n).filter(c => c.sub === 'restart').map(c => c.args[0])
  expect(next).toEqual(['respawn-cancel', 'set'])
  expect(states(w)).toEqual(['cancelled'])
  expect(w.submits.length).toBe(0)
})

test('AT-RS-13: bg: the respawn call fails or runs out of time: respawn-cancel first (the note failed), then respawn-refused and the continue once', async ($, on) => {
  const w = await session($, on, { route: 'bg' })
  w.replies.restart = args => (args[0] === 'respawn' ? 'reject' : { exitCode: 0, stdout: JSON.stringify(w.restartReply(args, SID_A)) + '\n' })
  await nudgedTurn($, w)
  await w.advance(RESTART_GRACE_MS)
  expect(acts(w).slice(-3)).toEqual(['respawn', 'respawn-cancel', 'set'])
  expect(w.flag(w.restartCalls('respawn-cancel')[0], '--state')).toBe('failed')
  expect(carry(w)).toMatchObject({ state: 'failed' })
  expect(w.rowsOf('refresh_failed')).toEqual([expect.objectContaining({ route: 'bg', why: 'respawn-refused', code: 'other' })])
  expect(w.submits.length).toBe(1)
  await w.advance(RESPAWN_WATCH_MS)
  expect([w.rowsOf('refresh_failed').length, w.submits.length]).toEqual([1, 1])
})

test('AT-RS-13: bg: the respawn passes the job folder and the fresh mode (the helper reads respawnFlags again); its bypass-left is a skip, not a retry', async ($, on) => {
  const w = await session($, on, { route: 'bg' })
  w.restartRespawn = { ok: false, why: 'bypass-left' }
  await nudgedTurn($, w)
  await w.advance(RESTART_GRACE_MS)
  const r = w.restartCalls('respawn')[0]
  expect([w.flag(r, '--job-dir'), w.flag(r, '--mode')]).toEqual([JOB, 'acceptEdits'])
  expect(acts(w).slice(-3)).toEqual(['respawn', 'respawn-cancel', 'set'])
  expect(whys(w, 'refresh_skipped')).toEqual(['bypass-left'])
  expect(w.rowsOf('refresh_failed')).toEqual([])
  expect(w.storeGet(`restart_tried:${SID_A}`)).toMatchObject({ targets: { '2.1.312': { n: 1, why: 'bypass-left' } } })
  expect(w.submits.length).toBe(1)
})

test('AT-RS-13: bg: a prompt while the respawn call runs: respawn-cancel at once and again when the call returns; no watchdog, no continue', async ($, on) => {
  const w = await session($, on, { route: 'bg' })
  await nudgedTurn($, w)
  let fired = false
  w.atHelper = async (sub, args) => {
    if (sub !== 'restart' || args[0] !== 'respawn' || fired) return
    fired = true
    await w.userTurn($, 'wait, one more thing')
  }
  await w.advance(RESTART_GRACE_MS)
  expect(fired).toBe(true)
  // Recorded in the order the calls reached the helper: the prompt's cancel (the note first,
  // then the kill) while the respawn call was on its way, then the cancel once it returned.
  expect(acts(w).slice(-4)).toEqual(['respawn-cancel', 'set', 'respawn', 'respawn-cancel'])
  expect(w.restartCalls('respawn-cancel').map(c => w.flag(c, '--state'))).toEqual(['cancelled', 'cancelled'])
  expect(whys(w, 'refresh_skipped')).toEqual(['busy'])
  await w.advance(RESPAWN_WATCH_MS)
  expect([w.rowsOf('refresh_failed').length, w.submits.length, w.restartCalls('respawn-cancel').length]).toEqual([0, 0, 2])
})

test('AT-RS-13: bg: a prompt while a failed respawn is being cancelled: the person\'s turn wins (busy); no refresh_failed, no continue', async ($, on) => {
  const w = await session($, on, { route: 'bg' })
  w.replies.restart = args => (args[0] === 'respawn' ? 'reject' : { exitCode: 0, stdout: JSON.stringify(w.restartReply(args, SID_A)) + '\n' })
  await nudgedTurn($, w)
  let fired = false
  w.atHelper = async (sub, args) => {
    if (sub !== 'restart' || args[0] !== 'respawn-cancel' || fired) return
    fired = true
    await w.userTurn($, 'hold on')
  }
  await w.advance(RESTART_GRACE_MS)
  expect(fired).toBe(true)
  expect(whys(w, 'refresh_skipped')).toEqual(['busy'])
  expect([w.rowsOf('refresh_failed').length, w.submits.length]).toEqual([0, 0])
})

test('AT-RS-15: an idle restart that fails runs no continue, even with a nudge left from a compaction that failed', async ($, on) => {
  const w = await session($, on)
  w.compactMode = 'reject'
  await nudgedTurn($, w)
  expect(w.submits.length).toBe(0)
  w.compactMode = 'ok'
  await w.advance(26 * 60000)
  await raiseCompact(w.engine as never, { trigger: 'auto' })
  expect(w.flag(w.restartCalls('arm')[0], '--continue')).toBe('0')
  w.draft = 'x'
  await w.advance(RESTART_GRACE_MS)
  expect(whys(w, 'refresh_skipped')).toEqual(['draft'])
  expect(w.submits.length).toBe(0)
})

test('AT-RS-05: the launch note not written at exiting (gone, another nonce\'s, ended): no /exit, refresh_failed helper-failed, the continue', async ($, on) => {
  const w = await session($, on)
  await nudgedTurn($, w)
  setReplyFor(w, 'exiting', { l: 'absent' })
  await w.advance(RESTART_GRACE_MS)
  expect(w.commandRuns.filter(c => c.command === 'exit').length).toBe(0)
  expect(w.rowsOf('refresh_failed')).toEqual([expect.objectContaining({ route: 'fg', why: 'helper-failed', code: 'launch-absent' })])
  expect(states(w)).toEqual(['exiting', 'cancelled'])
  expect(w.submits.length).toBe(1)
})

test('AT-RS-14 (mod part): bg: a client attached in this load: attached', async ($, on) => {
  const w = await session($, on, { route: 'bg' })
  await (w.engine as unknown as { session: { attach: (e: unknown) => Promise<unknown> } }).session.attach({ surface: 'mobile', clientId: 'mobile:1' })
  await nudgedTurn($, w)
  expect(whys(w, 'refresh_skipped')).toEqual(['attached'])
})

test('AT-RS-14 (mod part): bg: a surface besides the terminal: attached', async ($, on) => {
  const w = await session($, on, { route: 'bg' })
  w.surfaceList = ['terminal', 'desktop']
  await nudgedTurn($, w)
  expect(whys(w, 'refresh_skipped')).toEqual(['attached'])
})

test('AT-RS-14 (mod part): bg without the daemon backend or a job folder: job-unknown', async ($, on) => {
  const w = await session($, on, { route: 'bg' })
  w.env = { CLAUDE_CODE_SESSION_KIND: 'bg' }
  await nudgedTurn($, w)
  expect(whys(w, 'refresh_skipped')).toEqual(['job-unknown'])
})

test('AT-RS-15: a restart after Claude Code\'s own idle compaction carries no continue', async ($, on) => {
  const w = await session($, on)
  await w.userTurn($)
  w.tokens = 300000
  await w.turnEnd($)
  await w.advance(26 * 60000)
  await raiseCompact(w.engine as never, { trigger: 'auto' })
  const arm = w.restartCalls('arm')[0]
  expect(w.flag(arm, '--continue')).toBe('0')
  expect(w.rowsOf('refresh_start')[0]).toMatchObject({ continue: false })
})

const BLOCKS: [string, string][] = [['permissions', 'session-rules'], ['add-dir', 'session-dirs'], ['sandbox', 'session-rules'], ['remote-control', 'remote'], ['EnterWorktree', 'worktree']]
for (const [cmd, why] of BLOCKS) {
  test(`AT-RS-16: ${cmd} blocks the rest of the load (${why})`, async ($, on) => {
    const w = await session($, on)
    if (cmd === 'EnterWorktree') await (w.engine as unknown as { tool: { call: (e: unknown) => Promise<unknown> } }).tool.call({ tool: 'EnterWorktree' })
    else await (w.engine as unknown as { command: { run: (e: unknown) => Promise<unknown> } }).command.run({ command: cmd, args: '', origin: { kind: 'composer' } })
    await nudgedTurn($, w)
    expect(whys(w, 'refresh_skipped')).toEqual([why])
  })
}

test('AT-RS-03 (G13): a target tried and cancelled is not tried again in the session; the cooldown holds 10 min', async ($, on) => {
  const w = await session($, on)
  await nudgedTurn($, w)
  w.draft = 'x'
  await w.advance(RESTART_GRACE_MS)
  w.draft = ''
  await runContinue($, w)
  await w.advance(11 * 60000)
  await nudgedTurn($, w)
  expect(whys(w, 'refresh_skipped')).toEqual(['draft', 'tried'])
})

test('AT-RS-03 (G13): an attempt in the last 10 minutes: cooldown; two in 24 h: cap', async ($, on) => {
  const w = await session($, on)
  w.storeSet(`restart_tried:${SID_A}`, { targets: {}, attempts: [w.clock.now()], last: w.clock.now() })
  await nudgedTurn($, w)
  await runContinue($, w)
  w.storeSet(`restart_tried:${SID_A}`, { targets: {}, attempts: [w.clock.now() - 3600000, w.clock.now() - 1800000], last: w.clock.now() - 1800000 })
  await nudgedTurn($, w)
  expect(whys(w, 'refresh_skipped')).toEqual(['cooldown', 'cap'])
})

for (const person of [false, true]) {
  test(`AT-RS-10: the new load claims the note: refresh_done, the transcript line; ${person ? 'a person first: no continue' : 'the continue 2 s later'}`, async ($, on) => {
    const w = new World({ version: { version: '2.1.312' } }).install(on)
    w.restartSetting = 'on'
    w.env = { [LAUNCH_ENV]: LAUNCH }
    w.files.set(CARRY, JSON.stringify({ v: 1, route: 'fg', state: 'go', sid: SID_A }) + '\n')
    w.restartClaimReply = { claimed: true, why: null, route: 'fg', from: '2.1.311', to: '2.1.312', continue: true, at: 1 }
    await w.start($)
    const claim = w.restartCalls('claim')[0]
    expect([w.flag(claim, '--launch'), w.flag(claim, '--load-id') !== undefined]).toEqual([LAUNCH, true])
    expect(w.rowsOf('refresh_done')).toEqual([expect.objectContaining({ route: 'fg', from: '2.1.311', to: '2.1.312' })])
    expect(w.uiLogs).toEqual([expect.stringContaining('this session restarted on Claude Code 2.1.312 (was 2.1.311); same session.')])
    if (person) await w.userTurn($, 'hello again')
    await w.advance(2000)
    expect(w.submits).toEqual(person ? [] : [continueLine(w.name)])
    expect(w.rowsOf('continue').filter(r => r.after === 'restart').length).toBe(person ? 0 : 1)
  })
}

test('AT-RS-10: no carry note and no launcher: no claim call', async ($, on) => {
  const w = new World({ version: { version: '2.1.312' } }).install(on)
  w.restartSetting = 'on'
  await w.start($)
  expect(w.restartCalls().length).toBe(0)
})

test('AT-RS-10: a note that is not claimed changes nothing', async ($, on) => {
  const v = new World({ version: { version: '2.1.312' } }).install(on)
  v.files.set(CARRY, '{}\n')
  v.restartClaimReply = { why: 'no-proof' }
  await v.start($)
  expect(v.restartCalls('claim').length).toBe(1)
  expect([v.rowsOf('refresh_done').length, v.rowsOf('refresh_failed').length, v.uiLogs.length]).toEqual([0, 0, 0])
})

test('AT-RS-11: the new load still on the old version: refresh_failed same-version, the target never tried again', async ($, on) => {
  const w = new World({ version: { version: '2.1.311' } }).install(on)
  w.files.set(CARRY, '{}\n')
  w.restartClaimReply = { claimed: true, why: null, route: 'bg', from: '2.1.311', to: '2.1.312', continue: true, at: 1 }
  await w.start($)
  expect(w.rowsOf('refresh_failed')).toEqual([expect.objectContaining({ route: 'bg', why: 'same-version', to: '2.1.312' })])
  expect(w.storeGet(`restart_tried:${SID_A}`)).toMatchObject({ targets: { '2.1.312': { n: 2, why: 'same-version' } } })
  await w.advance(2000)
  expect(w.submits).toEqual([])
})

test('AT-RS-10: not-confirmed and launcher refusals become refresh_failed rows; failed background restarts one transcript line each', async ($, on) => {
  const w = new World({ version: { version: '2.1.311' } }).install(on)
  w.restartSetting = 'on'
  w.restartReports = [{ short: 'job7', to: '2.1.312', code: 'cwd_gone' }]
  w.env = { [LAUNCH_ENV]: LAUNCH }
  w.restartClaimReply = { why: 'not-confirmed', route: 'fg', from: '2.1.311', to: '2.1.312', refused: [{ reason: 'launch-file', at: 1 }] }
  await w.start($)
  expect(w.rowsOf('refresh_failed').map(r => [r.why, r.code ?? null])).toEqual([['launcher-refused', 'launch-file'], ['not-confirmed', null]])
  expect(w.uiLogs).toEqual([expect.stringContaining('a background session (job7) did not come back after a restart on Claude Code 2.1.312')])
})

test('AT-RS-17: the texts the model reads name no claude command, no --resume and no launcher', () => {
  const t = continueLine('x')
  expect(t).not.toMatch(/claude |--resume|-claude\b|respawn/)
})

test('AT-RS-18: refresh rows are content-free: no path, no model string, no argv', async ($, on) => {
  const w = await session($, on)
  w.exitGate = new Promise(() => undefined)
  await nudgedTurn($, w)
  await w.advance(RESTART_GRACE_MS + EXIT_WINDOW_MS)
  const rows = w.rows.filter(r => /^(refresh_|version_drift)/.test(r.ev))
  expect(rows.length).toBeGreaterThan(0)
  for (const r of rows) {
    const text = JSON.stringify({ ...r, sid: null, ts: null })
    expect([r.ev, /\/|claude-test-model|--/.test(text)]).toEqual([r.ev, false])
  }
})

test('the fallback launch note is the launcher\'s protocol 1 form: 12 keys, at in seconds, exiting_at in ms', () => {
  const run: RestartRun = {
    sid: SID_A, route: 'fg', nonce: '0123456789abcdef', from: '2.1.311', to: '2.1.312', cont: true, contDue: true, armedAt: 1, phase: 'exiting',
    token: 'fedcba9876543210', mode: 'default', effort: 'high', model: 'opus', exitingAt: 1792580712345,
  }
  expect(launchNote(run, 'go', 1792580714999)).toBe([
    'proto=1', 'state=go', 'token=fedcba9876543210', `sid=${SID_A}`, 'nonce=0123456789abcdef', 'at=1792580714',
    'exiting_at=1792580712345', 'from=2.1.311', 'to=2.1.312', 'model=opus', 'effort=high', 'mode=default',
  ].join('\n') + '\n')
})
