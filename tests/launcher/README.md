# Restart launcher: protocol 1 file contract and tests

`plugin/scripts/<brand>-claude` (built by `tools/build` from `src/claude-launcher.tmpl`) is the
opt-in launcher of restart on update. It starts `claude` as a child, waits,
and starts the same session again only when the plugin's note proves that the plugin itself
ended the session to restart it. This file is the contract the plugin side (the mod and the
helper's `restart` command) must meet. The cases in `run.sh` hold the launcher to it
with hand-written notes (`notes/`) and a stub `claude` (`stub/claude`).

Names below use the brand `afk-compact`; a rename changes every one of them (`tools/build`
fills `{{plugin}}`, `{{launch_env}}` and `{{version}}`).

## 1. The launch folder

- The cache folder (XDG): `$XDG_CACHE_HOME` when it is an absolute path (a relative one is
  ignored, as the XDG rules say), else `$HOME/.cache`, with trailing `/` removed. A `HOME` that
  is not an absolute path makes the launch a pass-through. A missing cache folder is created
  (`mkdir -p` under `umask 077`). Not `$TMPDIR` or `/tmp`: macOS removes files there that were
  not used for about 3 days, some Linux systems clean `/tmp` after about 10 days, and a session
  can live longer than that. A cache folder that others may write to without the sticky bit
  (`ls -ldn "<cache>/."` field 1 with `w` for group or other and no `t`/`T` at the end) makes
  the launch a pass-through: another user could rename the runtime folder away after its check
  and put one of their own in its place. The cache folder's owner and any ACL on it are not
  checked, so `$XDG_CACHE_HOME` must not name a folder another user owns.
- `<cache>/afk-compact/` (the runtime folder): created with `mkdir -m 700` when missing.
  It must not be a symlink, `ls -ldn` must show the uid as owner (field 3) and a mode (field 1)
  of `drwx------`, optionally followed by `@` (macOS extended attributes; macOS 13+ tags every
  new folder with `com.apple.provenance`) or `.` (an SELinux context). A `+` (an ACL) refuses,
  and on macOS `/bin/ls -lde` must print no ACL line (macOS shows `@`, not `+`, when a folder
  has both). On Linux, when `getfacl` is installed, `getfacl -c` must list only the `user::`,
  `group::` and `other::` entries. busybox `ls` never shows `+`, so on a busybox system without
  `getfacl` an ACL on the folder is not seen. Anything else: pass-through.
- `L-<token>/` inside it (the launch folder), `mkdir -m 700`, the same checks. The token is 16
  lower-case hex characters from `od -An -N8 -tx1 /dev/urandom`.
- `AFK_COMPACT_LAUNCH` holds the launch folder's path, exported to claude only when the launcher
  arms. A pass-through unsets it. The name is `tools/build`'s `launch_env(name)`: the plugin
  name in upper case, `-` as `_`, then `_LAUNCH`. The plugin side must take it from the same
  function (a literal `$.env.get(...)` in a generated module).
- At start the launcher removes the launch folders of launchers that are gone: an `L-*` folder
  whose `launcher.json` names a pid that `kill -0` does not reach. The plugin removes
  `last-refusal-*` files older than 7 days when a session claims or reports them (the cache
  folder is not cleaned by the system).
- At exit (any exit, HUP, TERM) the launcher removes the files below by name, then `rmdir`s the
  folder. A file with any other name keeps the folder alive, so the plugin writes no others.

## 2. Files

| File | Written by | When | Format | Read by |
|---|---|---|---|---|
| `launcher.json` | launcher | at start, and rewritten before each relaunch (`launcher.json.tmp`, then rename) | one JSON line (§3), 0600 | plugin: G3, G3a |
| `stamps` | launcher | one line appended at each relaunch | epoch seconds, one per line, 0600 | launcher cap; plugin G3a (`launcher-cap`) |
| `sid` | plugin (`restart arm`) | once, `O_EXCL`; rewritten (`sid.tmp`, then rename) when the claude process that bound it now runs another session (§6) | the session id and `\n`, then one line `<pid> <start time>` of that claude process | launcher (its first line must equal the note's `sid`); plugin G3 (`other-session`) |
| `restart.note` | plugin | at arm and at every state change: write `restart.note.tmp`, then rename | flat `key=value` lines (§4) | launcher, after claude exits |
| `restart.used` | launcher | the note renamed when the launcher consumes it | the note, unchanged | plugin: the claim proof in the new load (§5.2), never a note to act on |
| `restart.mode-end` | plugin (`on_SessionEnd`, optional hardening; not written on Claude Code 2.1.312, whose SessionEnd input has no `permission_mode`) | at session end: write `restart.mode-end.tmp`, then rename | one line: the internal mode name | launcher, then deleted |
| `../last-refusal-<token>` | launcher | a `go` note refused, a countdown stopped, or a relaunched claude failing within 15 s | `proto=1`, `reason=`, `sid=`, `at=` lines, 0600, no values | `/afk-compact:status`; the next load of that sid (`refresh_failed {route:'fg', why:'launcher-refused', code:<reason>}`). The plugin deletes it once reported; the launcher never does |

## 3. `launcher.json`

```
{"proto":1,"launcher_version":"0.1.0","pid":4242,"token":"<16 hex>","started":<epoch s>,"cwd":"<pwd -P>","uname":"Darwin|Linux","relaunches":0,"bypass_ok":false,"file_flags":["/abs/path",...],"stamps":"stamps","launch_mode":"plan"}
```

- One line, these keys in this order, no spaces. It holds no argv and no flag value other than
  the file paths. `cwd` and every path hold no `"`, `\` or control character: the launcher
  passes through instead, so the JSON needs no escapes.
- `pid` is the launcher shell (an ancestor of claude; with `--via`, a wrapper sits between).
- `relaunches` counts the relaunches of this launcher.
- `bypass_ok` is true when the launch arguments hold `--dangerously-skip-permissions` or
  `--allow-dangerously-skip-permissions`, or when the last `--permission-mode` (`=` form too) is
  `bypassPermissions` (commander keeps the last value of a repeated flag, so
  `--permission-mode bypassPermissions --permission-mode manual` is false). Nothing else
  counts: not bypass allowed in settings, and not
  `--inherit-permission-mode bypassPermissions` (Claude Code counts that one as bypass in some
  paths; leaving it out is the safe side).
- `file_flags` lists the values of `--settings`, `--mcp-config` (each value),
  `--system-prompt-file` and `--append-system-prompt-file` that are paths. A value whose first
  non-blank character is `{` or `[` (inline JSON), or that is empty, is not a path and is not
  listed. A leading `./` is removed and a relative path is joined to `cwd`; nothing else is
  normalized (`x/../s.json` stays).
- `launch_mode` is the mode this claude starts in, as the internal name: `bypassPermissions`
  when the launch arguments hold `--dangerously-skip-permissions` (it wins over
  `--permission-mode` at start), else the last `--permission-mode` value (`manual` written
  `default`). Empty when the launch names no mode (the settings decide), names one the
  launcher does not know, or uses `--inherit-permission-mode`. Before each relaunch it becomes
  the note's `mode`, the mode the relaunched claude starts in. The plugin reads it as the launch
  mode of its "never wider" rule (§6); an empty or missing value counts as `default`.
- The plugin refuses a `proto` it does not know.

## 4. `restart.note` (protocol 1)

Exactly these 12 keys, each once, in any order, one `key=value` per line, nothing else (no
blank line, no comment, no `\r`, at most 24 lines). Values are never evaluated; each must match
its pattern exactly.

| Key | Value |
|---|---|
| `proto` | `1` |
| `state` | `armed`, `exiting`, `go` or `cancelled` |
| `token` | the launch token (the `L-<token>` name and `launcher.json` `token`) |
| `sid` | the session id: a lower-case UUID, 8-4-4-4-12 hex |
| `nonce` | 16 lower-case hex characters |
| `at` | epoch seconds of the last state change (no leading zero) |
| `exiting_at` | epoch milliseconds, set at `exiting`; empty before (required for `go`) |
| `from`, `to` | the running and the target version, `x.y.z` digits |
| `model` | empty, or 1-100 of `A-Z a-z 0-9 . _ : / [ ] -`, not starting with `-` (so it can never read as a flag) |
| `effort` | empty, `low`, `medium`, `high`, `xhigh` or `max` |
| `mode` | `acceptEdits`, `auto`, `bypassPermissions`, `default`, `dontAsk` or `plan` (the internal name; the launcher writes `default` as `manual` on the command line) |

## 5. What the launcher does when claude exits

1. No `restart.note`: exit with claude's exit code. Nothing printed.
2. `state` is `armed`, `exiting` or `cancelled`: the same (the plugin did not ask for a
   relaunch, or a person exited).
3. `state` missing or not one of the four: one line `afk-compact: not restarting (pattern).`
   (with `Resume with: claude --resume <sid>` when the sid is valid), no `last-refusal`.
4. `state=go`: the checks below in order. The first that fails prints
   `afk-compact: not restarting (<reason>). Resume with: claude --resume <sid>` (the hint only
   with a valid sid), writes `last-refusal-<token>`, and exits with claude's code.

   | Reason | Fails when |
   |---|---|
   | `exit-code` | claude's exit code is not 0 |
   | `pattern` | any key missing, repeated or unknown, any value off its pattern, a line without `=` |
   | `proto` | `proto` is not 1 |
   | `token` | `token` is not this launcher's |
   | `age` | `now - at` is over 120 s, or `at` is more than 2 s in the future |
   | `window` | `exiting_at` is empty, or `at - floor(exiting_at / 1000)` is not 0 to 5 (the go must come within 5 s of the plugin's own `/exit`) |
   | `other-session` | `<launch>/sid` is missing, or holds another sid |
   | `bypass` | `mode=bypassPermissions` and `bypass_ok` is false |
   | `mode-changed` | `restart.mode-end` exists and differs from `mode` |
   | `launch-file` | a `file_flags` path is not a readable regular file |
   | `cap` | `stamps` holds 3 or more times from the last 3600 s |
   | `no-terminal` | stdin or stdout is no longer a terminal (a relaunched claude would start in print mode) |
   | `consume` | `restart.used` exists and is a symlink or not a regular file (a rename would move the note into a folder), or the rename to `restart.used` failed |

5. Rename `restart.note` to `restart.used`, print
   `afk-compact: restarting session <first 8 of sid> on Claude Code <to> in 3 s (Ctrl+C stops it)`
   (`... in 3 s, permission mode bypassPermissions (Ctrl+C stops it)` when the note's mode is
   `bypassPermissions`) and count down. Ctrl+C: `not restarting (cancelled)`, `last-refusal`,
   exit 130. A Ctrl+C counts from the moment claude has exited, so one pressed before the
   countdown line stops the relaunch too (the line is then not printed). HUP or TERM: exit 129
   or 143, never a relaunch. While claude runs, the shell runs these traps only once claude has
   exited (POSIX: a trap waits for the foreground command), so `kill <launcher pid>` alone
   leaves claude running and the launcher waiting; a closed terminal sends HUP to claude as
   well.
6. Rewrite `launcher.json` with `relaunches` + 1, append a stamp, and run
   `<--via words> claude <kept arguments> --resume <sid> [--allow-dangerously-skip-permissions] [--model <m>] [--effort <e>] --permission-mode <mode>`:
   - kept arguments: the launch arguments of class `keep` (the flag table in the template), in
     their original order, values included;
   - `--allow-dangerously-skip-permissions` exactly when `bypass_ok`; the launch's own
     `--dangerously-skip-permissions` never comes back;
   - `--model`: the note's `model`; when empty, the launch `--model` value (if there was one),
     as `--model=<value>` when that value starts with `-`;
   - `--effort`: the same with `effort` and the launch `--effort`;
   - a variadic flag (`--add-dir`, `--allowedTools`, `--mcp-config`, ...) takes the following
     words only in its space form, as commander does: after `--allowedTools=X` the next plain
     word is a prompt word and is dropped; after `--allowedTools X` it is a value and is kept;
   - `--permission-mode`: the note's `mode`, `default` written `manual`.
7. A relaunched claude that exits non-zero within 15 s: the line
   `afk-compact: Claude Code <to> did not start (exit <n>). Your session is saved; start it the way you usually do with --resume <sid>.`,
   `last-refusal` with `start-failed`, and exit with its code. No retry.
8. Otherwise the loop goes on with the next exit of claude (step 1).

## 6. What the plugin side must do (no launcher-only refusal)

A refusal after the plugin's `/exit` closes a session that was meant to continue, so the plugin
runs every check the launcher can fail before it arms (G3a), on the exact note it would write:

- `launcher.json` `proto` is 1; its `pid` is alive and an ancestor of this claude with no other
  claude between them; the folder is `L-<token>` with the `launcher.json` token and passes §1.
- `sid` binding: create `<launch>/sid` with `O_EXCL` (the session id, then the pid and start
  time of this claude). An existing file with another sid refuses
  (`launcher-invalid:other-session`), except when its second line names this same claude
  process (a `/clear` or `/resume` changed the session id in the launcher's own child) or a
  claude process that is gone (the launcher's earlier child, before a relaunch): then the file
  is rewritten for this session (`sid.tmp`, then rename).
- Every value matches §4 (`note-pattern`), and `bypassPermissions` only with `bypass_ok`
  (`bypass-not-available`). `mode` is the newest `permission_mode` of a main Stop,
  UserPromptSubmit or PermissionRequest hook input when it is from the last turn or later;
  otherwise the narrower of `launch_mode` and the newest one seen, never wider than either
  (`mode-unknown` when none was seen, or when the two are `plan` and `dontAsk`, which the
  plugin does not order).
- Every `file_flags` path is a readable regular file (`launch-file`).
- Fewer than 3 stamps from the last 3600 s (`launcher-cap`).
- Write each note as `restart.note.tmp`, then rename it. Set `at` at every state change.
  Write `go` within 5 s of `exiting_at` (milliseconds) and only when `session.end` has reason
  `prompt_input_exit`; the launcher reads it at most 120 s later. Both sides use the same
  clock (`date +%s`, `Date.now()`).
- In the launch folder, write only `sid`, `restart.note` (`.tmp`) and `restart.mode-end`
  (`.tmp`).
- Claim in the new load only with `restart.used` holding this note's `nonce` and `sid`
  (§5.2). Report and then delete `last-refusal-<token>` files.

What the plugin cannot predict, and so the launcher alone decides: claude's exit code, the
note's age at exit, a file deleted in the seconds between the gate and the exit, the countdown
and the crash guard.

## 7. When the launcher passes through

It runs claude exactly as given (with `--via` words first), with no launch folder and
`AFK_COMPACT_LAUNCH` unset, after one stderr line
`afk-compact: restart on update is not available for this launch (<reason>)`. The reason names
a flag or a fixed condition, never a value: a refuse-class flag (`-p`, `--bg`, `-w`,
`--remote-control`, `--no-session-persistence`, ...), an unknown flag, combined short flags, a
value given to a flag that takes none, a subcommand as the first positional word, stdin or
stdout not a terminal, a file path with a quote, backslash or control character, a working
folder path with one, no cache folder (a `HOME` that is not an absolute path, or one that
could not be made), a cache folder that others may write to without the sticky bit, a runtime
folder that is not private, no random token or clock, a launch folder that could not be made,
or a system other than macOS and Linux. On Windows (MINGW, MSYS, CYGWIN) the line is
`afk-compact: restart on update: not supported on Windows`. Inside a Claude Code session
(`CLAUDECODE` set) the launcher does not start at all: exit 2.

## 7a. Limits

- **Anything running as you can ask for a relaunch.** `AFK_COMPACT_LAUNCH` is in the
  environment of claude and so of every command it runs, and the launch folder is yours. A
  process that writes a valid `go` note there (with the `sid` file) gets a relaunch, and when
  the launch had a bypass flag (`bypass_ok`) the relaunch can come back in
  `bypassPermissions` even if you had left it; the countdown line then names that mode. This
  is no new power (such a process can already edit your settings), but "a bypass you left is
  never restored" holds only for notes the plugin writes.
- **The launch folder lives in your cache folder** (`~/.cache/afk-compact`, or under
  `$XDG_CACHE_HOME`). A tool that empties the cache folder during a session removes the launch
  folder: restart on update then ends for that session (no `launcher.json` for the plugin, no
  note for the launcher: the session simply exits as usual) and the hourly cap starts again.
  A launcher killed with SIGKILL, or a machine that stopped, leaves its folder until the next
  launcher start sweeps it.
- **ACLs under busybox:** see §1 (`getfacl`).
- **HUP and TERM** reach the launcher's traps only after claude has exited (§5 step 5).

## 8. Running the tests

- `tests/launcher/run.sh [--shell "SHELL"]... [--quick] [CASE...]`: every case under every
  POSIX shell found (`/bin/sh`, `/bin/bash`, `bash`, `/bin/dash`, `dash`, `/bin/zsh`, `zsh`,
  `busybox sh`; links to one already listed are skipped). Needs `script(1)` and `perl`.
- `tests/launcher/docker.sh [IMAGE...]`: the same on Linux in Docker, no network, no
  credentials, the repo read-only, as uid 1000, plus the real foreign-owner case. Default
  images: `debian:bookworm-slim` (dash as `/bin/sh`, bash) and `launcher-test-alpine:1`
  (busybox ash as `/bin/sh`, zsh, from `alpine.Dockerfile`). Both must be present locally:
  `docker pull debian:bookworm-slim` and `tests/launcher/docker.sh --build-alpine` (the only
  steps that use the network).
- `tools/launcher-flags`: the flag table against `claude --help` of the newest installed
  Claude Code (every visible option and command, and each option's arity).
- `tools/check phase0` and `integration` run `tools/launcher-flags` and `run.sh` in their
  `X-launcher` step; `integration` adds `docker.sh` (`LAUNCHER_DOCKER=skip` skips it and says
  so).
