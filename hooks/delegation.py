#!/usr/bin/env python3
"""Delegation dial (levels 0-5) and subagent rules.

Hook subcommands (hook JSON on stdin):
  session-start  SessionStart: inject the policy text of the session's level           (only when the dial is on)
  prompt         UserPromptSubmit: re-inject it when the level changed since the last injection (dial on); and, dial
                 on or off, a note when the prompt starts with the slash command of a skill under the plugin's former
                 name (a successor started by an older hub), see former_name_context()
  pre-tool       PreToolUse on Agent|Task|Workflow: AGENT_HUB_DELEGATION_RULES (dial on; may test the level),
                 then AGENT_HUB_EFFORT_RULES (always, Agent/Task only) — the first deny wins

CLI subcommands (the /delegation skill, through bin/delegation):
  show                print the level, where it comes from, and its policy
  set N [--global]    this session's override (needs $CLAUDE_CODE_SESSION_ID), or the default for all sessions
  clear               drop this session's override
  try [TYPE [MODEL]] [--tool T] [--type NAME] [--model M]   evaluate the rules for a hypothetical Agent call

Settings (hub home config.json or environment; see docs/reference.md "Agent discipline"):
  AGENT_HUB_DELEGATION          on | off (default off)
  AGENT_HUB_DELEGATION_DEFAULT  level when nothing else is set (default 3)
  AGENT_HUB_DELEGATION_LEVEL    environment only: the level for every session started with it
  AGENT_HUB_DELEGATION_LEVELS   {"0": {"name": "OFF", "policy": "…"}, …} — replaces the built-in texts per level
  AGENT_HUB_DELEGATION_COMMON   text appended to every level's policy
  AGENT_HUB_DELEGATION_RULES    rule list (bin/subagent_rules.py); default: level 0 denies Agent, Task, Workflow
  AGENT_HUB_EFFORT_RULES        rule list (or shorthand) for every subagent launch, also applied by `agent spawn`;
                                the user's and the repository's sets both apply, any deny wins (default none)
  AGENT_HUB_STATE_DIR           state directory (default <hub home>/.state); levels live in <state>/delegation/

Resolution of the level: this session's override > $AGENT_HUB_DELEGATION_LEVEL > the global level (set --global)
> AGENT_HUB_DELEGATION_DEFAULT > 3. Fail-open: an error of its own never blocks a tool call.
"""
from __future__ import annotations

import json
import os
import re
import sys
import time
from pathlib import Path

if __name__ == "__main__" and sys.argv[1:2] in (["session-start"], ["prompt"], ["pre-tool"]):  # hook mode: see hooks/failsafe.py
    try:
        import failsafe

        failsafe.install()
    except Exception:  # noqa: BLE001 — without it the hook is as it was
        pass

sys.path.insert(0, str(Path(__file__).resolve().parent))  # bin/delegation loads this module by filename
from codex_compat import agent_call as codex_agent_call, native_tool, policy_tool

PLUGIN_ROOT = os.environ.get("PLUGIN_ROOT") or os.environ.get("CLAUDE_PLUGIN_ROOT") or os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
sys.path.insert(0, os.path.join(PLUGIN_ROOT, "bin"))
try:
    import hubcore as hc  # noqa: E402
    import subagent_rules as sr  # noqa: E402
except Exception:  # noqa: BLE001 — fail-open: as a hook, never block a session over an import error
    if len(sys.argv) > 1 and sys.argv[1] in ("session-start", "prompt", "pre-tool"):
        sys.exit(0)
    raise

PRUNE_AFTER_DAYS = 30
LEVELS = range(0, 6)
# rename:transition — the plugin's name before the rename. A hub on an older plugin copy starts its successor with the prompt
# `/agent-hub:hub take over stage …` (the command before the rename); the successor is a new session that has only this
# plugin's `/delamain:hub`, and a model that gets an unknown slash command as plain text may refuse to follow it
# (Haiku did, CLI 2.1.289).
FORMER_PLUGIN = sr.LEGACY_PLUGIN_NAME  # rename:transition
# rename:transition
# The owner asking to be grilled, in Russian or English: «грилинг», «грилл ми», «погриль», «грильни», "grill me",
# "grilling", /…:grill-me. Not a barbecue grill («гриль», «грили», "grilled cheese") nor a path (skills/grilling/).
GRILL_RE = re.compile(r"грилл?инг|грилл?\s*ми|погрилл?[ьи]|грилл?ьн|\bgrill\s+me\b|\bgrilling\b(?![/.])|:grill-me\b",
                      re.IGNORECASE)
FORMER_COMMAND_RE = re.compile(r"\s*/" + re.escape(FORMER_PLUGIN) + r":([A-Za-z0-9][A-Za-z0-9_-]*)(?=\s|\Z)")
BUILTIN_LEVELS = {
    0: ("OFF", "Do everything yourself. No subagents (the Agent and Workflow tools are blocked by a hook) and no "
               "background sessions for your own work; parallelise with background Bash if needed."),
    1: ("MINIMAL", "Work yourself by default. Delegate only when the user asks for it explicitly, or when a piece "
                   "must run isolated (for example an executor in its own worktree). Searches, file reading and "
                   "probes: yourself."),
    2: ("ECONOMICAL", "Delegate only large independent pieces: an executor for a specified change, a review by a "
                      "model other than the author, reading another repository. Anything under about ten tool "
                      "calls you do yourself; do not start a subagent for a single search."),
    3: ("BALANCED", "Delegate mechanical work with a checkable answer (searches, log reading, test runs) to a "
                    "small fast model and bounded work from a finished design to a mid-size one; keep framing, "
                    "decisions and the final synthesis. Delegate when a third search pass comes up or another "
                    "repository needs reading whole."),
    4: ("DELEGATION-FIRST", "Read only what you need to decide. Exploration beyond about three files and every "
                            "code change go to a subagent; independent pieces run in parallel and in the "
                            "background. You keep decisions, communication with the user, merges and the "
                            "synthesis."),
    5: ("ORCHESTRATOR", "Hands-off. You read subagent reports, decide, talk to the user and run git operations; "
                        "everything else, including a single search or a one-line edit, goes to a subagent with a "
                        "full brief. Keep your own context small: a fresh agent per stage over resuming a long one."),
}
BUILTIN_COMMON = ("The level sets how much you delegate, not which model or effort; the subagent rules still "
                  "apply. Name the level when you report what you delegated.")
DEFAULT_DELEGATION_RULES = [
    {"when": {"level": "0", "tool": ["Agent", "Task", "Workflow"]}, "decision": "deny",
     "reason": "Delegation level is 0 ({source}): do this yourself. The user can raise it with /delegation."},
]


def enabled() -> bool:
    return hc.truthy(hc.setting("AGENT_HUB_DELEGATION"))


def state_root() -> Path:
    raw = hc.setting("AGENT_HUB_STATE_DIR")
    return (Path(raw).expanduser() if raw else hc.root() / ".state") / "delegation"


def parse_level(raw) -> int | None:
    try:
        n = int(str(raw).strip())
    except (ValueError, TypeError):
        return None
    return n if n in LEVELS else None


def read_level(path: Path) -> int | None:
    try:
        return parse_level(path.read_text())
    except OSError:
        return None


def resolve(session_id: str | None) -> tuple:
    root = state_root()
    if session_id:
        n = read_level(root / "sessions" / session_id)
        if n is not None:
            return n, "session override"
    n = parse_level(os.environ.get("AGENT_HUB_DELEGATION_LEVEL", ""))
    if n is not None:
        return n, "env AGENT_HUB_DELEGATION_LEVEL"
    n = read_level(root / "level")
    if n is not None:
        return n, "global (set --global)"
    n = parse_level(hc.setting("AGENT_HUB_DELEGATION_DEFAULT") or "")
    if n is not None:
        return n, "AGENT_HUB_DELEGATION_DEFAULT"
    return 3, "built-in default"


def policy(level: int) -> str:
    name, text = BUILTIN_LEVELS[level]
    custom = hc.setting_json("AGENT_HUB_DELEGATION_LEVELS", {}) or {}
    entry = custom.get(str(level)) if isinstance(custom, dict) else None
    if isinstance(entry, dict):
        name, text = str(entry.get("name") or name), str(entry.get("policy") or text)
    elif isinstance(entry, str):
        text = entry
    common = hc.setting("AGENT_HUB_DELEGATION_COMMON")
    common = BUILTIN_COMMON if common is None else common
    if os.environ.get("AGENT_HUB_ENGINE") == "codex" and level == 0:
        text = ("Do everything yourself. No subagents or background sessions for your own work. "
                "Supported spawn_agent/resume_agent tool calls are blocked by the hook; shell-launched "
                "sessions and specialized runtime paths are outside this tool guard.")
    return f"Delegation level {level}/5 ({name}). {text} {common}".strip()


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def prune() -> None:
    cutoff = time.time() - PRUNE_AFTER_DAYS * 86400
    for d in (state_root() / "sessions", state_root() / "injected"):
        if not d.is_dir():
            continue
        for f in d.iterdir():
            try:
                if f.stat().st_mtime < cutoff:
                    f.unlink()
            except OSError:
                pass


def plugin_name() -> str:  # rename:transition (only former_name_context uses it)
    """This plugin's name (the namespace of its skills), from its manifest."""
    for manifest in (".claude-plugin", ".codex-plugin"):
        try:
            name = json.loads((Path(PLUGIN_ROOT) / manifest / "plugin.json").read_text(encoding="utf-8")).get("name")
        except (OSError, ValueError, AttributeError):
            continue
        if isinstance(name, str) and name:
            return name
    return "delamain"


def own_skills() -> set:  # rename:transition (only former_name_context uses it)
    """The names of this plugin's skills: the folders under skills/ that hold a SKILL.md (read, never a list to go stale)."""
    return {p.parent.name for p in (Path(PLUGIN_ROOT) / "skills").glob("*/SKILL.md")}


def former_name_context(prompt) -> str | None:  # rename:transition
    """A note for the model when the prompt starts with `/agent-hub:<skill>` (the command before the rename) and <skill> is
    one of this plugin's skills, else None: the harness does not know the former slash command and hands it to the model as text. Any other prompt
    (plain text, `/delamain:…`, another plugin's `/foo:hub`, an unknown skill) gets nothing. The text names no tool and
    decides nothing, so it is harmless where the former command never arrives (Codex)."""
    m = FORMER_COMMAND_RE.match(prompt) if isinstance(prompt, str) else None
    if not m:  # nearly every prompt: no file is read for it
        return None
    name, plugin = m.group(1), plugin_name()
    if plugin == FORMER_PLUGIN or name not in own_skills():
        return None
    return (f"`/{FORMER_PLUGIN}:{name}` is the former name of this plugin's skill `/{plugin}:{name}` (the plugin "
            f"{FORMER_PLUGIN} was renamed to {plugin}). Invoke the skill {sr.named(name, plugin)} and carry out the "
            f"rest of the prompt as its arguments.")


def grilling_context(prompt) -> str | None:
    """A note for the model when the owner's prompt asks for grilling, else None. Free-text Russian («грилинг») did not
    make hub models load the companion skill (14.10: 2 of 2 hub sessions answered in their own question format), so
    the hook names it; the text is engine-neutral and decides nothing else."""
    if not isinstance(prompt, str) or not GRILL_RE.search(prompt):
        return None
    return ("The owner's prompt looks like a request for grilling. If it is one, before replying load the companion "
            "grilling skill (Claude Code: the Skill tool with `mattpocock-skills:grilling`; Codex: the `grilling` "
            "skill) and run it as written: rounds of numbered questions, each with a recommended answer, in its "
            "format, until the frontier of the topic the owner named is empty; facts you can look up are yours, not "
            "questions. A hub's own question format (A/B with a default and a due time) and its \"stop once the "
            "business result is clear\" limit do not apply to a grilling the owner asked for, and its decisions wait "
            "for the owner's answers: a recommendation is not a default taken on silence. If the prompt only mentions "
            "grilling, ignore this note. If the skill is not installed, say so once and follow the same method.")


def emit(event: str, **fields) -> None:
    print(json.dumps({"hookSpecificOutput": {"hookEventName": event, **fields}}, ensure_ascii=False))


def decide(tool: str, tool_input: dict, cwd, session_id) -> str | None:
    """The deny reason for one Agent/Task/Workflow call, or None."""
    level, source = resolve(session_id) if enabled() else (None, "dial off")
    native = native_tool(tool)
    call = (codex_agent_call(tool, tool_input, cwd, level) if native in ("spawn_agent", "resume_agent")
            else sr.agent_call(policy_tool(tool), tool_input, cwd, level))
    call["source"] = source
    if level is not None:
        rules = hc.setting_json("AGENT_HUB_DELEGATION_RULES", None)
        label = "AGENT_HUB_DELEGATION_RULES"
        defaults = DEFAULT_DELEGATION_RULES
        # These native calls start another turn on an existing agent. A pure message
        # (send_message) does not reactivate an idle agent and keeps its own policy.
        if native in ("send_input", "followup_task"):
            defaults = [*defaults, {"when": {"level": "0", "tool": "SendMessage"}, "decision": "deny",
                                    "reason": "Delegation level is 0 ({source}): do this yourself."}]
        res = sr.evaluate(defaults if rules is None else rules, call, label)
        if res and res[0] == "deny":
            return sr.deny_reason(res, label)
    if tool in ("Agent", "Task") or native == "spawn_agent":
        return sr.check_effort(call, cwd)
    return None


def hook_input() -> dict:
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return {}
    return data if isinstance(data, dict) else {}


def main(argv: list) -> int:
    cmd = argv[1] if len(argv) > 1 else "show"

    if cmd in ("session-start", "prompt"):
        try:
            data = hook_input()
            hc.use_cwd(data.get("cwd"))  # the hub home (its .state, its config.json) of the session's directory
            event = "SessionStart" if cmd == "session-start" else "UserPromptSubmit"
            parts = []
            if enabled():
                sid = data.get("session_id")
                level, _ = resolve(sid)
                marker = state_root() / "injected" / sid if sid else None
                if cmd == "session-start":
                    if marker:
                        write(marker, str(level))
                    prune()
                    parts.append(policy(level))
                elif (read_level(marker) if marker else None) != level:
                    if marker:
                        write(marker, str(level))
                    parts.append(f"Delegation level changed to {level}. " + policy(level))
            # rename:transition — independent of the dial: it is about the prompt, not about delegation
            if cmd == "prompt":
                for note in (former_name_context(data.get("prompt")), grilling_context(data.get("prompt"))):
                    if note:
                        parts.append(note)
            if parts:
                emit(event, additionalContext="\n\n".join(parts))
        except Exception:  # noqa: BLE001 — fail-open
            pass
        return 0

    if cmd == "pre-tool":
        try:
            data = hook_input()
            hc.use_cwd(data.get("cwd"))
            tool = data.get("tool_name")
            if policy_tool(tool) in ("Agent", "Task", "Workflow", "SendMessage"):
                reason = decide(tool, data.get("tool_input") or {}, data.get("cwd"), data.get("session_id"))
                if reason:
                    emit("PreToolUse", permissionDecision="deny", permissionDecisionReason=reason)
        except Exception:  # noqa: BLE001 — fail-open: a broken hook must not block every session
            pass
        return 0

    sid = hc.session_id()
    off_note = "" if enabled() else ("\n(the delegation dial is off: no policy is injected and level rules do not "
                                     "apply; set AGENT_HUB_DELEGATION to on in the hub home's config.json)")

    if cmd == "show":
        level, source = resolve(sid)
        print(f"level={level} source={source}\n{policy(level)}{off_note}")
        return 0

    if cmd == "set":
        n = parse_level(argv[2]) if len(argv) > 2 else None
        if n is None:
            print("usage: delegation set N [--global]   (N = 0..5)", file=sys.stderr)
            return 2
        if "--global" in argv[3:]:
            write(state_root() / "level", f"{n}\n")
            scope = "global default"
        else:
            if not sid:
                print("No session id is set (CLAUDE_CODE_SESSION_ID/CODEX_THREAD_ID/AGENT_SESSION_ID); use --global",
                      file=sys.stderr)
                return 2
            write(state_root() / "sessions" / sid, f"{n}\n")
            scope = f"session {sid}"
        level, source = resolve(sid)
        if sid:
            write(state_root() / "injected" / sid, str(level))
        print(f"set {n} for {scope}; effective level={level} ({source})\n{policy(level)}{off_note}")
        return 0

    if cmd == "clear":
        if sid:
            try:
                (state_root() / "sessions" / sid).unlink()
            except FileNotFoundError:
                pass
        level, source = resolve(sid)
        if sid:
            write(state_root() / "injected" / sid, str(level))
        print(f"session override cleared; effective level={level} ({source})\n{policy(level)}{off_note}")
        return 0

    if cmd == "try":
        import argparse

        p = argparse.ArgumentParser(prog="delegation try")
        p.add_argument("--tool", default="Agent")
        p.add_argument("--type", default="", dest="subagent_type")
        p.add_argument("--model", default="")
        p.add_argument("--cwd", default=os.getcwd())
        p.add_argument("positional", nargs="*", metavar="TYPE [MODEL]")
        a = p.parse_args(argv[2:])
        if a.positional:
            a.subagent_type = a.positional[0]
            if len(a.positional) > 1:
                a.model = a.positional[1]
        ti = {k: v for k, v in (("subagent_type", a.subagent_type), ("model", a.model)) if v}
        level = resolve(sid)[0] if enabled() else None
        print(json.dumps(sr.agent_call(a.tool, ti, a.cwd, level), ensure_ascii=False))
        reason = decide(a.tool, ti, a.cwd, sid)
        print(f"deny: {reason}" if reason else "allow")
        return 1 if reason else 0

    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
