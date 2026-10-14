#!/usr/bin/env python3
"""Keep a registered hub from routing work into Claude Desktop's session cards.

Claude Desktop's own system prompt tells the model to propose follow-ups as cards (`mcp__ccd_session__start_session`
with `initiation` "own_initiative" or "offer") and to fork with `hand_off_to_session`. A hub's autopilot cannot click
a card, and a card session is invisible to agent-top and to a successor hub; the app starts a session without a click
only in a turn the owner typed (`user_asked`). So in a registered hub the plugin's own routes win.

Hook subcommands (hook JSON on stdin):
  pre-tool       PreToolUse on mcp__ccd_session__start_session | …hand_off_to_session | …spawn_task: deny
                 `hand_off_to_session`, `spawn_task` and a start with initiation own_initiative / offer in a hub's session; allow
                 `user_asked`, a start from a card (`proposal_id`) and every call outside a hub
  session-start  SessionStart: one line of context in a hub's session (a resumed hub; `hub start` and `hub takeover`
                 print the same line in their digest, hubcore.DESKTOP_CARDS_LINE)

A hub is the session registered as the `hub` role of some stage (is_hub). Fail-open: when the registry cannot be
read, or the session cannot be told, nothing is denied and nothing is said.
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
import sys

PLUGIN_ROOT = os.environ.get("PLUGIN_ROOT") or os.environ.get("CLAUDE_PLUGIN_ROOT") or os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
sys.path.insert(0, os.path.join(PLUGIN_ROOT, "bin"))
try:
    import hubcore as hc  # noqa: E402
except Exception:  # noqa: BLE001 — fail-open: as a hook, never block a session over an import error
    if len(sys.argv) > 1 and sys.argv[1] in ("session-start", "pre-tool"):
        sys.exit(0)
    raise

START = "mcp__ccd_session__start_session"
HAND_OFF = "mcp__ccd_session__hand_off_to_session"
SPAWN_TASK = "mcp__ccd_session__spawn_task"  # the older task-card tool of the same server: it only ever makes a card
CARD_INITIATIONS = ("own_initiative", "offer")
DENY_REASON = (
    "In a registered hub Desktop's session cards and forks are off: autopilot turns cannot click a card, and agents "
    "must be visible to agent-top and reachable by successors.\n"
    "Executor work: `agent spawn --engine … --role … --brief …`. A decision the owner must make: `ask add`. "
    "A shift of the hub: `hub handoff` / `hub succeed`.\n"
    "A session or fork the owner asked for in their own message: start_session with initiation \"user_asked\" "
    "(and context \"fork\" for a fork)."
)


def is_hub(session_id, host_id="") -> bool:
    """True when the session is the registered `hub` of some stage of the hub home. The session is matched by its
    CLI session id or its Desktop `local_…` id; a Desktop id counts only when Desktop's own record of it names this CLI
    session (every child process inherits the id from the environment, an `agent spawn` worker included).
    Anything that cannot be read is "not a hub"."""
    sid = session_id if isinstance(session_id, str) else ""
    if not sid:
        return False
    host = host_id if isinstance(host_id, str) and host_id.startswith("local_") else ""
    try:
        stages = sorted(d.name for d in hc.root().iterdir() if (d / "roles.json").is_file())
    except OSError:
        return False
    for stage in stages:
        try:
            rec = hc.roles_load(stage)["roles"].get("hub")
        except (hc.Failure, hc.UsageError, OSError, ValueError, AttributeError, TypeError):
            continue  # one unreadable registry must not hide the hub of another stage
        if not isinstance(rec, dict):
            continue
        if sid in (rec.get("session"), rec.get("cli_session_id")):
            return True
        if host and rec.get("session") == host and (hc.desktop_session(host) or {}).get("cliSessionId") == sid:
            return True
    return False


def decide(tool, tool_input) -> str | None:
    """The deny reason for one call of the Desktop session tools (before the hub check), or None."""
    if tool in (HAND_OFF, SPAWN_TASK):
        return DENY_REASON
    if tool != START or not isinstance(tool_input, dict):
        return None
    if tool_input.get("proposal_id"):  # the owner accepted a card: the app gates it itself
        return None
    initiation = tool_input.get("initiation")
    if isinstance(initiation, str) and initiation.strip().lower() in CARD_INITIATIONS:
        return DENY_REASON
    return None


def hook_input() -> dict:
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return {}
    return data if isinstance(data, dict) else {}


def emit(event: str, **fields) -> None:
    print(json.dumps({"hookSpecificOutput": {"hookEventName": event, **fields}}, ensure_ascii=False))


def main(argv: list) -> int:
    cmd = argv[1] if len(argv) > 1 else ""
    try:
        data = hook_input()
        if cmd == "pre-tool":
            reason = decide(data.get("tool_name"), data.get("tool_input"))
            if reason:  # the hub check reads the registry, so it comes after the cheap tests
                hc.use_cwd(data.get("cwd"))
                if is_hub(data.get("session_id"), os.environ.get("CLAUDE_CODE_HOST_SESSION_ID", "")):
                    emit("PreToolUse", permissionDecision="deny", permissionDecisionReason=reason)
        elif cmd == "session-start":
            hc.use_cwd(data.get("cwd"))
            if is_hub(data.get("session_id"), os.environ.get("CLAUDE_CODE_HOST_SESSION_ID", "")):
                emit("SessionStart", additionalContext=hc.DESKTOP_CARDS_LINE)
    except Exception:  # noqa: BLE001 — fail-open: a broken hook must not block a session
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
