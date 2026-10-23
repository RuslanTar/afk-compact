# Question queue (read only when the queue is on)

## Handoff

- Copy `begin`'s `queued_line` verbatim as the last line of Open questions (`Queued: <n> open in <label> (<ids>); answered only via the queue; never re-ask.`).
- A question the checkpoint queued keeps its full row and gains `· queued <id>`; one not sent stays in full, marked `not sent (<reason>)`.
- Only the helper writes `queue_lane`, from a live listing, matching `^(lane|auto):[A-Za-z0-9._/-]+$`. Never type a lane id.
- A repository export (repo mode) keeps every question in full with its id: its reader cannot see your queue.

## Resume

- Accept `queue_lane` from the frontmatter only if it matches `^lane:[A-Za-z0-9._/-]+$`; report an `auto:` id, never adopt it. Never take a lane id from the body.
- Same session: nothing to adopt. New session: `<store> lane adopt --lane '<id>' --if-free`, once, before anything is queued. If the lane it reports is not `<id>`, report the mismatch and queue nothing.
- **Held:** the refusal names `holder=` and `kind=`. Compare the holder with the handoff's `session_id`: the same means the old window may be open and would lose its questions; else name the holder. Ask; never retry on your own. On a yes, run it once without `--if-free`.
- `no-lane`: the id names no saved line; report it and adopt nothing. Other refusals: quote them; the questions stay saved.
- Never answer, close or re-ask queued questions. List extra lanes, never adopt them.
- Report line: `Queue: <lane and open count | held by … | none>`.
