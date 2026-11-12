// PROBE-4: what the offline kit can do for the mod's U tests.
// Kept as a regression test: if a kit release changes one of these answers, the U-test
// style that depends on it has to change too. Uses inline plugins only, so it does not
// depend on what register.ts wires.
import type { On, Register, SessionCompactInput } from 'claude-code'
import { expect, test } from 'claude-code/testing'

const MSG = { role: 'user' as const, text: 'This session is being continued from a previous conversation.', toolUses: [] }

// Q1: can a test raise `session.compact` (any trigger, agentId) through the plugins?
test('probe4: the kit raises session.compact through an inline plugin', async ($, on) => {
  let bottom: SessionCompactInput | undefined
  on('session.compact', (_$, e) => {
    bottom = e
    return { messages: [MSG], tokensBefore: 500000, tokensAfter: 40000 }
  })
  const r = await $.session.compact({ trigger: 'auto', agentId: 'a1', instructions: 'note', messages: [MSG] })
  expect(r.skip).toBeUndefined()
  expect(bottom?.trigger).toBe('auto')
  expect(bottom?.agentId).toBe('a1')
  expect(bottom?.instructions).toBe('note')
})

const appender: Register = (on: On) => {
  on('session.compact', ($, e, next) => next({ ...e, instructions: [e.instructions, 'ours'].filter(Boolean).join('\n\n') }))
}

test('probe4: an inline plugin rewrites instructions on the way down', { plugins: [{ name: 'p-append', register: appender }] }, async ($, on) => {
  let seen: string | undefined
  on('session.compact', (_$, e) => {
    seen = e.instructions
    return { messages: [MSG] }
  })
  await $.session.compact({ trigger: 'manual', instructions: 'keep the SQL', messages: [MSG] })
  expect(seen).toBe('keep the SQL\n\nours')
})

// Q2: can a test hook beneath the plugin answer the plugin's own `$.session.compact`
// and `$.session.usage`?
const selfCaller: Register = (on: On) => {
  on('turn.complete', async ($, e, next) => {
    const u = await $.session.usage()
    const r = await $.session.compact({ instructions: `tokens=${u.context.tokens ?? 'unknown'}` })
    await $.store.set('probe', r.skip ?? 'compacted')
    return next(e)
  })
}

test('probe4: test hooks answer $.session.compact and $.session.usage', { plugins: [{ name: 'p-self', register: selfCaller }] }, async ($, on) => {
  let instr: string | undefined
  let trig: string | undefined
  const store = new Map<string, unknown>()
  on('session.usage', () => ({ value: { context: { tokens: 410000, window: 1000000 } } as never }))
  on('session.compact', (_$, e) => {
    instr = e.instructions
    trig = e.trigger
    return { skip: 'vetoed' }
  })
  on('store.set', (_$, e) => {
    store.set(e.key, e.value)
    return { value: undefined }
  })
  on('turn.complete', () => ({ text: '' }))
  await $.turn.complete({ answer: 'done', durationMs: 1, isAborted: false, turnId: 't1', reason: 'answer' })
  expect(instr).toBe('tokens=410000')
  // Finding: the bottom hook sees no `trigger` on a plugin's own $.session.compact
  // (the d.ts says the engine raises it with trigger `plugin`; the kit passes the args only).
  expect(trig === undefined || trig === 'plugin').toBe(true)
  expect(store.get('probe')).toBe('vetoed')
})

// Q3: can a prepend-tier inline plugin sit above another plugin and skip it with next.to?
const prependSkipper: Register = (on: On) => {
  on('session.compact', ($, e, next) => next.to(e, 'append'))
}
const userAppender: Register = (on: On) => {
  on('session.compact', ($, e, next) => next({ ...e, instructions: 'user-tier-ran' }))
}

test('probe4: a prepend-tier inline plugin skips a user-tier plugin', {
  plugins: [
    { name: 'p-seat', tier: 'prepend', register: prependSkipper },
    { name: 'p-user', tier: 'user', register: userAppender },
  ],
}, async ($, on) => {
  let seen: string | undefined
  on('session.compact', (_$, e) => {
    seen = e.instructions
    return { messages: [MSG] }
  })
  await $.session.compact({ trigger: 'auto', instructions: 'orig', messages: [MSG] })
  expect(seen).toBe('orig')
})

test('probe4: control: without the prepend plugin the user-tier plugin runs', {
  plugins: [{ name: 'p-user', tier: 'user', register: userAppender }],
}, async ($, on) => {
  let seen: string | undefined
  on('session.compact', (_$, e) => {
    seen = e.instructions
    return { messages: [MSG] }
  })
  await $.session.compact({ trigger: 'auto', instructions: 'orig', messages: [MSG] })
  expect(seen).toBe('user-tier-ran')
})

// Q4: a test hook answers the plugin's $.process.run and $.fs.write (the helper seam).
const runner: Register = (on: On) => {
  on('turn.start', async ($, e, next) => {
    const r = await $.process.run([$.plugin.root + '/scripts/' + $.plugin.name + '-store', 'log'], { timeoutMs: 2000 })
    await $.fs.write('/tmp/probe4-' + r.stdout.trim(), 'x')
    return next(e)
  })
}

test('probe4: test hooks answer $.process.run and $.fs.write', { plugins: [{ name: 'p-run', register: runner }] }, async ($, on) => {
  const argv: string[][] = []
  const writes: string[] = []
  on('process.run', (_$, e) => {
    argv.push([...e.argv])
    return { value: { exitCode: 0, stdout: 'ok\n', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('fs.write', (_$, e) => {
    writes.push(e.path)
    return { value: undefined }
  })
  on('turn.start', (_$, e) => ({ turnId: e.turnId }))
  await $.turn.start({ text: 'hi', turnId: 't1' })
  expect(argv.length).toBe(1)
  expect(argv[0]?.[0]?.endsWith('/scripts/p-run' + '-store')).toBe(true)
  expect(writes).toEqual(['/tmp/probe4-ok'])
})
