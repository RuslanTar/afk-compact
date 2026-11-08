<!-- Source of plugin/assets/queue-contract.md (tools/build: comments stripped, {{plugin}} filled). The caller is plugin/helper/lib/queue.pm (list, add) with plugin/helper/cmd/queue-add.pl (the draft and its caps) and plugin/helper/lib/skills/session_cmds.pm (adopt); `queue check` is plugin/helper/cmd/queue.pl. tools/fixtures-gen --check holds the two schema files to those caps and to its strict list contract. -->
# The queue_cmd contract (version 1)

`queue_cmd` names a program of your own that keeps the questions an unattended {{plugin}} session needs to ask you. This file is the whole contract between the plugin and that program. Two JSON Schema files beside it describe the two JSON documents: `queue-stub.v1.schema.json` (the `list` reply) and `queue-add.v1.schema.json` (the `add` draft). `examples/queue-folder.sh` is a minimal program that keeps it. `<store>` below is `"<plugin folder>/scripts/{{plugin}}-store"`, the plugin's helper.

## How the plugin runs the program

- It runs the program file directly, with the subcommand and flags below as separate arguments; it never passes a root folder, a project, a repository or a working folder. The program finds its own store (a fixed folder, an environment variable of its own) and, if it needs one, the project from its current folder.
- The current folder is the one the helper runs in, usually the session's folder. The environment is the session's (the plugin restores your own `PERL5LIB` and `PERLLIB`).
- stdin is empty, except for `add`, which gets the draft. Only stdout is read; stderr is discarded, so a `REFUSED:` line must go to stdout.
- Each call runs in its own process group. When the wait below runs out, the plugin stops the group with TERM and reads the call as a timeout.
- Text is UTF-8. Every size below is in bytes.

| Subcommand | Arguments | When the plugin calls it | Wait |
|---|---|---|---|
| `list` | `--json --session <sid>` | at a checkpoint, at `begin` of a handoff, after a compaction, when `measure --compact` runs, and in the local comparison trial | 5 s at a checkpoint and at `begin` (less when the checkpoint's own budget is short), 3 s after a compaction and in `measure`, 1.5 s in the trial |
| `add` | `--json --session <sid> --client-id ck-<12 hex> [--lane-name <slug>]`, the draft on stdin | at a checkpoint, once per question that waits on you; not while the last `list` reply had no `commands` or left `add` out | 5 s |
| `adopt` | `--lane <id> [--if-free] [--must-exist]` | only from `/{{plugin}}:resume`, when a new session resumes a handoff that records a `lane:` id | 5 s |

`<sid>` is the Claude Code session id. `--lane-name` is the kebab-case slug of the session's handoff topic, when it has one: a name for the lane if the program makes one. `adopt` gets no session flag; `--must-exist` is passed only while the last `list` reply named `adopt:must-exist` in `commands`. Any other subcommand or flag is a usage error (exit 2).

## list

`list` only reads: it must not create a lane, a folder or a record, also for a session it has never seen. It exits 0 and prints one JSON object on stdout and nothing else (at most 256 KiB), tagged `"schema": "queue-stub/v1"` (`queue-stub.v1.schema.json`):

| Key | Required | Value |
|---|---|---|
| `schema` | yes | `"queue-stub/v1"`. Without it the reply is not read (`queue: degraded (untagged)`); another value: `degraded (schema)` |
| `session` | yes | the `--session` value |
| `lane` | yes | this session's lane, `lane:<name>` (named; may be adopted) or `auto:<name>` (unnamed), `<name>` from `A-Z a-z 0-9 . _ / -`; or `null` when the session has none |
| `open` | yes | the open questions of the lane: a count, or a list of their ids (each at most 64 characters from `A-Z a-z 0-9 . _ : / -`) |
| `pending` | yes | how many of them wait for an answer (a count) |
| `preview` | yes | `true` when `lane` is only the name the program would give: nothing is used from the reply then |
| `held_by` | yes | the session id of another live session that holds the lane, or `null` |
| `label` | no | a short name of the lane for the handoff (one line, at most 80 characters; default: the lane id) |
| `commands` | no | the subcommands it supports, from `list`, `adopt`, `adopt:must-exist` and `add`; without it the plugin takes `list` and `adopt` only and never calls `add` |
| `lanes` | no | other lanes, as ids or `{id, holder, open, preview}` objects; shown to no one, ignored |

Unknown keys are ignored. With a usable lane and open questions, the handoff gets one line `Queued: <n> open in <label> (<ids>); answered only via the queue; never re-ask.` A reply that is not one JSON object, a non-zero exit or no answer in time puts the queue in `degraded (not-json|exit|timeout)` for the session, and the handoff gets no `Queued:` line.

## add

The draft on stdin is one JSON object, `"schema": "queue-add/v1"` (`queue-add.v1.schema.json`), at most 4,096 bytes, its keys in this order:

| Key | Value |
|---|---|
| `schema` | `"queue-add/v1"` |
| `client_id` | the same value as `--client-id`: `ck-` and 12 lowercase hex, made from the session id, the question and the option labels, so the same question gets the same id |
| `session` | the same value as `--session` |
| `asked_at` | when the plugin built the draft, local time with offset: `2026-11-08T12:00:00+01:00` |
| `source` | `{"plugin": "{{plugin}}", "kind": "checkpoint", "nonce": "<8 lowercase hex>"}` |
| `question` | the question, ending with `?`; at most 600 bytes |
| `kind` | `choice`, `approval` or `open` |
| `options` | for `choice` and `approval` only: 2 to 4 objects `{label, description, recommended, long_term}`: `label` at most 40 bytes, `description` at most 300 bytes, the two flags `true` or `false`; at most one option is recommended |
| `recommendation_none_reason` | why no option is recommended: required when none is, at most 200 bytes |
| `blocks` | what waits on the answer; at most 200 bytes |
| `context` | optional: what the person needs to know to answer; at most 400 bytes |

The helper refuses a draft over these caps itself and sends nothing. It scans every text for secrets first: a hard hit sends nothing, a soft hit arrives redacted. Unknown keys may be added in a later version of the same schema; ignore them.

The answer is the exit code, and on exit 0 one JSON line on stdout (at most 64 KiB in all): `{"status": "queued" | "exists", "id": "<queue id>"}`, the id at most 128 characters from `A-Z a-z 0-9 . _ : / -`. You may add `"schema": "queue-add/v1"`, `"lane"` and `"client_id"`; the plugin reads `status` and `id`. A refusal prints one line `REFUSED: <kind>: <reason>` on stdout (exit 2 prints none).

| Exit | Meaning | The helper prints |
|---|---|---|
| 0 | queued, or already present for this client id (`exists`: write nothing new) | `QUEUED <id>` / `EXISTS <id>` |
| 2 | usage error or unknown subcommand, no `REFUSED:` line (an older program without `add`) | `NOT QUEUED (unsupported)`; no `add` for a day |
| 3 | the session's lane is held by another live session; nothing written | `NOT QUEUED (held)` |
| 4 | no lane could be named | `NOT QUEUED (no-lane)` |
| 5 | the draft is refused (`REFUSED: draft: <rule>`) | `NOT QUEUED (invalid)` |
| 6 | the store is damaged, locked or unreadable, or any other failure | `NOT QUEUED (error)` |

Any other exit, a malformed exit-0 line and no answer within 5 s (`NOT QUEUED (timeout)`) all mean "not queued", and the question stays in the handoff. The helper also keeps the client ids it queued, so it sends a question once per session.

## adopt

`adopt --lane <id>` binds the calling session to the lane `<id>` (always a `lane:` id). It exits 0 with the bound lane id in its first stdout line (or a JSON object with `lane`). With `--if-free` it refuses a lane another live session holds; without it, it takes the lane over (the person said yes). With `--must-exist` it refuses an id that names no lane. A refusal prints one line, at most 200 bytes, without command text:

| Exit | First line |
|---|---|
| 3 | `REFUSED: held: holder=<sid> kind=<process\|heartbeat> lane=<id>` |
| 4 | `REFUSED: no-lane: <reason>` (only with `--must-exist`) |
| 6 | `REFUSED: damaged: <reason>`, `REFUSED: untrusted: <reason>` or `REFUSED: no-process: <reason>`; nothing written |
| 2 | a usage error, or no `adopt` |

## Testing

`! <store> queue check [<program>]` runs only what reads: `list --json --session 00000000-0000-4000-8000-00000000c0de` once (a made-up session id), and checks that the file is executable, the exit code, the time (1.5 s, the plugin's shortest wait), the JSON, the schema tag, every key of the table above and the `commands` list. It prints `ok` or `FAIL` with the fix per check, then `QUEUE CHECK PASS` (exit 0) or `QUEUE CHECK FAIL <check>` (exit 1). Without `<program>` it checks `queue_cmd`. It never calls `add` or `adopt`: they write, and the contract has no dry run. Test those against a scratch store of your own, for example:

```sh
printf '%s' '{"schema":"queue-add/v1","client_id":"ck-0123456789ab","session":"test-1","asked_at":"2026-11-08T12:00:00+01:00","source":{"plugin":"{{plugin}}","kind":"checkpoint","nonce":"0123abcd"},"question":"Ship on Friday?","kind":"approval","options":[{"label":"Yes","description":"Ship it","recommended":true,"long_term":true},{"label":"No","description":"Wait a week","recommended":false,"long_term":false}],"blocks":"the release"}' \
  | <program> add --json --session test-1 --client-id ck-0123456789ab; echo "exit $?"
```

The first run answers `queued` (exit 0), the same line again `exists` with the same id, and `list --json --session test-1` then counts one open question.
