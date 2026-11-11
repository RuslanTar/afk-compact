<!-- Source of plugin/assets/cache-contract.md (tools/build: comments stripped, {{plugin}} filled). The command is plugin/helper/cmd/cache.pl, its logic and the state file plugin/helper/lib/cachestate.pm; the shim is kept by the SessionStart hook (plugin/helper/cmd/hook.pl). Facts of Claude Code 2.1.319 checked live on 2026-11-09 (v0.1.7 probes Q2, Q3). -->
# The cache command (version 1)

`<store> cache` says whether a session's prompt cache is warm, for a status line or a script of your own. This file is its whole contract. `<store>` is `${XDG_STATE_HOME:-~/.local/state}/{{plugin}}/bin/{{plugin}}-store`, a two-line `#!/bin/sh` file that runs the installed plugin's helper (below), or `"<plugin folder>/scripts/{{plugin}}-store"` itself.

```
<store> cache [--sid <session id>] [--stdin] [--json] [--note-usage]
```

- `--stdin` reads the JSON object Claude Code sends a status line command on stdin (`session_id`, `prompt_cache`, `transcript_path`; at most 1 MiB).
- `--sid` names the session; without `--stdin` the command reads only the plugin's own record of it and the transcript that record names. With both, the two ids must be the same, else the state is `unknown` (`bad-sid`).
- `--json` prints the object below; without it, one plain line.
- `--note-usage` (with `--stdin`) also records the input's `rate_limits` in the plugin's shared usage record ([below](#the-usage-record)). It changes nothing in the output.

It exits 0 whatever it reads (a usage error says so on stderr), writes nothing but the usage record when `--note-usage` asks for it, and reads at most the plugin's small state file and the last 2 MiB of the transcript. Only where the helper cannot run at all does it fail like every other command: without perl 5.28 or later it prints `REFUSED: helper-runtime` and exits 3, and a damaged plugin copy exits 70 with the reason on stderr. It loads none of the plugin's settings, so no option changes what it reads.

## The plain line

| State | Line |
|---|---|
| warm | `cache 1h warm 42m left`, then ` ↻3/7` while keep-warm runs (ping 3 of at most 7) |
| cold, expired | `cache 1h cold (expired 12m ago)` |
| cold, compacted | `cache cold (compacted)` |
| cold, a keep-warm ping that did not read the conversation | `cache cold (keep-warm ping missed)` |
| unknown | nothing at all (no line) |

The text may change between versions; read `--json` in anything that parses it.

## The JSON object

One line, `"schema": "{{plugin}}-cache/v1"`. Times are whole epoch seconds.

| Key | Value |
|---|---|
| `schema` | `"{{plugin}}-cache/v1"` |
| `sid` | the session id read, or `null` |
| `now` | the time of the reading |
| `state` | `warm`, `cold` or `unknown` |
| `why` | `null` while warm; `expired`, `compacted` or `fork-miss` when cold; `no-data`, `caching-off` or `bad-sid` when unknown |
| `ttl` | the cache tier the last request wrote, `"1h"` or `"5m"`, or `null` |
| `source` | where the reading came from: `claude-code` (`prompt_cache` on stdin), `transcript` (its last main `api-request` line), `plugin` (a keep-warm ping alone), or `null` |
| `last` | the last request that read or wrote the cache: `{"kind": "main" \| "keep_warm", "at", "source"}` (a `keep_warm` one's source is `plugin`), or `null` |
| `expires_at`, `seconds_left` | when the cache expires, and the seconds left (0 once past); `null` unless the state is warm or `expired` |
| `age_s` | seconds since `last.at`, or `null` |
| `keep_warm` | `null` when the plugin logged no keep-warm row for the session (a `keep_warm_stop` with `no-idle-path`, for an idle gap keep-warm did not start, is one); else `{"active", "n", "max", "hours", "gap_started_at", "next_due_at", "last_result", "stop"}`: `active` true while it keeps the cache warm; `n` the pings that read the cache in this idle gap; `max` the most a gap can send, `floor((keep_warm_hours × 60 − 1) / 50)` (7 at 6 hours; drift or a retry can leave it at 6); `next_due_at` the next ping while active (when keep-warm waits for a usage limit's reset, the request just after it), else `null`; `last_result` the last ping's result (`warm`, `fork-miss`, `nothing-to-fork`, `api-error`, `aborted`, `error`); `stop` the last stop, `{"why", "pings", "at"}` (`why` as the log's `keep_warm_stop` row: `turn`, `cutoff`, `no-jobs`, `no-idle-path`, …), or `null` |
| `ended_at` | when the session ended (SessionEnd), or `null`; a resume clears it |
| `plugin_version` | the plugin version that answered |

A later version may add keys to `v1`; ignore the ones you do not know. A change that removes or changes a key gets a new schema, `{{plugin}}-cache/v2`.

## How the state is read

1. **The main session's last request.** With `--stdin`, Claude Code's own `prompt_cache` (Claude Code 2.1.312 and later; absent until a session's first response, also after a resume): its `ttl` and `expires_at`. Otherwise the last main `api-request` line of the transcript (its time and the TTL of its last cache breakpoint), read from the end: 256 KiB, then 2 MiB.
2. **The plugin's keep-warm ping** counts only when it started after that request. A ping that read the cache makes `last` a `keep_warm` one and, on the one-hour tier, moves `expires_at` to its start plus one hour. Claude Code 2.1.319 already does the same in `prompt_cache` (a fork of the main conversation that reads the cache moves `expires_at` to its start plus the TTL, and is not counted as a request); the plugin takes the later of the two, so a version that does not still reads warm. On the five-minute tier it changes `last` but not `expires_at`. A later ping of the same idle gap that failed (an API error, an abort) changes neither. A ping that did not read the conversation (`fork-miss`) reads as cold: in such cases the next main request missed the cache too (17 of 17 measured).
3. **A compaction** after the last request (the plugin's `compacted` row of the main session, written once the compaction ran; a skipped one does not count, nor the `idle_compact` row written before plugin idle compaction is tried) reads as cold, `compacted`, until the next request.
4. Otherwise the cache is warm until `expires_at`, then cold, `expired`. `caching_observed: false` in `prompt_cache` reads as unknown, `caching-off`.

## The usage record

With `--note-usage`, `cache` adds the status line's usage readings (`rate_limits`: `five_hour`, `seven_day`, a gateway's `spend_limit`, each with `used_percentage` and `resets_at`) to `${XDG_STATE_HOME:-~/.local/state}/{{plugin}}/usage.v1.json` (0600), one small file for the machine. The plugin's own hooks add each session's reading there too. Each entry holds a window kind, its share, its reset time, when it was read, its source (`statusline` or `plugin`) and the first 8 characters of the session id: no account, no token, no conversation text. Claude Code sends a status line the session's reading without the time it was taken, so a `statusline` entry holds when a status line first showed that share and reset, and the plugin never counts it as newer than the same session's `plugin` entry of that kind, which holds when Claude Code took the reading; a `statusline` entry with no such entry is not counted. The status line's reading is the one the session's hooks see, so it never makes a reading fresher. Plugin idle compaction, the idle handoff turn and keep-warm read it before they skip or stop near a usage limit (README, "Near a usage limit"): an entry counts until its `resets_at`, however old, since a window's share only grows until it resets (one with a past `resets_at` counts for nothing, one with none only for 10 minutes after its `at`), and of the entries of one window (the same kind, `resets_at` within a minute) the latest `at` stands for it. A session that has no reading of its own yet (one reloaded before its first response) goes by its own entries. An entry is replaced only by a later reading of the same session, source and kind; it is dropped at the next write once its `resets_at` has passed (one with none 10 minutes after it was last read or shown), and at most 64 are kept, a session's entries together (the sessions read or shown longest ago go first, but never the latest entry of a window). Like the state files below, it is never written inside a git work tree (a dotfiles repository at the home folder): there is no record then. The plugin works the same without it: the status line's readings are one more source, never a required one. Its fields are internal and may change.

## The files

- **State:** `${XDG_STATE_HOME:-~/.local/state}/{{plugin}}/cache/<session id>.v1.json` (0600), one per session: the transcript path from SessionStart, the keep-warm gap from the log's `keep_warm_*` rows, the last compaction, and the end. The plugin's log writer updates it after each such row (a temp file renamed into place); when two Claude Code processes hold one session, the last writer wins and the next row corrects it. Its fields are internal: read them through `cache`. A row the helper could not write (one kept under the log folder's `events/`) is not in it. `prune --apply` deletes the files of sessions that ended more than 7 days ago, and those of sessions with no recorded end that were not written for 7 days (a crashed session never records one).
- **Shim:** `${XDG_STATE_HOME:-~/.local/state}/{{plugin}}/bin/{{plugin}}-store` (0755): `#!/bin/sh`, a comment, and `exec '<plugin folder>/scripts/{{plugin}}-store' "$@"`. The SessionStart hook of an installed copy (in Claude Code's plugin cache or its synced plugins folder, or read in place from a local folder marketplace) writes it (a temp file renamed into place): when it is missing, when it runs a copy that is gone, or when it runs an older version (after a downgrade it keeps running the newer copy while that folder is still there). A `--plugin-dir` load never touches it, nor a file there that is not such a shim. Uninstalling the plugin leaves it, running the old copy: a cache copy until Claude Code deletes that folder, a copy read in place from a local folder marketplace for as long as that folder exists (Claude Code never deletes it). Delete it yourself.

Both paths follow `XDG_STATE_HOME` when it is an absolute path in Claude Code's environment, as the plugin's other default folders do. Neither is written inside a git work tree or a `.planning` folder (a dotfiles repository at your home folder, for example); `cache` then reads only `prompt_cache` and the transcript, and there is no shim (a `.gitignore` line does not change this): set `XDG_STATE_HOME` to a folder outside it where Claude Code starts, or call `"<plugin folder>/scripts/{{plugin}}-store"`.

## Testing

```sh
printf '%s' '{"session_id":"test-1","prompt_cache":{"ttl":"1h","expires_at":'"$(( $(date +%s) + 1500 ))"'}}' \
  | ~/.local/state/{{plugin}}/bin/{{plugin}}-store cache --stdin
```

prints `cache 1h warm 25m left`; add `--json` for the object.
