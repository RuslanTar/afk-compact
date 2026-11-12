// U tests through the kit: the job recorder in the main `tool.call` handler
// (AT-J-01, AT-J-02; both output-path candidates go to the helper).
import { expect, test } from 'claude-code/testing'
import { AGENT, SID_A, World } from './harness.test'

const TEXT = 'Command running in background with ID: b7e1c2a9. Output is being written to: /private/tmp/claude-501/-w-repo/' + SID_A + '/tasks/b7e1c2a9.output'

test('AT-J-01: a Bash result with backgroundTaskId gives one job line with every raw field; isReadOnly copied', async ($, on) => {
  const w = new World().install(on)
  w.toolAnswer = () => ({ result: { stdout: '', stderr: '', interrupted: false, backgroundTaskId: 'b7e1c2a9' }, text: TEXT, isReadOnly: true })
  await w.start($)
  await w.turnStart($)
  await $.tool.call({ tool: 'Bash', command: 'rg -n TODO src; echo "__exit $?"', run_in_background: true } as never)
  const calls = w.callsOf('log').filter(c => w.flag(c, '--stream') === 'jobs')
  expect(calls.length).toBe(1)
  expect(calls[0]?.args).toEqual(['--sid', SID_A, '--stream', 'jobs', '--stdin'])
  expect(w.jobLines.length).toBe(1)
  const j = w.jobLines[0] ?? {}
  expect(j).toMatchObject({
    kind: 'job', task_id: 'b7e1c2a9', command: 'rg -n TODO src; echo "__exit $?"', cwd: '/w/repo', is_read_only: true,
    sandbox_disabled: false, backgrounded: 'flag', result_text: TEXT,
  })
  expect(typeof j.launched_at).toBe('string')
  expect(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}$/.test(String(j.launched_at))).toBe(true)
  expect('background_output_path' in j).toBe(false)
})

test('AT-J-01: no isReadOnly from core: is_read_only false; backgroundOutputPath passed through when core gives it', async ($, on) => {
  const w = new World().install(on)
  w.toolAnswer = () => ({ result: { stdout: '', stderr: '', interrupted: false, backgroundTaskId: 'b1', backgroundOutputPath: '/r/tasks/b1.output', dangerouslyDisableSandbox: true }, text: 'x' })
  await w.start($)
  await w.turnStart($)
  await $.tool.call({ tool: 'Bash', command: 'touch /tmp/x', run_in_background: true } as never)
  expect(w.jobLines[0]).toMatchObject({ is_read_only: false, sandbox_disabled: true, background_output_path: '/r/tasks/b1.output' })
})

test('AT-J-02: Ctrl+B and timeout-backgrounded results (input flag false) are recorded user / timeout; another move is other', async ($, on) => {
  const w = new World().install(on)
  let res: Record<string, unknown> = {}
  w.toolAnswer = () => ({ result: { stdout: '', stderr: '', interrupted: false, ...res }, text: '' })
  await w.start($)
  await w.turnStart($)
  res = { backgroundTaskId: 'b2', backgroundedByUser: true }
  await $.tool.call({ tool: 'Bash', command: 'npm test' } as never)
  res = { backgroundTaskId: 'b3', timedOutAfterMs: 120000 }
  await $.tool.call({ tool: 'Bash', command: 'npm run build', run_in_background: false } as never)
  res = { backgroundTaskId: 'b4', backgroundedToDeliverMessage: true }
  await $.tool.call({ tool: 'Bash', command: 'make' } as never)
  expect(w.jobLines.map(j => [j.task_id, j.backgrounded])).toEqual([['b2', 'user'], ['b3', 'timeout'], ['b4', 'other']])
})

test('AT-J-01: subagent, denied, foreground and errored calls record nothing; a TaskStop appends a stop line', async ($, on) => {
  const w = new World().install(on)
  let answer: unknown = { result: { stdout: 'ok', stderr: '', interrupted: false } }
  w.toolAnswer = () => answer
  await w.start($)
  await w.turnStart($)
  await $.tool.call({ tool: 'Bash', command: 'ls' } as never)
  answer = { result: { stdout: '', stderr: '', interrupted: false, backgroundTaskId: 'b5' }, text: '' }
  await $.tool.call({ tool: 'Bash', command: 'sleep 100', run_in_background: true, agentId: AGENT } as never)
  answer = { deny: 'blocked by policy' }
  await $.tool.call({ tool: 'Bash', command: 'make', run_in_background: true } as never)
  answer = { isError: true, result: 'boom', text: 'boom' }
  await $.tool.call({ tool: 'Bash', command: 'make', run_in_background: true } as never)
  expect(w.jobLines.length).toBe(0)
  answer = { result: { message: 'stopped', task_id: 'b6', task_type: 'local_bash' }, text: 'stopped' }
  await $.tool.call({ tool: 'TaskStop', task_id: 'b6' } as never)
  expect(w.jobLines).toEqual([{ kind: 'stop', task_id: 'b6' }])
})

test('TaskStop error: a TaskStop with an error result still records the stop line, so the job is never relaunched', async ($, on) => {
  const w = new World().install(on)
  w.toolAnswer = () => ({ isError: true, result: 'No task found with ID: b8', text: 'No task found with ID: b8' })
  await w.start($)
  await w.turnStart($)
  await $.tool.call({ tool: 'TaskStop', task_id: 'b8' } as never)
  expect(w.jobLines).toEqual([{ kind: 'stop', task_id: 'b8' }])
})

test('Dev-1: REFUSED jobs-caller (exit 3) is the helper\'s answer, logged there; the call result is untouched', async ($, on) => {
  const w = new World().install(on)
  w.jobsReply = { exitCode: 3, stdout: 'REFUSED: jobs-caller\n' }
  w.toolAnswer = () => ({ result: { stdout: '', stderr: '', interrupted: false, backgroundTaskId: 'b7' }, text: 'started' })
  await w.start($)
  await w.turnStart($)
  const r = (await $.tool.call({ tool: 'Bash', command: 'rg x', run_in_background: true } as never)) as { text?: string; deny?: string }
  expect([r.deny, r.text]).toEqual([undefined, 'started'])
  expect(w.rowsOf('helper_missing').length).toBe(0)
})
