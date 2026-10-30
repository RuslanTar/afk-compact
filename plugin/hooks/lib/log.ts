// Mod rows (MOD-SPEC §2.5, WATCHER-SPEC §6.2 envelope): one `log` helper call per row, in order;
// when the helper call fails, one file per row under `<watch>/<sid>/events/`. Rows are
// content-free: ids, counts, enums, byte counts, durations, our own paths. One exception:
// `compact_rejected.error` and `compact_command.error` keep Claude Code's own rejection or
// failure text (trimmed, one line, no session content), in the local stream only; the export
// drops it.
import type { Deps } from './deps'
import { PLUGIN_VERSION } from './meta.gen'
import { randomHex } from './nonce'
import { call, ident } from './helper'
import { byteLength } from './normalize'

export type Fields = Record<string, string | number | boolean | null | readonly string[] | Record<string, number>>

const FORMATS = new Map<string, Intl.DateTimeFormat | null>()

/** A formatter of the named IANA zone's wall clock, or null when the engine does not know the zone. */
function zoneFormat(zone: string): Intl.DateTimeFormat | null {
  let f = FORMATS.get(zone)
  if (f !== undefined) return f
  try {
    f = new Intl.DateTimeFormat('en-US', {
      timeZone: zone, hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit',
      hour: '2-digit', minute: '2-digit', second: '2-digit',
    })
  } catch {
    f = null
  }
  if (FORMATS.size < 16) FORMATS.set(zone, f)
  return f
}

/** The wall clock of `ms` in `zone` and its offset in minutes; undefined when the zone is unknown. */
function zoneWall(ms: number, zone: string): { y: number; mo: number; d: number; h: number; mi: number; s: number; off: number } | undefined {
  const f = zoneFormat(zone)
  if (f === null) return undefined
  try {
    const part: Record<string, number> = {}
    for (const x of f.formatToParts(ms)) if (x.type !== 'literal') part[x.type] = Number(x.value)
    const y = part['year'], mo = part['month'], d = part['day'], h = part['hour'], mi = part['minute'], s = part['second']
    if (y === undefined || mo === undefined || d === undefined || h === undefined || mi === undefined || s === undefined) return undefined
    if (![y, mo, d, h, mi, s].every(Number.isInteger)) return undefined
    const wall = new Date(Date.UTC(2000, mo - 1, d, h, mi, s))
    wall.setUTCFullYear(y)
    const off = Math.round((wall.getTime() - Math.floor(ms / 1000) * 1000) / 60000)
    return { y, mo, d, h, mi, s, off }
  } catch {
    return undefined
  }
}

/**
 * ISO 8601 local time with milliseconds and the offset of that instant. `zone` is the system's
 * zone now (`stamp`, `zoneOf`); without it, or when the engine does not know it, the zone is the
 * one the engine read at load, which goes stale when the system zone changes under a running
 * session (0.1.2 log-tz). The helper's `log` also writes each row's ts at its own offset
 * (cmd/log.pl `_restamp`), a backstop for a row stamped in the engine's zone.
 */
export function isoLocal(ms: number, withMs = true, zone?: string): string {
  const p = (n: number, w = 2) => String(n).padStart(w, '0')
  const z = zone !== undefined ? zoneWall(ms, zone) : undefined
  const dt = new Date(ms)
  const w = z ?? {
    y: dt.getFullYear(), mo: dt.getMonth() + 1, d: dt.getDate(), h: dt.getHours(), mi: dt.getMinutes(), s: dt.getSeconds(),
    off: -dt.getTimezoneOffset(),
  }
  const sign = w.off >= 0 ? '+' : '-'
  const a = Math.abs(w.off)
  const msPart = ((ms % 1000) + 1000) % 1000
  const base = `${p(w.y, 4)}-${p(w.mo)}-${p(w.d)}T${p(w.h)}:${p(w.mi)}:${p(w.s)}`
  return base + (withMs ? '.' + p(msPart, 3) : '') + `${sign}${p(Math.floor(a / 60))}:${p(a % 60)}`
}

/**
 * The IANA zone a resolved `/etc/localtime` names (`.../zoneinfo/Etc/GMT-1`, a `posix/` or
 * `right/` tree too, or macOS's shipped `/usr/share/zoneinfo.default/` copy), when the engine
 * knows it; else undefined.
 */
export function zoneOfPath(real: string | undefined): string | undefined {
  if (real === undefined) return undefined
  // Greedy: the cut is at the last zoneinfo directory in the path.
  const m = /^.*\/zoneinfo(?:\.default)?\//.exec(real)
  if (m === null) return undefined
  const name = real.slice(m[0].length).replace(/^(?:posix|right)\//, '')
  if (!/^[A-Za-z][A-Za-z0-9_+-]*(?:\/[A-Za-z0-9_+-]+)*$/.test(name)) return undefined
  return zoneFormat(name) !== null ? name : undefined
}

/** The system zone now (`Deps.zone`, read again at each stamp), or undefined for the engine's own. */
export async function zoneOf(d: Deps): Promise<string | undefined> {
  if (d.zone === undefined) return undefined
  try {
    return await d.zone()
  } catch {
    return undefined
  }
}

/** `isoLocal` of `ms` in the system zone now. */
export async function stamp(d: Deps, ms: number, withMs = true): Promise<string> {
  return isoLocal(ms, withMs, await zoneOf(d))
}

export type Row = Record<string, unknown>

export async function makeRow(d: Deps, sid: string, ev: string, fields: Fields, actor = 'main'): Promise<Row> {
  const now = await d.now()
  const s = d.state
  // The state is read at `now`, before the zone lookup awaits its file check: a turn starting
  // during that check does not lend this row its turn_seq.
  const pid = s.ident?.pid ?? null
  const ccVersion = s.ccVersion
  const turnSeq = s.turnSeq
  return {
    v: 1,
    ts: await stamp(d, now),
    ev,
    sid,
    actor,
    writer: 'mod',
    pid,
    plugin_version: PLUGIN_VERSION,
    cc_version: ccVersion,
    turn_seq: turnSeq,
    ...fields,
  }
}

/** Appends one row to `<watch>/<sid>.jsonl` through the helper, or the fallback event file. */
export async function log(d: Deps, sid: string, ev: string, fields: Fields = {}, actor = 'main'): Promise<void> {
  const row = await makeRow(d, sid, ev, fields, actor)
  const line = JSON.stringify(row)
  if (byteLength(line) > 4096) return
  const r = await call(d, ['log', '--sid', sid, '--json', line])
  if (r.ok) return
  await fallback(d, sid, row)
  if (!d.state.helperMissingLogged) {
    d.state.helperMissingLogged = true
    await fallback(d, sid, await makeRow(d, sid, 'helper_missing', { stage: 'log', error_class: r.exitCode === null ? 'rejected' : 'exit-' + String(r.exitCode) }))
  }
}

async function fallback(d: Deps, sid: string, row: Row): Promise<void> {
  const p = await d.paths()
  if (!p) return
  const now = await d.now()
  await d.write(`${p.watch}/${sid}/events/${now}-${randomHex(4)}.json`, JSON.stringify(row) + '\n')
}

/**
 * A `skip` reason as a row value (WATCHER-SPEC §6.3 `compacted.skip`: null or a class). Any
 * hook can set the reason, so its free text is never logged: a short token is kept, else `other`
 * (the free-text fields are `compact_rejected.error` and `compact_command.error`, see the header).
 */
export function skipClass(reason: string): string {
  return /^[A-Za-z0-9._:-]{1,40}$/.test(reason) ? reason : 'other'
}

/**
 * The load is headless (`claude -p`, the Agent SDK, or an app or editor built on it): Claude Code
 * rejects a plugin's `$.session.compact` there, so from here on in this load the plugin gives no
 * nudge, handoff turn or idle turn, and compacts only by running `/compact` at a turn end
 * (`compact: command`; boundary.ts) until that path is off (`compact: none`, `compactOff`). One
 * `headless {via, compact}` row per session id, from what told it: `session-start` (no person at
 * the prompt), `compact-rejected` (Claude Code's own answer), or `same-load` (the first main turn
 * of a new session id in a load already headless, as after a `/clear`, for which no
 * `session.start` fires).
 */
export async function markHeadless(d: Deps, sid: string, via: 'session-start' | 'compact-rejected' | 'same-load'): Promise<void> {
  const s = d.state
  if (s.headless && s.headlessSid === sid) return
  if (!s.headless) s.nudgeNonce = undefined
  s.headless = true
  s.headlessSid = sid
  await log(d, sid, 'headless', { via, compact: s.headlessCompact })
}

/**
 * The `/compact` path cannot work in this headless load (no such command, the host's input
 * ended) or failed twice in a row: no plugin compaction from here on in it. One more `headless`
 * row, `{via: command-failed, compact: none}`, which `/status` reads.
 */
export async function compactOff(d: Deps, sid: string): Promise<void> {
  const s = d.state
  if (s.headlessCompact === 'none') return
  s.headlessCompact = 'none'
  s.headlessSid = sid
  await log(d, sid, 'headless', { via: 'command-failed', compact: 'none' })
}

/** Records one helper-missing row for a non-log helper call (once per load). */
export async function helperMissing(d: Deps, sid: string, stage: string): Promise<void> {
  if (d.state.helperMissingLogged) return
  d.state.helperMissingLogged = true
  await log(d, sid, 'helper_missing', { stage })
}

/** One `ident` call per load: pid, its start time and the helper's effective watch folder. */
export async function ensureIdent(d: Deps, sid: string): Promise<void> {
  if (d.state.ident) return
  const id = await ident(d, sid)
  if (id) d.state.ident = id
  else {
    d.state.ident = { pid: null, pid_lstart: null }
    await helperMissing(d, sid, 'ident')
  }
}

/**
 * The watch folder the helper vetted (MOD-SPEC §1.2 unsafe roots, PRIV-04), or undefined: when
 * `ident` refused every log folder (null) or gave no answer. Raw text (the summary stash) is
 * written only here, never under the folder the options name.
 */
export async function vettedWatch(d: Deps, sid: string): Promise<string | undefined> {
  await ensureIdent(d, sid)
  const w = d.state.ident?.watch
  return typeof w === 'string' ? w.replace(/\/+$/, '') : undefined
}

/**
 * The toast for an escalation row (MOD-SPEC §5.5: log + toast where the mod runs, never an
 * action), once per kind per load. Wording is provisional: the design names the toast, not its
 * text, except the two after-step toasts of MOD-SPEC §5.2 (see `toastOnce`).
 */
export function escalate(d: Deps, row: string): void {
  toastOnce(d, row, `${d.name}: ${row}; see /${d.name}:status`)
}

export function toastOnce(d: Deps, key: string, text: string): void {
  if (d.state.toasted.has(key)) return
  d.state.toasted.add(key)
  d.toast(text)
}
