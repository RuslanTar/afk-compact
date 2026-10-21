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
import { checkpoint, claim, ident, measure, parseSave, prevCopy } from '../../hooks/lib/helper'
import { BRAND } from './_gen/brand.gen'
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
  test('every golden, byte for byte', () => {
    expect(cases.length).toBeGreaterThan(20)
    for (const g of cases) {
      const got = assemble(NAME, g.asset as AssetName, g.tags as Tag[], GOLDEN_RUNTIME)
      expect({ golden: g.asset + '__' + (g.tags.join('+') || 'base'), text: got })
        .toEqual({ golden: g.asset + '__' + (g.tags.join('+') || 'base'), text: g.parts.join(NAME) })
    }
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
  return { name: NAME, root: '/p', helper: '/p/bin/' + NAME + '-store', run: async () => res } as unknown as Deps
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
  })

  test('the fake helper answers the same argv with the same exit code and form', () => {
    const w = new World()
    const bin = '/p/bin/' + NAME + '-store'
    for (const [path, parts] of Object.entries(REPLY_INPUTS)) w.files.set(path, join(parts))
    for (const r of HELPER_REPLIES) {
      const argv = argvOf(r)
      // The fake's state knobs for what the real helper keeps on disk between calls.
      if (r.name === 'prev-copy-path') w.prevCopy = '~/.claude/handoffs/r/LAB-42/compact/2026-10-21_14-05-12_5e55a001_c1-1a2b3c.md'
      w.saveLine = r.name === 'save-copy-exists' ? 'EXISTS: ~/.claude/handoffs/r/LAB-42/compact/2026-10-21_14-05-12_5e55a001_c1-1a2b3c.md sha-match' : undefined
      const fake = w.helper([bin, ...argv], {})
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
