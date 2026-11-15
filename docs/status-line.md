# The cache state in your status line


Claude Code can show a status line below the prompt: a command of yours that gets the session's details as JSON on stdin (`statusLine` in your settings). The plugin's helper can put the prompt cache's state in it: whether the conversation is still cached, for how long, and, while keep-warm runs, which request of the idle gap it is at:

```
██████░░░░░░ 30m
```

That is the meter (`cache --stdin --bar`, 0.1.13): 12 cells that fill as the cache nears its expiry, blue, then yellow from half the time, red from 90%, and the cache's age, the time since the request that set its expiry (`--left` shows the time left instead). While keep-warm runs it turns cyan and reads `↻3/7`, with `…` while a request is out; a cold cache reads `cold 1h02m` (magenta) or `cold miss`, and right after a compaction `compacted`. A `~` before the age means the cache's lifetime was read from the transcript. Before the session's first response, or when the cache's lifetime is not known, it prints nothing. `--short` drops the cells (`c 30m`), `--ascii` draws `#` and `-`, and `--color never` turns colour off (`NO_COLOR` and `TERM=dumb` do too). `/afk-compact:settings` shows which status line your settings run, previews the meter and prints the snippet for your setup; it changes no file, you paste the snippet yourself.

Without `--bar` the command prints one plain line:

```
cache 1h warm 42m left ↻3/7
```

`↻3/7` is the third request of at most seven in this idle gap (`keep_warm_hours` × 60 − 1 minutes, divided by 50 and rounded down: 7 at the default 6 hours; a late or retried request can leave it at 6). A cold cache reads `cache 1h cold (expired 12m ago)` or `cache cold (keep-warm ping missed)` (a keep-warm request that did not read the conversation from the cache: the session's next request then misses it too). Right after a compaction it reads `cache compacted`: the context is nearly empty then, so there is little to cache, and the next request writes it anew. Before the session's first response there is nothing to read, and the command prints nothing.

Two more parts can follow. ` · ping pending` shows while a keep-warm request is out. ` · keep-warm off (<why>)` shows when keep-warm did not start in this idle gap, with the reason: `ttl-5m` (the five-minute cache), `near-limit` (a usage limit is near), `no-idle-path` (nothing would compact the session after it), `cutoff`, and so on. When no background job of the session is open (`no-jobs`), the line shows nothing: that is the normal idle case, not something to act on, and `/afk-compact:status` and the log still name it. For example:

```
cache 1h warm 8m left ↻2/7 · ping pending
cache 1h warm 6m left · keep-warm off (near-limit)
```

The command is `cache --stdin`, called through a fixed path that the plugin keeps pointing at its installed copy, `~/.local/state/afk-compact/bin/afk-compact-store` (`$XDG_STATE_HOME/afk-compact/bin/` when Claude Code's environment sets `XDG_STATE_HOME`); the first session of an installed copy writes it (one in Claude Code's plugin cache or its synced plugins folder, or one Claude Code reads in place from a local folder marketplace), and a `--plugin-dir` run never changes it. When the copy it points at is gone (uninstalled, pruned, a failed update), it prints nothing and exits 0, so the status line shows no cache segment instead of an error. After a downgrade to 0.1.12 or earlier the file keeps running the 0.1.13 copy while that copy exists (those versions do not recognise the new file and leave it alone), and once that copy is gone the segment stays blank; delete the file and the older version writes its own at its next session start (the plain line only: `--bar` needs 0.1.13). It reads Claude Code's own cache figures from the status line's input (Claude Code 2.1.312 and later; else the session's transcript) and the plugin's keep-warm record, writes nothing (unless you add `--note-usage`, below) and exits 0 (on a host whose perl the helper cannot run it prints `REFUSED: helper-runtime`, as every command does, except with `--bar`, which then prints nothing). A plugin copy older than 0.1.13 does not know `--bar`: the meter stays blank until the plugin is updated. Neither that path, the keep-warm record nor the shared usage record (`--note-usage`, below) is written inside a git work tree, such as a dotfiles repository at your home folder; set `XDG_STATE_HOME` outside it then (without the usage record, each session reads only its own usage, and `/afk-compact:status` shows none). The details are in `assets/cache-contract.md` in the plugin folder.

**A plain status line.** Claude Code runs one status line command and shows its output as the whole line, so this replaces the status line you have now. In `~/.claude/settings.json`:

```json
"statusLine": {
  "type": "command",
  "command": "[ ! -f ~/.local/state/afk-compact/bin/afk-compact-store ] || sh ~/.local/state/afk-compact/bin/afk-compact-store cache --stdin --bar --note-usage",
  "refreshInterval": 30
}
```

The `[ ! -f … ] ||` part runs the meter only once that file exists: before the plugin's first session writes it, the line stays empty instead of showing an error.

To keep your own line, call both from one script; the meter on a second line leaves your line exactly as it was, and a removed plugin drops only the meter:

```sh
#!/bin/sh
in=$(head -c 1048576)
printf '%s' "$in" | ~/bin/my-statusline
t=~/.local/state/afk-compact/bin/afk-compact-store
[ -x "$t" ] && printf '%s' "$in" | "$t" cache --stdin --bar --note-usage 2>/dev/null
exit 0
```

**ccstatusline.** Add a Custom Command widget in ccstatusline's own settings screen with the command `[ ! -f ~/.local/state/afk-compact/bin/afk-compact-store ] || sh ~/.local/state/afk-compact/bin/afk-compact-store cache --stdin --bar --note-usage` (ccstatusline passes Claude Code's JSON on to it; write the full path where `~` is not expanded), a timeout of 1000 ms, and "preserve colors" on (or add `--color never` and leave it off). `/afk-compact:settings` prints these values with the full path; the plugin never edits ccstatusline's own file.

**`--note-usage`.** With it, the command also records the usage limits the status line shows (the five-hour and seven-day shares and their reset times) in one small file of the plugin's, `~/.local/state/afk-compact/usage.v1.json`, where each session's hooks record their own readings too. It writes no account or conversation data, and leave it out to keep the command read-only: the plugin works the same without a status line.

**Your own format.** `cache --stdin --json` prints one JSON object (`state`, `seconds_left`, `keep_warm.n`, `keep_warm.max`, …). `label` is the word to show: `warm`, `compacted`, `cold` or `unknown` (`state` reads `cold` right after a compaction, as it always has); `keep_warm.pending` and `keep_warm.off` hold the two parts above. With `jq`, which not every system has: `… cache --stdin --json | jq -r '"\(.label) \(.seconds_left // "")"'`. A script can also ask about a session by its id, `cache --sid <session id> --json`, which reads the plugin's own record of it and its transcript.
