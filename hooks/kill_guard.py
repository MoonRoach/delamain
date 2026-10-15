#!/usr/bin/env python3
"""Kill guard: a PreToolUse hook on Bash that refuses to kill processes by name or pattern.

A pattern matches every process of the user whose name or command line contains it: other agents, the hub, the
desktop app. On 14.10 one agent cleaned up its test sleeps with `pkill -f "[s]leep 300" -P 1`; macOS (BSD) `pkill`
stops reading options at the first pattern, so `-P` and `1` became two more patterns, and `1` matched nearly every
process: Claude Desktop and four headless agents got SIGTERM. Only the agent itself survived, since `pkill` skips its
own ancestors. No detachment protects a process from a signal sent to its pid.

Denied (foreground and background commands alike):

* `pkill` and `killall` as a command (after `sudo` / `env` / `timeout` / `if` / `!` …, inside `bash -c "…"` too);
* `kill $(pgrep …)`, `` kill `pgrep …` `` and `pgrep … | xargs kill`: the same pattern kill in two steps.

The escape marker `# kill-ok: <reason>` (AGENT_HUB_KILL_ESCAPE) lets a deliberate pattern kill through, with the
reason in the transcript — except a `pkill` with an option or a second pattern after the first pattern: on macOS that
is never what the command says. Quoted text no shell runs (`git commit -m "… pkill …"`, `grep pkill`) is data, read
the way hooks/polling_guard.py reads it.

Settings (environment, the repository's .agent-hub/config.json, or the hub home's config.json):
  AGENT_HUB_KILL_GUARD   on | off (default on)
  AGENT_HUB_KILL_ESCAPE  kill-ok
Fail-open: an error of its own never blocks a command.
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

import polling_guard as pg

DEFAULT_ESCAPE = "kill-ok"

# What may stand before the command word: shell keywords (`if ! pkill …; then`), then polling_guard's prefix
# (a group opener, `VAR=x`, sudo / env / nohup / timeout …).
_HEAD = r"^\s*(?:(?:if|then|else|elif|do|while|until|!)\s+)*" + pg._CMD_PREFIX[1:]
_PATTERN_KILL = re.compile(_HEAD + r"(?:\S*/)?(pkill|killall)(?![\w.-])(.*)$", re.DOTALL)
_KILL_SUBST = re.compile(_HEAD + r"(?:\S*/)?kill(?![\w.-]).*?(?:\$\(|`)\s*(?:\S*/)?pgrep\b", re.DOTALL)
_PGREP = re.compile(_HEAD + r"(?:\S*/)?pgrep(?![\w.-])")
_XARGS_KILL = re.compile(_HEAD + r"(?:\S*/)?xargs\b.*?(?:^|\s)(?:\S*/)?kill(?![\w.-])", re.DOTALL)
_REDIRECT = re.compile(r"^(?:\d+|&)?(?:[<>]{1,2}|>&|<&)(\S*)$")
# pkill options that take a value (BSD and procps), short and long.
_VALUE_SHORT = set("FGgJMNPstUuc")
_VALUE_LONG = {"--signal", "--parent", "--pgroup", "--session", "--euid", "--uid", "--group", "--terminal",
               "--pidfile", "--ns", "--nslist", "--runstates", "--env", "--cgroup"}

INSTEAD = """Instead:
  • a process you started — `kill <pid>`: keep `$!` after starting it in the background, or the pid it printed;
  • a group you started with `setsid` — `kill -- -<pgid>`;
  • a Delamain agent — `agent stop <role>`;
  • a pid you do not know yet — `pgrep -lf '<pattern>'` first (options before the pattern), read the list, then
    `kill <pid>` in the next command.

If the pattern kill is deliberate, add the comment `# {escape}: <reason>` to the command; the reason stays in the
transcript."""


def _trap(args: str):
    """Why a `pkill` argument list does not mean what it says on macOS, or None: an option or a second pattern after
    the first pattern."""
    words = args.split()
    pattern, i = None, 0
    while i < len(words):
        w = words[i]
        if w.startswith("#"):  # a comment ends the command
            break
        redirect = _REDIRECT.match(w)
        if redirect:  # `2>/dev/null`, `> out`: not an argument
            i += 1 if redirect.group(1) else 2
            continue
        if pattern is not None:
            if w.startswith("-"):
                return (f"`{w}` stands after the pattern: macOS (BSD) `pkill` stops reading options at the first "
                        f"pattern, so `{w}` and what follows are more patterns — `pkill -f \"[s]leep 300\" -P 1` "
                        "matched `1` and signalled nearly every process. Options go before the pattern.")
            return (f"`{w}` is a second pattern: macOS (BSD) `pkill` signals every process that matches any of "
                    "them.")
        if w == "--":
            pattern = words[i + 1] if i + 1 < len(words) else None
            i += 2
            continue
        if w.startswith("--"):
            i += 1 if "=" in w or w not in _VALUE_LONG else 2
            continue
        if w.startswith("-") and len(w) > 1:
            signal = w[1:].isdigit() or (len(w) > 2 and w[1:].isupper())  # `-9`, `-TERM`, `-SIGKILL`
            i += 2 if w[-1] in _VALUE_SHORT and not signal else 1
            continue
        pattern = w
        i += 1
    return None


def _segments(text: str):
    return [s for s in pg._SEGMENT_SEP.split(text) if s.strip()]


def check(command: str):
    """(reason, overridable) of a denial, or None."""
    executed, quoted, _ = pg.views(command)
    for seg in _segments(executed):
        m = _PATTERN_KILL.match(seg)
        if not m:
            continue
        trap = _trap(m.group(2)) if m.group(1) == "pkill" else None
        if trap:
            return f"This is `{seg.strip()}`. {trap}", False
        return f"This is `{seg.strip()}` — a kill by name or pattern.", True
    segs = _segments(quoted)
    for i, seg in enumerate(segs):
        if _KILL_SUBST.match(seg) or (_PGREP.match(seg) and i + 1 < len(segs) and _XARGS_KILL.match(segs[i + 1])):
            return f"This is `{seg.strip()}` — a kill of whatever `pgrep` matches.", True
    return None


def message(reason: str, overridable: bool, escape_word: str) -> str:
    head = ("Killing processes by name or pattern is not run (Delamain kill guard): a pattern matches every process "
            "of yours whose name or command line contains it — other agents, the hub, the desktop app.")
    tail = INSTEAD.format(escape=escape_word)
    if not overridable:
        tail = tail.rsplit("\n\n", 1)[0] + "\n\nThe escape comment does not pass this one: fix the argument order."
    return f"{head}\n\n{reason}\n\n{tail}"


def main() -> int:
    try:
        event = json.load(sys.stdin)
    except ValueError:
        return 0
    if not isinstance(event, dict) or event.get("tool_name") != "Bash":
        return 0
    command = (event.get("tool_input") or {}).get("command")
    if not isinstance(command, str):
        return 0
    try:
        hc = pg.hubcore()
        hc.use_cwd(event.get("cwd"))
        enabled = hc.setting("AGENT_HUB_KILL_GUARD", cwd=event.get("cwd")) or "on"
        escape_word = (hc.setting("AGENT_HUB_KILL_ESCAPE", cwd=event.get("cwd")) or DEFAULT_ESCAPE).strip()
    except Exception:  # noqa: BLE001 — without the plugin's bin/ the built-in defaults still apply
        enabled, escape_word = "on", DEFAULT_ESCAPE
    if enabled.strip().lower() in ("off", "0", "false", "no"):
        return 0
    res = check(command)
    if not res:
        return 0
    reason, overridable = res
    tail = r"\b" if re.match(r"\w", escape_word[-1:]) else ""
    if overridable and re.search(r"#\s*" + re.escape(escape_word) + tail, command):
        return 0
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": message(reason, overridable, escape_word),
    }}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    try:
        code = main()
    except Exception:  # noqa: BLE001 — fail-open
        code = 0
    sys.exit(code)
