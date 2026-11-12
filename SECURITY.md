# Security policy

## Supported versions

afk-compact is an early (0.x) project. Only the **latest minor release** gets security fixes. Today that is the 0.1.x line, and the newest 0.1.x release is the supported one. If you run an older release, update first (`claude plugin update afk-compact`, then `/reload-plugins`) and check whether the problem is still there.

| Version | Supported |
|---|---|
| Latest minor release (the newest 0.1.x) | Yes |
| Anything older | No |

When 0.2 or a later minor ships, this table moves to it, and the previous minor stops getting fixes once the new one is out.

## Reporting a vulnerability

**Please do not open a public issue, pull request or discussion for a security problem.**

Use GitHub's private vulnerability reporting on the canonical repository, <https://github.com/RuslanTar/afk-compact>:

1. Open the repository's **Security** tab.
2. Choose **Report a vulnerability**.
3. Describe the problem as described below and submit.

Only the maintainers can read the report. GitHub keeps the discussion, any fix branch and the advisory in one private place until it is published. You do not need to give an email address.

Please include:

- the plugin version (`/afk-compact:status` shows it) and the Claude Code version;
- your operating system;
- what you did, what you expected and what happened;
- a minimal way to reproduce it, if you have one;
- what you think an attacker could do with it.

Do **not** attach real secrets, real conversations or real handoffs. If a reproduction needs sensitive content, describe its shape or use a made-up example. The plugin's own `/afk-compact:report` zip is content-free by design, but read what is inside before you attach it anywhere.

## What to expect

This is a small project run by one maintainer, so these are goals, not promises:

- an acknowledgement within 7 days;
- an assessment, and a plan or a request for more detail, within 14 days;
- a fix in the next release when the report is confirmed, with a credit in the advisory if you want one.

If a report is not a vulnerability, the maintainers will say why. If you do not hear back in 14 days, add a comment to the private report.

## What counts

The plugin runs on your machine, reads session transcripts and writes files, so these are in scope:

- **Content or secrets leaving a boundary they should not.** A secret, conversation text, a summary, a command or a path that appears in a `/afk-compact:report` zip, a log row, a published handoff, a repository export or a copy of evidence when the documented rules say it should be withheld, hashed or redacted.
- **A bypass of the secret scans** that run before a handoff is published, an evidence file is copied, or a report is built.
- **Writes outside the intended folders**, such as through a crafted path, a symlink, a long or non-ASCII name, a relative setting or a folder inside a git work tree that should have been refused.
- **Acting without asking.** A background job started again that the documented rules say must ask first, an approval carried across a compaction where the plugin says it asks again, or an action on a protected branch.
- **Command injection or code execution** through a hook input, a transcript row, a setting, a job record, a launcher argument or a file name.
- **A stored file with looser permissions than documented.** The plugin writes its files private (`umask 077`).
- **A network call.** The plugin makes none and sends no telemetry; any call it does make is a bug with security impact.

Out of scope:

- Problems in Claude Code itself, or in another plugin. Report those to their own maintainers.
- Anything that needs control of your own account or machine to begin with, such as editing your own settings file.
- The content of a conversation you chose to add to a report when the skill asked and you said yes.
- Reports that only describe a missing hardening measure, with no way to use it.
- Native Windows, which is not supported yet.

## Disclosure

After a fix ships, the maintainers publish a GitHub security advisory that names the affected and fixed versions and credits the reporter unless you ask not to be named. Please give the project a reasonable time to fix a problem before you talk about it in public; the maintainers will keep you informed and will not sit on a confirmed report.
