// U tests of the pure libs: nonce (AT-C-01), detector (AT-C-02), assembler budgets (AT-P-07,
// D-17/DP-8 table), clamp (AT-P-03/04/15/16 arithmetic), the run-time brand in the marker
// (BT-01 U part), sha256.
import { describe, expect, test } from 'claude-code/testing'
import { ASSET_NAMES, assetText } from '../../hooks/lib/assets.gen'
import type { Tag } from '../../hooks/lib/assemble'
import { assembleText, leftovers } from '../../hooks/lib/assemble'
import { CLAMP_DEFAULTS, DEFAULTS, clamp, clampConstants, minWindow, parseOptions } from '../../hooks/lib/config'
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
  saved_copy: PREV, tokens: '612,345', queue_add: NAME + '-store queue-add --sid 00000000-0000-4000-8000-000000000000 --nonce a1b2c3d4',
  measured_facts: '', remeasure: '', halt_reason: 'compactions keep repeating without progress', max_calls: '34', handoff_path: PREV,
  draft_state: 'present', handoff_finish: '`' + NAME + "-store publish --stage '" + PREV + "' --slug lab-123-retry --status in-progress`",
}
const BLANK = Object.fromEntries(Object.keys(WORST).map(k => [k, '']))
const TAGS: Record<string, Tag[]> = {
  'handoff-instructions': ['midturn', 'auto', 'chain', 'handoff', 'measured'],
  'subagent-instructions': ['fallback'],
  'resume-context': ['midturn', 'nonok', 'handoff', 'handoff-partial'],
  'checkpoint-nudge': ['continue', 'halt', 'halt-handoff', 'queue'],
  'handoff-turn': ['submit', 'near', 'spent', 'imminent'],
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
  // D-17: the static core has a soft 4,500-char target only (tools/assemble prints ADVISORY);
  // the hard guard is the channel total below, with the D-18 `[handoff]` line included.
  test('mod main [midturn]+[chain]+[handoff]+[measured] with a full 3,000 B block ≤8,192 B (the hard channel total)', () => {
    const s = assembleText(text('handoff-instructions'), ['midturn', 'chain', 'handoff', 'measured'], { ...WORST, measured_facts: 'x'.repeat(3000) })
    expect(byteLength(s) <= 8192).toBe(true)
  })
  test('classic fallback (main [auto]+[chain] + subagent [fallback]) ≤8,192 B', () => {
    const s = assembleText(text('handoff-instructions'), ['auto', 'chain'], WORST, ['measured']) + assembleText(text('subagent-instructions'), ['fallback'], WORST)
    expect(byteLength(s) <= 8192).toBe(true)
  })
  test('mod main [midturn]+[chain]+[measured] with a full 3,000 B block ≤8,192 B', () => {
    const s = assembleText(text('handoff-instructions'), ['midturn', 'chain', 'measured'], { ...WORST, measured_facts: 'x'.repeat(3000) })
    expect(byteLength(s) <= 8192).toBe(true)
  })
  test('resume protocol ≤2,500 chars (DP-8 hard; ADVISORY above 2,000) for every tag combination the mod builds', () => {
    // `[handoff]` and `[handoff-partial]` never come together (MOD-SPEC §3.4).
    for (const tags of combos(['midturn', 'nonok', 'handoff', 'handoff-partial']).filter(t => !(t.includes('handoff') && t.includes('handoff-partial')))) {
      const s = assembleText(text('resume-context'), tags, WORST, ['measured_at', 'remeasure'])
      expect(s.length <= 2500).toBe(true)
    }
  })
  test('the queue tag is applied when given (D-10: the mod gives it only with queue_cmd set)', () => {
    const t = text('checkpoint-nudge')
    const s = assembleText(t, ['continue', 'queue'], WORST)
    const without = assembleText(t, ['continue'], WORST)
    if (t.includes('\n[queue] ')) {
      expect(s).not.toBe(without)
      if (t.includes('@queue_add@')) expect(s).toContain(WORST.queue_add)
    } else expect(s).toBe(without)
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
  expect([p4.soft_max, p4.target, p4.disabled]).toEqual([51000, 34000, 'trigger-disabled-small-window'])
  const off = clamp({ ...DEFAULTS, triggers: false }, 1000000)
  expect([off.disabled, off.clamped, off.small_window]).toEqual(['triggers-off', [], false])
  const small = clamp(DEFAULTS, 350000)
  expect(small.disabled).toBeNull()
})

test('AT-P-15: clamp at windows 329000 and 328999, defaults: enabled (target 120000) / disabled', () => {
  const on = clamp(DEFAULTS, 329000)
  expect([on.soft_max, on.target, on.disabled]).toEqual([180000, 120000, null])
  const off = clamp(DEFAULTS, 328999)
  expect(off.disabled).toBe('trigger-disabled-small-window')
})

// AT-P-16's "off → 567000" is N − 100,000; the same §1.2 formula's floor(0.8 × window) = 560,000
// binds first, so the off value is 560000 (needs/mod-escalations.md E-M-2).
test('AT-P-16: window 700000: soft max 551000 + clamped; handoff_turn off: 560000 (reserve 52,000 + allowance, else 100,000)', () => {
  const on = clamp(DEFAULTS, 700000)
  expect(on.soft_max).toBe(551000)
  expect(on.clamped).toEqual([{ key: 'soft_max', configured: 600000, effective: 551000 }, { key: 'target', configured: 400000, effective: 367333 }])
  expect(clamp({ ...DEFAULTS, handoff_turn: 'off' }, 700000).soft_max).toBe(560000)
  expect(clamp({ ...DEFAULTS, handoff_turn: 'off' }, 720000).soft_max).toBe(576000)
  expect(clamp({ ...DEFAULTS, handoff_turn: 'off', native_window_tokens: 640000 }, 1000000).soft_max).toBe(507000)
  expect(clamp(DEFAULTS, 800000).soft_max).toBe(600000)
  expect(clamp({ ...DEFAULTS, handoff_turn_max_tokens: 150000 }, 800000).soft_max).toBe(565000)
})

test('handoff_turn / handoff_turn_max_tokens / queue_cmd options: validation, clamp, notes', () => {
  const a = parseOptions({ handoff_turn: ' OFF ', handoff_turn_max_tokens: 5000, queue_cmd: '/q/bin/queue' })
  expect([a.handoff_turn, a.handoff_turn_max_tokens, a.queue_cmd]).toEqual(['off', 20000, '/q/bin/queue'])
  expect(a.notes).toEqual({ invalid: [], clamped: [{ key: 'handoff_turn_max_tokens', configured: 5000, effective: 20000 }] })
  const b = parseOptions({ handoff_turn: 'fork', handoff_turn_max_tokens: '900000' })
  expect([b.handoff_turn, b.handoff_turn_max_tokens]).toEqual(['halt', 150000])
  expect(b.notes.invalid).toEqual(['handoff_turn'])
  const c = parseOptions({ handoff_turn: '${user_config.handoff_turn}', queue_cmd: '' })
  expect([c.handoff_turn, c.handoff_turn_max_tokens, c.queue_cmd, c.notes]).toEqual(['halt', 64000, '', { invalid: [], clamped: [] }])
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

test('RRP-08 temp paths: a temp root counts only at a path start; a URL path, query or fragment is never recorded', () => {
  expect(tempPaths({ url: 'https://bucket.s3.example.invalid/tmp/upload.zip?X-Amz-Credential=abc%2F20261021' })).toEqual([])
  expect(tempPaths({ command: 'curl -s https://api.example.invalid/v1/tmp/export?access_token=abc -o out.json' })).toEqual([])
  expect(tempPaths({ command: 'open https://h.example.invalid/x/scratchpad/notes.md#top' })).toEqual([])
  expect(tempPaths({ command: 'cat /tmp/report.txt?raw=1 /tmp/page.html#part' })).toEqual(['/tmp/report.txt', '/tmp/page.html'])
  expect(tempPaths({ command: 'X=/tmp/a.log; cat "/tmp/b.log" `cat /tmp/c.log` $(ls /private/var/folders/x1/T/d.log) >/tmp/e.log' })).toEqual([
    '/tmp/a.log', '/tmp/b.log', '/tmp/c.log', '/private/var/folders/x1/T/d.log', '/tmp/e.log',
  ])
})

test('detector: an s=sub marker with the main Resume here heading in a subagent-proven compaction is scope-leak (MOD-SPEC 5.1, corpus 41)', () => {
  const name = 'x'.repeat(14)
  const text = '<summary>\n' + markerText(name, '5e6f7081', 'sub') + '\n## Task as assigned\nfind callers\n## Resume here\nStatus: active\n' +
    sentinelText(name, '5e6f7081') + '\n</summary>'
  expect(detectSummary(text, name, { dispatchNonce: '5e6f7081', scope: 'sub' }).verdict).toBe('scope-leak')
  expect(detectSummary(text, name, { dispatchNonce: '5e6f7081', scope: 'main' }).verdict).toBe('scope-leak')
  const noHeading = text.replace('## Resume here\nStatus: active\n', '')
  expect(detectSummary(noHeading, name, { dispatchNonce: '5e6f7081', scope: 'sub' }).verdict).toBe('ok')
})

// P5-FOLD A3 (MOD-SPEC §1.2 effective thresholds): small-window diagnostics.
test('AT-P5-07: clamp diagnostics: raw negative values, min_window, triggers off computes the clamp, the 100,000 window floor', () => {
  const tiny = clamp(DEFAULTS, 100000)
  expect([tiny.disabled, tiny.soft_max, tiny.target, tiny.small_window, tiny.min_window]).toEqual(['trigger-disabled-small-window', -49000, -32667, true, 329000])
  const off = clamp({ ...DEFAULTS, triggers: false }, 100000)
  expect([off.disabled, off.small_window, off.min_window]).toEqual(['triggers-off', true, 329000])
  expect(off.clamped.map(c => c.key)).toEqual(['soft_max', 'target'])
  const floor = parseOptions({ native_window_tokens: 50000 })
  expect([floor.native_window_tokens, floor.notes.clamped]).toEqual([100000, [{ key: 'native_window_tokens', configured: 50000, effective: 100000 }]])
  expect(parseOptions({ native_window_tokens: 0 }).native_window_tokens).toBe(0)
  expect(parseOptions({ native_window_tokens: 100000 }).notes.clamped).toEqual([])
  expect(minWindow({ ...DEFAULTS, handoff_turn: 'off' })).toBe(313000)
  expect(minWindow({ ...DEFAULTS, compact_target_tokens: 100000 })).toBe('never')
  expect(minWindow({ ...DEFAULTS, compact_soft_max_tokens: 170000 })).toBe('never')
  // min_window is the edge: enabled there, disabled one token below.
  expect([clamp(DEFAULTS, 329000).disabled, clamp(DEFAULTS, 328999).disabled]).toEqual([null, 'trigger-disabled-small-window'])
  const ho = { ...DEFAULTS, handoff_turn: 'off' as const }
  expect([clamp(ho, 313000).disabled, clamp(ho, 312999).disabled]).toEqual([null, 'trigger-disabled-small-window'])
})

test('clamp constants: one shared source (the spec-literals clamp object when complete), else the built-in values', () => {
  expect(CLAMP_DEFAULTS).toEqual({ native_offset: 33000, min_target: 120000, reserve_base: 52000, reserve_no_handoff: 100000, window_floor: 100000 })
  expect(clampConstants(undefined)).toEqual(CLAMP_DEFAULTS)
  expect(clampConstants({ native_offset: 33000 })).toEqual(CLAMP_DEFAULTS)
  const shipped = specValue('clamp')
  if (shipped !== undefined) expect(clampConstants(shipped)).toEqual(CLAMP_DEFAULTS)
})

// S-SETTINGS A, D; IC-1 config keys; MOD-SPEC §1.2.
test('MOD-02 options: cap default 6; precompact_turn, unattended_prod_reads, idle_handoff_turn (trim, fold, invalid), idle_handoff_min_tokens (clamped)', () => {
  expect(DEFAULTS.max_auto_continues_per_hour).toBe(6)
  // BLD-08 / OD-4 provisional: the same default as src/plugin.json (`model`).
  expect(DEFAULTS.precompact_turn).toBe('model')
  expect(parseOptions({}).max_auto_continues_per_hour).toBe(6)
  const a = parseOptions({ precompact_turn: ' Model ', unattended_prod_reads: 'ALLOW', idle_handoff_turn: ' on', idle_handoff_min_tokens: 50000 })
  expect([a.precompact_turn, a.unattended_prod_reads, a.idle_handoff_turn, a.idle_handoff_min_tokens]).toEqual(['model', 'allow', 'on', 100000])
  expect(a.notes).toEqual({ invalid: [], clamped: [{ key: 'idle_handoff_min_tokens', configured: 50000, effective: 100000 }] })
  // AT-PC-04: any other value is `code` (the no-extra-cost path), whatever the default.
  const b = parseOptions({ precompact_turn: 'sometimes', unattended_prod_reads: 'yes', idle_handoff_turn: 'maybe', idle_handoff_min_tokens: '2000000' })
  expect([b.precompact_turn, b.unattended_prod_reads, b.idle_handoff_turn, b.idle_handoff_min_tokens]).toEqual(['code', 'forbid', 'off', 1000000])
  expect(b.notes.invalid).toEqual(['precompact_turn', 'unattended_prod_reads', 'idle_handoff_turn'])
  const c = parseOptions({ precompact_turn: '${user_config.precompact_turn}', unattended_prod_reads: '', idle_handoff_turn: '  ' })
  expect([c.precompact_turn, c.unattended_prod_reads, c.idle_handoff_turn, c.idle_handoff_min_tokens, c.notes])
    .toEqual([DEFAULTS.precompact_turn, 'forbid', 'off', 200000, { invalid: [], clamped: [] }])
  expect(parseOptions({ precompact_turn: 'CODE' }).precompact_turn).toBe('code')
})
