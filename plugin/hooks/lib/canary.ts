// Update-drift canaries on the mod side (MOD-SPEC §5.6): C1 version, C5 mod key set, C7 trigger.
import type { Deps } from './deps'
import { escalate, log } from './log'
import { sha8 } from './normalize'

/** `$.store` key: the versions any session on this machine ran, oldest first (C1). */
export const SEEN_KEY = 'cc_versions_seen'
/** `$.store` key: `{ [sid]: version }`, the version each recent session last ran (C1, per session). */
export const BY_SID_KEY = 'cc_version_by_sid'
/** Bounds on the two keys (the store is one JSON file of at most 4 MiB). */
export const SEEN_MAX = 32
export const BY_SID_MAX = 256

function strings(v: unknown): string[] {
  return Array.isArray(v) ? v.filter((x): x is string => typeof x === 'string') : []
}

function bySid(v: unknown): Record<string, string> {
  const out: Record<string, string> = {}
  if (typeof v !== 'object' || v === null || Array.isArray(v)) return out
  for (const [k, x] of Object.entries(v as Record<string, unknown>)) if (typeof x === 'string') out[k] = x
  return out
}

/**
 * C1 at `session.start`: one `version_change {from, to}` row, `smokeDue`, the version.json mirror
 * and one escalation, when either holds.
 * - Machine: this version is new to the machine. It differs from `lastVersion` and no session here
 *   ran it before (`cc_versions_seen`), or it is a dev build not yet due. `from` is `lastVersion`.
 *   A session on a version another session already ran logs nothing (probe 2026-10-27 P5: a fresh
 *   session on 2.1.310 after P12's 2.1.311 logged a downgrade and moved smokeDue back).
 * - Session: this session itself ran another version before (`cc_version_by_sid`): a background
 *   session the supervisor moved, a `claude --resume` or `claude respawn` on another binary.
 *   `from` is that version. Only the row and the escalation: the smoke check stays machine-wide.
 */
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
  // Before the first write of the set (or with the store lost), the machine has seen lastVersion.
  const seenStored = strings(await d.storeGet(SEEN_KEY))
  const seen = seenStored.length > 0 ? seenStored : from !== undefined ? [from] : []
  const trips = (from !== undefined && from !== to && !seen.includes(to)) || (isDev && due !== to)
  if (!seen.includes(to) || seenStored.length === 0) await d.storeSet(SEEN_KEY, [...seen.filter(x => x !== to), to].slice(-SEEN_MAX))
  const sids = bySid(await d.storeGet(BY_SID_KEY))
  const ownFrom = Object.prototype.hasOwnProperty.call(sids, sid) ? sids[sid] : undefined
  if (ownFrom !== to) {
    delete sids[sid]
    sids[sid] = to
    const keys = Object.keys(sids)
    for (const k of keys.slice(0, Math.max(0, keys.length - BY_SID_MAX))) delete sids[k]
    await d.storeSet(BY_SID_KEY, sids)
  }
  const moved = ownFrom !== undefined && ownFrom !== to
  if (trips || moved) await log(d, sid, 'version_change', { from: (moved ? ownFrom : from) ?? null, to })
  if (trips) {
    await d.storeSet('lastVersion', to)
    await d.storeSet('smokeDue', to)
    if (mirrorPath) await d.write(mirrorPath, JSON.stringify({ lastVersion: to, smokeDue: to }) + '\n')
  } else if (from === undefined) {
    await d.storeSet('lastVersion', to)
    if (mirrorPath) await d.write(mirrorPath, JSON.stringify({ lastVersion: to, smokeDue: due }) + '\n')
  }
  if (trips || moved) escalate(d, 'version-change')
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
