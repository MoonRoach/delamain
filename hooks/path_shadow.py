#!/usr/bin/env python3
"""SessionStart hook: one line when a command of the same name as one of the plugin's tools (any executable of its bin/:
hub, jlog, jwait, agent, ask, roles, lock, …) comes before the plugin's bin/ on PATH — GitHub CLI `hub` from Homebrew is
the usual one. The Delamain commands then run the other program, and an agent's `jlog` writes to a journal the hub never
reads.

Also keeps $HUB_BIN, which the briefs and tools call as "$HUB_BIN/jlog", pointing at this plugin's bin/: a `claude --bg`
session gets the environment of the long-running Claude Code daemon, and with it the HUB_BIN of whichever plugin version
was current when the daemon started, so a background hub would run an old jlog and jwait. When $HUB_BIN is unset or points
elsewhere the hook appends `export HUB_BIN=<the bin/> of the plugin copy it belongs to` (its own location; an inherited
PLUGIN_ROOT is ignored, and a CLAUDE_PLUGIN_ROOT naming another copy makes it leave HUB_BIN alone) to $CLAUDE_ENV_FILE (Claude Code runs that file before every
Bash command of the session; without the variable — Codex — nothing is written) and, if it replaced a stale value, says so
in one line.

Reads PATH as this hook process sees it; nothing is run. Does nothing, and writes nothing, until a hub home exists
(<hub home>: `hub start` creates it): a machine that never ran a hub is left alone.
Scope as in questions.py: a session that starts in the hub home, in a repository with `.agent-hub/`, under
AGENT_HUB_SCOPE_DIRS, or as a hub agent (HUB_TAG) hears it every time; a session elsewhere (a first project that has no `.agent-hub/` yet) hears it once per distinct set of shadowing
paths, remembered in <state dir>/path-shadow/seen (AGENT_HUB_STATE_DIR, default <hub home>/.state). Fail-open: any
error of its own -> exit 0 with no output.
"""
from __future__ import annotations

if __name__ == "__main__":  # fail-safe first, before anything that can fail: see hooks/failsafe.py
    try:
        import failsafe

        failsafe.install()
    except Exception:  # noqa: BLE001 — without it the hook is as it was
        pass

import json
import os
import shlex
import sys
from pathlib import Path


def bin_dir() -> Path:
    """The bin/ of the plugin copy this hook belongs to: its own location. Not an inherited root: a Claude worker started
    from a Codex host carries the host's PLUGIN_ROOT, which may be an older version's."""
    return Path(os.path.dirname(os.path.dirname(os.path.realpath(__file__)))) / "bin"


def correct_hub_bin() -> str:
    """Write HUB_BIN=<this plugin's bin/> into $CLAUDE_ENV_FILE when the session's value is unset or points elsewhere.
    Returns the one-line notice when it replaced a stale value, else ""."""
    env_file = os.environ.get("CLAUDE_ENV_FILE")
    want = bin_dir()
    have = os.environ.get("HUB_BIN", "").strip()
    if not env_file or (have and os.path.realpath(have) == os.path.realpath(want)):
        return ""
    claimed = os.environ.get("CLAUDE_PLUGIN_ROOT", "").strip()  # a cross-check only: when it names another copy, leave HUB_BIN alone
    if claimed and os.path.realpath(os.path.join(claimed, "bin")) != os.path.realpath(want):
        return ""
    with open(env_file, "a", encoding="utf-8") as f:
        f.write(f"export HUB_BIN={shlex.quote(str(want))}\n")
    if not have:
        return ""
    return (f"delamain: $HUB_BIN was {have}, another plugin version (a background session inherits the daemon's "
            f"environment); set to {want} for this session's commands")


def main() -> int:
    try:
        event = json.loads(sys.stdin.read() or "{}")  # drained so the harness never blocks on the pipe
    except Exception:
        event = {}
    event = event if isinstance(event, dict) else {}
    sys.path.insert(0, str(bin_dir()))
    import hubcore as hc  # noqa: E402

    hc.use_cwd(event.get("cwd"))
    if not hc.root().is_dir():
        return 0
    lines = []
    try:
        notice = correct_hub_bin()
    except OSError:
        notice = ""
    if notice:
        lines.append(notice + ". Tell the user about it in one line.")
    shadowed = hc.shadowed_tools()
    if not shadowed:
        return emit(lines)
    seen = None
    if not (os.environ.get("HUB_TAG") or hc.in_scope(event.get("cwd") or os.getcwd())):
        seen = hc.state_dir() / "path-shadow" / "seen"
        signature = "\n".join(sorted(f"{n}={p}" for n, p in shadowed))
        try:
            if seen.read_text(encoding="utf-8") == signature:
                return emit(lines)
        except OSError:
            pass
        hc.atomic_write(seen, signature)
    lines.append("delamain: " + hc.shadow_warning(shadowed) + ". Tell the user about it in one line.")
    return emit(lines)


def emit(lines: list) -> int:
    if lines:
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": "\n".join(lines)}},
                         ensure_ascii=False))
    return 0


if __name__ == "__main__":
    try:
        main()
    except BaseException:
        pass
    sys.exit(0)
