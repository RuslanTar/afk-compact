// U tests through the kit: the session.compact handler.
import { expect, test } from 'claude-code/testing'
import { COMPACT_LINE_DELAY_MS, compactLine, summaryText } from '../../hooks/lib/compact'
import { detectSummary, markerText, sentinelText } from '../../hooks/lib/detect'
import { AGENT, ARTIFACT_HEAD, HOME, KEPT, ROOT, SID_A, WATCH, World, markerNonce, raiseCompact } from './harness.test'

test('AT-M1-06: main auto mid-turn: dispatch resolves before next; marker nonce = record; [midturn]', async ($, on) => {
  const w = new World().install(on)
  let dispatchesAtBottom = -1
  w.atCompact = () => {
    dispatchesAtBottom = w.callsOf('dispatch').length
  }
  await $.turn.start({ text: 'go on', turnId: 't1' })
  await raiseCompact($, { trigger: 'auto', instructions: 'keep the SQL' })
  const d = w.callsOf('dispatch')
  expect(d.length).toBe(1)
  expect(dispatchesAtBottom).toBe(1)
  const instr = w.compacts[0]?.instructions ?? ''
  const nonce = markerNonce(w, instr)
  expect(nonce).toBe(w.flag(d[0], '--nonce'))
  expect(w.flag(d[0], '--channel')).toBe('mod-hook')
  expect(w.flag(d[0], '--resume-pref')).toBe('prompt.context')
  expect(w.flag(d[0], '--midturn')).toBe('true')
  expect(instr.startsWith('keep the SQL\n\nThe user\'s ')).toBe(true)
  expect(instr).toContain('This began mid-turn: the last step is [unverified] unless shown done.')
  // 0.1.3 small fixes: the closing-line rule is the last line, after the size aim
  expect(instr.endsWith('Replace, never extend, the earlier summary.\nLast line before </summary>: ' + sentinelText(w.name, nonce ?? '') + '\n')).toBe(true)
  expect(w.callsOf('checkpoint').length).toBe(1)
})

test('AT-M1-07: precompute: dispatch row, no checkpoint, instructions appended, no after-step save', async ($, on) => {
  const w = new World().install(on)
  await raiseCompact($, { trigger: 'precompute' })
  expect(w.callsOf('dispatch').length).toBe(1)
  expect(w.callsOf('checkpoint').length).toBe(0)
  expect(markerNonce(w, w.compacts[0]?.instructions)).toBe(w.flag(w.callsOf('dispatch')[0], '--nonce'))
  expect(w.compacts[0]?.instructions).toContain('This began mid-turn')
  expect(w.callsOf('save-copy').length).toBe(0)
  expect(w.callsOf('sweep').length).toBe(0)
  expect(w.rowsOf('precompute_dispatched').length).toBe(1)
})

test('AT-M4-01: subagent: [e.instructions, subagent text] only; no checkpoint, nudge or resume block', async ($, on) => {
  const w = new World({ tokens: 700000 }).install(on)
  await raiseCompact($, { trigger: 'auto', agentId: AGENT, instructions: 'parent note' })
  const instr = w.compacts[0]?.instructions ?? ''
  expect(instr.startsWith('parent note\n\nThe user\'s ')).toBe(true)
  expect(markerNonce(w, instr)).toBe(w.flag(w.callsOf('dispatch')[0], '--nonce'))
  expect(instr).toContain(' s=sub' + CLOSE_MARK)
  expect(instr).not.toContain(' s=main' + CLOSE_MARK)
  expect(instr).not.toContain('Only if this is a subagent')
  expect(instr).not.toContain('## Resume here')
  expect(w.callsOf('checkpoint').length).toBe(0)
  expect(w.callsOf('measure').length).toBe(0)
  expect(w.callsOf('sweep').length).toBe(0)
  const d = w.callsOf('dispatch')[0]
  expect(w.flag(d, '--actor')).toBe(AGENT)
  expect(w.flag(d, '--resume-pref')).toBe('none')
  expect(w.callsOf('save-copy').map(c => w.flag(c, '--scope'))).toEqual(['sub'])
  expect(w.flag(w.callsOf('save-copy')[0], '--agent')).toBe(AGENT)
  const ctx = await $.prompt.context({ blocks: [] })
  expect(ctx.blocks.length).toBe(0)
  expect(w.rowsOf('nudge').length).toBe(0)
})

test('AT-M6-01: manual with a note: note, a blank line, then the precedence line', async ($, on) => {
  const w = new World().install(on)
  await raiseCompact($, { trigger: 'manual', instructions: 'keep the SQL' })
  const instr = w.compacts[0]?.instructions ?? ''
  expect(instr.startsWith(`keep the SQL\n\nThe user's ${w.name} plugin asks for this form, not any section list above; a user's /compact note wins.\n`)).toBe(true)
  expect(w.flag(w.callsOf('dispatch')[0], '--trigger')).toBe('manual')
  expect(w.callsOf('checkpoint').length).toBe(1)
})

test('AT-M6-02: manual without a note: instructions = main text only', async ($, on) => {
  const w = new World().install(on)
  await raiseCompact($, { trigger: 'manual' })
  const instr = w.compacts[0]?.instructions ?? ''
  expect(instr.startsWith(`The user's ${w.name} plugin asks for this form`)).toBe(true)
  expect(instr).not.toContain('This began mid-turn')
  expect(instr).not.toContain('If this began mid-turn')
  expect(instr.match(MAIN_MARKS)?.length).toBe(1)
})

test('AT-M6-05: trigger plugin from another plugin: foreign text first, ours appended once, no checkpoint', async ($, on) => {
  const w = new World().install(on)
  await raiseCompact($, { trigger: 'plugin', instructions: '[other-plugin] keep the migration notes' })
  const instr = w.compacts[0]?.instructions ?? ''
  expect(instr.startsWith('[other-plugin] keep the migration notes\n\n')).toBe(true)
  expect(instr.match(MAIN_MARKS)?.length).toBe(1)
  expect(w.callsOf('checkpoint').length).toBe(0)
  expect(w.callsOf('save-copy').length).toBe(1)
})

test('AT-M2-02: our marker with a mod-self record: e unchanged; no nonce, checkpoint or record; one row, one toast', async ($, on) => {
  const w = new World().install(on)
  await $.session.start({ cwd: '/w', surface: 'terminal', isInteractive: true })
  const nonce = '1a2b3c4d'
  w.files.set(`${WATCH}/${SID_A}/dispatch/${nonce}.json`, JSON.stringify({ nonce, channel: 'mod-self' }))
  const own = 'First line inside <summary>: ' + markerText(w.name, nonce, 'main')
  const before = w.callsOf('dispatch').length
  await raiseCompact($, { trigger: 'plugin', instructions: own })
  await raiseCompact($, { trigger: 'plugin', instructions: own })
  expect(w.compacts.map(c => c.instructions)).toEqual([own, own])
  expect(w.callsOf('dispatch').length).toBe(before)
  expect(w.callsOf('checkpoint').length).toBe(0)
  expect(w.callsOf('save-copy').length).toBe(0)
  expect(w.rowsOf('self_call_hook_ran').length).toBe(1)
  expect(w.toasts.filter(t => t.includes('self-call-hook-ran')).length).toBe(1)
})

test('AT-C-10 (mod): a pasted old marker with no record is no marker: our text appended, new nonce', async ($, on) => {
  const w = new World().install(on)
  await $.session.start({ cwd: '/w', surface: 'terminal', isInteractive: true })
  const note = 'keep this old summary in mind: ' + markerText(w.name, 'deadbeef', 'main') + ' … ' + sentinelText(w.name, 'deadbeef')
  await raiseCompact($, { trigger: 'manual', instructions: note })
  const instr = w.compacts[0]?.instructions ?? ''
  expect(instr.startsWith(note + '\n\n')).toBe(true)
  const nonce = markerNonce(w, instr)
  expect(nonce).not.toBe('deadbeef')
  expect(nonce).toBe(w.flag(w.callsOf('dispatch')[0], '--nonce'))
  expect(w.rowsOf('self_call_hook_ran').length).toBe(0)
})

test('AT-M3-13: an unknown trigger logs trigger_unknown and is shaped as main auto', async ($, on) => {
  const w = new World().install(on)
  await raiseCompact($, { trigger: 'idle2' })
  expect(w.rowsOf('trigger_unknown').length).toBe(1)
  expect(w.rowsOf('trigger_unknown')[0]?.trigger).toBe('idle2')
  expect(markerNonce(w, w.compacts[0]?.instructions)).toBeDefined()
  expect(w.flag(w.callsOf('dispatch')[0], '--trigger')).toBe('auto')
})

test('AT-M3-04: no summary message: copy_failed summary-not-found, toast, resume block with [nonok]', async ($, on) => {
  const w = new World().install(on)
  w.summaryMode = 'missing'
  await raiseCompact($, { trigger: 'auto' })
  const failed = w.rowsOf('copy_failed')
  expect(failed.length).toBe(1)
  expect(failed[0]?.reason).toBe('summary-not-found')
  expect(w.toasts.some(t => t.includes('copy-failed'))).toBe(true)
  expect(w.callsOf('save-copy').length).toBe(0)
  const ctx = await $.prompt.context({ blocks: [] })
  const block = ctx.blocks.find(b => b.name === `${w.name}-resume`)
  expect(block?.text).toContain('Summary not in handoff format: take state from Measured facts and kept messages.')
  expect(block?.text).toContain('saved copy of this summary: not saved (summary-not-found)')
})

test('AF-A1: a summary behind the Artifact header (2.1.312) is found: stashed from its prefix on, the PostCompact copy matches, verdict ok; two in a row never halt', async ($, on) => {
  const w = new World().install(on)
  w.summaryMode = 'artifact'
  w.postCompactSaved = true
  await raiseCompact($, { trigger: 'auto' })
  await raiseCompact($, { trigger: 'auto' })
  expect(w.rowsOf('copy_failed')).toEqual([])
  expect(w.callsOf('save-copy').length).toBe(2)
  const nonce = w.flag(w.callsOf('dispatch')[1], '--nonce') ?? ''
  expect(w.files.get(`${WATCH}/${SID_A}/pending/${nonce}.mod.md`)?.startsWith('This session is being continued')).toBe(true)
  expect(w.rowsOf('copy_exists').length).toBe(2)
  expect(w.rowsOf('copy_mismatch').length).toBe(0)
  expect(w.rowsOf('halt')).toEqual([])
  expect(w.toasts.some(t => t.includes('not in handoff format'))).toBe(false)
  const block = (await $.prompt.context({ blocks: [] })).blocks.find(b => b.name === `${w.name}-resume`)
  expect(block?.text).not.toContain('Summary not in handoff format')
  expect(block?.text).toContain(`saved copy of this summary: ~/.claude/handoffs/r/LAB-42/compact/2026-10-21_14-05-12_5e55a001_c1-${nonce.slice(0, 6)}.md`)
})

test('AF-A4: the prefix past the start is taken only behind a header tag line; a kept message that quotes the prefix line is not a summary', () => {
  const body = 'This session is being continued from a previous conversation.\nSummary:\n1. ...'
  expect(summaryText(body)).toBe(body)
  expect(summaryText(ARTIFACT_HEAD + body)).toBe(body)
  expect(summaryText('the line it starts with:\n' + body)).toBeUndefined()
  expect(summaryText('<artifact-content-authored-by-others/>\nno summary here')).toBeUndefined()
})

/** The classic PostCompact hook's copy of the compaction now at the bottom, with this verdict (and nonce, by default its own).
 *  It says `writer: postcompact-fallback` on purpose: the old-copy case (copies before 0.1.3; the hooks write `postcompact` now,
 *  and readers take both). */
function hooksSaved(w: World, verdict: string, nonceOf: (n: string) => string = n => n): void {
  w.atCompact = () => {
    const n = markerNonce(w, w.compacts[w.compacts.length - 1]?.instructions) ?? ''
    const rel = `/.claude/handoffs/r/LAB-42/compact/2026-10-21_14-05-12_5e55a001_c1-${n.slice(0, 6)}.md`
    w.prevCopy = '~' + rel
    w.files.set(HOME + rel, `---\nkind: compact-summary\nwriter: postcompact-fallback\nnonce: ${nonceOf(n)}\nsession_id: ${SID_A}\nactor: main\nverdict: ${verdict}\n---\nbody\n`)
  }
}

test('AF-A2: summary not found by the mod: the hooks side\'s copy of this nonce gives the block its path and verdict; two in a row never halt', async ($, on) => {
  const w = new World().install(on)
  w.summaryMode = 'missing'
  hooksSaved(w, 'ok')
  await raiseCompact($, { trigger: 'auto' })
  await raiseCompact($, { trigger: 'auto' })
  const nonce = w.flag(w.callsOf('dispatch')[1], '--nonce') ?? ''
  expect(w.rowsOf('copy_failed').map(r => r.reason)).toEqual(['summary-not-found', 'summary-not-found'])
  expect(w.rowsOf('halt')).toEqual([])
  expect(w.toasts.some(t => t.includes('not in handoff format'))).toBe(false)
  const block = (await $.prompt.context({ blocks: [] })).blocks.find(b => b.name === `${w.name}-resume`)
  expect(block?.text).not.toContain('Summary not in handoff format')
  expect(block?.text).not.toContain('not saved')
  expect(block?.text).toContain(`saved copy of this summary: ~/.claude/handoffs/r/LAB-42/compact/2026-10-21_14-05-12_5e55a001_c1-${nonce.slice(0, 6)}.md`)
})

test('AF-A3: summary not found and no hooks-side verdict of this nonce (none, or another nonce\'s copy): not counted toward 2-nonok; a hooks-side non-ok verdict still counts', async ($, on) => {
  const w = new World().install(on)
  w.summaryMode = 'missing'
  await raiseCompact($, { trigger: 'auto' })
  hooksSaved(w, 'unshaped', () => 'deadbeef')
  await raiseCompact($, { trigger: 'auto' })
  expect(w.rowsOf('halt')).toEqual([])
  const block = (await $.prompt.context({ blocks: [] })).blocks.find(b => b.name === `${w.name}-resume`)
  expect(block?.text).toContain('saved copy of this summary: not saved (summary-not-found)')
  hooksSaved(w, 'unshaped')
  await raiseCompact($, { trigger: 'auto' })
  await raiseCompact($, { trigger: 'auto' })
  expect(w.rowsOf('halt').map(r => [r.reason, r.active])).toEqual([['2-nonok', true]])
})

test('after-step: saved copy, verdict ok, main sweep, block via prompt.context once', async ($, on) => {
  const w = new World().install(on)
  await raiseCompact($, { trigger: 'auto' })
  const nonce = w.flag(w.callsOf('dispatch')[0], '--nonce') ?? ''
  const save = w.callsOf('save-copy')[0]
  expect(w.flag(save, '--writer')).toBe('mod')
  expect(w.flag(save, '--scope')).toBe('main')
  expect(w.flag(save, '--from')).toBe(`${WATCH}/${SID_A}/pending/${nonce}.mod.md`)
  expect(w.flag(save, '--tokens')).toBe('100000,40000')
  expect(w.callsOf('sweep').length).toBe(1)
  expect(w.rowsOf('compacted')[0]?.nonce).toBe(nonce)
  const ctx = await $.prompt.context({ blocks: [{ name: 'currentDate', text: 'x' }] })
  const block = ctx.blocks.find(b => b.name === `${w.name}-resume`)
  expect(block?.text.startsWith(`The ${w.name} plugin adds this after compaction`)).toBe(true)
  expect(block?.text).not.toContain('Summary not in handoff format')
  expect(block?.text).toContain(`--origin ${SID_A} --item`)
  expect(block?.text).toContain('Git: main @ 3f9c2e1')
  expect((block?.text.length ?? 0) <= 6000).toBe(true)
  expect(w.claims.get(nonce)).toBe('prompt.context')
  const again = await $.prompt.context({ blocks: [] })
  expect(again.blocks.length).toBe(0)
})

test('after-step: EXISTS sha-match → copy_exists; EXISTS sha-differs → copy_mismatch + toast; REFUSED → copy_failed', async ($, on) => {
  const w = new World().install(on)
  w.saveLine = `EXISTS: ${ROOT}/r/x.md sha-match`
  await raiseCompact($, { trigger: 'auto' })
  w.saveLine = `EXISTS: ${ROOT}/r/x.md sha-differs`
  await raiseCompact($, { trigger: 'auto' })
  w.saveLine = 'REFUSED: root-in-git'
  await raiseCompact($, { trigger: 'auto' })
  expect(w.rowsOf('copy_exists').length).toBe(1)
  expect(w.rowsOf('copy_mismatch').length).toBe(1)
  expect(w.rowsOf('copy_failed').map(r => r.reason)).toEqual(['root-in-git'])
  expect(w.toasts.some(t => t.includes('copy-mismatch'))).toBe(true)
  expect(w.toasts.some(t => t.includes('copy-failed'))).toBe(true)
})

test('CC311-01: the Claude Code 2.1.311 installed form (tools-used block in a <system-reminder> block) matches the PostCompact copy: copy_exists, verdict ok, marker on line 1, no mismatch', async ($, on) => {
  const w = new World().install(on)
  w.summaryMode = 'cc311'
  w.postCompactSaved = true
  await raiseCompact($, { trigger: 'auto' })
  const nonce = w.flag(w.callsOf('dispatch')[0], '--nonce') ?? ''
  const installed = w.summaryMessages(w.compacts[0]?.instructions)[0]?.text ?? ''
  expect(installed).toContain('\n<system-reminder>\n<tools-used-before-summary>')
  const det = detectSummary(installed, w.name, { dispatchNonce: nonce, scope: 'main' })
  expect({ verdict: det.verdict, marker_line: det.marker_line, sentinel_from_end: det.sentinel_from_end }).toEqual({ verdict: 'ok', marker_line: 1, sentinel_from_end: 1 })
  expect(det.sha256).toBe(detectSummary(`<summary>\n${w.summaryBody(nonce, 'main')}</summary>`, w.name, { dispatchNonce: nonce, scope: 'main' }).sha256)
  expect(w.rowsOf('copy_exists').map(r => r.nonce)).toEqual([nonce])
  expect(w.rowsOf('copy_mismatch').length).toBe(0)
  expect(w.toasts.some(t => t.includes('copy-mismatch'))).toBe(false)
  expect(w.toasts.some(t => t.includes('not in handoff format'))).toBe(false)
})

test('RRP-04: after EXISTS sha-differs the mod neither rewrites its .mod.md stash nor retries save-copy (the helper settles the stash)', async ($, on) => {
  const w = new World().install(on)
  w.saveLine = `EXISTS: ${ROOT}/r/x.md sha-differs`
  await raiseCompact($, { trigger: 'auto' })
  await w.settle()
  const saves = w.callsOf('save-copy')
  expect(saves.length).toBe(1)
  const from = w.flag(saves[0], '--from') ?? ''
  expect(from.endsWith('.mod.md')).toBe(true)
  expect(w.writes.filter(p => p === from).length).toBe(1)
  expect(w.rowsOf('copy_mismatch').length).toBe(1)
})

test('AT-E-11: measured_block off: no Measured facts in the instructions', async ($, on) => {
  const w = new World().install(on)
  w.measured = 'Git: main @ 3f9c2e1'
  await raiseCompact($, { trigger: 'auto' })
  expect(w.compacts[0]?.instructions).not.toContain('Measured facts')
  expect(w.flag(w.callsOf('checkpoint')[0], '--measured')).toBeUndefined()
})

test('AT-E-11: measured_block on: block in the mod path, ≤3,000 B with its header', { options: { measured_block: true } }, async ($, on) => {
  const w = new World().install(on)
  w.measured = 'Git: feature/LAB-123-retry @ 3f9c2e1, 2 modified\n' + 'GSD: phase 2 of 4\n'.repeat(120)
  await raiseCompact($, { trigger: 'auto' })
  const instr = w.compacts[0]?.instructions ?? ''
  expect(w.callsOf('checkpoint')[0]?.args).toContain('--measured')
  const at = instr.indexOf('Measured facts below are the plugin')
  expect(at).toBeGreaterThan(0)
  const end = instr.indexOf('\nAim for 6–10K characters')
  const section = instr.slice(at, end)
  expect(section).toContain('Git: feature/LAB-123-retry')
  expect(bytes(section) <= 3000).toBe(true)
  await raiseCompact($, { trigger: 'precompute' })
  expect(w.compacts[1]?.instructions).not.toContain('Measured facts')
})

test('AT-E-12: precompute and subagent dispatches never call checkpoint or sweep', async ($, on) => {
  const w = new World().install(on)
  await raiseCompact($, { trigger: 'precompute' })
  await raiseCompact($, { trigger: 'auto', agentId: AGENT })
  expect(w.callsOf('checkpoint').length).toBe(0)
  expect(w.callsOf('sweep').length).toBe(0)
})

test('helper down: dispatch record written with $.fs.write, helper_missing in a fallback event file', async ($, on) => {
  const w = new World().install(on)
  await $.session.start({ cwd: '/w', surface: 'terminal', isInteractive: true })
  w.helperDown = true
  await raiseCompact($, { trigger: 'manual' })
  const nonce = markerNonce(w, w.compacts[0]?.instructions) ?? ''
  const rec = JSON.parse(w.files.get(`${WATCH}/${SID_A}/dispatch/${nonce}.json`) ?? '{}') as Record<string, unknown>
  // The helper's record keys in its order (dispatch.pm record): idle and idle_gap_s always;
  // `model` last, when the session's model was read.
  expect(Object.keys(rec)).toEqual(['v', 'nonce', 'session_id', 'actor', 'agent_id', 'trigger', 'channel', 'resume_pref', 'midturn', 'idle', 'idle_gap_s', 'tags', 'instructions_sha8', 'instructions_bytes', 'cc_version', 'cc_version_src', 'load_id', 'pid', 'pid_lstart', 'ts', 'model'])
  expect([rec.agent_id, rec.idle, rec.idle_gap_s]).toEqual([null, false, null])
  expect(rec.cc_version_src).toBe(typeof rec.cc_version === 'string' && rec.cc_version !== '' ? 'mod' : null)
  expect(rec.channel).toBe('mod-hook')
  expect(rec.nonce).toBe(nonce)
  const events = [...w.files.entries()].filter(([p]) => p.startsWith(`${WATCH}/${SID_A}/events/`)).map(([, t]) => JSON.parse(t) as { ev: string })
  expect(events.some(r => r.ev === 'helper_missing')).toBe(true)
  expect(events.some(r => r.ev === 'dispatch')).toBe(true)
})

test('F2-1 (S-21 order, mod side): inside next(), where PreCompact, SessionStart(compact) and PostCompact run before the boundary row exists, the dispatch record already carries the P1 proof; nothing is saved or swept yet', async ($, on) => {
  const w = new World().install(on)
  await $.session.start({ cwd: '/w', surface: 'terminal', isInteractive: true })
  const atBottom: { records: string[][]; saves: number; sweeps: number }[] = []
  w.atCompact = () => {
    atBottom.push({
      records: w.callsOf('dispatch').map(c => [w.flag(c, '--actor') ?? '', w.flag(c, '--channel') ?? '', w.flag(c, '--resume-pref') ?? '']),
      saves: w.callsOf('save-copy').length,
      sweeps: w.callsOf('sweep').length,
    })
  }
  await raiseCompact($, { trigger: 'auto' })
  await raiseCompact($, { trigger: 'auto', agentId: AGENT })
  expect(atBottom).toEqual([
    { records: [['main', 'mod-hook', 'prompt.context']], saves: 0, sweeps: 0 },
    { records: [['main', 'mod-hook', 'prompt.context'], [AGENT, 'mod-hook', 'none']], saves: 1, sweeps: 1 },
  ])
  // Helper down: the $.fs.write record carries the agent id the same way.
  w.atCompact = undefined
  w.helperDown = true
  await raiseCompact($, { trigger: 'auto', agentId: AGENT })
  const nonce = markerNonce(w, w.compacts[2]?.instructions) ?? ''
  const rec = JSON.parse(w.files.get(`${WATCH}/${SID_A}/dispatch/${nonce}.json`) ?? '{}') as Record<string, unknown>
  expect([rec.agent_id, rec.actor, rec.channel, rec.resume_pref]).toEqual([AGENT, AGENT, 'mod-hook', 'none'])
})

const CLOSE_MARK = '\u27eb'
const MAIN_MARKS = new RegExp(' v1 n=[0-9a-f]{8} s=main' + CLOSE_MARK, 'g')

function bytes(s: string): number {
  let n = 0
  for (const ch of s) {
    const c = ch.codePointAt(0) ?? 0
    n += c < 0x80 ? 1 : c < 0x800 ? 2 : c < 0x10000 ? 3 : 4
  }
  return n
}

void KEPT

test('compacted.skip is a class: a short token is kept, free text from a hook is logged as other', async ($, on) => {
  const w = new World().install(on)
  w.compactMode = { skip: 'vetoed' }
  await raiseCompact($, { trigger: 'auto' })
  w.compactMode = { skip: 'the user said: keep everything about the SQL migration' }
  await raiseCompact($, { trigger: 'auto' })
  expect(w.rowsOf('compacted').map(r => r.skip)).toEqual(['vetoed', 'other'])
  expect(JSON.stringify(w.rows)).not.toContain('SQL migration')
})

test('after-step toasts: non-ok verdict names it; the fourth main compaction toasts once', async ($, on) => {
  const w = new World().install(on)
  const fourth = () => w.toasts.filter(t => t === `${w.name}: 4 compactions in this session; consider /${w.name}:handoff and a fresh session.`).length
  w.summaryMode = 'truncated'
  await raiseCompact($, { trigger: 'auto' })
  expect(w.toasts).toContain(`${w.name}: compaction summary not in handoff format (truncated); the resume block adds a fallback note.`)
  w.summaryMode = 'ok'
  await raiseCompact($, { trigger: 'auto', agentId: AGENT })
  await raiseCompact($, { trigger: 'auto' })
  await raiseCompact($, { trigger: 'auto' })
  expect(fourth()).toBe(0)
  await raiseCompact($, { trigger: 'auto' })
  expect(fourth()).toBe(1)
  await raiseCompact($, { trigger: 'auto' })
  expect(fourth()).toBe(1)
  expect(w.toasts.filter(t => t.includes('not in handoff format')).length).toBe(1)
})

test('after-step toast: a summary over 12,000 chars gives the same toast once, on the first main compaction', async ($, on) => {
  const w = new World().install(on)
  const base = w.summaryMessages.bind(w)
  w.summaryMessages = instr => base(instr).map(m => (m.role === 'user' ? { ...m, text: m.text.replace('Status: active\n', 'Status: active\n' + 'x'.repeat(12001) + '\n') } : m))
  await raiseCompact($, { trigger: 'auto' })
  await raiseCompact($, { trigger: 'auto' })
  expect(w.toasts.filter(t => t.startsWith(`${w.name}: 4 compactions in this session`)).length).toBe(1)
  expect(w.toasts.some(t => t.includes('not in handoff format'))).toBe(false)
})

test('AT-M2-02 (across loads): a version already seen in $.store logs no second self_call_hook_ran', async ($, on) => {
  const w = new World()
  w.install(on, { 'selfcall:2.1.306': true })
  await $.session.start({ cwd: '/w', surface: 'terminal', isInteractive: true })
  const nonce = '1a2b3c4d'
  w.files.set(`${WATCH}/${SID_A}/dispatch/${nonce}.json`, JSON.stringify({ nonce, channel: 'mod-self' }))
  await raiseCompact($, { trigger: 'plugin', instructions: markerText(w.name, nonce, 'main') })
  expect(w.rowsOf('self_call_hook_ran').length).toBe(0)
  expect(w.callsOf('dispatch').length).toBe(0)
})

test('@remeasure@: the after-step measures for this compaction\'s nonce (its own evidence), also for another plugin\'s trigger:plugin call', async ($, on) => {
  const w = new World().install(on)
  await $.turn.start({ text: 'go on', turnId: 't1' })
  await raiseCompact($, { trigger: 'plugin' })
  const nonce = w.flag(w.callsOf('dispatch')[0], '--nonce')
  expect(nonce).toMatch(/^[0-9a-f]{8}$/)
  expect(w.callsOf('checkpoint').length).toBe(0)
  const m = w.callsOf('measure')
  expect(m.length).toBe(1)
  expect(w.flag(m[0], '--nonce')).toBe(nonce)
})

// Scoped carry (AT-AP-05, mod half): the
// re-measure names this compaction's saved copy, so the helper checks the summary's approvals.
test('AT-AP-05 (mod): the after-step measure passes --copy=<the saved copy save-copy printed>; no saved copy, no --copy; the delivery re-measure passes it too', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await raiseCompact($, { trigger: 'manual' })
  const nonce = w.flag(w.callsOf('dispatch')[0], '--nonce') ?? ''
  const copy = `~/.claude/handoffs/r/LAB-42/compact/2026-10-21_14-05-12_5e55a001_c1-${nonce.slice(0, 6)}.md`
  expect(w.callsOf('measure')[0]?.args).toContain('--copy=' + copy)
  await w.advance(601 * 1000)
  await $.prompt.context({ blocks: [] })
  expect(w.callsOf('measure')[1]?.args).toContain('--copy=' + copy)
  w.saveLine = 'REFUSED: no-bucket'
  await raiseCompact($, { trigger: 'manual' })
  const last = w.callsOf('measure')[w.callsOf('measure').length - 1]
  expect((last?.args ?? []).some(a => a.startsWith('--copy'))).toBe(false)
})

// C-STORE: the mod writes the orphan index marker before its stash.
test('AT-ST-03, AT-ST-07 (mod half): the after-step writes <watch>/.orphans/<sid> (empty) before pending/<nonce>.mod.md, main and subagent', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await raiseCompact($, { trigger: 'manual' })
  await raiseCompact($, { trigger: 'auto', agentId: AGENT })
  const marker = `${WATCH}/.orphans/${SID_A}`
  const stashes = w.writes.map((p, i) => [p, i] as const).filter(([p]) => p.startsWith(`${WATCH}/${SID_A}/pending/`) && p.endsWith('.mod.md'))
  expect(stashes.length).toBe(2)
  const marks = w.writes.map((p, i) => [p, i] as const).filter(([p]) => p === marker).map(([, i]) => i)
  expect(marks.length).toBe(2)
  expect(stashes.every(([, i], k) => (marks[k] ?? Infinity) < i)).toBe(true)
  expect(w.files.get(marker)).toBe('')
})

test('no vetted watch folder (ident refused every log folder): no marker and no stash', async ($, on) => {
  const w = new World().install(on)
  w.identWatch = null
  await w.start($)
  await raiseCompact($, { trigger: 'manual' })
  expect(w.writes.filter(p => p.includes('/.orphans/') || p.endsWith('.mod.md'))).toEqual([])
})

// QA-B3 (setting-driven, one text): the [queue] lines of
// the compaction text ride on queue_cmd, as the nudge's do; unset, they are dropped.
const QUEUE_LINE = 'A queued question (Questions shows its id)'
test('QA-B3 (mod part): queue_cmd set: the main compaction text keeps the [queue] lines and the dispatch tags name queue', { options: { queue_cmd: '/q/bin/queue' } }, async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await raiseCompact($, { trigger: 'auto' })
  expect(w.compacts[0]?.instructions ?? '').toContain(QUEUE_LINE)
  expect((w.flag(w.callsOf('dispatch')[0], '--tags') ?? '').split(',')).toContain('queue')
  // The subagent text never carries it.
  await raiseCompact($, { trigger: 'auto', agentId: AGENT })
  expect(w.compacts[1]?.instructions ?? '').not.toContain(QUEUE_LINE)
  expect(w.callsOf('queue-add').length).toBe(0)
})

test('QA-B3 (mod part): queue_cmd unset: no [queue] line and no queue tag', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await raiseCompact($, { trigger: 'auto' })
  expect(w.compacts[0]?.instructions ?? '').not.toContain(QUEUE_LINE)
  expect((w.flag(w.callsOf('dispatch')[0], '--tags') ?? '').split(',')).not.toContain('queue')
})

// 0.1.3 (root decision on the small-fixes review): a summary complete but for its closing line
// reads ok-unclosed, an ok verdict: no fallback note, no toast, never toward the 2-in-a-row halt;
// the compaction line names the word. A summary cut inside its body stays truncated.
test('ok-unclosed: complete but for the closing line: no nonok note or toast, two in a row never halt, the line names the word; cut in the body still halts', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  w.summaryMode = 'unclosed'
  await raiseCompact($, { trigger: 'auto' })
  await w.advance(COMPACT_LINE_DELAY_MS)
  await raiseCompact($, { trigger: 'auto' })
  await w.advance(COMPACT_LINE_DELAY_MS)
  expect(w.rowsOf('halt')).toEqual([])
  expect(w.toasts.some(t => t.includes('not in handoff format'))).toBe(false)
  const block = (await $.prompt.context({ blocks: [] })).blocks.find(b => b.name === `${w.name}-resume`)
  expect(block?.text).toBeDefined()
  expect(block?.text).not.toContain('Summary not in handoff format')
  expect(w.compactLines[0]).toBe(`${w.name}: compaction ok-unclosed · copy saved`)
  w.summaryMode = 'truncated'
  await raiseCompact($, { trigger: 'auto' })
  await raiseCompact($, { trigger: 'auto' })
  expect(w.rowsOf('halt').map(r => [r.reason, r.active])).toEqual([['2-nonok', true]])
})

// So the user can tell whether the compaction went well: one dim transcript line after
// every main compaction (compact.ts compactLine), never sent to the model, never for a subagent.
test('compaction line: ok main compaction: one line, copy saved, running jobs counted from the measure', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  w.measureBlock = 'Git: main @ 3f9c2e1, 0 modified, 0 untracked\nIn flight (sidecar 2026-10-30 07:35 +0200):\n  b1 · workflow · running\n  b2 · shell · running\n  b3 · shell · completed\nEvidence: none'
  await raiseCompact($, { trigger: 'auto' })
  await w.advance(COMPACT_LINE_DELAY_MS)
  expect(w.compactLines).toEqual([`${w.name}: compaction ok · copy saved · 2 jobs running`])
  // Nothing in flight: no count; a manual compaction gets its line too.
  w.measureBlock = 'Git: main @ 3f9c2e1, 0 modified, 0 untracked\nIn flight: none listed\nEvidence: none'
  await raiseCompact($, { trigger: 'manual' })
  await w.advance(COMPACT_LINE_DELAY_MS)
  expect(w.compactLines[1]).toBe(`${w.name}: compaction ok · copy saved`)
  // The model never reads it: the resume block does not carry it.
  const ctx = await $.prompt.context({ blocks: [] })
  expect(ctx.blocks.find(b => b.name === `${w.name}-resume`)?.text).not.toContain('compaction ok')
})

test('compaction line: not in handoff format, and no summary at all: NOT, the verdict, the copy state and the status pointer', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  w.summaryMode = 'unshaped'
  await raiseCompact($, { trigger: 'auto' })
  await w.advance(COMPACT_LINE_DELAY_MS)
  expect(w.compactLines).toEqual([`${w.name}: compaction NOT in handoff format (unshaped) · copy saved · see /${w.name}:status`])
  w.summaryMode = 'missing'
  await raiseCompact($, { trigger: 'auto' })
  await w.advance(COMPACT_LINE_DELAY_MS)
  expect(w.compactLines[1]).toBe(`${w.name}: compaction NOT in handoff format (unshaped) · copy NOT saved (summary-not-found) · see /${w.name}:status`)
  // An ok summary whose copy was refused still says so.
  w.summaryMode = 'ok'
  w.saveLine = 'REFUSED: root-in-git'
  await raiseCompact($, { trigger: 'auto' })
  await w.advance(COMPACT_LINE_DELAY_MS)
  expect(w.compactLines[2]).toBe(`${w.name}: compaction ok · copy NOT saved (root-in-git) · see /${w.name}:status`)
})

test('compaction line: none for a subagent compaction, a precompute or a skipped one', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await raiseCompact($, { trigger: 'auto', agentId: AGENT })
  await raiseCompact($, { trigger: 'precompute' })
  expect(w.callsOf('save-copy').length).toBe(1)
  // Claude Code skipped it: nothing was compacted, so no line either.
  w.compactMode = { skip: 'nothing to compact' }
  await raiseCompact($, { trigger: 'manual' })
  expect(w.rowsOf('compacted').map(r => r.skip)).toEqual([null, 'other'])
  await w.advance(COMPACT_LINE_DELAY_MS)
  expect(w.compactLines).toEqual([])
})

// Review of the first build: an after-step that throws (here its first store write) still gets
// a line, with the error class and the status pointer; never for a subagent.
test('compaction line: an after-step that failed says so', async ($, on) => {
  let down = false
  // Registered before World.install, so it stands outside the World's store (first is outermost).
  on('store.set', { key: 'idle_seen:' + SID_A }, (_$, e, next) => {
    if (down) throw new TypeError('store down')
    return next(e)
  })
  const w = new World().install(on)
  await w.start($)
  down = true
  await raiseCompact($, { trigger: 'auto' })
  // The kit hands a hook's throw back as its own error class.
  const rows = w.rowsOf('watch_error').map(r => [r.stage, r.error_class])
  expect(rows).toEqual([['after-step', 'HooksError']])
  // Held until the hook has returned, as the ok line is.
  expect(w.compactLines).toEqual([])
  await w.advance(COMPACT_LINE_DELAY_MS)
  expect(w.compactLines).toEqual([`${w.name}: compaction done · plugin step failed (HooksError) · see /${w.name}:status`])
})

test('compaction line: warn_ui false shows none', { options: { warn_ui: false } }, async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await raiseCompact($, { trigger: 'auto' })
  expect(w.rowsOf('compacted').length).toBe(1)
  await w.advance(COMPACT_LINE_DELAY_MS)
  expect(w.compactLines).toEqual([])
})

test('compactLine: a published handoff by file name, a cut-off handoff turn, one job', () => {
  const base = { ok: true, verdict: 'ok' as const, savedCopy: '/r/c.md', notSaved: undefined, running: 1 }
  expect(compactLine('p', { ...base, handoff: { published: '~/.claude/handoffs/p/x/2026-10-30_07-35-23_ab_x.md' } }))
    .toBe('p: compaction ok · copy saved · handoff 2026-10-30_07-35-23_ab_x.md · 1 job running')
  expect(compactLine('p', { ...base, running: 0, handoff: { draft: true, finish: 'fin' } })).toBe('p: compaction ok · copy saved · handoff cut off (draft present)')
  expect(compactLine('p', { ...base, running: 0, handoff: { draft: true, finish: null } })).toBe('p: compaction ok · copy saved · handoff cut off (draft absent)')
})

// Review of the second build, finding 1: Claude Code installs the hook's result (and the
// compaction boundary) once the hook has returned, so a native compaction's line is logged
// COMPACT_LINE_DELAY_MS after it, never inside the hook.
test('compaction line: a native compaction logs it after the hook has returned, not inside it', async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await raiseCompact($, { trigger: 'auto' })
  expect(w.compactLines).toEqual([])
  await w.advance(COMPACT_LINE_DELAY_MS - 1)
  expect(w.compactLines).toEqual([])
  await w.advance(1)
  expect(w.compactLines).toEqual([`${w.name}: compaction ok · copy saved`])
  await w.advance(60000)
  expect(w.compactLines.length).toBe(1)
})

// Review of the second build, finding 4: the plugin's own compaction (boundary.ts settleSelf)
// gets the step-failed line too, once, right after `$.session.compact` resolved.
test('compaction line: a plugin compaction whose after-step failed says so, once', { options: { precompact_turn: 'false' } }, async ($, on) => {
  let down = false
  on('store.set', { key: 'idle_seen:' + SID_A }, (_$, e, next) => {
    if (down) throw new TypeError('store down')
    return next(e)
  })
  const w = new World().install(on)
  await w.start($)
  await w.turnStart($)
  w.tokens = 410000
  await w.turnEnd($)
  down = true
  await w.advance(2000)
  expect(w.compacts.length).toBe(1)
  expect(w.flag(w.callsOf('dispatch')[0], '--channel')).toBe('mod-self')
  expect(w.rowsOf('watch_error').map(r => [r.stage, r.error_class])).toEqual([['after-step', 'HooksError']])
  expect(w.compactLines).toEqual([`${w.name}: compaction done · plugin step failed (HooksError) · see /${w.name}:status`])
  down = false
  await w.advance(60000)
  expect(w.compactLines.length).toBe(1)
})

// Review of the second build, finding 4: a subagent's after-step that fails (here the first
// clock read after its summary stash) logs its error row and shows no line.
test('compaction line: none for a subagent compaction whose after-step failed', async ($, on) => {
  let armed = false
  let boom = false
  // Outside the World's hooks (first is outermost): the stash write arms one failing clock read.
  on('fs.write', {}, (_$, e, next) => {
    if (armed && e.path.endsWith('.mod.md')) {
      armed = false
      boom = true
    }
    return next(e)
  })
  on('clock.now', {}, (_$, e, next) => {
    if (!boom) return next(e)
    boom = false
    throw new Error('clock unreadable')
  })
  const w = new World().install(on)
  await w.start($)
  armed = true
  await raiseCompact($, { trigger: 'auto', agentId: AGENT })
  expect(armed).toBe(false)
  expect(w.rowsOf('watch_error').map(r => [r.stage, r.error_class])).toEqual([['after-step', 'HooksError']])
  await w.advance(COMPACT_LINE_DELAY_MS)
  expect(w.compactLines).toEqual([])
})
