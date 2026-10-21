// U tests of the pure libs: nonce (AT-C-01), detector (AT-C-02), assembler budgets (AT-P-07),
// clamp (AT-P-03/04 arithmetic), the run-time brand in the marker (BT-01 U part), sha256.
import { describe, expect, test } from 'claude-code/testing'
import { ASSET_NAMES, assetText } from '../../hooks/lib/assets.gen'
import type { Tag } from '../../hooks/lib/assemble'
import { assembleText, leftovers } from '../../hooks/lib/assemble'
import { DEFAULTS, clamp } from '../../hooks/lib/config'
import { CLOSE, OPEN, detectSummary, lastInstrMarker, markerText, sentinelText, specValue } from '../../hooks/lib/detect'
import { drawNonce, randomHex } from '../../hooks/lib/nonce'
import { byteLength, sha256, strip } from '../../hooks/lib/normalize'
import { endsWithQuestion } from '../../hooks/lib/boundary'
import { formatTokens, tempPaths } from '../../hooks/lib/nudge'

const NAME = 'x'.repeat(14)

describe('AT-C-01 nonce', () => {
  test('10,000 draws: all 8 lowercase hex, no repeat; a colliding draw is replaced', async () => {
    const records = new Set<string>()
    for (let i = 0; i < 10000; i++) {
      const n = await drawNonce(async x => records.has(x))
      expect(/^[0-9a-f]{8}$/.test(n)).toBe(true)
      expect(records.has(n)).toBe(false)
      records.add(n)
    }
    expect(records.size).toBe(10000)
    const draws = ['1a2b3c4d', '5e6f7a8b']
    const seen: string[] = []
    const n = await drawNonce(async x => {
      seen.push(x)
      return x === '1a2b3c4d'
    }, () => draws.shift() ?? randomHex(8))
    expect(n).toBe('5e6f7a8b')
    expect(seen[0]).toBe('1a2b3c4d')
  })
})

describe('AT-C-02 detector', () => {
  const P = 'zz-detect-probe'
  const n = '1a2b3c4d'
  const marker = markerText(P, n, 'main')
  const sentinel = sentinelText(P, n)
  const body = `${marker}\n# LAB-42 — retry in progress\n## Resume here\nStatus: active\n${sentinel}`

  test('(a) wrapper lines then the marker: found on line 1', () => {
    const raw = 'This session is being continued from a previous conversation that ran out of context.\n\n' +
      '<tools-used-before-summary>\nBash, Read\n</tools-used-before-summary>\n\nSummary:\n<summary>\n' + body + '\n</summary>'
    const d = detectSummary(raw, P, { dispatchNonce: n, scope: 'main' })
    expect(d.marker_line).toBe(1)
    expect(d.verdict).toBe('ok')
  })
  test('(b) marker on body line 6: not found', () => {
    const d = detectSummary('a\nb\nc\nd\ne\n' + body, P)
    expect(d.marker_line).toBeNull()
    expect(d.verdict).toBe('unshaped')
  })
  test('(c) marker at byte 0, no wrapper: found', () => {
    const d = detectSummary(body, P)
    expect(d.marker_line).toBe(1)
    expect(d.verdict).toBe('ok')
  })
  test("(d) another plugin's header line only: not ours, unshaped", () => {
    const d = detectSummary(markerText('otherplug', n, 'main') + '\n# x\n' + sentinelText('otherplug', n), P)
    expect(d.nonce).toBeNull()
    expect(d.verdict).toBe('unshaped')
  })
  test('(e) sentinel followed by </summary> and blank lines: ok', () => {
    const d = detectSummary('<summary>\n' + body + '\n</summary>\n\n\n', P, { dispatchNonce: n })
    expect(d.sentinel_from_end).toBe(1)
    expect(d.verdict).toBe('ok')
  })
  test('(f) text after the sentinel: ok-trailer', () => {
    const d = detectSummary(body + '\nOne more note.', P, { dispatchNonce: n })
    expect(d.sentinel_from_end).toBe(2)
    expect(d.verdict).toBe('ok-trailer')
  })
  test('the rest of the verdict table: truncated, stale, scope-leak', () => {
    expect(detectSummary(`${marker}\n# t\n## Resume here`, P).verdict).toBe('truncated')
    expect(detectSummary(body, P, { dispatchNonce: '99999999' }).verdict).toBe('stale')
    expect(detectSummary(body, P, { noDispatch: true }).verdict).toBe('stale')
    expect(detectSummary(body, P, { precomputed: true }).verdict).toBe('stale')
    expect(detectSummary(body, P, { dispatchNonce: n, scope: 'sub' }).verdict).toBe('scope-leak')
    expect(detectSummary('# t\n## Resume here\nx', P, { scope: 'sub' }).verdict).toBe('scope-leak')
    const sub = markerText(P, n, 'sub') + '\n## Task as assigned: x\n' + sentinel
    expect(detectSummary(sub, P, { dispatchNonce: n, scope: 'main' }).verdict).toBe('scope-leak')
    expect(detectSummary(sub, P, { dispatchNonce: n, scope: 'sub' }).verdict).toBe('ok')
  })
  test('AT-C-09 (TS side): PostCompact and installed-message forms give one normalized body and sha256', () => {
    const post = '<summary>\n' + body + '\n</summary>'
    const mod = 'This session is being continued from a previous conversation.\n\n<tools-used-before-summary>\nBash\n</tools-used-before-summary>\nSummary:\n<summary>\n' + body + '\n</summary>\n'
    expect(strip(post).body).toBe(strip(mod).body)
    expect(detectSummary(post, P).sha256).toBe(detectSummary(mod, P).sha256)
    expect(strip(post).body.endsWith(sentinel + '\n')).toBe(true)
  })
  test('instruction marker: unanchored, the last match counts', () => {
    const t = 'note ' + markerText(P, 'deadbeef', 'main') + ' then\nFirst line inside <summary>: ' + markerText(P, n, 'main')
    expect(lastInstrMarker(t, P)).toEqual({ nonce: n, scope: 'main' })
    expect(lastInstrMarker('no marker', P)).toBeUndefined()
    expect(lastInstrMarker(markerText(P, n, 'manual'), P)).toBeUndefined()
  })
})

const PREV = '~/.claude/handoffs/example-repo/LAB-123/' + 'p'.repeat(141 - '~/.claude/handoffs/example-repo/LAB-123/'.length)
const WORST = {
  nonce: 'a1b2c3d4', previous_copy: PREV, measured_at: '2026-10-21T04:40:00+03:00', session_id: '00000000-0000-4000-8000-000000000000',
  saved_copy: PREV, tokens: '612,345', queue_add: 'queue-cmd add --lane example-repo/LAB-123', measured_facts: '', remeasure: '',
}
const BLANK = Object.fromEntries(Object.keys(WORST).map(k => [k, '']))
const TAGS: Record<string, Tag[]> = {
  'handoff-instructions': ['midturn', 'auto', 'chain', 'measured'],
  'subagent-instructions': ['fallback'],
  'resume-context': ['midturn', 'nonok'],
  'checkpoint-nudge': ['continue', 'halt', 'queue'],
}

function combos(tags: Tag[]): Tag[][] {
  const out: Tag[][] = [[]]
  for (const t of tags) for (const c of [...out]) out.push([...c, t])
  return out
}

describe('AT-P-07 assembler (14-character name)', () => {
  const text = (a: (typeof ASSET_NAMES)[number]) => assetText(a, NAME)

  test('every asset, every tag combination: no [tag] line, @name@, brace token or review comment survives', () => {
    for (const a of ASSET_NAMES) {
      for (const tags of combos(TAGS[a] ?? [])) {
        const s = assembleText(text(a), tags, WORST)
        expect(leftovers(s)).toEqual([])
        expect(s.endsWith('\n')).toBe(true)
      }
    }
  })
  test('main static core ≤4,000 chars on every mod and classic path', () => {
    for (const tags of [[], ['midturn'], ['chain'], ['midturn', 'chain'], ['auto'], ['auto', 'chain']] as Tag[][]) {
      const core = assembleText(text('handoff-instructions'), tags, BLANK, ['measured'])
      expect(core.length <= 4000).toBe(true)
    }
  })
  test('classic fallback (main [auto]+[chain] + subagent [fallback]) ≤8,192 B', () => {
    const s = assembleText(text('handoff-instructions'), ['auto', 'chain'], WORST, ['measured']) + assembleText(text('subagent-instructions'), ['fallback'], WORST)
    expect(byteLength(s) <= 8192).toBe(true)
  })
  test('mod main [midturn]+[chain]+[measured] with a full 3,000 B block ≤8,192 B', () => {
    const s = assembleText(text('handoff-instructions'), ['midturn', 'chain', 'measured'], { ...WORST, measured_facts: 'x'.repeat(3000) })
    expect(byteLength(s) <= 8192).toBe(true)
  })
  test('resume protocol ≤2,000 chars for every tag combination', () => {
    for (const tags of combos(['midturn', 'nonok'])) {
      const s = assembleText(text('resume-context'), tags, WORST, ['measured_at', 'remeasure'])
      expect(s.length <= 2000).toBe(true)
    }
  })
  test('the queue tag is never applied (D-10)', () => {
    const s = assembleText(text('checkpoint-nudge'), ['continue', 'queue'], WORST)
    expect(s).toBe(assembleText(text('checkpoint-nudge'), ['continue'], WORST))
  })
  test('heading literals equal the spec-literals block (skipped until handoff-spec.md exists)', () => {
    const heads = specValue('sections_main')
    if (!Array.isArray(heads)) return
    const lines = assembleText(text('handoff-instructions'), ['chain'], WORST).split('\n').filter(l => l.startsWith('#'))
    let last = -1
    for (const h of heads as string[]) {
      const at = lines.findIndex(l => l.startsWith(h))
      expect(at).toBeGreaterThan(last)
      last = at
    }
  })
})

test('BT-01 (U part): the marker in assets.gen.ts takes the run-time plugin name', () => {
  const t = assetText('handoff-instructions', 'zz-rename-probe')
  expect(t).toContain(OPEN + 'zz-rename-probe v1 n=@nonce@ s=main' + CLOSE)
  expect(t).toContain(OPEN + '/zz-rename-probe n=@nonce@' + CLOSE)
  expect(assetText('subagent-instructions', 'q')).toContain(OPEN + 'q v1 n=@nonce@ s=sub' + CLOSE)
})

test('clamp arithmetic: AT-P-03 and AT-P-04', () => {
  const p3 = clamp({ ...DEFAULTS, compact_soft_max_tokens: 900000, native_window_tokens: 800000 }, 1000000)
  expect([p3.soft_max, p3.target, p3.disabled]).toEqual([640000, 400000, null])
  expect(p3.clamped).toEqual([{ key: 'soft_max', configured: 900000, effective: 640000 }])
  const p4 = clamp(DEFAULTS, 200000)
  expect([p4.soft_max, p4.target, p4.disabled]).toEqual([67000, 44666, 'trigger-disabled-small-window'])
  const off = clamp({ ...DEFAULTS, triggers: false }, 1000000)
  expect([off.disabled, off.clamped]).toEqual(['triggers-off', []])
  const small = clamp(DEFAULTS, 350000)
  expect(small.disabled).toBeNull()
})

test('sha256 of known vectors', () => {
  expect(sha256('')).toBe('e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855')
  expect(sha256('abc')).toBe('ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad')
  expect(sha256(OPEN + 'x' + CLOSE + ' é')).toBe('99d8cf184eeb3db97df1f55a5e1312a85c348074d1f5d516793b97a95bc8d12f')
})

test('small helpers: token format, question end, temp paths', () => {
  expect(formatTokens(612345)).toBe('612,345')
  expect(formatTokens(1000000)).toBe('1,000,000')
  expect(endsWithQuestion('All green.\n\nShould I push now?\n')).toBe(true)
  expect(endsWithQuestion('Is it? Yes.')).toBe(false)
  expect(tempPaths({ command: 'cat /tmp/a.log | wc; ls /private/tmp/b/c.txt', file_path: '/var/folders/x1/T/out.json' })).toEqual([
    '/tmp/a.log', '/private/tmp/b/c.txt', '/var/folders/x1/T/out.json',
  ])
  expect(tempPaths({ command: 'cat repo/src/main.ts' })).toEqual([])
})
