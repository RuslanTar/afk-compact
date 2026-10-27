// Phase 2 cross-checks (BUILD-PLAN §4.4) on the TS side, over generated modules (the kit has no fs):
//   BT-04  the TS assembler gives the goldens tools/assemble wrote, byte for byte
//   AT-C-03  the TS detector gives every tuple of tests/fixtures/summaries/expected.tsv
//   BT-05  the mod reads the real helper's recorded replies, and the fake helper the U tests use
//          answers the same argv with the same exit code and the same output form
import { describe, expect, test } from 'claude-code/testing'
import type { AssetName } from '../../hooks/lib/assets.gen'
import type { Tag } from '../../hooks/lib/assemble'
import { assemble } from '../../hooks/lib/assemble'
import type { DetectContext } from '../../hooks/lib/detect'
import { detectSummary } from '../../hooks/lib/detect'
import type { Deps, RunResult } from '../../hooks/lib/deps'
import { LAUNCHER_DIR, launcherPath, storeWord } from '../../hooks/lib/deps'
import { checkpoint, claim, handoffState, handoffTurnOpen, handoffTurnSupersede, ident, logJobs, measure, parseHandoffState, parseSave, prevCopy } from '../../hooks/lib/helper'
import { parseMeasure } from '../../hooks/lib/shadow'
import { BRAND } from './_gen/brand.gen'
import * as CORPUS_GEN from './_gen/corpus.gen'
import { CORPUS } from './_gen/corpus.gen'
import { GOLDENS, GOLDEN_RUNTIME } from './_gen/goldens.gen'
import { HELPER_REPLIES, REPLY_INPUTS, REPLY_NONCE, REPLY_SID } from './_gen/helper-replies.gen'
import type { RecordedReply } from './_gen/helper-replies.gen'
import { World } from './harness.test'

const NAME = 'x'.repeat(14)

describe('BT-04 TS assembler vs the goldens', () => {
  // D-10 (small-rulings §1.7): the mod applies `queue` whenever `queue_cmd` is set, so every
  // golden counts, the queue ones included.
  const cases = GOLDENS
  // Runtime values that carry the build name (queue_add, handoff_finish) are rendered with NAME.
  const runtime = Object.fromEntries(Object.entries(GOLDEN_RUNTIME)
    .map(([k, v]) => [k, typeof v === 'string' ? v.split(BRAND.name).join(NAME) : v]))
  test('every golden, byte for byte', () => {
    expect(cases.length).toBeGreaterThan(20)
    for (const g of cases) {
      const got = assemble(NAME, g.asset as AssetName, g.tags as Tag[], runtime)
      expect({ golden: g.asset + '__' + (g.tags.join('+') || 'base'), text: got })
        .toEqual({ golden: g.asset + '__' + (g.tags.join('+') || 'base'), text: g.parts.join(NAME) })
    }
  })
})

// P5-FOLD A1 (fix-to-mod item 1): the 6 P5 summaries and the after-close cases, with the
// fixture's listed trailer, once tools/fixtures-gen renders `CORPUS_P5` (until then: nothing to run).
describe('AT-P5-01, AT-P5-02 TS detector vs the P5 corpus', () => {
  test('every P5 entry gives its verdict, placement and sha', () => {
    const g = CORPUS_GEN as unknown as Record<string, unknown>
    const p5 = g['CORPUS_P5'] as { file: string; text: string; verdict: string; sentinel_place: string | null; normalized_sha256: string; dispatch: unknown }[] | undefined
    if (p5 === undefined) return
    const trailers = (g['P5_COPY_TRAILERS'] as string[] | undefined) ?? []
    expect(p5.length).toBeGreaterThan(5)
    for (const c of p5) {
      const d = c.dispatch as { nonce?: unknown } | null
      const r = detectSummary(c.text, BRAND.name, d && typeof d === 'object' ? { dispatchNonce: String(d.nonce), scope: 'main' } : {}, trailers)
      expect({ file: c.file, verdict: r.verdict, place: r.sentinel_place, sha: r.sha256 }).toEqual({ file: c.file, verdict: c.verdict, place: c.sentinel_place, sha: c.normalized_sha256 })
    }
  })
})

// Idle lab runs of 2026-10-23 on Claude Code 2.1.309 (EXPERIMENT-RESULTS §5.2): the installed
// message carries three engine trailers after the sentinel (the third is new in 2.1.309) and the
// PostCompact compact_summary an <analysis> block before <summary>. Every form reads ok, sentinel
// 1 from the end, marker on body line 1, and both forms of one run share the normalized body.
describe('idle 2.1.309 summaries: TS detector vs summaries/idle', () => {
  test('every entry gives its tuple, with the shipped trailers only', () => {
    const g = CORPUS_GEN as unknown as Record<string, unknown>
    const idle = g['CORPUS_IDLE'] as { file: string; text: string; verdict: string; marker_line: number | null; sentinel_from_end: number | null; nonce: string | null; normalized_sha256: string }[] | undefined
    expect(idle?.length).toBe(6)
    for (const c of idle ?? []) {
      const r = detectSummary(c.text, BRAND.name, { dispatchNonce: c.nonce ?? undefined, scope: 'main' })
      expect({ file: c.file, verdict: r.verdict, marker_line: r.marker_line, sentinel_from_end: r.sentinel_from_end, sha: r.sha256 })
        .toEqual({ file: c.file, verdict: 'ok', marker_line: 1, sentinel_from_end: 1, sha: c.normalized_sha256 })
      expect({ file: c.file, verdict: c.verdict }).toEqual({ file: c.file, verdict: 'ok' })
    }
    const byNonce = new Map<string, Set<string>>()
    for (const c of idle ?? []) byNonce.set(c.nonce ?? '', (byNonce.get(c.nonce ?? '') ?? new Set()).add(c.normalized_sha256))
    expect([...byNonce.values()].map(s => s.size)).toEqual([1, 1, 1])
  })
})

describe('AT-C-03 TS detector vs expected.tsv', () => {
  test('every corpus file gives the expected tuple', () => {
    expect(CORPUS.length).toBe(41)
    for (const c of CORPUS) {
      const ctx: DetectContext = {}
      if (c.dispatch === 'none') ctx.noDispatch = true
      else if (c.dispatch !== null) {
        const d = c.dispatch as { nonce?: unknown; agent_id?: unknown; channel?: unknown }
        ctx.dispatchNonce = String(d.nonce)
        if (d.agent_id !== null && d.agent_id !== undefined) ctx.scope = 'sub'
        else if (d.channel === 'mod-hook' || d.channel === 'mod-self') ctx.scope = 'main'
      }
      const r = detectSummary(c.text, BRAND.name, ctx)
      expect({ file: c.file, verdict: r.verdict, marker_line: r.marker_line, sentinel_from_end: r.sentinel_from_end, nonce: r.nonce, scope: r.scope, sha: r.sha256 })
        .toEqual({ file: c.file, verdict: c.verdict, marker_line: c.marker_line, sentinel_from_end: c.sentinel_from_end, nonce: c.nonce, scope: c.scope, sha: c.normalized_sha256 })
    }
  })
})

const join = (parts: readonly string[]): string => parts.join(NAME)
const reply = (name: string): RecordedReply => {
  const r = HELPER_REPLIES.find(x => x.name === name)
  if (!r) throw new Error('no recorded reply ' + name)
  return r
}
const argvOf = (r: RecordedReply): string[] => r.argv.map(join)

/** A Deps whose helper answers with one recorded reply. */
function depsFor(r: RecordedReply): Deps {
  const res: RunResult = { ok: r.exitCode === 0, exitCode: r.exitCode, stdout: join(r.stdout), error: '' }
  return { name: NAME, root: '/p', helper: '/p/scripts/' + NAME + '-store', run: async () => res } as unknown as Deps
}

/** Output form: paths, 8-hex ids and numbers stand for any value. */
function form(s: string): string {
  return s.replace(/(~|\$TMP)?\/[^\s"]+/g, '<path>').replace(/\b[0-9a-f]{8}\b/g, '<hex8>').replace(/\d+/g, '<n>')
}

describe('BT-05 recorded helper replies', () => {
  test('the mod reads every real reply as intended', async () => {
    expect(await ident(depsFor(reply('ident')), REPLY_SID)).toEqual({ pid: 424242, pid_lstart: 'Tue Oct 21 09:00:00 2026' })
    expect(await prevCopy(depsFor(reply('prev-copy-none')), REPLY_SID)).toBeUndefined()
    expect(await prevCopy(depsFor(reply('prev-copy-path')), REPLY_SID)).toMatch(/^~\/.+_c1-1a2b3c\.md$/)
    expect(reply('dispatch-ok').exitCode).toBe(0)
    expect({ exit: reply('dispatch-exists').exitCode, out: join(reply('dispatch-exists').stdout) }).toEqual({ exit: 3, out: 'REFUSED: nonce-exists\n' })
    const cp = await checkpoint(depsFor(reply('checkpoint')), REPLY_SID, REPLY_NONCE, false)
    expect(cp?.measured_block ?? null).toBeNull()
    const saved = parseSave({ ok: true, exitCode: 0, stdout: join(reply('save-copy-saved').stdout), error: '' })
    expect([saved.verdict, saved.kind, saved.marker_line, saved.sentinel_from_end]).toEqual(['ok', 'saved', 1, 1])
    const again = parseSave({ ok: true, exitCode: 0, stdout: join(reply('save-copy-exists').stdout), error: '' })
    expect([again.kind, again.path]).toEqual(['exists-match', saved.path])
    expect(await claim(depsFor(reply('claim-claimed')), REPLY_SID, REPLY_NONCE, 'prompt.context')).toBe('CLAIMED')
    expect(await claim(depsFor(reply('claim-taken')), REPLY_SID, REPLY_NONCE, 'prompt.submit')).toBe('TAKEN')
    const block = await measure(depsFor(reply('measure')), REPLY_SID)
    expect(typeof block === 'string' && block.length > 0 && block.length <= 3000).toBe(true)
    expect([reply('log').exitCode, join(reply('log').stdout), reply('log-paths').exitCode]).toEqual([0, '', 0])
    // D-18 B8 / Dev-1 D1: the handoff-turn calls, handoff-state in its six forms, the jobs log.
    const sidOf = (n: string): string => argvOf(reply(n))[2] ?? ''
    const htOf = (n: string): string => argvOf(reply(n))[argvOf(reply(n)).indexOf('--ht') + 1] ?? ''
    expect(await handoffTurnOpen(depsFor(reply('handoff-turn-open')), sidOf('handoff-turn-open'), htOf('handoff-turn-open'), 'cap', 34, 64000)).toBe('ok')
    expect(await handoffTurnOpen(depsFor(reply('handoff-turn-open-exists')), REPLY_SID, htOf('handoff-turn-open-exists'), 'cap', 34, 64000)).toBe('EXISTS')
    expect(await handoffTurnSupersede(depsFor(reply('handoff-turn-supersede')), REPLY_SID, htOf('handoff-turn-supersede'), REPLY_NONCE)).toBe(true)
    expect(await handoffTurnSupersede(depsFor(reply('handoff-turn-supersede-exists')), REPLY_SID, htOf('handoff-turn-supersede-exists'), REPLY_NONCE)).toBe(true)
    expect([reply('handoff-turn-supersede-no-ht').exitCode, join(reply('handoff-turn-supersede-no-ht').stdout)]).toEqual([3, 'REFUSED: no-ht\n'])
    expect(await handoffTurnSupersede(depsFor(reply('handoff-turn-supersede-no-ht')), REPLY_SID, htOf('handoff-turn-supersede-no-ht'), REPLY_NONCE)).toBe(false)
    const hs = async (n: string) => handoffState(depsFor(reply(n)), REPLY_SID, htOf(n))
    expect(await hs('handoff-state-none')).toEqual({ state: 'none' })
    expect(await hs('handoff-state-staged')).toEqual({
      state: 'staged', stage: '~/.claude/handoffs/repo/LAB-42/.staging/5e55a001-0a0b0c03', draft: true,
      finish: join(reply('handoff-state-staged').stdout).replace(/^.* finish=/, '').trimEnd(),
    })
    const staged = await hs('handoff-state-staged')
    // core C-2 (core-to-mod §24): the finish command starts with the token `<store>`, which the
    // resume block's first line defines as `@store@`; it holds no launcher word or plugin root of
    // its own. The storeWord()/`ctx::store_cmd()` parity is checked on `@store@` (AT-PK-03 below).
    const finish = staged.state === 'staged' ? staged.finish ?? '' : ''
    expect([finish.startsWith("<store> publish --stage '"), finish.includes('$PLUGIN'), finish.includes('/' + LAUNCHER_DIR + '/')]).toEqual([true, false, false])
    expect(await hs('handoff-state-staged-no-finish')).toEqual({
      state: 'staged', stage: "~/.claude/handoffs/repo/LAB-42/.staging/it's-0a0b0c04", draft: false, finish: null,
    })
    expect(await hs('handoff-state-published')).toEqual({ state: 'published', path: '~/.claude/handoffs/repo/LAB-42/2026-10-21_14-05-12_5e55a001_retry.md' })
    expect(await hs('handoff-state-superseded')).toEqual({ state: 'superseded', nonce: REPLY_NONCE })
    // DP-28: a claimed handoff file the publish could not write answers `publish-failed <path>`;
    // the mod reads it as failed, so the cycle falls back to the full summary text.
    expect(join(reply('handoff-state-publish-failed').stdout)).toMatch(/^publish-failed ~\/\S+_retry-2\.md\n$/)
    expect(await hs('handoff-state-publish-failed')).toEqual({ state: 'failed' })
    expect(parseHandoffState(join(reply('handoff-state-none').stdout))).toEqual({ state: 'none' })
    const jobs = reply('log-jobs-caller')
    expect([jobs.exitCode, join(jobs.stdout), jobs.stdin !== undefined]).toEqual([3, 'REFUSED: jobs-caller\n', true])
    const jr = await logJobs(depsFor(jobs), REPLY_SID, join(jobs.stdin ?? []).split('\n').filter(l => l !== ''))
    expect(jr?.exitCode).toBe(3)
    expect(reply('dispatch-handoff-ht').exitCode).toBe(0)
    // The local shadow trial without its config: absent, nothing written.
    expect(parseMeasure(join(reply('trial-measure-absent').stdout))).toEqual({ state: 'absent', why: null })
    expect([reply('trial-save-absent').exitCode, JSON.parse(join(reply('trial-save-absent').stdout))]).toEqual([0, { why: 'absent', written: false }])
  })

  test('the fake helper answers the same argv with the same exit code and form', () => {
    const w = new World()
    const bin = '/p/scripts/' + NAME + '-store'
    for (const [path, parts] of Object.entries(REPLY_INPUTS)) w.files.set(path, join(parts))
    for (const r of HELPER_REPLIES) {
      const argv = argvOf(r)
      // The fake's state knobs for what the real helper keeps on disk between calls.
      if (r.name === 'prev-copy-path') w.prevCopy = '~/.claude/handoffs/r/LAB-42/compact/2026-10-21_14-05-12_5e55a001_c1-1a2b3c.md'
      // handoff-state answers the recorded line; the jobs stream refuses as outside Claude Code.
      if (r.name.startsWith('handoff-state-')) w.htStates.set(argv[argv.indexOf('--ht') + 1] ?? '', join(r.stdout).trimEnd())
      w.jobsReply = r.name === 'log-jobs-caller' ? { exitCode: 3, stdout: 'REFUSED: jobs-caller\n' } : { exitCode: 0, stdout: '' }
      w.saveLine = r.name === 'save-copy-exists' ? 'EXISTS: ~/.claude/handoffs/r/LAB-42/compact/2026-10-21_14-05-12_5e55a001_c1-1a2b3c.md sha-match' : undefined
      const fake = w.helper([bin, ...argv], {}, r.stdin === undefined ? undefined : join(r.stdin))
      if (fake === 'reject') throw new Error('fake helper rejected ' + r.name)
      const real = join(r.stdout)
      if (r.name === 'measure') {
        // Free text whose content depends on the work tree; both are non-empty blocks.
        expect([r.name, fake.exitCode, fake.stdout.trim() !== '', real.trim() !== '']).toEqual([r.name, r.exitCode, true, true])
        continue
      }
      if (r.name === 'ident' || r.name === 'checkpoint') {
        // JSON: every key the fake gives (the keys the mod reads) is in the real reply.
        const fk = Object.keys(JSON.parse(fake.stdout) as object).sort()
        const rk = Object.keys(JSON.parse(real) as object)
        expect([r.name, fake.exitCode, fk.filter(k => !rk.includes(k))]).toEqual([r.name, r.exitCode, []])
        continue
      }
      expect([r.name, fake.exitCode, form(fake.stdout)]).toEqual([r.name, r.exitCode, form(real)])
    }
  })
})

// AT-PK-03 (mod part): the launcher word for the root classes PKG-RUNTIME A.1 names. The helper's
// `ctx::store_cmd()` gives the same words (core case AT-PK-03-store-word holds the same roots).
describe('AT-PK-03 storeWord', () => {
  test('double quotes; single quotes for ", $, backquote, backslash; refused when \' is there too', () => {
    const tail = '/scripts/' + NAME + '-store'
    expect(launcherPath('/p', NAME)).toBe('/p' + tail)
    expect(storeWord('/p', NAME)).toBe('"/p' + tail + '"')
    expect(storeWord('/opt/a b/.claude/plugins/cache/m/x/1.0.0', NAME)).toBe('"/opt/a b/.claude/plugins/cache/m/x/1.0.0' + tail + '"')
    expect(storeWord("/p/it's", NAME)).toBe('"/p/it\'s' + tail + '"')
    expect(storeWord('/p/$HOME', NAME)).toBe("'/p/$HOME" + tail + "'")
    expect(storeWord('/p/a"b', NAME)).toBe("'/p/a\"b" + tail + "'")
    expect(storeWord('/p/a`b', NAME)).toBe("'/p/a`b" + tail + "'")
    expect(storeWord('/p/a\\b', NAME)).toBe("'/p/a\\b" + tail + "'")
    expect(storeWord('/p/a"b\'c', NAME)).toBeUndefined()
    expect(storeWord('/p/$it\'s', NAME)).toBeUndefined()
  })
})
