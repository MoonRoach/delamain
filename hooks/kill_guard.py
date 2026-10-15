#!/usr/bin/env python3
"""Kill guard: a PreToolUse hook on Bash that refuses to kill processes by name or pattern.

A pattern matches every process of the user whose name or command line contains it: other agents, the hub, the
desktop app. On 14.10 one agent cleaned up its test sleeps with `pkill -f "[s]leep 300" -P 1`; macOS (BSD) `pkill`
stops reading options at the first pattern, so `-P` and `1` became two more patterns, and `1` matched nearly every
process: Claude Desktop and four headless agents got SIGTERM. Only the agent itself survived, since `pkill` skips its
own ancestors. No detachment protects a process from a signal sent to its pid.

Denied (foreground and background commands alike):

* `pkill`, `killall` and `killall5` as a command (after `sudo` / `env` / `timeout` / `eval` / `if` / `!` …, inside
  `bash -c "…"` too);
* the same pattern kill in two steps, with `pgrep`, `pidof` or a `grep` of `ps` output as the pid source: `kill $(pgrep …)`,
  `` kill `pidof …` ``, `pgrep … | sort | xargs kill`, and the loop or variable forms inside one command
  (`for p in $(pgrep …); do kill $p; done`, `pgrep … | while read p; do kill $p; done`, `P=$(pgrep …); kill $P`).

A segment whose command word is `ssh` runs somewhere else and is not read.

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
_HEAD = r"^\s*(?:(?:if|then|else|elif|do|while|until|eval|!)\s+)*" + pg._CMD_PREFIX[1:]
_PATTERN_KILL = re.compile(_HEAD + r"(?:\S*/)?(pkill|killall5?)(?![\w.-])(.*)$", re.DOTALL)
_KILL = re.compile(_HEAD + r"(?:\S*/)?kill(?![\w.-])")
_PGREP = re.compile(_HEAD + r"(?:\S*/)?(?:pgrep|pidof)(?![\w.-])")  # a name lookup: its output is pids
_GREP = re.compile(_HEAD + r"(?:\S*/)?grep(?![\w.-])")  # a pid source after a `ps` stage
_PS = re.compile(_HEAD + r"(?:\S*/)?ps(?![\w.-])")
_XARGS_KILL = re.compile(_HEAD + r"(?:\S*/)?xargs\b.*?(?:^|\s)(?:\S*/)?kill(?![\w.-])", re.DOTALL)
_FOR_IN = re.compile(r"^\s*for\s+\w+\s+in\s")
_ASSIGN = re.compile(r"^\s*(?:(?:export|local|declare|typeset|readonly)\s+(?:-\w+\s+)*)?\w+(?:\[[^\]]*\])?\+?=")
_WHILE_READ = re.compile(r"^\s*while\s+(?:IFS=\S*\s+)?read\b")
_SSH = re.compile(_HEAD + r"(?:\S*/)?ssh(?![\w.-])")
# Segments as polling_guard splits them, plus a single `&` (a background statement, not `&&`, `>&`, `&>`).
_SEGMENT_SPLIT = re.compile(r"(\|\||&&|\|\s*\n|[;|\n]|(?<![<>&|])&(?![&>]))")
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
                return (f"`{w}` stands after the pattern: procps `pkill` reads it as an option, but macOS (BSD) `pkill` "
                        f"stops reading options at the first pattern, so `{w}` and what follows are more patterns — "
                        "`pkill -f \"[s]leep 300\" -P 1` matched `1` and signalled nearly every process. Options "
                        "first means the same on both: write them before the pattern.")
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


def _split(text: str):
    """[(stage, separator after it)] of a command text, split at the top level only: what stands inside `$(…)` or
    backticks stays in its stage (read with `_substitutions`). A single `&` separates statements; a comment ends at
    the newline."""
    out, buf, stack, in_tick, i, n = [], [], [], False, 0, len(text)

    def flush(sep):
        stage = "".join(buf).strip()
        buf.clear()
        if stage:
            out.append((stage, sep))

    while i < n:
        c = text[i]
        if c == "\\":
            buf.append(text[i:i + 2])
            i += 2
            continue
        if c == "`":
            in_tick = not in_tick
        elif c == "$" and text.startswith("$(", i):
            stack.append("$")
            buf.append("$(")
            i += 2
            continue
        elif c == "(":
            stack.append("(")
        elif c == ")" and stack:
            stack.pop()
        if not in_tick and "$" not in stack:
            if c == "#" and (i == 0 or text[i - 1] in " \t\n;&|("):
                i = text.find("\n", i) if "\n" in text[i:] else n
                continue
            sep = None
            if c in ";\n":
                sep = c
            elif c == "|":
                sep = text[i:i + 2] if text[i:i + 2] in ("||", "|&") else "|"
            elif c == "&" and (text.startswith("&&", i) or (text[i - 1:i] not in ("<", ">", "|") and text[i + 1:i + 2] != ">")):
                sep = "&&" if text.startswith("&&", i) else "&"
            if sep:
                flush(sep)
                i += len(sep)
                continue
        buf.append(c)
        i += 1
    flush(";")
    return out


def _substitutions(stage: str):
    """Bodies of the `$(…)` and `` `…` `` in a stage (outermost ones; each body is read again for its own)."""
    bodies, i, n = [], 0, len(stage)
    while i < n:
        if stage[i] == "\\":
            i += 2
        elif stage.startswith("$(", i):
            depth, j = 1, i + 2
            while j < n and depth:
                depth += (stage[j] == "(") - (stage[j] == ")")
                j += 1
            bodies.append(stage[i + 2:j - 1 if depth == 0 else j])
            i = j
        elif stage[i] == "`":
            j = stage.find("`", i + 1)
            j = n if j == -1 else j
            bodies.append(stage[i + 1:j])
            i = j + 1
        else:
            i += 1
    return bodies


_MAX_NESTING = 8  # `$(…)` inside `$(…)`: deeper text is not read (and cannot exhaust the stack)


def _has_source(stages, depth: int = 0) -> bool:
    """Do these stage texts (of one pipeline, or of a `$(…)` body) produce pids by a name lookup: `pgrep`, `pidof`, or
    a `grep` after `ps`?"""
    for k, stage in enumerate(stages):
        if _PGREP.match(stage) or (_GREP.match(stage) and any(_PS.match(prev) for prev in stages[:k])):
            return True
        if depth < _MAX_NESTING and any(_has_source([st for st, _ in _split(body)], depth + 1)
                                        for body in _substitutions(stage)):
            return True
    return False


def _levels(text: str, depth: int = 0):
    """Every list of [(stage, separator)] in a command: the top level, then those inside every `$(…)` / backtick."""
    stages = _split(text)
    yield stages
    if depth < _MAX_NESTING:
        for stage, _ in stages:
            for body in _substitutions(stage):
                yield from _levels(body, depth + 1)


def _pipelines(stages):
    """Lists of (index, stage) joined by pipes."""
    out, cur = [], []
    for k, (stage, sep) in enumerate(stages):
        cur.append((k, stage))
        if sep not in ("|", "|&"):
            out.append(cur)
            cur = []
    if cur:
        out.append(cur)
    return out


def _drop_ssh(command: str, keep_line: bool = False) -> str:
    """The command without the segments whose command word is `ssh`: they run on another machine. `keep_line`: see
    `polling_guard.strip_heredocs`."""
    if "ssh" not in command:
        return command
    protected, strings = pg._protect(pg.strip_heredocs(command.replace("\x00", "").replace("\\\n", " "), keep_line))
    parts = _SEGMENT_SPLIT.split(protected)
    return "".join("ssh" if i % 2 == 0 and _SSH.match(part) else pg._TOKEN.sub(lambda m: strings[int(m.group(1))], part)
                   for i, part in enumerate(parts))


def check(command: str):
    """(reason, overridable) of a denial, or None."""
    executed = pg.views(_drop_ssh(command), True)[0]
    levels = list(_levels(executed))
    for stages in levels:
        for stage, _ in stages:
            m = _PATTERN_KILL.match(stage)
            if not m:
                continue
            trap = _trap(m.group(2)) if m.group(1) == "pkill" else None
            if trap:
                return f"This is `{stage}`. {trap}", False
            return f"This is `{stage}` — a kill by name or pattern.", True
    for stages in levels:
        texts = [st for st, _ in stages]
        for k, stage in enumerate(texts):
            if _KILL.match(stage) and any(_has_source([st for st, _ in _split(body)]) for body in _substitutions(stage)):
                return f"This is `{stage}` — a kill of whatever a name lookup (`pgrep`, `pidof`, `ps | grep`) matches.", True
        for pipe in _pipelines(stages):
            for j, (k, stage) in enumerate(pipe):
                if _XARGS_KILL.match(stage) and _has_source([st for _, st in pipe[:j]]):
                    return f"This is `{stage}` after a name lookup — a kill of whatever it matches.", True
        # The same kill in two statements: a pid source in the header of a `for`, a `VAR=$(…)`, or piped into
        # `while read`, and a `kill` later in the command.
        flagged = None
        for pipe in _pipelines(stages):
            for j, (k, stage) in enumerate(pipe):
                bodies = _substitutions(stage)
                source = any(_has_source([st for st, _ in _split(body)]) for body in bodies)
                if (source and (_FOR_IN.match(stage) or _ASSIGN.match(stage))) or (
                        _WHILE_READ.match(stage) and _has_source([st for _, st in pipe[:j]])):
                    flagged = k
                    break
            if flagged is not None:
                break
        if flagged is not None:
            for stage in texts[flagged + 1:]:
                if _KILL.match(stage):
                    return (f"This is `{texts[flagged]}` and later `{stage}` — a kill of whatever a name lookup "
                            "(`pgrep`, `pidof`, `ps | grep`) matches.", True)
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
