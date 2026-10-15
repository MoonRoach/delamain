#!/usr/bin/env python3
"""Decode Windows transport and replace this process with the Linux runtime."""
from __future__ import annotations

import base64
import json
import os
from pathlib import Path
import re
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from worker_proxy import exec_worker

COMMANDS = {
    "hub", "agent", "jlog", "jwait", "lock", "roles", "ask", "tell",
    "nightq", "delegation", "agent-top", "watchdog", "codex",
}
PATH_OPTIONS = {"--cwd", "--brief", "--repo", "--out", "--handoff"}
RUNTIME_ENV = {"DELAMAIN_CODEX_PATH", "DELAMAIN_PLUGIN_ROOT", "DELAMAIN_CODEX_HOME"}
PROXY_ENV = {"HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "all_proxy", "no_proxy"}


def windows_path(value: str) -> bool:
    return bool(re.match(r"^[A-Za-z]:[\\/]", value)) or value.startswith("\\\\")


def linux_path(value: str) -> str:
    if not windows_path(value):
        return value
    # Each path is an argv item; wslpath never receives a shell program.
    return subprocess.check_output(["wslpath", "-a", "-u", value], text=True).rstrip("\n")


def convert_args(args: list[str]) -> list[str]:
    result = []
    for arg in args:
        option, sep, value = arg.partition("=")
        if sep and option in PATH_OPTIONS:
            result.append(option + "=" + linux_path(value))
        else:
            # Only entire absolute paths are converted; relative paths retain
            # Linux semantics. Text containing a Windows path is left intact.
            result.append(linux_path(arg))
    return result


def version_key(path: Path) -> tuple[int, ...]:
    return tuple(int(n) for n in re.findall(r"\d+", path.name))


def find_codex(env: dict[str, str], base: Path) -> Path:
    if env.get("DELAMAIN_CODEX_PATH"):
        executable = Path(linux_path(env["DELAMAIN_CODEX_PATH"])).expanduser()
    else:
        versions = [p for p in (base / "codex").glob("*") if (p / "bin/codex").is_file()]
        if not versions:
            raise RuntimeError("No Linux Codex package; set DELAMAIN_CODEX_PATH to its bin/codex.")
        executable = max(versions, key=version_key) / "bin/codex"
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise RuntimeError(f"Linux Codex is not executable: {executable}")
    return executable


def find_plugin(env: dict[str, str]) -> Path:
    if env.get("DELAMAIN_PLUGIN_ROOT"):
        root = Path(linux_path(env["DELAMAIN_PLUGIN_ROOT"])).expanduser()
    else:
        cache = Path(env["CODEX_HOME"]) / "plugins/cache/delamain-codex/delamain"
        roots = [p for p in cache.glob("*") if (p / "bin/hub").is_file()]
        if not roots:
            raise RuntimeError("No installed Delamain plugin; install it in the Linux CODEX_HOME.")
        root = max(roots, key=version_key)
    if not (root / "bin/hub").is_file():
        raise RuntimeError(f"Not a Delamain plugin root: {root}")
    return root


def main() -> None:
    encoded = Path(sys.argv[2]).read_text(encoding="ascii") if sys.argv[1] == "--payload-file" else sys.argv[1]
    payload = json.loads(base64.b64decode(encoded, validate=True).decode("utf-8"))
    env = dict(os.environ)
    for name, value in payload["env"].items():
        if name.startswith(("AGENT_HUB_", "HUB_")) or name == "CODEX_THREAD_ID" or name in RUNTIME_ENV | PROXY_ENV:
            env[name] = str(value)
    base = Path.home() / ".local/share/delamain"
    env["CODEX_HOME"] = linux_path(env.get("DELAMAIN_CODEX_HOME", str(base / "codex-home")))
    # Normalize home paths explicitly; other forwarded values are opaque text.
    env["AGENT_HUB_HOME"] = linux_path(env.get("AGENT_HUB_HOME", str(Path.home() / "agent-hub")))
    env.setdefault("AGENT_HUB_ENGINE", "codex")
    args = payload["argv"]
    if args and args[0] in COMMANDS:
        command, args = args[0], args[1:]
    elif not args or args[0].startswith("-"):
        command = "codex"
    else:
        raise RuntimeError("Unknown command. Use codex explicitly before a positional prompt.")
    os.chdir(linux_path(payload["cwd"]))
    codex = find_codex(env, base)
    plugin = find_plugin(env)
    env["PATH"] = os.pathsep.join((str(codex.parent), str(plugin / "bin"), env.get("PATH", "")))
    env["CODEX_BIN"] = str(Path(__file__).with_name("worker_proxy.py"))
    env["DELAMAIN_LINUX_CODEX"] = str(codex)
    args = convert_args(args)
    if command == "codex":
        exec_worker(str(codex), args, env)
    executable = plugin / "bin" / command
    if not executable.is_file():
        raise RuntimeError(f"Installed plugin is missing {command}: {executable}")
    os.execvpe(sys.executable, [sys.executable, str(executable), *args], env)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, RuntimeError) as error:
        print(f"delamain: {error}", file=sys.stderr)
        sys.exit(1)
