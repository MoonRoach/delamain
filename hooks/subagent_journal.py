#!/usr/bin/env python3
"""Journal the start and the end of every sub-agent (the Agent tool) of a registered session.

Hook subcommands (hook JSON on stdin), both `async` in hooks/hooks.json, so neither delays the sub-agent:
  start  SubagentStart: `- HH:MM [<parent tag>/<agent id>] SUB start <agent type> <model>: <description>`
  stop   SubagentStop:  `- HH:MM [<parent tag>/<agent id>] SUB end done|error`

The parent is the payload's session (or a Desktop restart of it, hubcore.session_matches) as a role in a stage's
registry ($HUB_STAGE first); the line goes to that stage's journal under a sub-tag of the role's tag, so `hub why`,
the history and agent-top see it beside the role's own lines. The payload carries no description or model: they come
from the sub-agent's `agent-<id>.meta.json` beside the parent's transcript, which Claude Code (2.1.299) writes only
after the synchronous SubagentStart hooks have returned, so the start hook waits for it up to META_WAIT_S.
The lines are for the record and wake nobody: status words of the description are lower-cased and `@` is dropped
(hubcore.quiet), and jwait passes over sub-agent lines altogether (hubcore.sub_agent_line).
Fail-open: an unregistered session, an unreadable registry, any error — nothing is written and the sub-agent runs.
Codex has no such events: its sub-agents are not journaled.
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
import re
import sys
import time
from pathlib import Path

PLUGIN_ROOT = os.environ.get("PLUGIN_ROOT") or os.environ.get("CLAUDE_PLUGIN_ROOT") or os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
sys.path.insert(0, os.path.join(PLUGIN_ROOT, "bin"))
try:
    import hubcore as hc  # noqa: E402
except Exception:  # noqa: BLE001 — fail-open: as a hook, never block a sub-agent over an import error
    if len(sys.argv) > 1 and sys.argv[1] in ("start", "stop"):
        sys.exit(0)
    raise

AGENT_ID_RE = re.compile(r"[A-Za-z0-9_-]{1,64}")
META_WAIT_S = 3.0  # the meta file appeared at once after the sync hooks in the 2.1.299 probe; then the line goes without it
META_POLL_S = 0.05
DESCRIPTION_MAX = 120
TAIL_BYTES = 256 * 1024  # how much of the sub-agent's transcript the end check reads


def hook_input() -> dict:
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return {}
    return data if isinstance(data, dict) else {}


def parent_role(session_id, host_id="") -> tuple | None:
    """(stage, tag) of the session as a role of some stage's registry, $HUB_STAGE first; None when unregistered or
    unreadable."""
    sid = session_id if isinstance(session_id, str) else ""
    if not sid:
        return None
    host = host_id if isinstance(host_id, str) and host_id.startswith("local_") else ""
    try:
        stages = sorted(d.name for d in hc.root().iterdir() if (d / "roles.json").is_file())
    except OSError:
        return None
    own = os.environ.get("HUB_STAGE", "").strip()
    if own in stages:
        stages.remove(own)
        stages.insert(0, own)
    for stage in stages:
        try:
            roles = hc.roles_load(stage)["roles"]
        except (hc.Failure, hc.UsageError, OSError, ValueError, AttributeError, TypeError):
            continue  # one unreadable registry must not hide the role in another stage
        for name, rec in roles.items():
            if hc.session_matches(rec, sid, host):
                return stage, (rec.get("tag") or name)
    return None


def meta_path(data: dict, agent_id: str) -> Path | None:
    tp = data.get("transcript_path")
    if not isinstance(tp, str) or not tp.endswith(".jsonl"):
        return None
    return Path(tp[: -len(".jsonl")]) / "subagents" / f"agent-{agent_id}.meta.json"


def read_meta(path: Path | None, wait_s: float) -> dict:
    deadline = time.monotonic() + wait_s
    while path is not None:
        try:
            meta = json.loads(path.read_text(encoding="utf-8"))
            return meta if isinstance(meta, dict) else {}
        except (OSError, ValueError):
            if time.monotonic() >= deadline:
                return {}
            time.sleep(META_POLL_S)  # not there yet, or half-written
    return {}


def ended_with_error(path) -> bool:
    """Whether the sub-agent's last assistant message in its transcript is an API error."""
    if not isinstance(path, str) or not path:
        return False
    try:
        with open(path, "rb") as fh:
            size = os.fstat(fh.fileno()).st_size
            fh.seek(max(0, size - TAIL_BYTES))
            lines = fh.read().splitlines()
    except OSError:
        return False
    for line in reversed(lines):
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if isinstance(ev, dict) and ev.get("type") == "assistant":
            return bool(ev.get("isApiErrorMessage") or ev.get("error"))
    return False


def line_text(cmd: str, data: dict, agent_id: str) -> str:
    if cmd == "start":
        meta = read_meta(meta_path(data, agent_id), META_WAIT_S)
        kind = meta.get("agentType") or data.get("agent_type") or "agent"
        model = meta.get("model") or "inherit"
        desc = hc.one_line(str(meta.get("description") or ""))[:DESCRIPTION_MAX]
        return hc.quiet(f"SUB start {hc.one_line(str(kind))} {hc.one_line(str(model))}: {desc}".rstrip(": "))
    return "SUB end " + ("error" if ended_with_error(data.get("agent_transcript_path")) else "done")


def main(argv: list) -> int:
    cmd = argv[1] if len(argv) > 1 else ""
    try:
        if cmd not in ("start", "stop"):
            return 0
        data = hook_input()
        agent_id = data.get("agent_id")
        if not isinstance(agent_id, str) or not AGENT_ID_RE.fullmatch(agent_id):
            return 0
        hc.use_cwd(data.get("cwd"))
        hit = parent_role(data.get("session_id"), os.environ.get("CLAUDE_CODE_HOST_SESSION_ID", ""))
        if hit:
            stage, tag = hit
            hc.journal_append(stage, f"{tag}/{agent_id}", line_text(cmd, data, agent_id))
    except Exception:  # noqa: BLE001 — fail-open: a broken hook must not block a sub-agent
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
