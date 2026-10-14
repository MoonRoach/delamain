"""Fail-safe wrapper for the plugin's hooks: whatever happens inside a hook, the harness gets a valid answer in time.

Claude Code 2.1.299 stopped letting an action through when a plugin hook cannot hand back its answer: a hook that
crashes, hangs past its `timeout` or prints half a JSON document now blocks the user's Bash and Edit calls (and withholds
the result of a tool that already ran). Every hook of this plugin is a guard that is meant to fail open, so each calls
`install()` first thing:

  - stdout is held back and written once at exit, and only if it is one complete JSON document; anything else (a crash
    after a partial print, a stray traceback line) is dropped, which reads as "no decision";
  - the exit status is always 0, whatever ended the process: an uncaught exception, an import error at module level,
    `sys.exit(1)`;
  - a timer answers "no decision" before the harness's own timeout (DEADLINES, seconds, one below the `timeout` of
    hooks/hooks.json and hooks/codex-hooks.json; tests/t_hook_failsafe.sh checks the two agree). A hook stuck on a
    stalled filesystem or an stdin that never closes is cut there. $AGENT_HUB_HOOK_DEADLINE_S overrides it (the tests).

A deliberate decision is not affected: a hook that printed its deny and then failed still delivers the deny.
"""
from __future__ import annotations

import atexit
import io
import json
import os
import sys
import threading

DEFAULT_DEADLINE_S = 3.5  # the shortest `timeout` in the hook configs is 5 s
DEADLINES = {
    "board_locks.py": 3.5,  # timeout 5
    "polling_guard.py": 3.5,  # timeout 5
    "questions.py": 8.5,  # timeout 10
    "delegation.py": 8.5,
    "path_shadow.py": 8.5,
    "handoff_size.py": 8.5,
    "context_budget.py": 8.5,
}

_state: dict = {}


def deadline_s() -> float:
    try:
        return float(os.environ["AGENT_HUB_HOOK_DEADLINE_S"])
    except (KeyError, ValueError):
        return DEADLINES.get(os.path.basename(sys.argv[0]), DEFAULT_DEADLINE_S)


def _finish() -> None:
    """At exit: deliver a complete JSON answer, if there is one, and leave with status 0."""
    timer = _state.get("timer")
    if timer is not None:
        timer.cancel()
    real, buf = _state.get("stdout"), _state.get("buffer")
    try:
        sys.stdout = real
        text = buf.getvalue()
        if text.strip():
            json.loads(text)  # a half-written document is no answer
            data = text.encode("utf-8", "replace")  # JSON is UTF-8 whatever the locale; a lone surrogate must not lose the answer
            if hasattr(real, "buffer"):
                real.flush()
                real.buffer.write(data)
                real.buffer.flush()
            else:
                real.write(text)
                real.flush()
    except BaseException:  # noqa: BLE001 — nothing is delivered, which means "no decision"
        pass
    try:
        sys.stderr.flush()
    except BaseException:  # noqa: BLE001
        pass
    os._exit(0)


def _give_up() -> None:
    os._exit(0)  # the buffered output is dropped with the process


def install() -> None:
    """Arm the fail-safe for this hook process. Call once, before anything that can fail."""
    if _state:
        return
    _state["stdout"], _state["buffer"] = sys.stdout, io.StringIO()
    sys.stdout = _state["buffer"]
    timer = threading.Timer(deadline_s(), _give_up)
    timer.daemon = True
    timer.start()
    _state["timer"] = timer
    atexit.register(_finish)
