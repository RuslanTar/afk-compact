# Compatibility

Where the plugin runs: operating systems, Claude Code surfaces, and managed setups.

## Platforms

| Platform | This version |
|---|---|
| macOS 13 or newer | Supported. The full test suite runs on macOS (Apple silicon). |
| Linux with glibc | Supported, with perl 5.28 or newer. In containers, the helper compiles and its smoke checks pass on Debian 10 and 12, Ubuntu 20.04 and a current Ubuntu, and Fedora, with perl 5.28 to 5.42, on arm64 and emulated amd64. Perl 5.28 itself is checked on two images; with perl 5.26 or no perl, the plugin falls back as described in [Limits](limitations.md#limits). Not yet done on Linux: a clean run of the full test suite and a real Claude Code session. |
| Alpine and other musl systems | Expected to work, not yet tested in a session. With `apk add perl`, the helper's smoke checks pass in an Alpine container; without perl, the fallback works there. |
| WSL 2 | Expected to work like Linux, not yet tested. |
| Windows, native | Not supported yet; planned for a later release. |

The plugin has never run on native Windows. What follows is expected from the way it is built, not something that has been seen:

- **Without Git for Windows**, Claude Code runs hook commands in PowerShell, which cannot start the plugin's launcher. Each plugin hook is then expected to fail with a visible hook error at its event. These errors do not block a tool call or a compaction, but compactions are not reliably shaped, no summary or evidence copies are saved, and the skills cannot call the helper.
- **With Git for Windows**, the hooks may reach the helper through Git Bash and its perl, but nothing on that path has been tested: process start times, file locks and paths may be wrong, and the mod's own helper calls are expected to fail.

On Windows, running Claude Code inside WSL 2 is the expected route until native support lands.

## Surfaces

| Where Claude Code runs | What the plugin does there |
|---|---|
| Terminal (`claude`) | Everything these pages describe. |
| Headless: `claude -p`, the Agent SDK, and apps that run Claude Code through it, such as the desktop app | Shaping, saved copies, verdicts and the resume block. Its own compactions run as a plain `/compact` at a turn end; no nudge, handoff turn, idle handoff turn, continue or plugin idle compaction. Not yet checked in a live session. See [Limits](limitations.md#limits). |
| claude.ai and Cowork | Not tested yet. Cowork and remote sessions read their own settings and do not load the plugin from your machine (not tested). |
| Subagents, on any surface | Shaped summaries and saved copies; no resume block, nudge or handoff turn. |

## Team, Enterprise and managed machines

Some managed setups hold plugin hooks on compaction and prompt context for user-installed plugins. The plugin decides per compaction whether its mod hook ran, and its classic command hooks take over when it did not:

| What | Usual case | Mod hook held |
|---|---|---|
| Shaping native, manual and subagent compactions | mod hook | classic `PreCompact` fallback (one text that selects the subagent form by itself) |
| Plugin compactions, nudge, auto-continue | yes | yes |
| Resume block | prompt context | `SessionStart`, else the continue text; after an idle compaction none: its block waits for prompt context, never goes by `SessionStart`, and `/afk-compact:status` reports it as undelivered |
| Summary copy | `PostCompact`, mod as backup | `PostCompact`, mod as backup for its own compactions |
| Evidence before a compaction | before each main manual, auto or plugin compaction | only before the plugin's own; other compactions get the sweep right after |
| Measured facts to the summarizer | when `measured_block` is on | only on the plugin's own compactions |

`/afk-compact:status` shows how each compaction was shaped and the policy flags it read at session start.

If a policy stops the mod from loading at all, the classic hooks still shape, save and resume, but plugin compactions, the nudge and auto-continue stop. If a policy allows only managed hooks, the classic hooks do not run. When the mod hook is held as well, a turn-end compaction without auto-continue has no channel left for its resume block, and `/afk-compact:status` reports it as undelivered.

Under a Team organization that seats Claude Code's security plugin first, Claude Code may show the model a note that this plugin's compaction hook was skipped, sometimes after a subagent compacted. That note comes from Claude Code. The plugin's classic hooks shaped and saved that compaction, and `/afk-compact:status` shows it as `classic-only`.

The seated path has been run live under a Team organization (Claude Code 2.1.306 and 2.1.307, Haiku, one background subagent), but not yet on a machine with managed settings.
