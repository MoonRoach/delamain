#!/usr/bin/env python3
"""Windows Desktop transport. Policies and processes remain in the original plugin."""
from __future__ import annotations

import base64
import copy
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys

HOOKS = {"questions", "delegation", "path_shadow", "board_locks", "polling_guard", "kill_guard", "handoff_size", "context_budget"}
APP_ENV = {"CODEX_INTERNAL_ORIGINATOR_OVERRIDE", "CODEX_APP_TOOLS_PIPE_PATH"}
IDENTITY_ENV = {"CODEX_THREAD_ID", "AGENT_SESSION_ID"}
PROXY_ENV = {"HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "all_proxy", "no_proxy"}
PATH_OPTIONS = {"--cwd", "--brief", "--repo", "--out", "--handoff", "--project-path", "--file"}
PATH_KEYS = {"cwd", "transcript_path", "agent_transcript_path", "workdir"}


def windows_path(value: str) -> bool:
    return bool(re.match(r"^[A-Za-z]:[\\/]", value)) or value.startswith("\\\\")


def linux_path(value: str) -> str:
    if not windows_path(value):
        return value
    return subprocess.check_output(["wslpath", "-a", "-u", value], text=True).rstrip("\n")


def map_paths(value):
    """Translate structured path fields only; prompts and tool source stay opaque."""
    if isinstance(value, dict):
        return {k: linux_path(v) if k in PATH_KEYS and isinstance(v, str)
                else [linux_path(p) if isinstance(p, str) else p for p in v]
                if k == "writable_roots" and isinstance(v, list)
                else map_paths(v) for k, v in value.items()}
    if isinstance(value, list):
        return [map_paths(v) for v in value]
    return value


def convert_args(args: list[str], command: str = "") -> list[str]:
    result = []
    previous = ""
    # The send parsers treat option-looking message words as data after the
    # role. They expose no file options at all.
    if command in ("agent-send", "tell", "jlog", "roles", "ask", "lock") or command == "agent" and args[:1] == ["send"]:
        return list(args)
    options = set(PATH_OPTIONS)
    if command == "hub" and args[:2] == ["home", "migrate"]:
        options.update(("--from", "--to"))
    if command == "git":
        options.add("-C")
    opaque = False
    for arg in args:
        if opaque or arg == "--":
            result.append(arg)
            opaque = True
            continue
        option, sep, value = arg.partition("=")
        result.append(option + "=" + linux_path(value) if sep and option in options
                      else linux_path(arg) if previous in options else arg)
        previous = option if not sep else ""
    return result


def environment(payload: dict, plugin: Path) -> dict[str, str]:
    env = dict(os.environ)
    # WSL may have inherited the caller's app markers implicitly through WSLENV.
    for key in (*APP_ENV, *IDENTITY_ENV):
        env.pop(key, None)
    for key, value in payload.get("env", {}).items():
        if key.startswith(("AGENT_HUB_", "HUB_")) or key in APP_ENV | IDENTITY_ENV | PROXY_ENV:
            env[key] = str(value)
    if env.get("AGENT_HUB_HOME"):
        env["AGENT_HUB_HOME"] = linux_path(env["AGENT_HUB_HOME"])
    config = payload["config"]
    env.pop("AGENT_HUB_NATIVE_CODEX_PATHS", None)
    if payload.get("mode") == "hook":
        env["CODEX_HOME"] = linux_path(config["WindowsCodexHome"])
        env["AGENT_HUB_NATIVE_CODEX_PATHS"] = "1"
    else:
        env["CODEX_HOME"] = linux_path(config["LinuxHome"])
    env["CODEX_BIN"] = str(plugin / "windows/desktop_codex.py")
    env["PLUGIN_ROOT"] = str(plugin)
    env["AGENT_HUB_ENGINE"] = "codex"
    # Leave the original project/user/legacy home resolution intact. The shared
    # default is ~/agent-hub; a nondefault installer home is only its fallback.
    if not env.get("AGENT_HUB_HOME") and config.get("HubHome") != str(Path.home() / "agent-hub"):
        sys.path.insert(0, str(plugin / "bin"))
        import hubcore
        if hubcore.home().layer in ("user", "default"):
            env["AGENT_HUB_HOME"] = linux_path(config["HubHome"])
    env["PATH"] = os.pathsep.join((str(plugin / "bin"), str(Path(config["LinuxCodex"]).parent),
                                  "/usr/local/bin", "/usr/bin", "/bin", env.get("PATH", "")))
    return env


def command_source(item: dict) -> str:
    if item["kind"] in ("shell", "raw"):
        return item["script"]  # Exact literal source; never interpolate it.
    args = list(item["argv"])
    name = args[0].replace("\\", "/").rsplit("/", 1)[-1].lower()
    if name in ("git.exe", "glab.exe", "gh.exe"):
        args[0] = name[:-4]
        name = name[:-4]
    args = [args[0], *convert_args(args[1:], name)]
    if name == "cd" and len(args) == 2:
        args[1] = linux_path(args[1])
    return shlex.join(args)


def translated_command(command: str, replacements: list[dict]) -> str:
    # PowerShell AST offsets count UTF-16 code units; Python indexes Unicode
    # code points. Translate before replacements (including astral characters).
    def offset(n: int) -> int:
        return len(command.encode("utf-16-le")[:n * 2].decode("utf-16-le"))
    replacements = [dict(item, start=offset(item["start"]), end=offset(item["end"])) for item in replacements]
    for item in sorted(replacements, key=lambda x: x["start"], reverse=True):
        source = command_source(item)
        command = command[:item["start"]] + source + command[item["end"]:]
    return command


def normalize_event(event: dict, payload: dict) -> dict:
    event = map_paths(copy.deepcopy(event))
    tin = event.get("tool_input")
    if isinstance(tin, dict):
        if tin.get("workdir"):
            event["cwd"] = tin["workdir"]
        if event.get("tool_name") == "Bash" and isinstance(tin.get("command"), str):
            if payload.get("hook") in ("board_locks", "polling_guard", "kill_guard") and payload.get("command_projection"):
                # Each bridge invocation starts a fresh process. Its Bash cd
                # affects that program only, never the next native/bridge call.
                projection = []
                for item in payload["command_projection"]:
                    if item["kind"] == "pipeline":
                        projection.extend(kill_pipeline_views(item, payload))
                    else:
                        projection.append(item)
                commands = guard_events(event, projection)
                event["_desktop_commands"] = commands
                tin["command"] = commands[0]["tool_input"]["command"] if commands else ""
            else:
                # Context handover eligibility must retain enclosing syntax and
                # non-command expressions too: projecting only recognized calls
                # could erase a companion side effect and falsely allow a turn.
                tin["command"] = translated_command(tin["command"], payload.get("command_replacements", []))
        if event.get("tool_name") == "apply_patch" and isinstance(tin.get("command"), str):
            # Only protocol headers name files. Never rewrite added/deleted
            # source, which can legitimately contain a Windows path as text.
            tin["command"] = re.sub(r"^(\*\*\* (?:Add File|Update File|Delete File|Move to): )([^\r\n]+)",
                                    lambda match: match[1] + linux_path(match[2]), tin["command"], flags=re.M)
    return event


def kill_pipeline_views(pipeline: dict, payload: dict) -> list[dict]:
    """Preserve native stdin edges using the original guard's executed views.

    Shell bodies are separate programs: a trailing comment or semicolon must
    not capture/rebind the next native stage. Only actual PipelineAst stages
    share this lookup context; no recognizer or escape policy is copied here.
    """
    sys.path.insert(0, str(Path(linux_path(payload["pluginroot"])) / "hooks"))
    import kill_guard
    upstream = []
    result = []
    for stage in pipeline["stages"]:
        replacements = [dict(change, start=change["start"] - stage["start"],
                             end=change["end"] - stage["start"])
                        for change in payload.get("command_replacements", [])
                        if stage["start"] <= change["start"] and change["end"] <= stage["end"]]
        body = translated_command(stage["script"], replacements)
        executed = kill_guard.pg.views(kill_guard._drop_ssh(body), True)[0]
        levels = list(kill_guard._levels(executed))
        if kill_guard._has_source(upstream):
            # The original hook scans raw source for its escape marker. Keep
            # this sink's scope, never an upstream bridge's marker. Commenting
            # every line prevents quoted display data from becoming an action.
            scope = "\n".join("# " + line for line in body.splitlines())
            for level in levels:
                for pipe in kill_guard._pipelines(level):
                    start = pipe[0][0]
                    # A later statement can still read native stdin (notably
                    # while-read followed by kill). Retain the complete suffix.
                    suffix = "".join(text + separator for text, separator in level[start:])
                    result.append({"kind": "shell", "script":
                                   "pgrep __desktop_pipeline_source__ | " + suffix + "\n" + scope})
        # ps in one native stage followed by grep in another is also an original
        # name-lookup source. Retain prior executed stages for its recognizer.
        upstream.extend(text for level in levels for text, _ in level)
    return result


def guard_events(event: dict, projection: list[dict]) -> list[dict]:
    cwd = event.get("cwd")
    comments = "\n".join(item["script"] for item in projection if item["kind"] == "comment")
    # Nested/dynamic location changes have no statically known execution order.
    uncertain = any(item.get("uncertain_cwd") for item in projection)
    result = []
    for item in projection:
        if item["kind"] == "comment":
            continue
        if item["kind"] == "location":
            if not item.get("uncertain_cwd"):
                try:
                    path = linux_path(item["path"]).replace("\\", "/")
                    candidate = os.path.normpath(os.path.join(cwd or "", path))
                    if os.path.isdir(candidate):
                        cwd = candidate
                    else:
                        uncertain = True
                except (OSError, ValueError, subprocess.CalledProcessError):
                    # A failed Set-Location may leave the native shell at its
                    # previous directory. Do not let an invalid path fail open.
                    uncertain = True
            continue
        current = copy.deepcopy(event)
        current["cwd"] = cwd
        current["tool_input"]["command"] = command_source(item) + ("\n" + comments if comments else "")
        current["_desktop_uncertain_cwd"] = uncertain
        result.append(current)
    return result


def prelude(payload: dict, event: dict) -> str:
    root = payload["pluginroot"]
    sid = str(event.get("session_id") or "")
    bridge = root.rstrip("\\/") + "\\windows\\desktop.ps1"
    invocation = "& '" + bridge.replace("'", "''") + "' --session-id '" + sid.replace("'", "''") + "'"
    return ("Delamain runs in the existing WSL runtime from this native Windows chat. "
            f"Current session_id: {sid}. Invoke original tools with PowerShell: {invocation} <tool> <args>. "
            f"For Bash source use {invocation} shell '<literal Bash source>' (double single quotes inside a PowerShell "
            "single-quoted string); never construct this shell argument dynamically. Optional shell --cwd <path> "
            "precedes the source. Use the path --windows /linux/path helper before passing Linux paths to native "
            "file tools or workdir; path --linux <WindowsPath> converts the other direction. "
            "Keep the original Delamain workflow, board locks, waits, and handoffs. "
            f"Installed plugin root: {root}. Read Linux home files through returned UNC paths or literal bridge shell.")


def run_hook(payload: dict, plugin: Path, event: dict) -> int:
    hook = payload["hook"]
    if hook not in HOOKS:
        raise ValueError("unsupported hook")
    events = event.pop("_desktop_commands", [event])
    output = ""
    status = 0
    for current in events:
        if current.get("cwd"):
            os.chdir(current["cwd"])
        env = environment(payload, plugin)
        sid = current.get("session_id")
        if sid:
            env["CODEX_THREAD_ID"] = str(sid)
            env["AGENT_SESSION_ID"] = str(sid)
        if hook == "board_locks" and current.pop("_desktop_uncertain_cwd", False):
            # Use the original recognizer and configured rules, but never invent
            # a directory for an action after an unevaluated native location.
            sys.path.insert(0, str(plugin / "hooks"))
            import board_locks
            with_environment = dict(os.environ)
            try:
                os.environ.clear()
                os.environ.update(env)
                command = current["tool_input"]["command"]
                if not board_locks.ESCAPE_HATCH.search(command) and any(
                        board_locks.classify(seg, board_locks.load_rules(current.get("cwd")))
                        for seg in board_locks.segments(command)):
                    output = json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                        "permissionDecision": "deny", "permissionDecisionReason":
                        "Delamain cannot determine the working directory of this guarded action after a dynamic or conditional PowerShell location change. Use tool_input.workdir or one literal shell --cwd call."}}) + "\n"
                    break
            finally:
                os.environ.clear()
                os.environ.update(with_environment)
        result = subprocess.run([sys.executable, str(plugin / "hooks" / (hook + ".py")),
                                 *payload.get("hookargs", [])], input=json.dumps(current, ensure_ascii=False),
                                text=True, stdout=subprocess.PIPE, env=env)
        status = result.returncode
        if result.stdout.strip():
            data = json.loads(result.stdout)
            previous = json.loads(output) if output.strip() else {}
            if previous.get("systemMessage") and data.get("systemMessage"):
                data["systemMessage"] = previous["systemMessage"] + "\n" + data["systemMessage"]
            output = json.dumps({**previous, **data}, ensure_ascii=False) + "\n"
            if data.get("hookSpecificOutput", {}).get("permissionDecision") == "deny":
                break
        if status:
            break
    if hook == "questions" and event.get("hook_event_name") == "SessionStart":
        data = json.loads(output) if output.strip() else {}
        specific = data.setdefault("hookSpecificOutput", {"hookEventName": "SessionStart"})
        specific["additionalContext"] = "\n".join(filter(None, (specific.get("additionalContext"), prelude(payload, event))))
        output = json.dumps(data, ensure_ascii=False) + "\n"
    sys.stdout.write(output)
    return status


def main() -> int:
    encoded = Path(sys.argv[2]).read_text(encoding="ascii") if sys.argv[1] == "--payload-file" else sys.argv[1]
    payload = json.loads(base64.b64decode(encoded, validate=True).decode("utf-8"))
    plugin = Path(linux_path(payload["pluginroot"]))
    os.chdir(linux_path(payload["cwd"]))
    if payload["mode"] == "hook":
        event = normalize_event(payload["event"], payload)
        if event.get("cwd"):
            # Home resolution belongs to the actual tool directory, not the
            # directory from which the native hook wrapper happened to start.
            os.chdir(event["cwd"])
        return run_hook(payload, plugin, event)
    args = payload["argv"]
    if not args:
        raise ValueError("expected an original Delamain tool, shell, or path")
    command, args = args[0], args[1:]
    if command == "path":
        if len(args) != 2 or args[0] not in ("--windows", "--linux"):
            raise ValueError("path --windows|--linux PATH")
        if args[0] == "--linux":
            print(linux_path(args[1]))
        else:
            print(subprocess.check_output(["wslpath", "-a", "-w", linux_path(args[1])], text=True).rstrip("\n"))
        return 0
    if command == "shell":
        if len(args) == 3 and args[0] == "--cwd":
            os.chdir(linux_path(args[1]))
            args = args[2:]
        if len(args) != 1:
            raise ValueError("shell [--cwd PATH] requires one literal Bash program")
        # Nonlogin Bash preserves the explicit original-tool PATH. -l would
        # silently reset it from the user's shell profile.
        os.execvpe("/bin/bash", ["/bin/bash", "-c", args[0]], environment(payload, plugin))
    executable = plugin / "bin" / command
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]*", command) or not executable.is_file():
        raise ValueError(f"unknown Delamain tool: {command}")
    # Original alias tools are /bin/sh scripts; other tools use Python. Let
    # each unchanged executable's own shebang choose its interpreter.
    os.execvpe(str(executable), [str(executable), *convert_args(args, command)], environment(payload, plugin))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"delamain desktop: {error}", file=sys.stderr)
        sys.exit(1)
