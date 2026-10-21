// GEN by tools/build from the ```json spec-literals block of src/assets/handoff-spec.md. Do not edit; edit the source and run tools/build.
export const SPEC_PRESENT = true as const

export const SPEC = {
  "spec_version": 1,
  "title_prefix": "# ",
  "sections_main": [
    "## Resume here",
    "## User constraints",
    "## Decisions and do-not-re-raise",
    "## In flight",
    "## Live state",
    "## Open questions",
    "## Location",
    "## Work done and findings",
    "## Evidence",
    "## Next steps"
  ],
  "sections_location": [
    "### GSD",
    "### Environment",
    "### Guards in force",
    "### Ownership"
  ],
  "sections_subagent": [
    "## Task as assigned",
    "## Constraints from the parent",
    "## Report",
    "## Done",
    "## Findings",
    "## Produced but not yet delivered",
    "## Own background tasks",
    "## Next action"
  ],
  "marker_re": "^⟪compactinue v1 n=([0-9a-f]{8}) s=(main|sub|manual)⟫$",
  "sentinel_re": "^⟪/compactinue n=([0-9a-f]{8})⟫$",
  "instr_marker_re": "⟪compactinue v1 n=([0-9a-f]{8}) s=(main|sub)⟫",
  "marker_window_lines": 5,
  "sentinel_window_nonblank_lines": 3,
  "wrappers": {
    "head_line_prefix": "This session is being continued",
    "tools_block_open": "<tools-used-before-summary>",
    "tools_block_close": "</tools-used-before-summary>",
    "summary_line": "Summary:",
    "summary_open": "<summary>",
    "summary_close": "</summary>"
  },
  "copy_trailers": [],
  "verdicts": [
    "stale",
    "scope-leak",
    "unshaped",
    "truncated",
    "ok-trailer",
    "ok"
  ],
  "ok_verdicts": [
    "ok",
    "ok-trailer"
  ],
  "scopes": [
    "main",
    "sub",
    "manual"
  ],
  "status_words": [
    "active",
    "blocked",
    "waiting-owner",
    "waiting-job",
    "done"
  ],
  "ladder": [
    "proposed",
    "queued",
    "implemented",
    "tested",
    "committed",
    "pushed",
    "in review",
    "merged",
    "deployed",
    "published",
    "installed"
  ],
  "claim_tags": {
    "verified_re": "\\[verified [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} [+-][0-9]{4}: [^\\]]+\\]",
    "unverified": "[unverified]",
    "inherited_re": "\\[inherited: [^\\]]+\\]",
    "superseded_re": "Superseded: [UDXQB]-[0-9]+ by [UDXQB]-[0-9]+ \\([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} [+-][0-9]{4}\\)"
  },
  "live_state_tags": [
    "measured",
    "verified",
    "unverified",
    "inherited"
  ],
  "time_re": "[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} [+-][0-9]{4}",
  "time_legacy_re": "([0-9]{2}-[0-9]{2} )?[0-9]{2}:[0-9]{2}",
  "id_prefixes": {
    "U": "user constraint, approval or ask",
    "D": "decision",
    "X": "rejected, refuted or failed",
    "Q": "question",
    "B": "in-flight row"
  },
  "id_range_re": "\\b[UDXQB]-[0-9]+(\\.\\.|–|—)([UDXQB]-)?[0-9]+\\b",
  "question_owners_re": "^(next-agent|user|external:.+|bg:B-[0-9]+)$",
  "question_raised_by": [
    "user",
    "agent",
    "external"
  ],
  "question_status_re": "^(unasked|asked [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} [+-][0-9]{4}|timed out|answered: .+)$",
  "restart_classes": [
    "auto",
    "ask",
    "never"
  ],
  "kinds": [
    "agent",
    "teammate",
    "workflow",
    "monitor",
    "cron",
    "shell",
    "server",
    "peer",
    "external"
  ],
  "dies_on": [
    "/clear",
    "exit",
    "7-day expiry",
    "nothing"
  ],
  "frontmatter_status": [
    "in-progress",
    "blocked",
    "completed"
  ],
  "lineage_reasons": [
    "clear",
    "fork",
    "bg-copy",
    "handoff-resume",
    "none"
  ],
  "relations": [
    "same-session",
    "successor",
    "other",
    "unselected"
  ],
  "integrity": [
    "ok",
    "possibly truncated",
    "legacy",
    "unshaped",
    "s=sub"
  ],
  "lane_re": "^(lane|auto):[A-Za-z0-9._/-]+$",
  "lane_adopt_re": "^lane:[A-Za-z0-9._/-]+$",
  "none_forms_handoff": {
    "## User constraints": [
      "^none stated$"
    ],
    "## In flight": [
      "^Nothing in flight — checked [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} [+-][0-9]{4} via .+$",
      "^Nothing in flight known \\(not checked\\)$"
    ],
    "## Live state": [
      "^none beyond git — checked [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} [+-][0-9]{4}$"
    ],
    "## Open questions": [
      "^none$"
    ]
  },
  "none_forms_compaction": {
    "## User constraints": [
      "^none stated$"
    ],
    "## In flight": [
      "^Nothing in flight as of the last message \\(not checked\\)$"
    ],
    "## Live state": [
      "^none beyond git \\(not checked\\)$"
    ],
    "## Open questions": [
      "^none$"
    ],
    "## Own background tasks": [
      "^none \\(not checked\\)$"
    ]
  },
  "inflight_table_columns": [
    "B-n · runtime id",
    "kind · what · owner",
    "due · watched (last probe)",
    "probe",
    "on finish",
    "dies on",
    "restart"
  ],
  "inflight_compact_row_re": "^-? ?B-[0-9]+ \\S+ · ",
  "inflight_max_rows": 8,
  "more_handoff_re": "^\\+[0-9]+ more: B-[0-9]+(, B-[0-9]+)*; see evidence/[^ ]+/inflight\\.md$",
  "more_compaction_re": "\\+[0-9]+ more: B-[0-9]+(, B-[0-9]+)*",
  "recipe_path": "<bucket>/evidence/<stem>/restart/<B-n>.md",
  "fold_line_re": "^(- )?([DX]-[0-9]+(, [DX]-[0-9]+)*) settled; full text in (\\S+)$",
  "frontmatter_keys_handoff": [
    "kind",
    "writer",
    "nonce",
    "date",
    "session_id",
    "actor",
    "previous_session_id",
    "lineage_reason",
    "transcript_path",
    "claude_pid",
    "cc_version",
    "repository",
    "bucket",
    "worktree",
    "branch",
    "git_commit",
    "status",
    "ticket",
    "queue_lane",
    "previous_handoff",
    "previous_kind",
    "own_previous_handoff",
    "imported_from",
    "gsd"
  ],
  "frontmatter_keys_copy": [
    "kind",
    "writer",
    "nonce",
    "date",
    "session_id",
    "actor",
    "previous_session_id",
    "lineage_reason",
    "transcript_path",
    "claude_pid",
    "cc_version",
    "repository",
    "bucket",
    "bucket_source",
    "worktree",
    "branch",
    "git_commit",
    "status",
    "queue_lane",
    "previous_handoff",
    "trigger",
    "compaction_seq",
    "tokens_before",
    "tokens_after",
    "verdict",
    "channel",
    "seat_state",
    "evidence",
    "redacted"
  ],
  "frontmatter_keys_export": [
    "kind",
    "writer",
    "nonce",
    "date",
    "session_id",
    "actor",
    "previous_session_id",
    "lineage_reason",
    "cc_version",
    "repository",
    "bucket",
    "branch",
    "git_commit",
    "status",
    "ticket",
    "queue_lane",
    "previous_handoff",
    "gsd",
    "export"
  ],
  "export_value": "repo",
  "previous_kinds": [
    "own",
    "chain",
    "foreign"
  ],
  "carry": {
    "tag_re": "\\[from [0-9a-f]{8} · ([UDX]-[0-9]+|-) · [^\\]]+\\]",
    "foreign_approval_note": "context only, not valid here; re-ask"
  },
  "call_cap": 25,
  "recipe_cap": 8,
  "lint_ids": {
    "blocking": [
      "headings",
      "meta-in-draft",
      "update-heading",
      "resume-lines",
      "step1-mismatch",
      "none-form",
      "ephemeral-path",
      "live-asof",
      "unprinted-time",
      "time-format",
      "id-range",
      "carry-provenance",
      "carry-approval",
      "private-path",
      "recipe-placeholder",
      "recipe-script",
      "recipe-spawn",
      "secret-hard"
    ],
    "advisory": [
      "size",
      "section-cap",
      "code-block",
      "log-lines",
      "hash-lines",
      "must-read",
      "changes",
      "overlap",
      "recipe-mismatch",
      "secret-warn"
    ],
    "repo_mode_only": [
      "private-path"
    ]
  },
  "private_path_classes": [
    {
      "id": "claude-projects",
      "re": "(~|\\$HOME|\\$\\{HOME\\})/\\.claude/projects/"
    },
    {
      "id": "claude-jsonl",
      "re": "(~|\\$HOME|\\$\\{HOME\\})/\\.claude/[^\\s'\"`]*\\.jsonl"
    },
    {
      "id": "other-home",
      "re": "(/[U]sers/[^/\\s'\"`]+/|/[h]ome/[^/\\s'\"`]+/|[A-Za-z]:\\\\{1,2}[U]sers\\\\{1,2}[^\\\\\\s'\"`]+\\\\)"
    },
    {
      "id": "probe-tmp",
      "re": "(/private/tmp/claude-|/tmp/claude-|\\$TMPDIR/claude-|\\$\\{TMPDIR\\}/claude-)"
    }
  ],
  "wait": {
    "cond_res": {
      "pid-exit": "^pid-exit:([0-9]+)(@([0-9]+))?$",
      "file": "^file:([^:]+)$",
      "marker": "^marker:([^:]+):(.+)$",
      "exit": "^exit:([^:]+)$"
    },
    "guard_res": {
      "pid": "^pid:([0-9]+)(@([0-9]+))?$",
      "file": "^file:([^:]+)$"
    },
    "max_default_s": 270,
    "max_range_s": [
      0,
      7200
    ],
    "main_max_s": 1800,
    "subagent_bash_timeout_ms": 300000,
    "marker_regex_max_chars": 200,
    "marker_regex_forbidden": [
      "(?{",
      "(??{",
      "(*"
    ],
    "alarm_slack_s": 5,
    "match_text_max_chars": 120,
    "first_scan_max_bytes": 268435456,
    "exit_codes": {
      "done": 0,
      "refused": 3,
      "pending": 10,
      "stalled": 11,
      "ended": 12,
      "overdue": 13,
      "usage": 64,
      "internal": 70
    },
    "exit_markers": [
      {
        "id": "echo",
        "re": "^__exit (-?[0-9]+)$",
        "active": true
      },
      {
        "id": "runtime",
        "re": "^\\[exited with code (-?[0-9]+)\\]$",
        "active": true
      },
      {
        "id": "killed",
        "re": "^\\[killed\\]$",
        "active": true,
        "means": "killed"
      }
    ],
    "end_suffix": "; echo \"__exit $?\"",
    "inflight_probe_cmd": "compactinue-store wait --for <spec> --max 0"
  },
  "frontmatter_kinds": [
    "handoff",
    "compact-summary",
    "subagent-summary"
  ],
  "writers": [
    "handoff",
    "mod",
    "postcompact-fallback"
  ],
  "evidence_statuses": [
    "copied",
    "dup",
    "ref-only",
    "redacted",
    "withheld",
    "missing"
  ],
  "manifest_columns": [
    "copy_path",
    "origin",
    "bytes",
    "sha256",
    "mtime",
    "copied_at",
    "mode",
    "scan",
    "regen_cmd",
    "meaning"
  ],
  "manifest_scan": [
    "full",
    "excerpt",
    "ref-only",
    "withheld",
    "redacted"
  ],
  "receipts": {
    "wrote": "Wrote handoff to: ",
    "refused_lint_re": "^REFUSED: lint \\([0-9]+ blocking\\); draft kept at .+$",
    "refused_re": "^REFUSED: .+$"
  },
  "secret_rules": [
    {
      "id": "pem",
      "class": "HARD",
      "re": "-----BEGIN ([A-Z0-9 ]+)-----(?:(?:(?!-----BEGIN )[\\s\\S])*?-----END \\1-----|(?:(?:\\r?\\n|(?:\\\\r)?\\\\n)[ \\t]*(?:[A-Za-z0-9+/=]+|(?:Proc-Type|DEK-Info|Version|Comment|Hash|Charset): [^\\r\\n\\\\\"]*)?(?=[\\r\\n\\\\\"']|$))*)"
    },
    {
      "id": "aws-key-id",
      "class": "HARD",
      "re": "\\b(AKIA|ASIA)[0-9A-Z]{16}\\b"
    },
    {
      "id": "github-token",
      "class": "HARD",
      "re": "\\bgh[pousr]_[A-Za-z0-9]{36,}"
    },
    {
      "id": "github-pat",
      "class": "HARD",
      "re": "\\bgithub_pat_[A-Za-z0-9_]{50,}"
    },
    {
      "id": "gitlab-token",
      "class": "HARD",
      "re": "\\bglpat-[A-Za-z0-9_-]{20,}"
    },
    {
      "id": "slack-token",
      "class": "HARD",
      "re": "\\bxox[abposr]-[A-Za-z0-9-]{10,}"
    },
    {
      "id": "anthropic-key",
      "class": "HARD",
      "re": "\\bsk-ant-[A-Za-z0-9_-]{20,}"
    },
    {
      "id": "openai-key",
      "class": "HARD",
      "re": "\\bsk-(proj-)?[A-Za-z0-9]{20,}"
    },
    {
      "id": "google-api-key",
      "class": "HARD",
      "re": "\\bAIza[0-9A-Za-z_-]{35}"
    },
    {
      "id": "stripe-key",
      "class": "HARD",
      "re": "\\b[rs]k_live_[A-Za-z0-9]{20,}"
    },
    {
      "id": "npm-token",
      "class": "HARD",
      "re": "\\bnpm_[A-Za-z0-9]{36}\\b"
    },
    {
      "id": "jwt",
      "class": "HARD",
      "re": "\\beyJ[A-Za-z0-9_-]{8,}\\.eyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}"
    },
    {
      "id": "auth-header",
      "class": "HARD",
      "re": "\\b([Bb]earer|[Bb]asic)[ \\t]+[A-Za-z0-9._~+/-]{16,}=*"
    },
    {
      "id": "url-userinfo",
      "class": "HARD",
      "re": "\\b[A-Za-z][A-Za-z0-9+.-]*://[^/\\s:@]*:[^/\\s@]+@[^/\\s]+"
    },
    {
      "id": "key-value",
      "class": "WARN",
      "re": "([Pp][Aa][Ss][Ss]([Ww][Oo][Rr][Dd]|[Ww][Dd])?|[Ss][Ee][Cc][Rr][Ee][Tt]|[Tt][Oo][Kk][Ee][Nn]|[Kk][Ee][Yy])[\"']?[ \\t]*[=:][ \\t]*[\"']?[^\\s\"',;]{6,}"
    },
    {
      "id": "cloud-key-bare",
      "class": "WARN",
      "re": "(^|[^A-Za-z0-9/+])(?=[A-Za-z0-9/+]{0,39}[A-Z])(?=[A-Za-z0-9/+]{0,39}[a-z])(?=[A-Za-z0-9/+]{0,39}[0-9])[A-Za-z0-9/+]{40}($|[^A-Za-z0-9/+=])"
    },
    {
      "id": "high-entropy",
      "class": "WARN",
      "re": "(^|[^A-Za-z0-9+/])(?=[A-Za-z0-9+/]{0,200}[0-9])(?=[A-Za-z0-9+/]{0,200}[A-Z])(?=[A-Za-z0-9+/]{0,200}[a-z])[A-Za-z0-9+/]{32,}={0,2}",
      "min_entropy": 4.0
    },
    {
      "id": "cookie",
      "class": "WARN",
      "re": "([Ss]et-)?[Cc]ookie\\\\?[\"']?[ \\t]*:[ \\t]*(\\\\?[\"'\\[][ \\t]*)*([^=\\s;\"'\\\\]+=\\\\?\"?[^;\\s\"'\\\\]*(\\\\?\")?;[ \\t]*)*[^=\\s;\"'\\\\]+=\\\\?\"?[^;\\s\"'\\\\]{8,}((\\\\?\")?;[ \\t]*[^=\\s;\"'\\\\]+=\\\\?\"?[^;\\s\"'\\\\]*)*"
    }
  ],
  "deny_names": {
    "globs": [
      ".env*",
      "*.pem",
      "*.key",
      "*.p12",
      "*.pfx",
      "id_rsa*",
      "id_dsa*",
      "id_ecdsa*",
      "id_ed25519*",
      ".netrc",
      ".npmrc",
      ".claude.json",
      ".credentials.json",
      ".bash_history",
      ".zsh_history",
      ".sh_history",
      "fish_history",
      "history.jsonl",
      "*.har",
      "*.sqlite",
      "*.sqlite3",
      "*.heapsnapshot"
    ],
    "except_globs": [
      ".env.example",
      ".env.sample",
      ".env.template",
      ".env.dist",
      ".env.*.example",
      ".env.*.sample",
      ".env.*.template",
      ".env.*.dist"
    ]
  },
  "log_like_globs": [
    "*.log",
    "*.json",
    "*.jsonl",
    "*.ndjson",
    "*.output"
  ],
  "clutter_classes": [
    {
      "id": "abs-path-line",
      "re": "^[ \\t]*([-*][ \\t]+)?(/|~/)[^ \\t]+[ \\t]*$"
    },
    {
      "id": "code-block",
      "re": "^[ \\t]*(```|~~~)",
      "max_lines": 5
    },
    {
      "id": "log-line",
      "re": "^[ \\t]*(\\[?[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}|\\[?(TRACE|DEBUG|INFO|WARN|WARNING|ERROR|FATAL|CRITICAL)\\]?[ :])"
    },
    {
      "id": "stack-line",
      "re": "^([ \\t]+at [^ ]+.*[(:][0-9]+|[ \\t]*File \"[^\"]+\", line [0-9]+|Traceback \\(most recent call last\\)|[ \\t]*(from )?[^ \\t]+\\.[a-z]+:[0-9]+:in )"
    },
    {
      "id": "arithmetic-line",
      "re": "^[ \\t]*([-*][ \\t]+)?[0-9][0-9.,_]*([ \\t]*[-+*/×x÷][ \\t]*[0-9][0-9.,_]*)+[ \\t]*=[ \\t]*[-+]?[0-9]"
    },
    {
      "id": "hash-run",
      "re": "^[ \\t]*([-*][ \\t]+)?`?[0-9a-f]{7,64}`?([ \\t]|$)",
      "min_run": 4
    },
    {
      "id": "tmp-path",
      "re": "(^|[\\s'\"(=:`])(/tmp/|/private/tmp/|/var/folders/|/private/var/folders/|\\$TMPDIR/|\\$\\{TMPDIR\\}/|[^\\s'\"`]*/scratchpad/|[^\\s'\"`]*/tasks/[^/\\s'\"`]+\\.output)"
    }
  ],
  "outward_classes": [
    {
      "id": "push",
      "re": "\\bgit\\b.*\\bpush\\b"
    },
    {
      "id": "force-push",
      "re": "\\bgit\\b.*\\bpush\\b.*(--force|--force-with-lease|[ \\t]-[A-Za-z]*f\\b|[ \\t]\\+[^ \\t]+)"
    },
    {
      "id": "mr-write",
      "re": "\\b(gh[ \\t]+(pr|issue)[ \\t]+(create|merge|close|reopen|comment|edit|review|ready)|glab[ \\t]+(mr|issue)[ \\t]+(create|merge|close|reopen|note|update|approve))\\b"
    },
    {
      "id": "http-write",
      "re": "\\b(curl\\b.*([ \\t](-X|--request)[ \\t]*(POST|PUT|PATCH|DELETE)\\b|[ \\t](-d|--data[a-z-]*|-F|--form|-T|--upload-file)\\b)|wget\\b.*--(post|method)|gh[ \\t]+api\\b.*([ \\t](-X|--method)[ \\t]*(POST|PUT|PATCH|DELETE)|[ \\t](-f|-F|--field|--raw-field|--input)\\b))"
    },
    {
      "id": "deploy",
      "re": "\\b(deploy|kubectl[ \\t]+(apply|create|delete|patch|replace|rollout|scale|set|edit)|helm[ \\t]+(install|upgrade|uninstall|rollback)|terraform[ \\t]+(apply|destroy|import)|tofu[ \\t]+(apply|destroy))\\b"
    },
    {
      "id": "publish",
      "re": "\\b((npm|yarn|pnpm)[ \\t]+publish|gem[ \\t]+push|twine[ \\t]+upload|cargo[ \\t]+publish|docker[ \\t]+push|gh[ \\t]+release[ \\t]+(create|upload|edit))\\b"
    },
    {
      "id": "history-rewrite",
      "re": "\\bgit\\b.*\\b(rebase|filter-branch|filter-repo|commit[ \\t]+.*--amend|reset[ \\t]+.*--hard|update-ref[ \\t]+-d)\\b"
    },
    {
      "id": "recursive-delete",
      "re": "\\b(rm[ \\t]+(-[A-Za-z]*[rR][A-Za-z]*|--recursive)\\b|find\\b.*[ \\t]-delete\\b|git[ \\t]+(.*[ \\t])?clean\\b|rsync\\b.*--delete)"
    },
    {
      "id": "mcp-write",
      "re": "^mcp__.+__([A-Za-z]+_)?([Cc]reate|[Uu]pdate|[Dd]elete|[Rr]emove|[Pp]ost|[Ss]end|[Mm]erge|[Pp]ublish|[Ww]rite|[Aa]dd|[Ee]dit|[Cc]omment|[Tt]ransition|[Aa]pprove|[Cc]lose)"
    }
  ],
  "alert_texts": {
    "A-01": "summary copy missing",
    "A-02": "unshaped or truncated shaped compaction",
    "A-03": "scope leak",
    "A-04": "fabricated check lines",
    "A-05": "compaction outside the band",
    "A-06": "cold large compaction",
    "A-07": "thrash",
    "A-08": "nudge unresolved",
    "A-09": "ledger loss",
    "A-10": "summary growth",
    "A-11": "stalled background item",
    "A-12": "outward action without consent",
    "A-13": "session-id canary",
    "A-14": "slow resume",
    "A-15": "version, arm or hook-surface change",
    "A-16": "sec-default bypass suspected",
    "A-17": "failed or blocked compaction",
    "A-18": "auto-continue stopped",
    "A-19": "auto-continue cap breached",
    "A-20": "workflow stopped after compaction",
    "A-21": "secret-shaped content in a summary or copy",
    "A-22": "heal on an unproven relation",
    "A-23": "resume block missing, doubled or degraded",
    "A-24": "storage growth",
    "A-25": "watcher unhealthy",
    "A-26": "plugin layers not running",
    "A-27": "auto-continue without a nudge"
  }
} as const
