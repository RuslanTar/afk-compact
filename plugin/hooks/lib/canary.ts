// Update-drift canaries on the mod side (MOD-SPEC §5.6): C1 version, C5 mod key set, C7 trigger.
import type { Deps } from './deps'
import { escalate, log } from './log'
import { sha8 } from './normalize'

/** C1 at `session.start`: `$.session.version()` vs `$.store` `lastVersion`, mirrored to version.json. */
export async function versionCanary(d: Deps, sid: string): Promise<void> {
  let v: { version: string; base?: string }
  try {
    v = await d.version()
  } catch {
    return
  }
  const to = v.version
  const isDev = to.endsWith('-dev') || (v.base ?? '').endsWith('-dev')
  const p = await d.paths()
  const mirrorPath = p ? `${p.watch}/version.json` : undefined
  let mirror: { lastVersion?: unknown; smokeDue?: unknown } = {}
  if (mirrorPath) {
    const t = await d.read(mirrorPath)
    if (t !== undefined) {
      try {
        mirror = JSON.parse(t) as typeof mirror
      } catch {
        mirror = {}
      }
    }
  }
  const stored = await d.storeGet('lastVersion')
  const from = typeof stored === 'string' ? stored : typeof mirror.lastVersion === 'string' ? mirror.lastVersion : undefined
  const dueStored = await d.storeGet('smokeDue')
  const due = typeof dueStored === 'string' ? dueStored : typeof mirror.smokeDue === 'string' ? mirror.smokeDue : null
  const trips = (from !== undefined && from !== to) || (isDev && due !== to)
  if (trips) {
    await log(d, sid, 'version_change', { from: from ?? null, to })
    await d.storeSet('lastVersion', to)
    await d.storeSet('smokeDue', to)
    if (mirrorPath) await d.write(mirrorPath, JSON.stringify({ lastVersion: to, smokeDue: to }) + '\n')
    escalate(d, 'version-change')
    return
  }
  if (from === undefined) {
    await d.storeSet('lastVersion', to)
    if (mirrorPath) await d.write(mirrorPath, JSON.stringify({ lastVersion: to, smokeDue: due }) + '\n')
  }
}

/** The four `session.compact` triggers this build knows (C7). */
export const TRIGGERS = ['manual', 'auto', 'plugin', 'precompute'] as const
export type Trigger = (typeof TRIGGERS)[number]

/**
 * ID-1 (owner D2 "native owns idle compaction", 2026-10-23): a trigger Claude Code is expected to
 * add (`idle`, upstream #101070) is handled exactly like the one it refines, wherever that one is
 * tested (checkpoint, the idle predicate, the after-step), with no `trigger_unknown` row. Nothing
 * keys on the "Compacted while idle" notice text.
 */
export const TRIGGER_ALIASES: Readonly<Record<string, Trigger>> = { idle: 'auto' }

/** C7: an unknown trigger logs `trigger_unknown` and is shaped as main `auto`. */
export async function triggerCanary(d: Deps, sid: string, trigger: string): Promise<Trigger> {
  if ((TRIGGERS as readonly string[]).includes(trigger)) return trigger as Trigger
  const alias = Object.prototype.hasOwnProperty.call(TRIGGER_ALIASES, trigger) ? TRIGGER_ALIASES[trigger] : undefined
  if (alias !== undefined) return alias
  await log(d, sid, 'trigger_unknown', { trigger: trigger.slice(0, 32) })
  escalate(d, 'trigger-unknown')
  return 'auto'
}

/**
 * C5 (mod side): sha8 of the sorted key set of the `session.compact` input against
 * `assets/canary-baseline.json` (`c5["session.compact"]`: one sha8 or a list), once per version.
 * No baseline, no row.
 */
export async function keysetCanary(d: Deps, sid: string, input: object): Promise<void> {
  const version = d.state.ccVersion ?? 'unknown'
  if (d.state.keysetLoggedFor.has(version)) return
  const keys = Object.keys(input).sort()
  const h = sha8(keys.join(','))
  const t = await d.read(d.root + '/assets/canary-baseline.json')
  if (t === undefined) return
  let want: unknown
  try {
    want = (JSON.parse(t) as { c5?: Record<string, unknown> }).c5?.['session.compact']
  } catch {
    return
  }
  const accepted = Array.isArray(want) ? want.filter(x => typeof x === 'string') : typeof want === 'string' ? [want] : []
  if (accepted.length === 0) return
  d.state.keysetLoggedFor.add(version)
  if (accepted.includes(h)) return
  await log(d, sid, 'keyset_change', { surface: 'session.compact', keyset_sha8: h, keys: keys.length })
  escalate(d, 'keyset-change')
}
