# Installation <!-- Source of docs/installation.md and part of plugin/README.md. Compare only with Claude Code's own behaviour, never name another plugin or tool. No recall, retention, speed or cost-saving number until the benchmark publishes one. No user-local paths beyond the configurable defaults. Cross-page links: page.md#anchor. -->

## Requirements

- Claude Code **{{cc_min}}** or newer (mods). The one-line install below needs **2.1.292** or newer. This version was tested against **2.1.319**; the `PermissionDenied` and `StopFailure` hooks are not yet checked on older versions.
- **Perl 5.28** or newer, using only modules that ship with every perl. It is already on macOS and on Debian and Ubuntu (slim images too). On Alpine, run `apk add perl` first; on a minimal Fedora image, `dnf install perl-interpreter`.
- `git` for the git measurements. On a Mac without the Command Line Tools, the plugin skips git rather than open the install dialog.
- Claude Code in a terminal, or a local session of the desktop app (the desktop app runs Claude Code headless, where the plugin compacts by running `/compact`; not yet checked live there, see [Limits](limitations.md#limits)). claude.ai and Cowork are not tested yet: whether they install the plugin and run its hooks, mod and helper has not been checked.

## Install

At the prompt of a terminal session:

```
/plugin install {{plugin}} --marketplace {{repo}}
```

From a shell:

```
claude plugin install {{plugin}} --marketplace {{repo}}
```

In the desktop app, where `/plugin` does not run: click **+** next to the prompt box, then **Plugins**, **Add marketplace** with `{{repo}}`, then **Add plugin**.

Answer `y` to add the marketplace, pick a scope (user scope is first), then review the settings screen. Every setting has a working default (see [Settings](configuration.md#settings)); `/{{plugin}}:settings` goes through them later, section by section.

To check the install, run `/{{plugin}}:status` in a session. It prints the effective thresholds and, after the first compaction, its verdict and the copy's path.

## Update

Auto-update is off for third-party marketplaces. Update by hand, then reload open sessions (or start a new one):

```
claude plugin update {{plugin}}
```

```
/reload-plugins
```

A session keeps the plugin copy it loaded until it reloads. When sessions started later run another version (an update, or a rollback), the session says so in one line, `this session runs 0.1.2; sessions started since 2026-11-01 14:02 +0200 run 0.1.3: /reload-plugins`: in `/{{plugin}}:status` (which always shows the session's version and plugin folder), in the resume block after a compaction, and in `/{{plugin}}:handoff`'s report. The other version is the one the newest session start on this machine loaded from the same install: a project pinned to another version (a project-scope install) is compared only with sessions of that project, and a `--plugin-dir` copy only with sessions of that folder. There is no line when that start is more than 7 days old, or when this session's copy was installed after it. Both sessions need 0.1.3 or later: an older session neither records its start nor shows the line, so the first notice comes with the first update after 0.1.3 while a 0.1.3 session still runs. When an update or an uninstall replaces the copy a session runs, Claude Code marks that copy in its plugin cache (and removes it 14 days later), and from 0.1.4 on the session says so at once, with no later session start needed: `this session runs 0.1.4, replaced by an install at 2026-11-01 14:02 +0200: /reload-plugins` (beside a newer start, both parts in one line). After `/reload-plugins` the session runs the new copy, which carries no mark, and the line goes.

After a Claude Code update, `/{{plugin}}:status` may say a check is due and offer a user-run `! "<plugin folder>/scripts/{{plugin}}-store" smoke`, printed with the real folder. It validates the plugin, runs its offline tests, and compares the Claude Code binary and its type declarations with the version this release was tested on. In the binary it counts the strings the plugin relies on. It fails only when the count of a rare string changes, or when the compaction experiment's list of arms changes. A rare string is one the tested binary holds at most a few times (the recorded limit is `rare_max` in `assets/canary-baseline.json`), such as the experiment flag, its environment variable and the idle-compaction notices. Common words such as `control` and `short` appear thousands of times in unrelated code, and their counts move with every release. A changed count of a common word prints an `info c8` line and does not fail smoke. The type declarations come from Claude Code's built-in plugin-authoring skill, which writes them to a temporary folder when it loads; Claude Code clears that folder after a few days. If smoke says none were found, type `/plugin-authoring` once in any session (it costs one model turn), then run smoke again while that session is open (or pass `--types FILE`).

## Uninstall

```
claude plugin uninstall {{plugin}}
```

Uninstalling removes the hooks and skills. It leaves your handoffs, copies, evidence and logs in place; see [What it writes](files-and-storage.md#what-it-writes-on-your-machine) to remove them. It also leaves `~/.local/state/{{plugin}}/bin/{{plugin}}-store`, the fixed path a [status line](status-line.md#the-cache-state-in-your-status-line) calls, which keeps running the old copy of the plugin: a copy in Claude Code's plugin cache until Claude Code deletes that folder, then it fails; a copy read in place from a local folder marketplace for as long as that folder exists, since Claude Code never deletes it. Delete it and remove the call from your status line.
