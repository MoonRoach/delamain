#!/usr/bin/env python3
"""Antigravity CLI (agy) stand-in for tests/t_agy_review.sh: no model, no network.

Headless (`-p`): appends one record per call to $FAKE_AGY_DIR/calls.jsonl (argv, HOME, cwd and the settings.json the call
sees under that HOME, and its PATH, HOME and GIT_* variables) and answers with entry N of the list in $FAKE_AGY_DIR/scenario.json (the last entry once the list is
used up): {"json": {...agy's JSON...}, "exit": 0, "sleep": 0, "raw": "text printed instead of the JSON",
"ignore_term": true (ignores SIGTERM)}.
Interactive (no `-p`): appends to interactive.log and draws what the real CLI draws for /usage, read from
$FAKE_AGY_PANEL (a file; without it the stand-in exits at once, which is how agy looks when it cannot be read); with
$FAKE_AGY_HANG it prints nothing and sits there.
"""
import json
import os
import signal
import sys
import time
from pathlib import Path

state = Path(os.environ["FAKE_AGY_DIR"])
args = sys.argv[1:]

if "-p" not in args:
    with open(state / "interactive.log", "a") as log:
        log.write("started\n")
    if os.environ.get("FAKE_AGY_HANG"):
        time.sleep(300)
        sys.exit(0)
    panel = os.environ.get("FAKE_AGY_PANEL")
    if not panel or not Path(panel).is_file():
        sys.exit(1)
    sys.stdout.write("\x1b[2J\x1b[1mAntigravity\x1b[0m  ? for shortcuts\n")
    sys.stdout.flush()
    seen = b""
    while b"/usage" not in seen or b"\n" not in seen:   # Esc, then the command, then Enter (CR becomes NL on a tty)
        chunk = os.read(0, 4096)
        if not chunk:
            sys.exit(0)
        seen += chunk
    # the panel is drawn with colours and a bar glyph, as the real one is
    sys.stdout.write("\x1b[38;5;39m" + Path(panel).read_text().replace("███", "\x1b[32m███\x1b[0m") + "\x1b[0m\n")
    sys.stdout.flush()
    time.sleep(0.3)
    sys.exit(0)

calls = state / "calls.jsonl"
index = len(calls.read_text().splitlines()) if calls.exists() else 0
scenario = json.loads((state / "scenario.json").read_text())
step = scenario[min(index, len(scenario) - 1)]
if step.get("ignore_term"):   # an agy that does not stop for SIGTERM; set before the call is logged, so a test can rely on it
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
settings = Path(os.environ.get("HOME", "")) / ".gemini" / "antigravity-cli" / "settings.json"
with open(calls, "a") as log:
    log.write(json.dumps({"argv": args, "pid": os.getpid(), "ppid": os.getppid(), "home": os.environ.get("HOME"),
                          "cwd": os.getcwd(), "settings": settings.read_text() if settings.is_file() else None,
                          "env": {k: v for k, v in os.environ.items() if k in ("PATH", "HOME") or k.startswith("GIT_")}})
              + "\n")
time.sleep(step.get("sleep", 0))
if "raw" in step:
    print(step["raw"])
else:
    print(json.dumps(step.get("json", {})))
sys.exit(step.get("exit", 0))
