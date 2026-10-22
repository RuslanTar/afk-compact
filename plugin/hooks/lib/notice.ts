// The watcher's first-run notice (WATCHER-SPEC §8 item 8, W-BETA A). At a main `session.start`
// the mod asks the helper `notice claim --id <id>`; the helper creates
// `<watch>/notice/<id>.shown` exclusively and answers `show` (first time) or `seen`. On `show`
// the mod shows the fixed text once, for 20 s, whatever `warn_ui` says: a one-time transparency
// notice, not a warning. The id carries the notice version, so a bump shows it again. The text
// holds no user content.
import type { Deps } from './deps'
import { specValue } from './detect'
import { call } from './helper'

/** Notice id (version 1) and text when the spec-literals block has no `notice` object yet. */
export const NOTICE_ID = 'watcher-1'
export const NOTICE_MS = 20000
export const NOTICE_MAX = 200

/** The fixed text for a plugin name (the spec asset's wording, W-BETA A). */
export function noticeFallback(name: string): string {
  return `${name}: local compaction logs are on (content-free; nothing is sent). To share them: /${name}:report. To turn them off: set watcher to off in /config.`
}

/**
 * The notice id and text from a spec-literals `notice` value `v` (`id`, and `text` with the
 * plugin name filled in at build time) when it has both, else the built-in pair. `v` is always
 * passed: `undefined` means "no notice object", never "read the shipped one".
 */
export function noticeSpec(name: string, v: unknown): { id: string; text: string } {
  if (typeof v === 'object' && v !== null) {
    const o = v as Record<string, unknown>
    if (typeof o.id === 'string' && /^[a-z0-9-]{1,40}$/.test(o.id) && typeof o.text === 'string' && o.text !== '') return { id: o.id, text: o.text }
  }
  return { id: NOTICE_ID, text: noticeFallback(name) }
}

/** The pair this build shows: from the shipped spec-literals `notice` object, else the built-in one. */
export function shippedNotice(name: string): { id: string; text: string } {
  return noticeSpec(name, specValue('notice'))
}

/** `watcher` as the helper reads it (trimmed, case-folded); only `off` turns the logs off. */
export function watcherOff(v: unknown): boolean {
  return typeof v === 'string' && v.trim().toLowerCase() === 'off'
}

/** Main `session.start`: claims the notice and shows it the first time; nothing with `watcher` off. */
export async function showNotice(d: Deps, sid: string): Promise<void> {
  if (d.cfg.watcher_off) return
  const n = shippedNotice(d.name)
  void sid // the claim is per install, not per session (WATCHER-SPEC §8 item 8)
  const r = await call(d, ['notice', 'claim', '--id', n.id])
  if (!r.ok || r.stdout.trim() !== 'show') return
  d.notice(n.text.slice(0, NOTICE_MAX), NOTICE_MS)
}
