"""Codex hook adapters. Transcript and patch formats are best-effort local interfaces."""
from __future__ import annotations

import os
import ntpath
from pathlib import Path
import subprocess


def role_profile_path(filename, directory):
    """Resolve native Windows declarations only for mapped Desktop hooks."""
    if os.environ.get("AGENT_HUB_NATIVE_CODEX_PATHS") == "1":
        if ntpath.isabs(filename) and not filename.startswith("/"):
            return Path(subprocess.check_output(["wslpath", "-a", "-u", filename], text=True).rstrip("\n"))
        filename = filename.replace("\\", "/")
    profile = Path(filename).expanduser()
    return profile if profile.is_absolute() else directory / profile


def native_tool(name):
    """Canonical names in Codex CLI and the desktop collaboration namespace."""
    if not isinstance(name, str):
        return name
    for prefix in ("collaboration.", "collaboration__"):
        if name.startswith(prefix):
            return name[len(prefix):]
    # CLI 0.160.0 concatenates namespace and name in local hook payloads.
    # Limit this spelling to known collaboration tools, never arbitrary prefixes.
    if name in {"collaboration" + tool for tool in (
            "spawn_agent", "resume_agent", "send_input", "send_message", "followup_task",
            "wait_agent", "interrupt_agent", "list_agents")}:
        return name[len("collaboration"):]
    return name


def policy_tool(name):
    """Existing policies retain their Agent/SendMessage terminology."""
    return {"spawn_agent": "Agent", "send_input": "SendMessage",
            "send_message": "SendMessage", "followup_task": "SendMessage",
            "resume_agent": "Agent"}.get(native_tool(name), name)


def agent_call(tool, args, cwd, level):
    """Read Codex role config, never a similarly named Claude agent definition.

    Custom file model/effort override explicit spawn values, per native role semantics.
    Unknown or inline session overrides stay inherited rather than claiming a configured
    effort that cannot be observed by hooks. Explicit legacy config_file declarations
    remain supported; standalone discovery is used when no such declaration is present.
    """
    try:
        import tomllib
    except ImportError:
        tomllib = None
    typ = str(args.get("agent_type") or "default").strip()
    definition = {}
    found = False
    if tomllib is not None:
        user_dir = Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex")
        directory = Path(cwd or os.getcwd()).resolve()
        # Project config precedence runs from the repository root toward cwd.
        chain = [directory, *directory.parents]
        project_found = False
        for i, item in enumerate(chain):
            if (item / ".git").exists():
                chain = chain[:i + 1]
                project_found = True
                break
        if not project_found:
            chain = [directory]  # no repository: never inspect unrelated ancestors
        dirs = [user_dir, *[p / ".codex" for p in reversed(chain)]]
        mapped_profile = None
        standalone = None
        for directory in dirs:
            # Scan only immediate TOML files in the role directory. The declared name,
            # not a filename supplied by the tool, identifies a native custom role.
            for profile in sorted((directory / "agents").glob("*.toml")):
                try:
                    candidate = tomllib.loads(profile.read_text(encoding="utf-8"))
                except (OSError, ValueError):
                    continue  # an unrelated broken role must not disable this guard
                if candidate.get("name") == typ and all(isinstance(candidate.get(k), str)
                                                         for k in ("description", "developer_instructions")):
                    standalone = candidate
                    break
            path = directory / "config.toml"
            if not path.is_file():
                continue
            config = tomllib.loads(path.read_text(encoding="utf-8"))
            role = config.get("agents", {}).get(typ)
            if not isinstance(role, dict):
                continue
            filename = role.get("config_file")
            if filename:
                mapped_profile = role_profile_path(filename, path.parent)
        if mapped_profile is not None:
            # Compatibility convention: retain explicit legacy mappings over discovery.
            # Native docs do not specify collisions between these two authoring formats.
            definition = tomllib.loads(mapped_profile.read_text(encoding="utf-8"))
            found = True
        elif standalone is not None:
            definition = standalone
            found = True
    model = str(definition.get("model") or args.get("model") or "inherit").strip().lower()
    effort = str(definition.get("model_reasoning_effort") or args.get("reasoning_effort") or "inherit")
    source = "definition" if definition.get("model") else "param" if args.get("model") else "inherit"
    return {"tool": policy_tool(tool), "level": "off" if level is None else str(level),
            "subagent_type": typ, "defined": "true" if found else "false", "model": model,
            "model_from": source, "effort": effort}


def patch_paths(command):
    """Every source and destination named by an apply_patch edit."""
    if not isinstance(command, str):
        return []
    return [line.split(": ", 1)[1] for line in command.splitlines()
            if line.startswith(("*** Add File: ", "*** Update File: ", "*** Delete File: ", "*** Move to: "))]


def patch_contents(command, cwd):
    """Yield (source, destination, resulting content) without writing any file.

    The supported apply_patch format includes add, delete, update, move, multiple
    hunks, and end-of-file anchoring. A patch that cannot be reconstructed raises
    ValueError; the caller keeps the plugin's established fail-open behavior.
    """
    if not isinstance(command, str):
        return []
    lines = command.strip().splitlines()
    if not lines or lines[0] != "*** Begin Patch" or lines[-1] != "*** End Patch":
        raise ValueError("not an apply_patch patch")
    out = []
    i = 1
    while i < len(lines) - 1:
        header = lines[i]
        i += 1
        if header.startswith("*** Delete File: "):
            out.append((header.removeprefix("*** Delete File: "), None, None))
            continue
        if header.startswith("*** Add File: "):
            target = header.removeprefix("*** Add File: ")
            content = []
            while i < len(lines) - 1 and not lines[i].startswith("*** "):
                if not lines[i].startswith("+"):
                    raise ValueError("invalid addition")
                content.append(lines[i][1:])
                i += 1
            out.append((None, target, "\n".join(content) + ("\n" if content else "")))
            continue
        if not header.startswith("*** Update File: "):
            raise ValueError("unsupported patch header")
        source = header.removeprefix("*** Update File: ")
        target = source
        if lines[i].startswith("*** Move to: "):
            target = lines[i].removeprefix("*** Move to: ")
            i += 1
        current = (Path(cwd) / source).read_text(encoding="utf-8").splitlines()
        pos = 0
        while i < len(lines) - 1 and not lines[i].startswith(("*** Add File: ", "*** Delete File: ", "*** Update File: ")):
            marker = lines[i]
            if marker.startswith("*** "):
                raise ValueError("unexpected patch marker")
            if marker == "@@" or marker.startswith("@@ "):
                i += 1
                if marker.startswith("@@ "):
                    anchor = marker[3:]
                    hits = [n for n in range(pos, len(current)) if current[n].strip() == anchor.strip()]
                    if not hits:
                        raise ValueError("missing patch anchor")
                    pos = hits[0] + 1
            old, new = [], []
            while i < len(lines) - 1 and not lines[i].startswith(("@@", "*** ")):
                line = lines[i]
                if not line:
                    line = " "
                if line[0] not in " +-":
                    raise ValueError("invalid hunk")
                if line[0] in " -":
                    old.append(line[1:])
                if line[0] in " +":
                    new.append(line[1:])
                i += 1
            at_end = i < len(lines) and lines[i] == "*** End of File"
            if at_end:
                i += 1
            matches = []
            for normalize in (lambda s: s, str.rstrip, str.strip):
                matches = [n for n in range(pos, len(current) - len(old) + 1)
                           if (not at_end or n + len(old) == len(current))
                           and [normalize(s) for s in current[n:n + len(old)]] == [normalize(s) for s in old]]
                if matches:
                    break
            if not matches:
                raise ValueError("missing patch context")
            start = matches[0] if old else len(current)
            current[start:start + len(old)] = new
            pos = start + len(new)
        out.append((source, target, "\n".join(current) + ("\n" if current else "")))
    return out
