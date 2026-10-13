#!/usr/bin/env python3
"""Select native app-server transport or the original Linux worker executable."""
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from worker_proxy import exec_worker


def main() -> None:
    config = json.loads(Path(__file__).with_name("desktop-config.json").read_text(encoding="utf-8-sig"))
    args = sys.argv[1:]
    env = dict(os.environ)
    if args[:2] == ["app-server", "proxy"]:
        executable = subprocess.check_output(["wslpath", "-a", "-u", config["WindowsCodex"]], text=True).rstrip("\n")
        env["CODEX_HOME"] = config["WindowsCodexHome"]
        # WSLENV explicitly exports the Windows-form home to the native proxy;
        # /p would incorrectly translate a value which is already native.
        exports = {"CODEX_HOME", *[key for key in ("CODEX_INTERNAL_ORIGINATOR_OVERRIDE", "CODEX_APP_TOOLS_PIPE_PATH") if env.get(key)]}
        entries = [x for x in env.get("WSLENV", "").split(":") if x and x.split("/")[0] not in exports]
        env["WSLENV"] = ":".join([*entries, *sorted(exports)])
    else:
        executable = config["LinuxCodex"]
        env["CODEX_HOME"] = config["LinuxHome"]
        for key in ("CODEX_INTERNAL_ORIGINATOR_OVERRIDE", "CODEX_APP_TOOLS_PIPE_PATH"):
            env.pop(key, None)
        env["WSLENV"] = ":".join(x for x in env.get("WSLENV", "").split(":")
                                  if x and x.split("/")[0] not in {"CODEX_INTERNAL_ORIGINATOR_OVERRIDE", "CODEX_APP_TOOLS_PIPE_PATH"})
    if args[:2] == ["app-server", "proxy"]:
        os.execvpe(executable, [executable, *args], env)
    else:
        exec_worker(executable, args, env)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, RuntimeError) as error:
        print(f"delamain desktop codex: {error}", file=sys.stderr)
        sys.exit(1)
