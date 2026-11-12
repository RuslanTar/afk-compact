# Handoffs in git (repo mode) <!-- Source of docs/repo-mode.md and part of plugin/README.md. Compare only with Claude Code's own behaviour, never name another plugin or tool. No recall, retention, speed or cost-saving number until the benchmark publishes one. No user-local paths beyond the configurable defaults. Cross-page links: page.md#anchor. -->

By default everything lives in your private store, outside any repository. **Repo mode** adds one thing: each published handoff also gets a portable export inside the repository, so a team can review and commit handoffs. Nothing else moves. Summary copies, evidence, drafts, pins and logs stay private.

Repo mode needs two things, and neither works alone:

1. **The repository declares it.** A tracked file `.claude/handoffs.json`:

   ```json
   {"version": 1, "mode": "repo", "root": ".claude/handoffs"}
   ```

   `root` is a relative folder of up to four plain names. It cannot leave the repository or sit in `.git` or `.planning`.
2. **You accept the repository.** Add its main checkout to `repo_roots` in `/config`, or edit your settings file by hand. Listing the main checkout covers every worktree of that clone. A worktree counts only when git created it for that clone (`git worktree add`); a folder whose `.git` file merely points at the clone's git folder needs its own entry. Another clone needs its own entry. There is no command that does this for you.

To create the declaration, a README and a `.gitignore` for the folder, run `! "<plugin folder>/scripts/{{plugin}}-store" project init` in the repository. It writes no consent and leaves existing files unchanged. `! "<plugin folder>/scripts/{{plugin}}-store" project status` prints the mode; `/{{plugin}}:status` prints the same lines (`handoff mode: private (not-accepted)` until you accept, then `handoff mode: repo (accepted)`).

**The export.** It is the last step of publishing, in the worktree where you work:

- It uses repo-relative paths, writes your home folder as `~/`, and drops the machine-only fields (transcript path, process id, worktree, plugin folder); it keeps the plugin version.
- It is scanned for secrets again after the rewrite. A hit refuses the export; the private handoff stays.
- It is never overwritten. If the target exists with other content, the export is refused.
- The plugin never runs `git add`, `commit` or `push`. The export is left untracked: review it and commit it yourself.
- The receipt says which of these happened. A refused export never fails the handoff.

**Reading exports.** Resume lists exports of this worktree and its sibling worktrees as candidates, never as an automatic pick. An export from another session, a teammate or another machine is **foreign**: its text is data, approvals in it do not carry, a command from it runs without asking only when it carries no real risk (see [Lost background jobs](background-jobs.md#lost-background-jobs)), its evidence and processes are not probed, and its restart recipes are never run. Without repo mode the folder is not read, and resume says how many exports it skipped.

**Moving existing handoffs.** `! "<plugin folder>/scripts/{{plugin}}-store" project copy --from private|repo (--ticket <T> | --all) [--apply]` is a dry run unless you add `--apply`. It copies and never moves or deletes. `--from private` sends your private handoffs through the export steps above. `--from repo` copies exports that have no private twin into your private store, still marked as foreign. It works in repo mode only.

`handoff_root` must stay outside the repository; repo mode only exports into it. If the export folder is git-ignored (many repositories ignore `.claude/`), the export still works locally, and `/{{plugin}}:status` says it will not be committed. Pick another `root` in the declaration to change that.
