// U tests through the kit: session lifecycle, liveness, canaries, resume delivery, the seat
// simulation and the fs trace (MOD-SPEC §3.3, §3.4, §5.6, §7, §10).
import { shippedNotice } from '../../hooks/lib/notice'
import type { On, Register } from 'claude-code'
import type { Engine } from 'claude-code/testing'
import { expect, test } from 'claude-code/testing'
import { AGENT, HOME, ROOT, SID_A, SID_B, WATCH, World, markerNonce, raiseCompact } from './harness.test'

test('AT-M1-16: mod-alive.json under sid A at session.start and under sid B at a main turn.start after /clear', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  const a = JSON.parse(w.files.get(`${WATCH}/${SID_A}/mod-alive.json`) ?? '{}') as Record<string, unknown>
  expect(a.pid).toBe(43210)
  expect(a.pid_lstart).toBe('Tue Oct 21 14:00:00 2026')
  expect(typeof a.load_id).toBe('string')
  expect(a.turn_id).toBeNull()
  w.sid = SID_B
  await w.turnStart($)
  const b = JSON.parse(w.files.get(`${WATCH}/${SID_B}/mod-alive.json`) ?? '{}') as Record<string, unknown>
  expect(b.turn_id).toBe('t1')
  expect(b.load_id).toBe(a.load_id)
  expect(w.callsOf('ident').length).toBe(1)
})

test('session.start rows: policy flags and the session row', async ($, on) => {
  const w = new World().install(on)
  w.policy = { allowManagedModsOnly: true }
  await w.start($)
  expect(w.rowsOf('policy')[0]).toMatchObject({ mods_managed_only: true, hooks_managed_only: false, writer: 'mod', sid: SID_A, pid: 43210, v: 1 })
  expect(w.rowsOf('session')[0]).toMatchObject({ phase: 'start', mod_loaded: true, pid_lstart: 'Tue Oct 21 14:00:00 2026' })
  for (const k of ['source', 'reason', 'previous_session_id', 'lineage_reason']) expect(w.rowsOf('session')[0]?.[k]).toBeNull()
  for (const r of w.rows) for (const k of ['v', 'ts', 'ev', 'sid', 'actor', 'writer', 'pid', 'plugin_version', 'cc_version', 'turn_seq']) expect(Object.keys(r)).toContain(k)
})

test('AT-M3-08: lastVersion 2.1.304, version 2.1.305: one version_change, smokeDue, one toast; again: nothing', async ($, on) => {
  const w = new World({ version: { version: '2.1.305' } })
  w.install(on, { lastVersion: '2.1.304' })
  await w.start($)
  await w.start($)
  expect(w.rowsOf('version_change').map(r => [r.from, r.to])).toEqual([['2.1.304', '2.1.305']])
  expect(JSON.parse(w.files.get(`${WATCH}/version.json`) ?? '{}')).toEqual({ lastVersion: '2.1.305', smokeDue: '2.1.305' })
  expect(w.toasts.filter(t => t.includes('version-change')).length).toBe(1)
})

test('AT-M3-08 (reload): a load that finds lastVersion equal adds nothing', async ($, on) => {
  const w = new World({ version: { version: '2.1.305' } })
  w.install(on, { lastVersion: '2.1.305', smokeDue: '2.1.305' })
  await w.start($)
  expect(w.rowsOf('version_change').length).toBe(0)
  // The first-run notice (W-BETA A) is not a version toast.
  expect(w.toasts.filter(t => t !== shippedNotice(w.name).text).length).toBe(0)
})

test('AT-M3-09: version 2.1.306-dev sets smokeDue, once', async ($, on) => {
  const w = new World({ version: { version: '2.1.306-dev', base: '2.1.306-dev' } })
  w.install(on, { lastVersion: '2.1.306-dev' })
  await w.start($)
  await w.start($)
  expect(w.rowsOf('version_change').length).toBe(1)
  expect(JSON.parse(w.files.get(`${WATCH}/version.json`) ?? '{}').smokeDue).toBe('2.1.306-dev')
})

test('C5 (mod): a session.compact key set off the baseline logs keyset_change once per version', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  w.files.set(`${w.root}/assets/canary-baseline.json`, JSON.stringify({ c5: { 'session.compact': '00000000' } }))
  await raiseCompact($, { trigger: 'auto' })
  await raiseCompact($, { trigger: 'manual' })
  expect(w.rowsOf('keyset_change').length).toBe(1)
  expect(w.rowsOf('keyset_change')[0]?.surface).toBe('session.compact')
})

test('C5 (mod): no baseline file, no row', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await raiseCompact($, { trigger: 'auto' })
  expect(w.rowsOf('keyset_change').length).toBe(0)
})

test('resume_undelivered: a block no channel claimed through a whole turn; none when SessionStart claimed it', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await w.turnStart($)
  await raiseCompact($, { trigger: 'auto' })
  await w.turnEnd($)
  expect(w.rowsOf('resume_undelivered').length).toBe(0)
  await w.turnStart($)
  await w.turnEnd($)
  expect(w.rowsOf('resume_undelivered').length).toBe(1)
  expect(w.toasts.some(t => t.includes('resume-undelivered'))).toBe(true)

  await raiseCompact($, { trigger: 'auto' })
  const nonce = markerNonce(w, w.compacts[1]?.instructions) ?? ''
  w.files.set(`${WATCH}/${SID_A}/resume-claimed/${nonce}`, 'sessionstart')
  await w.turnStart($)
  await w.turnEnd($)
  await w.turnStart($)
  await w.turnEnd($)
  expect(w.rowsOf('resume_undelivered').length).toBe(1)
})

test('prompt.context: TAKEN (SessionStart won) adds no block', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  w.atCompact = () => {
    const n = markerNonce(w, w.compacts[w.compacts.length - 1]?.instructions)
    if (n) w.claims.set(n, 'sessionstart')
  }
  await raiseCompact($, { trigger: 'auto' })
  const ctx = await $.prompt.context({ blocks: [] })
  expect(ctx.blocks.length).toBe(0)
})

test('temp paths cited in main tool inputs go to paths.jsonl once', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await w.turnStart($)
  await $.tool.call({ tool: 'Bash', command: 'tail -n 20 /tmp/build.log' } as never)
  await $.tool.call({ tool: 'Bash', command: 'wc -l /tmp/build.log' } as never)
  await $.tool.call({ tool: 'Bash', command: 'cat /tmp/sub.log', agentId: AGENT } as never)
  expect(w.pathRows.map(r => r.path)).toEqual(['/tmp/build.log'])
  expect(w.pathRows[0]?.ev).toBe('path')
})

const seat: Register = (on: On) => {
  on('session.compact', ($, e, next) => next.to(e, 'append'))
  on('prompt.context', ($, e, next) => next.to(e, 'append'))
}

/** A nudged main turn, compacted at its end (500 ms), as in the boundary tests. */
async function nudged($: Engine, w: World): Promise<void> {
  await w.turnStart($)
  w.tokens = 610000
  await w.tool($)
  await w.turnEnd($)
  await w.advance(500)
}

test('AT-M1-11: seat simulation (prepend-tier plugin skips ours): self-call marker, resume_pref sessionstart, continue without the block when SessionStart claimed', {
  plugins: [{ name: 'seat-sim', tier: 'prepend', register: seat }],
}, async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  w.files.set(`${WATCH}/${SID_A}/classic-alive.json`, '{}')
  await $.prompt.context({ blocks: [] })
  w.atCompact = () => {
    const n = markerNonce(w, w.compacts[w.compacts.length - 1]?.instructions)
    if (n) w.claims.set(n, 'sessionstart')
  }
  await nudged($, w)
  expect(w.compacts.length).toBe(1)
  const d = w.callsOf('dispatch')[0]
  expect(markerNonce(w, w.compacts[0]?.instructions)).toBe(w.flag(d, '--nonce'))
  expect(w.flag(d, '--channel')).toBe('mod-self')
  expect(w.flag(d, '--resume-pref')).toBe('sessionstart')
  expect(w.submits.length).toBe(1)
  expect(w.submits[0]).not.toContain('plugin adds this after compaction')
})

test('AT-M1-11: seat simulation: the full block in the continue text when the claim is still free', {
  plugins: [{ name: 'seat-sim', tier: 'prepend', register: seat }],
}, async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  w.files.set(`${WATCH}/${SID_A}/classic-alive.json`, '{}')
  await nudged($, w)
  expect(w.flag(w.callsOf('dispatch')[0], '--resume-pref')).toBe('sessionstart')
  expect(w.submits[0]).toContain(`The ${w.name} plugin adds this after compaction`)
  const nonce = w.flag(w.callsOf('dispatch')[0], '--nonce') ?? ''
  expect(w.claims.get(nonce)).toBe('prompt.submit')
  const raised = await raiseCompact($, { trigger: 'auto' })
  expect(raised.skip).toBeUndefined()
  expect(markerNonce(w, w.compacts[1]?.instructions)).toBeUndefined()
})

test('resume_pref for mod-self: prompt.context once prompt.context ran; prompt.submit with no classic-alive', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await nudged($, w)
  expect(w.flag(w.callsOf('dispatch')[0], '--resume-pref')).toBe('prompt.submit')
  await w.advance(60000)
  await w.turnStart($, 'continue text')
  await $.prompt.context({ blocks: [] })
  await w.turnEnd($)
  for (let q = 0; q < 2; q++) {
    await w.turnStart($)
    w.tokens = 100000
    await w.turnEnd($)
  }
  await nudged($, w)
  expect(w.flag(w.callsOf('dispatch')[1], '--resume-pref')).toBe('prompt.context')
})

test('AT-M5-06: full mod lifecycle under an fs trace: no pin write; every write under <root>', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await w.turnStart($)
  await raiseCompact($, { trigger: 'auto' })
  await raiseCompact($, { trigger: 'auto', agentId: AGENT })
  await raiseCompact($, { trigger: 'precompute' })
  await $.prompt.context({ blocks: [] })
  await w.turnEnd($)
  await nudged($, w)
  w.summaryMode = 'unshaped'
  await w.turnStart($, 'continue text')
  await raiseCompact($, { trigger: 'auto' })
  await raiseCompact($, { trigger: 'auto' })
  w.helperDown = true
  await raiseCompact($, { trigger: 'manual' })
  await w.turnEnd($)
  expect(w.writes.length).toBeGreaterThan(5)
  for (const p of w.writes) {
    expect(p.startsWith(ROOT + '/')).toBe(true)
    expect(p.includes('/.sessions/')).toBe(false)
  }
  expect(w.writes.some(p => p.startsWith(HOME + '/.claude/handoffs/.watch/'))).toBe(true)
})

test('unsafe roots: ident watch null (every log folder refused): the mod writes no file at all', async ($, on) => {
  const w = new World().install(on)
  w.identWatch = null
  await w.start($)
  await w.turnStart($)
  await raiseCompact($, { trigger: 'auto' })
  await w.settle()
  expect(w.callsOf('ident').length).toBe(1)
  expect(w.writes).toEqual([])
})

test('unsafe roots: the mod writes under the watch folder ident gives, not the configured one', async ($, on) => {
  const w = new World().install(on)
  const other = HOME + '/.claude/handoffs-default/.watch'
  w.identWatch = other
  await w.start($)
  await w.turnStart($)
  await raiseCompact($, { trigger: 'auto' })
  await w.settle()
  expect(w.writes.length).toBeGreaterThan(0)
  expect(w.writes.filter(p => !p.startsWith(other + '/'))).toEqual([])
  expect(w.files.has(`${other}/${SID_A}/mod-alive.json`)).toBe(true)
  expect(w.writes.some(p => p.startsWith(`${other}/${SID_A}/pending/`))).toBe(true)
})

test('tool.call: the tool starts before its temp paths are recorded (no helper spawn ahead of the tool)', async ($, on) => {
  const w = new World().install(on)
  let atStart = -1
  w.toolAnswer = () => {
    atStart = w.pathRows.length
    return { result: {} }
  }
  await w.start($)
  await w.turnStart($)
  await $.tool.call({ tool: 'Bash', command: 'tail -n 20 /tmp/build.log' } as never)
  expect(atStart).toBe(0)
  await w.settle()
  expect(w.pathRows.map(r => r.path)).toEqual(['/tmp/build.log'])
})

test('F2-6: one tool call citing three new temp paths: one log --stream paths --stdin spawn, three JSON lines; a repeat call spawns nothing', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await w.turnStart($)
  await $.tool.call({ tool: 'Bash', command: 'diff /tmp/a.log /tmp/b.log > /private/tmp/c.diff' } as never)
  await w.settle()
  const calls = w.callsOf('log').filter(c => w.flag(c, '--stream') === 'paths')
  expect(calls.length).toBe(1)
  expect(calls[0]?.args).toContain('--stdin')
  expect(calls[0]?.args).not.toContain('--json')
  const lines = (calls[0]?.stdin ?? '').split('\n').filter(l => l !== '')
  expect(lines.map(l => (JSON.parse(l) as { path: string }).path)).toEqual(['/tmp/a.log', '/tmp/b.log', '/private/tmp/c.diff'])
  expect(w.pathRows.map(r => [r.ev, r.tool, r.sid])).toEqual([['path', 'Bash', SID_A], ['path', 'Bash', SID_A], ['path', 'Bash', SID_A]])
  await $.tool.call({ tool: 'Bash', command: 'cat /tmp/a.log /tmp/b.log' } as never)
  await w.settle()
  expect(w.callsOf('log').filter(c => w.flag(c, '--stream') === 'paths').length).toBe(1)
})

test('PRIV-04: no ident answer (helper failed it): the raw summary is stashed nowhere, not under the configured watch', async ($, on) => {
  const w = new World().install(on)
  w.replies['ident'] = () => ({ exitCode: 70, stdout: '' })
  await w.start($)
  await w.turnStart($)
  await raiseCompact($, { trigger: 'auto' })
  await w.settle()
  expect(w.writes.filter(p => p.includes('/pending/'))).toEqual([])
  expect([...w.files.keys()].filter(p => p.endsWith('.mod.md'))).toEqual([])
  expect(w.callsOf('save-copy').length).toBe(0)
  expect(w.rowsOf('copy_failed').map(r => r.reason)).toEqual(['helper-missing'])
})

test('PRIV-04: a compaction before any session.start or turn.start in this load asks ident first and stashes under its watch only', async ($, on) => {
  const w = new World().install(on)
  const other = HOME + '/.claude/handoffs-default/.watch'
  w.identWatch = other
  await raiseCompact($, { trigger: 'manual' })
  await w.settle()
  expect(w.callsOf('ident').length).toBe(1)
  const stashed = w.writes.filter(p => p.endsWith('.mod.md'))
  expect(stashed.length).toBe(1)
  expect(stashed[0]?.startsWith(`${other}/${SID_A}/pending/`)).toBe(true)
  expect(w.flag(w.callsOf('save-copy')[0], '--from')).toBe(stashed[0])
})

test('PRIV-04: ident watch null: no stash, copy_failed unsafe-root (row through the helper log)', async ($, on) => {
  const w = new World().install(on)
  w.identWatch = null
  await w.start($)
  await w.turnStart($)
  await raiseCompact($, { trigger: 'auto' })
  await w.settle()
  expect(w.writes).toEqual([])
  expect(w.rowsOf('copy_failed').map(r => r.reason)).toEqual(['unsafe-root'])
})

test('tool.call: auto_evidence off records no temp paths', { options: { auto_evidence: false } }, async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await w.turnStart($)
  await $.tool.call({ tool: 'Bash', command: 'tail -n 20 /tmp/build.log' } as never)
  await w.settle()
  expect(w.pathRows).toEqual([])
  expect(w.callsOf('log').filter(c => c.args.includes('paths')).length).toBe(0)
})
