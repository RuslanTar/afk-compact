// Run-time asset grammar (compaction DESIGN-NOTES §2, BUILD-PLAN §3.4 items 2–5) over the
// rendered texts in assets.gen.ts. Same algorithm as tools/assemble and the helper's assembler,
// so the three give byte-identical text (BT-04).
import { assetText } from './assets.gen'
import type { AssetName } from './assets.gen'

export type Tag = 'midturn' | 'auto' | 'chain' | 'measured' | 'fallback' | 'nonok' | 'continue' | 'halt' | 'queue'

/** Runtime `@name@` values; a token with no value is left for the invariant check to catch. */
export type Runtime = Partial<Record<
  'nonce' | 'previous_copy' | 'measured_at' | 'measured_facts' | 'session_id' | 'saved_copy' | 'remeasure' | 'tokens' | 'queue_add',
  string
>>

const TAG = /^\[([a-z-]+)\] /

/**
 * Keeps a `[tag] ` line (tag removed) when its tag is active and not dropped, else drops it;
 * drops any line holding a `@name@` of a dropped block; joins by `\n`, strips, one trailing
 * `\n`; then fills `@name@` tokens. `queue` is never applied in v1 (D-10).
 */
export function assembleText(text: string, tags: readonly Tag[], runtime: Runtime, drop: readonly string[] = []): string {
  const active = new Set<string>(tags.filter(t => t !== 'queue'))
  const out: string[] = []
  for (const raw of splitLines(text)) {
    let line = raw
    const m = TAG.exec(line)
    if (m) {
      const tag = m[1] ?? ''
      if (!active.has(tag) || drop.includes(tag)) continue
      line = line.slice(m[0].length)
    }
    if (drop.some(d => line.includes(`@${d}@`))) continue
    out.push(line)
  }
  const s = pyStrip(out.join('\n')) + '\n'
  return s.replace(/@([a-z_]+)@/g, (whole, name: string) => {
    const v = (runtime as Record<string, string | undefined>)[name]
    return v === undefined ? whole : v
  })
}

export function assemble(plugin: string, asset: AssetName, tags: readonly Tag[], runtime: Runtime, drop: readonly string[] = []): string {
  return assembleText(assetText(asset, plugin), tags, runtime, drop)
}

/** BUILD-PLAN §3.4 item 5: no `[tag] ` line start, no `@…@`, no build-time brace token, no review comment. */
export function leftovers(s: string): string[] {
  const out: string[] = []
  const re = /^\[[a-z-]+\] |@[a-z_]+@|\{\{|<!-{2}/gm
  for (let m = re.exec(s); m !== null; m = re.exec(s)) out.push(m[0])
  return out
}

/** Python's str.splitlines() for the line breaks an asset can hold. */
function splitLines(s: string): string[] {
  const parts = s.split(/\r\n|\r|\n/)
  if (parts.length > 0 && parts[parts.length - 1] === '') parts.pop()
  return parts
}

/** Python's str.strip() for ASCII whitespace (what the reference assembler uses). */
function pyStrip(s: string): string {
  return s.replace(/^[ \t\n\r\f\v]+/, '').replace(/[ \t\n\r\f\v]+$/, '')
}
