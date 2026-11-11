// Per-compaction nonce: 8 lowercase hex characters from crypto.getRandomValues
// when present, else Math.random; redrawn while a dispatch record with that nonce exists.

type Crypto = { getRandomValues?: (a: Uint8Array) => Uint8Array }

export function randomHex(chars: number): string {
  const bytes = new Uint8Array(Math.ceil(chars / 2))
  const c = (globalThis as { crypto?: Crypto }).crypto
  if (c && typeof c.getRandomValues === 'function') c.getRandomValues(bytes)
  else for (let i = 0; i < bytes.length; i++) bytes[i] = Math.floor(Math.random() * 256)
  let s = ''
  for (const b of bytes) s += b.toString(16).padStart(2, '0')
  return s.slice(0, chars)
}

/**
 * Draws a nonce; `exists(nonce)` says whether a dispatch record already holds it, and a
 * colliding draw is replaced (at most `tries` draws, the last one kept).
 */
export async function drawNonce(
  exists: (nonce: string) => Promise<boolean>,
  draw: () => string = () => randomHex(8),
  tries = 8,
): Promise<string> {
  let n = draw()
  for (let i = 1; i < tries && (await exists(n)); i++) n = draw()
  return n
}
