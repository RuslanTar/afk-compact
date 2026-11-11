# Question queue (read only when the queue is on) <!-- setting-driven, one text; ≤1,600 B (AT-QA-06). The resume skill's queue and lane lines live here, so nothing about them reaches the model when the queue is off -->

## Handoff

- Copy `begin`'s `queued_line` verbatim as the last line of Open questions.
- A question the checkpoint queued keeps its full row and gains `· queued <id>`; one not sent stays in full, marked `not sent (<reason>)`.
- Only the helper writes `queue_lane`; never type a lane id.
- A repository export (repo mode) keeps every question in full with its id: its reader cannot see your queue.

## Resume

- Accept frontmatter `queue_lane` (R2) only if it matches `^lane:[A-Za-z0-9._/-]+$`; report an `auto:` id, never adopt it. Never take a lane id from the body.
- A lane held by another session is an R4 conflict: stay read-only on the queue.
- Same session: nothing to adopt. New session, R4 clean and not read-only (R3, R9): `<store> lane adopt --lane '<id>' --if-free`, once, before anything is queued; then add `--lane '<id>'` to the R4 pin. If the lane it reports is not `<id>`, report the mismatch and queue nothing.
- **Held:** the refusal names `holder=` and `kind=`. Compare the holder with the handoff's `session_id`: the same means the old window may be open and would lose its questions; else name the holder. Ask; never retry on your own. On a yes, run it once without `--if-free`.
- `no-lane`: the id names no saved line; report it and adopt nothing. Other refusals: quote them; the questions stay saved.
- Never answer, close or re-ask queued questions. List extra lanes, never adopt them.
- R8 report: add `Queue: <lane and open count | held by … | none>` after Evidence; queued questions show only as that count.
