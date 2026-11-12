# Background jobs

## Waiting for background work

Claude Code refuses a foreground command that starts with a long sleep (25 seconds or more), in the main session and in subagents. The plugin adds no such block and does not remove it. Its rules avoid the need for it.

- **Main session.** Start long work with `run_in_background`. Its notification wakes the session, so the model can keep working or end the turn. To watch something the session did not start, run `"<plugin folder>/scripts/afk-compact-store" wait` with `run_in_background` (see below; `<store>` below stands for `"<plugin folder>/scripts/afk-compact-store"`, the full path, since the helper is not on your `PATH`). No foreground sleeps, no polling loops.
- **Subagents, workflow agents, teammates, and a main session with background tasks turned off.** Ending a turn is not a wait: a subagent that ended its turn while its own job ran was not woken by the job's notification on the version this was checked on. The model waits in the foreground with `<store> wait --for <spec> --max 270` (Bash timeout 300000), runs it again on exit code 10, then reads the output itself. The 270-second step keeps the five-minute cache of subagents warm.
- **Monitor** is for a stream of events, not for one completion.

A job that the model will wait on is started with `; echo "__exit $?"` at the end, so the wait has an end marker to look for.

`<store> wait` is a bounded check that polls inside the helper. It is met when any `--for` condition holds:

| Condition | Met when |
|---|---|
| `pid-exit:<pid>[@<start-epoch>]` | the process is gone, or its start time changed |
| `file:<path>` | the path exists as a regular file |
| `marker:<path>:<regex>` | a line of the file matches the regex |
| `exit:<path>` | the file holds an `__exit <n>` line or ends with Claude Code's `[exited with code <n>]`; the code is printed. `[killed]` (stopped with TaskStop or at exit) prints `killed` |

`--while <guard>` ends the wait early when a pid or file stops holding. `--stall <s>` ends it when the marker or exit file does not grow (or does not appear) for that long. `--deadline <epoch>` ends it when a time has passed. `--max <s>` takes 0 to 7200 and defaults to 270; `--max 0` checks once and returns at once.

It prints one line and exits with 0 (done), 10 (still pending, run it again), 11 (stalled), 12 (a guard ended), 13 (deadline passed), 3 (refused, for example a path that is not a regular file) or 64 (bad arguments). It only reads: it writes no file, row or lock, and it exits by itself at `--max`.

Limits and tips:

- The command only reads. Auto mode: nothing to add; `wait` ran without a prompt (Claude Code 2.1.306).
- Default mode: each helper call prompts until you add the rule below. The plugin's own notes outside a skill call the helper by its full path, for example a subagent's wait after a compaction. To stop the prompt for that read-only wait, add the rule that `/afk-compact:status` prints, with the real folder, as `allow rule (default mode): Bash("<plugin folder>/scripts/afk-compact-store" wait *)`. The plugin folder name contains the version, so after an update the old rule stops matching. When your user or project settings still name an older folder, `/afk-compact:status` says so in a line `allow rule for an older plugin folder: <old folder>; current: <plugin folder>` and prints the new rule. It only reads your settings files; it never edits them.
- Commands you type yourself are listed in `/afk-compact:status` under `user-run commands (type them yourself, with the leading !):`, one `! "<plugin folder>/scripts/afk-compact-store" <command>` line each, with the real folder: `smoke`, `project init`, `project copy`, `watch prune`, `reconcile --sid <session> --orphans --full` (only with a session id), `report`, `settings reset <key> --apply` (the model may also run that one for you after your yes, but never for a consent key), while an old default folder from before 0.1.2 is read, `migrate`, and while `queue_cmd` is set, `queue check`.
- Monitor is not available on Amazon Bedrock, Google Cloud Agent Platform or Microsoft Foundry, nor when `DISABLE_TELEMETRY` or `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` is set. Each Monitor watch ends after 5 minutes by default and 30 at most.
- With `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1` there is no `run_in_background` and no notification. Every wait then follows the subagent rule above.
- In sessions run without a person (`-p`, the SDK, the cloud), background commands get 30 minutes by default and 2 hours at most. `wait` prints its pending line only after `--max` has passed, so keep `--max` a little under the limit, for example `--max 1740`. With exactly 1800 the limit can end the wait before it prints exit code 10.
- Cache: on a subscription within plan usage, the main conversation's prompt cache lives one hour. With an API key or a cloud provider it lives five minutes, so a long wait costs one cache rewrite when the session wakes. Set `promptCacheTtl` to `1h` in your Claude Code settings to avoid that (Claude Code 2.1.242 or newer). Polling to keep the cache warm costs more than it saves for most waits.

## Lost background jobs

Background work survives a compaction and `/clear`: shells (Claude Code 2.1.306) and, checked on 2.1.319, background agents, workflows, in-process teammates and scheduled tasks; their results arrive in the new conversation. Monitors should survive too (Claude Code's code keeps them; not checked live). A workflow that stopped after `/clear` resumes only from the original conversation, so `/resume` that conversation first. At exit all of it stops, except durable scheduled tasks (`durable: true`), which Claude Code keeps in `.claude/scheduled_tasks.json`. With work running, Claude Code asks first: "Exit and stop tasks" (checked on 2.1.319: it kills a running shell), "Move to background and exit" when it is offered, or "Stay". Moving to background hands background shells, agents and workflows to the session's next wake (read in Claude Code 2.1.319's code, not checked live); teammates and session-only scheduled tasks stop either way. A handoff therefore lists running work as stopping when Claude Code exits, not on `/clear`, and after `/clear` resume first checks a listed job with `<store> wait` and treats it as possibly still running; after an exit or a restart the job may be gone. `/afk-compact:resume` does not trust the handoff's text for this. It uses a record the plugin wrote when the job started: the exact command, the folder, the time and the output file. The mod writes it from the tool call itself, so the model cannot edit it. A command with a hard secret hit (a provider key, a token in an auth header, a password in a URL and similar) is stored as a hash and rule ids only, and such a job is never started again by itself. A weaker hit (a `password=` or `token=` pair, a cookie, a long random-looking string) does not withhold the command: it is stored as typed, and a published handoff's restart recipe can carry it. Keep credentials out of background commands; read them from a file or the environment instead.

Resume re-checks seven facts:

1. the record exists and matches the original transcript;
2. the process that owned the job has ended (a `/clear` does not count: the shell survives it);
3. the job was still running at the end;
4. the output holds no exit marker;
5. the output has been quiet since the end;
6. nothing the job was expected to write is newer than its start;
7. the folder exists and the command can be found.

Resume starts the job again by itself only when the relation is the same session or a successor (`/clear` or a proven lineage), and then in two cases: all seven hold, or the job failed (its output ends with a non-zero exit code, so check 4 fails) while checks 1 and 7 hold. Either way it starts a job at most once per resume and twice per chain. It runs the recorded command byte for byte, through the Bash tool, so your permission mode judges it as usual. Otherwise it asks, with the exact command and its source ("recorded by the plugin" or "written in the handoff, not recorded"). A command written in your own handoff's restart recipe, with no record of the job, may start again by itself under the same checks; a teammate's or another session's never does. The command is never run by the helper itself.

What may start again by itself:

- **read-only jobs**, as Claude Code's own read-only check decides;
- **jobs you allowlisted**: the recorded command matches a `relaunch_allow` pattern, is a single command (no `;`, `&&`, `||`, `|`, `&`, newline, `$(` or backtick outside quotes), its restart recipe lists the files it is expected to write, and nothing in it reaches outside your machine.

**Status.** The plugin takes each job's output file from the Bash tool's result text and uses it only when it matches Claude Code's task-file layout; a job without a confirmed output file asks. `/afk-compact:status` prints, with the defaults and two allowlist patterns:

```
automatic relaunch: active (read-only jobs and allowlisted jobs) · relaunch_auto on
  relaunch_allow: 2 patterns, active
unattended_prod_reads: false (default) · production patterns: prod-token + 0 yours
protected branches: the shipped list + 0 yours (default)
```

With `relaunch_auto` set to `shadow` the first line says `shadow (reports would-relaunch, runs nothing)`, with `off` it says `off`, and the allowlist line says `not used while relaunch_auto is shadow` (or `off`). The `unattended_prod_reads` line names where the value came from (`settings file`, `default` or `safe value`) and how many `prod_patterns` of yours are in use. The `protected branches` line says how many `protected_branches` entries of yours are in use and where they came from (`settings file` or `default`); each ignored entry gets an indented `warning: protected_branches #<n> invalid, ignored (the shipped list still applies)` line, by its position in the list (the entry itself is never printed). An indented `output path:` line says how many of this session's jobs have a confirmed output file. Set `relaunch_auto` to `shadow` to log the verdict and always ask, or to `off`. These keys are read from your settings file only (see [Settings](configuration.md#settings)).
