# {{plugin}} <!-- Source of the header of plugin/README.md: the build adds the Contents list, then every shipped page of src/docs/ORDER (headings one level down), then _plugin-footer.md. Links as in a src/docs page. -->

When a Claude Code session compacts, {{plugin}} asks Claude Code's own summarizer for a handoff instead of a plain summary. It keeps a read-only copy of every summary, checks that the summary has the expected shape, and gives the next turn a short resume block. It also adds six skills: `/{{plugin}}:handoff`, `/{{plugin}}:resume`, `/{{plugin}}:status`, `/{{plugin}}:report`, `/{{plugin}}:settings` and `/{{plugin}}:prune`.

> [!NOTE]
> Early version (0.x). The parts that need a live session or a managed machine have not been run yet; see [Limits](limitations.md#limits). This page describes the design and reports no measurements.

This file is the full reference. The same pages, one by one, and the comparison with Claude Code's own compaction are on the project page: https://github.com/{{repo}}
