// GEN by tools/fixtures-gen from tests/fixtures. Do not edit; edit the fixtures and run tools/fixtures-gen.
export const PAYLOADS: Readonly<Record<string, Readonly<Record<string, unknown>>>> = {
 "PermissionDenied/bash-push-classifier-policy": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "PermissionDenied",
  "permission_mode": "auto",
  "tool_name": "Bash",
  "tool_input": {
   "command": "git push origin feature/LAB-123-retry",
   "description": "push the branch"
  },
  "tool_use_id": "toolu_fixture_bash_push_classifier_policy",
  "reason": "Denied by the auto-mode classifier: pushing to a remote needs the user's approval."
 },
 "PermissionDenied/bash-sleep-classifier-unavailable": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "PermissionDenied",
  "permission_mode": "auto",
  "tool_name": "Bash",
  "tool_input": {
   "command": "sleep 120 && bin/check SECRET_CANARY_7f3",
   "description": "wait for the job"
  },
  "tool_use_id": "toolu_fixture_bash_sleep_classifier_unavailable",
  "reason": "The permission classifier is temporarily unavailable, so this action was denied."
 },
 "PermissionDenied/mcp-tool-other": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "PermissionDenied",
  "permission_mode": "auto",
  "tool_name": "mcp__fixture-server__delete_item",
  "tool_input": {
   "item": "LAB-123"
  },
  "tool_use_id": "toolu_fixture_mcp_tool_other",
  "reason": "Something else stopped this call.",
  "mcp_server": {
   "name": "fixture-server",
   "source": "user"
  }
 },
 "PermissionDenied/read-env-rule": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "PermissionDenied",
  "permission_mode": "auto",
  "tool_name": "Read",
  "tool_input": {
   "file_path": "$TMP/example-repo/.env"
  },
  "tool_use_id": "toolu_fixture_read_env_rule",
  "reason": "Denied by permission rule Read(./.env) in project settings."
 },
 "PermissionDenied/write-outside-user": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "PermissionDenied",
  "permission_mode": "auto",
  "tool_name": "Write",
  "tool_input": {
   "file_path": "$TMP/outside/notes.md",
   "content": "CANARY-TEXT-tool-input"
  },
  "tool_use_id": "toolu_fixture_write_outside_user",
  "reason": "The user rejected this tool call."
 },
 "PostCompact/canary": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "PostCompact",
  "trigger": "manual",
  "compact_summary": "<summary>\n\u27eacompactinue v1 n=1a2b3c4d s=main\u27eb\n# LAB-123 \u2014 retry worker drains, one flaky spec open\n## Resume here\nStatus: active \u00b7 State: retry worker implemented, one flaky spec left (checkpoint: clean)\nStep 1: `bin/test spec/workers/retry_worker_spec.rb:42` \u2014 for \"make the retry worker drain the queue\"\nGate: none \u00b7 Don't: re-run the full suite before the flaky spec is fixed\nLive: nothing running known (not checked)\n## User constraints\nU-1 \"keep the public API of RetryWorker unchanged\" \u2014 scope lib/retry_worker.rb; ask: open\nU-2 \"no new gems\" \u2014 scope Gemfile; ask: done\n## Decisions and do-not-re-raise\nD-1 exponential backoff capped at 5 tries \u2014 because the upstream rate limit resets in 60 s (user)\nD-3 keep SECRET_CANARY_7f3 out of logs \u2014 because it is a fixture canary (user)\nD-2 the job stays idempotent by request id \u2014 because duplicates were seen in staging (agent)\nX-1 rejected a global mutex \u2014 it serialised unrelated queues\n## In flight\nNothing in flight as of the last message (not checked)\n## Live state\nnone beyond git (not checked)\n## Open questions\nQ-1 drop the legacy retry flag now or next release \u00b7 blocks nothing \u00b7 options now, next \u00b7 recommendation next \u00b7 raised by agent \u00b7 unasked\n## Location\nworktree example-repo, branch feature/LAB-123-retry, cwd example-repo\n## Work done and findings\nRetryWorker backoff: implemented \u2014 lib/retry_worker.rb#perform; tests: 41 pass, 1 flaky, `bin/test spec/workers`\nFinding: the flaky spec depends on wall-clock rounding \u2014 spec/workers/retry_worker_spec.rb:42\n## Evidence\nVolatile: none\n## Next steps\n1. `bin/test spec/workers/retry_worker_spec.rb:42` \u2014 done when it passes 5 runs in a row\n\u27ea/compactinue n=1a2b3c4d\u27eb\n</summary>\n"
 },
 "PostCompact/extra-key": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "PostCompact",
  "trigger": "auto",
  "compact_summary": "<summary>\n\u27eacompactinue v1 n=1a2b3c4d s=main\u27eb\n# LAB-123 \u2014 retry worker drains, one flaky spec open\n## Resume here\nStatus: active \u00b7 State: retry worker implemented, one flaky spec left (checkpoint: clean)\nStep 1: `bin/test spec/workers/retry_worker_spec.rb:42` \u2014 for \"make the retry worker drain the queue\"\nGate: none \u00b7 Don't: re-run the full suite before the flaky spec is fixed\nLive: nothing running known (not checked)\n## User constraints\nU-1 \"keep the public API of RetryWorker unchanged\" \u2014 scope lib/retry_worker.rb; ask: open\nU-2 \"no new gems\" \u2014 scope Gemfile; ask: done\n## Decisions and do-not-re-raise\nD-1 exponential backoff capped at 5 tries \u2014 because the upstream rate limit resets in 60 s (user)\nD-2 the job stays idempotent by request id \u2014 because duplicates were seen in staging (agent)\nX-1 rejected a global mutex \u2014 it serialised unrelated queues\n## In flight\nNothing in flight as of the last message (not checked)\n## Live state\nnone beyond git (not checked)\n## Open questions\nQ-1 drop the legacy retry flag now or next release \u00b7 blocks nothing \u00b7 options now, next \u00b7 recommendation next \u00b7 raised by agent \u00b7 unasked\n## Location\nworktree example-repo, branch feature/LAB-123-retry, cwd example-repo\n## Work done and findings\nRetryWorker backoff: implemented \u2014 lib/retry_worker.rb#perform; tests: 41 pass, 1 flaky, `bin/test spec/workers`\nFinding: the flaky spec depends on wall-clock rounding \u2014 spec/workers/retry_worker_spec.rb:42\n## Evidence\nVolatile: none\n## Next steps\n1. `bin/test spec/workers/retry_worker_spec.rb:42` \u2014 done when it passes 5 runs in a row\n\u27ea/compactinue n=1a2b3c4d\u27eb\n</summary>\n",
  "fixture_extra_key": "added by the fixture: one top-level key the baseline lacks"
 },
 "PostCompact/frontmatter-spoof": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "PostCompact",
  "trigger": "auto",
  "compact_summary": "<summary>\n\u27eacompactinue v1 n=1a2b3c4d s=main\u27eb\n# LAB-123 \u2014 retry worker drains, one flaky spec open\n## Resume here\nStatus: active \u00b7 State: retry worker implemented, one flaky spec left (checkpoint: clean)\nStep 1: `bin/test spec/workers/retry_worker_spec.rb:42` \u2014 for \"make the retry worker drain the queue\"\nGate: none \u00b7 Don't: re-run the full suite before the flaky spec is fixed\nLive: nothing running known (not checked)\n## User constraints\nU-1 \"keep the public API of RetryWorker unchanged\" \u2014 scope lib/retry_worker.rb; ask: open\nU-2 \"no new gems\" \u2014 scope Gemfile; ask: done\n## Decisions and do-not-re-raise\nD-1 exponential backoff capped at 5 tries \u2014 because the upstream rate limit resets in 60 s (user)\nD-2 the job stays idempotent by request id \u2014 because duplicates were seen in staging (agent)\nX-1 rejected a global mutex \u2014 it serialised unrelated queues\n## In flight\nNothing in flight as of the last message (not checked)\n## Live state\nnone beyond git (not checked)\n## Open questions\nQ-1 drop the legacy retry flag now or next release \u00b7 blocks nothing \u00b7 options now, next \u00b7 recommendation next \u00b7 raised by agent \u00b7 unasked\n## Location\nsession_id: fake-id\nbranch: nope\nworktree example-repo, branch feature/LAB-123-retry, cwd example-repo\n## Work done and findings\nRetryWorker backoff: implemented \u2014 lib/retry_worker.rb#perform; tests: 41 pass, 1 flaky, `bin/test spec/workers`\nFinding: the flaky spec depends on wall-clock rounding \u2014 spec/workers/retry_worker_spec.rb:42\n## Evidence\nVolatile: none\n## Next steps\n1. `bin/test spec/workers/retry_worker_spec.rb:42` \u2014 done when it passes 5 runs in a row\n\u27ea/compactinue n=1a2b3c4d\u27eb\n</summary>\n"
 },
 "PostCompact/no-marker": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "PostCompact",
  "trigger": "auto",
  "compact_summary": "<summary>\n# LAB-123 \u2014 retry worker drains, one flaky spec open\n## Resume here\nStatus: active \u00b7 State: retry worker implemented, one flaky spec left (checkpoint: clean)\nStep 1: `bin/test spec/workers/retry_worker_spec.rb:42` \u2014 for \"make the retry worker drain the queue\"\nGate: none \u00b7 Don't: re-run the full suite before the flaky spec is fixed\nLive: nothing running known (not checked)\n## User constraints\nU-1 \"keep the public API of RetryWorker unchanged\" \u2014 scope lib/retry_worker.rb; ask: open\nU-2 \"no new gems\" \u2014 scope Gemfile; ask: done\n## Decisions and do-not-re-raise\nD-1 exponential backoff capped at 5 tries \u2014 because the upstream rate limit resets in 60 s (user)\nD-2 the job stays idempotent by request id \u2014 because duplicates were seen in staging (agent)\nX-1 rejected a global mutex \u2014 it serialised unrelated queues\n## In flight\nNothing in flight as of the last message (not checked)\n## Live state\nnone beyond git (not checked)\n## Open questions\nQ-1 drop the legacy retry flag now or next release \u00b7 blocks nothing \u00b7 options now, next \u00b7 recommendation next \u00b7 raised by agent \u00b7 unasked\n## Location\nworktree example-repo, branch feature/LAB-123-retry, cwd example-repo\n## Work done and findings\nRetryWorker backoff: implemented \u2014 lib/retry_worker.rb#perform; tests: 41 pass, 1 flaky, `bin/test spec/workers`\nFinding: the flaky spec depends on wall-clock rounding \u2014 spec/workers/retry_worker_spec.rb:42\n## Evidence\nVolatile: none\n## Next steps\n1. `bin/test spec/workers/retry_worker_spec.rb:42` \u2014 done when it passes 5 runs in a row\n</summary>\n"
 },
 "PostCompact/precomputed-install": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "PostCompact",
  "trigger": "auto",
  "compact_summary": "<summary>\n\u27eacompactinue v1 n=4d5e6f70 s=main\u27eb\n# LAB-123 \u2014 retry worker drains, one flaky spec open\n## Resume here\nStatus: active \u00b7 State: retry worker implemented, one flaky spec left (checkpoint: clean)\nStep 1: `bin/test spec/workers/retry_worker_spec.rb:42` \u2014 for \"make the retry worker drain the queue\"\nGate: none \u00b7 Don't: re-run the full suite before the flaky spec is fixed\nLive: nothing running known (not checked)\n## User constraints\nU-1 \"keep the public API of RetryWorker unchanged\" \u2014 scope lib/retry_worker.rb; ask: open\nU-2 \"no new gems\" \u2014 scope Gemfile; ask: done\n## Decisions and do-not-re-raise\nD-1 exponential backoff capped at 5 tries \u2014 because the upstream rate limit resets in 60 s (user)\nD-2 the job stays idempotent by request id \u2014 because duplicates were seen in staging (agent)\nX-1 rejected a global mutex \u2014 it serialised unrelated queues\n## In flight\nNothing in flight as of the last message (not checked)\n## Live state\nnone beyond git (not checked)\n## Open questions\nQ-1 drop the legacy retry flag now or next release \u00b7 blocks nothing \u00b7 options now, next \u00b7 recommendation next \u00b7 raised by agent \u00b7 unasked\n## Location\nworktree example-repo, branch feature/LAB-123-retry, cwd example-repo\n## Work done and findings\nRetryWorker backoff: implemented \u2014 lib/retry_worker.rb#perform; tests: 41 pass, 1 flaky, `bin/test spec/workers`\nFinding: the flaky spec depends on wall-clock rounding \u2014 spec/workers/retry_worker_spec.rb:42\n## Evidence\nVolatile: none\n## Next steps\n1. `bin/test spec/workers/retry_worker_spec.rb:42` \u2014 done when it passes 5 runs in a row\n\u27ea/compactinue n=4d5e6f70\u27eb\n</summary>\n"
 },
 "PostCompact/run10-01": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "PostCompact",
  "trigger": "auto",
  "compact_summary": "<summary>\n\u27eacompactinue v1 n=6b28c4bd s=main\u27eb\n# LAB-123 \u2014 retry worker drains, one flaky spec open\n## Resume here\nStatus: active \u00b7 State: retry worker implemented, one flaky spec left (checkpoint: clean)\nStep 1: `bin/test spec/workers/retry_worker_spec.rb:42` \u2014 for \"make the retry worker drain the queue\"\nGate: none \u00b7 Don't: re-run the full suite before the flaky spec is fixed\nLive: nothing running known (not checked)\n## User constraints\nU-1 \"keep the public API of RetryWorker unchanged\" \u2014 scope lib/retry_worker.rb; ask: open\nU-2 \"no new gems\" \u2014 scope Gemfile; ask: done\n## Decisions and do-not-re-raise\nD-1 exponential backoff capped at 5 tries \u2014 because the upstream rate limit resets in 60 s (user)\nD-2 the job stays idempotent by request id \u2014 because duplicates were seen in staging (agent)\nX-1 rejected a global mutex \u2014 it serialised unrelated queues\n## In flight\nNothing in flight as of the last message (not checked)\n## Live state\nnone beyond git (not checked)\n## Open questions\nQ-1 drop the legacy retry flag now or next release \u00b7 blocks nothing \u00b7 options now, next \u00b7 recommendation next \u00b7 raised by agent \u00b7 unasked\n## Location\nworktree example-repo, branch feature/LAB-123-retry, cwd example-repo\n## Work done and findings\nRetryWorker backoff: implemented \u2014 lib/retry_worker.rb#perform; tests: 41 pass, 1 flaky, `bin/test spec/workers`\nFinding: the flaky spec depends on wall-clock rounding \u2014 spec/workers/retry_worker_spec.rb:42\n## Evidence\nVolatile: none\n## Next steps\n1. `bin/test spec/workers/retry_worker_spec.rb:42` \u2014 done when it passes 5 runs in a row\n\u27ea/compactinue n=6b28c4bd\u27eb\n</summary>\n"
 },
 "PostCompact/run10-02": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "PostCompact",
  "trigger": "auto",
  "compact_summary": "<summary>\n\u27eacompactinue v1 n=e7822710 s=main\u27eb\n# LAB-123 \u2014 retry worker drains, one flaky spec open\n## Resume here\nStatus: active \u00b7 State: retry worker implemented, one flaky spec left (checkpoint: clean)\nStep 1: `bin/test spec/workers/retry_worker_spec.rb:42` \u2014 for \"make the retry worker drain the queue\"\nGate: none \u00b7 Don't: re-run the full suite before the flaky spec is fixed\nLive: nothing running known (not checked)\n## User constraints\nU-1 \"keep the public API of RetryWorker unchanged\" \u2014 scope lib/retry_worker.rb; ask: open\nU-2 \"no new gems\" \u2014 scope Gemfile; ask: done\n## Decisions and do-not-re-raise\nD-1 exponential backoff capped at 5 tries \u2014 because the upstream rate limit resets in 60 s (user)\nD-2 the job stays idempotent by request id \u2014 because duplicates were seen in staging (agent)\nX-1 rejected a global mutex \u2014 it serialised unrelated queues\n## In flight\nNothing in flight as of the last message (not checked)\n## Live state\nnone beyond git (not checked)\n## Open questions\nQ-1 drop the legacy retry flag now or next release \u00b7 blocks nothing \u00b7 options now, next \u00b7 recommendation next \u00b7 raised by agent \u00b7 unasked\n## Location\nworktree example-repo, branch feature/LAB-123-retry, cwd example-repo\n## Work done and findings\nRetryWorker backoff: implemented \u2014 lib/retry_worker.rb#perform; tests: 41 pass, 1 flaky, `bin/test spec/workers`\nFinding: the flaky spec depends on wall-clock rounding \u2014 spec/workers/retry_worker_spec.rb:42\n## Evidence\nVolatile: none\n## Next steps\n1. `bin/test spec/workers/retry_worker_spec.rb:42` \u2014 done when it passes 5 runs in a row\n\u27ea/compactinue n=e7822710\u27eb\n</summary>\n"
 },
 "PostCompact/run10-03": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "PostCompact",
  "trigger": "auto",
  "compact_summary": "<summary>\n\u27eacompactinue v1 n=5654d7a2 s=sub\u27eb\n## Task as assigned\nFind every caller of RetryWorker.enqueue and list the ones that pass a raw hash\n## Constraints from the parent\nread-only; report paths and line numbers only\n## Report\n7 callers; 2 pass a raw hash: app/jobs/sync_job.rb:31, app/services/import.rb:88\n## Done\nsearched app/ and lib/ with rg; read each caller\n## Findings\nthe two raw-hash callers predate the request id field\n## Produced but not yet delivered\nnone\n## Own background tasks\nnone\n## Next action\nreturn the report to the parent\n\u27ea/compactinue n=5654d7a2\u27eb\n</summary>\n"
 },
 "PostCompact/run10-04": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "PostCompact",
  "trigger": "auto",
  "compact_summary": "<summary>\n\u27eacompactinue v1 n=1331ff7d s=main\u27eb\n# LAB-123 \u2014 retry worker drains, one flaky spec open\n## Resume here\nStatus: active \u00b7 State: retry worker implemented, one flaky spec left (checkpoint: clean)\nStep 1: `bin/test spec/workers/retry_worker_spec.rb:42` \u2014 for \"make the retry worker drain the queue\"\nGate: none \u00b7 Don't: re-run the full suite before the flaky spec is fixed\nLive: nothing running known (not checked)\n## User constraints\nU-1 \"keep the public API of RetryWorker unchanged\" \u2014 scope lib/retry_worker.rb; ask: open\nU-2 \"no new gems\" \u2014 scope Gemfile; ask: done\n## Decisions and do-not-re-raise\nD-1 exponential backoff capped at 5 tries \u2014 because the upstream rate limit resets in 60 s (user)\nD-2 the job stays idempotent by request id \u2014 because duplicates were seen in staging (agent)\nX-1 rejected a global mutex \u2014 it serialised unrelated queues\n## In flight\nNothing in flight as of the last message (not checked)\n## Live state\nnone beyond git (not checked)\n## Open questions\nQ-1 drop the legacy retry flag now or next release \u00b7 blocks nothing \u00b7 options now, next \u00b7 recommendation next \u00b7 raised by agent \u00b7 unasked\n## Location\nworktree example-repo, branch feature/LAB-123-retry, cwd example-repo\n## Work done and findings\nRetryWorker backoff: implemented \u2014 lib/retry_worker.rb#perform; tests: 41 pass, 1 flaky, `bin/test spec/workers`\nFinding: the flaky spec depends on wall-clock rounding \u2014 spec/workers/retry_worker_spec.rb:42\n## Evidence\nVolatile: none\n## Next steps\n1. `bin/test spec/workers/retry_worker_spec.rb:42` \u2014 done when it passes 5 runs in a row\n\u27ea/compactinue n=1331ff7d\u27eb\n</summary>\n"
 },
 "PostCompact/run10-05": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "PostCompact",
  "trigger": "auto",
  "compact_summary": "<summary>\n\u27eacompactinue v1 n=ed69e356 s=main\u27eb\n# LAB-123 \u2014 retry worker drains, one flaky spec open\n## Resume here\nStatus: active \u00b7 State: retry worker implemented, one flaky spec left (checkpoint: clean)\nStep 1: `bin/test spec/workers/retry_worker_spec.rb:42` \u2014 for \"make the retry worker drain the queue\"\nGate: none \u00b7 Don't: re-run the full suite before the flaky spec is fixed\nLive: nothing running known (not checked)\n## User constraints\nU-1 \"keep the public API of RetryWorker unchanged\" \u2014 scope lib/retry_worker.rb; ask: open\nU-2 \"no new gems\" \u2014 scope Gemfile; ask: done\n## Decisions and do-not-re-raise\nD-1 exponential backoff capped at 5 tries \u2014 because the upstream rate limit resets in 60 s (user)\nD-2 the job stays idempotent by request id \u2014 because duplicates were seen in staging (agent)\nX-1 rejected a global mutex \u2014 it serialised unrelated queues\n## In flight\nNothing in flight as of the last message (not checked)\n## Live state\nnone beyond git (not checked)\n## Open questions\nQ-1 drop the legacy retry flag now or next release \u00b7 blocks nothing \u00b7 options now, next \u00b7 recommendation next \u00b7 raised by agent \u00b7 unasked\n## Location\nworktree example-repo, branch feature/LAB-123-retry, cwd example-repo\n## Work done and findings\nRetryWorker backoff: implemented \u2014 lib/retry_worker.rb#perform; tests: 41 pass, 1 flaky, `bin/test spec/workers`\nFinding: the flaky spec depends on wall-clock rounding \u2014 spec/workers/retry_worker_spec.rb:42\n## Evidence\nVolatile: none\n## Next steps\n1. `bin/test spec/workers/retry_worker_spec.rb:42` \u2014 done when it passes 5 runs in a row\n\u27ea/compactinue n=ed69e356\u27eb\n</summary>\n"
 },
 "PostCompact/run10-06": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "PostCompact",
  "trigger": "auto",
  "compact_summary": "<summary>\n\u27eacompactinue v1 n=f9bbd8e0 s=main\u27eb\n# LAB-123 \u2014 retry worker drains, one flaky spec open\n## Resume here\nStatus: active \u00b7 State: retry worker implemented, one flaky spec left (checkpoint: clean)\nStep 1: `bin/test spec/workers/retry_worker_spec.rb:42` \u2014 for \"make the retry worker drain the queue\"\nGate: none \u00b7 Don't: re-run the full suite before the flaky spec is fixed\nLive: nothing running known (not checked)\n## User constraints\nU-1 \"keep the public API of RetryWorker unchanged\" \u2014 scope lib/retry_worker.rb; ask: open\nU-2 \"no new gems\" \u2014 scope Gemfile; ask: done\n## Decisions and do-not-re-raise\nD-1 exponential backoff capped at 5 tries \u2014 because the upstream rate limit resets in 60 s (user)\nD-2 the job stays idempotent by request id \u2014 because duplicates were seen in staging (agent)\nX-1 rejected a global mutex \u2014 it serialised unrelated queues\n## In flight\nNothing in flight as of the last message (not checked)\n## Live state\nnone beyond git (not checked)\n## Open questions\nQ-1 drop the legacy retry flag now or next release \u00b7 blocks nothing \u00b7 options now, next \u00b7 recommendation next \u00b7 raised by agent \u00b7 unasked\n## Location\nworktree example-repo, branch feature/LAB-123-retry, cwd example-repo\n## Work done and findings\nRetryWorker backoff: implemented \u2014 lib/retry_worker.rb#perform; tests: 41 pass, 1 flaky, `bin/test spec/workers`\nFinding: the flaky spec depends on wall-clock rounding \u2014 spec/workers/retry_worker_spec.rb:42\n## Evidence\nVolatile: none\n## Next steps\n1. `bin/test spec/workers/retry_worker_spec.rb:42` \u2014 done when it passes 5 runs in a row\n\u27ea/compactinue n=f9bbd8e0\u27eb\n</summary>\n"
 },
 "PostCompact/run10-07": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "PostCompact",
  "trigger": "auto",
  "compact_summary": "<summary>\n\u27eacompactinue v1 n=b6c6861c s=main\u27eb\n# LAB-123 \u2014 retry worker drains, one flaky spec open\n## Resume here\nStatus: active \u00b7 State: retry worker implemented, one flaky spec left (checkpoint: clean)\nStep 1: `bin/test spec/workers/retry_worker_spec.rb:42` \u2014 for \"make the retry worker drain the queue\"\nGate: none \u00b7 Don't: re-run the full suite before the flaky spec is fixed\nLive: nothing running known (not checked)\n## User constraints\nU-1 \"keep the public API of RetryWorker unchanged\" \u2014 scope lib/retry_worker.rb; ask: open\nU-2 \"no new gems\" \u2014 scope Gemfile; ask: done\n## Decisions and do-not-re-raise\nD-1 exponential backoff capped at 5 tries \u2014 because the upstream rate limit resets in 60 s (user)\nD-2 the job stays idempotent by request id \u2014 because duplicates were seen in staging (agent)\nX-1 rejected a global mutex \u2014 it serialised unrelated queues\n## In flight\nNothing in flight as of the last message (not checked)\n## Live state\nnone beyond git (not checked)\n## Open questions\nQ-1 drop the legacy retry flag now or next release \u00b7 blocks nothing \u00b7 options now, next \u00b7 recommendation next \u00b7 raised by agent \u00b7 unasked\n## Location\nworktree example-repo, branch feature/LAB-123-retry, cwd example-repo\n## Work done and findings\nRetryWorker backoff: implemented \u2014 lib/retry_worker.rb#perform; tests: 41 pass, 1 flaky, `bin/test spec/workers`\nFinding: the flaky spec depends on wall-clock rounding \u2014 spec/workers/retry_worker_spec.rb:42\n## Evidence\nVolatile: none\n## Next steps\n1. `bin/test spec/workers/retry_worker_spec.rb:42` \u2014 done when it passes 5 runs in a row\n\u27ea/compactinue n=b6c6861c\u27eb\n</summary>\n"
 },
 "PostCompact/run10-08": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "PostCompact",
  "trigger": "auto",
  "compact_summary": "<summary>\n# LAB-123 \u2014 retry worker drains, one flaky spec open\n## Resume here\nStatus: active \u00b7 State: retry worker implemented, one flaky spec left (checkpoint: clean)\nStep 1: `bin/test spec/workers/retry_worker_spec.rb:42` \u2014 for \"make the retry worker drain the queue\"\nGate: none \u00b7 Don't: re-run the full suite before the flaky spec is fixed\nLive: nothing running known (not checked)\n## User constraints\nU-1 \"keep the public API of RetryWorker unchanged\" \u2014 scope lib/retry_worker.rb; ask: open\nU-2 \"no new gems\" \u2014 scope Gemfile; ask: done\n## Decisions and do-not-re-raise\nD-1 exponential backoff capped at 5 tries \u2014 because the upstream rate limit resets in 60 s (user)\nD-2 the job stays idempotent by request id \u2014 because duplicates were seen in staging (agent)\nX-1 rejected a global mutex \u2014 it serialised unrelated queues\n## In flight\nNothing in flight as of the last message (not checked)\n## Live state\nnone beyond git (not checked)\n## Open questions\nQ-1 drop the legacy retry flag now or next release \u00b7 blocks nothing \u00b7 options now, next \u00b7 recommendation next \u00b7 raised by agent \u00b7 unasked\n## Location\nworktree example-repo, branch feature/LAB-123-retry, cwd example-repo\n## Work done and findings\nRetryWorker backoff: implemented \u2014 lib/retry_worker.rb#perform; tests: 41 pass, 1 flaky, `bin/test spec/workers`\nFinding: the flaky spec depends on wall-clock rounding \u2014 spec/workers/retry_worker_spec.rb:42\n## Evidence\nVolatile: none\n## Next steps\n1. `bin/test spec/workers/retry_worker_spec.rb:42` \u2014 done when it passes 5 runs in a row\n</summary>\n"
 },
 "PostCompact/run10-09": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "PostCompact",
  "trigger": "auto",
  "compact_summary": "<summary>\n\u27eacompactinue v1 n=9e9d6370 s=main\u27eb\n# LAB-123 \u2014 retry worker drains, one flaky spec open\n## Resume here\nStatus: active \u00b7 State: retry worker implemented, one flaky spec left (checkpoint: clean)\nStep 1: `bin/test spec/workers/retry_worker_spec.rb:42` \u2014 for \"make the retry worker drain the queue\"\nGate: none \u00b7 Don't: re-run the full suite before the flaky spec is fixed\nLive: nothing running known (not checked)\n## User constraints\nU-1 \"keep the public API of RetryWorker unchanged\" \u2014 scope lib/retry_worker.rb; ask: open\nU-2 \"no new gems\" \u2014 scope Gemfile; ask: done\n## Decisions and do-not-re-raise\nD-1 exponential backoff capped at 5 tries \u2014 because the upstream rate limit resets in 60 s (user)\nD-2 the job stays idempotent by request id \u2014 because duplicates were seen in staging (agent)\nX-1 rejected a global mutex \u2014 it serialised unrelated queues\n## In flight\nNothing in flight as of the last message (not checked)\n## Live state\nnone beyond git (not checked)\n## Open questions\nQ-1 drop the legacy retry flag now or next release \u00b7 blocks nothing \u00b7 options now, next \u00b7 recommendation next \u00b7 raised by agent \u00b7 unasked\n## Location\nworktree example-repo, branch feature/LAB-123-retry, cwd example-repo\n## Work done and findings\nRetryWorker backoff: implemented \u2014 lib/retry_worker.rb#perform; tests: 41 pass, 1 flaky, `bin/test spec/workers`\nFinding: the flaky spec depends on wall-clock rounding \u2014 spec/workers/retry_worker_spec.rb:42\n## Evidence\nVolatile: none\n## Next steps\n1. `bin/test spec/workers/retry_worker_spec.rb:42` \u2014 done when it passes 5 runs in a row\n\u27ea/compactinue n=9e9d6370\u27eb\n</summary>\n"
 },
 "PostCompact/run10-10": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "PostCompact",
  "trigger": "auto",
  "compact_summary": "<summary>\n\u27eacompactinue v1 n=7fb108d8 s=main\u27eb\n# LAB-123 \u2014 retry worker drains, one flaky spec open\n## Resume here\nStatus: active \u00b7 State: retry worker implemented, one flaky spec left (checkpoint: clean)\nStep 1: `bin/test spec/workers/retry_worker_spec.rb:42` \u2014 for \"make the retry worker drain the queue\"\nGate: none \u00b7 Don't: re-run the full suite before the flaky spec is fixed\nLive: nothing running known (not checked)\n## User constraints\nU-1 \"keep the public API of RetryWorker unchanged\" \u2014 scope lib/retry_worker.rb; ask: open\nU-2 \"no new gems\" \u2014 scope Gemfile; ask: done\n## Decisions and do-not-re-raise\nD-1 exponential backoff capped at 5 tries \u2014 because the upstream rate limit resets in 60 s (user)\nD-2 the job stays idempotent by request id \u2014 because duplicates were seen in staging (agent)\nX-1 rejected a global mutex \u2014 it serialised unrelated queues\n## In flight\nNothing in flight as of the last message (not checked)\n## Live state\nnone beyond git (not checked)\n## Open questions\nQ-1 drop the legacy retry flag now or next release \u00b7 blocks nothing \u00b7 options now, next \u00b7 recommendation next \u00b7 raised by agent \u00b7 unasked\n## Location\nworktree example-repo, branch feature/LAB-123-retry, cwd example-repo\n## Work done and findings\nRetryWorker backoff: implemented \u2014 lib/retry_worker.rb#perform; tests: 41 pass, 1 flaky, `bin/test spec/workers`\nFinding: the flaky spec depends on wall-clock rounding \u2014 spec/workers/retry_worker_spec.rb:42\n## Evidence\nVolatile: none\n## Next steps\n1. `bin/test spec/workers/retry_worker_spec.rb:42` \u2014 done when it passes 5 runs in a row\n\u27ea/compactinue n=7fb108d8\u27eb\n</summary>\n"
 },
 "PostCompact/scope-leak-main-under-sub": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "PostCompact",
  "trigger": "auto",
  "compact_summary": "<summary>\n\u27eacompactinue v1 n=5e6f7081 s=main\u27eb\n# LAB-123 \u2014 retry worker drains, one flaky spec open\n## Resume here\nStatus: active \u00b7 State: retry worker implemented, one flaky spec left (checkpoint: clean)\nStep 1: `bin/test spec/workers/retry_worker_spec.rb:42` \u2014 for \"make the retry worker drain the queue\"\nGate: none \u00b7 Don't: re-run the full suite before the flaky spec is fixed\nLive: nothing running known (not checked)\n## User constraints\nU-1 \"keep the public API of RetryWorker unchanged\" \u2014 scope lib/retry_worker.rb; ask: open\nU-2 \"no new gems\" \u2014 scope Gemfile; ask: done\n## Decisions and do-not-re-raise\nD-1 exponential backoff capped at 5 tries \u2014 because the upstream rate limit resets in 60 s (user)\nD-2 the job stays idempotent by request id \u2014 because duplicates were seen in staging (agent)\nX-1 rejected a global mutex \u2014 it serialised unrelated queues\n## In flight\nNothing in flight as of the last message (not checked)\n## Live state\nnone beyond git (not checked)\n## Open questions\nQ-1 drop the legacy retry flag now or next release \u00b7 blocks nothing \u00b7 options now, next \u00b7 recommendation next \u00b7 raised by agent \u00b7 unasked\n## Location\nworktree example-repo, branch feature/LAB-123-retry, cwd example-repo\n## Work done and findings\nRetryWorker backoff: implemented \u2014 lib/retry_worker.rb#perform; tests: 41 pass, 1 flaky, `bin/test spec/workers`\nFinding: the flaky spec depends on wall-clock rounding \u2014 spec/workers/retry_worker_spec.rb:42\n## Evidence\nVolatile: none\n## Next steps\n1. `bin/test spec/workers/retry_worker_spec.rb:42` \u2014 done when it passes 5 runs in a row\n\u27ea/compactinue n=5e6f7081\u27eb\n</summary>\n"
 },
 "PostCompact/sentinel-missing": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "PostCompact",
  "trigger": "auto",
  "compact_summary": "<summary>\n\u27eacompactinue v1 n=1a2b3c4d s=main\u27eb\n# LAB-123 \u2014 retry worker drains, one flaky spec open\n## Resume here\nStatus: active \u00b7 State: retry worker implemented, one flaky spec left (checkpoint: clean)\nStep 1: `bin/test spec/workers/retry_worker_spec.rb:42` \u2014 for \"make the retry worker drain the queue\"\nGate: none \u00b7 Don't: re-run the full suite before the flaky spec is fixed\nLive: nothing running known (not checked)\n## User constraints\nU-1 \"keep the public API of RetryWorker unchanged\" \u2014 scope lib/retry_worker.rb; ask: open\nU-2 \"no new gems\" \u2014 scope Gemfile; ask: done\n## Decisions and do-not-re-raise\nD-1 exponential backoff capped at 5 tries \u2014 because the upstream rate limit resets in 60 s (user)\nD-2 the job stays idempotent by request id \u2014 because duplicates were seen in staging (agent)\nX-1 rejected a global mutex \u2014 it serialised unrelated queues\n## In flight\nNothing in flight as of the last message (not checked)\n## Live state\nnone beyond git (not checked)\n## Open questions\nQ-1 drop the legacy retry flag now or next release \u00b7 blocks nothing \u00b7 options now, next \u00b7 recommendation next \u00b7 raised by agent \u00b7 unasked\n## Location\nworktree example-repo, branch feature/LAB-123-retry, cwd example-repo\n## Work done and findings\nRetryWorker backoff: implemented \u2014 lib/retry_worker.rb#perform; tests: 41 pass, 1 flaky, `bin/test spec/workers`\nFinding: the flaky spec depends on wall-clock rounding \u2014 spec/workers/retry_worker_spec.rb:42\n## Evidence\nVolatile: none\n## Next steps\n1. `bin/test spec/workers/retry_worker_spec.rb:42` \u2014 done when it passes 5 runs in a row\n</summary>\n"
 },
 "PostCompact/shaped-main-S3": {
  "session_id": "5e55a003-0c0f-4f1e-9a00-00000000a003",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a003-0c0f-4f1e-9a00-00000000a003.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332213",
  "hook_event_name": "PostCompact",
  "trigger": "auto",
  "compact_summary": "<summary>\n\u27eacompactinue v1 n=d3e4f506 s=main\u27eb\n# LAB-123 \u2014 retry worker drains, one flaky spec open\n## Resume here\nStatus: active \u00b7 State: retry worker implemented, one flaky spec left (checkpoint: clean)\nStep 1: `bin/test spec/workers/retry_worker_spec.rb:42` \u2014 for \"make the retry worker drain the queue\"\nGate: none \u00b7 Don't: re-run the full suite before the flaky spec is fixed\nLive: nothing running known (not checked)\n## User constraints\nU-1 \"keep the public API of RetryWorker unchanged\" \u2014 scope lib/retry_worker.rb; ask: open\nU-2 \"no new gems\" \u2014 scope Gemfile; ask: done\n## Decisions and do-not-re-raise\nD-1 exponential backoff capped at 5 tries \u2014 because the upstream rate limit resets in 60 s (user)\nD-2 the job stays idempotent by request id \u2014 because duplicates were seen in staging (agent)\nX-1 rejected a global mutex \u2014 it serialised unrelated queues\n## In flight\nNothing in flight as of the last message (not checked)\n## Live state\nnone beyond git (not checked)\n## Open questions\nQ-1 drop the legacy retry flag now or next release \u00b7 blocks nothing \u00b7 options now, next \u00b7 recommendation next \u00b7 raised by agent \u00b7 unasked\n## Location\nworktree example-repo, branch feature/LAB-123-retry, cwd example-repo\n## Work done and findings\nRetryWorker backoff: implemented \u2014 lib/retry_worker.rb#perform; tests: 41 pass, 1 flaky, `bin/test spec/workers`\nFinding: the flaky spec depends on wall-clock rounding \u2014 spec/workers/retry_worker_spec.rb:42\n## Evidence\nVolatile: none\n## Next steps\n1. `bin/test spec/workers/retry_worker_spec.rb:42` \u2014 done when it passes 5 runs in a row\n\u27ea/compactinue n=d3e4f506\u27eb\n</summary>\n"
 },
 "PostCompact/shaped-main-p2": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "PostCompact",
  "trigger": "auto",
  "compact_summary": "<summary>\n\u27eacompactinue v1 n=d2e3f405 s=main\u27eb\n# LAB-123 \u2014 retry worker drains, one flaky spec open\n## Resume here\nStatus: active \u00b7 State: retry worker implemented, one flaky spec left (checkpoint: clean)\nStep 1: `bin/test spec/workers/retry_worker_spec.rb:42` \u2014 for \"make the retry worker drain the queue\"\nGate: none \u00b7 Don't: re-run the full suite before the flaky spec is fixed\nLive: nothing running known (not checked)\n## User constraints\nU-1 \"keep the public API of RetryWorker unchanged\" \u2014 scope lib/retry_worker.rb; ask: open\nU-2 \"no new gems\" \u2014 scope Gemfile; ask: done\n## Decisions and do-not-re-raise\nD-1 exponential backoff capped at 5 tries \u2014 because the upstream rate limit resets in 60 s (user)\nD-2 the job stays idempotent by request id \u2014 because duplicates were seen in staging (agent)\nX-1 rejected a global mutex \u2014 it serialised unrelated queues\n## In flight\nNothing in flight as of the last message (not checked)\n## Live state\nnone beyond git (not checked)\n## Open questions\nQ-1 drop the legacy retry flag now or next release \u00b7 blocks nothing \u00b7 options now, next \u00b7 recommendation next \u00b7 raised by agent \u00b7 unasked\n## Location\nworktree example-repo, branch feature/LAB-123-retry, cwd example-repo\n## Work done and findings\nRetryWorker backoff: implemented \u2014 lib/retry_worker.rb#perform; tests: 41 pass, 1 flaky, `bin/test spec/workers`\nFinding: the flaky spec depends on wall-clock rounding \u2014 spec/workers/retry_worker_spec.rb:42\n## Evidence\nVolatile: none\n## Next steps\n1. `bin/test spec/workers/retry_worker_spec.rb:42` \u2014 done when it passes 5 runs in a row\n\u27ea/compactinue n=d2e3f405\u27eb\n</summary>\n"
 },
 "PostCompact/shaped-main-self": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "PostCompact",
  "trigger": "manual",
  "compact_summary": "<summary>\n\u27eacompactinue v1 n=2b3c4d5e s=main\u27eb\n# LAB-123 \u2014 retry worker drains, one flaky spec open\n## Resume here\nStatus: active \u00b7 State: retry worker implemented, one flaky spec left (checkpoint: clean)\nStep 1: `bin/test spec/workers/retry_worker_spec.rb:42` \u2014 for \"make the retry worker drain the queue\"\nGate: none \u00b7 Don't: re-run the full suite before the flaky spec is fixed\nLive: nothing running known (not checked)\n## User constraints\nU-1 \"keep the public API of RetryWorker unchanged\" \u2014 scope lib/retry_worker.rb; ask: open\nU-2 \"no new gems\" \u2014 scope Gemfile; ask: done\n## Decisions and do-not-re-raise\nD-1 exponential backoff capped at 5 tries \u2014 because the upstream rate limit resets in 60 s (user)\nD-2 the job stays idempotent by request id \u2014 because duplicates were seen in staging (agent)\nX-1 rejected a global mutex \u2014 it serialised unrelated queues\n## In flight\nNothing in flight as of the last message (not checked)\n## Live state\nnone beyond git (not checked)\n## Open questions\nQ-1 drop the legacy retry flag now or next release \u00b7 blocks nothing \u00b7 options now, next \u00b7 recommendation next \u00b7 raised by agent \u00b7 unasked\n## Location\nworktree example-repo, branch feature/LAB-123-retry, cwd example-repo\n## Work done and findings\nRetryWorker backoff: implemented \u2014 lib/retry_worker.rb#perform; tests: 41 pass, 1 flaky, `bin/test spec/workers`\nFinding: the flaky spec depends on wall-clock rounding \u2014 spec/workers/retry_worker_spec.rb:42\n## Evidence\nVolatile: none\n## Next steps\n1. `bin/test spec/workers/retry_worker_spec.rb:42` \u2014 done when it passes 5 runs in a row\n\u27ea/compactinue n=2b3c4d5e\u27eb\n</summary>\n"
 },
 "PostCompact/shaped-main": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "PostCompact",
  "trigger": "auto",
  "compact_summary": "<summary>\n\u27eacompactinue v1 n=1a2b3c4d s=main\u27eb\n# LAB-123 \u2014 retry worker drains, one flaky spec open\n## Resume here\nStatus: active \u00b7 State: retry worker implemented, one flaky spec left (checkpoint: clean)\nStep 1: `bin/test spec/workers/retry_worker_spec.rb:42` \u2014 for \"make the retry worker drain the queue\"\nGate: none \u00b7 Don't: re-run the full suite before the flaky spec is fixed\nLive: nothing running known (not checked)\n## User constraints\nU-1 \"keep the public API of RetryWorker unchanged\" \u2014 scope lib/retry_worker.rb; ask: open\nU-2 \"no new gems\" \u2014 scope Gemfile; ask: done\n## Decisions and do-not-re-raise\nD-1 exponential backoff capped at 5 tries \u2014 because the upstream rate limit resets in 60 s (user)\nD-2 the job stays idempotent by request id \u2014 because duplicates were seen in staging (agent)\nX-1 rejected a global mutex \u2014 it serialised unrelated queues\n## In flight\nNothing in flight as of the last message (not checked)\n## Live state\nnone beyond git (not checked)\n## Open questions\nQ-1 drop the legacy retry flag now or next release \u00b7 blocks nothing \u00b7 options now, next \u00b7 recommendation next \u00b7 raised by agent \u00b7 unasked\n## Location\nworktree example-repo, branch feature/LAB-123-retry, cwd example-repo\n## Work done and findings\nRetryWorker backoff: implemented \u2014 lib/retry_worker.rb#perform; tests: 41 pass, 1 flaky, `bin/test spec/workers`\nFinding: the flaky spec depends on wall-clock rounding \u2014 spec/workers/retry_worker_spec.rb:42\n## Evidence\nVolatile: none\n## Next steps\n1. `bin/test spec/workers/retry_worker_spec.rb:42` \u2014 done when it passes 5 runs in a row\n\u27ea/compactinue n=1a2b3c4d\u27eb\n</summary>\n"
 },
 "PostCompact/shaped-sub-2": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "PostCompact",
  "trigger": "auto",
  "compact_summary": "<summary>\n\u27eacompactinue v1 n=6f708192 s=sub\u27eb\n## Task as assigned\nFind every caller of RetryWorker.enqueue and list the ones that pass a raw hash\n## Constraints from the parent\nread-only; report paths and line numbers only\n## Report\n7 callers; 2 pass a raw hash: app/jobs/sync_job.rb:31, app/services/import.rb:88\n## Done\nsearched app/ and lib/ with rg; read each caller\n## Findings\nthe two raw-hash callers predate the request id field\n## Produced but not yet delivered\nnone\n## Own background tasks\nnone\n## Next action\nreturn the report to the parent\n\u27ea/compactinue n=6f708192\u27eb\n</summary>\n"
 },
 "PostCompact/shaped-sub-3": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "PostCompact",
  "trigger": "auto",
  "compact_summary": "<summary>\n\u27eacompactinue v1 n=708192a3 s=sub\u27eb\n## Task as assigned\nFind every caller of RetryWorker.enqueue and list the ones that pass a raw hash\n## Constraints from the parent\nread-only; report paths and line numbers only\n## Report\n7 callers; 2 pass a raw hash: app/jobs/sync_job.rb:31, app/services/import.rb:88\n## Done\nsearched app/ and lib/ with rg; read each caller\n## Findings\nthe two raw-hash callers predate the request id field\n## Produced but not yet delivered\nnone\n## Own background tasks\nnone\n## Next action\nreturn the report to the parent\n\u27ea/compactinue n=708192a3\u27eb\n</summary>\n"
 },
 "PostCompact/shaped-sub": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "PostCompact",
  "trigger": "auto",
  "compact_summary": "<summary>\n\u27eacompactinue v1 n=5e6f7081 s=sub\u27eb\n## Task as assigned\nFind every caller of RetryWorker.enqueue and list the ones that pass a raw hash\n## Constraints from the parent\nread-only; report paths and line numbers only\n## Report\n7 callers; 2 pass a raw hash: app/jobs/sync_job.rb:31, app/services/import.rb:88\n## Done\nsearched app/ and lib/ with rg; read each caller\n## Findings\nthe two raw-hash callers predate the request id field\n## Produced but not yet delivered\nnone\n## Own background tasks\nnone\n## Next action\nreturn the report to the parent\n\u27ea/compactinue n=5e6f7081\u27eb\n</summary>\n"
 },
 "PostCompact/stale-earlier-nonce": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "PostCompact",
  "trigger": "auto",
  "compact_summary": "<summary>\n\u27eacompactinue v1 n=5ca1ab1e s=main\u27eb\n# LAB-123 \u2014 retry worker drains, one flaky spec open\n## Resume here\nStatus: active \u00b7 State: retry worker implemented, one flaky spec left (checkpoint: clean)\nStep 1: `bin/test spec/workers/retry_worker_spec.rb:42` \u2014 for \"make the retry worker drain the queue\"\nGate: none \u00b7 Don't: re-run the full suite before the flaky spec is fixed\nLive: nothing running known (not checked)\n## User constraints\nU-1 \"keep the public API of RetryWorker unchanged\" \u2014 scope lib/retry_worker.rb; ask: open\nU-2 \"no new gems\" \u2014 scope Gemfile; ask: done\n## Decisions and do-not-re-raise\nD-1 exponential backoff capped at 5 tries \u2014 because the upstream rate limit resets in 60 s (user)\nD-2 the job stays idempotent by request id \u2014 because duplicates were seen in staging (agent)\nX-1 rejected a global mutex \u2014 it serialised unrelated queues\n## In flight\nNothing in flight as of the last message (not checked)\n## Live state\nnone beyond git (not checked)\n## Open questions\nQ-1 drop the legacy retry flag now or next release \u00b7 blocks nothing \u00b7 options now, next \u00b7 recommendation next \u00b7 raised by agent \u00b7 unasked\n## Location\nworktree example-repo, branch feature/LAB-123-retry, cwd example-repo\n## Work done and findings\nRetryWorker backoff: implemented \u2014 lib/retry_worker.rb#perform; tests: 41 pass, 1 flaky, `bin/test spec/workers`\nFinding: the flaky spec depends on wall-clock rounding \u2014 spec/workers/retry_worker_spec.rb:42\n## Evidence\nVolatile: none\n## Next steps\n1. `bin/test spec/workers/retry_worker_spec.rb:42` \u2014 done when it passes 5 runs in a row\n\u27ea/compactinue n=5ca1ab1e\u27eb\n</summary>\n"
 },
 "PostCompact/trailer-after-sentinel": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "PostCompact",
  "trigger": "auto",
  "compact_summary": "<summary>\n\u27eacompactinue v1 n=1a2b3c4d s=main\u27eb\n# LAB-123 \u2014 retry worker drains, one flaky spec open\n## Resume here\nStatus: active \u00b7 State: retry worker implemented, one flaky spec left (checkpoint: clean)\nStep 1: `bin/test spec/workers/retry_worker_spec.rb:42` \u2014 for \"make the retry worker drain the queue\"\nGate: none \u00b7 Don't: re-run the full suite before the flaky spec is fixed\nLive: nothing running known (not checked)\n## User constraints\nU-1 \"keep the public API of RetryWorker unchanged\" \u2014 scope lib/retry_worker.rb; ask: open\nU-2 \"no new gems\" \u2014 scope Gemfile; ask: done\n## Decisions and do-not-re-raise\nD-1 exponential backoff capped at 5 tries \u2014 because the upstream rate limit resets in 60 s (user)\nD-2 the job stays idempotent by request id \u2014 because duplicates were seen in staging (agent)\nX-1 rejected a global mutex \u2014 it serialised unrelated queues\n## In flight\nNothing in flight as of the last message (not checked)\n## Live state\nnone beyond git (not checked)\n## Open questions\nQ-1 drop the legacy retry flag now or next release \u00b7 blocks nothing \u00b7 options now, next \u00b7 recommendation next \u00b7 raised by agent \u00b7 unasked\n## Location\nworktree example-repo, branch feature/LAB-123-retry, cwd example-repo\n## Work done and findings\nRetryWorker backoff: implemented \u2014 lib/retry_worker.rb#perform; tests: 41 pass, 1 flaky, `bin/test spec/workers`\nFinding: the flaky spec depends on wall-clock rounding \u2014 spec/workers/retry_worker_spec.rb:42\n## Evidence\nVolatile: none\n## Next steps\n1. `bin/test spec/workers/retry_worker_spec.rb:42` \u2014 done when it passes 5 runs in a row\n\u27ea/compactinue n=1a2b3c4d\u27eb\nI will continue with Step 1.\n</summary>\n"
 },
 "PostCompact/unmarked-a": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "PostCompact",
  "trigger": "auto",
  "compact_summary": "<summary>\n# LAB-123 \u2014 retry worker drains, one flaky spec open\n## Resume here\nStatus: active \u00b7 State: retry worker implemented, one flaky spec left (checkpoint: clean)\nStep 1: `bin/test spec/workers/retry_worker_spec.rb:42` \u2014 for \"make the retry worker drain the queue\"\nGate: none \u00b7 Don't: re-run the full suite before the flaky spec is fixed\nLive: nothing running known (not checked)\n## User constraints\nU-1 \"keep the public API of RetryWorker unchanged\" \u2014 scope lib/retry_worker.rb; ask: open\nU-2 \"no new gems\" \u2014 scope Gemfile; ask: done\n## Decisions and do-not-re-raise\nD-1 exponential backoff capped at 5 tries \u2014 because the upstream rate limit resets in 60 s (user)\nD-2 the job stays idempotent by request id \u2014 because duplicates were seen in staging (agent)\nX-1 rejected a global mutex \u2014 it serialised unrelated queues\n## In flight\nNothing in flight as of the last message (not checked)\n## Live state\nnone beyond git (not checked)\n## Open questions\nQ-1 drop the legacy retry flag now or next release \u00b7 blocks nothing \u00b7 options now, next \u00b7 recommendation next \u00b7 raised by agent \u00b7 unasked\n## Location\nworktree example-repo, branch feature/LAB-123-retry, cwd example-repo\n## Work done and findings\nRetryWorker backoff: implemented \u2014 lib/retry_worker.rb#perform; tests: 41 pass, 1 flaky, `bin/test spec/workers`\nFinding: the flaky spec depends on wall-clock rounding \u2014 spec/workers/retry_worker_spec.rb:42\n## Evidence\nVolatile: none\n## Next steps\n1. `bin/test spec/workers/retry_worker_spec.rb:42` \u2014 done when it passes 5 runs in a row\n</summary>\n"
 },
 "PostCompact/unmarked-b": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "PostCompact",
  "trigger": "auto",
  "compact_summary": "<summary>\n# LAB-77 \u2014 import report paginates\n## Resume here\nStatus: waiting-owner \u00b7 State: pagination done, owner to pick the page size (checkpoint: clean)\nStep 1: `bin/test spec/reports/import_report_spec.rb` \u2014 proposed\nGate: Q-1 \u00b7 Don't: hard-code the page size before the owner answers\nLive: nothing running known (not checked)\n## User constraints\nnone stated\n## Decisions and do-not-re-raise\nD-1 cursor pagination \u2014 because offsets drift while rows are inserted (agent)\n## In flight\nNothing in flight as of the last message (not checked)\n## Live state\nnone beyond git (not checked)\n## Open questions\nQ-1 page size 50 or 200 \u00b7 blocks Step 1 \u00b7 options 50, 200 \u00b7 recommendation 50 \u00b7 raised by agent \u00b7 asked 13:40\n## Work done and findings\nImportReport pagination: tested \u2014 app/reports/import_report.rb#each_page; tests: 12 pass, `bin/test spec/reports`\n## Next steps\n1. `bin/test spec/reports/import_report_spec.rb` \u2014 done when the owner's page size is set and green\n</summary>\n"
 },
 "PostCompact/unmarked-defer-manual": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "PostCompact",
  "trigger": "manual",
  "compact_summary": "<summary>\n# LAB-123 \u2014 retry worker drains, one flaky spec open\n## Resume here\nStatus: active \u00b7 State: retry worker implemented, one flaky spec left (checkpoint: clean)\nStep 1: `bin/test spec/workers/retry_worker_spec.rb:42` \u2014 for \"make the retry worker drain the queue\"\nGate: none \u00b7 Don't: re-run the full suite before the flaky spec is fixed\nLive: nothing running known (not checked)\n## User constraints\nU-1 \"keep the public API of RetryWorker unchanged\" \u2014 scope lib/retry_worker.rb; ask: open\nU-2 \"no new gems\" \u2014 scope Gemfile; ask: done\n## Decisions and do-not-re-raise\nD-1 exponential backoff capped at 5 tries \u2014 because the upstream rate limit resets in 60 s (user)\nD-2 the job stays idempotent by request id \u2014 because duplicates were seen in staging (agent)\nX-1 rejected a global mutex \u2014 it serialised unrelated queues\n## In flight\nNothing in flight as of the last message (not checked)\n## Live state\nnone beyond git (not checked)\n## Open questions\nQ-1 drop the legacy retry flag now or next release \u00b7 blocks nothing \u00b7 options now, next \u00b7 recommendation next \u00b7 raised by agent \u00b7 unasked\n## Location\nworktree example-repo, branch feature/LAB-123-retry, cwd example-repo\n## Work done and findings\nRetryWorker backoff: implemented \u2014 lib/retry_worker.rb#perform; tests: 41 pass, 1 flaky, `bin/test spec/workers`\nFinding: the flaky spec depends on wall-clock rounding \u2014 spec/workers/retry_worker_spec.rb:42\n## Evidence\nVolatile: none\n## Next steps\n1. `bin/test spec/workers/retry_worker_spec.rb:42` \u2014 done when it passes 5 runs in a row\n</summary>\n"
 },
 "PreCompact/canary-manual": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "PreCompact",
  "trigger": "manual",
  "custom_instructions": "keep SECRET_CANARY_7f3 and CANARY-TEXT-instructions out of every log\n\nThe user's compactinue plugin asks for this form, not any section list above; a user's /compact note wins.\nIn order; omit empty sections lacking a None: form:\nFirst line inside <summary>: \u27eacompactinue v1 n=1a2b3c4d s=main\u27eb\n# <ticket or topic> \u2014 <state in \u22648 words>\nLast line before </summary>: \u27ea/compactinue n=1a2b3c4d\u27eb"
 },
 "PreCompact/foreign-header-auto": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "PreCompact",
  "trigger": "auto",
  "custom_instructions": "\u27eafixture-notes v1 n=1a2b3c4d s=main\u27eb\nSummarise as fixture-notes cards; keep each card under 300 characters.\n\u27ea/fixture-notes n=1a2b3c4d\u27eb"
 },
 "PreCompact/manual-note": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "PreCompact",
  "trigger": "manual",
  "custom_instructions": "keep the SQL"
 },
 "PreCompact/null-auto": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "PreCompact",
  "trigger": "auto",
  "custom_instructions": null
 },
 "PreCompact/null-manual": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "PreCompact",
  "trigger": "manual",
  "custom_instructions": null
 },
 "PreCompact/orphan-marker-manual": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "PreCompact",
  "trigger": "manual",
  "custom_instructions": "Use this earlier summary as a guide:\n\u27eacompactinue v1 n=0badf00d s=main\u27eb\n# LAB-9 \u2014 old work\n\u27ea/compactinue n=0badf00d\u27eb"
 },
 "PreCompact/orphan-then-ours-manual": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "PreCompact",
  "trigger": "manual",
  "custom_instructions": "Use this earlier summary as a guide:\n\u27eacompactinue v1 n=0badf00d s=main\u27eb\n\nThe user's compactinue plugin asks for this form, not any section list above; a user's /compact note wins.\nIn order; omit empty sections lacking a None: form:\nFirst line inside <summary>: \u27eacompactinue v1 n=1a2b3c4d s=main\u27eb\n# <ticket or topic> \u2014 <state in \u22648 words>\nLast line before </summary>: \u27ea/compactinue n=1a2b3c4d\u27eb"
 },
 "PreCompact/self-call-manual": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "PreCompact",
  "trigger": "manual",
  "custom_instructions": "The user's compactinue plugin asks for this form, not any section list above; a user's /compact note wins.\nIn order; omit empty sections lacking a None: form:\nFirst line inside <summary>: \u27eacompactinue v1 n=2b3c4d5e s=main\u27eb\n# <ticket or topic> \u2014 <state in \u22648 words>\nLast line before </summary>: \u27ea/compactinue n=2b3c4d5e\u27eb"
 },
 "PreCompact/shaped-auto": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "PreCompact",
  "trigger": "auto",
  "custom_instructions": "The user's compactinue plugin asks for this form, not any section list above; a user's /compact note wins.\nIn order; omit empty sections lacking a None: form:\nFirst line inside <summary>: \u27eacompactinue v1 n=1a2b3c4d s=main\u27eb\n# <ticket or topic> \u2014 <state in \u22648 words>\nLast line before </summary>: \u27ea/compactinue n=1a2b3c4d\u27eb"
 },
 "PreCompact/shaped-manual-note": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "PreCompact",
  "trigger": "manual",
  "custom_instructions": "keep the SQL\n\nThe user's compactinue plugin asks for this form, not any section list above; a user's /compact note wins.\nIn order; omit empty sections lacking a None: form:\nFirst line inside <summary>: \u27eacompactinue v1 n=1a2b3c4d s=main\u27eb\n# <ticket or topic> \u2014 <state in \u22648 words>\nLast line before </summary>: \u27ea/compactinue n=1a2b3c4d\u27eb"
 },
 "PreCompact/shaped-sub-auto": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "PreCompact",
  "trigger": "auto",
  "custom_instructions": "The user's compactinue plugin asks for this form, not any section list above; a user's /compact note wins.\nIn order; omit empty sections lacking a None: form:\nFirst line inside <summary>: \u27eacompactinue v1 n=5e6f7081 s=sub\u27eb\n# <ticket or topic> \u2014 <state in \u22648 words>\nLast line before </summary>: \u27ea/compactinue n=5e6f7081\u27eb"
 },
 "SessionEnd/clear": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "SessionEnd",
  "reason": "clear"
 },
 "SessionEnd/logout": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "SessionEnd",
  "reason": "logout"
 },
 "SessionEnd/other": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "SessionEnd",
  "reason": "other"
 },
 "SessionEnd/prompt-input-exit": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "SessionEnd",
  "reason": "prompt_input_exit"
 },
 "SessionEnd/resume": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "SessionEnd",
  "reason": "resume"
 },
 "SessionStart/clear-S2": {
  "session_id": "5e55a002-0c0f-4f1e-9a00-00000000a002",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a002-0c0f-4f1e-9a00-00000000a002.jsonl",
  "cwd": "$TMP/example-repo",
  "hook_event_name": "SessionStart",
  "source": "clear",
  "model": "claude-fixture-model"
 },
 "SessionStart/compact-S2": {
  "session_id": "5e55a002-0c0f-4f1e-9a00-00000000a002",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a002-0c0f-4f1e-9a00-00000000a002.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "SessionStart",
  "source": "compact",
  "model": "claude-fixture-model"
 },
 "SessionStart/compact": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "SessionStart",
  "source": "compact",
  "model": "claude-fixture-model"
 },
 "SessionStart/fork-S3": {
  "session_id": "5e55a003-0c0f-4f1e-9a00-00000000a003",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a003-0c0f-4f1e-9a00-00000000a003.jsonl",
  "cwd": "$TMP/example-repo",
  "hook_event_name": "SessionStart",
  "source": "fork",
  "model": "claude-fixture-model",
  "seconds_since_last_response": 30,
  "context_tokens": 95000,
  "prompt_cache_likely_expired": false,
  "estimated_cache_write_usd": 0.0
 },
 "SessionStart/resume": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "hook_event_name": "SessionStart",
  "source": "resume",
  "model": "claude-fixture-model",
  "seconds_since_last_response": 420,
  "context_tokens": 181000,
  "prompt_cache_likely_expired": true,
  "estimated_cache_write_usd": 0.68
 },
 "SessionStart/startup": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "hook_event_name": "SessionStart",
  "source": "startup",
  "model": "claude-fixture-model"
 },
 "Stop/basic": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [],
  "session_crons": []
 },
 "Stop/canary-message": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Here is SECRET_CANARY_7f3 and CANARY-TEXT-assistant in the last message.",
  "background_tasks": [],
  "session_crons": []
 },
 "Stop/hook-active": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": true,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [],
  "session_crons": []
 },
 "Stop/ring-01": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-001",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 1",
    "command": "bin/test spec/workers --seed 1"
   },
   {
    "id": "t-1001",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1001"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-02": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-002",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 2",
    "command": "bin/test spec/workers --seed 2"
   },
   {
    "id": "t-1002",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1002"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-03": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-003",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 3",
    "command": "bin/test spec/workers --seed 3"
   },
   {
    "id": "t-1003",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1003"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-04": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-004",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 4",
    "command": "bin/test spec/workers --seed 4"
   },
   {
    "id": "t-1004",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1004"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-05": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-005",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 5",
    "command": "bin/test spec/workers --seed 5"
   },
   {
    "id": "t-1005",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1005"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-06": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-006",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 6",
    "command": "bin/test spec/workers --seed 6"
   },
   {
    "id": "t-1006",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1006"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-07": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-007",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 7",
    "command": "bin/test spec/workers --seed 7"
   },
   {
    "id": "t-1007",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1007"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-08": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-008",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 8",
    "command": "bin/test spec/workers --seed 8"
   },
   {
    "id": "t-1008",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1008"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-09": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-009",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 9",
    "command": "bin/test spec/workers --seed 9"
   },
   {
    "id": "t-1009",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1009"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-10": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-010",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 10",
    "command": "bin/test spec/workers --seed 10"
   },
   {
    "id": "t-1010",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1010"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-11": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-011",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 11",
    "command": "bin/test spec/workers --seed 11"
   },
   {
    "id": "t-1011",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1011"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-12": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-012",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 12",
    "command": "bin/test spec/workers --seed 12"
   },
   {
    "id": "t-1012",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1012"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-13": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-013",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 13",
    "command": "bin/test spec/workers --seed 13"
   },
   {
    "id": "t-1013",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1013"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-14": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-014",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 14",
    "command": "bin/test spec/workers --seed 14"
   },
   {
    "id": "t-1014",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1014"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-15": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-015",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 15",
    "command": "bin/test spec/workers --seed 15"
   },
   {
    "id": "t-1015",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1015"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-16": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-016",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 16",
    "command": "bin/test spec/workers --seed 16"
   },
   {
    "id": "t-1016",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1016"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-17": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-017",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 17",
    "command": "bin/test spec/workers --seed 17"
   },
   {
    "id": "t-1017",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1017"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-18": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-018",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 18",
    "command": "bin/test spec/workers --seed 18"
   },
   {
    "id": "t-1018",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1018"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-19": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-019",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 19",
    "command": "bin/test spec/workers --seed 19"
   },
   {
    "id": "t-1019",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1019"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-20": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-020",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 20",
    "command": "bin/test spec/workers --seed 20"
   },
   {
    "id": "t-1020",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1020"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-21": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-021",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 21",
    "command": "bin/test spec/workers --seed 21"
   },
   {
    "id": "t-1021",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1021"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-22": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-022",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 22",
    "command": "bin/test spec/workers --seed 22"
   },
   {
    "id": "t-1022",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1022"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-23": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-023",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 23",
    "command": "bin/test spec/workers --seed 23"
   },
   {
    "id": "t-1023",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1023"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-24": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-024",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 24",
    "command": "bin/test spec/workers --seed 24"
   },
   {
    "id": "t-1024",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1024"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-25": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-025",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 25",
    "command": "bin/test spec/workers --seed 25"
   },
   {
    "id": "t-1025",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1025"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-26": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-026",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 26",
    "command": "bin/test spec/workers --seed 26"
   },
   {
    "id": "t-1026",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1026"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-27": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-027",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 27",
    "command": "bin/test spec/workers --seed 27"
   },
   {
    "id": "t-1027",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1027"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-28": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-028",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 28",
    "command": "bin/test spec/workers --seed 28"
   },
   {
    "id": "t-1028",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1028"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-29": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-029",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 29",
    "command": "bin/test spec/workers --seed 29"
   },
   {
    "id": "t-1029",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1029"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-30": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-030",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 30",
    "command": "bin/test spec/workers --seed 30"
   },
   {
    "id": "t-1030",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1030"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-31": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-031",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 31",
    "command": "bin/test spec/workers --seed 31"
   },
   {
    "id": "t-1031",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1031"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-32": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-032",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 32",
    "command": "bin/test spec/workers --seed 32"
   },
   {
    "id": "t-1032",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1032"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-33": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-033",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 33",
    "command": "bin/test spec/workers --seed 33"
   },
   {
    "id": "t-1033",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1033"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-34": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-034",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 34",
    "command": "bin/test spec/workers --seed 34"
   },
   {
    "id": "t-1034",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1034"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-35": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-035",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 35",
    "command": "bin/test spec/workers --seed 35"
   },
   {
    "id": "t-1035",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1035"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-36": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-036",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 36",
    "command": "bin/test spec/workers --seed 36"
   },
   {
    "id": "t-1036",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1036"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-37": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-037",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 37",
    "command": "bin/test spec/workers --seed 37"
   },
   {
    "id": "t-1037",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1037"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-38": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-038",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 38",
    "command": "bin/test spec/workers --seed 38"
   },
   {
    "id": "t-1038",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1038"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-39": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-039",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 39",
    "command": "bin/test spec/workers --seed 39"
   },
   {
    "id": "t-1039",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1039"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-40": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-040",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 40",
    "command": "bin/test spec/workers --seed 40"
   },
   {
    "id": "t-1040",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1040"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-41": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-041",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 41",
    "command": "bin/test spec/workers --seed 41"
   },
   {
    "id": "t-1041",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1041"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-42": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-042",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 42",
    "command": "bin/test spec/workers --seed 42"
   },
   {
    "id": "t-1042",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1042"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-43": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-043",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 43",
    "command": "bin/test spec/workers --seed 43"
   },
   {
    "id": "t-1043",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1043"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-44": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-044",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 44",
    "command": "bin/test spec/workers --seed 44"
   },
   {
    "id": "t-1044",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1044"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-45": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-045",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 45",
    "command": "bin/test spec/workers --seed 45"
   },
   {
    "id": "t-1045",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1045"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-46": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-046",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 46",
    "command": "bin/test spec/workers --seed 46"
   },
   {
    "id": "t-1046",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1046"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-47": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-047",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 47",
    "command": "bin/test spec/workers --seed 47"
   },
   {
    "id": "t-1047",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1047"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-48": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-048",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 48",
    "command": "bin/test spec/workers --seed 48"
   },
   {
    "id": "t-1048",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1048"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-49": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-049",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 49",
    "command": "bin/test spec/workers --seed 49"
   },
   {
    "id": "t-1049",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1049"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-50": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-050",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 50",
    "command": "bin/test spec/workers --seed 50"
   },
   {
    "id": "t-1050",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1050"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-51": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-050",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 50",
    "command": "bin/test spec/workers --seed 50"
   },
   {
    "id": "t-1050",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1050"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-52": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-050",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 50",
    "command": "bin/test spec/workers --seed 50"
   },
   {
    "id": "t-1050",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1050"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-53": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-050",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 50",
    "command": "bin/test spec/workers --seed 50"
   },
   {
    "id": "t-1050",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1050"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-54": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-050",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 50",
    "command": "bin/test spec/workers --seed 50"
   },
   {
    "id": "t-1050",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1050"
   }
  ],
  "session_crons": []
 },
 "Stop/ring-55": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-050",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 50",
    "command": "bin/test spec/workers --seed 50"
   },
   {
    "id": "t-1050",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 1050"
   }
  ],
  "session_crons": []
 },
 "Stop/with-tasks": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "Stop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "last_assistant_message": "Done: the flaky spec passes five runs in a row.",
  "background_tasks": [
   {
    "id": "b-001",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 1",
    "command": "bin/test spec/workers --seed 1"
   },
   {
    "id": "a-002",
    "type": "subagent",
    "status": "running",
    "description": "fixture subagent task 2",
    "agent_type": "general-purpose"
   },
   {
    "id": "w-003",
    "type": "workflow",
    "status": "running",
    "description": "fixture workflow task 3",
    "name": "fixture-workflow-3"
   },
   {
    "id": "t-004",
    "type": "teammate",
    "status": "running",
    "description": "fixture teammate task 4"
   },
   {
    "id": "m-005",
    "type": "monitor",
    "status": "running",
    "description": "fixture monitor task 5",
    "server": "fixture-server",
    "tool": "watch_logs"
   }
  ],
  "session_crons": [
   {
    "id": "c-001",
    "schedule": "0 9 * * 1-5",
    "recurring": true,
    "prompt": "fixture: check the nightly import"
   }
  ]
 },
 "StopFailure/max-output-tokens": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "StopFailure",
  "error": "max_output_tokens",
  "last_assistant_message": "SECRET_CANARY_7f3 partial answer"
 },
 "StopFailure/rate-limit": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "StopFailure",
  "error": "rate_limit",
  "error_details": "429 from the fixture endpoint; CANARY-TEXT-error-details",
  "last_assistant_message": "Working on it"
 },
 "StopFailure/server-error": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "StopFailure",
  "error": "server_error"
 },
 "SubagentStop/basic": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "SubagentStop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "agent_id": "a9a00b3f363327444",
  "agent_transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001/subagents/agent-a9a00b3f363327444.jsonl",
  "agent_type": "general-purpose",
  "last_assistant_message": "7 callers; 2 pass a raw hash.",
  "background_tasks": [],
  "session_crons": []
 },
 "SubagentStop/summarizer-fork": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "SubagentStop",
  "permission_mode": "default",
  "stop_hook_active": false,
  "agent_id": "a0c0ffee0c0a1b2c3",
  "agent_transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001/subagents/agent-a0c0ffee0c0a1b2c3.jsonl",
  "agent_type": "",
  "last_assistant_message": "<summary>\nfixture summary text CANARY-TEXT-summary\n</summary>",
  "background_tasks": [],
  "session_crons": []
 },
 "SubagentStop/with-tasks": {
  "session_id": "5e55a001-0c0f-4f1e-9a00-00000000a001",
  "transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001.jsonl",
  "cwd": "$TMP/example-repo",
  "prompt_id": "9f0e1d2c-3b4a-4596-8877-665544332211",
  "hook_event_name": "SubagentStop",
  "permission_mode": "default",
  "effort": {
   "level": "high"
  },
  "stop_hook_active": false,
  "agent_id": "a9a00b3f363327444",
  "agent_transcript_path": "$TMP/projects/-tmp-example-repo/5e55a001-0c0f-4f1e-9a00-00000000a001/subagents/agent-a9a00b3f363327444.jsonl",
  "agent_type": "general-purpose",
  "last_assistant_message": "Started a background test run.",
  "background_tasks": [
   {
    "id": "b-007",
    "type": "shell",
    "status": "running",
    "description": "fixture shell task 7",
    "command": "bin/test spec/workers --seed 7"
   }
  ],
  "session_crons": []
 }
}
export const PAYLOADS_INVALID: Readonly<Record<string, string>> = {
 "PermissionDenied/empty": "",
 "PermissionDenied/malformed": "{\"session_id\": \"5e55a001-0c0f-4f1e-9a00-00000000a001\", \"hook_event_name\": \"PermissionDenied\", \"trigger\": \"auto\", \"cwd\": \n",
 "PostCompact/empty": "",
 "PostCompact/malformed": "{\"session_id\": \"5e55a001-0c0f-4f1e-9a00-00000000a001\", \"hook_event_name\": \"PostCompact\", \"trigger\": \"auto\", \"cwd\": \n",
 "PreCompact/empty": "",
 "PreCompact/malformed": "{\"session_id\": \"5e55a001-0c0f-4f1e-9a00-00000000a001\", \"hook_event_name\": \"PreCompact\", \"trigger\": \"auto\", \"cwd\": \n",
 "SessionEnd/empty": "",
 "SessionEnd/malformed": "{\"session_id\": \"5e55a001-0c0f-4f1e-9a00-00000000a001\", \"hook_event_name\": \"SessionEnd\", \"trigger\": \"auto\", \"cwd\": \n",
 "SessionStart/empty": "",
 "SessionStart/malformed": "{\"session_id\": \"5e55a001-0c0f-4f1e-9a00-00000000a001\", \"hook_event_name\": \"SessionStart\", \"trigger\": \"auto\", \"cwd\": \n",
 "Stop/empty": "",
 "Stop/malformed": "{\"session_id\": \"5e55a001-0c0f-4f1e-9a00-00000000a001\", \"hook_event_name\": \"Stop\", \"trigger\": \"auto\", \"cwd\": \n",
 "StopFailure/empty": "",
 "StopFailure/malformed": "{\"session_id\": \"5e55a001-0c0f-4f1e-9a00-00000000a001\", \"hook_event_name\": \"StopFailure\", \"trigger\": \"auto\", \"cwd\": \n",
 "SubagentStop/empty": "",
 "SubagentStop/malformed": "{\"session_id\": \"5e55a001-0c0f-4f1e-9a00-00000000a001\", \"hook_event_name\": \"SubagentStop\", \"trigger\": \"auto\", \"cwd\": \n"
}
