# Earlier runs, and why they are not results

Before the pre-registered benchmark ([METHOD.md](METHOD.md)) there were earlier lab experiments. This page lists them and says why none is used as a result for afk-compact 0.1.9. It gives no scores on purpose: those runs are not evidence for the current plugin.

## What exists

**The 2026-10-20 lab (OCT20).** One day, one account, one machine, Claude Code 2.1.304, `claude-opus-5-5` at effort `xhigh`, a 150K window (300K for the longer soak runs). It ran a synthetic repository with 14 planted facts (canaries), compacted about 5 times per run, and scored each summary with two blind judges.

| Arm | What it was |
|---|---|
| Native | No steering; a logging probe only. |
| Classic hooks | A lab summary instruction on the PreCompact hook, plus a resume block. |
| CLAUDE.md | The same instruction as a `## Compact Instructions` section. |
| Lean | Native, with the summarizer variant forced by an environment variable. |
| Lean + hooks | Lean plus the classic hooks. |
| Short | A mod asking for at most three short sentences. |
| Fork-swap | A fork writes the saved document, replacing the engine summary. |
| Turn-end trigger | Compaction at a turn end, with the classic hooks. |
| Soak (native, mod, fixed mod) | Longer runs under the author's full setup with background jobs. |

Eleven runs were judged; five more were mechanism probes with no judging. Each arm has n = 1.

**Idle-compaction experiment.** Eight runs on Claude Code 2.1.309 that checked how native idle compaction and the plugin's early idle handling behave. They have no planted facts and no recall scoring.

**Planned studies that never ran as scored arms.** An n >= 5 design and a second scenario with 38 canaries were written and not run.

## Why they are not used as results

1. **n = 1 per arm.** Between-run spread is unknown, and the differences that were seen are a point or two of a small total. That is not distinguishable from noise.
2. **The plugin arms tested an ancestor text.** Every instructed arm used one short lab instruction. The text the plugin ships today has a different form and very little word overlap with it. It adds a marker, a resume section, numbered rule and decision lines that are copied across summaries, in-flight job rows and tags.
3. **Auto-memory leaked the planted facts** into later answers in most judged runs, so the recall quiz and the next-step turn are confounded.
4. **The native arm was not purely native.** It carried the lab probe and logging hooks, and the server-side summarizer variant was not pinned. The soak runs used the author's full settings and plugins of that day.
5. **The background agent's sleep was blocked** in the first two waves, so that fact measures a finished result, not a job in flight.
6. **Blinding was partial.** The summary form gives the arm away.
7. **Judge inputs for the soak runs were cut** to a length limit, though the summaries were not.
8. **Per-summary, per-fact judge scores do not exist.** The judges scored each fact only for the last summary.
9. **Small windows.** Real sessions compact at far larger context sizes, and mid-turn automatic compaction differs from turn-end compaction in timing as well as text.
10. **Claude Code moved on.** Version 2.1.309 and later keep the last messages verbatim after the summary, which changes how stale a next step can be.
11. **Cost was not logged per run.**

## How they are used anyway

- Only in the OCT20 replica panel, never pooled into SC-A, SC-B or SC-C.
- Each earlier run carries a weight below 1: a text-lineage weight for how close its instruction text is to the shipped text per fact type, a version weight for the Claude Code change, and a scenario weight. The rule and the per-run weights are in [METHOD.md](METHOD.md#114-earlier-runs-oct20-panel-only).
- Native-only and short-summary runs carry no plugin weight. They are context, not plugin evidence.
- The v2-only result is always shown first, with the pooled result beside it, and with the sensitivity at weights 0 and 1.
- The saved summaries and judge inputs can be re-scored with the new rubric at no run cost.
