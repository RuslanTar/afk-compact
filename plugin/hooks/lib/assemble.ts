// Run-time asset grammar (compaction DESIGN-NOTES §2, BUILD-PLAN §3.4 items 2–5) over the
// rendered texts in assets.gen.ts. Same algorithm as tools/assemble and the helper's assembler,
// so the three give byte-identical text (BT-04).
import { ASSET_NAMES, assetText } from './assets.gen'
import type { AssetName } from './assets.gen'

/**
 * Line tags (DESIGN-NOTES §2 tag table). D-18 adds `handoff` and `handoff-partial` (main text,
 * resume block), `halt-handoff` (the nudge's handoff-turn sentence) and the handoff-turn asset's
 * `submit`, `near`, `spent` and `imminent`. 2026-10-22 (MOD-SPEC §3.4, BUILD-PLAN §3.4): the
 * resume block's `prod-forbid`/`prod-allow` (exactly one) and `idle` (never with `midturn`), and
 * the handoff-turn asset's `submit-halt`, `submit-pre` and `submit-idle` (one per turn kind).
 * 2026-10-23: the resume block's `idle-halt` (owner xxxxxxxx-25: `[idle]` in halt mode, never with
 * `idle` or `midturn`) and `idle-again` (owner xxxxxxxx-37: the block again on a person's return).
 * 2026-10-26: the resume block's `driver` (owner, GSD re-entry per session: kept only when the
 * re-measure names this session's `Active driver:`).
 * 2026-10-27: the resume block's `idle-done` (away digest phase 1, owner 2026-10-27 12:5x: the idle line
 * of a finished or blocked work lane; never with `idle`, `idle-halt`, `midturn` or `driver`).
 * 2026-10-27: `trial-tail` of the shadow trial's old-arm adapter (TRIAL-DUAL-HANDOFF §4.1: the last
 * reply and a newly typed prompt, kept only when there is one).
 * 2026-10-30: the resume block's `idle-off` and `idle-done-off` (owner rule (c), 2026-10-28:
 * `[idle]` and `[idle-done]` under `idle_digest: off`, which ask for one line on the lane state in
 * place of the away digest; in the same exclusive idle group).
 * 2026-10-30: the resume block's `handoff-ack` (owner 2026-10-30 07:49, "short message after
 * compaction": a published handoff whose report was not sent gets one ack line; only with `handoff`).
 * 0.1.2: the resume block's `question` (question carry, investigation wf_c3788b4f-00e fix 1: the
 * question a main turn ended on that no person's turn has followed yet; beside any other tag).
 * 2026-10-31: the resume block's `auto-mode` (D-22, root: in auto permission mode the classifier
 * blocks a gated outward action a carried approval covers, so the block asks first; kept only
 * when the mod saw auto as the newest main permission mode, `autoModeOf` in resume.ts).
 * 0.1.3: the resume block's `resumed` (resume-text A: one code-rendered first line, `Resumed · step
 * 1: …`; never with `handoff-ack` or `idle-again`) and `question-timeout` (resume-text B: the carried
 * question's dialog timed out; only with `question`).
 */
export type Tag =
  | 'midturn' | 'auto' | 'chain' | 'measured' | 'fallback' | 'nonok' | 'continue' | 'halt' | 'queue'
  | 'halt-handoff' | 'handoff' | 'handoff-partial' | 'submit' | 'near' | 'spent' | 'imminent'
  | 'prod-forbid' | 'prod-allow' | 'idle' | 'idle-halt' | 'idle-again' | 'submit-halt' | 'submit-pre' | 'submit-idle'
  | 'driver' | 'trial-tail' | 'idle-done' | 'idle-off' | 'idle-done-off' | 'handoff-ack' | 'question' | 'auto-mode'
  | 'resumed' | 'question-timeout'

/** Runtime `@name@` values; a token with no value is left for the invariant check to catch. */
export type Runtime = Partial<Record<
  | 'nonce' | 'previous_copy' | 'measured_at' | 'measured_facts' | 'session_id' | 'saved_copy' | 'remeasure' | 'tokens' | 'queue_add'
  | 'halt_reason' | 'max_calls' | 'handoff_path' | 'draft_state' | 'handoff_finish'
  /** `storeWord()` of this plugin's launcher (PKG-RUNTIME A.2); the idle turn's minutes (IC-1 D5). */
  | 'store' | 'idle_min'
  /** Owner xxxxxxxx-37: when a background result's turn took the idle block (`[idle-again]`). */
  | 'idle_used_at'
  /**
   * Away digest phase 1 (`[idle-done]`): the work lane's state, the reason code gives for it, and the
   * digest's Basis line (lane.ts), which `[idle]`'s step-5 digest carries too (owner 2026-10-27 22:32).
   */
  | 'lane' | 'lane_why' | 'lane_basis'
  /** Question carry (`[question]`): the open question, on one line within QUESTION_MAX (question.ts). */
  | 'question'
  /** 0.1.3 resume-text A (`[resumed]`): the code-rendered first line (resume.ts `resumeLine`). */
  | 'resume_line'
  /** The shadow trial's fork prompts (TRIAL-DUAL-HANDOFF §4.2): texts read at run time from the user's local files. */
  | 'old_skill' | 'old_template' | 'trial_facts' | 'trial_tail',
  string
>>

const TAG = /^\[([a-z-]+)\] /

/**
 * Keeps a `[tag] ` line (tag removed) when its tag is active and not dropped, else drops it;
 * drops any line holding a `@name@` of a dropped block; joins by `\n`, strips, one trailing
 * `\n`; then fills `@name@` tokens. Callers pass `queue` only when `queue_cmd` is set (D-10).
 */
export function assembleText(text: string, tags: readonly Tag[], runtime: Runtime, drop: readonly string[] = []): string {
  const active = new Set<string>(tags)
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

/** The asset is in this build (one added after the mod, such as `handoff-turn`, may not be yet). */
export function hasAsset(name: string): name is AssetName {
  return (ASSET_NAMES as readonly string[]).includes(name)
}

/** The asset is in this build and has at least one line with this tag (a text not landed yet has none). */
export function hasTag(asset: string, tag: Tag): boolean {
  if (!hasAsset(asset)) return false
  return splitLines(assetText(asset, '')).some(l => l.startsWith(`[${tag}] `))
}

/** `assemble` for an asset this build may lack: undefined when it is missing or renders empty. */
export function assembleIf(plugin: string, asset: string, tags: readonly Tag[], runtime: Runtime, drop: readonly string[] = []): string | undefined {
  if (!hasAsset(asset)) return undefined
  const s = assemble(plugin, asset, tags, runtime, drop)
  return s.trim() === '' ? undefined : s
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
