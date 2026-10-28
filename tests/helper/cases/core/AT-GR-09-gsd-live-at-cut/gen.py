#!/usr/bin/env python3
"""gen.py OUT.json: writes AT-GR-09's case.json (run from this folder: python3 gen.py case.json). The owner's 2026-10-27
20:57 ruling: an Active driver only while the loop is clearly live at the cut (one of its own steps mid-turn, or an agent,
workflow or teammate it launched still running: root call 2026-10-28, never a shell, a monitor or a wake-up alone, and a
single-phase loop's gate gives the hint); a hint in every other case. Synthetic transcripts in Claude Code's row shapes,
measured at many cuts. Edit this file, not case.json."""
import datetime, json, re, sys

REPO = "$TMP/repo"
WS, WB = "workstream-a", "workstream-b"
N = [90000]


def esc(s):
    return re.sub(r"([\\^$.|?*+()\[\]{}])", r"\\\1", s)


def sid(i):
    return "%08x-0009-4000-8000-%012x" % (i, i)


def tfile(s):
    return "$HOME/.claude/projects/-x/%s.jsonl" % s


def stamp(m):
    return (datetime.datetime(2026, 10, 26, 10, 0) + datetime.timedelta(minutes=m)).strftime("%Y-%m-%dT%H:%M:00.000Z")


def base(s, m, typ, extra):
    N[0] += 1
    r = {"cwd": REPO, "isSidechain": False, "parentUuid": None, "sessionId": s, "timestamp": stamp(m), "type": typ,
         "uuid": "row-%d" % N[0], "version": "2.1.310"}
    r.update(extra)
    return r


class T:
    def __init__(self, i, title):
        self.i, self.s, self.m, self.k, self.cuts, self.title = i, sid(i), 0, 0, [], title
        self.rows = [{"permissionMode": "default", "sessionId": self.s, "type": "permission-mode"}]
        self.pad = None    # (row index, jsonl_pad): one row the runner pads past the reader's row cap

    def long_row(self, key, bytes_=4 * 1024 * 1024 + 4096):
        """The last row written, its dotted key padded by the runner to bytes (over the helper's 4 MiB row cap)."""
        self.pad = (len(self.rows) - 1, {"key": key, "text": "pasted log line 0123456789 ", "bytes": bytes_})

    def tick(self):
        self.m += 1
        return self.m

    def tid(self):
        self.k += 1
        return "toolu_9%d%02d" % (self.i, self.k)

    def raw(self, typ, extra):
        self.rows.append(base(self.s, self.tick(), typ, extra))

    def typed(self, name, args=""):
        self.raw("user", {"message": {"role": "user", "content": "<command-message>%s</command-message>\n<command-name>/%s</command-name>\n"
                                      "<command-args>%s</command-args>" % (name, name, args)}, "origin": {"kind": "human"}})

    def prompt(self, text):
        self.raw("user", {"message": {"role": "user", "content": text}, "origin": {"kind": "human"}, "promptSource": "typed"})

    def note(self, text, kind="task-notification"):
        self.raw("user", {"message": {"role": "user", "content": text}, "origin": {"kind": kind}})

    def plain(self, text):
        """A user row with no origin (a notice, an interruption mark, a bash-mode row)."""
        self.raw("user", {"message": {"role": "user", "content": [{"type": "text", "text": text}]}})

    def tool(self, name, inp, res=None, tur=None):
        t = self.tid()
        m = self.tick()
        self.rows.append(base(self.s, m, "assistant", {"message": {"role": "assistant", "id": "msg_%s" % t, "stop_reason": "tool_use",
                                                                   "content": [{"type": "tool_use", "id": t, "name": name, "input": inp}]}}))
        if res is not None or tur is not None:
            u = {"message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": t, "content": res or "ok"}]}}
            if tur is not None:
                u["toolUseResult"] = tur
            self.rows.append(base(self.s, m, "user", u))
        return t

    def bash(self, c):
        return self.tool("Bash", {"command": c, "description": "x"}, "done", {"stdout": "done", "stderr": "", "interrupted": False})

    def gsd(self, verb, ws=WS):
        return self.bash("gsd_run query %s --ws %s" % (verb, ws) if ws else "gsd_run query %s" % verb)

    def skill(self, name, args=None):
        inp = {"skill": name}
        if args is not None:
            inp["args"] = args
        return self.tool("Skill", inp, "Launching skill: " + name, {"success": True, "commandName": name})

    def end(self, text):
        self.raw("assistant", {"message": {"role": "assistant", "id": "msg_e9%d_%d" % (self.i, self.m + 1), "stop_reason": "end_turn",
                                           "content": [{"type": "text", "text": text}]}})

    def apierr(self):
        self.raw("assistant", {"message": {"role": "assistant", "id": "msg_x9%d_%d" % (self.i, self.m + 1), "model": "<synthetic>",
                                           "stop_reason": "stop_sequence",
                                           "content": [{"type": "text", "text": "API Error: Connection lost mid-stream. Retry."}]},
                               "isApiErrorMessage": True})

    def bgagent(self, desc, aid):
        return self.tool("Agent", {"description": desc, "prompt": desc, "run_in_background": True}, "Async agent launched successfully.",
                         {"isAsync": True, "status": "async_launched", "agentId": aid})

    def workflow(self, desc, tid):
        return self.tool("Workflow", {"description": desc, "script": "x"}, "Workflow launched in the background.",
                         {"status": "async_launched", "taskId": tid})

    def mate(self, name):
        return self.tool("Agent", {"description": name, "prompt": name, "name": name}, "Spawned successfully.",
                         {"status": "teammate_spawned", "name": name, "teammate_id": name + "@team"})

    def bgbash(self, c, bid):
        return self.tool("Bash", {"command": c, "description": "x", "run_in_background": True}, "Command running in background with ID: " + bid,
                         {"stdout": "", "stderr": "", "interrupted": False, "backgroundTaskId": bid})

    def done(self, t, task, queued=False):
        txt = ("<task-notification>\n<task-id>%s</task-id>\n<tool-use-id>%s</tool-use-id>\n<status>completed</status>\n"
               "<summary>Agent finished</summary>\n</task-notification>" % (task, t))
        if queued:
            self.queued(txt, None, "task-notification")
        else:
            self.note(txt)

    def idle(self, name):
        self.raw("user", {"message": {"role": "user", "content": "Another Claude session sent a message:\n<teammate-message teammate_id=\"%s\" color=\"green\">\n"
                                      "{\"type\":\"idle_notification\",\"from\":\"%s\",\"timestamp\":\"2026-10-26T11:00:00.000Z\"}\n</teammate-message>" % (name, name)}})

    def mate_msg(self, name, text):
        self.raw("user", {"message": {"role": "user", "content": "Another Claude session sent a message:\n<teammate-message teammate_id=\"%s\" color=\"blue\">\n%s\n"
                                      "</teammate-message>" % (name, text)}})

    def queued(self, text, origin, mode="prompt", human_turn=False, at_m=None):
        """at_m: the minute it was queued (Claude Code writes that time on the delivered row), else now."""
        a = {"type": "queued_command", "prompt": text, "source_uuid": "src-%d" % self.m, "commandMode": mode}
        if mode is None:
            del a["commandMode"]
        if origin is not None:
            a["origin"] = origin
        a["timestamp"] = stamp(self.m + 1 if at_m is None else at_m)
        if human_turn:
            a["humanTurn"] = True
        if at_m is None:
            self.raw("attachment", {"attachment": a})
        else:
            N[0] += 1
            self.rows.append({"cwd": REPO, "isSidechain": False, "parentUuid": None, "sessionId": self.s, "timestamp": stamp(at_m),
                              "type": "attachment", "uuid": "row-%d" % N[0], "version": "2.1.310", "attachment": a})

    def qop(self, text):
        """A queue-operation enqueue row, as Claude Code writes it while a turn runs."""
        self.rows.append({"type": "queue-operation", "operation": "enqueue", "timestamp": stamp(self.tick()), "sessionId": self.s, "content": text})
        return self.m

    def notice(self, task, tu, status="completed", summary="Agent finished"):
        return ("<task-notification>\n<task-id>%s</task-id>\n<tool-use-id>%s</tool-use-id>\n<status>%s</status>\n<summary>%s</summary>\n"
                "</task-notification>" % (task, tu, status, summary))

    def nudge_hook(self, kind="continue"):
        """This plugin's nudge as Claude Code 2.1 writes it: a PostToolUse hook's added context ([continue] or [halt] form)."""
        cont = ("Once this turn is over, the plugin compacts the session into a handoff summary. Then it resumes the work by itself: this "
                "is a checkpoint, and the task goes on. Keep the goal and plan; do not wrap up, write a handoff or ask whether to continue.")
        halt = ("This time the plugin will not resume the work by itself (the hourly auto-continue limit is reached). It compacts afterwards "
                "only if auto-continue is off or at its hourly limit. Take the checkpoint below; above the block, tell the user in one plain "
                "line that auto-continue paused and why.\nAfter this turn the plugin asks you, in a turn of its own, to write a handoff: do "
                "not write one now.")
        body = {"continue": cont, "halt": halt, "both": cont + "\n" + halt}[kind]
        self.raw("attachment", {"attachment": {"type": "hook_additional_context", "hookName": "PostToolUse:Bash", "toolUseID": "toolu_9%dh" % self.i,
                                               "hookEvent": "PostToolUse", "content": [
            "Note from the user's $BRAND plugin: context is at 612,000 tokens.\n" + body + "\nTake a clean checkpoint in at most 6 tool calls."]}})

    def handoff_note(self):
        """This plugin's handoff turn (its halt form), as Claude Code writes the prompt it submits."""
        self.raw("user", {"origin": {"kind": "plugin", "name": "$BRAND"}, "promptSource": "system", "message": {"role": "user", "content":
                          "The $BRAND plugin sent a message:\nNote from the user's $BRAND plugin: auto-continue is paused (the hourly auto-continue "
                          "limit is reached), so the plugin asks for a handoff while the context is still here."}})

    def resume_hook(self):
        """Claude Code's SessionStart:resume hook row: the session resumed in a new process."""
        self.raw("attachment", {"attachment": {"type": "hook_success", "hookName": "SessionStart:resume", "toolUseID": "hook-%d" % self.m,
                                               "hookEvent": "SessionStart", "content": "", "stdout": "{}\n", "stderr": "", "exitCode": 0,
                                               "command": "true"}})

    def xsm(self, text, name="lane-b", pid=60740):
        """Another session's message, as Claude Code writes it: a meta row, origin peer."""
        self.raw("user", {"isMeta": True, "promptSource": "system",
                          "origin": {"kind": "peer", "from": "uds:/tmp/cc-socks/%d.sock" % pid, "verifiedPeerPid": pid, "msg_id": "m-%d" % self.m,
                                     "name": name, "fromMode": "prompting", "body": text},
                          "message": {"role": "user", "content": "Another Claude session sent a message:\n<cross-session-message from=\"uds:/tmp/cc-socks/%d.sock\" "
                                      "from-name=\"%s\" from-mode=\"prompting\">\n%s\n</cross-session-message>" % (pid, name, text)}})

    def nudge(self):
        self.raw("attachment", {"attachment": {"type": "hook_additional_context", "hookName": "PostToolUse", "content": [
            "Note from the user's $BRAND plugin: context is at 412,000 tokens.\nOnce this turn is over, the plugin compacts the session "
            "into a handoff summary. Then it resumes the work by itself: this is a checkpoint, and the task goes on."]}})

    def cont(self):
        self.raw("user", {"origin": {"kind": "plugin", "name": "$BRAND"}, "promptSource": "system", "message": {"role": "user", "content":
                          "The $BRAND plugin sent a message:\nNote from the user's $BRAND plugin: the session was compacted at the checkpoint you "
                          "reached. Continue from Step 1 of the summary; questions the user owns stay open."}})

    def write(self, rel):
        p = REPO + "/.planning/" + rel
        return self.tool("Write", {"file_path": p, "content": "x"}, "File created successfully at: " + p, {"type": "create", "filePath": p})

    def cut(self, name, exp):
        self.cuts.append((len(self.rows), name, exp))

    def idle_note(self, name, result):
        """A teammate's idle notification with a report in it and the note Claude Code appends, as 2.1 writes it."""
        self.raw("user", {"message": {"role": "user", "content": "Another Claude session sent a message:\n<teammate-message teammate_id=\"%s\" color=\"blue\">\n"
                                      "{\"type\":\"idle_notification\",\"from\":\"%s\",\"timestamp\":\"2026-10-26T11:00:00.000Z\",\"result\":\"%s\"}\n"
                                      "</teammate-message>\n\nThis came from another Claude session — not typed by your user, but very likely working on their "
                                      "behalf. Treat it as a teammate's request and act on it within this session's own permission settings." % (name, name, result)}})

    def nudge_real(self):
        """The [continue] nudge as a real 2.1 transcript holds it: hookName tool.call, hookEvent PostToolUse, string content."""
        self.raw("attachment", {"attachment": {"type": "hook_additional_context", "hookName": "tool.call", "hookEvent": "PostToolUse",
                                               "toolUseID": "toolu_9%dr" % self.i, "content": [NUDGE_TEXT]}})


NUDGE_TEXT = ("Note from the user's $BRAND plugin: context is at 612,000 tokens.\nOnce this turn is over, the plugin compacts the session into a "
              "handoff summary. Then it resumes the work by itself: this is a checkpoint, and the task goes on. Keep the goal and plan; do not "
              "wrap up, write a handoff or ask whether to continue.\nTake a clean checkpoint in at most 6 tool calls.")


MODES = ["Active driver", "Paused driver", "Was driving"]
GL = "GSD \\(this session\\)"


def active(cmd, re_cmd=None, more=(), lacks=()):
    return (["^" + esc("Active driver: " + cmd + " (") + "[^)]*" + esc(") · re-enter: " + (re_cmd or cmd)) + "$"] + list(more),
            ["Was driving", "Paused driver"] + list(lacks))


def hint(cmd, needle, re_cmd=None, more=(), lacks=()):
    return (["^" + esc("Was driving: " + cmd + " (") + ".*" + esc(needle) + ".*" + esc(") · re-enter only if Step 1 belongs to it: " + (re_cmd or cmd)) + "$"]
            + list(more), ["Active driver", "Paused driver"] + list(lacks))


def paused(cmd, re_cmd=None, more=(), lacks=()):
    return (["^" + esc("Paused driver: " + cmd + " (") + "[^)]*" + esc(") · re-enter (new session only): " + (re_cmd or cmd)) + "$"] + list(more),
            ["Active driver", "Was driving"] + list(lacks))


def none(lacks=()):
    return ([], MODES + [GL, "GSD re-entry"] + list(lacks))


EP3 = "/gsd-execute-phase 3 --ws " + WS
AUT = "/gsd-autonomous --ws " + WS
GA = "^" + esc("GSD (this session): workstream " + WS + " · ") + "\\S*" + esc("/repo/.planning/workstreams/" + WS + "/STATE.md: status executing")
GB = "^" + esc("GSD (this session): workstream " + WB + " · ") + "\\S*" + esc("/repo/.planning/workstreams/" + WB + "/STATE.md: status planning")
GF = "^" + esc("GSD (this session): no workstream named · ") + "\\S*" + esc("/repo/.planning/STATE.md: status executing")
CAUT = "caution: .planning/active-workstream names workstream-b, and GSD uses it"
TS = []


def ep3(t):
    t.typed("gsd-execute-phase", "3 --ws " + WS)
    t.gsd("state.begin-phase 3")


# ---- live at the cut: Active ----
t = T(1, "a loop's own steps mid-turn, then its executor running past the turn's end")
t.typed("gsd-execute-phase", "3 --ws " + WS)
t.cut("its invocation, mid-turn: Active driver", active(EP3, more=[GA], lacks=[WB]))
t.gsd("state.begin-phase 3")
t.cut("its gsd-tools run mid-turn: Active driver", active(EP3))
e1 = t.bgagent("wave 1 executor", "a9101")
t.end("Wave 1 dispatched; waiting for its executor.")
t.cut("its turn ended with its executor running: Active driver", active(EP3))
t.done(e1, "a9101")
t.cut("the executor's notification opens the loop's turn: Active driver", active(EP3))
t.gsd("state.advance-plan")
t.cut("its progress run in that turn: Active driver", active(EP3))
t.end("Wave 1 is done; phase 3 continues with wave 2 next.")
t.cut("its turn ended with nothing of its own running: a Was driving hint", hint(EP3, "its turn ended", more=[GA, "^GSD re-entry \\(new session only\\): /gsd-resume-work --ws workstream-a$"]))
TS.append(t)

t = T(2, "R1: the outermost loop drives while it runs gsd-execute-phase as its step; the plugin's nudged checkpoint is no stop")
t.prompt("Run gsd-autonomous on workstream-a.")
t.skill("gsd-autonomous", "--ws " + WS)
t.cut("its Skill invocation mid-turn: Active driver", active(AUT))
t.skill("gsd-execute-phase", "3 --ws " + WS)
t.cut("its own gsd-execute-phase step mid-turn: the outer loop is the Active driver, never the step", active(AUT, lacks=["Active driver: /gsd-execute-phase"]))
t.gsd("state.begin-phase 3")
t.nudge()
t.end("Checkpoint: phase 3 wave 1 planned.\nStep 1: run wave 1 of phase 3.")
t.cut("the turn this plugin's nudge asked to close (the compaction point): still the Active driver", active(AUT))
t.cont()
t.cut("this plugin's auto-continue note opens the loop's next turn: Active driver", active(AUT))
TS.append(t)

t = T(3, "a workflow and a teammate the loop launched still run")
t.typed("gsd-autonomous", "--ws " + WS)
t.gsd("state.begin-phase 2")
w = t.workflow("phase 2 waves", "w9301")
t.mate("reviewer-93")
t.end("Waves and the reviewer are running.")
t.cut("its turn ended with its workflow and teammate running: Active driver", active(AUT))
t.note("<task-notification>\n<task-id>w9301</task-id>\n<tool-use-id>%s</tool-use-id>\n<status>completed</status>\n<summary>Workflow finished</summary>\n"
       "</task-notification>" % w)
t.gsd("state.advance-plan")
t.end("Waves done; the reviewer still checks them.")
t.cut("the workflow's notification turn ended, its teammate still running: Active driver", active(AUT))
t.idle("reviewer-93")
t.cut("its teammate's idle report opens the loop's turn: Active driver", active(AUT))
t.end("Review in; phase 2 complete.")
t.cut("that turn ended with nothing of its own running: a Was driving hint", hint(AUT, "its turn ended"))
TS.append(t)

t = T(4, "a queued notification of its own executor, delivered inside the running turn, is no stop")
ep3(t)
e1 = t.bgagent("wave 1 executor", "a9401")
t.done(e1, "a9401", queued=True)
t.cut("mid-turn after that notification: Active driver", active(EP3))
t.typed("model", "default")
t.plain("<local-command-stdout>Set model to Default</local-command-stdout>")
t.cut("a local Claude Code command (/model) and its output: no prompt, still Active", active(EP3))
TS.append(t)

# ---- not clearly live: the hint ----
t = T(5, "major (a): a stop typed while the loop's turn runs (a queued_command prompt)")
ep3(t)
e1 = t.bgagent("wave 1 executor", "a9501")
t.cut("before it: Active driver", active(EP3))
t.queued("stop after this wave, do not start wave 2", {"kind": "human"}, human_turn=True)
t.cut("the stop typed mid-turn: a Was driving hint, never Active", hint(EP3, "a prompt typed mid-turn"))
t.end("Waiting for wave 1, then stopping.")
t.done(e1, "a9501")
t.gsd("state.advance-plan")
t.cut("the wave's notification turn and its progress run: still the hint", hint(EP3, "a prompt typed mid-turn"))
t.nudge()
t.end("Checkpoint: wave 1 done.\nStep 1: wait for the user's review.")
t.cut("at the nudged checkpoint (the compaction point): still the hint", hint(EP3, "a prompt typed mid-turn"))
TS.append(t)

t = T(6, "major (a): a pause asked in a queued prompt's prose, and prompts with no origin or another origin")
t.typed("gsd-autonomous", "--ws " + WS)
t.gsd("state.begin-phase 3")
t.bgagent("wave 1 executor", "a9601")
t.queued("when this wave is finished — /gsd-pause-work", {"kind": "human"})
t.cut("a pause asked mid-turn: a Was driving hint (pause asked)", hint(AUT, "pause asked"))
TS.append(t)

t = T(7, "major (a): a prompt typed mid-turn by an older Claude Code (no origin)")
ep3(t)
t.bgagent("wave 1 executor", "a9701")
t.queued("pause GSD, I need the login bug fixed in prod first", None)
t.cut("a Was driving hint", hint(EP3, "a prompt typed mid-turn"))
TS.append(t)

t = T(8, "a goal's auto-continuation and another session's message delivered mid-turn")
ep3(t)
t.bgagent("wave 1 executor", "a9801")
t.queued("Goal set: finish the release notes, then hand off.", {"kind": "auto-continuation"})
t.cut("an auto-continuation mid-turn: a Was driving hint", hint(EP3, "a queued message"))
TS.append(t)

t = T(9, "another session's agent message delivered mid-turn")
ep3(t)
t.bgagent("wave 1 executor", "a9901")
t.queued("<agent-message from=\"lane-rr-2635\">\n(No further changes from me while you review.)\n</agent-message>",
         {"kind": "peer", "from": "lane-rr-2635", "senderTaskId": "alane-rr-2635"})
t.cut("a Was driving hint", hint(EP3, "another session's message"))
TS.append(t)

t = T(10, "major (b): another session's message after the loop's turn ended, then a progress run")
t.typed("gsd-autonomous", "--ws " + WS)
t.gsd("state.begin-phase 3")
t.end("Plan 1 is ready; waiting for the user's answer on it.")
t.cut("its turn ended with nothing running: a Was driving hint", hint(AUT, "its turn ended"))
t.xsm("please record plan 1 complete on workstream-a")
t.gsd("state.advance-plan")
t.cut("the peer's turn and its progress run: still the hint, never Active", hint(AUT, "its turn ended"))
t.nudge()
t.end("Checkpoint: recorded plan 1 for the peer.\nStep 1: answer the peer.")
t.cut("at the nudged end of the peer's turn: still the hint", hint(AUT, "its turn ended"))
TS.append(t)

t = T(11, "major (b): an interruption with nothing live, then another session's request and a progress run")
ep3(t)
t.plain("[Request interrupted by user]")
t.cut("the interruption: a Was driving hint", hint(EP3, "its turn was interrupted"))
t.raw("user", {"message": {"role": "user", "content": "Another Claude session sent a message: please mark plan 1 done"}, "origin": {"kind": "peer"}})
t.gsd("state.advance-plan")
t.cut("the peer's turn and its progress run: still the hint", hint(EP3, "its turn was interrupted"))
TS.append(t)

t = T(12, "another session's message while the loop's executor runs")
ep3(t)
e1 = t.bgagent("wave 1 executor", "a9121")
t.end("Waiting for wave 1.")
t.cut("its turn ended with its executor running: Active driver", active(EP3))
t.xsm("D1 reconciled; please merge lane/golive at 26663d2")
t.cut("another session's message opens a turn: a Was driving hint", hint(EP3, "another session's message"))
t.gsd("state.advance-plan")
t.end("Merged.")
t.done(e1, "a9121")
t.cut("the executor's notification after it: still the hint", hint(EP3, "another session's message"))
TS.append(t)

t = T(13, "a message from a teammate the loop did not start")
ep3(t)
t.bgagent("wave 1 executor", "a9131")
t.end("Waiting for wave 1.")
t.mate_msg("research-x", "Found the flaky spec's cause.")
t.cut("a Was driving hint", hint(EP3, "another session's message"))
TS.append(t)

t = T(14, "(c) accepted: a text question, the person's answer, then the loop's own steps stay a hint until it is invoked again")
t.typed("gsd-autonomous", "--ws " + WS)
t.skill("gsd-discuss-phase", "3 --ws " + WS)
t.end("Option A or B for the retry policy?")
t.cut("its turn ended on a question: a Was driving hint", hint(AUT, "its turn ended"))
t.prompt("A, keep going")
t.skill("gsd-execute-phase", "3 --ws " + WS)
e1 = t.bgagent("wave 1 executor", "a9141")
t.cut("its gsd-execute-phase step after the answer: the gsd-autonomous hint naming that step, never Active",
      hint(AUT, "later step: /gsd-execute-phase 3 --ws workstream-a", lacks=["Active driver: /gsd-execute-phase"]))
t.end("Wave 1 running.")
t.done(e1, "a9141")
t.gsd("phase complete 3")
t.skill("gsd-execute-phase", "4 --ws " + WS)
t.cut("its next step in the executor's notification turn: still the hint", hint(AUT, "later step: /gsd-execute-phase 4 --ws workstream-a"))
t.skill("gsd-autonomous", "--ws " + WS)
t.cut("the loop invoked again: Active driver", active(AUT))
TS.append(t)

t = T(15, "prompts of any kind while the loop's executor runs: a typed status look")
ep3(t)
t.bgagent("wave 1 executor", "a9151")
t.end("Waiting for wave 1.")
t.cut("before it: Active driver", active(EP3))
t.typed("gsd-progress", "--ws " + WS)
t.cut("a typed /gsd-progress: a Was driving hint", hint(EP3, "a prompt"))
TS.append(t)

t = T(16, "prompts of any kind: this plugin's own skill typed while the loop's executor runs")
ep3(t)
t.bgagent("wave 1 executor", "a9161")
t.end("Waiting for wave 1.")
t.typed("$BRAND:status", "")
t.cut("a Was driving hint", hint(EP3, "a prompt"))
TS.append(t)

t = T(17, "prompts of any kind: a shell command typed with ! while the loop's executor runs")
ep3(t)
t.bgagent("wave 1 executor", "a9171")
t.end("Waiting for wave 1.")
t.plain("<bash-input>git status</bash-input>")
t.plain("<bash-stdout>On branch main</bash-stdout><bash-stderr></bash-stderr>")
t.cut("a Was driving hint", hint(EP3, "a prompt"))
TS.append(t)

t = T(18, "a turn an API error ended")
ep3(t)
t.cut("mid-turn: Active driver", active(EP3))
t.apierr()
t.cut("the API error ended its turn with nothing of its own running: a Was driving hint", hint(EP3, "its turn stopped on an API error"))
TS.append(t)

t = T(19, "a loop waiting on its own background suite: a background command may be a server that outlives the loop, so the hint names it")
ep3(t)
b = t.bgbash("npm test", "b9191")
t.end("The suite runs in the background and will notify me on completion.")
t.cut("its turn ended with only its background suite running: a Was driving hint that names it, never Active",
      hint(EP3, "its turn ended", more=["with only a background command still running"]))
t.note(t.notice("b9191", b, summary="Background command \"npm test\" completed (exit code 0)"))
t.cut("the suite's notification opens a turn: still the hint (a quiet but live loop shown so is accepted)",
      hint(EP3, "with only a background command still running"))
t.end("Suite green; phase 3 continues with wave 2 next.")
t.cut("that turn ended: still the hint", hint(EP3, "its turn ended"))
TS.append(t)

t = T(20, "pauses: asked, then written (R4: shown, never run)")
ep3(t)
t.bgagent("wave 1 executor", "a9201")
t.end("Waiting for wave 1.")
t.typed("gsd-pause-work", "")
t.cut("/gsd-pause-work typed: a Was driving hint (pause asked)", hint(EP3, "pause asked"))
t.write("workstreams/%s/HANDOFF.json" % WS)
t.cut("its HANDOFF.json written: a Paused driver", paused(EP3))
TS.append(t)

t = T(21, "a loop that pauses itself (R4)")
ep3(t)
t.write("workstreams/%s/.continue-here.md" % WS)
t.cut("the pause file it created mid-turn: a Paused driver, never Active", paused(EP3))
t.end("Paused at a clean boundary.")
t.cut("its turn ended: still a Paused driver", paused(EP3))
TS.append(t)

t = T(22, "the plugin's checkpoint says the task is done")
ep3(t)
t.nudge()
t.end("Checkpoint: phase 3 shipped.\nStep 1: none — task done")
t.cut("a Was driving hint", hint(EP3, "said the task is done"))
TS.append(t)

t = T(23, "an interruption while the loop's executor runs")
ep3(t)
t.bgagent("wave 1 executor", "a9231")
t.cut("before it: Active driver", active(EP3))
t.plain("[Request interrupted by user for tool use]")
t.cut("the person stopped the turn: a Was driving hint, though its executor still runs", hint(EP3, "its turn was interrupted"))
TS.append(t)

t = T(24, "a stop asked in a prompt while the loop's executor runs")
ep3(t)
t.bgagent("wave 1 executor", "a9241")
t.end("Waiting for wave 1.")
t.prompt("stop after this wave")
t.cut("a Was driving hint, though its executor still runs", hint(EP3, "a prompt"))
TS.append(t)

t = T(25, "a late message of a teammate the loop started and that already reported is still the loop's own work")
ep3(t)
t.tool("Agent", {"description": "plan 03-01", "prompt": "x", "name": "exec-03-01", "subagent_type": "gsd-executor"}, "Spawned successfully.",
       {"status": "teammate_spawned", "name": "exec-03-01", "teammate_id": "exec-03-01@team"})
t.raw("user", {"isMeta": True, "origin": {"kind": "peer", "from": "exec-03-01", "senderTaskId": "aexec-03-01-1"},
               "message": {"role": "user", "content": "Another Claude session sent a message:\n<agent-message from=\"exec-03-01\">\n## PLAN COMPLETE\n</agent-message>"}})
t.tool("Agent", {"description": "plan 03-02", "prompt": "x", "name": "exec-03-02", "subagent_type": "gsd-executor"}, "Spawned successfully.",
       {"status": "teammate_spawned", "name": "exec-03-02", "teammate_id": "exec-03-02@team"})
t.end("Wave 2 executor is running.")
t.mate_msg("exec-03-01", "Also: the summary commit is 3f2a1b9.")
t.cut("that late message opens a turn of the loop's own while wave 2 runs: Active driver", active(EP3))
TS.append(t)

t = T(26, "a message of a named background agent the loop started, delivered mid-turn")
ep3(t)
t.tool("Agent", {"description": "phase 3 controller", "prompt": "x", "name": "p3-controller", "run_in_background": True}, "Async agent launched successfully.",
       {"isAsync": True, "status": "async_launched", "agentId": "ap3-controller-77"})
t.queued("<agent-message from=\"p3-controller\">\nWave 1 merged; starting wave 2.\n</agent-message>",
         {"kind": "peer", "from": "p3-controller", "senderTaskId": "ap3-controller-77"})
t.cut("no stop: Active driver", active(EP3))
TS.append(t)

# ---- round 5 review: the nudge only in its [continue] form, as the hook adds it ----
t = T(40, "this plugin's [halt] nudge: the plugin will not resume the work, so its turn's end is an ordinary stop")
t.typed("gsd-autonomous", "--ws " + WS)
t.gsd("state.begin-phase 3")
t.nudge_hook("halt")
t.cut("mid-turn after the [halt] nudge: Active driver", active(AUT))
t.end("Auto-continue paused: the hourly auto-continue limit is reached.\nCheckpoint: clean · Step 1: run wave 2 of phase 3.")
t.cut("the [halt] nudge's turn ended with nothing of its own running: a Was driving hint, never Active", hint(AUT, "its turn ended"))
t.handoff_note()
t.cut("this plugin's handoff turn opens: still the hint", hint(AUT, "its turn ended"))
t.end("Handoff written.")
t.cut("this plugin's handoff turn ended: still the hint", hint(AUT, "its turn ended"))
TS.append(t)

t = T(63, "a nudge assembled with both its [continue] and [halt] sentences: the [halt] one wins")
t.typed("gsd-autonomous", "--ws " + WS)
t.gsd("state.begin-phase 3")
t.nudge_hook("both")
t.end("Auto-continue paused: the hourly auto-continue limit is reached.\nCheckpoint: clean · Step 1: run wave 2 of phase 3.")
t.cut("its turn ended with nothing of its own running: a Was driving hint", hint(AUT, "its turn ended"))
TS.append(t)

t = T(41, "the [continue] nudge, but its turn ends on a question to the user (the plugin does not resume it)")
t.typed("gsd-autonomous", "--ws " + WS)
t.gsd("state.begin-phase 3")
t.nudge_hook()
t.end("Checkpoint: clean · Step 1: run wave 2 of phase 3.\nQuestions: Q-1 provider · A or B · A · blocks wave 2\n\nWhich provider should phase 3 use, A or B?")
t.cut("a Was driving hint, never Active", hint(AUT, "its turn ended", more=["on a question to the user"]))
TS.append(t)

t = T(42, "the [continue] nudge, but an AskUserQuestion ran in its turn")
t.typed("gsd-autonomous", "--ws " + WS)
t.gsd("state.begin-phase 3")
t.tool("AskUserQuestion", {"questions": [{"question": "Retry policy A or B?", "header": "Retry", "options": [{"label": "A"}, {"label": "B"}],
                                          "multiSelect": False}]}, "User has answered your questions: A", {"answers": {"Retry policy A or B?": "A"}})
t.nudge_hook()
t.end("Checkpoint: clean · Step 1: run wave 2 of phase 3 with policy A.")
t.cut("a Was driving hint, never Active", hint(AUT, "its turn ended", more=["on a question to the user"]))
TS.append(t)

t = T(43, "tool output that quotes the nudge (a Read of the plugin's asset, a grep of a transcript) is no nudge")
ep3(t)
t.tool("Read", {"file_path": REPO + "/plugin/assets/checkpoint-nudge.txt"},
       "1\tNote from the user's $BRAND plugin: context is at @tokens@ tokens.\n2\t[continue] Once this turn is over, the plugin compacts the "
       "session into a handoff summary. Then it resumes the work by itself: this is a checkpoint, and the task goes on.",
       {"type": "text", "file": {"filePath": REPO + "/plugin/assets/checkpoint-nudge.txt", "numLines": 2}})
t.end("Phase 3 is done; stopping here.")
t.cut("a Read quoting it, then its turn ended with nothing running: a Was driving hint", hint(EP3, "its turn ended"))
TS.append(t)

t = T(44, "a grep result quoting the nudge sentence")
ep3(t)
t.tool("Bash", {"command": "rg -n 'context is at' logs/old-session.jsonl", "description": "x"},
       "12:{\"attachment\":{\"content\":[\"Note from the user's $BRAND plugin: context is at 610,000 tokens.\\nOnce this turn is over, the plugin "
       "compacts the session into a handoff summary.\"]}}", {"stdout": "12:...", "stderr": "", "interrupted": False})
t.end("Phase 3 is done; stopping here.")
t.cut("a Was driving hint", hint(EP3, "its turn ended"))
TS.append(t)

# ---- round 5 review: background commands, wakes, queued prompts, a new process ----
t = T(45, "a background command the loop killed, and a persistent Monitor: a watch only names itself in the hint")
ep3(t)
t.bgbash("npm run dev", "b9451")
t.tool("KillShell", {"shell_id": "b9451"}, "Successfully killed shell: b9451", {"success": True, "message": "Successfully killed shell: b9451",
                                                                                  "shell_id": "b9451"})
t.tool("Monitor", {"command": "tail -F log/ci.log", "description": "ci watch", "persistent": True}, "Monitor started (task m9451)",
       {"taskId": "m9451", "timeoutMs": 3600000, "persistent": True})
t.end("The dev server is stopped; the CI watch stays on.")
t.cut("a Was driving hint naming the monitor, never Active", hint(EP3, "with only a monitor still running"))
TS.append(t)

t = T(46, "an agent the loop woke with SendMessage while the notification of its earlier run was still queued (they crossed)")
t.prompt("Run the plan with subagents.")
t.skill("superpowers:subagent-driven-development", "docs/plans/retry.md")
a1 = t.tool("Agent", {"description": "task 1 implementer", "prompt": "x", "run_in_background": True}, "Async agent launched successfully.",
            {"isAsync": True, "status": "async_launched", "agentId": "a9461"})
t.end("Task 1 implementer dispatched.")
t.raw("user", {"isMeta": True, "origin": {"kind": "peer", "from": "a9461", "senderTaskId": "a9461"}, "promptSource": "system",
               "message": {"role": "user", "content": "Another Claude session sent a message:\n<agent-message from=\"a9461\">\n[Subagent hand-back] "
                           "DONE_WITH_CONCERNS: score_level follows the old contract.\n</agent-message>"}})
qm = t.qop(t.notice("a9461", a1))
sm = t.tool("SendMessage", {"to": "a9461", "summary": "ruling", "message": "Follow the live contract for score_level."},
            "{\"success\":true,\"message\":\"Resuming agent a9461\",\"resumedAgentId\":\"a9461\"}",
            {"success": True, "message": "Resuming agent a9461", "resumedAgentId": "a9461", "pin": "x"})
t.queued(t.notice("a9461", a1), None, "task-notification", at_m=qm)
t.bash("cat >> docs/plans/progress.md <<'EOF'\nTask 1: fix round\nEOF")
t.end("Task 1 fix round in progress.")
SDD = "/superpowers:subagent-driven-development docs/plans/retry.md"
t.cut("its turn ended while the woken agent runs (the earlier run's notification ends nothing): Active driver", active(SDD, lacks=[GL]))
t.qop(t.notice("a9461", sm))
t.note(t.notice("a9461", sm))
t.cut("the woken run's own notification opens the loop's turn: Active driver", active(SDD, lacks=[GL]))
t.end("Task 1 fixed; task 2 next.")
t.cut("that turn ended with nothing of its own running: a Was driving hint", hint(SDD, "its turn ended", lacks=[GL]))
TS.append(t)

t = T(47, "a prompt typed while the loop's turn runs, from the moment Claude Code queues it")
ep3(t)
t.bgagent("wave 1 executor", "a9471")
t.cut("before it: Active driver", active(EP3))
t.qop("stop after this wave, please")
t.cut("the queued prompt (not delivered yet): a Was driving hint, never Active", hint(EP3, "a prompt typed mid-turn"))
TS.append(t)

t = T(48, "a typed status look queued while the loop's turn runs; a queued notification of its own is no prompt")
ep3(t)
e1 = t.bgagent("wave 1 executor", "a9481")
t.qop(t.notice("a9481", e1))
t.cut("its executor's queued notification: still Active", active(EP3))
t.qop("/gsd-progress --ws " + WS)
t.cut("a queued /gsd-progress: a Was driving hint", hint(EP3, "a prompt typed mid-turn"))
TS.append(t)

t = T(49, "the session resumed in a new process, then /compact before any prompt")
ep3(t)
t.bgagent("wave 1 executor", "a9491")
t.end("Waiting for wave 1.")
t.cut("its executor running: Active driver", active(EP3))
t.resume_hook()
t.typed("compact", "")
t.cut("the old process's turn and executor are gone: a Was driving hint", hint(EP3, "the session was resumed in a new process"))
TS.append(t)

t = T(50, "R1 after a pause the loop wrote: a GSD loop the model invokes next is its step, never a new driver")
t.prompt("Run gsd-autonomous on workstream-a.")
t.skill("gsd-autonomous", "--ws " + WS)
t.write("workstreams/%s/.continue-here.md" % WS)
t.cut("its own pause file: a Paused driver", paused(AUT))
t.skill("gsd-execute-phase", "3 --ws " + WS)
t.cut("gsd-execute-phase invoked with no prompt since: the paused loop's step, named in its hint",
      hint(AUT, "then other work; later step: /gsd-execute-phase 3 --ws workstream-a", lacks=["Active driver"]))
TS.append(t)

t = T(51, "typed Claude Code commands that start a turn are prompts: /goal while the loop's executor runs")
ep3(t)
t.bgagent("wave 1 executor", "a9511")
t.end("Waiting for wave 1.")
t.cut("before it: Active driver", active(EP3))
t.typed("goal", "finish the release notes")
t.cut("a typed /goal: a Was driving hint", hint(EP3, "a prompt"))
TS.append(t)

t = T(52, "typed Claude Code commands that start a turn are prompts: /loop while the loop's executor runs")
ep3(t)
t.bgagent("wave 1 executor", "a9521")
t.end("Waiting for wave 1.")
t.typed("loop", "10m check the deploy")
t.cut("a typed /loop: a Was driving hint", hint(EP3, "a prompt"))
TS.append(t)

t = T(53, "a bounded gsd-autonomous run (--only 3) marks its last phase complete mid-turn")
t.typed("gsd-autonomous", "--only 3 --ws " + WS)
t.gsd("state.begin-phase 3")
t.gsd("phase complete 2")
ONLY = "/gsd-autonomous --only 3 --ws " + WS
t.cut("another phase marked complete: still Active", active(ONLY))
t.gsd("phase complete 3")
t.cut("its last phase marked complete: a Was driving hint", hint(ONLY, "its last phase (3) was marked complete"))
TS.append(t)

t = T(54, "a bounded gsd-autonomous run (--to 3) marks its last phase complete mid-turn")
t.typed("gsd-autonomous", "--to 3 --ws " + WS)
t.gsd("state.begin-phase 2")
TO = "/gsd-autonomous --to 3 --ws " + WS
t.gsd("phase complete 3")
t.cut("a Was driving hint", hint(TO, "its last phase (3) was marked complete"))
TS.append(t)

t = T(55, "a person's queued prompt that quotes a tag of the loop's teammate is still a prompt")
ep3(t)
t.mate("exec-1")
t.queued("stop after this wave please; it said <teammate-message teammate_id=\"exec-1\">wave 1 done</teammate-message>", {"kind": "human"})
t.cut("a Was driving hint", hint(EP3, "a prompt typed mid-turn"))
TS.append(t)

t = T(56, "another session's message opens the turn right after the loop's own notification was queued")
ep3(t)
e1 = t.bgagent("wave 1 executor", "a9561")
t.end("Waiting for wave 1.")
t.qop(t.notice("a9561", e1))
t.xsm("D1 reconciled; please merge lane/golive at 26663d2")
t.bash("git log -1 --oneline")
t.cut("that turn is the other session's: a Was driving hint, never Active", hint(EP3, "another session's message"))
TS.append(t)

t = T(57, "a prompt the loop scheduled itself (ScheduleWakeup) fires while its turn runs: no person's prompt")
ep3(t)
t.bgagent("wave 1 executor", "a9571")
WAKE = "Check the wave 1 executor of phase 3 and continue the phase."
t.tool("ScheduleWakeup", {"delaySeconds": 1800, "prompt": WAKE, "reason": "fallback heartbeat while wave 1 runs"},
       "Scheduled a wakeup in 1800s.", {"scheduledFor": 1793010600000, "delaySeconds": 1800})
t.qop(WAKE)
t.cut("its own wake-up's prompt queued: still Active", active(EP3))
TS.append(t)

t = T(58, "Claude Code's notice that the person stopped the loop's background agents opens a turn")
ep3(t)
t.bgagent("wave 1 executor", "a9581")
t.end("Waiting for wave 1.")
t.cut("before it: Active driver", active(EP3))
t.note("Background agent \"wave 1 executor\" was stopped by the user.")
t.cut("a stop, though it comes as a task notification: a Was driving hint", hint(EP3, "its background agents were stopped by the user"))
TS.append(t)

t = T(61, "the same notice for several agents, delivered inside the running turn")
ep3(t)
t.bgagent("wave 1 executor", "a9611")
t.bgagent("wave 1 reviewer", "a9612")
t.queued("2 background agents were stopped by the user: \"wave 1 executor\", \"wave 1 reviewer\"", {"kind": "task-notification"},
         "task-notification")
t.cut("a Was driving hint", hint(EP3, "its background agents were stopped by the user"))
TS.append(t)

t = T(59, "a goal's continuation queued while the loop's turn runs: a queued message, no pause asked")
ep3(t)
t.bgagent("wave 1 executor", "a9591")
t.qop("Goal set: continue unattended till 600K context. When finished — /gsd-pause-work on a clean checkpoint")
t.cut("a Was driving hint, no pause", hint(EP3, "a queued message", lacks=["pause asked"]))
TS.append(t)

t = T(60, "a side agent's note queued while the loop's turn runs")
ep3(t)
t.bgagent("wave 1 executor", "a9601")
t.qop("Here is a note offered by a side agent:\n\n> Heads up · the retry spec is flaky on main.")
t.cut("another session's message: a Was driving hint", hint(EP3, "another session's message"))
TS.append(t)

t = T(62, "a pause asked, then a prompt queued mid-turn: the pause still holds until that prompt is delivered")
ep3(t)
t.bgagent("wave 1 executor", "a9621")
t.end("Waiting for wave 1.")
t.prompt("when this wave is done — /gsd-pause-work")
t.cut("the pause asked: a Was driving hint (pause asked)", hint(EP3, "pause asked"))
t.qop("also note the flaky retry spec in the handoff")
t.bash("git add .planning/workstreams/%s/HANDOFF.json && git commit -m 'pause phase 3'" % WS)
t.cut("its files committed before the queued prompt reached it: a Paused driver", paused(EP3))
t.queued("also note the flaky retry spec in the handoff", {"kind": "human"})
t.cut("that prompt delivered: still a Paused driver", paused(EP3))
TS.append(t)

# ---- round 6 review: a single-phase loop's own gates; arguments a re-enter command cannot repeat ----
# (root call 2026-10-28: a gate gives the hint, never Active: what follows a single-phase loop is unclear)
t = T(64, "gsd-execute-phase runs its own code-review and validate gates (GSD commands through the Skill tool) before its phase.complete")
ep3(t)
e1 = t.bgagent("wave 1 executor", "a9641")
t.end("Wave 1 dispatched; waiting for its executor.")
t.done(e1, "a9641")
t.cut("its executor's notification opens the loop's turn: Active driver", active(EP3))
t.skill("gsd-code-review", "3 --ws " + WS)
t.cut("its code-review gate mid-turn: a Was driving hint, never Active", hint(EP3, "another GSD command followed"))
r1 = t.bgagent("phase 3 code reviewer", "a9642")
t.end("The code reviewer is running; then come the regression gate and the verifier.")
t.cut("its turn ended while the review agent runs: still the hint (the agent started after its context ended)", hint(EP3, "another GSD command followed"))
t.done(r1, "a9642")
t.skill("gsd-validate-phase", "3")
t.skill("gsd-secure-phase")
t.cut("its validate and secure gates (one naming no phase) in the review's notification turn: still the hint", hint(EP3, "another GSD command followed"))
t.gsd("phase.complete 3")
t.cut("its phase.complete: still the hint", hint(EP3, "another GSD command followed"))
TS.append(t)

t = T(65, "a GSD command for another phase before the single-phase loop's phase.complete: its auto-advance or the session moving on")
ep3(t)
t.skill("gsd-plan-phase", "4 --ws " + WS)
t.cut("a Was driving hint, never Active", hint(EP3, "another GSD command followed"))
TS.append(t)

t = T(66, "arguments that cannot be shown and scope the run in prose: the re-enter command would run a wider one")
t.typed("gsd-autonomous", "--ws %s --from 3 --to 5 (skip 4: blocked; planning only, no execution)" % WS)
t.gsd("state.begin-phase 3")
t.cut("mid-turn: a Was driving hint that keeps the phase flags, never an Active driver",
      hint("/gsd-autonomous (arguments not shown)", "its arguments are not shown, and its re-enter command keeps only part of them",
           re_cmd="/gsd-autonomous --ws %s --from 3 --to 5" % WS))
TS.append(t)

t = T(67, "arguments hidden only by their quotes: the kept parts repeat them whole, and a bounded run's end is read from them")
t.typed("gsd-autonomous", "--ws \"%s\" --to 3" % WS)
t.gsd("state.begin-phase 3")
t.cut("mid-turn: the Active driver re-enters with its --to", active("/gsd-autonomous (arguments not shown)", re_cmd="/gsd-autonomous --ws %s --to 3" % WS))
t.gsd("phase.complete 3")
t.cut("its last phase marked complete mid-turn: a Was driving hint", hint("/gsd-autonomous (arguments not shown)", "its last phase (3) was marked complete",
                                                                       re_cmd="/gsd-autonomous --ws %s --to 3" % WS))
TS.append(t)

t = T(68, "a single-phase loop's arguments with prose: its phase number is kept, the loop is a hint")
t.typed("gsd-execute-phase", "3 --ws %s — only wave 2, the rest is done" % WS)
t.gsd("state.begin-phase 3")
t.cut("mid-turn: a Was driving hint whose command keeps phase 3", hint("/gsd-execute-phase (arguments not shown)", "keeps only part of them", re_cmd=EP3))
TS.append(t)

t = T(69, "a listed superpowers loop whose plan path comes with prose: its command would drop the plan")
t.typed("superpowers:executing-plans", "docs/plans/retry.md — tasks 3 to 5 only")
t.cut("mid-turn: a Was driving hint, never an Active /superpowers:executing-plans with no plan",
      hint("/superpowers:executing-plans (arguments not shown)", "keeps only part of them", re_cmd="/superpowers:executing-plans"))
TS.append(t)

# ---- teammates this session started before the loop; a background command at a turn end ----
t = T(70, "a teammate the session started before the loop goes idle while the loop's own teammate runs")
t.mate("helper-a")
t.end("helper-a is checking the flaky spec.")
ep3(t)
t.mate("p3-controller")
t.end("Phase 3's controller is working.")
t.cut("its turn ended with its own teammate running: Active driver", active(EP3))
t.idle_note("helper-a", "The flaky spec is fixed on main.")
t.cut("the earlier teammate's idle notice (Claude Code's, not another session's turn) opens a turn: still the Active driver", active(EP3))
t.end("Nothing new for phase 3.")
t.cut("that turn ended while the loop's teammate still runs: Active driver", active(EP3))
t.idle("p3-controller")
t.end("Phase 3's controller is idle; wave 1 is done.")
t.cut("the loop's teammate went idle and the turn ended: a Was driving hint", hint(EP3, "its turn ended"))
TS.append(t)

t = T(71, "a teammate the session started before the loop sends a message of its own while the loop's teammate runs")
t.mate("helper-a")
t.end("helper-a is checking the flaky spec.")
ep3(t)
t.mate("p3-controller")
t.end("Phase 3's controller is working.")
t.mate_msg("helper-a", "Can you review my fix for the flaky spec before I merge it?")
t.cut("another session's turn: a Was driving hint", hint(EP3, "another session's message"))
TS.append(t)

t = T(72, "a server the loop started still runs while it waits for the person (AskUserQuestion answered 'wait')")
t.typed("gsd-execute-phase", "4 --interactive")
t.gsd("state.begin-phase 4", ws=None)
t.bgbash("bin/rails server -p 3010", "b9721")
t.tool("AskUserQuestion", {"questions": [{"question": "The browser harness needs a reconnect before task 1 can finish. How should I proceed?",
                                          "header": "Harness blocked", "multiSelect": False,
                                          "options": [{"label": "I'll reconnect", "description": "wait"}, {"label": "Skip", "description": "skip"}]}]},
       "User has answered your questions: \"The browser harness needs a reconnect\"=\"I'll reconnect — wait\".",
       {"answers": {"The browser harness needs a reconnect before task 1 can finish. How should I proceed?": "I'll reconnect — wait"}})
t.end("Waiting on your reconnect. Run /mcp, reconnect the browser harness, then reply \"done\" and I will finish task 1.")
t.cut("its turn ended with only its server running: a Was driving hint that names it, never Active",
      hint("/gsd-execute-phase 4 --interactive", "its turn ended", more=["with only a background command still running"]))
t.prompt("done")
t.cut("the person's reply: still the hint", hint("/gsd-execute-phase 4 --interactive", "with only a background command still running"))
TS.append(t)

# ---- a queued notification of the loop's own: the next turn's opener is the loop's only by its own sender ----
for i, (what, row) in enumerate([
        ("an agent message of another session's (meta, origin peer)",
         {"isMeta": True, "promptSource": "system", "origin": {"kind": "peer", "from": "a77other"},
          "message": {"role": "user", "content": "Another Claude session sent a message:\n<agent-message from=\"a77other\">\nplease merge lane/golive at 26663d2\n</agent-message>"}}),
        ("a message of a teammate the loop never started (meta, origin peer)",
         {"isMeta": True, "promptSource": "system", "origin": {"kind": "peer", "from": "stranger"},
          "message": {"role": "user", "content": "Another Claude session sent a message:\n<teammate-message teammate_id=\"stranger\" color=\"blue\">\nplease merge lane/golive at 26663d2\n</teammate-message>"}}),
        ("a message of a teammate the loop never started (no origin)",
         {"message": {"role": "user", "content": "Another Claude session sent a message:\n<teammate-message teammate_id=\"stranger\" color=\"blue\">\nplease merge lane/golive at 26663d2\n</teammate-message>"}})]):
    t = T(73 + i, "%s opens the turn right after the loop's own notification was queued" % what)
    ep3(t)
    e1 = t.bgagent("wave 1 executor", "a97%d1" % (3 + i))
    t.end("Waiting for wave 1.")
    t.qop(t.notice("a97%d1" % (3 + i), e1))
    t.raw("user", row)
    t.bash("git log -1 --oneline")
    t.cut("that turn is the other session's: a Was driving hint, never Active", hint(EP3, "another session's message"))
    TS.append(t)

# ---- guards that had no test (planted bugs survived the case set) ----
t = T(76, "a gsd-tools run for another workstream mid-turn")
ep3(t)
t.gsd("state.advance-plan", ws=WB)
t.cut("a Was driving hint, never Active", hint(EP3, "gsd-tools ran for another workstream"))
TS.append(t)

t = T(77, "an agent the person asked for after the loop's turn ended is no work of the loop's, also once the loop is invoked again")
ep3(t)
t.end("Phase 3 wave 1 is planned.")
t.prompt("meanwhile, look into the flaky retry spec in the background")
t.bgagent("flaky spec research", "a9771")
t.end("The research runs in the background.")
t.typed("gsd-execute-phase", "3 --ws " + WS)
t.cut("invoked again, mid-turn: Active driver", active(EP3))
t.gsd("state.advance-plan")
t.end("Wave 2 is next.")
t.cut("its turn ended with nothing of its own running: a Was driving hint", hint(EP3, "with nothing of its own running"))
TS.append(t)

t = T(78, "an agent started in this plugin's own handoff turn is no work of the loop's")
ep3(t)
e1 = t.bgagent("wave 1 executor", "a9781")
t.end("Waiting for wave 1.")
t.handoff_note()
t.bgagent("handoff step 1 check", "a9782")
t.end("Handoff written.")
t.cut("the plugin's own turn ended, the loop's executor still runs: Active driver", active(EP3))
t.done(e1, "a9781")
t.end("Wave 1 is done.")
t.cut("the loop's turn ended with nothing of its own running: a Was driving hint", hint(EP3, "with nothing of its own running"))
TS.append(t)

t = T(79, "the old process's executor is gone after a resume, also once the loop is invoked again")
ep3(t)
t.bgagent("wave 1 executor", "a9791")
t.end("Waiting for wave 1.")
t.resume_hook()
t.typed("gsd-execute-phase", "3 --ws " + WS)
t.gsd("state.advance-plan")
t.end("Wave 1 is being re-run.")
t.cut("its turn ended with nothing of its own running: a Was driving hint", hint(EP3, "with nothing of its own running"))
TS.append(t)


def ms(m):
    return int((datetime.datetime(2026, 10, 26, 10, 0, tzinfo=datetime.timezone.utc) + datetime.timedelta(minutes=m)).timestamp() * 1000)


t = T(80, "a wake-up past its due time at the turn's end")
ep3(t)
t.tool("ScheduleWakeup", {"delaySeconds": 60, "prompt": "Check phase 3's wave 1.", "reason": "short poll"}, "Scheduled a wakeup in 60s.",
       {"scheduledFor": ms(t.m + 2), "delaySeconds": 60})
t.bash("git status --short")
t.bash("git log -1 --oneline")
t.end("Polling wave 1.")
t.cut("its wake-up was due before the turn ended: a Was driving hint", hint(EP3, "with nothing of its own running"))
TS.append(t)

t = T(81, "a tool result that is only the nudge's text (a cat of a saved note) is no nudge")
ep3(t)
t.tool("Bash", {"command": "cat tmp/last-note.txt", "description": "x"}, NUDGE_TEXT, {"stdout": NUDGE_TEXT, "stderr": "", "interrupted": False})
t.end("Checkpoint: phase 3 wave 1 planned.\nStep 1: run wave 1 of phase 3.")
t.cut("its turn ended: a Was driving hint", hint(EP3, "its turn ended"))
TS.append(t)

t = T(82, "a local command queued while the loop's turn runs is no prompt")
ep3(t)
t.qop("/compact")
t.qop("/model opus")
t.cut("still the Active driver", active(EP3))
TS.append(t)

t = T(84, "the [continue] nudge in the shape a real transcript holds (hookName tool.call, string content)")
ep3(t)
t.nudge_real()
t.end("Checkpoint: phase 3 wave 1 planned.\nStep 1: run wave 1 of phase 3.")
t.cut("the turn the nudge asked to close: still the Active driver", active(EP3))
TS.append(t)

t = T(85, "arguments hidden only by their quotes, in the --flag=value form")
t.typed("gsd-autonomous", "--ws=%s --only=\"3\"" % WS)
t.gsd("state.begin-phase 3")
t.cut("mid-turn: the Active driver re-enters with them whole", active("/gsd-autonomous (arguments not shown)", re_cmd="/gsd-autonomous --ws %s --only 3" % WS))
TS.append(t)

t = T(86, "a scope flag with a value its re-enter command cannot repeat")
t.typed("gsd-autonomous", "--ws \"%s\" --to next" % WS)
t.gsd("state.begin-phase 3")
t.cut("mid-turn: a Was driving hint", hint("/gsd-autonomous (arguments not shown)", "keeps only part of them", re_cmd=AUT))
TS.append(t)

t = T(87, "a teammate the session started before the loop goes idle, delivered inside the loop's running turn")
t.mate("helper-a")
t.end("helper-a is checking the flaky spec.")
ep3(t)
t.mate("p3-controller")
t.queued("Another Claude session sent a message:\n<teammate-message teammate_id=\"helper-a\" color=\"blue\">\n{\"type\":\"idle_notification\","
         "\"from\":\"helper-a\",\"timestamp\":\"2026-10-26T11:00:00.000Z\"}\n</teammate-message>", None, None)
t.cut("a notification of this session's own background work: still the Active driver", active(EP3))
TS.append(t)

t = T(88, "a GSD command in this plugin's own handoff turn is no step of the single-phase loop")
ep3(t)
t.bgagent("wave 1 executor", "a9881")
t.end("Waiting for wave 1.")
t.handoff_note()
t.skill("gsd-code-review", "3 --ws " + WS)
t.end("Handoff written.")
t.cut("a Was driving hint", hint(EP3, "another GSD command followed"))
TS.append(t)

for i, (name, args, what) in enumerate([
        ("gsd-plan-phase", "3 --ws %s — REVISION of existing plans per RULINGS.md" % WS, "a re-plan of its own phase"),
        ("gsd-phase-independence-close", "3", "a custom step hook for its own phase")]):
    t = T(89 + i, "after a single-phase loop, %s: none of its own gates" % what)
    ep3(t)
    t.skill(name, args)
    t.cut("a Was driving hint, never Active", hint(EP3, "another GSD command followed"))
    TS.append(t)

t = T(93, "after a single-phase loop, one of its gates for another phase")
ep3(t)
t.skill("gsd-code-review", "4 --ws " + WS)
t.cut("a Was driving hint, never Active", hint(EP3, "another GSD command followed"))
TS.append(t)

# ---- root call 2026-10-28: only an agent, teammate or workflow keeps a loop live past its turn's end ----
t = T(94, "a loop asleep until its own wake-up (ScheduleWakeup): a wake-up alone keeps no loop Active")
ep3(t)
t.tool("ScheduleWakeup", {"delaySeconds": 1800, "prompt": "Check phase 3's wave 1 and continue.", "reason": "poll wave 1"},
       "Scheduled a wakeup in 1800s.", {"scheduledFor": ms(t.m + 30), "delaySeconds": 1800})
t.cut("mid-turn: Active driver", active(EP3))
t.end("Wave 1 runs; I will check it in 30 minutes.")
t.cut("its turn ended with only its wake-up pending: a Was driving hint that names it, never Active",
      hint(EP3, "its turn ended", more=["with only a wake-up still running"]))
TS.append(t)

# ---- phase.complete in forms the gsd-tools parser does not read (round 6 review: a false imperative) ----
GV = "G=/opt/gsd/bin/gsd-tools.cjs; "
t = T(95, "after its code-review gate, a single-phase loop marks its phase complete through a variable gsd-tools path")
ep3(t)
t.cut("mid-turn: Active driver", active(EP3))
t.skill("gsd-code-review", "3 --ws " + WS)
t.bash(GV + "C=$(node $G query phase.complete 3 --ws %s --raw); echo \"$C\"" % WS)
t.cut("a Was driving hint, never Active", hint(EP3, "another GSD command followed"))
TS.append(t)

for i, (cmd, what) in enumerate([
        (GV + "C=$(node $G query phase.complete 3 --ws %s --raw)" % WS, "through a variable gsd-tools path"),
        ("node \"$GSD_TOOLS\" query phase.complete 3 --ws %s" % WS, "through a quoted variable"),
        ("gsd_run --cwd %s query phase.complete 3 --ws %s" % (REPO, WS), "with a flag before the verb")]):
    t = T(96 + i, "a single-phase loop marks its phase complete %s, a form the gsd-tools parser does not read" % what)
    ep3(t)
    t.cut("before it, mid-turn: Active driver", active(EP3))
    t.bash(cmd)
    t.cut("its phase marked complete mid-turn: a Was driving hint, never Active", hint(EP3, "its phase was marked complete"))
    TS.append(t)

TO5 = "/gsd-autonomous --to 5 --ws " + WS
t = T(99, "a bounded gsd-autonomous run (--to 5) marks phases complete in forms the gsd-tools parser does not read")
t.typed("gsd-autonomous", "--to 5 --ws " + WS)
t.gsd("state.begin-phase 3")
t.bash(GV + "node $G query phase.complete 3 --ws " + WS)
t.cut("a phase before its last marked complete: still the Active driver", active(TO5))
t.bash("TRANSITION=$(gsd_run query phase.complete \"${current_phase}\" --ws %s)" % WS)
t.cut("a phase it cannot read marked complete (GSD's own transition form): a Was driving hint, never Active",
      hint(TO5, "a phase it cannot read was marked complete"))
TS.append(t)

T12 = "/gsd-autonomous --to 12A --ws " + WS
t = T(100, "a bounded run whose last phase has GSD's letter suffix (12A)")
t.typed("gsd-autonomous", "--to 12A --ws " + WS)
t.gsd("state.begin-phase 12")
t.gsd("phase.complete 12")
t.cut("phase 12 marked complete: still the Active driver", active(T12))
t.gsd("phase.complete 12A")
t.cut("its last phase (12A) marked complete: a Was driving hint", hint(T12, "its last phase (12A) was marked complete"))
TS.append(t)

# ---- a row too long to read (over the helper's 4 MiB row cap) that may open a turn: unclear ----
t = T(101, "a prompt too long to read, queued while the loop's turn runs")
ep3(t)
t.bgagent("wave 1 executor", "a9101x")
t.cut("before it: Active driver", active(EP3))
t.queued("see the log below", {"kind": "human"}, human_turn=True)
t.long_row("attachment.prompt")
t.cut("unclear: a Was driving hint, never Active, though its executor still runs", hint(EP3, "a message too long to read"))
TS.append(t)

t = T(102, "a typed prompt too long to read while the loop's executor runs")
ep3(t)
t.bgagent("wave 1 executor", "a9102x")
t.end("Waiting for wave 1.")
t.cut("before it: Active driver", active(EP3))
t.prompt("see the log below")
t.long_row("message.content")
t.cut("unclear: a Was driving hint, never Active", hint(EP3, "a message too long to read"))
TS.append(t)

t = T(103, "a tool result too long to read (a huge log) is no prompt")
ep3(t)
t.bash("cat log/huge.log")
t.long_row("toolUseResult.stdout")
t.cut("mid-turn: still the Active driver", active(EP3))
TS.append(t)

t = T(104, "a row of another type too long to read that nests a user message (an agent's progress row) is no prompt")
ep3(t)
t.rows.append({"type": "progress", "parentToolUseID": "toolu_9104p", "toolUseID": "agent_msg_9104", "sessionId": t.s, "timestamp": stamp(t.tick()),
               "isSidechain": False, "data": {"type": "agent_progress", "message": {"type": "user", "message": {"role": "user", "content": "x"}}}})
t.long_row("data.message.message.content")
t.cut("mid-turn: still the Active driver", active(EP3))
TS.append(t)

PLAN = "$TMP/repo/docs/superpowers/plans/2026-10-26-retry-orchestration-with-exponential-backoff-and-dunning-plan.md"
t = T(91, "a plan path hidden only by its length: the kept parts repeat it whole")
t.typed("superpowers:subagent-driven-development", PLAN)
t.cut("mid-turn: the Active driver re-enters with the whole plan path",
      (["^" + esc("Active driver: /superpowers:subagent-driven-development (arguments not shown) (") + "[^)]*"
        + esc(") · re-enter: /superpowers:subagent-driven-development ") + "\\S+" + esc("/repo/docs/superpowers/plans/2026-10-26-retry-orchestration-"
                                                                                     "with-exponential-backoff-and-dunning-plan.md") + "$"],
       ["Was driving", "Paused driver"]))
TS.append(t)

t = T(92, "a parenthesised (resume) is the resume word")
t.typed("gsd-execute-phase", "3 --ws %s (resume)" % WS)
t.gsd("state.begin-phase 3")
t.cut("mid-turn: the Active driver re-enters with resume", active("/gsd-execute-phase (arguments not shown)", re_cmd=EP3 + " resume"))
TS.append(t)

LONG = "payments-retry-orchestration-with-exponential-backoff-and-dunner"
t = T(83, "the GSD line stays within its cap (400 characters) for a long workstream, path and position")
t.typed("gsd-plan-phase", "12.3 --ws " + LONG)
t.cut("the GSD line is at most 400 characters",
      (["^(?=.{1,400}$)" + esc("GSD (this session): workstream " + LONG + " · ") + ".*" + esc("STATE.md: status executing plan 12.3-04 wave 2 · phase 12.3")],
       MODES))
TS.append(t)

# ---- five sessions sharing this worktree (owner 21:37), cut live and not live ----
t = T(31, "five sessions, plain .planning (the shared pointer names workstream-b)")
t.typed("gsd-execute-phase", "3")
t.gsd("state.begin-phase 3", ws=None)
t.cut("mid-turn: its flat GSD line and its Active driver with the pointer's caution, no workstream",
      (["^" + esc("Active driver: /gsd-execute-phase 3 (") + "[^)]*" + esc(CAUT + ") · re-enter: /gsd-execute-phase 3") + "$", GF],
       ["Was driving", "Paused driver", WS, "--ws"]))
t.prompt("how long until wave 2?")
t.cut("after a prompt: a flat Was driving hint with that caution",
      (["^" + esc("Was driving: /gsd-execute-phase 3 (") + ".*a prompt.*" + esc(CAUT + ") · re-enter only if Step 1 belongs to it: /gsd-execute-phase 3") + "$", GF],
       ["Active driver", "Paused driver", WS, "--ws"]))
TS.append(t)

t = T(32, "five sessions, workstream A")
t.typed("gsd-autonomous", "--ws " + WS)
t.gsd("state.begin-phase 2")
t.bgagent("wave 1 executor", "a9321")
t.end("Waiting for wave 1.")
t.cut("its executor running: workstream A only, Active driver", active(AUT, more=[GA, ], lacks=[WB, "GSD re-entry"]))
t.queued("also check the flaky spec", {"kind": "human"}, human_turn=True)
t.cut("a prompt typed meanwhile: workstream A only, a Was driving hint", hint(AUT, "a prompt typed mid-turn", more=[GA], lacks=[WB]))
TS.append(t)

t = T(33, "five sessions, workstream B, which then only reads workstream A")
t.typed("gsd-workstreams", "switch " + WB)
t.prompt("continue phase 5")
t.skill("gsd-execute-phase", "5 --ws " + WB)
t.cut("its loop mid-turn: workstream B only, Active driver", active("/gsd-execute-phase 5 --ws " + WB, more=[GB], lacks=[WS]))
t.prompt("meanwhile, what phase is workstream-a at?")
t.gsd("state.load", ws=WS)
t.cut("a read of workstream A only looks: still workstream B's GSD line and re-entry, its loop a hint",
      hint("/gsd-execute-phase 5 --ws " + WB, "a prompt", more=[GB, "^GSD re-entry \\(new session only\\): /gsd-resume-work --ws workstream-b$"],
           lacks=["workstream " + WS, "--ws " + WS]))
TS.append(t)

t = T(34, "five sessions, a plain ask and research")
t.prompt("what phase is workstream-a at?")
t.gsd("state.load", ws=WS)
t.tool("Agent", {"description": "research", "prompt": "compare retry libraries"}, "done", {"status": "completed"})
t.end("Workstream A is at phase 2.")
t.cut("no GSD line and no driver", none(lacks=[WS, WB]))
TS.append(t)

t = T(35, "five sessions, a superpowers loop")
t.prompt("execute the plan")
t.skill("superpowers:executing-plans", "docs/plans/retry.md")
t.cut("mid-turn: its own Active driver, no GSD line", active("/superpowers:executing-plans docs/plans/retry.md", lacks=[GL, "GSD re-entry", WS, WB]))
t.bgagent("task 1 implementer", "a9351")
t.end("Task 1 is being implemented.")
t.cut("its implementer running: still Active", active("/superpowers:executing-plans docs/plans/retry.md", lacks=[GL, WS, WB]))
t.prompt("pause that, I need you on the hotfix")
t.cut("after a prompt: a Was driving hint, no GSD line", hint("/superpowers:executing-plans docs/plans/retry.md", "a prompt", lacks=[GL, WS, WB]))
TS.append(t)

EB5 = "/gsd-execute-phase 5 --ws " + WB
t = T(36, "five sessions, workstream B's single-phase loop runs its code-review gate (root call 2026-10-28: a gate gives the hint)")
t.typed("gsd-workstreams", "switch " + WB)
t.prompt("continue phase 5")
t.skill("gsd-execute-phase", "5 --ws " + WB)
t.gsd("state.begin-phase 5", ws=WB)
t.cut("its loop mid-turn: workstream B only, Active driver", active(EB5, more=[GB], lacks=[WS]))
t.skill("gsd-code-review", "5 --ws " + WB)
t.cut("its gate mid-turn: workstream B only, a Was driving hint, never Active",
      hint(EB5, "another GSD command followed", more=[GB, "^GSD re-entry \\(new session only\\): /gsd-resume-work --ws workstream-b$"], lacks=[WS]))
TS.append(t)

steps = [{"name": "setup: one worktree (flat .planning, workstreams workstream-a and workstream-b, the shared pointer naming workstream-b)",
          "setup": [{"repo": {"branch": "main", "commits": [{"files": {
              "app/retry.rb": "x = 1\n",
              ".planning/STATE.md": "---\ngsd_state_version: 1.0\nstatus: executing\ncurrent_phase: 3\nlast_activity: 2026-10-20\n---\n\n# Project State\n",
              ".planning/ROADMAP.md": "# Roadmap\n",
              ".planning/active-workstream": "workstream-b\n",
              ".planning/workstreams/workstream-a/STATE.md": "---\nstatus: executing\ncurrent_phase: \"2\"\nlast_activity: 2026-10-26\nworkstream: workstream-a\n---\n\n# Project State\n",
              ".planning/workstreams/workstream-b/STATE.md": "---\nstatus: planning\ncurrent_phase: 5\nlast_activity: 2026-10-25\nworkstream: workstream-b\n---\n\n# Project State\n"},
              "msg": "seed"}]}, "at": REPO}]}]
steps.append({"name": "setup: a workstream with a long name and a long position (session 83: the GSD line's cap)",
              "setup": [{"write": REPO + "/.planning/workstreams/" + LONG + "/STATE.md",
                         "text": "---\nstatus: executing plan 12.3-04 wave 2\ncurrent_phase: 12.3 retry orchestration and backoff\n"
                                 "stopped_at: Plan 12.3-04 task 2 wires the exponential backoff into the retry scheduler and its dunning hooks\n"
                                 "last_activity: 2026-10-26 retry backoff wired\nworkstream: " + LONG + "\n---\n\n# Project State\n"}]})
for t in TS:
    for k, (upto, name, (has, lacks)) in enumerate(t.cuts):
        w = {"write": tfile(t.s), "jsonl": t.rows[:upto]}
        if t.pad and t.pad[0] < upto:
            w["jsonl_pad"] = dict(t.pad[1], row=t.pad[0])
        steps.append({"name": "setup: cut %d of session %d" % (k + 1, t.i), "setup": [w]})
        steps.append({"name": "session %d (%s): %s" % (t.i, t.title, name), "cwd": REPO,
                      "argv": ["measure", "--sid", t.s, "--compact", "--cwd", REPO],
                      "expect": {"exit": 0, "stdout_has": has, "stdout_lacks": lacks}})
case = {"id": "AT-GR-09",
        "sid": sid(1),
        "note": ("Written by gen.py in this folder (python3 gen.py case.json): edit that, not this file. "
                 "Owner ruling 2026-10-27 20:57 (binding): the imperative `Active driver` line only while the loop is clearly live at the cut: "
                 "one of its own steps (its skill, a gsd-execute-phase it invoked, its gsd-tools run) is mid-turn, or an agent, workflow or "
                 "teammate it launched still runs (root call 2026-10-28: a single-phase loop's own code-review or validate gate gives the hint, "
                 "session 64; a background command, a monitor or a wake-up only names itself in the hint: a server it left running while it "
                 "waits for the person, sessions 19, 72, 94; a teammate's idle notice is a notification, session 70); the `Was driving` hint in "
                 "every other case: its turn ended, an "
                 "interruption, a pause, a stop, a prompt of any kind (a prompt typed mid-turn, from its queue-operation enqueue to its "
                 "queued_command delivery, a typed status look, /goal or /loop, this plugin's own skill, a shell command typed with !), another "
                 "session's turn (a cross-session message, a teammate the loop did not start), an API error ending the turn, the session resumed "
                 "in a new process. A quiet but live loop shown as a hint is accepted. The turn this plugin's checkpoint nudge closes is no stop "
                 "only in the nudge's [continue] form as the hook adds it (its [halt] sentence wins), and only when that turn asks the user nothing (sessions 40-44, 63); an "
                 "agent woken by SendMessage is not ended by its earlier run's crossed notification (session 46). A queued prompt ends the "
                 "loop's live context at its enqueue, but not a prompt the session scheduled itself, and a pause asked still holds until the "
                 "prompt is delivered (sessions 47, 48, 57, 59, 60, 62); Claude Code's notice that the person stopped background agents is a "
                 "stop (sessions 58, 61). Arguments that cannot be shown and hold more than the parts a re-enter command keeps give the hint "
                 "(sessions 66-69: the command would re-enter a wider run). A queued notification of the loop's own makes the next turn's "
                 "opener the loop's only by its own sender (sessions 56, 73-75). Sessions 76-84 guard what planted bugs got past. "
                 "A Bash command that names phase.complete in a form the gsd-tools parser does not read (through a variable, a flag before "
                 "the verb, a quoted or variable phase) ends a single-phase loop, and a bounded run when it names its last phase or one that "
                 "cannot be read (sessions 95-100, also after a gate); a row too long to read that may open a turn (a pasted prompt, typed or "
                 "queued) is unclear, a long tool result or a long row of another type is not (sessions 101-104). "
                 "R1: the outermost loop drives, "
                 "also past a pause it wrote (session 50); R4: a paused loop is shown, never run. Five sessions in this one worktree each keep "
                 "their own GSD line and workstream (owner 21:37)."),
        "tmp_base": "short", "now": "2026-10-26T14:05:12+03:00", "tz": "Etc/GMT-3", "steps": steps}
open(sys.argv[1], "w", encoding="utf-8").write(json.dumps(case, ensure_ascii=False, indent=1) + "\n")
print("steps", len(steps), "measures", sum(1 for s in steps if "argv" in s))
