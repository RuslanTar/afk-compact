// U tests through the kit: a headless session's plugin compaction as a `/compact` command.
// Claude Code rejects `$.session.compact` in a headless session (`claude -p`, the Agent SDK, or
// an app or editor built on it), while a `/compact` input compacts there; a plugin runs one with
// `$.command.run({ command: 'compact' })`. The bare command reaches our own `session.compact`
// hook (trigger `manual`), which shapes it with the text the boundary prepared and runs the
// after-step. An interactive session keeps `$.session.compact`.
import { expect, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { Deps, OwnCompact, RunResult } from '../../hooks/lib/deps'
import { claimOwnCompact, commandClass, launcherPath, newState, pluginCompactOff } from '../../hooks/lib/deps'
import { commandOutcome, compactRejected } from '../../hooks/lib/boundary'
import { SID_A, World, markerNonce, raiseCompact } from './harness.test'

const MIN = 60000
/** Turn ends at or above the target (400K) and below the soft max: the timer runs 2,000 ms. */
const AT_TARGET = 410000

/** A person's main turn that ends at the target, then the boundary's delay. */
async function turnAtTarget($: Engine, w: World): Promise<void> {
  await w.userTurn($, 'next step please', 'sdk')
  w.tokens = AT_TARGET
  await w.turnEnd($)
  await w.advance(2000)
}

function headlessWorld(on: Parameters<World['install']>[0]): World {
  const w = new World().install(on)
  w.interactive = false
  return w
}

test('AT-HC-01: commandClass names no-command, input-ended, in-hook, not-enough, other; pluginCompactOff only for a headless load with the path off', () => {
  expect(commandClass('$.command.run: no command named compact')).toBe('no-command')
  expect(commandClass('the host has ended its input')).toBe('input-ended')
  expect(commandClass('rejected inside a hook the turn waits on')).toBe('in-hook')
  expect(commandClass('Not enough messages to compact.')).toBe('not-enough')
  expect(commandClass('Not compacted · a hook said no')).toBe('other')
  const s = newState('l')
  expect(pluginCompactOff(s)).toBe(false)
  s.headless = true
  expect(pluginCompactOff(s)).toBe(false)
  s.headlessCompact = 'none'
  expect(pluginCompactOff(s)).toBe(true)
  s.headless = false
  expect(pluginCompactOff(s)).toBe(false)
})

test('AT-HC-02: claimOwnCompact takes one main manual compaction while our /compact is in flight; never auto, precompute or a subagent\'s', () => {
  const s = newState('l')
  expect(claimOwnCompact(s, { trigger: 'manual' })).toBeUndefined()
  s.ownCompact = { nonce: '1a2b3c4d', text: 't', pref: 'prompt.context', t0: 0, claimed: false }
  expect(claimOwnCompact(s, { trigger: 'auto' })).toBeUndefined()
  expect(claimOwnCompact(s, { trigger: 'precompute' })).toBeUndefined()
  expect(claimOwnCompact(s, { trigger: 'manual', agentId: 'a1' })).toBeUndefined()
  expect(claimOwnCompact(s, { trigger: 'manual' })?.nonce).toBe('1a2b3c4d')
  expect(claimOwnCompact(s, { trigger: 'manual' })).toBeUndefined()
})

test('AT-HC-03: headless, a turn end at the target: one bare /compact, shaped by our hook with the mod-self nonce; after-step, compacted and compact_command rows; no $.session.compact, nudge or continue; the next prompt gets the resume block', async ($, on) => {
  const w = headlessWorld(on)
  await w.start($)
  expect(w.rowsOf('headless').map(r => [r.via, r.compact])).toEqual([['session-start', 'command']])
  await turnAtTarget($, w)
  // One /compact, bare, from this plugin: no text of ours in the transcript's command row.
  expect(w.commandRuns.map(c => [c.command, c.args])).toEqual([['compact', '']])
  expect(w.commandRuns[0]?.origin).toEqual({ kind: 'plugin', name: w.name })
  // The only compaction that reached the bottom is the command's manual one, with our text.
  expect(w.compacts.map(c => c.trigger)).toEqual(['manual'])
  const d = w.callsOf('dispatch')
  expect(d.length).toBe(1)
  expect(w.flag(d[0], '--channel')).toBe('mod-self')
  expect(w.flag(d[0], '--trigger')).toBe('plugin')
  const nonce = w.flag(d[0], '--nonce')
  expect(markerNonce(w, w.compacts[0]?.instructions)).toBe(nonce)
  expect(w.callsOf('checkpoint').length).toBe(1)
  expect(w.callsOf('save-copy').map(c => w.flag(c, '--nonce'))).toEqual([nonce])
  expect(w.rowsOf('compacted').map(r => [r.nonce, r.skip])).toEqual([[nonce, null]])
  expect(w.rowsOf('compact_command').map(r => [r.nonce, r.result, r.error_class])).toEqual([[nonce, 'compacted', null]])
  expect(w.rowsOf('compact_rejected').length).toBe(0)
  expect(w.rowsOf('self_call_hook_ran').length).toBe(0)
  expect([w.rowsOf('nudge').length, w.submits.length]).toEqual([0, 0])
  // The person's next prompt: the resume block rides along (prompt.context).
  w.tokens = 40000
  await w.userTurn($, 'go on', 'sdk')
  const ctx = await $.prompt.context({ blocks: [] })
  expect(ctx.blocks.length).toBe(1)
  expect(ctx.blocks[0]?.text).toContain(nonce?.slice(0, 6) ?? 'x')
})

test('AT-HC-04: a failed /compact (Claude Code answers its reason): compact_command failed with the class and text, no compacted row; the cooldown holds the next turn end; the second failure in a row turns the path off (headless command-failed none); no more /compact after', async ($, on) => {
  const w = headlessWorld(on)
  w.commandMode = { text: 'Not enough messages to compact.' }
  await w.start($)
  await turnAtTarget($, w)
  expect(w.rowsOf('compact_command').map(r => [r.result, r.error_class, r.error])).toEqual([['failed', 'not-enough', 'Not enough messages to compact.']])
  expect(w.rowsOf('compacted').length).toBe(0)
  expect(w.callsOf('save-copy').length).toBe(0)
  // Within the 30 s cooldown: no retry at the next turn end.
  await turnAtTarget($, w)
  expect(w.commandRuns.length).toBe(1)
  expect(w.rowsOf('skip').map(r => r.why)).toContain('cooldown')
  await w.advance(MIN)
  await turnAtTarget($, w)
  expect(w.commandRuns.length).toBe(2)
  expect(w.rowsOf('headless').map(r => [r.via, r.compact])).toEqual([['session-start', 'command'], ['command-failed', 'none']])
  await w.advance(MIN)
  await turnAtTarget($, w)
  await w.advance(10 * MIN)
  await turnAtTarget($, w)
  expect(w.commandRuns.length).toBe(2)
  expect(w.compacts.length).toBe(0)
  expect(w.submits.length).toBe(0)
})

/** A Deps for the outcome step alone: the helper's `log` rows are kept, every other call fails. */
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
  d.state.headless = true
  return { d, rows }
}

const own = (nonce: string, claimed = false): OwnCompact => ({ nonce, text: 't', pref: 'prompt.context', t0: 0, claimed })

test('AT-HC-05: /compact rejected as unknown (compaction off) or past the host\'s input: the path is off at once, with Claude Code\'s text; another rejection or failure counts once', async () => {
  const a = rowDeps()
  await commandOutcome(a.d, 'sid-1', own('1a2b3c4d'), { rejected: new Error('$.command.run: no command named compact') })
  expect(a.rows.map(r => [r.ev, r.result ?? r.via, r.error_class ?? r.compact, r.error ?? null])).toEqual([
    ['compact_command', 'rejected', 'no-command', '$.command.run: no command named compact'],
    ['headless', 'command-failed', 'none', null],
  ])
  expect([a.d.state.headlessCompact, a.d.state.commandFails, a.d.state.lastPluginCompactAt]).toEqual(['none', 1, 0])

  const b = rowDeps()
  await commandOutcome(b.d, 'sid-1', own('1a2b3c4d'), { rejected: new Error('the host has ended its input') })
  expect(b.rows.map(r => r.error_class ?? r.compact)).toEqual(['input-ended', 'none'])

  const c = rowDeps()
  await commandOutcome(c.d, 'sid-1', own('1a2b3c4d'), { rejected: new Error('rejected inside a hook the turn waits on') })
  expect(c.rows.map(r => [r.result, r.error_class])).toEqual([['rejected', 'in-hook']])
  expect([c.d.state.headlessCompact, c.d.state.commandFails]).toEqual(['command', 1])
  await commandOutcome(c.d, 'sid-1', own('5e6f7a8b'), { text: 'Not compacted \u00b7 a hook said no' })
  expect(c.rows.map(r => [r.ev, r.result ?? r.via, r.error_class ?? r.compact])).toEqual([
    ['compact_command', 'rejected', 'in-hook'], ['compact_command', 'failed', 'other'], ['headless', 'command-failed', 'none'],
  ])
})

test('AT-HC-05: only a claimed compaction that compacted resets the failure count; claimed but skipped, claimed with no result and unclaimed are failures with the cooldown, two in a row turn the path off', async () => {
  const a = rowDeps()
  a.d.state.commandFails = 1
  const o = own('1a2b3c4d', true)
  o.result = { messages: [] }
  await commandOutcome(a.d, 'sid-1', o, { text: undefined })
  expect([a.d.state.commandFails, a.d.state.lastPluginCompactAt]).toEqual([0, undefined])
  const k = own('5e6f7a8b', true)
  k.result = { skip: 'other-plugin' }
  await commandOutcome(a.d, 'sid-1', k, { text: 'Not compacted \u00b7 other-plugin' })
  expect([a.d.state.commandFails, a.d.state.lastPluginCompactAt, a.d.state.headlessCompact]).toEqual([1, 0, 'command'])
  await commandOutcome(a.d, 'sid-1', own('9c0d1e2f'), { text: undefined })
  expect(a.rows.map(r => [r.ev, r.nonce ?? r.via, r.result ?? r.compact, r.error_class ?? null])).toEqual([
    ['compact_command', '1a2b3c4d', 'compacted', null], ['compact_command', '5e6f7a8b', 'skipped', null],
    ['compact_command', '9c0d1e2f', 'unclaimed', null], ['headless', 'command-failed', 'none', null],
  ])
  expect([a.d.state.commandFails, a.d.state.headlessCompact, a.d.state.pluginCompactions.length]).toEqual([2, 'none', 1])

  // Claimed, no result (the compaction beneath our hook threw): failed, with Claude Code's text.
  const b = rowDeps()
  await commandOutcome(b.d, 'sid-1', own('1a2b3c4d', true), { rejected: new Error('Error during compaction: summarizer failed') })
  expect(b.rows.map(r => [r.result, r.error_class, r.error])).toEqual([['failed', 'other', 'Error during compaction: summarizer failed']])
  expect([b.d.state.commandFails, b.d.state.lastPluginCompactAt]).toEqual([1, 0])
  await commandOutcome(b.d, 'sid-1', own('5e6f7a8b', true), { text: undefined })
  expect(b.rows.map(r => [r.ev, r.result ?? r.compact, r.error_class ?? null, r.error ?? null])).toEqual([
    ['compact_command', 'failed', 'other', 'Error during compaction: summarizer failed'], ['compact_command', 'failed', 'other', null],
    ['headless', 'none', null, null],
  ])
})

test('AT-HC-05: a rejection through the kit (class other): one failure, the cooldown holds the next turn end; the second in a row turns the path off', async ($, on) => {
  const w = headlessWorld(on)
  w.commandMode = 'reject'
  await w.start($)
  await turnAtTarget($, w)
  expect(w.rowsOf('compact_command').map(r => [r.result, r.error_class])).toEqual([['rejected', 'other']])
  expect(w.rowsOf('headless').map(r => r.compact)).toEqual(['command'])
  await turnAtTarget($, w)
  expect(w.commandRuns.length).toBe(1)
  await w.advance(MIN)
  await turnAtTarget($, w)
  expect(w.rowsOf('headless').map(r => r.compact)).toEqual(['command', 'none'])
  await w.advance(MIN)
  await turnAtTarget($, w)
  expect(w.commandRuns.length).toBe(2)
})

test('AT-HC-05: failed, compacted, failed: the path stays on (two failures in a row turn it off, not two in the load)', async ($, on) => {
  const w = headlessWorld(on)
  w.commandMode = { text: 'Not compacted · busy' }
  await w.start($)
  await turnAtTarget($, w)
  w.commandMode = 'run'
  await w.advance(MIN)
  await turnAtTarget($, w)
  w.commandMode = { text: 'Not compacted · busy' }
  await w.advance(MIN)
  await turnAtTarget($, w)
  expect(w.rowsOf('compact_command').map(r => r.result)).toEqual(['failed', 'compacted', 'failed'])
  expect(w.rowsOf('headless').map(r => r.compact)).toEqual(['command'])
})

test('AT-HC-06: a /compact that compacted without reaching our hook: compact_command unclaimed, no after-step; a failure with the cooldown, the second in a row turns the path off', async ($, on) => {
  const w = headlessWorld(on)
  w.commandMode = 'unclaimed'
  await w.start($)
  await turnAtTarget($, w)
  expect(w.rowsOf('compact_command').map(r => r.result)).toEqual(['unclaimed'])
  expect(w.callsOf('save-copy').length).toBe(0)
  expect(w.rowsOf('compacted').length).toBe(0)
  await turnAtTarget($, w)
  expect(w.commandRuns.length).toBe(1)
  expect(w.rowsOf('headless').map(r => r.compact)).toEqual(['command'])
  await w.advance(MIN)
  await turnAtTarget($, w)
  expect(w.commandRuns.length).toBe(2)
  expect(w.rowsOf('headless').map(r => r.compact)).toEqual(['command', 'none'])
  await w.advance(MIN)
  await turnAtTarget($, w)
  expect(w.commandRuns.length).toBe(2)
})

test('AT-HC-07: interactive: $.session.compact as before, no /compact command', { options: { precompact_turn: 'code' } }, async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await turnAtTarget($, w)
  expect(w.compacts.length).toBe(1)
  expect(w.commandRuns.length).toBe(0)
  expect(w.rowsOf('compact_command').length).toBe(0)
  expect(w.rowsOf('compacted').length).toBe(1)
})

test('AT-HC-08: a load whose $.session.compact rejected as headless (no isInteractive false at its start) keeps the /compact path: headless compact-rejected, compact command', async () => {
  const { d, rows } = rowDeps()
  d.state.headless = false
  await compactRejected(d, 'sid-1', '1a2b3c4d', new Error('not available in a headless (-p / SDK) session yet'))
  expect(rows.map(r => [r.ev, r.error_class ?? r.via, r.compact ?? null])).toEqual([
    ['compact_rejected', 'headless', null], ['headless', 'compact-rejected', 'command'],
  ])
  expect([d.state.headless, pluginCompactOff(d.state)]).toEqual([true, false])
})

test('AT-HC-09: a person\'s (or the host\'s) /compact in a headless session, none of ours in flight: shaped as a manual one (mod-hook), no compact_command row', async ($, on) => {
  const w = headlessWorld(on)
  await w.start($)
  await w.userTurn($, 'hi', 'sdk')
  await w.turnEnd($)
  await raiseCompact($, { trigger: 'manual' })
  const d = w.callsOf('dispatch')
  expect(w.flag(d[0], '--channel')).toBe('mod-hook')
  expect(w.flag(d[0], '--trigger')).toBe('manual')
  expect(w.rowsOf('compact_command').length).toBe(0)
})

test('AT-HC-10: no loop: two unshaped summaries in a row enter halt (2-nonok); no /compact after, until a person\'s prompt clears it', async ($, on) => {
  const w = headlessWorld(on)
  w.summaryMode = 'unshaped'
  await w.start($)
  await turnAtTarget($, w)
  await w.advance(MIN)
  await turnAtTarget($, w)
  expect(w.commandRuns.length).toBe(2)
  expect(w.rowsOf('halt').map(r => [r.reason, r.active])).toEqual([['2-nonok', true]])
  // A turn this plugin did not open (a task notification) keeps halt: no /compact.
  await w.advance(MIN)
  await w.userTurn($, 'background result', 'task-notification')
  w.tokens = AT_TARGET
  await w.turnEnd($)
  await w.advance(2000)
  expect(w.commandRuns.length).toBe(2)
  // A person's prompt (SDK origin) clears halt; the next turn end compacts again.
  w.summaryMode = 'ok'
  await w.advance(MIN)
  await turnAtTarget($, w)
  expect(w.commandRuns.length).toBe(3)
  expect(w.rowsOf('compact_command').map(r => r.result)).toEqual(['compacted', 'compacted', 'compacted'])
})

test('AT-HC-11: the /compact is never a person\'s prompt: no prompt.submit of ours, no turn of ours, halt not cleared by it', async ($, on) => {
  const w = headlessWorld(on)
  await w.start($)
  await turnAtTarget($, w)
  expect(w.submitOrigins.length).toBe(0)
  expect(w.commandRuns.length).toBe(1)
  expect(w.commandRuns[0]?.args).toBe('')
  expect(w.rowsOf('halt').length).toBe(0)
  expect(w.rowsOf('headless').map(r => r.sid)).toEqual([SID_A])
})

test('AT-HC-12: no self-repeating /compact: a claimed /compact that was skipped is a failure with the cooldown, so the end of the turn Claude Code ran it in (after the command answered) runs no second one; the second skip in a row turns the path off', async ($, on) => {
  const w = headlessWorld(on)
  w.compactMode = { skip: 'other-plugin' }
  await w.start($)
  await turnAtTarget($, w)
  // The turn the /compact ran in ends after the command answered, at the target, no prompt typed.
  for (let i = 0; i < 4; i++) {
    await w.turnStart($, '/compact')
    await w.turnEnd($, '', 'answer')
    await w.advance(2000)
  }
  expect(w.commandRuns.length).toBe(1)
  expect([w.callsOf('checkpoint').length, w.callsOf('dispatch').length]).toEqual([1, 1])
  expect(w.rowsOf('compact_command').map(r => r.result)).toEqual(['skipped'])
  expect(w.rowsOf('skip').map(r => r.why)).toContain('cooldown')
  expect(w.rowsOf('headless').map(r => r.compact)).toEqual(['command'])
  // A person's turn end past the cooldown runs one more; skipped again, the path is off.
  await w.advance(MIN)
  await turnAtTarget($, w)
  expect(w.commandRuns.length).toBe(2)
  expect(w.rowsOf('headless').map(r => [r.via, r.compact])).toEqual([['session-start', 'command'], ['command-failed', 'none']])
  await w.advance(MIN)
  await turnAtTarget($, w)
  expect(w.commandRuns.length).toBe(2)
})

test('AT-HC-13: the turn our /compact runs in (started while it is in flight) ends with no plugin compaction, even past the cooldown', async ($, on) => {
  const w = headlessWorld(on)
  w.compactMode = { skip: 'other-plugin' }
  w.commandTurn = true
  await w.start($)
  await turnAtTarget($, w)
  expect(w.commandRuns.length).toBe(1)
  await w.advance(MIN)
  await w.turnEnd($, '', 'answer')
  await w.advance(2000)
  expect(w.commandRuns.length).toBe(1)
  expect(w.rowsOf('compact_command').map(r => r.result)).toEqual(['skipped'])
  // A person's next turn end compacts as usual.
  w.compactMode = 'ok'
  await turnAtTarget($, w)
  expect(w.rowsOf('compact_command').map(r => r.result)).toEqual(['skipped', 'compacted'])
})

test('AT-HC-14: claimed, but the compaction beneath our hook threw (no result): compact_command failed with a class, not skipped; the cooldown holds the next turn end; the second in a row turns the path off', async ($, on) => {
  const w = headlessWorld(on)
  w.compactMode = 'reject'
  await w.start($)
  await turnAtTarget($, w)
  expect(w.rowsOf('compact_command').map(r => [r.result, r.error_class])).toEqual([['failed', 'other']])
  expect(w.rowsOf('compacted').length).toBe(0)
  await turnAtTarget($, w)
  expect(w.commandRuns.length).toBe(1)
  await w.advance(MIN)
  await turnAtTarget($, w)
  expect(w.commandRuns.length).toBe(2)
  expect(w.rowsOf('headless').map(r => r.compact)).toEqual(['command', 'none'])
})
