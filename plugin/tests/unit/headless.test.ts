// U tests through the kit: a headless session (`claude -p`, the Agent SDK), where Claude Code
// rejects a plugin's compaction call (`$.session.compact`). The plugin then neither nudges nor
// opens a handoff or idle turn; it compacts only by running `/compact` at a turn end
// (headless-compact.test.ts), and not at all once that path is off. Claude Code's own
// compactions are still shaped. A live probe: the nudge at 315K, then
// `compact_rejected` with the error text discarded.
import { expect, test } from 'claude-code/testing'
import type { Deps, RunResult } from '../../hooks/lib/deps'
import { launcherPath, newState, rejectClass, rejectText } from '../../hooks/lib/deps'
import { boundary, compactRejected } from '../../hooks/lib/boundary'
import { nudgeText } from '../../hooks/lib/nudge'
import { SID_A, SID_B, World, markerNonce, raiseCompact } from './harness.test'

const HEADLESS_ERR = 'session.compact is not available in a headless (-p / SDK) session yet'
const MIN = 60000
const LIMITS = [{ kind: 'five_hour', percentUsed: 12 }, { kind: 'seven_day', percentUsed: 30 }]

test('AT-HL-01: rejectText keeps Claude Code\'s error on one line, at most 160 characters; rejectClass names headless, turn-running, other', () => {
  expect(rejectText(new Error('line one\n\tline\u0007 two  '))).toBe('line one line two')
  expect(rejectText(new Error('x'.repeat(400))).length).toBe(160)
  expect(rejectText('plain string')).toBe('plain string')
  expect(rejectClass(HEADLESS_ERR)).toBe('headless')
  expect(rejectClass('a turn is running')).toBe('turn-running')
  expect(rejectClass('Cannot compact while a turn runs')).toBe('turn-running')
  expect(rejectClass('something else')).toBe('other')
})

test('AT-HL-02: session.start isInteractive false: one headless row after the session row; no nudge, handoff or idle turn; the plugin compaction runs as /compact, never $.session.compact; native compactions still shaped', { options: { idle_handoff_turn: 'true', precompact_turn: 'true' } }, async ($, on) => {
  const w = new World().install(on)
  w.interactive = false
  w.rateLimits = LIMITS
  await w.start($)
  const evs = w.rows.map(r => r.ev)
  expect(evs.indexOf('headless')).toBeGreaterThan(evs.indexOf('session'))
  expect(w.rowsOf('headless').map(r => [r.via, r.compact])).toEqual([['session-start', 'command']])
  await w.userTurn($)
  w.tokens = 610000
  expect((await w.tool($)).context).toBeUndefined()
  expect(w.rowsOf('nudge').length).toBe(0)
  await w.turnEnd($)
  await w.advance(60 * MIN)
  // One plugin compaction, as a bare /compact (manual through our hook), no submit of any turn.
  expect(w.commandRuns.map(c => [c.command, c.args])).toEqual([['compact', '']])
  expect(w.compacts.map(c => c.trigger)).toEqual(['manual'])
  expect(w.submits.length).toBe(0)
  expect(w.callsOf('dispatch').map(c => w.flag(c, '--channel'))).toEqual(['mod-self'])
  expect(w.callsOf('handoff-turn').length).toBe(0)
  expect(w.rowsOf('idle_mode').map(r => r.plugin_turn)).toEqual(['off'])
  expect(w.rowsOf('idle_silent').length).toBe(0)
  // Claude Code's own automatic compaction: shaped through the hook as in any session.
  await raiseCompact($, { trigger: 'auto' })
  const d = w.callsOf('dispatch')
  expect(d.length).toBe(2)
  expect(w.flag(d[1], '--channel')).toBe('mod-hook')
  expect(markerNonce(w, w.compacts[1]?.instructions)).toBe(w.flag(d[1], '--nonce'))
  expect(w.rowsOf('headless').length).toBe(1)
})

/** A Deps for the rejection handler alone: the helper's `log` rows are kept, every other call fails. */
function rowDeps(): { d: Deps; rows: Record<string, unknown>[] } {
  const rows: Record<string, unknown>[] = []
  const d = {
    name: 'x', root: '/p', helper: launcherPath('/p', 'x'), state: newState('l'),
    now: async () => 0,
    async run(argv: readonly string[]): Promise<RunResult> {
      if (argv[1] !== 'log') return { ok: false, exitCode: 64, stdout: '', error: '' }
      rows.push(JSON.parse(argv[argv.indexOf('--json') + 1] ?? '{}') as Record<string, unknown>)
      return { ok: true, exitCode: 0, stdout: '', error: '' }
    },
  } as unknown as Deps
  return { d, rows }
}

test('AT-HL-03: a headless rejection logs its class and text and one headless row; after it no nudge, and no plugin compaction once the /compact path is off; another rejection marks nothing', async () => {
  const { d, rows } = rowDeps()
  d.state.nudgeNonce = '1a2b3c4d'
  await compactRejected(d, 'sid-1', '1a2b3c4d', new Error(HEADLESS_ERR))
  await compactRejected(d, 'sid-1', '5e6f7a8b', new Error(HEADLESS_ERR))
  expect(rows.map(r => [r.ev, r.error_class ?? r.via, r.error ?? null])).toEqual([
    ['compact_rejected', 'headless', HEADLESS_ERR],
    ['headless', 'compact-rejected', null],
    ['compact_rejected', 'headless', HEADLESS_ERR],
  ])
  expect([d.state.headless, d.state.nudgeNonce]).toEqual([true, undefined])
  // Both return before any engine read this Deps lacks (usage, session id): nothing more runs.
  expect(await nudgeText(d, 'sid-1')).toBeUndefined()
  d.state.headlessCompact = 'none'
  await boundary(d)
  expect(rows.length).toBe(3)

  const other = rowDeps()
  await compactRejected(other.d, 'sid-2', '1a2b3c4d', new Error('a turn is running'))
  expect(other.rows.map(r => [r.ev, r.error_class, r.error])).toEqual([['compact_rejected', 'turn-running', 'a turn is running']])
  expect(other.d.state.headless).toBe(false)
})

test('AT-HL-05: a /clear in a headless load: the new session id gets its own headless row (same-load) at its first turn; still no nudge or submit; the plugin compaction runs as /compact', async ($, on) => {
  const w = new World().install(on)
  w.interactive = false
  await w.start($)
  await w.userTurn($)
  await w.turnEnd($)
  await w.userTurn($)
  await w.turnEnd($)
  expect(w.rowsOf('headless').map(r => [r.sid, r.via])).toEqual([[SID_A, 'session-start']])
  await $.session.end({ reason: 'clear', sessionId: SID_A, resume: { id: SID_A } } as never)
  w.sid = SID_B
  await w.userTurn($)
  w.tokens = 610000
  expect((await w.tool($)).context).toBeUndefined()
  await w.turnEnd($)
  await w.userTurn($)
  await w.turnEnd($)
  await w.advance(60 * MIN)
  expect(w.rowsOf('headless').map(r => [r.sid, r.via, r.compact])).toEqual([[SID_A, 'session-start', 'command'], [SID_B, 'same-load', 'command']])
  expect([w.rowsOf('nudge').length, w.submits.length]).toEqual([0, 0])
  expect([w.commandRuns.length, w.rowsOf('compact_command').map(r => [r.sid, r.result])]).toEqual([1, [[SID_B, 'compacted']]])
})

test('AT-HL-05: an interactive load logs no headless row at its turns', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await w.userTurn($)
  await w.turnEnd($)
  await $.session.end({ reason: 'clear', sessionId: SID_A, resume: { id: SID_A } } as never)
  w.sid = SID_B
  await w.userTurn($)
  await w.turnEnd($)
  expect(w.rowsOf('headless').length).toBe(0)
})
