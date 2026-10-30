// U tests of the pure libs: nonce (AT-C-01), detector (AT-C-02), assembler budgets (AT-P-07,
// D-17/DP-8 table), clamp (AT-P-03/04/15/16 arithmetic), the run-time brand in the marker
// (BT-01 U part), sha256.
import { describe, expect, test } from 'claude-code/testing'
import { ASSET_NAMES, assetText } from '../../hooks/lib/assets.gen'
import type { Tag } from '../../hooks/lib/assemble'
import { assembleText, hasTag, leftovers } from '../../hooks/lib/assemble'
import { CLAMP_DEFAULTS, DEFAULTS, IDLE_INVALID_READS_AS, NAME_TOKEN, clamp, clampConstants, minWindow, parseOptions, paths, softCap, stateRoot, targetOf } from '../../hooks/lib/config'
import { CLOSE, OPEN, detectSummary, grammar, lastInstrMarker, markerText, sentinelText, specValue } from '../../hooks/lib/detect'
import { drawNonce, randomHex } from '../../hooks/lib/nonce'
import { byteLength, sha256, strip } from '../../hooks/lib/normalize'
import { endsWithQuestion } from '../../hooks/lib/boundary'
import { formatTokens, tempPaths } from '../../hooks/lib/nudge'
import type { Deps } from '../../hooks/lib/deps'
import { cacheSOf, compactMinOf, envTruthy } from '../../hooks/lib/deps'
import { checkpoint } from '../../hooks/lib/helper'
import { BLOCK_MAX, BLOCK_SOFT, fitBlock, keepGsdLines, prodAllowed, storeRuntime } from '../../hooks/lib/resume'

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
/** PKG-RUNTIME A.2: budgets render `@store@` with a 160-character root stand-in. */
const STORE = '"' + '/' + 'r'.repeat(159) + '/scripts/' + NAME + '-store"'
const WORST = {
  store: STORE, idle_min: '49',
  nonce: 'a1b2c3d4', previous_copy: PREV, measured_at: '2026-10-21T04:40:00+03:00', session_id: '00000000-0000-4000-8000-000000000000',
  saved_copy: PREV, tokens: '612,345', queue_add: NAME + '-store queue-add --sid 00000000-0000-4000-8000-000000000000 --nonce a1b2c3d4',
  measured_facts: '', remeasure: '', halt_reason: 'compactions keep repeating without progress', max_calls: '34', handoff_path: PREV,
  draft_state: 'present', handoff_finish: '`' + NAME + "-store publish --stage '" + PREV + "' --slug lab-123-retry --status in-progress`",
  idle_used_at: '2026-10-21T04:40:00+03:00',
  // Away digest phase 1 [idle-done]: the lane word, the longest reason and the longest Basis line
  // lane.ts gives (LANE_WHY_MAX, LANE_BASIS_MAX; tools/assemble budgets with the same values).
  lane: 'hard-blocked', lane_why: 'no Status code could read, but every listed step is marked done',
  lane_basis: '999+ of 999+ listed steps marked done; 999+ units running; git: no upstream, unpushed unknown, 999+ files changed',
  // The shadow trial's fork texts (TRIAL-DUAL-HANDOFF §4.2): read at run time from local files.
  old_skill: '# Old skill\nStep 1.', old_template: '# Template', trial_facts: 'Repository: r', trial_tail: 'Last reply:\ndone',
}
const BLANK = Object.fromEntries(Object.keys(WORST).map(k => [k, '']))
const TAGS: Record<string, Tag[]> = {
  'handoff-instructions': ['midturn', 'auto', 'chain', 'handoff', 'measured'],
  'subagent-instructions': ['fallback'],
  'resume-context': ['midturn', 'nonok', 'handoff', 'handoff-partial', 'idle', 'idle-halt', 'idle-again', 'prod-forbid', 'prod-allow', 'driver', 'idle-done',
    'idle-off', 'idle-done-off'],
  'checkpoint-nudge': ['continue', 'halt', 'halt-handoff', 'queue'],
  'handoff-turn': ['submit', 'submit-halt', 'submit-pre', 'submit-idle', 'near', 'spent', 'imminent'],
  'trial-old-handoff': ['trial-tail'],
}

/**
 * The tag combinations the mod builds: every subset, less the exclusive groups (BLD-04, XR-19):
 * exactly one of `prod-forbid`/`prod-allow` on the resume block, at most one of `idle`, `idle-halt`
 * (owner xxxxxxxx-25), `idle-done` (away digest phase 1), their `idle_digest: off` variants
 * `idle-off` and `idle-done-off` (owner rule (c)) and `midturn`, `idle-again` (owner xxxxxxxx-37)
 * only with one of those idle lines, `handoff` never with `handoff-partial`, `driver` never with
 * `idle-halt`, `idle-done` or `idle-done-off`, and one handoff-turn kind at a time.
 */
function combos(tags: Tag[]): Tag[][] {
  let out: Tag[][] = [[]]
  for (const t of tags) for (const c of [...out]) out.push([...c, t])
  const has = (c: Tag[], t: Tag) => c.includes(t)
  if (tags.includes('prod-forbid')) out = out.filter(c => has(c, 'prod-forbid') !== has(c, 'prod-allow'))
  const IDLE: Tag[] = ['idle', 'idle-halt', 'idle-done', 'idle-off', 'idle-done-off']
  out = out.filter(c => [...IDLE, 'midturn' as Tag].filter(t => has(c, t)).length <= 1 && !(has(c, 'handoff') && has(c, 'handoff-partial')))
  out = out.filter(c => !has(c, 'idle-again') || IDLE.some(t => has(c, t)))
  // Owner 2026-10-26 [driver]: never with [idle-halt] (auto-continue is paused); a measured driver
  // keeps the work lane working, so never with [idle-done] either (lane.ts).
  out = out.filter(c => !(has(c, 'driver') && (has(c, 'idle-halt') || has(c, 'idle-done') || has(c, 'idle-done-off'))))
  out = out.filter(c => [has(c, 'submit-halt'), has(c, 'submit-pre'), has(c, 'submit-idle')].filter(Boolean).length <= 1)
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
  // the hard guard is the channel total below, with the D-18 `[handoff]` line included; 8,720 B since
  // the owner's 2026-10-26 plugin-text ruling ("Raise the cap"; tools/assemble BUDGETS), 8,800 B since the
  // away digest's lane Status and step marks (owner 2026-10-27 12:5x). Classic keeps 8,192.
  test('mod main [midturn]+[chain]+[handoff]+[measured] with a full 3,000 B block ≤8,800 B (the hard channel total)', () => {
    const s = assembleText(text('handoff-instructions'), ['midturn', 'chain', 'handoff', 'measured'], { ...WORST, measured_facts: 'x'.repeat(3000) })
    expect(byteLength(s) <= 8800).toBe(true)
  })
  test('classic fallback (main [auto]+[chain] + subagent [fallback]) ≤8,192 B', () => {
    const s = assembleText(text('handoff-instructions'), ['auto', 'chain'], WORST, ['measured']) + assembleText(text('subagent-instructions'), ['fallback'], WORST)
    expect(byteLength(s) <= 8192).toBe(true)
  })
  test('mod main [midturn]+[chain]+[measured] with a full 3,000 B block ≤8,800 B', () => {
    const s = assembleText(text('handoff-instructions'), ['midturn', 'chain', 'measured'], { ...WORST, measured_facts: 'x'.repeat(3000) })
    expect(byteLength(s) <= 8800).toBe(true)
  })
  // RP-1 (owner 2026-10-23, ratify xxxxxxxx#R3 overturned): 3,000 is a soft target now; the protocol
  // may exceed it only up to the size its logged reason names (tools/budget-reasons.json, 4,130
  // since owner xxxxxxxx-18 and xxxxxxxx-37 added the idle check line and the [idle-again] note,
  // the owner's 2026-10-26 GSD re-entry ruling the [driver] line, and the 2026-10-26 plugin-text
  // ruling TC-02's idle report and TC-26's unblocked Next steps with the ask repeated last; 4,590
  // since the away digest's [idle-done] line with its code-rendered Basis, and the step-5 digest
  // clause of [idle], owner 2026-10-27 12:5x and AWAY-DIGEST phase 1 items 3 and 5; 4,620 since that
  // step-5 digest carries the code-rendered Basis line too, owner 2026-10-27 22:32; 4,657 since
  // release-0.1.0's [driver] line names the workflow file a GSD loop command loads).
  test('resume protocol ≤4,657 chars (soft 3,000 with a logged reason; RP-1) for every tag combination the mod builds, @store@ at its 160-char root', () => {
    for (const tags of combos(TAGS['resume-context'] ?? [])) {
      const s = assembleText(text('resume-context'), tags, WORST, ['measured_at', 'remeasure'])
      expect(s.length <= 4657).toBe(true)
    }
  })
  // REVIEW-NIGHT NR-11 / TG-04 (RP-2, RP-4): the shipped worst-case protocol, not a synthetic one.
  test('AT-TX-11 (U half): every shipped resume protocol beside a 3,000-byte measured block goes out untrimmed (≤BLOCK_MAX 9,500; soft 6,500)', () => {
    const measured = Array.from({ length: 30 }, (_, i) => 'm'.repeat(98) + String(i % 10)).join('\n').slice(0, 3000)
    let worst: Tag[] = []
    let worstLen = 0
    for (const tags of combos(TAGS['resume-context'] ?? [])) {
      const render = (m: string) => assembleText(text('resume-context'), tags, { ...WORST, remeasure: m })
      const block = fitBlock(render, measured)
      expect(block).toBe(render(measured))
      expect(block.length <= BLOCK_MAX).toBe(true)
      if (block.length > worstLen) [worst, worstLen] = [tags, block.length]
    }
    expect(BLOCK_MAX === 9500 && BLOCK_SOFT === 6500 && BLOCK_MAX < 10000).toBe(true)
    // Over the hard cap, whole re-measure lines go first, with a note.
    const render = (m: string) => assembleText(text('resume-context'), worst, { ...WORST, remeasure: m })
    const big = fitBlock(render, measured + '\n' + 'z'.repeat(4000))
    expect(big.length <= BLOCK_MAX && big.includes('(+')).toBe(true)
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

test('STATE-ROOT (0.1.2): the default handoff root is outside ~/.claude, and .watch moves with it', () => {
  // the plugin's name stands as a token in the fallback default; parseOptions fills it in
  expect(DEFAULTS.handoff_root).toBe('~/.local/state/' + NAME_TOKEN + '/handoffs')
  const unset = parseOptions({ handoff_root: '${user_config.handoff_root}', log_dir: '' }, 'nm')
  expect(paths(unset, '/hh/u')).toEqual({ root: '/hh/u/.local/state/nm/handoffs', watch: '/hh/u/.local/state/nm/handoffs/.watch' })
  expect(paths(parseOptions({}, 'nm'), '/hh/u/')?.watch).toBe('/hh/u/.local/state/nm/handoffs/.watch')
  // no name: `plugin`, the helper's last fallback (ctx::brand), never the bare token
  expect(parseOptions({}).handoff_root).toBe('~/.local/state/plugin/handoffs')
  // a value the user set stays the only root (the old default included); log_dir still wins for .watch
  expect(paths(parseOptions({ handoff_root: '~/.claude/handoffs' }, 'nm'), '/hh/u')?.root).toBe('/hh/u/.claude/handoffs')
  expect(paths(parseOptions({ log_dir: '/var/x/logs/' }, 'nm'), '/hh/u')?.watch).toBe('/var/x/logs')
  expect(paths(DEFAULTS, undefined)).toBeUndefined()
})

test('STATE-ROOT (0.1.2): the default disposable root is outside ~/.claude too; a value set stays', () => {
  expect(DEFAULTS.disposable_root).toBe('~/.local/state/' + NAME_TOKEN + '/disposable')
  expect(parseOptions({ disposable_root: '${user_config.disposable_root}' }, 'nm').disposable_root).toBe('~/.local/state/nm/disposable')
  expect(parseOptions({}).disposable_root).toBe('~/.local/state/plugin/disposable')
  // the old default set explicitly is kept as it is
  expect(parseOptions({ disposable_root: '~/.claude/trash-staging' }, 'nm').disposable_root).toBe('~/.claude/trash-staging')
})

test('STATE-ROOT (0.1.2): the default handoff root reads under an absolute $XDG_STATE_HOME, as the helper', () => {
  const xdg = { home: '/xs', name: 'nm' }
  // unset or equal to the default (as written or expanded): under XDG_STATE_HOME, .watch with it
  expect(paths(parseOptions({}, 'nm'), '/hh/u', xdg)).toEqual({ root: '/xs/nm/handoffs', watch: '/xs/nm/handoffs/.watch' })
  expect(paths(parseOptions({ handoff_root: '~/.local/state/nm/handoffs' }, 'nm'), '/hh/u', { home: '/xs/', name: 'nm' })?.root).toBe('/xs/nm/handoffs')
  expect(stateRoot('/hh/u/.local/state/nm/handoffs/', '/hh/u', '/xs', 'nm')).toBe('/xs/nm/handoffs')
  // a relative or empty XDG_STATE_HOME is ignored (the XDG rule); none given: the literal default
  expect(stateRoot('~/.local/state/nm/handoffs', '/hh/u', 'rel/state', 'nm')).toBe('/hh/u/.local/state/nm/handoffs')
  expect(stateRoot('~/.local/state/nm/handoffs', '/hh/u', '', 'nm')).toBe('/hh/u/.local/state/nm/handoffs')
  expect(paths(parseOptions({}, 'nm'), '/hh/u')?.root).toBe('/hh/u/.local/state/nm/handoffs')
  // any other value stays the only root, the old default and another plugin's default included
  expect(stateRoot('~/.claude/handoffs', '/hh/u', '/xs', 'nm')).toBe('/hh/u/.claude/handoffs')
  expect(stateRoot('/var/x', '/hh/u', '/xs', 'nm')).toBe('/var/x')
  expect(stateRoot('~/.local/state/other/handoffs', '/hh/u', '/xs', 'nm')).toBe('/hh/u/.local/state/other/handoffs')
  // no name: `plugin`, as parseOptions
  expect(paths(parseOptions({}), '/hh/u', { home: '/xs' })?.root).toBe('/xs/plugin/handoffs')
  // log_dir still wins for .watch
  expect(paths(parseOptions({ log_dir: '/var/x/logs' }, 'nm'), '/hh/u', xdg)).toEqual({ root: '/xs/nm/handoffs', watch: '/var/x/logs' })
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

// text-to-mod M-2 (spec §16 `clamp`, MOD-02 parity): the ten keys, each read from the shipped object.
test('clamp constants: one shared source (the spec-literals clamp object, key by key), else the built-in values', () => {
  expect(CLAMP_DEFAULTS).toEqual({
    native_offset: 33000, min_target: 120000, reserve_base: 52000, reserve_no_handoff: 100000, window_floor: 100000,
    soft_ratio: 0.8, target_num: 2, target_den: 3, handoff_tokens_min: 20000, handoff_tokens_max: 150000,
  })
  expect(clampConstants(undefined)).toEqual(CLAMP_DEFAULTS)
  expect(clampConstants([1, 2])).toEqual(CLAMP_DEFAULTS)
  expect(clampConstants({ native_offset: 40000 })).toEqual({ ...CLAMP_DEFAULTS, native_offset: 40000 })
  // Not positive numbers, or a fractional num/den: that key keeps its built-in value.
  expect(clampConstants({ target_num: 1.5, target_den: 0, soft_ratio: '0.5', min_target: -1, window_floor: Infinity })).toEqual(CLAMP_DEFAULTS)
  // Parity: the shipped object holds exactly these keys and values (skipped until the build carries it).
  const shipped = specValue('clamp')
  if (shipped !== undefined) {
    expect(shipped).toEqual(CLAMP_DEFAULTS)
    expect(clampConstants(shipped)).toEqual(CLAMP_DEFAULTS)
  }
})

test('clamp: target = floor(soft x target_num / target_den) in integers, never a float 2/3; the ratios and bounds come from the constants', () => {
  expect([targetOf(180000), targetOf(179999), targetOf(3)]).toEqual([120000, 119999, 2])
  expect(softCap(225000)).toBe(180000)
  // The 180,000 soft max edge: enabled at min_target exactly.
  const edge = clamp({ ...DEFAULTS, compact_soft_max_tokens: 180000 }, 1000000)
  expect([edge.soft_max, edge.target, edge.disabled]).toEqual([180000, 120000, null])
  // Other constants change the clamp and min_window the same way (the helper's and watcher's reading).
  const k = { ...CLAMP_DEFAULTS, soft_ratio: 0.5, target_num: 1, target_den: 2 }
  const e = clamp(DEFAULTS, 1000000, k)
  expect([e.soft_max, e.target, e.min_window]).toEqual([500000, 250000, 480000])
  expect(minWindow(DEFAULTS, { ...k, soft_ratio: 0.8 })).toBe(389000)
  // handoff_turn_max_tokens bounds are the object's handoff_tokens_min / _max.
  expect(parseOptions({ handoff_turn_max_tokens: 10 }).handoff_turn_max_tokens).toBe(CLAMP_DEFAULTS.handoff_tokens_min)
  expect(parseOptions({ handoff_turn_max_tokens: 900000 }).handoff_turn_max_tokens).toBe(CLAMP_DEFAULTS.handoff_tokens_max)
})

// S-SETTINGS A, D; IC-1 config keys; MOD-SPEC §1.2.
test('MOD-02 options: cap default 6; precompact_turn, unattended_prod_reads, idle_handoff_turn (trim, fold, invalid), idle_handoff_min_tokens (clamped)', () => {
  expect(DEFAULTS.max_auto_continues_per_hour).toBe(6)
  // Owner xxxxxxxx-18: the same default as src/plugin.json (`model`).
  expect(DEFAULTS.precompact_turn).toBe('model')
  expect(parseOptions({}).max_auto_continues_per_hour).toBe(6)
  // AT-IA-01 (idle D3): default `auto`; the old `on` reads as `auto` with a config_note; `off` is off;
  // any other value is `off` plus config_invalid (owner xxxxxxxx-13; there is no forced on).
  expect(DEFAULTS.idle_handoff_turn).toBe('auto')
  const a = parseOptions({ precompact_turn: ' Model ', unattended_prod_reads: 'ALLOW', idle_handoff_turn: ' on', idle_handoff_min_tokens: 50000 })
  expect([a.precompact_turn, a.unattended_prod_reads, a.idle_handoff_turn, a.idle_handoff_min_tokens]).toEqual(['model', 'allow', 'auto', 100000])
  expect(a.notes).toEqual({ invalid: [], clamped: [{ key: 'idle_handoff_min_tokens', configured: 50000, effective: 100000 }], noted: [{ key: 'idle_handoff_turn', note: 'legacy-on' }] })
  // AT-PC-04: any other value is `code` (the no-extra-cost path), whatever the default.
  const b = parseOptions({ precompact_turn: 'sometimes', unattended_prod_reads: 'yes', idle_handoff_turn: 'maybe', idle_handoff_min_tokens: '2000000' })
  expect([b.precompact_turn, b.unattended_prod_reads, b.idle_handoff_turn, b.idle_handoff_min_tokens]).toEqual(['code', 'forbid', 'off', 1000000])
  expect(b.notes.invalid).toEqual(['precompact_turn', 'unattended_prod_reads', 'idle_handoff_turn'])
  const c = parseOptions({ precompact_turn: '${user_config.precompact_turn}', unattended_prod_reads: '', idle_handoff_turn: '  ' })
  expect([c.precompact_turn, c.unattended_prod_reads, c.idle_handoff_turn, c.idle_handoff_min_tokens, c.notes])
    .toEqual([DEFAULTS.precompact_turn, 'forbid', 'auto', 200000, { invalid: [], clamped: [] }])
  expect(parseOptions({ precompact_turn: 'CODE' }).precompact_turn).toBe('code')
  expect(parseOptions({ idle_handoff_turn: ' OFF ' }).idle_handoff_turn).toBe('off')
})

// AT-IA-01, owner xxxxxxxx-13 (2026-10-26, "Off + common words"): false, no, none, disabled, 0 read as
// off; true, yes, 1, on as auto (a JSON boolean or number too); anything else is off plus
// config_invalid, which /status shows. One value with settings.pm $IDLE_INVALID.
test('AT-IA-01 idle_handoff_turn: common words, and any other value reads as off', () => {
  expect(IDLE_INVALID_READS_AS).toBe('off')
  for (const w of ['false', ' No ', 'NONE', 'disabled', '0', false, 0]) {
    const r = parseOptions({ idle_handoff_turn: w } as never)
    expect([w, r.idle_handoff_turn, r.notes.invalid]).toEqual([w, 'off', []])
  }
  for (const w of ['true', 'Yes', ' 1 ', true, 1]) {
    const r = parseOptions({ idle_handoff_turn: w } as never)
    expect([w, r.idle_handoff_turn, r.notes.invalid]).toEqual([w, 'auto', []])
  }
  // A blank value (spaces, a tab) is unset: the default, no note; settings.pm reads it so too.
  for (const w of ['  ', '\t', ' \t ']) {
    const r = parseOptions({ idle_handoff_turn: w } as never)
    expect([w, r.idle_handoff_turn, r.notes.invalid]).toEqual([w, DEFAULTS.idle_handoff_turn, []])
  }
  for (const w of ['flase', 'enabled', 'auto-ish', '2', 2, 'of']) {
    const r = parseOptions({ idle_handoff_turn: w } as never)
    expect([w, r.idle_handoff_turn, r.notes.invalid]).toEqual([w, 'off', ['idle_handoff_turn']])
  }
})

// IDLE-COMPACT §5 (D9): `idle_compact` reads like `idle_handoff_turn` (the same word lists and
// invalid value as settings.pm); default `auto` pending the owner (Q3). `on` is a plain auto word
// here (no legacy note: the key is new).
test('AT-IC-C00 idle_compact: default auto; common words; any other value reads as off with config_invalid', () => {
  expect(DEFAULTS.idle_compact).toBe('auto')
  expect(parseOptions({}).idle_compact).toBe('auto')
  for (const w of ['off', 'false', ' No ', 'NONE', 'disabled', '0', false, 0]) {
    const r = parseOptions({ idle_compact: w } as never)
    expect([w, r.idle_compact, r.notes.invalid]).toEqual([w, 'off', []])
  }
  for (const w of ['auto', 'true', 'Yes', ' 1 ', 'on', true, 1]) {
    const r = parseOptions({ idle_compact: w } as never)
    expect([w, r.idle_compact, r.notes.invalid, r.notes.noted]).toEqual([w, 'auto', [], undefined])
  }
  for (const w of ['  ', '\t', '${user_config.idle_compact}']) expect(parseOptions({ idle_compact: w } as never).idle_compact).toBe('auto')
  for (const w of ['maybe', 'enabled', '2']) {
    const r = parseOptions({ idle_compact: w } as never)
    expect([w, r.idle_compact, r.notes.invalid]).toEqual([w, IDLE_INVALID_READS_AS, ['idle_compact']])
  }
})

// IDLE-COMPACT §1.2, §5: the environment the idle timers read. CLAUDE_CODE_IDLE_COMPACT_MIN_TOKENS
// as native `IXt` reads it; the D10 test seam bounded to 120-3600 s; a flag as Claude Code reads one.
test('AT-IC-C00 idle env: compactMinOf, cacheSOf, envTruthy', () => {
  expect([compactMinOf(undefined), compactMinOf(''), compactMinOf('abc'), compactMinOf('-5'), compactMinOf('0'), compactMinOf('1.5')]).toEqual([200000, 200000, 200000, 200000, 200000, 200000])
  expect([compactMinOf('50000'), compactMinOf(' 300000 '), compactMinOf('100000')]).toEqual([100000, 300000, 100000])
  expect([cacheSOf(undefined), cacheSOf('60'), cacheSOf('abc'), cacheSOf('119'), cacheSOf('3601'), cacheSOf('600.5')]).toEqual([undefined, undefined, undefined, undefined, undefined, undefined])
  expect([cacheSOf('120'), cacheSOf(' 600 '), cacheSOf('3600')]).toEqual([120, 600, 3600])
  expect(['1', 'true', ' YES ', 'on'].map(envTruthy)).toEqual([true, true, true, true])
  expect([undefined, '', '0', 'false', 'off', 'no', 'x'].map(v => envTruthy(v))).toEqual([false, false, false, false, false, false, false])
})

// P5-FOLD A1 (MOD-SPEC §5.1): a sentinel placed right after `</summary>` belongs to the body.
describe('AT-P5-01, AT-P5-02 sentinel after </summary>', () => {
  const N = '1a2b3c4d'
  const body = (n = N) => markerText(NAME, n, 'main') + '\n# LAB-42 retry\n## Resume here\nStatus: active\n'
  const post = (inner: string, tail: string) => '<summary>\n' + inner + '</summary>' + tail
  const installed = (inner: string, tail: string) => 'This session is being continued from a previous conversation that ran out of context.\n\nSummary:\n<summary>\n' + inner + '</summary>' + tail
  const S = sentinelText(NAME, N)

  test('AT-P5-01: three summaries with the sentinel inside, three after the close tag: 6/6 ok, the place reported, the body ends with the sentinel, the same sha in both message forms', () => {
    const cases = [
      { text: post(body() + S + '\n', '\n'), place: 'inside' },
      { text: post(body() + S + '\n\n', ''), place: 'inside' },
      { text: installed(body() + S + '\n', '\n\n'), place: 'inside' },
      { text: post(body(), '\n' + S + '\n'), place: 'after-close' },
      { text: post(body(), '\n\n' + S), place: 'after-close' },
      { text: installed(body(), S + '\n'), place: 'after-close' },
    ]
    const shas = new Set<string>()
    for (const c of cases) {
      const r = detectSummary(c.text, NAME, { dispatchNonce: N, scope: 'main' })
      expect([r.verdict, r.sentinel_place, r.sentinel_from_end]).toEqual(['ok', c.place, 1])
      expect(r.normalized.endsWith(S + '\n')).toBe(true)
      shas.add(r.sha256)
    }
    expect(shas.size).toBe(1)
  })

  test('AT-P5-02: another nonce after the close tag is truncated; a non-sentinel line first stays outside; a listed trailer is cut; unlisted text after it is ok-trailer; no marker is unshaped', () => {
    const other = sentinelText(NAME, '9f9f9f9f')
    expect(detectSummary(post(body(), '\n' + other + '\n'), NAME, { dispatchNonce: N, scope: 'main' }).verdict).toBe('truncated')
    const notFirst = detectSummary(post(body(), '\nan engine line\n' + S + '\n'), NAME, { dispatchNonce: N, scope: 'main' })
    expect([notFirst.verdict, notFirst.sentinel_place]).toEqual(['truncated', null])
    expect(notFirst.normalized.includes(S)).toBe(false)
    // Every shipped trailer pattern has a sample engine line here (Claude Code 2.1.309 writes all
    // three after an installed summary); each listed one, and all of them together, are cut.
    const samples = [
      'If you need specific details from before compaction (like exact code snippets, error messages, or content you generated), read the full transcript at: /tmp/example-home/x.jsonl',
      'Continue the conversation from where it left off without asking the user any further questions. Resume directly.',
      'The messages after this summary are the most recent messages from before compaction, kept verbatim.',
    ]
    const listed = specStrings('copy_trailers')
    for (const pat of listed) {
      const line = samples.find(s => new RegExp(pat).test(s))
      expect({ pat, sample: line !== undefined }).toEqual({ pat, sample: true })
      const r = detectSummary(installed(body(), '\n' + S + '\n\n' + (line ?? '')), NAME, { dispatchNonce: N, scope: 'main' })
      expect([r.verdict, r.sentinel_place]).toEqual(['ok', 'after-close'])
    }
    if (listed.length > 0) {
      const all = detectSummary(installed(body(), '\n' + S + '\n\n' + samples.join('\n') + '\n'), NAME, { dispatchNonce: N, scope: 'main' })
      expect([all.verdict, all.sentinel_place, all.sentinel_from_end]).toEqual(['ok', 'after-close', 1])
    }
    const unlisted = detectSummary(post(body(), '\n' + S + '\nFixture trailer line: an engine sentence that no baseline lists.\n'), NAME, { dispatchNonce: N, scope: 'main' })
    expect([unlisted.verdict, unlisted.sentinel_place, unlisted.sentinel_from_end]).toEqual(['ok-trailer', 'after-close', 2])
    const bare = '<summary>\n# LAB-42 retry\nNo marker here.\n</summary>\n' + S + '\n'
    expect(detectSummary(bare, NAME, { dispatchNonce: N, scope: 'main' }).verdict).toBe('unshaped')
    // Text after the close tag never joins the body when it is not the sentinel (unchanged).
    expect(strip(post(body() + S + '\n', '\nan engine line\n'), [], grammar(NAME).sentinel).body).toBe(body() + S + '\n')
    expect(strip(post(body(), '\n' + S + '\n'), []).body).toBe(body())
    // A listed trailer after the moved sentinel is cut (any list, the shipped one or a given one).
    expect(strip(installed(body(), '\n' + S + '\n\nPlease go on.'), ['Please go on.'], grammar(NAME).sentinel).body).toBe(body() + S + '\n')
    // Trailers are line patterns (the helper's reading); one inside a closed summary is body.
    expect(strip(installed(body(), '\n' + S + '\nFixture listed trailer: x'), ['^Fixture listed trailer: .*$'], grammar(NAME).sentinel).body).toBe(body() + S + '\n')
    expect(strip('<summary>\nbody\nPlease go on.\n</summary>', ['^Please go on\\.$']).body).toBe('body\nPlease go on.\n')
    expect(strip('Summary:\nbody\nPlease go on.\n', ['^Please go on\\.$']).body).toBe('body\n')
  })
})

function specStrings(key: string): string[] {
  const v = specValue(key)
  return Array.isArray(v) ? v.filter((x): x is string => typeof x === 'string') : []
}

// MOD-04 (MOD-SPEC §3.4, BUILD-PLAN §3.4; S-SETTINGS B, PKG-RUNTIME A.1/A.2).
describe('MOD-04 resume-block tags and the store token', () => {
  // The step-4 pair as T-TEXT/S-SETTINGS word it (two lines, one tag each), and a store line.
  const TEXT = 'Head.\n[prod-forbid] 4. ask before production.\n[prod-allow] 4. a read-only production check may run.\n[chain] Run @store@ wait once.\nTail.\n'

  test('AT-PR-05 (mod part): [prod-allow] only when the option and the checkpoint consent both say allow (four combinations); exactly one step-4 line', () => {
    const combos: [string, string | undefined, boolean][] = [
      ['allow', 'allow', true], ['allow', 'forbid', false], ['forbid', 'allow', false], ['forbid', 'forbid', false], ['allow', undefined, false],
    ]
    for (const [opt, consent, want] of combos) {
      expect(prodAllowed(opt, consent)).toBe(want)
      const out = assembleText(TEXT, [want ? 'prod-allow' : 'prod-forbid'], {})
      expect(out.split('\n').filter(l => l.startsWith('4. ')).length).toBe(1)
      expect(out.includes('read-only production check')).toBe(want)
    }
  })

  test('AT-PK-03 (mod part): @store@ is the launcher word; a root no quoting can carry drops its lines and escalates store_path_unquotable', () => {
    const toasts: string[] = []
    const fake = (root: string) => ({ name: NAME, root, cfg: { warn_ui: true }, state: { toasted: new Set<string>() }, toast: (t: string) => toasts.push(t) }) as unknown as Deps
    const ok = storeRuntime(fake('/p'))
    expect(ok).toEqual({ runtime: { store: '"/p/scripts/' + NAME + '-store"' }, drop: [] })
    expect(assembleText(TEXT, ['chain'], ok.runtime, ok.drop)).toContain('Run "/p/scripts/' + NAME + '-store" wait once.')
    const bad = storeRuntime(fake('/p/a"b\'c'))
    expect(bad).toEqual({ runtime: {}, drop: ['store'] })
    expect(toasts.length).toBe(1)
    expect(toasts[0]).toContain('store_path_unquotable')
    const out = assembleText(TEXT, ['chain'], bad.runtime, bad.drop)
    expect([out.includes('wait once'), leftovers(out)]).toEqual([false, []])
  })

  test('checkpoint JSON: the consent object is read (string values only), {} when absent', async () => {
    const run = (stdout: string) => ({ name: NAME, root: '/p', helper: '/p/h', run: async () => ({ ok: true, exitCode: 0, stdout, error: '' }) }) as unknown as Deps
    const a = await checkpoint(run(JSON.stringify({ measured_block: null, lane: null, checkpoint_ms: {}, consent: { unattended_prod_reads: 'allow', n: 3 } })), 's', '1a2b3c4d', false)
    expect(a?.consent).toEqual({ unattended_prod_reads: 'allow' })
    const b = await checkpoint(run(JSON.stringify({ measured_block: null })), 's', '1a2b3c4d', false)
    expect(b?.consent).toEqual({})
  })

  test('hasTag: a tag line the build carries, or not', () => {
    expect(hasTag('resume-context', 'midturn')).toBe(true)
    expect(hasTag('resume-context', 'submit-idle')).toBe(false)
    expect(hasTag('no-such-asset', 'midturn')).toBe(false)
  })
})

// Fourth review of the GSD re-entry: the stored GSD line carries STATE.md text, so `$&`, `$'`, `` $` ``
// and `$$` in it stay literal when it replaces a timed-out GSD step.
test('AT-GR-08: keepGsdLines keeps replacement patterns in a stored GSD line literal', () => {
  const gsd = "GSD (this session): no workstream named · /r/.planning/STATE.md: status executing · stopped at fix $& and $' in costs $$ $`"
  const fresh = 'Git: main @ 9e9e9e9\nGSD: not measured (timeout)\nIn flight: none listed'
  const out = keepGsdLines(fresh, `Git: main @ 3f9c2e1\n${gsd}\nIn flight: none listed`)
  expect(out).toBe(`Git: main @ 9e9e9e9\n${gsd}\nIn flight: none listed`)
  expect(keepGsdLines(fresh, undefined)).toBe(fresh)
})
