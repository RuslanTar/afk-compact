// Mod rows (MOD-SPEC §2.5, WATCHER-SPEC §6.2 envelope): one `log` helper call per row, in order;
// when the helper call fails, one file per row under `<watch>/<sid>/events/`. Rows are
// content-free: ids, counts, enums, byte counts, durations, our own paths.
import type { Deps } from './deps'
import { PLUGIN_VERSION } from './meta.gen'
import { randomHex } from './nonce'
import { call, ident } from './helper'
import { byteLength } from './normalize'

export type Fields = Record<string, string | number | boolean | null | readonly string[] | Record<string, number>>

/** ISO 8601 local time with milliseconds and offset. */
export function isoLocal(ms: number, withMs = true): string {
  const dt = new Date(ms)
  const off = -dt.getTimezoneOffset()
  const sign = off >= 0 ? '+' : '-'
  const a = Math.abs(off)
  const p = (n: number, w = 2) => String(n).padStart(w, '0')
  const base = `${dt.getFullYear()}-${p(dt.getMonth() + 1)}-${p(dt.getDate())}T${p(dt.getHours())}:${p(dt.getMinutes())}:${p(dt.getSeconds())}`
  return base + (withMs ? '.' + p(dt.getMilliseconds(), 3) : '') + `${sign}${p(Math.floor(a / 60))}:${p(a % 60)}`
}

export type Row = Record<string, unknown>

export async function makeRow(d: Deps, sid: string, ev: string, fields: Fields, actor = 'main'): Promise<Row> {
  const now = await d.now()
  const s = d.state
  return {
    v: 1,
    ts: isoLocal(now),
    ev,
    sid,
    actor,
    writer: 'mod',
    pid: s.ident?.pid ?? null,
    plugin_version: PLUGIN_VERSION,
    cc_version: s.ccVersion,
    turn_seq: s.turnSeq,
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
 * hook can set the reason, so free text is never logged: a short token is kept, else `other`.
 */
export function skipClass(reason: string): string {
  return /^[A-Za-z0-9._:-]{1,40}$/.test(reason) ? reason : 'other'
}

/**
 * The session is headless (`claude -p`, the Agent SDK): from here on in this load the plugin
 * neither nudges nor starts a compaction. One `headless {via}` row per load, from what told it:
 * `session-start` (no person at the prompt) or `compact-rejected` (Claude Code's own answer).
 */
export async function markHeadless(d: Deps, sid: string, via: 'session-start' | 'compact-rejected'): Promise<void> {
  if (d.state.headless) return
  d.state.headless = true
  d.state.nudgeNonce = undefined
  await log(d, sid, 'headless', { via })
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
