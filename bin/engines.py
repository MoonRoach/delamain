"""Engine boundaries: validated launch policy and raw-event normalization.

Keep provider events in log.jsonl. Consumers use normalize_event without relying
on one provider's output format. Missing engine metadata always means Claude.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

import hubcore as hc

# App-only transport/attribution markers must never leak into detached CLI workers.
CODEX_APP_ENV = ("CODEX_INTERNAL_ORIGINATOR_OVERRIDE", "CODEX_APP_TOOLS_PIPE_PATH")


def codex_desktop():
    return (not os.environ.get("AGENT_ROLE")
            and os.environ.get("CODEX_INTERNAL_ORIGINATOR_OVERRIDE") == "Codex Desktop"
            and bool(os.environ.get("CODEX_APP_TOOLS_PIPE_PATH")))


ENGINES = ("claude", "codex")
CODEX_EFFORTS = ("none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra")
SANDBOXES = ("read-only", "workspace-write", "danger-full-access")


def selected(given=None, cwd=None):
    name = given or hc.setting("AGENT_HUB_ENGINE", cwd=cwd) or ("codex" if os.environ.get("CODEX_THREAD_ID") else "claude")
    if name not in ENGINES:
        raise hc.UsageError(f"engine {name!r}: one of {', '.join(ENGINES)}")
    return name


def codex_bin(cwd=None):
    if sys.version_info < (3, 11):
        raise hc.UsageError("Codex support requires Python 3.11+ (standard-library TOML parsing)")
    value = hc.setting("CODEX_BIN", cwd=cwd) or "codex"
    found = shutil.which(value)
    if not found:
        raise hc.Failure("codex not found on PATH (set CODEX_BIN)")
    return found


def model_map(cwd=None):
    raw = hc.setting("AGENT_HUB_CODEX_MODEL_MAP", cwd=cwd)
    if not raw:
        return {}
    try:
        data = json.loads(raw) if raw.strip().startswith("{") else dict(s.strip().split("=", 1) for s in raw.split(","))
        if not isinstance(data, dict) or any(not isinstance(k, str) or not hc.MODEL_ALIAS_RE.fullmatch(k)
                                           or not isinstance(v, str) or not hc.MODEL_VALUE_RE.fullmatch(v)
                                           for k, v in data.items()):
            raise ValueError
    except (ValueError, TypeError):
        raise hc.UsageError("AGENT_HUB_CODEX_MODEL_MAP must map safe aliases to model IDs") from None
    return data


def model_problem(model, cwd=None):
    if not isinstance(model, str) or not hc.MODEL_VALUE_RE.fullmatch(model):
        return "a model ID or configured alias (letters, digits and . _ : @ [ ] / - only)"
    if model in hc.MODEL_ALIASES and model not in model_map(cwd):
        return f"{model!r} is a Claude alias; configure AGENT_HUB_CODEX_MODEL_MAP or pass a Codex model ID"
    return None


def permission_policy(mode=None, sandbox=None, cwd=None):
    """No interactive approval in a detached worker; preserve sandbox on resume."""
    if sandbox is not None:
        if sandbox not in SANDBOXES:
            raise hc.UsageError(f"sandbox {sandbox!r}: one of {', '.join(SANDBOXES)}")
        if mode is not None:
            raise hc.UsageError("choose --sandbox or --permission-mode for Codex, not both")
        return sandbox
    mode = mode or hc.setting("AGENT_HUB_CODEX_PERMISSION_MODE", cwd=cwd) or hc.setting("AGENT_HUB_PERMISSION_MODE", cwd=cwd) or "bypassPermissions"
    mapping = {"bypassPermissions": "danger-full-access", "full-access": "danger-full-access",
               "dontAsk": "workspace-write", "acceptEdits": "workspace-write", "plan": "read-only",
               **{s: s for s in SANDBOXES}}
    if mode not in mapping:
        raise hc.UsageError(f"Codex permission mode {mode!r}: use bypassPermissions or an explicit sandbox; "
                            "interactive Claude modes are not supported for detached Codex runs")
    return mapping[mode]


def sandbox_policy(raw):
    """Validate a rollout sandbox without silently discarding restrictions."""
    try:
        policy = json.loads(raw) if isinstance(raw, str) else dict(raw)
    except (ValueError, TypeError):
        raise hc.UsageError("--sandbox-policy must be a JSON object") from None
    if not isinstance(policy, dict) or policy.get("type") not in SANDBOXES:
        raise hc.UsageError("--sandbox-policy needs a supported sandbox type")
    keys = {"type"}
    if policy["type"] == "workspace-write":
        keys |= {"network_access", "writable_roots", "exclude_tmpdir_env_var", "exclude_slash_tmp"}
    unsupported = set(policy) - keys
    if unsupported:
        raise hc.UsageError("cannot preserve sandbox restrictions: unsupported fields " + ", ".join(sorted(unsupported)))
    for key in keys - {"type", "writable_roots"}:
        if key in policy and not isinstance(policy[key], bool):
            raise hc.UsageError(f"sandbox policy {key} must be boolean")
    if "writable_roots" in policy:
        roots = policy["writable_roots"]
        if not isinstance(roots, list) or any(not isinstance(p, str) or not Path(p).is_absolute() for p in roots):
            raise hc.UsageError("sandbox writable_roots must be absolute paths; nested root restrictions cannot be flattened")
    return policy


def toml_value(value):
    """A CLI config override is TOML, not JSON; quote keys as well as values."""
    if isinstance(value, dict):
        return "{ " + ", ".join(json.dumps(str(k)) + " = " + toml_value(v) for k, v in value.items()) + " }"
    if isinstance(value, list):
        return "[" + ", ".join(toml_value(v) for v in value) + "]"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    raise hc.Failure(f"unsupported bundled hook configuration value: {type(value).__name__}")


def hook_args(cwd=None):
    path = hc.BIN.parent / "hooks" / "codex-hooks.json"
    try:
        hooks = json.loads(path.read_text(encoding="utf-8"))["hooks"]
        if not isinstance(hooks, dict):
            raise ValueError
    except (OSError, ValueError, KeyError) as e:
        raise hc.Failure(f"cannot load bundled Codex guards: {e}") from None
    trust = hc.setting("AGENT_HUB_CODEX_HOOK_TRUST", cwd=cwd) or "bypass"
    if trust not in ("bypass", "reviewed"):
        raise hc.UsageError("AGENT_HUB_CODEX_HOOK_TRUST must be bypass or reviewed")
    args = ["--enable", "hooks"]
    for event, groups in hooks.items():
        args += ["-c", f"hooks.{event}={toml_value(groups)}"]
    if trust == "bypass":
        args.append("--dangerously-bypass-hook-trust")
    return args


def worktree_git_roots(cwd):
    """Commit needs the linked worktree's index/HEAD plus shared objects and branch refs.

    Keep common config, hooks and other worktrees outside the write grant. Only
    linked worktrees get extra roots; ordinary checkout policy is unchanged.
    """
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"],
            cwd=cwd, capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return []
    if result.returncode:
        return []
    paths = result.stdout.strip().splitlines()
    if len(paths) != 2:
        return []
    gitdir, common = (Path(p).resolve() for p in paths)
    if gitdir == common:
        return []
    # Reftable stores refs and reflogs together; the files backend keeps them apart.
    refs = [common / "reftable"] if (common / "reftable").is_dir() else [
        common / "refs" / "heads", common / "logs" / "refs" / "heads"]
    return [str(p) for p in [gitdir, common / "objects", *refs]]


def codex_argv(meta, prompt=None, resume=False):
    """The command line of a run. The prompt is not in it: the trailing `-` makes `codex exec` (and `exec resume`)
    read it from stdin, so it never shows in `ps`. `prompt` is accepted for callers that preview the command."""
    args = [codex_bin(meta["cwd"]), "exec"]
    if resume:
        args += ["resume", meta["session_id"]]
    args += ["--json", "--skip-git-repo-check"]
    if meta.get("model"):
        args += ["-m", meta["model"]]
    if meta.get("effort"):
        args += ["-c", "model_reasoning_effort=" + json.dumps(meta["effort"])]
    sandbox = meta["sandbox"]
    if sandbox == "danger-full-access":
        args += ["--dangerously-bypass-approvals-and-sandbox"]
    else:
        # exec resume has no --sandbox/--add-dir flags; overrides work on both paths.
        args += ["-c", "sandbox_mode=" + json.dumps(sandbox), "-c", 'approval_policy="never"']
        if sandbox == "workspace-write":
            policy = meta.get("sandbox_policy") or {}
            roots = list(dict.fromkeys(policy.get("writable_roots", []) + [str(hc.root())]
                                       + worktree_git_roots(meta["cwd"])))
            args += ["-c", "sandbox_workspace_write.writable_roots=" + toml_value(roots)]
            for key in ("network_access", "exclude_tmpdir_env_var", "exclude_slash_tmp"):
                if key in policy:
                    args += ["-c", f"sandbox_workspace_write.{key}=" + toml_value(policy[key])]
    args += hook_args(meta["cwd"])
    return args + ["-"]


def normalize_event(ev):
    """Return zero or more common events; Codex usage is explicitly cumulative."""
    if not isinstance(ev, dict):
        return []
    kind = ev.get("type", "")
    if kind == "thread.started":
        return [{"type": "system", "subtype": "init", "session_id": ev.get("thread_id"), "_engine": "codex"}]
    if kind == "turn.started":
        return [{"type": "system", "subtype": "turn_start", "_engine": "codex"}]
    if kind in ("turn.completed", "turn.failed"):
        failed = kind != "turn.completed"
        return [{"type": "result", "subtype": "error" if failed else "success", "is_error": failed,
                 "errors": [ev.get("error") or ev.get("message")] if failed else [],
                 "codex_usage": ev.get("usage"), "_engine": "codex"}]
    if kind in ("item.started", "item.updated", "item.completed"):
        item = ev.get("item") or {}
        itype = item.get("type")
        blocks = []
        if itype in ("agent_message", "reasoning") and kind == "item.completed":
            blocks = [{"type": "text" if itype == "agent_message" else "thinking",
                       "text" if itype == "agent_message" else "thinking": item.get("text", "")}]
        elif itype == "command_execution":
            if kind == "item.started":
                blocks = [{"type": "tool_use", "id": item.get("id"), "name": "Bash",
                           "input": {"command": item.get("command", "")}}]
            elif kind == "item.completed":
                return [{"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": item.get("id"),
                         "content": item.get("aggregated_output", ""), "is_error": item.get("exit_code", 0) != 0}]},
                         "_engine": "codex"}]
        elif itype in ("file_change", "mcp_tool_call", "web_search"):
            if kind == "item.started":
                blocks = [{"type": "tool_use", "id": item.get("id"), "name": itype, "input": item}]
            elif kind == "item.completed":
                return [{"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": item.get("id"),
                         "content": json.dumps(item, ensure_ascii=False), "is_error": item.get("status") == "failed"}]},
                         "_engine": "codex"}]
        if blocks:
            return [{"type": "assistant", "message": {"id": item.get("id"), "content": blocks}, "_engine": "codex"}]
        return []
    return [ev]
