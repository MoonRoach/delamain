#!/usr/bin/env python3
"""Stand-in for the `claude` CLI in the autopilot tests (CLAUDE_BIN=<this>): `--bg`, `logs`, `agents --json`,
`auth status`, `stop`, `rm`; a `-p` run is handed to fake_claude.py (the headless fallback's `agent spawn`).
Never starts anything: every call is appended as one JSON line to $FAKE_BG_LOG (argv, cwd, the identity variables).

FAKE_BG=ok (default)      `--bg` prints "backgrounded · bg-1234abcd · <name>"
FAKE_BG=bypass            `--bg --permission-mode bypassPermissions` exits 1 with the disclaimer error
FAKE_BG=untrusted         `--bg` exits 1 "Workspace not trusted" unless the cwd is $FAKE_TRUSTED
FAKE_BG=noid              `--bg` prints nothing; `agents --json` lists the session
FAKE_BG=hang              `--bg` sleeps FAKE_HANG seconds (5) and prints nothing
FAKE_AGENTS (late|stale|none|prev|prevbusy|prevgone|fail), FAKE_PREV_SID, FAKE_AGENTS_SEQ, FAKE_ON_LOGS: see the `agents` and `logs` branches
FAKE_AGENT_NAME           the name of the late/stale rows (default stage-a-hub-2)
FAKE_STOP=fail            `stop` exits 1
FAKE_LOGIN=no             `auth status` says loggedIn false
FAKE_LOGS=link (default)  `logs` prints ANSI screen text with a Remote Control link
FAKE_LOGS=notloggedin     `logs` prints "Not logged in · Run /login";  FAKE_LOGS=none: no link
"""
import json, os, subprocess, sys, time

HERE = os.path.dirname(os.path.realpath(__file__))
argv = sys.argv[1:]
if "-p" in argv:
    with open(os.environ.get("FAKE_BG_LOG", "bg.log"), "a", encoding="utf-8") as fh:
        fh.write(json.dumps({"argv": ["-p-run"], "cwd": os.getcwd(),
                             "env": {"AGENT_SESSION_ID": os.environ.get("AGENT_SESSION_ID")}}) + "\n")
    os.execv(sys.executable, [sys.executable, os.path.join(HERE, "fake_claude.py")] + argv)
with open(os.environ.get("FAKE_BG_LOG", "bg.log"), "a", encoding="utf-8") as fh:
    fh.write(json.dumps({"argv": argv, "cwd": os.path.realpath(os.getcwd()),
                         "env": {k: os.environ.get(k) for k in ("CLAUDECODE", "CLAUDE_CODE_SESSION_ID", "HUB_TAG",
                                                                "CLAUDE_CODE_ENTRYPOINT", "AGENT_HUB_HOME",
                                                                "AGENT_SESSION_ID", "AGENT_HUB_ENGINE")}}) + "\n")
mode, cmd = os.environ.get("FAKE_BG", "ok"), (argv[0] if argv else "")
if cmd == "auth":
    print(json.dumps({"loggedIn": os.environ.get("FAKE_LOGIN", "yes") != "no", "authMethod": "claude.ai"}))
elif cmd == "logs":
    if os.environ.get("FAKE_ON_LOGS"):  # something that happens while the logs are read (a takeover registering)
        subprocess.run(os.environ["FAKE_ON_LOGS"], shell=True)
    logs = os.environ.get("FAKE_LOGS", "link")
    if logs == "notloggedin":
        print("\x1b[1mNot logged in\x1b[0m · Run /login")
    elif logs == "none":
        print("\x1b[2m✻ Starting…\x1b[0m\nline two of the screen")
    else:
        print("\x1b[2m/remote-control is active · \x1b[4mhttps://claude.ai/code/session_01AbC-xyz\x1b[0m\n> working")
elif cmd == "agents":
    # FAKE_AGENTS=late (default): this start's session and an older same-named one; stale: the older one only;
    # none: nothing. FAKE_AGENTS_SEQ=<file>: one of those words per call, consumed line by line.
    which = os.environ.get("FAKE_AGENTS", "late")
    seq = os.environ.get("FAKE_AGENTS_SEQ")
    if seq and os.path.exists(seq):
        lines = open(seq).read().splitlines()
        which, rest = (lines[0], lines[1:]) if lines else ("none", [])
        open(seq, "w").write("\n".join(rest))
    old = {"kind": "background", "id": "bg-older", "sessionId": "o", "name": os.environ.get("FAKE_AGENT_NAME", "stage-a-hub-2"), "startedAt": 1}
    new = {"kind": "background", "id": "bg-from-list", "sessionId": "s", "name": os.environ.get("FAKE_AGENT_NAME", "stage-a-hub-2"),
           "startedAt": int(time.time() * 1000)}
    # prev: an idle background session with a pid (state done), sessionId $FAKE_PREV_SID (the hub a takeover replaced);
    # prevbusy: the same but busy and working; prevgone: the same without a pid, state done; fail: no JSON, exit 1
    if which == "fail":
        sys.stderr.write("fake claude: agents failed\n")
        sys.exit(1)
    prev = {"kind": "background", "id": os.environ.get("FAKE_PREV_SID", "p")[:8], "sessionId": os.environ.get("FAKE_PREV_SID", "p"),
            "name": "Hub stage-a #16", "pid": 4242, "status": "idle", "state": "done", "startedAt": 1}
    rows = {"late": [new, old], "stale": [old], "none": [], "prev": [prev],
            "prevbusy": [dict(prev, status="busy", state="working")],
            "prevgone": [{k: v for k, v in prev.items() if k != "pid"}]}[which]
    print(json.dumps([{"kind": "interactive", "sessionId": "x", "name": "other"}] + rows))
elif cmd in ("stop", "rm"):
    if cmd == "stop" and os.environ.get("FAKE_STOP") == "fail":
        sys.stderr.write("fake claude: stop failed\n")
        sys.exit(1)
    print(f"{cmd} {argv[1] if len(argv) > 1 else ''}")
elif "--bg" in argv:
    pm = argv[argv.index("--permission-mode") + 1] if "--permission-mode" in argv else None
    if mode == "bypass" and pm == "bypassPermissions":
        sys.stderr.write("Error: --permission-mode bypassPermissions requires accepting the disclaimer first. Run "
                         "`claude --dangerously-skip-permissions` once interactively\n")
        sys.exit(1)
    if mode == "untrusted" and os.path.realpath(os.getcwd()) != os.path.realpath(os.environ.get("FAKE_TRUSTED", "/nowhere")):
        sys.stderr.write(f"Workspace not trusted. Run `claude` in {os.getcwd()} once and accept the trust prompt\n")
        sys.exit(1)
    if mode == "hang":  # `claude --bg` that does not return (the caller's timeout kills it)
        time.sleep(float(os.environ.get("FAKE_HANG", "5")))
        sys.exit(0)
    if mode != "noid":
        print(f"backgrounded · bg-1234abcd · {argv[argv.index('--remote-control') + 1]}")
else:
    sys.stderr.write(f"fake claude: unexpected {argv}\n")
    sys.exit(2)
