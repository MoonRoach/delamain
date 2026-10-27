#!/usr/bin/env python3
"""Fixture writer for tests/t_desktop_idle.sh: the files Claude Desktop and the CLI keep, and a stand-in process tree.

  desktop_idle_fixture.py proc            a process with two children (a `claude`, an MCP server retitled with a key in its name
                                          and a plain `sleep`), until SIGTERM
  desktop_idle_fixture.py cli CONFIG PID HOST STATUS STARTED_AGO_S STATUS_AGO_S
                                          <CONFIG>/sessions/<PID>.json, as the CLI writes it for a Desktop-hosted session
  desktop_idle_fixture.py desk DIR HOST CLI TITLE CWD BRANCH ACTIVITY_AGO_S [archived] [exempt]
                                          Desktop's record DIR/<a>/<b>/<HOST>.json
"""
import json
import os
import signal
import subprocess
import sys
import time


def main(argv):
    cmd = argv[0]
    if cmd == "proc":
        kids = [subprocess.Popen(["bash", "-c", 'exec -a "npm S3CR3T-key" sleep 600']), subprocess.Popen(["sleep", "600"])]
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
        try:
            time.sleep(600)
        finally:
            for k in kids:
                k.kill()
        return
    now = time.time()
    if cmd == "cli":
        config, pid, host, status, started_ago, status_ago = argv[1:7]
        os.makedirs(f"{config}/sessions", exist_ok=True)
        json.dump({"pid": int(pid), "sessionId": f"cli-{host}", "cwd": "/", "startedAt": int((now - float(started_ago)) * 1000),
                   "kind": "interactive", "entrypoint": "claude-desktop", "hostSessionId": host, "status": status,
                   "updatedAt": int((now - float(status_ago)) * 1000), "statusUpdatedAt": int((now - float(status_ago)) * 1000)},
                  open(f"{config}/sessions/{pid}.json", "w"))
    elif cmd == "desk":
        d, host, cli, title, cwd, branch, ago = argv[1:8]
        os.makedirs(f"{d}/acct/org", exist_ok=True)
        rec = {"sessionId": host, "cliSessionId": cli, "cwd": cwd, "originCwd": cwd, "branch": branch or None,
               "title": title, "lastActivityAt": int((now - float(ago)) * 1000), "isArchived": "archived" in argv[8:]}
        if "exempt" in argv[8:]:
            rec["autoArchiveExempt"] = True
        json.dump(rec, open(f"{d}/acct/org/{host}.json", "w"))


main(sys.argv[1:])
