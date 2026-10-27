// Wrapper strip, normalized body and sha256 (MOD-SPEC §5.1). Shared reading with the helper's
// detector: the PostCompact text (`<summary>…`) and the mod's installed message
// (`This session is being continued…`) of one summary give the same normalized body.

export type Stripped = {
  /** Body lines after the stripped header parts, up to (excluding) `</summary>`. */
  lines: string[]
  /** The normalized body: those lines joined by `\n` plus one final `\n`; empty for no body. */
  body: string
  /** Index in `lines` of a sentinel line moved in from after `</summary>`, or null (P5-FOLD A1). */
  movedSentinel: number | null
}

const CONTINUED = 'This session is being continued'
const TOOLS_OPEN = '<tools-used-before-summary>'
const TOOLS_CLOSE = '</tools-used-before-summary>'
const SUMMARY_OPEN = '<summary>'
const SUMMARY_CLOSE = '</summary>'
const ANALYSIS_OPEN = '<analysis>'
const ANALYSIS_CLOSE = '</analysis>'
const REMINDER_OPEN = '<system-reminder>'
const REMINDER_CLOSE = '</system-reminder>'

/**
 * Strips the header parts MOD-SPEC §5.1 names, repeated at the top until none applies (blank
 * lines between them dropped): a line starting `This session is being continued`, a
 * `<tools-used-before-summary>` block through its closing tag, an `<analysis>` block through its
 * closing tag (the summarizer's scratch text, which a PostCompact `compact_summary` of Claude Code
 * 2.1.309 keeps before `<summary>`; an unclosed one is body, not header), a `<system-reminder>`
 * block through its closing tag (the installed message of Claude Code 2.1.311 wraps the tools-used
 * block in it; an unclosed one is body, not header), a `Summary:` line, and the
 * `<summary>` tag (text after the tag on its line is body). The body ends before the first line
 * holding `</summary>` (text before the tag on that line is body); one listed installed-message
 * trailer (`copy_trailers`, line patterns) is cut when no close tag ended the body; trailing blank lines are trimmed. The normalized body is the
 * lines joined by `\n` plus one final `\n`, or empty for an empty body (the same reading as the
 * fixture tool's reference detector and the helper, so the sha256 values agree).
 *
 * Sentinel after the close tag (MOD-SPEC §5.1, P5-FOLD A1): when `sentinel` is given and the
 * first non-blank line after the `</summary>` line (or the text after `</summary>` on that same
 * line) matches it, that line is appended to the body, and the rest after it goes on as
 * installed-message text (a listed trailer is cut, as above). Only that one line moves: text
 * after `</summary>` that is not the sentinel stays outside the body.
 */
export function strip(raw: string, trailers: readonly string[] = [], sentinel?: RegExp): Stripped {
  const all = raw.replace(/\r\n/g, '\n').replace(/\r/g, '\n').split('\n')
  let i = 0
  while (i < all.length) {
    const line = all[i] ?? ''
    const t = line.trim()
    if (t === '') i++
    else if (line.startsWith(CONTINUED)) i++
    else if (t.startsWith(TOOLS_OPEN)) {
      while (i < all.length && !(all[i] ?? '').includes(TOOLS_CLOSE)) i++
      i++
    } else if (t.startsWith(ANALYSIS_OPEN)) {
      let j = i
      while (j < all.length && !(all[j] ?? '').includes(ANALYSIS_CLOSE)) j++
      if (j >= all.length) break
      i = j + 1
    } else if (t.startsWith(REMINDER_OPEN)) {
      let j = i
      while (j < all.length && !(all[j] ?? '').includes(REMINDER_CLOSE)) j++
      if (j >= all.length) break
      i = j + 1
    } else if (t === 'Summary:') i++
    else if (line.startsWith(SUMMARY_OPEN)) {
      const rest = line.slice(SUMMARY_OPEN.length)
      if (rest.trim() !== '') {
        all[i] = rest
        break
      }
      i++
    } else break
  }
  let lines: string[] = []
  let after: string[] | undefined
  for (let j = i; j < all.length; j++) {
    const line = all[j] ?? ''
    const at = line.indexOf(SUMMARY_CLOSE)
    if (at >= 0) {
      const head = line.slice(0, at)
      if (head.trim() !== '') lines.push(head)
      after = [line.slice(at + SUMMARY_CLOSE.length), ...all.slice(j + 1)]
      break
    }
    lines.push(line)
  }
  lines = trimTrailingBlank(lines)
  let movedSentinel: number | null = null
  if (sentinel && after) {
    const k = after.findIndex(l => l.trim() !== '')
    const first = k >= 0 ? (after[k] ?? '') : undefined
    // Matched with trailing whitespace trimmed, as the helper's scan reads lines; kept as is.
    if (first !== undefined && sentinel.test(first.replace(/\s+$/, ''))) {
      movedSentinel = lines.length
      lines = trimTrailingBlank([...lines, first, ...after.slice(k + 1)])
    }
  }
  // Listed installed-message trailers (`copy_trailers`: line patterns, as the helper reads them)
  // are cut from the end: when no `</summary>` closed the body, or after a moved sentinel (never
  // the sentinel or the body before it).
  const res = trailers.map(safeRe).filter((r): r is RegExp => r !== undefined)
  if (res.length > 0) {
    if (after === undefined) lines = cutTrailers(lines, res, 0)
    else if (movedSentinel !== null) lines = cutTrailers(lines, res, movedSentinel + 1)
  }
  if (movedSentinel !== null && movedSentinel >= lines.length) movedSentinel = null
  return { lines, body: lines.length === 0 ? '' : lines.join('\n') + '\n', movedSentinel }
}

function safeRe(t: string): RegExp | undefined {
  if (t === '') return undefined
  try {
    return new RegExp(t)
  } catch {
    return undefined
  }
}

/** Drops trailing lines (blank ones skipped) while each matches a trailer pattern, down to `floor`. */
function cutTrailers(lines: string[], res: readonly RegExp[], floor: number): string[] {
  let out = [...lines]
  let j = out.length - 1
  while (j >= floor) {
    const l = out[j] ?? ''
    if (l.trim() === '') {
      j--
      continue
    }
    if (!res.some(r => r.test(l))) break
    out = out.slice(0, j)
    j--
  }
  return trimTrailingBlank(out)
}

function trimTrailingBlank(lines: string[]): string[] {
  const out = [...lines]
  while (out.length > 0 && (out[out.length - 1] ?? '').trim() === '') out.pop()
  return out
}

/** UTF-8 bytes of a string (no TextEncoder in the hooks environment's typings). */
export function utf8(s: string): number[] {
  const out: number[] = []
  for (let i = 0; i < s.length; i++) {
    let c = s.charCodeAt(i)
    if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length) {
      const d = s.charCodeAt(i + 1)
      if (d >= 0xdc00 && d <= 0xdfff) {
        c = 0x10000 + ((c - 0xd800) << 10) + (d - 0xdc00)
        i++
      }
    }
    if (c < 0x80) out.push(c)
    else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 63))
    else if (c < 0x10000) out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63))
    else out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63))
  }
  return out
}

/** Byte length of a string in UTF-8. */
export function byteLength(s: string): number {
  return utf8(s).length
}

const K = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
]

/** sha256 of the string's UTF-8 bytes, lowercase hex. */
export function sha256(s: string): string {
  const bytes = utf8(s)
  const bitLen = bytes.length * 8
  bytes.push(0x80)
  while (bytes.length % 64 !== 56) bytes.push(0)
  const hi = Math.floor(bitLen / 0x100000000)
  const lo = bitLen >>> 0
  bytes.push((hi >>> 24) & 255, (hi >>> 16) & 255, (hi >>> 8) & 255, hi & 255)
  bytes.push((lo >>> 24) & 255, (lo >>> 16) & 255, (lo >>> 8) & 255, lo & 255)
  const h = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
  const w = new Array<number>(64).fill(0)
  for (let off = 0; off < bytes.length; off += 64) {
    for (let t = 0; t < 16; t++) {
      const b = off + t * 4
      w[t] = (((bytes[b] ?? 0) << 24) | ((bytes[b + 1] ?? 0) << 16) | ((bytes[b + 2] ?? 0) << 8) | (bytes[b + 3] ?? 0)) >>> 0
    }
    for (let t = 16; t < 64; t++) {
      const w15 = w[t - 15] ?? 0
      const w2 = w[t - 2] ?? 0
      const s0 = rotr(w15, 7) ^ rotr(w15, 18) ^ (w15 >>> 3)
      const s1 = rotr(w2, 17) ^ rotr(w2, 19) ^ (w2 >>> 10)
      w[t] = ((w[t - 16] ?? 0) + s0 + (w[t - 7] ?? 0) + s1) >>> 0
    }
    let [a, b, c, d, e, f, g, hh] = h as [number, number, number, number, number, number, number, number]
    for (let t = 0; t < 64; t++) {
      const S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
      const ch = (e & f) ^ (~e & g)
      const t1 = (hh + S1 + ch + (K[t] ?? 0) + (w[t] ?? 0)) >>> 0
      const S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
      const maj = (a & b) ^ (a & c) ^ (b & c)
      const t2 = (S0 + maj) >>> 0
      hh = g
      g = f
      f = e
      e = (d + t1) >>> 0
      d = c
      c = b
      b = a
      a = (t1 + t2) >>> 0
    }
    h[0] = ((h[0] ?? 0) + a) >>> 0
    h[1] = ((h[1] ?? 0) + b) >>> 0
    h[2] = ((h[2] ?? 0) + c) >>> 0
    h[3] = ((h[3] ?? 0) + d) >>> 0
    h[4] = ((h[4] ?? 0) + e) >>> 0
    h[5] = ((h[5] ?? 0) + f) >>> 0
    h[6] = ((h[6] ?? 0) + g) >>> 0
    h[7] = ((h[7] ?? 0) + hh) >>> 0
  }
  return h.map(x => (x >>> 0).toString(16).padStart(8, '0')).join('')
}

function rotr(x: number, n: number): number {
  return ((x >>> n) | (x << (32 - n))) >>> 0
}

/** First 8 hex characters of the sha256. */
export function sha8(s: string): string {
  return sha256(s).slice(0, 8)
}
