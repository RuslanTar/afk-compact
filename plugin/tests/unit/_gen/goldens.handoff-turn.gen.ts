// GEN by tools/assemble --goldens from tests/fixtures/assembly (runtime.json, expected/).
// Do not edit; edit the assets or runtime.json and run tools/assemble --goldens.
// Goldens of handoff-turn.txt in render order; goldens.gen.ts gathers every module.
// Each golden is split at the plugin name it was rendered with: join the parts with a name.

export const ROWS: readonly { asset: string; tags: readonly string[]; parts: readonly string[] }[] = [
 {
  "asset": "handoff-turn",
  "tags": [],
  "parts": [
   "\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit"
  ],
  "parts": [
   "Invoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "near"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "spent"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "imminent"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit-pre"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit-halt"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "near"
  ],
  "parts": [
   "Invoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "spent"
  ],
  "parts": [
   "Invoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "imminent"
  ],
  "parts": [
   "Invoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "submit-pre"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "submit-halt"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "near",
   "spent"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "near",
   "imminent"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "near",
   "submit-pre"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "near",
   "submit-halt"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "near",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "spent",
   "imminent"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "spent",
   "submit-pre"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "spent",
   "submit-halt"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "spent",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "imminent",
   "submit-pre"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "imminent",
   "submit-halt"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "imminent",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit-pre",
   "submit-halt"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit-pre",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit-halt",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "near",
   "spent"
  ],
  "parts": [
   "Invoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "near",
   "imminent"
  ],
  "parts": [
   "Invoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "near",
   "submit-pre"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "near",
   "submit-halt"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "near",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "spent",
   "imminent"
  ],
  "parts": [
   "Invoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "spent",
   "submit-pre"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "spent",
   "submit-halt"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "spent",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "imminent",
   "submit-pre"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "imminent",
   "submit-halt"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "imminent",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "submit-pre",
   "submit-halt"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "submit-pre",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "submit-halt",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "near",
   "spent",
   "imminent"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "near",
   "spent",
   "submit-pre"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "near",
   "spent",
   "submit-halt"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "near",
   "spent",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "near",
   "imminent",
   "submit-pre"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "near",
   "imminent",
   "submit-halt"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "near",
   "imminent",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "near",
   "submit-pre",
   "submit-halt"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "near",
   "submit-pre",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "near",
   "submit-halt",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "spent",
   "imminent",
   "submit-pre"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "spent",
   "imminent",
   "submit-halt"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "spent",
   "imminent",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "spent",
   "submit-pre",
   "submit-halt"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "spent",
   "submit-pre",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "spent",
   "submit-halt",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "imminent",
   "submit-pre",
   "submit-halt"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "imminent",
   "submit-pre",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "imminent",
   "submit-halt",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit-pre",
   "submit-halt",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "near",
   "spent",
   "imminent"
  ],
  "parts": [
   "Invoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "near",
   "spent",
   "submit-pre"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "near",
   "spent",
   "submit-halt"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "near",
   "spent",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "near",
   "imminent",
   "submit-pre"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "near",
   "imminent",
   "submit-halt"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "near",
   "imminent",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "near",
   "submit-pre",
   "submit-halt"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "near",
   "submit-pre",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "near",
   "submit-halt",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "spent",
   "imminent",
   "submit-pre"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "spent",
   "imminent",
   "submit-halt"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "spent",
   "imminent",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "spent",
   "submit-pre",
   "submit-halt"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "spent",
   "submit-pre",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "spent",
   "submit-halt",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "imminent",
   "submit-pre",
   "submit-halt"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "imminent",
   "submit-pre",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "imminent",
   "submit-halt",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "submit-pre",
   "submit-halt",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "near",
   "spent",
   "imminent",
   "submit-pre"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "near",
   "spent",
   "imminent",
   "submit-halt"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "near",
   "spent",
   "imminent",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "near",
   "spent",
   "submit-pre",
   "submit-halt"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "near",
   "spent",
   "submit-pre",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "near",
   "spent",
   "submit-halt",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "near",
   "imminent",
   "submit-pre",
   "submit-halt"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "near",
   "imminent",
   "submit-pre",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "near",
   "imminent",
   "submit-halt",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "near",
   "submit-pre",
   "submit-halt",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "spent",
   "imminent",
   "submit-pre",
   "submit-halt"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "spent",
   "imminent",
   "submit-pre",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "spent",
   "imminent",
   "submit-halt",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "spent",
   "submit-pre",
   "submit-halt",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "imminent",
   "submit-pre",
   "submit-halt",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "near",
   "spent",
   "imminent",
   "submit-pre"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "near",
   "spent",
   "imminent",
   "submit-halt"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "near",
   "spent",
   "imminent",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "near",
   "spent",
   "submit-pre",
   "submit-halt"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "near",
   "spent",
   "submit-pre",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "near",
   "spent",
   "submit-halt",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "near",
   "imminent",
   "submit-pre",
   "submit-halt"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "near",
   "imminent",
   "submit-pre",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "near",
   "imminent",
   "submit-halt",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "near",
   "submit-pre",
   "submit-halt",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "spent",
   "imminent",
   "submit-pre",
   "submit-halt"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "spent",
   "imminent",
   "submit-pre",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "spent",
   "imminent",
   "submit-halt",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "spent",
   "submit-pre",
   "submit-halt",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "imminent",
   "submit-pre",
   "submit-halt",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "near",
   "spent",
   "imminent",
   "submit-pre",
   "submit-halt"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "near",
   "spent",
   "imminent",
   "submit-pre",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "near",
   "spent",
   "imminent",
   "submit-halt",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "near",
   "spent",
   "submit-pre",
   "submit-halt",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "near",
   "imminent",
   "submit-pre",
   "submit-halt",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "spent",
   "imminent",
   "submit-pre",
   "submit-halt",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "near",
   "spent",
   "imminent",
   "submit-pre",
   "submit-halt"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "near",
   "spent",
   "imminent",
   "submit-pre",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "near",
   "spent",
   "imminent",
   "submit-halt",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "near",
   "spent",
   "submit-pre",
   "submit-halt",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "near",
   "imminent",
   "submit-pre",
   "submit-halt",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "spent",
   "imminent",
   "submit-pre",
   "submit-halt",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "near",
   "spent",
   "imminent",
   "submit-pre",
   "submit-halt",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 },
 {
  "asset": "handoff-turn",
  "tags": [
   "submit",
   "near",
   "spent",
   "imminent",
   "submit-pre",
   "submit-halt",
   "submit-idle"
  ],
  "parts": [
   "Note from the user's ",
   " plugin: auto-continue is paused (the hourly auto-continue limit is reached), so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the context reached the planned compaction point, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nNote from the user's ",
   " plugin: the session has been idle for 49 minutes and the prompt cache expires soon, so the plugin asks for a handoff while the context is still here. This is not the user's answer; their open questions stay open.\nInvoke the ",
   ":handoff skill now, with no arguments, and follow it. Plugin limit on top of the skill's: at most 34 tool calls in this turn. When the plugin says the budget is spent, draft and publish with what you have, or stop if nothing is drafted. Start no new work, ask nothing with a question tool, act outward on nothing.\nEnd with the skill's report, and put one plain line above it telling the user that auto-continue paused and why; unless the task is done, the verdict's first `Needs you:` item is to send any message to resume the work.\nEnd with the skill's report. Do not continue the task after it; the user's next message leads.\nLaunch no agents or workflows; a background result arriving now: note it in the handoff only. End with the skill's report; put any question your previous reply asked the user, unchanged, in its `Needs you:` list (add the list if the report has none).\nNote from the user's ",
   " plugin: the handoff budget is nearly spent. Skip the remaining probes and recipes; draft and publish now (Steps 6\u20137).\nNote from the user's ",
   " plugin: the handoff budget is spent. Make no call except `\"/p/scripts/",
   "-store\" publish` and edits inside the stage folder: publish the draft, or end the turn with the report.\nNote from the user's ",
   " plugin: native compaction is close. End the turn now with the report; the compaction summary carries the rest.\n"
  ]
 }
]
