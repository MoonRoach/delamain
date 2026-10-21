#!/usr/bin/env python3
"""Builds a fake hub home for t_agent_top.sh: agents in every state, logs shaped like `claude -p` stream-json.

  agent_top_fixture.py ROOT LIVE_PID SID_ALIVE SID_QUIET

LIVE_PID is a sleeper whose command line holds SID_ALIVE and SID_QUIET (the same rule `agent status` uses:
pid alive AND session id in its command line). Agents:
  alive1   live, a Bash tool call in flight, one read and one unread inbox message, a sub-agent event, a half-written last line
  quiet1   live, log untouched for 15 min                       -> quiet
  done1    finished, `result` event with "duration_api_ms" first   -> done, $1.25, modelUsage reports a 777k window
  crash1   no process, no result                                   -> dead
  err1     result with is_error                                    -> error
  resumed1 result, then a resume init, no process                  -> dead (running after the last result)
  reused   its pid is alive but runs another session (pid reuse)   -> dead
  oldie    finished 3 days ago                                     -> hidden without --all
  done1.20260114-233047  archive of an old run                     -> hidden without --all
  big1     3 MB log, 5000 turns, finished                          -> scanned from the tail when AGENT_TOP_SCAN_MAX is small
Stage stage-b: b1 (done). Stage empty: roles.json only.
"""
import datetime as dt
import json
import os
import subprocess
import sys
import time
from pathlib import Path

root, live_pid, sid_alive, sid_quiet = Path(sys.argv[1]), int(sys.argv[2]), sys.argv[3], sys.argv[4]
# The hub home and the lock board both follow the fixture root, whatever the caller's environment says.
os.environ["AGENT_HUB_HOME"] = str(root)
os.environ.pop("AGENT_BOARD_FILE", None)
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "bin"))
import hubcore as hc  # noqa: E402

NOW = time.time()
p = subprocess.Popen(["true"])
p.wait()
DEAD_PID = p.pid


def iso(off):
    return dt.datetime.fromtimestamp(NOW + off, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def line(ev):
    return json.dumps(ev, ensure_ascii=False, separators=(",", ":")) + "\n"


def init(sid):
    return line({"type": "system", "subtype": "init", "session_id": sid})


def text(mid, msg, off, sid, parent=None):
    return line({"type": "assistant", "message": {"id": mid, "content": [{"type": "text", "text": msg}],
                                                    "usage": {"input_tokens": 3, "cache_read_input_tokens": 40000, "cache_creation_input_tokens": 2000}},
                 "parent_tool_use_id": parent, "session_id": sid, "timestamp": iso(off)})


def tool(mid, tid, name, inp, off, sid):
    return line({"type": "assistant", "message": {"id": mid, "content": [{"type": "tool_use", "id": tid, "name": name, "input": inp}]},
                 "parent_tool_use_id": None, "session_id": sid, "timestamp": iso(off)})


def tool_result(tid, out, sid, err=False):
    return line({"type": "user", "message": {"role": "user", "content": [{"tool_use_id": tid, "type": "tool_result", "content": out, "is_error": err}]},
                 "parent_tool_use_id": None, "session_id": sid})


def result(sid, cost, err=False, subtype="success", msg="finished", usage=None):
    # the real CLI writes this event with "duration_api_ms" first, not "type"
    ev = {"duration_api_ms": 12, "type": "result", "subtype": subtype, "is_error": err, "num_turns": 3, "result": msg,
          "total_cost_usd": cost, "session_id": sid}
    if usage:
        ev["modelUsage"] = usage
    return line(ev)


def agent(stage, name, log, *, role=None, pid=DEAD_PID, sid=None, tag=None, mtime_off=0, model="claude-opus-5-5", unread=None, registry=True):
    d = root / stage / "agents" / name
    d.mkdir(parents=True, exist_ok=True)
    role = role or name
    sid = sid or f"sid-{name}"
    (d / "log.jsonl").write_bytes(log.encode("utf-8") if isinstance(log, str) else log)
    os.utime(d / "log.jsonl", (NOW + mtime_off, NOW + mtime_off))
    (d / "brief.md").write_text(f"# Fixture brief {name}\n\nDo the task and write DONE.\n", encoding="utf-8")
    (d / "inbox.md").write_text(f"# Inbox of agent {role}\n\n- 2026-01-15 10:00 old message\n- 2026-01-15 10:30 new message from the hub\n", encoding="utf-8")
    tag = tag or f"{role}-tag"
    meta = {"role": role, "tag": tag, "stage": stage, "session_id": sid, "model": model, "effort": "high",
            "cwd": str(root), "dir": str(d), "brief": str(d / "brief.md"), "title": f"Fixture {name} ({tag})",
            "report": str(root / stage / "coordinator" / "work" / f"{name}-REPORT.md"), "started_at": "2026-01-15T09:00:00+00:00",
            "runs": [{"pid": pid, "at": "2026-01-15T09:00:00+00:00", "kind": "spawn"}], "pid": pid}
    if unread:
        meta["inbox_unread"] = unread
    (d / "meta.json").write_text(json.dumps(meta, ensure_ascii=False, indent=1), encoding="utf-8")


# ---- stage-a
head = init(sid_alive) + text("m1", "Reading the task, checking the inbox", -120, sid_alive) \
    + tool("m2", "t1", "Bash", {"command": f"cat {root}/stage-a/agents/alive1/inbox.md", "description": "read the inbox"}, -110, sid_alive) \
    + tool_result("t1", "- 10:00 old message", sid_alive)
log = head + text("s1", "sub-agent work", -100, sid_alive, parent="t9") \
    + text("m3", "Running the tests", -60, sid_alive) \
    + tool("m4", "t2", "Bash", {"command": "pytest -x tests/", "description": "run the tests"}, -30, sid_alive) \
    + line({"type": "tool_progress", "tool_use_id": "t2-heartbeat-0", "tool_name": "Bash", "elapsed_time_seconds": 30}) \
    + line({"type": "rate_limit_event", "rate_limit_info": {"unifiedWindows": {"five_hour": {"utilization": 0.07, "resetsAt": NOW + 3600},
                                                                                "seven_day": {"utilization": 0.5, "resetsAt": NOW + 86400, "isUsingOverage": True}},
                                                                    # CLI 2.1.295+ tells whether the account has extra usage turned on; unknown fields must not matter
                                                                    "extraUsage": {"enabled": True, "usedCredits": 1.5}, "futureField": [1, {"a": None}]}}) \
    + '{"type":"assistant","message":{"id":"mZ","content":[{"type":"te'          # half-written last line, no newline
unread = [{"at": "2026-01-15T10:00:00+00:00", "msg": "old message", "log_offset": 0},
          {"at": "2026-01-15T10:30:00+00:00", "msg": "new message from the hub", "log_offset": len(head.encode("utf-8"))}]
agent("stage-a", "alive1", log, pid=live_pid, sid=sid_alive, unread=unread)
agent("stage-a", "quiet1", init(sid_quiet) + text("q1", "thinking about the schema", -900, sid_quiet), pid=live_pid, sid=sid_quiet, mtime_off=-900)
agent("stage-a", "done1", init("sid-done1") + text("d1", "finished: task 1", -700, "sid-done1") + result("sid-done1", 1.25, msg="finished: task 1",
             usage={"claude-haiku-4-5-20251001": {"contextWindow": 200000}, "claude-opus-5-5": {"contextWindow": 777000}}), mtime_off=-600)
agent("stage-a", "crash1", init("sid-crash1") + text("c1", "started work", -300, "sid-crash1")
      + tool("c2", "tc", "Bash", {"command": "make build"}, -290, "sid-crash1"), mtime_off=-280, registry=False)
agent("stage-a", "err1", init("sid-err1") + text("e1", "hit the turn limit", -200, "sid-err1")
      + result("sid-err1", 0.5, err=True, subtype="error_max_turns", msg="limit"), mtime_off=-190)
agent("stage-a", "resumed1", init("sid-resumed1") + text("r1", "first run", -800, "sid-resumed1") + result("sid-resumed1", 1.0)
      + init("sid-resumed1") + text("r2", "after the resume", -100, "sid-resumed1"), mtime_off=-90)
agent("stage-a", "reused", init("sid-reused") + text("u1", "was alive", -400, "sid-reused"), pid=live_pid, mtime_off=-390)
agent("stage-a", "oldie", init("sid-oldie") + text("o1", "finished long ago", -260000, "sid-oldie") + result("sid-oldie", 0.1), mtime_off=-259200)
agent("stage-a", "done1.20260114-233047", init("sid-old-run") + text("a1", "previous run", -90000, "sid-old-run") + result("sid-old-run", 0.2),
      role="done1", sid="sid-old-run", mtime_off=-90000)
big = [init("sid-big1")]
for i in range(5000):
    big.append(text(f"b{i}", f"step {i}: " + "x" * 520, -4000 + i / 2, "sid-big1"))
big.append(result("sid-big1", 2.0, msg="big log finished"))
agent("stage-a", "big1", "".join(big), mtime_off=-3600)

(root / "stage-a" / "roles.json").write_text(json.dumps({"version": 1, "retired": [], "sends": [], "roles": {
    "hub": {"session": "hub-desktop-session", "cli_session_id": "", "kind": "desktop", "tag": "hub-t", "title": "Hub test",
            "set_at": "2026-01-15T09:00:00+00:00"},
    "alive1": {"session": sid_alive, "cli_session_id": sid_alive, "kind": "headless", "tag": "alive1-tag", "title": "Fixture alive1", "pid": live_pid},
    "done1": {"session": "sid-done1", "kind": "headless", "tag": "done1-tag", "title": "Fixture done1", "pid": DEAD_PID},
    "quiet1": {"session": sid_quiet, "kind": "headless", "tag": "quiet1-tag", "title": "Fixture quiet1", "pid": live_pid},
}}, ensure_ascii=False), encoding="utf-8")

work = root / "stage-a" / "coordinator" / "work"
work.mkdir(parents=True, exist_ok=True)
today = dt.datetime.now(hc.TZ).date().isoformat()
(work / f"journal-{today}.md").write_text(
    "- 10:00 [hub-t] agents started\n- 10:05 [alive1-tag] ran the tests, all green\n- 10:06 [hub-t] @alive1-tag check the inbox\n"
    "- 10:07 [chief/sub] subtag line\n- 10:10 [done1-tag] DONE task 1 is ready\n", encoding="utf-8")

# ---- stage-b, empty
agent("stage-b", "b1", init("sid-b1") + text("x1", "stage-b agent finished", -50, "sid-b1") + result("sid-b1", 0.3), mtime_off=-40, model="claude-sonnet-5-5")
(root / "stage-b" / "coordinator" / "work").mkdir(parents=True, exist_ok=True)
(root / "stage-b" / "coordinator" / "work" / f"journal-{today}.md").write_text("- 09:00 [b-tag] a line of stage-b\n", encoding="utf-8")
(root / "empty").mkdir(exist_ok=True)
(root / "empty" / "roles.json").write_text('{"version":1,"roles":{}}', encoding="utf-8")

# ---- board: one active lock, one expired
import board  # noqa: E402

board.write([
    {"kind": "main-merge", "repo": "demo-repo", "owner_name": "Hub test", "session_id": "x", "until": board.fmt(board.now() + dt.timedelta(hours=2)),
     "why": "merging main", "taken_at": board.fmt(board.now())},
    {"kind": "stage", "repo": "demo-repo", "owner_name": "Previous", "session_id": "y", "until": board.fmt(board.now() - dt.timedelta(hours=1)),
     "why": "old booking", "taken_at": board.fmt(board.now() - dt.timedelta(hours=3))},
])
print(f"fixture ok: {root} dead_pid={DEAD_PID}")
