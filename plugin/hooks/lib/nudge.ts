// The mid-turn nudge (MOD-SPEC §9): main `tool.call` results only, never subagents, once per
// main turn, at or above the effective soft max, never on a denied call. Also: the open
// AskUserQuestion count, and the temp paths cited in tool inputs (MOD-SPEC §10 sweep scope).
import type { Deps } from './deps'
import type { Tag } from './assemble'
import { assemble } from './assemble'
import { effective } from './config'
import { call } from './helper'
import { log, makeRow } from './log'

export const ASK_TOOL = 'AskUserQuestion'

/** `612,345`: the token count as the nudge shows it. */
export function formatTokens(n: number): string {
  return String(Math.round(n)).replace(/\B(?=(\d{3})+(?!\d))/g, ',')
}

/** The nudge text for the current mode, or undefined when no nudge is due after this call. */
export async function nudgeText(d: Deps, sid: string): Promise<string | undefined> {
  const s = d.state
  if (s.nudgedThisTurn) return undefined
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
  const tags: Tag[] = [s.halt.active ? 'halt' : 'continue']
  await log(d, sid, 'nudge', { tokens, askq_open: s.askOpen > 0, halt: s.halt.active })
  return assemble(d.name, 'checkpoint-nudge', tags, { tokens: formatTokens(tokens) })
}

const TEMP = /(?:\/private)?\/tmp\/[^\s'"`;|&<>()]+|\/var\/folders\/[^\s'"`;|&<>()]+|\/[^\s'"`;|&<>()]*\/scratchpad\/[^\s'"`;|&<>()]+|[^\s'"`;|&<>()]*tasks\/[^\s/'"`;|&<>()]+\.output/g

function strings(v: unknown, out: string[], depth = 0): void {
  if (depth > 4 || out.length > 64) return
  if (typeof v === 'string') out.push(v)
  else if (Array.isArray(v)) for (const x of v) strings(x, out, depth + 1)
  else if (v !== null && typeof v === 'object') for (const x of Object.values(v)) strings(x, out, depth + 1)
}

/** Temp paths in a tool call's input (the sweep scope of MOD-SPEC §10), new ones only. */
export function tempPaths(input: Record<string, unknown>, seen: (p: string) => boolean = () => false): string[] {
  const texts: string[] = []
  for (const [k, v] of Object.entries(input)) if (k !== 'tool' && k !== 'agentId' && k !== 'tool_use_id') strings(v, texts)
  const found: string[] = []
  for (const t of texts) {
    for (const m of t.matchAll(TEMP)) {
      const p = m[0].replace(/[.,:]+$/, '')
      if (p.length > 1024 || seen(p) || found.includes(p)) continue
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

/** Appends the cited temp paths to `<watch>/<sid>/paths.jsonl` (`log --stream paths`). */
export async function recordPaths(d: Deps, sid: string, tool: string, input: Record<string, unknown>): Promise<void> {
  const seen = d.state.recordedPaths
  const found = tempPaths(input, p => seen.has(sid + '\n' + p))
  for (const p of found) {
    seen.add(sid + '\n' + p)
    const row = await makeRow(d, sid, 'path', { path: p, tool })
    await call(d, ['log', '--sid', sid, '--stream', 'paths', '--json', JSON.stringify(row)])
  }
}
