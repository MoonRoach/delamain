#!/usr/bin/env python3
"""Stand-in for the `claude` CLI in the watchdog tests (CLAUDE_BIN=<this>): `--version`, `agents --json`, `stop`,
`--bg --resume`; a `-p` run (the headless hub that `agent send` resumes) is handed to fake_claude.py.
Never starts anything: every call is appended as one JSON line to $FAKE_WD_LOG (argv, cwd).

$FAKE_WD_ROWS (a JSON file, default none)  the rows `agents --json` prints; `stop` removes a row, a resume adds one
FAKE_WD_AGENTS=fail                        `agents --json` exits 1
FAKE_WD_STOP=fail                          `stop` exits 1
FAKE_WD_ON_STOP=<shell command>            run by every `stop`, before it acts, with the target as its argument (a test that
                                           changes the world while the watchdog is stopping sessions)
FAKE_WD_ON_AGENTS=<n>:<shell command>      run by the n-th `agents --json` call of the log, before it answers (a test that changes the
                                           world between the watchdog's first look at a session and the look right before its stop)
FAKE_WD_RESUME=fail                        `--bg --resume` exits 1 ("Error: resume failed")
FAKE_WD_STOP=ghost                         `stop` of a hub exits 0 but its row stays listed (the process is not touched)
FAKE_WD_AGENTS_FAIL_FROM=<n>               from the n-th `agents --json` call of the log on, it exits 1
FAKE_WD_STOP=copy-fail                     `stop` of a copy (id cc…) exits 1; any other stop works
FAKE_WD_STOP=copy-ghost                    `stop` of a copy exits 0 but the copy stays listed
FAKE_WD_KIND=interactive FAKE_WD_KIND_FROM=2  from the 2nd `agents --json` call on, every row says that kind (the owner
                                           opened the session in a terminal meanwhile)
FAKE_WD_STOP_LINGER=<seconds>|hold         `stop` drops the row at once but the process of the row (its pid) is killed only
                                           that many seconds later (`hold`: never, the test ends it) (the daemon's release window of the real CLI, probed on
                                           2.1.289); a resume while that pid is still alive starts a copy
FAKE_WD_STOP_RELIST=1                      the row is listed again (the owner resumed the session) from the 2nd `agents` call
                                           after the stop
FAKE_WD_RESUME=copy                        `--bg --resume` always starts a copy (a new row, a different session id)
FAKE_WD_RESUME=stranger                    `--bg --resume` continues the same id, and an unrelated session (feedface) appears
                                           at the same time without any "copy" message
default                                    behaves like the real CLI (2.1.289, probed): a session that is still listed, or
                                           a call with any flag besides the prompt, starts a copy; otherwise the same id
                                           continues and a row for it appears
"""
import json, os, subprocess, sys

HERE = os.path.dirname(os.path.realpath(__file__))
NO_PROCESS = 99999999  # the pid of the rows this fake adds: no such process (the watchdog waits for a stopped row's pid to exit)
argv = sys.argv[1:]
if argv == ["--version"]:
    print("2.1.289 (Claude Code)")
    sys.exit(0)
if "-p" in argv:
    os.execv(sys.executable, [sys.executable, os.path.join(HERE, "fake_claude.py")] + argv)
with open(os.environ.get("FAKE_WD_LOG", "wd-claude.log"), "a", encoding="utf-8") as fh:
    fh.write(json.dumps({"argv": argv, "cwd": os.path.realpath(os.getcwd())}) + "\n")
rows_file = os.environ.get("FAKE_WD_ROWS")


def rows():
    try:
        return json.load(open(rows_file))
    except (OSError, TypeError, ValueError):
        return []


def save(r):
    if rows_file:
        json.dump(r, open(rows_file, "w"))


cmd = argv[0] if argv else ""
if cmd == "agents":
    if os.environ.get("FAKE_WD_ON_AGENTS"):
        want, _, shell = os.environ["FAKE_WD_ON_AGENTS"].partition(":")
        with open(os.environ.get("FAKE_WD_LOG", "wd-claude.log"), encoding="utf-8") as fh:
            nth = sum(1 for line in fh if json.loads(line)["argv"][:1] == ["agents"])
        if nth == int(want):
            subprocess.run(["sh", "-c", shell], check=False)
    if os.environ.get("FAKE_WD_AGENTS") == "fail":
        sys.stderr.write("fake claude: agents failed\n")
        sys.exit(1)
    if os.environ.get("FAKE_WD_AGENTS_FAIL_FROM"):
        with open(os.environ.get("FAKE_WD_LOG", "wd-claude.log"), encoding="utf-8") as fh:
            nth = sum(1 for line in fh if json.loads(line)["argv"][:1] == ["agents"])
        if nth >= int(os.environ["FAKE_WD_AGENTS_FAIL_FROM"]):
            sys.stderr.write("fake claude: agents failed\n")
            sys.exit(1)
    try:
        relist = json.load(open(rows_file + ".relist"))
        relist["left"] -= 1
        if relist["left"] <= 0:
            save(rows() + [relist["row"]])
            os.unlink(rows_file + ".relist")
        else:
            json.dump(relist, open(rows_file + ".relist", "w"))
    except (OSError, TypeError, ValueError):
        pass
    out = rows()
    kind, calls = os.environ.get("FAKE_WD_KIND"), 0
    if kind:
        with open(os.environ.get("FAKE_WD_LOG", "wd-claude.log"), encoding="utf-8") as fh:
            calls = sum(1 for line in fh if json.loads(line)["argv"][:1] == ["agents"])
        if calls >= int(os.environ.get("FAKE_WD_KIND_FROM", "1")):
            out = [dict(r, kind=kind) for r in out]
    print(json.dumps(out))
elif cmd == "stop":
    target = argv[1] if len(argv) > 1 else ""
    if os.environ.get("FAKE_WD_ON_STOP"):
        subprocess.run(["sh", "-c", os.environ["FAKE_WD_ON_STOP"], "sh", target], check=False)
    mode = os.environ.get("FAKE_WD_STOP", "")
    if mode == "fail" or (mode == "copy-fail" and target.startswith("cc")):
        sys.stderr.write("fake claude: stop failed\n")
        sys.exit(1)
    if mode == "copy-ghost" and target.startswith("cc"):
        print(f"stopped {target}")
        sys.exit(0)
    if mode == "ghost":
        print(f"stopped {target}")
        sys.exit(0)
    gone = [r for r in rows() if target in (r.get("id"), r.get("sessionId"))]
    save([r for r in rows() if r not in gone])
    linger = os.environ.get("FAKE_WD_STOP_LINGER")
    if linger and gone and gone[0].get("pid"):
        with open(rows_file + ".lingering", "a", encoding="utf-8") as fh:
            fh.write(json.dumps({"sid": gone[0].get("sessionId"), "pid": gone[0]["pid"]}) + "\n")
        if os.environ.get("FAKE_WD_STOP_RELIST"):  # the row comes back at the 2nd `agents` call after the stop
            with open(rows_file + ".relist", "w", encoding="utf-8") as fh:
                json.dump({"row": dict(gone[0], pid=NO_PROCESS), "left": 2}, fh)
        if linger != "hold":
            subprocess.Popen(["sh", "-c", f"sleep {float(linger)}; kill {int(gone[0]['pid'])}"], start_new_session=True,
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(f"stopped {target}")
elif cmd == "--bg" and "--resume" in argv:
    sid = argv[argv.index("--resume") + 1]
    rest = [a for a in argv[1:] if a not in ("--resume", sid)]
    flags = [a for a in rest if a.startswith("-")]
    listed = any(sid in (r.get("sessionId"), r.get("id")) for r in rows())
    try:  # the session was stopped but its process still exits: the daemon has not released it yet
        for line in open(rows_file + ".lingering", encoding="utf-8"):
            rec = json.loads(line)
            try:
                os.kill(rec["pid"], 0)
                listed = listed or rec["sid"] == sid
            except OSError:
                pass
    except (OSError, TypeError, ValueError):
        pass
    mode = os.environ.get("FAKE_WD_RESUME", "")
    if mode == "fail":
        sys.stderr.write("Error: resume failed\n")
        sys.exit(1)
    if mode == "stranger":
        save(rows() + [{"id": "feedface", "sessionId": "feedface-0000-4000-8000-000000000000", "kind": "background",
                        "status": "idle", "state": "done", "pid": NO_PROCESS, "cwd": os.getcwd(), "name": "owner's agent"}])
    if mode == "copy" or listed or flags:
        new = "cc" + sid[2:8]
        why = (f"session {sid[:8]} is already running in the background, so this started a copy as {new}." if listed
               else f"background session {sid[:8]} keeps its own saved options, so the flags you passed started a copy as {new}.")
        save(rows() + [{"id": new, "sessionId": new + "-0000-4000-8000-000000000000", "kind": "background",
                        "status": "idle", "state": "done", "pid": NO_PROCESS, "cwd": os.getcwd(), "name": "copy"}])
        print(f"note: {why}\nbackgrounded · {new}")
    else:
        save(rows() + [{"id": sid[:8], "sessionId": sid, "kind": "background", "status": "idle", "state": "done",
                        "pid": NO_PROCESS, "cwd": os.getcwd(), "name": "hub"}])
        print(f"note: woke session {sid[:8]} with its saved options (--remote-control, --model, --permission-mode).\n"
              f"backgrounded · {sid[:8]}")
else:
    sys.stderr.write(f"fake claude: unexpected call {argv}\n")
    sys.exit(1)
