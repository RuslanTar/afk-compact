// U tests: the usage-limit rule of keep-warm and plugin idle compaction (D-80, limits.ts). Test ids
// AT-LM-nn. Synthetic values only.
import { expect, test } from 'claude-code/testing'
import type { Deps } from '../../hooks/lib/deps'
import type { LimitCtx } from '../../hooks/lib/limits'
import { LIMIT_DELTAS_KEY, LIMIT_FRESH_MS, PLAN_CAPS, planShares, readDeltas, recordDeltas, resetOf, verdictOf, windowRule } from '../../hooks/lib/limits'
import { newState } from '../../hooks/lib/deps'

const NOW = 1792580712000
const MIN = 60000
const C: LimitCtx = { job: true, usageAt: NOW - 5 * MIN, now: NOW, deltas: { five_hour: [1, 2], seven_day: [1] } }
const w = (kind: string, percentUsed: number, resetsAt?: number) => ({ kind, percentUsed, ...(resetsAt !== undefined ? { resetsAt } : {}) })

test('AT-LM-01: below 90 every window is ok; the caps are 98 (five_hour) and 95 (seven_day)', () => {
  expect(PLAN_CAPS).toEqual({ five_hour: 98, seven_day: 95 })
  expect(LIMIT_FRESH_MS).toBe(10 * MIN)
  expect(verdictOf([w('five_hour', 89.9), w('seven_day', 40), w('spend_limit', 89)], C)).toEqual({ ok: true, band: false, rule: '90', windows: ['five_hour:89', 'seven_day:40', 'spend_limit:89'] })
  expect(verdictOf([], C)).toEqual({ ok: true, band: false, rule: '90', windows: [] })
})

test('AT-LM-02: a plan window above 90 runs on in the band only with a job open, a fresh reading and a measured change that fits below the cap', () => {
  // 93 + 2 + 1 < 98
  expect(verdictOf([w('five_hour', 93), w('seven_day', 40)], C)).toEqual({ ok: true, band: true, rule: 'band', windows: ['five_hour:93', 'seven_day:40'] })
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
  expect(verdictOf([w('five_hour', 93), w('spend_limit', 91)], C)).toEqual({ ok: false, band: false, rule: 'spend-90', windows: ['five_hour:93', 'spend_limit:91'] })
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
