#!/usr/bin/env python3
"""PreToolUse hook on Write|Edit: a HANDOFF-*.md file must stay <= 15 KiB (15360 bytes UTF-8).

Scope: only files in the hub home, in a repository with `.agent-hub/`, or under AGENT_HUB_SCOPE_DIRS (hub home
config.json); a HANDOFF-*.md anywhere else on the machine is not this plugin's business.

A handoff is read by a fresh session as its entry point; a long one burns the successor's context
before any work starts. Write: size of tool_input.content. Edit: read the current file, apply
old_string -> new_string (all occurrences when replace_all), measure the result. The limit is
overridable by $AGENT_HUB_HANDOFF_MAX_BYTES or the hub home's config.json. Fail-open: any error of its own (bad input, unreadable
file, old_string not found) -> exit 0, no output.
"""
from __future__ import annotations

if __name__ == "__main__":  # fail-safe first, before anything that can fail: see hooks/failsafe.py
    try:
        import failsafe

        failsafe.install()
    except Exception:  # noqa: BLE001 — without it the hook is as it was
        pass

import fnmatch
import json
import os
import sys
from pathlib import Path

from codex_compat import patch_contents

REASON = (
    "Handoff is {size} bytes > {limit}. Shorten it: follow the Delamain handoff template "
    "(templates/HANDOFF-template.md in the plugin; ≤ 12 KB, chronology goes to journal-<date>.md) and continue "
    "in a new session from it."
)


def hubcore():
    root = os.environ.get("PLUGIN_ROOT") or os.environ.get("CLAUDE_PLUGIN_ROOT") or os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
    sys.path.insert(0, os.path.join(root, "bin"))
    import hubcore as hc  # noqa: E402

    return hc


def hub_setting(name: str):
    """$NAME, else the hub home's config.json (hubcore.setting from the plugin's bin/)."""
    return hubcore().setting(name)


def main() -> None:
    data = json.loads(sys.stdin.read() or "{}")
    if not isinstance(data, dict) or data.get("hook_event_name", "PreToolUse") != "PreToolUse":
        return
    tool = data.get("tool_name")
    ti = data.get("tool_input") or {}
    if tool == "apply_patch":
        hc = hubcore()
        hc.use_cwd(data.get("cwd"))
        cwd = data.get("cwd") or os.getcwd()
        try:
            limit = int(hub_setting("AGENT_HUB_HANDOFF_MAX_BYTES") or 15360)
        except ValueError:
            limit = 15360
        for _, target, content in patch_contents(ti.get("command"), cwd):
            if target is None or content is None or not fnmatch.fnmatchcase(os.path.basename(target), "HANDOFF-*.md"):
                continue
            if not hc.in_scope(os.path.join(cwd, target)):
                continue
            size = len(content.encode("utf-8"))
            if size > limit:
                deny(size, limit)
                return
        return
    fp = ti.get("file_path")
    if tool not in ("Write", "Edit") or not isinstance(fp, str):
        return
    if not fnmatch.fnmatchcase(os.path.basename(fp), "HANDOFF-*.md"):
        return
    hubcore().use_cwd(data.get("cwd"))
    if not hubcore().in_scope(os.path.join(data.get("cwd") or os.getcwd(), fp)):
        return
    try:
        limit = int(hub_setting("AGENT_HUB_HANDOFF_MAX_BYTES") or 15360)
    except ValueError:
        print("handoff_size: AGENT_HUB_HANDOFF_MAX_BYTES is not a whole number; using 15360", file=sys.stderr)
        limit = 15360

    if tool == "Write":
        content = ti.get("content")
        if not isinstance(content, str):
            return
    else:
        old, new = ti.get("old_string"), ti.get("new_string")
        if not isinstance(old, str) or not isinstance(new, str):
            return
        cur = (Path(data.get("cwd") or os.getcwd()) / fp).read_text(encoding="utf-8")
        if old == "":
            content = new if cur == "" else None
        elif old not in cur:
            content = None  # the Edit itself will fail; not our business
        else:
            content = cur.replace(old, new) if ti.get("replace_all") else cur.replace(old, new, 1)
        if content is None:
            return

    size = len(content.encode("utf-8"))
    if size <= limit:
        return
    deny(size, limit)


def deny(size, limit):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": REASON.format(size=size, limit=limit),
    }}, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
