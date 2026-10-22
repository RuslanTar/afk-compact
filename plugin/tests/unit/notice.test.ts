// U tests through the kit: the watcher's first-run notice (WATCHER-SPEC §8 item 8, W-BETA A).
import { expect, test } from 'claude-code/testing'
import { leftovers } from '../../hooks/lib/assemble'
import { NOTICE_ID, NOTICE_MAX, noticeFallback, noticeSpec } from '../../hooks/lib/notice'
import { WATCH, World } from './harness.test'

test('AT-WB-12 (mod half): two session.start calls give one toast, shown with warn_ui false; the marker is the helper claim', { options: { warn_ui: false } }, async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  await w.start($)
  const text = noticeSpec(w.name).text
  expect(w.toasts).toEqual([text])
  expect(w.callsOf('notice').map(c => c.args)).toEqual([['claim', '--id', NOTICE_ID], ['claim', '--id', NOTICE_ID]])
  expect(w.files.has(`${WATCH}/notice/${NOTICE_ID}.shown`)).toBe(true)
})

test('AT-WB-12: the text is fixed, at most 200 characters, with no template leftovers; a version bump (a new id) shows it again', () => {
  for (const name of ['x', 'x'.repeat(16), 'compactinue']) {
    const t = noticeFallback(name)
    expect(t.length <= NOTICE_MAX).toBe(true)
    expect(leftovers(t)).toEqual([])
  }
  expect(noticeSpec('x', { id: 'watcher-2', text: 'x: logs are on.' })).toEqual({ id: 'watcher-2', text: 'x: logs are on.' })
  expect(noticeSpec('x', { id: 'bad id', text: 't' }).id).toBe(NOTICE_ID)
  expect(noticeSpec('x', undefined)).toEqual({ id: NOTICE_ID, text: noticeFallback('x') })
})

test('AT-WB-12: a bumped id shows the notice again in an install that saw the old one', async ($, on) => {
  const w = new World().install(on)
  w.files.set(`${WATCH}/notice/watcher-0.shown`, '')
  await w.start($)
  expect(w.toasts.length).toBe(1)
})

test('watcher off: no notice claim and no toast', { options: { watcher: ' OFF ' } }, async ($, on) => {
  const w = new World().install(on)
  await w.start($)
  expect([w.callsOf('notice').length, w.toasts.length]).toEqual([0, 0])
})

test('the helper refuses or is missing: no toast', async ($, on) => {
  const w = new World().install(on)
  w.replies.notice = () => ({ exitCode: 64, stdout: '' })
  await w.start($)
  expect(w.toasts.length).toBe(0)
})
