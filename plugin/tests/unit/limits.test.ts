// U tests: the usage-limit rule of keep-warm and plugin idle compaction (limits.ts). Test ids
// AT-LM-nn. Synthetic values only.
import { expect, test } from 'claude-code/testing'
import type { Deps } from '../../hooks/lib/deps'
import type { LimitCtx } from '../../hooks/lib/limits'
import type { Reading } from '../../hooks/lib/limits'
import { LIMIT_DELTAS_KEY, LIMIT_FRESH_MS, PLAN_CAPS, USAGE_NOTE_MS, judge, noteUsage, ownReadings, planShares, readDeltas, readingsNow, recordDeltas, recordReadings, resetOf, usageFields, verdictOf, windowRule } from '../../hooks/lib/limits'
import { newState } from '../../hooks/lib/deps'
import { resultJobOpen } from '../../hooks/lib/keepwarm'

const NOW = 1792580712000
const MIN = 60000
const C: LimitCtx = { job: true, usageAt: NOW - 5 * MIN, now: NOW, deltas: { five_hour: [1, 2], seven_day: [1] } }
const w = (kind: string, percentUsed: number, resetsAt?: number) => ({ kind, percentUsed, ...(resetsAt !== undefined ? { resetsAt } : {}) })
/** The own reading's source and age (`C.usageAt`: 5 min) of these window kinds. */
const U = (...kinds: string[]) => ({ usage_src: kinds.map(k => `${k}:plugin`), usage_age_s: Object.fromEntries(kinds.map(k => [k, 300])), usage_n: Object.fromEntries(kinds.map(k => [k, 1])) })

test('AT-LM-01: below 90 every window is ok; the caps are 98 (five_hour) and 95 (seven_day)', () => {
  expect(PLAN_CAPS).toEqual({ five_hour: 98, seven_day: 95 })
  expect(LIMIT_FRESH_MS).toBe(10 * MIN)
  expect(verdictOf([w('five_hour', 89.9), w('seven_day', 40), w('spend_limit', 89)], C)).toEqual({ ok: true, band: false, rule: '90', windows: ['five_hour:89', 'seven_day:40', 'spend_limit:89'], usage: U('five_hour', 'seven_day', 'spend_limit') })
  expect(verdictOf([], C)).toEqual({ ok: true, band: false, rule: '90', windows: [], usage: U() })
})

test('AT-LM-02: a plan window above 90 runs on in the band only with a job open, a fresh reading and a measured change that fits below the cap', () => {
  // 93 + 2 + 1 < 98
  expect(verdictOf([w('five_hour', 93), w('seven_day', 40)], C)).toEqual({ ok: true, band: true, rule: 'band', windows: ['five_hour:93', 'seven_day:40'], usage: U('five_hour', 'seven_day') })
  expect(windowRule(w('five_hour', 93), { ...C, job: false })).toBe('no-job')
  expect(windowRule(w('five_hour', 93), { ...C, usageAt: NOW - 11 * MIN })).toBe('stale')
  expect(windowRule(w('five_hour', 93), { ...C, usageAt: undefined })).toBe('stale')
  expect(windowRule(w('five_hour', 93), { ...C, deltas: {} })).toBe('no-delta')
  // A change of 4 points at 95: 95 + 4 + 1 is not below 98. A change under a point counts as one
  // (a reading not yet refreshed after the compaction reads 0): at 95, 97 < 98; at 96, 98 is not.
  expect(windowRule(w('five_hour', 95), { ...C, deltas: { five_hour: [4] } })).toBe('delta')
  expect(windowRule(w('five_hour', 95), { ...C, deltas: { five_hour: [0] } })).toBe('band')
  expect(windowRule(w('five_hour', 96), { ...C, deltas: { five_hour: [0, 0, 0, 0, 0] } })).toBe('delta')
  expect(windowRule(w('five_hour', 96), { ...C, deltas: { five_hour: [0.4] } })).toBe('delta')
  expect(windowRule(w('five_hour', 97), { ...C, deltas: { five_hour: [0] } })).toBe('delta')
  // The largest of the last changes counts.
  expect(windowRule(w('five_hour', 93), { ...C, deltas: { five_hour: [0, 5, 1] } })).toBe('delta')
  expect(windowRule(w('five_hour', 98), C)).toBe('cap')
})

test('AT-LM-03: seven_day stops at its own cap 95; spend_limit and an unknown window always stop at 90; NaN stops', () => {
  expect(windowRule(w('seven_day', 96), C)).toBe('cap')
  expect(windowRule(w('seven_day', 92), C)).toBe('band')
  expect(windowRule(w('seven_day', 93), C)).toBe('delta')
  expect(windowRule(w('spend_limit', 93), C)).toBe('spend-90')
  expect(windowRule(w('spend_limit', 89), C)).toBe('ok')
  expect(windowRule(w('', 91), C)).toBe('other-90')
  expect(windowRule(w('five_hour', NaN), C)).toBe('cap')
  // The first stopping window decides, though another is in the band.
  expect(verdictOf([w('five_hour', 93), w('spend_limit', 91)], C)).toEqual({ ok: false, band: false, rule: 'spend-90', windows: ['five_hour:93', 'spend_limit:91'], usage: U('five_hour', 'spend_limit') })
})

test('AT-LM-04: a window whose reset time passed counts for nothing; resetOf is the latest reset of the windows that stop or hold, plan windows only', () => {
  expect(verdictOf([w('five_hour', 99, NOW - 1)], C).ok).toBe(true)
  expect(resetOf([w('five_hour', 99, NOW + 10 * MIN), w('seven_day', 20, NOW + 99 * MIN)], C)).toBe(NOW + 10 * MIN)
  expect(resetOf([w('five_hour', 99, NOW + 10 * MIN), w('seven_day', 96, NOW + 30 * MIN)], C)).toBe(NOW + 30 * MIN)
  expect(resetOf([w('five_hour', 99)], C)).toBe(undefined)
  expect(resetOf([w('spend_limit', 99, NOW + MIN)], C)).toBe(undefined)
})

test('AT-LM-05: recordDeltas keeps the last five changes per plan window kind; a window read on one side only, a reset between, or a drop adds none', async () => {
  const store: Record<string, unknown> = {}
  const d = {
    state: newState('l'),
    storeGet: async (k: string) => store[k],
    storeSet: async (k: string, v: unknown) => { store[k] = JSON.parse(JSON.stringify(v)) },
  } as unknown as Deps
  await recordDeltas(d, [w('five_hour', 40, NOW + MIN), w('seven_day', 10), w('spend_limit', 5)], [w('five_hour', 43, NOW + MIN), w('seven_day', 10), w('spend_limit', 9)])
  expect(store[LIMIT_DELTAS_KEY]).toEqual({ five_hour: [3], seven_day: [0] })
  await recordDeltas(d, [w('five_hour', 40, NOW + MIN)], [w('five_hour', 2, NOW + 300 * MIN), w('seven_day', 11)])
  await recordDeltas(d, [w('five_hour', 50)], [w('five_hour', 49)])
  expect(store[LIMIT_DELTAS_KEY]).toEqual({ five_hour: [3], seven_day: [0] })
  for (const x of [1, 2, 3, 4, 5]) await recordDeltas(d, [w('five_hour', 10)], [w('five_hour', 10 + x)])
  expect((await readDeltas(d)).five_hour).toEqual([1, 2, 3, 4, 5])
  store[LIMIT_DELTAS_KEY] = { five_hour: ['x', -1, 2], seven_day: 'bad' }
  expect(await readDeltas(d)).toEqual({ five_hour: [2] })
  expect(planShares([w('five_hour', 43), w('spend_limit', 9), w('seven_day', 10)])).toEqual({ five_hour: 43, seven_day: 10 })
})

test('AT-LM-06 (design TESTS 12): a job read that throws counts as no job open: a plan window above 90 stops (rule no-job), as at 90', async () => {
  const d = { state: newState('l'), agentsWorking: async () => { throw new Error('no agent list') } } as unknown as Deps
  const job = await resultJobOpen(d, 'sid-1')
  expect(job).toBe(false)
  expect(verdictOf([w('five_hour', 93)], { ...C, job })).toEqual({ ok: false, band: false, rule: 'no-job', windows: ['five_hour:93'], usage: U('five_hour') })
})

test('AT-LM-07: noteUsage writes the own reading to the shared record (helper usage --stdin, epoch seconds), again only once it changed or 5 min passed; no window, no write', async () => {
  const sent: { argv: readonly string[]; stdin?: string }[] = []
  let limits = [w('five_hour', 44, NOW + 60 * MIN), w('seven_day', 21), w('', 3)]
  const d = {
    state: newState('l'), helper: '/p/helper',
    usage: async () => ({ tokens: 1, window: 2, rateLimits: limits }),
    sessionId: async () => '5e55a001-0c0f-4f1e-9a00-00000000a001',
    run: async (argv: readonly string[], _ms: number, stdin?: string) => {
      sent.push({ argv, stdin })
      return { ok: true, exitCode: 0, stdout: '{"readings":[]}\n', error: '' }
    },
  } as unknown as Deps
  await noteUsage(d, NOW)
  expect(sent.map(x => [x.argv.slice(1), JSON.parse(x.stdin ?? 'null')])).toEqual([[['usage', '--sid', '5e55a001-0c0f-4f1e-9a00-00000000a001', '--stdin'], {
    at: NOW / 1000, windows: [{ kind: 'five_hour', pct: 44, resets_at: Math.floor((NOW + 60 * MIN) / 1000) }, { kind: 'seven_day', pct: 21, resets_at: null }],
  }]])
  await noteUsage(d, NOW + USAGE_NOTE_MS - 1)
  expect(sent.length).toBe(1)
  await noteUsage(d, NOW + USAGE_NOTE_MS)
  expect(sent.length).toBe(2)
  limits = [w('five_hour', 45, NOW + 60 * MIN), w('seven_day', 21)]
  await noteUsage(d, NOW + USAGE_NOTE_MS + 1)
  expect(sent.length).toBe(3)
  limits = []
  await noteUsage(d, NOW + 99 * MIN)
  expect(sent.length).toBe(3)
})

test('AT-LM-08: usageFields names each window\'s source (kind:source, in order) and its age in whole seconds; a window with no known time has no age, one with no kind reads unknown', () => {
  const rs = [...ownReadings([w('five_hour', 44), w('', 3)], NOW - 61499), { ...w('seven_day', 21), at: undefined, src: 'peer' as const }]
  expect(usageFields(rs, NOW)).toEqual({ usage_src: ['five_hour:plugin', 'unknown:plugin', 'seven_day:peer'], usage_age_s: { five_hour: 61, unknown: 61 } })
  expect(verdictOf([w('five_hour', 93)], { ...C, job: false }).usage).toEqual(U('five_hour'))
  expect(verdictOf([w('five_hour', 93)], { ...C, usageAt: undefined }).usage).toEqual({ usage_src: ['five_hour:plugin'], usage_age_s: {}, usage_n: { five_hour: 0 } })
})

/** A reading of `src` (a peer's under `sid8`), read `ago` minutes before NOW. */
const r = (kind: string, pct: number, src: Reading['src'], ago: number, resetsAt?: number, sid8 = 'aaaaaaaa'): Reading =>
  ({ kind, percentUsed: pct, ...(resetsAt !== undefined ? { resetsAt } : {}), at: NOW - ago * MIN, src, ...(src === 'peer' ? { sid8 } : {}) })

test('AT-LM-09: the trust rule: a kind stops only when every fresh reading of it does; one under the limit lets it run (split); with no fresh reading it never stops (no-fresh); one reading per session, its newest', () => {
  const c = { ...C, job: false }
  // Own 95 fresh, a peer 40 fresh: split, the peer's reading is the one named.
  const v1 = judge([r('five_hour', 20, 'plugin', 1), r('seven_day', 95, 'plugin', 1), r('seven_day', 40, 'peer', 3)], c)
  expect([v1.ok, v1.rule, v1.windows, v1.usage]).toEqual([true, 'split', ['five_hour:20', 'seven_day:40'], { usage_src: ['five_hour:plugin', 'seven_day:peer'], usage_age_s: { five_hour: 60, seven_day: 180 }, usage_n: { five_hour: 1, seven_day: 2 } }])
  // Every fresh reading at or over: the kind stops, with the own reading's rule.
  const v2 = judge([r('seven_day', 93, 'plugin', 1), r('seven_day', 96, 'peer', 2), r('seven_day', 10, 'peer', 30, undefined, 'bbbbbbbb')], c)
  expect([v2.ok, v2.rule, v2.windows, v2.usage.usage_n]).toEqual([false, 'no-job', ['seven_day:93'], { seven_day: 2 }])
  // Nothing fresh: no stop, rule no-fresh (an old reading at the limit), or 90 (none at it).
  expect([judge([r('seven_day', 95, 'plugin', 11), r('seven_day', 99, 'peer', 50)], c).ok, judge([r('seven_day', 95, 'plugin', 11)], c).rule]).toEqual([true, 'no-fresh'])
  expect(judge([r('seven_day', 50, 'plugin', 11)], c).rule).toBe('90')
  // The session's own plugin and status-line readings are one: the newest counts (a stale 95, a fresh 40: ok).
  expect(judge([r('seven_day', 95, 'plugin', 20), r('seven_day', 40, 'statusline', 1)], c).rule).toBe('90')
  expect(judge([r('seven_day', 40, 'plugin', 20), r('seven_day', 95, 'statusline', 1)], c).ok).toBe(false)
  // A peer's two sources likewise: its newest only.
  expect(judge([r('seven_day', 95, 'plugin', 1), r('seven_day', 40, 'peer', 9), r('seven_day', 96, 'peer', 1)], c).ok).toBe(false)
  // A reading whose window has reset counts for nothing.
  expect(judge([r('seven_day', 95, 'plugin', 1), r('seven_day', 40, 'peer', 1, NOW - 1)], c).ok).toBe(false)
  // A spend limit keeps its 90 stop, by the same trust rule.
  expect([judge([r('spend_limit', 91, 'plugin', 1), r('spend_limit', 89, 'peer', 1)], c).rule, judge([r('spend_limit', 91, 'plugin', 1)], c).rule]).toEqual(['split', 'spend-90'])
})

test('AT-LM-10: the band holds when no fresh reading is under 90 and one is in the band; its reset is the latest of the readings that hold; a reading whose reset is over an hour from the others\' is an anomaly, still counted', () => {
  const R = NOW + 30 * MIN
  const v = judge([r('five_hour', 93, 'plugin', 1, R), r('five_hour', 99, 'peer', 2, R + 20 * MIN)], C)
  expect([v.ok, v.band, v.rule, v.reset, v.usage.usage_anomaly]).toEqual([true, true, 'band', R + 20 * MIN, undefined])
  const a = judge([r('seven_day', 95, 'plugin', 1, R), r('seven_day', 40, 'peer', 2, R + 5 * 60 * MIN), r('seven_day', 41, 'peer', 2, R + 10 * MIN, 'cccccccc')], { ...C, job: false })
  expect([a.ok, a.rule, a.usage.usage_anomaly]).toEqual([true, 'split', ['seven_day:peer']])
  // Two readings that differ: both are marked (neither can be told the odd one).
  expect(judge([r('seven_day', 95, 'plugin', 1, R), r('seven_day', 40, 'peer', 2, R + 3 * 60 * MIN)], C).usage.usage_anomaly).toEqual(['seven_day:plugin', 'seven_day:peer'])
  expect(resetOf([w('five_hour', 99, R)], C)).toBe(R)
})

test('AT-LM-11: recordReadings: the session\'s own plugin entries are left out, its status line\'s are its own, every other session\'s a peer\'s; seconds become ms; an entry out of form is dropped', () => {
  const sid = '5e55a001-0c0f-4f1e-9a00-00000000a001'
  const e = (o: Record<string, unknown>) => ({ kind: 'seven_day', pct: 40, resets_at: 1794492000, at: 1794225600.5, src: 'plugin', sid8: '5e55a002', ...o })
  expect(recordReadings([e({ sid8: '5e55a001' }), e({ sid8: '5e55a001', src: 'statusline' }), e({}), e({ resets_at: null, src: 'statusline' }), e({ pct: 'x' }), e({ kind: '' }), e({ src: 'other' }), e({ at: null }), null, 7], sid)).toEqual([
    { kind: 'seven_day', percentUsed: 40, resetsAt: 1794492000000, at: 1794225600500, src: 'statusline' },
    { kind: 'seven_day', percentUsed: 40, resetsAt: 1794492000000, at: 1794225600500, src: 'peer', sid8: '5e55a002' },
    { kind: 'seven_day', percentUsed: 40, at: 1794225600500, src: 'peer', sid8: '5e55a002' },
  ])
})

test('AT-LM-12: readingsNow writes the own reading and reads the record in one helper call; with no own window it only reads (and with no own entry there, another session\'s reading is none); a failed call leaves the own reading', async () => {
  const sent: (readonly string[])[] = []
  let reply = { ok: true, exitCode: 0, stdout: JSON.stringify({ readings: [{ kind: 'seven_day', pct: 40, resets_at: null, at: NOW / 1000 - 60, src: 'plugin', sid8: '5e55a002' }] }) + '\n', error: '' }
  const state = newState('l')
  state.usageAt = NOW - MIN
  const d = {
    state, helper: '/p/helper', sessionId: async () => 'x',
    run: async (argv: readonly string[]) => { sent.push(argv.slice(1)); return reply },
  } as unknown as Deps
  const rs = await readingsNow(d, '5e55a001-0c0f-4f1e-9a00-00000000a001', [w('seven_day', 95)])
  expect(rs.map(x => [x.kind, x.percentUsed, x.src, x.at])).toEqual([['seven_day', 95, 'plugin', NOW - MIN], ['seven_day', 40, 'peer', NOW - MIN]])
  expect(sent).toEqual([['usage', '--sid', '5e55a001-0c0f-4f1e-9a00-00000000a001', '--stdin']])
  expect(await readingsNow(d, 's', [])).toEqual([])
  expect(sent).toEqual([['usage', '--sid', '5e55a001-0c0f-4f1e-9a00-00000000a001', '--stdin'], ['usage', '--sid', 's']])
  reply = { ok: false, exitCode: 64, stdout: '', error: '' }
  expect((await readingsNow(d, 's', [w('seven_day', 95)])).map(x => x.src)).toEqual(['plugin'])
})

test('AT-LM-13 (review): the session\'s own status line entry is the live reading shown again, so it is never newer than the live reading\'s refresh: a status line run 30 s ago over a reading 54 min old reads 54 min old (no-fresh, not a skip)', () => {
  const sid = '5e55a001-0c0f-4f1e-9a00-00000000a001'
  const own = NOW - 54 * MIN
  const e = (o: Record<string, unknown>) => ({ kind: 'seven_day', pct: 95, resets_at: null, at: (NOW - 30000) / 1000, src: 'statusline', sid8: '5e55a001', ...o })
  expect(recordReadings([e({})], sid, own).map(x => [x.src, x.at])).toEqual([['statusline', own]])
  expect(recordReadings([e({ at: (own - MIN) / 1000 })], sid, own).map(x => x.at)).toEqual([own - MIN])
  // Without the live reading's time, the session's own plugin entry dates it; with neither, it is no reading.
  expect(recordReadings([e({ src: 'plugin', at: own / 1000 }), e({})], sid).map(x => x.at)).toEqual([own])
  expect(recordReadings([e({})], sid)).toEqual([])
  const v = judge([...ownReadings([w('seven_day', 95)], own), ...recordReadings([e({})], sid, own)], { ...C, job: false, usageAt: own })
  expect([v.ok, v.rule, v.usage.usage_n, v.usage.usage_age_s]).toEqual([true, 'no-fresh', { seven_day: 0 }, { seven_day: 54 * 60 }])
})

test('AT-LM-15 (review 2): another session\'s status line entry is never newer than that session\'s plugin entry of the same kind, and one with none is no reading: an entry evicted or pruned from the record and shown again (dated now) over a reading 50 min old reads 50 min old (no-fresh, not a skip)', () => {
  const sid = '5e55a001-0c0f-4f1e-9a00-00000000a001'
  const own = NOW - 55 * MIN - 30000
  const e = (o: Record<string, unknown>) => ({ kind: 'seven_day', pct: 95, resets_at: null, at: (NOW - 30000) / 1000, src: 'statusline', sid8: '5e55a002', ...o })
  const peerAt = NOW - 50 * MIN
  const rec = [e({}), e({ src: 'plugin', at: peerAt / 1000 }), e({ kind: 'five_hour', pct: 12 }), e({ sid8: '5e55a003' })]
  expect(recordReadings(rec, sid, own).map(x => [x.kind, x.sid8, x.at])).toEqual([['seven_day', '5e55a002', peerAt], ['seven_day', '5e55a002', peerAt]])
  // A status line entry older than the plugin entry keeps its own time; one that shows another share is dated no later than it.
  expect(recordReadings([e({ at: (peerAt - MIN) / 1000, pct: 97 }), e({ src: 'plugin', at: peerAt / 1000 })], sid, own).map(x => [x.percentUsed, x.at])).toEqual([[97, peerAt - MIN], [95, peerAt]])
  const v = judge([...ownReadings([w('seven_day', 95)], own), ...recordReadings(rec, sid, own)], { ...C, job: false, usageAt: own })
  expect([v.ok, v.rule, v.usage.usage_n]).toEqual([true, 'no-fresh', { seven_day: 0 }])
})

test('AT-LM-14 (review): a failed record write is not counted as written: the next refresh writes the unchanged reading again at once (noteUsage and readingsNow)', async () => {
  let ok = false
  let calls = 0
  const d = {
    state: newState('l'), helper: '/p/helper',
    usage: async () => ({ tokens: 1, window: 2, rateLimits: [w('seven_day', 21)] }),
    sessionId: async () => '5e55a001-0c0f-4f1e-9a00-00000000a001',
    run: async () => { calls++; return ok ? { ok: true, exitCode: 0, stdout: '{"readings":[]}\n', error: '' } : { ok: false, exitCode: 64, stdout: '', error: '' } },
  } as unknown as Deps
  await noteUsage(d, NOW)
  expect([calls, d.state.usageNote]).toEqual([1, undefined])
  d.state.usageAt = NOW
  await readingsNow(d, '5e55a001-0c0f-4f1e-9a00-00000000a001', [w('seven_day', 21)])
  expect([calls, d.state.usageNote]).toEqual([2, undefined])
  ok = true
  await noteUsage(d, NOW + 1000)
  expect([calls, d.state.usageNote?.at]).toEqual([3, NOW + 1000])
  await noteUsage(d, NOW + 2000)
  expect(calls).toBe(3)
})

test('AT-LM-16 (0.1.9, review): usage writes are throttled: parallel refreshes spawn one helper, a share moving by fractions within a point writes nothing until USAGE_NOTE_MS, a refresh during a write is folded into one check of the newest reading after it, a failed write drops the folded one', async () => {
  let pct = 41.2
  const sent: { at: number; windows: { pct: number }[] }[] = []
  let gate: (() => void) | undefined
  let fail = false
  const d = {
    state: newState('l'), helper: '/p/helper',
    usage: async () => ({ tokens: 1, window: 2, rateLimits: [w('seven_day', pct)] }),
    sessionId: async () => '5e55a001-0c0f-4f1e-9a00-00000000a001',
    run: async (_argv: string[], _ms: number, stdin?: string) => {
      sent.push(JSON.parse(stdin ?? '{}'))
      if (gate === undefined) await new Promise<void>(r => { gate = r })
      return fail ? { ok: false, exitCode: 64, stdout: '', error: '' } : { ok: true, exitCode: 0, stdout: '{"readings":[]}\n', error: '' }
    },
  } as unknown as Deps
  const open = () => { const g = gate; gate = () => undefined; g?.() }
  const settle = async () => { for (let i = 0; i < 20; i++) await Promise.resolve() }
  // 20 subagent responses at once, the share moving by fractions: one helper
  const all = Array.from({ length: 20 }, (_, i) => noteUsage(d, NOW + i))
  await settle()
  pct = 41.9
  await settle()
  open()
  await Promise.all(all)
  expect(sent.map(x => [x.at, x.windows[0]?.pct])).toEqual([[NOW / 1000, 41.2]])
  expect([d.state.usageNote?.at, d.state.usageNoting]).toEqual([NOW, undefined])
  // fractions within the point: nothing; the next point: written at once
  pct = 41.99
  await noteUsage(d, NOW + MIN)
  expect(sent.length).toBe(1)
  pct = 42.1
  await noteUsage(d, NOW + 2 * MIN)
  expect(sent.map(x => x.windows[0]?.pct)).toEqual([41.2, 42.1])
  // unchanged: written again once USAGE_NOTE_MS old, so a skip decision elsewhere reads a fresh entry
  pct = 42.6
  await noteUsage(d, NOW + 2 * MIN + USAGE_NOTE_MS - 1)
  expect(sent.length).toBe(2)
  await noteUsage(d, NOW + 2 * MIN + USAGE_NOTE_MS)
  expect(sent.map(x => [x.at, x.windows[0]?.pct]).slice(2)).toEqual([[(NOW + 2 * MIN + USAGE_NOTE_MS) / 1000, 42.6]])
  // a refresh during a write that moves a point: one more write after it, of the newest reading
  gate = undefined
  pct = 43.2
  const a = noteUsage(d, NOW + 20 * MIN)
  await settle()
  pct = 44.5
  const b = [noteUsage(d, NOW + 20 * MIN + 1), noteUsage(d, NOW + 20 * MIN + 2)]
  open()
  await Promise.all([a, ...b])
  expect(sent.map(x => [x.at, x.windows[0]?.pct]).slice(3)).toEqual([[(NOW + 20 * MIN) / 1000, 43.2], [(NOW + 20 * MIN + 2) / 1000, 44.5]])
  expect(d.state.usageNote?.at).toBe(NOW + 20 * MIN + 2)
  // a failed write: the folded refresh is dropped, the next refresh tries again
  gate = undefined
  fail = true
  pct = 45.5
  const c = noteUsage(d, NOW + 30 * MIN)
  await settle()
  pct = 46.5
  const e = noteUsage(d, NOW + 30 * MIN + 1)
  open()
  await Promise.all([c, e])
  expect([sent.length, d.state.usageNote?.at, d.state.usageNoting]).toEqual([6, NOW + 20 * MIN + 2, undefined])
  fail = false
  await noteUsage(d, NOW + 31 * MIN)
  expect(sent.map(x => x.windows[0]?.pct).slice(6)).toEqual([46.5])
})

// ---- Within a window (a kind and its reset time) the share only grows until the reset, so a
// reading counts until its window resets, however old; the readings of a window are one, its latest.
const DAY = 24 * 60 * MIN

test('D88-01: the live scenario: one seven_day reading at 99, 20 min old, resetting in 3 days, nothing refreshed it: it still counts, so keep-warm and plugin idle compaction stop (rule cap); its age is logged', () => {
  const v = judge([r('seven_day', 99, 'plugin', 20, NOW + 3 * DAY)], C)
  expect([v.ok, v.rule, v.windows, v.usage]).toEqual([false, 'cap', ['seven_day:99'], { usage_src: ['seven_day:plugin'], usage_age_s: { seven_day: 1200 }, usage_n: { seven_day: 1 } }])
  expect(verdictOf([w('seven_day', 99, NOW + 3 * DAY)], { ...C, usageAt: NOW - 20 * MIN }).ok).toBe(false)
  // A reading with no reset time keeps the 10-minute rule.
  expect(judge([r('seven_day', 99, 'plugin', 20)], C).rule).toBe('no-fresh')
})

test('D88-02: a reading whose reset has passed counts for nothing, however recent: a peer at 40 read a minute ago in a window that reset leaves the own 99 (20 min old, resets in 3 days) alone, and with nothing else counted the action runs', () => {
  const R = NOW + 3 * DAY
  expect(judge([r('seven_day', 99, 'plugin', 20, R), r('seven_day', 40, 'peer', 1, NOW - MIN)], C).rule).toBe('cap')
  expect(judge([r('seven_day', 99, 'plugin', 20, NOW - 1)], C)).toMatchObject({ ok: true, rule: '90', usage: { usage_n: {} } })
})

test('D88-03: two windows of one kind (99 resetting in 3 days, 21 resetting in 5, another account behind a proxy), both read 20-30 min before: they differ, so the action runs (split, the window with room named, 2 windows)', () => {
  const v = judge([r('seven_day', 99, 'plugin', 20, NOW + 3 * DAY), r('seven_day', 21, 'peer', 30, NOW + 5 * DAY)], { ...C, job: false })
  expect([v.ok, v.rule, v.windows, v.usage.usage_n, v.usage.usage_anomaly]).toEqual([true, 'split', ['seven_day:21'], { seven_day: 2 }, ['seven_day:plugin', 'seven_day:peer']])
})

test('D88-04: one window\'s readings are one: its latest decides (an older 40, another session\'s 5 min ago, and the own 99 a minute ago: stop; the other way round: run); resets within a minute are one window, two minutes apart two', () => {
  const R = NOW + 3 * DAY
  const v = judge([r('seven_day', 40, 'peer', 5, R), r('seven_day', 99, 'plugin', 1, R + 30000)], { ...C, job: false })
  expect([v.ok, v.rule, v.windows, v.usage.usage_n]).toEqual([false, 'cap', ['seven_day:99'], { seven_day: 1 }])
  expect(judge([r('seven_day', 99, 'plugin', 5, R), r('seven_day', 40, 'peer', 1, R)], C)).toMatchObject({ ok: true, rule: '90', windows: ['seven_day:40'] })
  expect(judge([r('seven_day', 40, 'peer', 5, R), r('seven_day', 99, 'plugin', 1, R + 2 * MIN)], C)).toMatchObject({ ok: true, rule: 'split' })
  // The keep-warm wait: every window that stops resets by the latest of them.
  expect(judge([r('five_hour', 99, 'plugin', 20, NOW + 30 * MIN), r('five_hour', 97, 'peer', 2, NOW + 90 * MIN)], C).reset).toBe(NOW + 90 * MIN)
})

test('D88-05 (the earlier rule kept): going above 90 still needs a fresh reading: a job open and a measured change that fits, at 92 read 20 min before (resets in 3 days): stop (rule stale); read 5 min before: the band', () => {
  const R = NOW + 3 * DAY
  expect(judge([r('seven_day', 92, 'plugin', 20, R)], C)).toMatchObject({ ok: false, band: false, rule: 'stale' })
  expect(judge([r('seven_day', 92, 'plugin', 5, R)], C)).toMatchObject({ ok: true, band: true, rule: 'band', reset: R })
})

test('D88-06: no own window (a load that adopted the session before its first response): the session\'s own record entries stand for the live reading and count until their reset, the other sessions\' beside them; the window\'s latest decides; with no own entry, none', async () => {
  const sid = '5e55a001-0c0f-4f1e-9a00-00000000a001'
  const R = (NOW + 3 * DAY) / 1000
  let rec: Record<string, unknown>[] = []
  const d = {
    state: newState('l'), helper: '/p/helper', sessionId: async () => sid,
    run: async () => ({ ok: true, exitCode: 0, stdout: JSON.stringify({ readings: rec }) + '\n', error: '' }),
  } as unknown as Deps
  const e = (o: Record<string, unknown>) => ({ kind: 'seven_day', pct: 99, resets_at: R, at: (NOW - 50 * MIN) / 1000, src: 'plugin', sid8: '5e55a001', ...o })
  rec = [e({}), e({ src: 'statusline', at: (NOW - MIN) / 1000 }), e({ sid8: '5e55a002', pct: 40, at: (NOW - 70 * MIN) / 1000 })]
  const rs = await readingsNow(d, sid, [])
  expect(rs.map(x => [x.src, x.percentUsed, x.at])).toEqual([['plugin', 99, NOW - 50 * MIN], ['statusline', 99, NOW - 50 * MIN], ['peer', 40, NOW - 70 * MIN]])
  expect(judge(rs, C)).toMatchObject({ ok: false, rule: 'cap', windows: ['seven_day:99'], usage: { usage_src: ['seven_day:plugin'], usage_n: { seven_day: 1 } } })
  rec = [e({ sid8: '5e55a002' })]
  expect(await readingsNow(d, sid, [])).toEqual([])
})

test('D88-07: a session\'s reading with no reset time beside its own reading of that kind with one is the same reading (one Claude Code object): not a window of its own, so an older lower share cannot split it', () => {
  const R = NOW + 3 * DAY
  const v = judge([r('seven_day', 99, 'plugin', 20, R), r('seven_day', 40, 'statusline', 5)], { ...C, job: false })
  expect([v.ok, v.rule, v.usage.usage_n]).toEqual([false, 'cap', { seven_day: 1 }])
})

test('D88-15 (review 3): own windows of unknown time (a plugin reload in the idle gap: the engine still reports the last response\'s windows, the load has not stamped them): the session\'s own record entries are read beside them, dated, so a lower share from another session read earlier does not decide; with no own entry the live share stands, being the larger (the share only grows until the reset)', async () => {
  const sid = '5e55a001-0c0f-4f1e-9a00-00000000a001'
  const R = (NOW + 3 * DAY) / 1000
  let rec: Record<string, unknown>[] = []
  const d = {
    state: newState('l'), helper: '/p/helper', sessionId: async () => sid,
    run: async () => ({ ok: true, exitCode: 0, stdout: JSON.stringify({ readings: rec }) + '\n', error: '' }),
  } as unknown as Deps
  const e = (o: Record<string, unknown>) => ({ kind: 'seven_day', pct: 99, resets_at: R, at: (NOW - 50 * MIN) / 1000, src: 'plugin', sid8: '5e55a001', ...o })
  const live = [w('seven_day', 99, NOW + 3 * DAY)]
  rec = [e({}), e({ sid8: '5e55a002', pct: 40, at: (NOW - 70 * MIN) / 1000 })]
  const rs = await readingsNow(d, sid, live)
  expect(rs.map(x => [x.src, x.percentUsed, x.at])).toEqual([['plugin', 99, undefined], ['plugin', 99, NOW - 50 * MIN], ['peer', 40, NOW - 70 * MIN]])
  expect(judge(rs, { ...C, job: false, usageAt: undefined })).toMatchObject({ ok: false, rule: 'cap', windows: ['seven_day:99'], usage: { usage_age_s: { seven_day: 3000 }, usage_n: { seven_day: 1 } } })
  rec = [e({ sid8: '5e55a002', pct: 40, at: (NOW - 70 * MIN) / 1000 })]
  expect(judge(await readingsNow(d, sid, live), { ...C, job: false, usageAt: undefined })).toMatchObject({ ok: false, rule: 'cap', windows: ['seven_day:99'] })
  // A live share below a dated one of the same window was read before it: the dated one decides.
  rec = [e({ sid8: '5e55a002', at: (NOW - 70 * MIN) / 1000 })]
  expect(judge(await readingsNow(d, sid, [w('seven_day', 30, NOW + 3 * DAY)]), { ...C, job: false, usageAt: undefined })).toMatchObject({ ok: false, rule: 'cap', windows: ['seven_day:99'] })
})

test('D88-16 (review 3): a reading dated more than a minute ahead (a clock that stepped back) has no known time, so it is not the latest of its window over a larger share: the own 99 read a minute ago and another session\'s 40 dated 4 min ahead stop (cap); one dated 30 s ahead is read as now, the latest: it runs', () => {
  const R = NOW + 3 * DAY
  expect(judge([r('seven_day', 99, 'plugin', 1, R), r('seven_day', 40, 'peer', -4, R)], { ...C, job: false })).toMatchObject({ ok: false, rule: 'cap', windows: ['seven_day:99'] })
  expect(judge([r('seven_day', 99, 'plugin', 1, R), r('seven_day', 40, 'peer', -0.5, R)], { ...C, job: false })).toMatchObject({ ok: true, rule: '90', windows: ['seven_day:40'] })
})
