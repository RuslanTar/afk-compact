// Dev-1 job records (MOD-SPEC §7 "Job records"): the main `tool.call` handler records each
// background shell after `next(e)` resolves, and each TaskStop. The mod sends the raw fields
// from the runtime envelope and result; the helper (`log --stream jobs`) adds the owner record,
// the command sha, the secret scan and both output-path candidates, and writes the row. The
// model never writes a job record: subagent calls, denied calls and mod-off sessions record none.
import type { Deps } from './deps'
import { helperMissing, isoLocal } from './log'
import { logJobs } from './helper'

/** core-to-mod: `result_text` is the result as the model read it, first 4,000 chars. */
export const RESULT_TEXT_MAX = 4000

/** What is read before `next(e)`: the session's directory and the launch time. */
export type JobStart = { cwd: string | undefined; launchedAt: string }

/** A Bash call or a TaskStop gets a start record; every other tool none. */
export async function jobStart(d: Deps, tool: string): Promise<JobStart | undefined> {
  if (tool !== 'Bash' && tool !== 'TaskStop') return undefined
  try {
    const cwd = tool === 'Bash' ? await d.cwd() : undefined
    return { cwd, launchedAt: isoLocal(await d.now(), false) }
  } catch {
    return undefined
  }
}

/** The answered call as `tool.call` resolves it (deny already ruled out). */
export type Answered = { result?: unknown; text?: string; isReadOnly?: true; isError?: true }

function obj(v: unknown): Record<string, unknown> {
  return v !== null && typeof v === 'object' ? (v as Record<string, unknown>) : {}
}

function id(v: unknown): string | undefined {
  return typeof v === 'string' && /^[A-Za-z0-9._:-]{1,128}$/.test(v) ? v : undefined
}

/**
 * The raw line for `log --stream jobs`, or undefined when the call started no background shell
 * and stopped nothing. `backgrounded`: `flag` (the input asked for it), `user` (Ctrl+B),
 * `timeout` (the command hit its timeout), `other` (any other move to the background).
 */
export function jobLine(tool: string, input: Record<string, unknown>, r: Answered, start: JobStart): string | undefined {
  const res = obj(r.result)
  if (tool === 'TaskStop') {
    // A stop that failed stopped nothing: no `{kind: stop}`, so Dev-1 never calls the job STOPPED.
    if (r.isError === true) return undefined
    const task = id(input['task_id']) ?? id(input['shell_id']) ?? id(res['task_id'])
    return task === undefined ? undefined : JSON.stringify({ kind: 'stop', task_id: task })
  }
  if (tool !== 'Bash' || r.isError === true) return undefined
  const task = id(res['backgroundTaskId'])
  const command = input['command']
  if (task === undefined || typeof command !== 'string' || command === '') return undefined
  const backgrounded = input['run_in_background'] === true ? 'flag'
    : res['backgroundedByUser'] === true ? 'user'
      : typeof res['timedOutAfterMs'] === 'number' ? 'timeout'
        : 'other'
  const row: Record<string, unknown> = {
    kind: 'job',
    task_id: task,
    command,
    cwd: start.cwd ?? null,
    launched_at: start.launchedAt,
    is_read_only: r.isReadOnly === true,
    sandbox_disabled: input['dangerouslyDisableSandbox'] === true || res['dangerouslyDisableSandbox'] === true,
    backgrounded,
    result_text: (r.text ?? '').slice(0, RESULT_TEXT_MAX),
  }
  const bop = res['backgroundOutputPath']
  if (typeof bop === 'string' && bop !== '') row['background_output_path'] = bop
  return JSON.stringify(row)
}

/** Sends one job or stop line; a helper that cannot run counts once as helper-missing. */
export async function recordJob(d: Deps, sid: string, tool: string, input: Record<string, unknown>, r: Answered, start: JobStart): Promise<void> {
  const line = jobLine(tool, input, r, start)
  if (line === undefined) return
  const res = await logJobs(d, sid, [line])
  if (res && res.exitCode === null) await helperMissing(d, sid, 'jobs')
}
