// U tests: the usage-limit rule of keep-warm and plugin idle compaction (D-80, limits.ts). Test ids
// AT-LM-nn. Synthetic values only.
import { expect, test } from 'claude-code/testing'
import type { Deps } from '../../hooks/lib/deps'
import type { LimitCtx } from '../../hooks/lib/limits'
import { LIMIT_DELTAS_KEY, LIMIT_FRESH_MS, PLAN_CAPS, USAGE_NOTE_MS, noteUsage, ownReadings, planShares, readDeltas, recordDeltas, resetOf, usageFields, verdictOf, windowRule } from '../../hooks/lib/limits'
import { newState } from '../../hooks/lib/deps'
import { resultJobOpen } from '../../hooks/lib/keepwarm'

const NOW = 1792580712000
const MIN = 60000
const C: LimitCtx = { job: true, usageAt: NOW - 5 * MIN, now: NOW, deltas: { five_hour: [1, 2], seven_day: [1] } }
const w = (kind: string, percentUsed: number, resetsAt?: number) => ({ kind, percentUsed, ...(resetsAt !== undefined ? { resetsAt } : {}) })
/** D-83: the own reading's source and age (`C.usageAt`: 5 min) of these window kinds. */
const U = (...kinds: string[]) => ({ usage_src: kinds.map(k => `${k}:plugin`), usage_age_s: Object.fromEntries(kinds.map(k => [k, 300])) })

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

test('AT-LM-07 (D-83): noteUsage writes the own reading to the shared record (helper usage --stdin, epoch seconds), again only once it changed or 5 min passed; no window, no write', async () => {
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

test('AT-LM-08 (D-83): usageFields names each window\'s source (kind:source, in order) and its age in whole seconds; a window with no known time has no age, one with no kind reads unknown', () => {
  const rs = [...ownReadings([w('five_hour', 44), w('', 3)], NOW - 61499), { ...w('seven_day', 21), at: undefined, src: 'peer' as const }]
  expect(usageFields(rs, NOW)).toEqual({ usage_src: ['five_hour:plugin', 'unknown:plugin', 'seven_day:peer'], usage_age_s: { five_hour: 61, unknown: 61 } })
  expect(verdictOf([w('five_hour', 93)], { ...C, job: false }).usage).toEqual(U('five_hour'))
  expect(verdictOf([w('five_hour', 93)], { ...C, usageAt: undefined }).usage).toEqual({ usage_src: ['five_hour:plugin'], usage_age_s: {} })
})
