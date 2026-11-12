# Benchmark

How afk-compact will be compared with Claude Code's native compaction, and what is published.

**Status: not run yet; results will land in `bench/results/<date>/`.** The method is fixed in advance and the runs have not started. Nothing in this repository claims a recall, retention, speed or cost result for the plugin.

## Files

| File | What it is |
|---|---|
| [METHOD.md](METHOD.md) | The frozen pre-registration: arms, settings, scenarios, planted facts and keys, measures, hypotheses, sample size, analysis, exclusions, stopping rules, limits. |
| [PRIOR.md](PRIOR.md) | The earlier lab runs, and why they are not used as results. |

## The design in short

- **Question.** In a long session that compacts again and again, what does Claude Code's native compaction lose, and what does afk-compact change? Three things are measured: what the session can still state, what it can recover when asked, and how it behaves after a resume.
- **Arms.** Native Claude Code 2.1.322 with no plugin, against the same Claude Code with afk-compact 0.1.9 at its install defaults. Same model (`claude-opus-5-5`, effort `high`), same scripted prompts, same seeds, run side by side in a fake HOME with auto-memory off.
- **Scenarios.** A synthetic, seeded repository per run.
  - SC-A: a load that grows over 10 compactions (the headline).
  - SC-B: a heavy load from the start, over 6 compactions.
  - SC-C: away and back (idle return, `claude --resume`, `/clear`).
  - OCT20: a replica of the 2026-10-20 lab, for comparability only.
  - Mode R (stage B): the plugin's own trigger at a real context size.
- **Endpoints.** Two co-primary endpoints, both in SC-A on 37 early facts and graded by deterministic keys: recall in the live context with no tools (closed book), and recall when read-only tools are allowed (open book). Everything else is secondary and reported with confidence intervals: summary recall by two blind judges, exact ids and numbers, rule drift, next step after resume, background work, approvals and their scope, idle return, `/clear`, cost and time.
- **Capabilities native lacks** (for example the documented resume command after `/clear`) are behaviour tests with pass rates in both arms, never recall numbers.
- **Analysis.** Paired by seed. Paired cluster bootstrap for the 95% CI, exact sign-flip permutation for the p-value, Holm across the two co-primaries. The README may say the plugin kept more (or less) only for a co-primary rejected under Holm; otherwise it says "no detectable difference at this n", with the CI.
- **Stopping rules.** n is fixed per stage; there is no early stop for efficacy or futility. Runs stop on budget, on account limits, or when a pilot gate fails. Invalid runs are retried once and listed.
- **What is published.** Every run, invalid ones with their reasons: scenarios, keys, summaries, saved copies, answers, judge outputs, the tables behind every chart, the pre-registration and every deviation from it.
- **Limits, stated in advance.** The plugin's author runs the benchmark. One model, one synthetic setting, one account. A cut at about 160K tokens, not the larger real cut. Real load profiles come from one user's sessions.

Results will be published here when the campaign has produced them.
