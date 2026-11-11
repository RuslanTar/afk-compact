// The mid-turn nudge: main `tool.call` results only, never subagents, once per
// main turn (never in the handoff turn), at or above the effective soft max, never on a
// denied call; `[halt]` with its reason in a last cycle, `[queue]` when `queue_cmd` is set. Also: the open
// AskUserQuestion count, and the temp paths cited in tool inputs (the sweep scope).
import type { Deps } from './deps'
import { storeWord } from './deps'
import type { Runtime, Tag } from './assemble'
import { assemble } from './assemble'
import { dispatchExists } from './compact'
import { effective } from './config'
import { lastCycleOf } from './cont'
import { HALT_REASON_TEXT, handoffPossible } from './handoff-turn'
import { logPaths } from './helper'
import { escalate, log, makeRow } from './log'
import { drawNonce } from './nonce'
import { byteLength } from './normalize'

export const ASK_TOOL = 'AskUserQuestion'

/** `612,345`: the token count as the nudge shows it. */
export function formatTokens(n: number): string {
  return String(Math.round(n)).replace(/\B(?=(\d{3})+(?!\d))/g, ',')
}

/** The nudge text for the current mode, or undefined when no nudge is due after this call. */
export async function nudgeText(d: Deps, sid: string): Promise<string | undefined> {
  const s = d.state
  // A headless session gets no nudge: no plugin compaction can follow it there.
  if (s.nudgedThisTurn || s.headless) return undefined
  const eff = await effective(d, sid)
  if (eff.disabled) return undefined
  let tokens: number | undefined
  try {
    tokens = (await d.usage()).tokens
  } catch {
    tokens = undefined
  }
  if (tokens === undefined || tokens < eff.soft_max) return undefined
  s.nudgedThisTurn = true
  s.resumeAfter = true
  // A last cycle gets `[halt]` with its reason, and the handoff-turn sentence
  // only when that turn can run, so the nudge never promises a resume or a turn that won't come.
  const last = await lastCycleOf(d, sid)
  s.lastCycle = last
  const tags: Tag[] = last === null ? ['continue'] : ['halt']
  if (last !== null && (await handoffPossible(d, sid))) tags.push('halt-handoff')
  const runtime: Runtime = { tokens: formatTokens(tokens) }
  if (last !== null) runtime.halt_reason = HALT_REASON_TEXT[last]
  // `[queue]` whenever `queue_cmd` is set (no I/O here); the nonce it names is the one this
  // cycle's plugin compaction then uses.
  // `queue_add` starts with the launcher word; a root no quoting can carry
  // drops `[queue]` and escalates (A.1).
  if (d.cfg.queue_cmd !== '') {
    const store = storeWord(d.root, d.name)
    if (store === undefined) escalate(d, 'store_path_unquotable')
    else {
      s.nudgeNonce = await drawNonce(n => dispatchExists(d, sid, n))
      tags.push('queue')
      runtime.queue_add = store + ` queue-add --sid ${sid} --nonce ${s.nudgeNonce}`
    }
  }
  await log(d, sid, 'nudge', { tokens, askq_open: s.askOpen > 0, halt: s.halt.active, last_cycle: last })
  return assemble(d.name, 'checkpoint-nudge', tags, runtime)
}

// A temp path starts a path: at the string's start or after whitespace, a quote, a
// backtick, `=`, `(`, `<` or `>`, never inside a URL (`https://host/tmp/...`). `?` and `#`
// end it, so a query string or fragment (which can hold a token) is never recorded.
const TEMP =
  /(?<=^|[\s'"`=(<>])(?:(?:\/private)?\/tmp\/[^\s'"`;|&<>()?#]+|(?:\/private)?\/var\/folders\/[^\s'"`;|&<>()?#]+|\/[^\s'"`;|&<>()?#]*\/scratchpad\/[^\s'"`;|&<>()?#]+|[^\s'"`;|&<>()?#]*tasks\/[^\s/'"`;|&<>()?#]+\.output)/g

function strings(v: unknown, out: string[], depth = 0): void {
  if (depth > 4 || out.length > 64) return
  if (typeof v === 'string') out.push(v)
  else if (Array.isArray(v)) for (const x of v) strings(x, out, depth + 1)
  else if (v !== null && typeof v === 'object') for (const x of Object.values(v)) strings(x, out, depth + 1)
}

/** The path without the shell assignment or wait spec it was cut with (`F=/tmp/x`, `exit:/tmp/x`). */
export function cutPrefix(p: string): string {
  const m = /^[A-Za-z_][A-Za-z0-9_-]*[=:](\/[\s\S]*)$/.exec(p)
  return m?.[1] ?? p
}

/**
 * A piece of a command, not a file, by its text alone (the helper's skills/begin.pm junk_path, one
 * table pins both: tests/fixtures/paths/junk-paths.json): not absolute, an unexpanded variable, a
 * glob or brace, a backslash, a `...` part, a last `-` (a prefix cut at a variable) or a printf
 * directive. Such a path never reaches paths.jsonl or the evidence sweep.
 */
export function junkPath(p: string): boolean {
  if (!p.startsWith('/')) return true
  if (/\$(?:[A-Za-z_{($]|$)/.test(p)) return true
  if (/[*[\]{}\\]/.test(p)) return true
  if (/(?:^|\/)\.\.\.(?:\/|$)/.test(p)) return true
  if (p.endsWith('-')) return true
  return /%[-+ #0]*[0-9]*(?:\.[0-9]+)?[sdifxXcu]/.test(p)
}

/** Temp paths in a tool call's input (the sweep scope), new ones only, junk left out. */
export function tempPaths(input: Record<string, unknown>, seen: (p: string) => boolean = () => false): string[] {
  const texts: string[] = []
  for (const [k, v] of Object.entries(input)) if (k !== 'tool' && k !== 'agentId' && k !== 'tool_use_id') strings(v, texts)
  const found: string[] = []
  for (const t of texts) {
    for (const m of t.matchAll(TEMP)) {
      const p = cutPrefix(m[0].replace(/[.,:]+$/, ''))
      if (p.length > 1024 || junkPath(p) || seen(p) || found.includes(p)) continue
      found.push(p)
      if (found.length >= 20) return found
    }
  }
  return found
}

/** Keeps a background `recordPaths` run where a test can await it; its failure is swallowed. */
export function trackPaths(state: Deps['state'], run: Promise<void>): void {
  const safe = run.catch(() => undefined)
  const prev = state.pathsInflight
  state.pathsInflight = prev ? Promise.all([prev, safe]) : safe
}

/**
 * Appends the cited temp paths to `<watch>/<sid>/paths.jsonl`: one `log --stream paths --stdin`
 * spawn per tool call, all its new paths as JSON lines. A row over 4 KB is not sent.
 */
export async function recordPaths(d: Deps, sid: string, tool: string, input: Record<string, unknown>): Promise<void> {
  const seen = d.state.recordedPaths
  const found = tempPaths(input, p => seen.has(sid + '\n' + p))
  const lines: string[] = []
  for (const p of found) {
    seen.add(sid + '\n' + p)
    const line = JSON.stringify(await makeRow(d, sid, 'path', { path: p, tool }))
    if (byteLength(line) + 1 <= 4096) lines.push(line)
  }
  await logPaths(d, sid, lines)
}
