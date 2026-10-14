#!/usr/bin/env python3
"""Context budget: nudge a session toward a handoff when its context grows large, and stop it from starting new
work past a hard threshold.

Claude context = usage of the last real assistant turn of the transcript:
    input_tokens + cache_read_input_tokens + cache_creation_input_tokens
If a compact_boundary record comes after that turn, its compactMetadata.postTokens wins.
Codex context = the latest event_msg token_count's info.last_token_usage.total_tokens, never the accumulated
total_token_usage. Cached/reasoning counters are already included. A compacted record resets the estimate until
fresh usage arrives. When a Codex rollout includes its model_context_window, default warn/block/step are
60%/85%/10% of that window; explicit settings still win. Transcript formats are not a stable runtime API.

Which transcript: the main thread reads `transcript_path` and skips sidechain records; inside a subagent (the hook
input carries `agent_id`) the subagent's own transcript (`agent_transcript_path`, else
<dir(transcript_path)>/<session_id>/subagents/agent-<agent_id>.jsonl) — if it cannot be found the hook stays silent.

Events:
  UserPromptSubmit, PostToolUse  additionalContext once on crossing AGENT_HUB_CONTEXT_WARN and again every
                                 AGENT_HUB_CONTEXT_WARN_STEP tokens above it
  PreToolUse                     deny the tools in AGENT_HUB_CONTEXT_BLOCK_TOOLS at AGENT_HUB_CONTEXT_BLOCK and above,
                                 unless the tool input matches AGENT_HUB_CONTEXT_ESCAPE (a HANDOFF-*.md path or the
                                 marker `handoff-ok`): handing the work over must stay possible

Autopilot (AGENT_HUB_AUTO_HANDOFF=on, bin/autopilot.py), in the main thread of a session registered as a stage's hub
(roles `hub`): the warning becomes the instruction to hand the shift to a successor at the next quiet point — `hub
handoff`, `hub succeed` with the hub's model, effort (the hook input's `effort.level`) and permission mode filled in, `jwait`; at the block threshold the deny
reason says "hand over now" and Bash, Write, Edit and NotebookEdit are gated too: Bash passes only when every command of
the line is `hub handoff`, `hub succeed`, `hub desktop-*`, `jlog` or `jwait` (no substitution, no subshell), a file tool only on a
HANDOFF-*.md file; the other gated tools pass on the usual escape. A UserPromptSubmit in that session whose prompt lacks the marker
"[agent-hub auto-handoff k/N]" (written under the name used before the rename; "[delamain auto-handoff k/N]" counts too)
and does not start with the watchdog's "[agent-hub watchdog]" (the name before the rename, still written; "[delamain watchdog]"
counts too) means the owner spoke and resets the stage's automatic-handoff chain.

Settings (hub home config.json or environment; docs/reference.md "Agent discipline"):
  AGENT_HUB_CONTEXT_BUDGET       on | off (default on)
  AGENT_HUB_CONTEXT_WARN         300000      AGENT_HUB_CONTEXT_WARN_STEP  50000
  AGENT_HUB_CONTEXT_BLOCK        500000      AGENT_HUB_CONTEXT_BLOCK_TOOLS ["Agent", "Task", "SendMessage"]
  AGENT_HUB_CONTEXT_ESCAPE       regex, default HANDOFF-<name>.md or handoff-ok
  AGENT_HUB_CONTEXT_TODO         the "what to do" sentence of both messages
  AGENT_HUB_STATE_DIR            state directory (default <hub home>/.state); this hook uses <state>/context-budget/
Fail-open: any error of its own -> exit 0, no output.
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
import shlex
import sys
import time
from pathlib import Path

from codex_compat import patch_paths, policy_tool

CHUNK = 1 << 20
MAX_SCAN = 64 << 20  # give up (silently) after reading this much from the tail
PRUNE_AFTER_DAYS = 14
DEFAULTS = {"warn": 300_000, "step": 50_000, "block": 500_000}
DEFAULT_TOOLS = ["Agent", "Task", "SendMessage"]
DEFAULT_ESCAPE = r"HANDOFF-[^\s/\\'\"`]*\.md|handoff-ok"
AUTOPILOT_TOOLS = ("Bash", "Write", "Edit", "NotebookEdit", "apply_patch")
AUTOPILOT_FILE = re.compile(r"(?:^|/)HANDOFF-[^/\s]*\.md$")
SEPARATORS = (";", "&&", "||", "|", "&")


def default_todo() -> str:
    """The "what to do" sentence. The skill is named in both forms for one release (rename:keep): a session started
    before the rename runs this hook from the updated plugin folder but knows the skill only as `agent-hub:handoff`."""
    try:
        import subagent_rules as sr  # noqa: E402  (bin/ is on sys.path once hubcore() ran)
        skill = sr.named("handoff")  # rename:transition
    except Exception:  # noqa: BLE001 — fail-open: the current name alone
        skill = "`delamain:handoff`"
    return (f"What to do: write a handoff with the skill {skill} using the plugin's templates/HANDOFF-template.md "
            "(at most 12 KB; the chronology goes to the journal) and continue in a new session from it.")


def autopilot():
    """bin/autopilot.py, or None when it cannot load — then the hook works as without autopilot (fail-open)."""
    try:
        import autopilot as ap  # noqa: E402  (bin/ is on sys.path once hubcore() ran)
    except Exception:  # noqa: BLE001
        return None
    return ap


def handover_command(command) -> bool:
    """True when every command of the Bash line is `hub handoff`, `hub succeed`, `hub desktop-*`, `jlog` or `jwait` (a leading VAR=value
    and redirections allowed). Anything the hook cannot read with certainty — a substitution, a subshell, unbalanced
    quotes — is not a handover command."""
    if not isinstance(command, str) or not command.strip() or "$(" in command or "`" in command:
        return False
    for line in command.splitlines():
        try:
            lex = shlex.shlex(line, posix=True, punctuation_chars=True)
            lex.whitespace_split = True
            tokens = list(lex)
        except ValueError:
            return False
        segs, cur, skip = [], [], ""
        for tok in tokens:
            if skip:
                # only /dev/null, a descriptor (`2>&1`) or a HANDOFF file: `jlog x > ~/.bashrc` is not a handover
                if not (tok == "/dev/null" or re.fullmatch(r"-|\d+", tok) and "&" in skip or AUTOPILOT_FILE.search(tok)):
                    return False
                skip = False
                continue
            if tok in SEPARATORS:
                segs.append(cur)
                cur = []
            elif set(tok) <= set("();<>|&"):
                if not (set(tok) <= set("<>&") and ("<" in tok or ">" in tok)):
                    return False  # a subshell, `|&`, `;;` …: not read with certainty
                skip = tok  # a redirection: its target is the next token, checked below
            else:
                cur.append(tok)
        segs.append(cur)
        for seg in segs:
            while seg and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", seg[0]):
                seg = seg[1:]
            if not seg:
                continue
            name = os.path.basename(seg[0])
            if not (name in ("jlog", "jwait") or (name == "hub" and len(seg) > 1 and seg[1] in ("handoff", "succeed", "desktop-request", "desktop-bind", "desktop-fail", "desktop-status"))):
                return False
    return True


def hubcore():
    root = os.environ.get("PLUGIN_ROOT") or os.environ.get("CLAUDE_PLUGIN_ROOT") or os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
    sys.path.insert(0, os.path.join(root, "bin"))
    import hubcore as hc  # noqa: E402

    return hc


def fmt(n: int) -> str:
    return f"{n // 1000}k"


def classify(line: bytes, skip_sidechain: bool):
    """('usage', n) | ('compact', n) | None for one JSONL line."""
    if not any(t in line for t in (b'"assistant"', b"compact_boundary", b'"event_msg"', b'"compacted"')):
        return None
    try:
        o = json.loads(line)
    except ValueError:
        return None
    if not isinstance(o, dict):
        return None
    if o.get("type") == "compacted":
        # Codex does not expose a stable post-compact count here. Zero resets the
        # warning buckets until the next model request publishes fresh usage.
        return ("compact", 0)
    if o.get("type") == "event_msg":
        payload = o.get("payload") or {}
        if payload.get("type") == "context_compacted":
            return ("compact", 0)
        if payload.get("type") != "token_count":
            return None
        usage = (payload.get("info") or {}).get("last_token_usage")
        if not isinstance(usage, dict):
            return None  # accumulated totals or rate-limit updates are not context
        # Codex input_tokens already includes cached tokens, output_tokens includes
        # reasoning tokens. Do not add their component counters a second time.
        n = usage.get("total_tokens")
        if n is None:
            n = int(usage.get("input_tokens") or 0) + int(usage.get("output_tokens") or 0)
        return ("usage", int(n)) if isinstance(n, (int, float)) and n >= 0 else None
    if o.get("type") == "system" and o.get("subtype") == "compact_boundary":
        post = (o.get("compactMetadata") or {}).get("postTokens")
        return ("compact", int(post)) if isinstance(post, (int, float)) else ("compact", 0)
    if o.get("type") != "assistant":
        return None
    if skip_sidechain and o.get("isSidechain") is True:
        return None
    msg = o.get("message") or {}
    if msg.get("model") == "<synthetic>":
        return None
    u = msg.get("usage") or {}
    n = sum(int(u.get(k) or 0) for k in ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"))
    return ("usage", n) if n > 0 else None


def transcript_lines(path: Path):
    """Bounded reverse iterator; a long rollout never gets loaded into memory whole."""
    with open(path, "rb") as f:
        f.seek(0, os.SEEK_END)
        pos = f.tell()
        tail = b""
        scanned = 0
        while pos > 0 and scanned < MAX_SCAN:
            step = min(CHUNK, pos)
            pos -= step
            f.seek(pos)
            buf = f.read(step) + tail
            scanned += step
            lines = buf.split(b"\n")
            tail = lines[0] if pos > 0 else b""
            body = lines[1:] if pos > 0 else lines
            for line in reversed(body):
                if not line.strip():
                    continue
                yield line


def context_tokens(path: Path, skip_sidechain: bool):
    """Scan the JSONL backwards; the first qualifying record from the end decides."""
    for line in transcript_lines(path):
        r = classify(line, skip_sidechain)
        if r:
            return r[1]
    return None


def context_window(path: Path):
    """The latest Codex window, falling back to session metadata when present."""
    for line in transcript_lines(path):
        if b"model_context_window" not in line and b"context_window" not in line:
            continue
        try:
            record = json.loads(line)
        except ValueError:
            continue
        payload = record.get("payload") or {}
        window = None
        if record.get("type") == "event_msg" and payload.get("type") == "token_count":
            window = (payload.get("info") or {}).get("model_context_window")
        elif record.get("type") in ("session_meta", "turn_context"):
            window = payload.get("context_window") or payload.get("model_context_window")
        if isinstance(window, (int, float)) and window > 0:
            return int(window)
    return None


def resolve_transcript(data: dict):
    sid = str(data.get("session_id") or "unknown")
    agent_id = data.get("agent_id")
    tp = data.get("transcript_path")
    if agent_id:
        key = f"{sid}__{agent_id}"
        atp = data.get("agent_transcript_path")
        if atp:
            return Path(atp), False, key
        if tp:
            cand = Path(tp).parent / sid / "subagents" / f"agent-{agent_id}.jsonl"
            return (cand if cand.is_file() else None), False, key
        return None, False, key
    return (Path(tp) if tp else None), True, sid


def mentions(obj, rx) -> bool:
    if isinstance(obj, str):
        return bool(rx.search(obj))
    if isinstance(obj, dict):
        return any(mentions(v, rx) for v in obj.values())
    if isinstance(obj, list):
        return any(mentions(v, rx) for v in obj)
    return False


def load_state(state_dir: Path, key: str) -> dict:
    try:
        return json.loads((state_dir / f"{key}.json").read_text())
    except Exception:  # noqa: BLE001
        return {}


def save_state(state_dir: Path, key: str, state: dict) -> None:
    try:
        state_dir.mkdir(parents=True, exist_ok=True)
        (state_dir / f"{key}.json").write_text(json.dumps(state))
        if time.time() % 50 < 1:  # cheap occasional prune
            cutoff = time.time() - PRUNE_AFTER_DAYS * 86400
            for p in state_dir.glob("*.json"):
                if p.stat().st_mtime < cutoff:
                    p.unlink(missing_ok=True)
    except Exception:  # noqa: BLE001
        pass


def emit(event: str, **fields) -> None:
    print(json.dumps({"hookSpecificOutput": {"hookEventName": event, **fields}}, ensure_ascii=False))


def main() -> None:
    data = json.loads(sys.stdin.read() or "{}")
    if not isinstance(data, dict):
        return
    event = data.get("hook_event_name") or ""
    if event not in ("PreToolUse", "UserPromptSubmit", "PostToolUse"):
        return
    hc = hubcore()
    hc.use_cwd(data.get("cwd"))  # the hub home of the session's directory, not of the hook process
    ap = autopilot()
    auto = bool(ap) and ap.enabled() and not data.get("agent_id")
    if auto and event == "UserPromptSubmit" and ap.owner_spoke(data.get("prompt")):
        stage = ap.hub_stage_of(str(data.get("session_id") or ""))
        if stage:
            ap.reset_chain(stage, "the owner spoke in the hub's session")
    if (hc.setting("AGENT_HUB_CONTEXT_BUDGET") or "on").strip().lower() in ("off", "0", "false", "no"):
        return
    tools = hc.setting_json("AGENT_HUB_CONTEXT_BLOCK_TOOLS", DEFAULT_TOOLS)
    if isinstance(tools, str):  # "Agent,SendMessage"
        tools = [t.strip() for t in tools.split(",") if t.strip()]
    raw_tool = data.get("tool_name")
    tool = policy_tool(raw_tool)
    sid = str(data.get("session_id") or "")
    hub_stage = None
    if event == "PreToolUse" and tool not in (tools or []) and raw_tool not in (tools or []):
        # gated only for a stage hub with autopilot on: the cheap registry lookup before any transcript read
        if not (auto and tool in AUTOPILOT_TOOLS):
            return
        hub_stage = ap.hub_stage_of(sid)
        if not hub_stage:
            return
    path, skip_side, key = resolve_transcript(data)
    if path is None or not path.is_file():
        return
    tokens = context_tokens(path, skip_side)
    if tokens is None:
        return
    window = context_window(path)
    defaults = ({"warn": max(1, int(window * .60)), "block": max(1, int(window * .85)),
                 "step": max(1, int(window * .10))} if window else DEFAULTS)
    warn = hc.int_setting("AGENT_HUB_CONTEXT_WARN", defaults["warn"])
    block = hc.int_setting("AGENT_HUB_CONTEXT_BLOCK", defaults["block"])
    step = hc.int_setting("AGENT_HUB_CONTEXT_WARN_STEP", defaults["step"])
    todo = hc.setting("AGENT_HUB_CONTEXT_TODO") or default_todo()
    escape_src = hc.setting("AGENT_HUB_CONTEXT_ESCAPE") or DEFAULT_ESCAPE
    try:
        escape = re.compile(escape_src)
    except re.error:
        escape = re.compile(DEFAULT_ESCAPE)
    gated = "/".join(tools or [])
    # autopilot applies to the registered hub of a stage only; looked up once the size makes it matter
    if hub_stage is None and auto and tokens >= min(warn, block):
        hub_stage = ap.hub_stage_of(sid)

    def plan(now_block: bool) -> str:
        model = ap.successor_model(None, path)
        mode = ap.configured_mode() or data.get("permission_mode") or None
        try:
            cwd = ap.predecessor_cwd(hub_stage, data.get("cwd") or None)
        except Exception:  # noqa: BLE001 — a broken registry must not lift the budget gate; `hub succeed` decides the directory
            cwd = None
        return ap.instruction(hub_stage, model, mode, cwd, now_block, fmt(block),
                              ap.hub_effort(data))

    if event == "PreToolUse":
        if tokens < block:
            return
        if hub_stage:
            tin = data.get("tool_input") if isinstance(data.get("tool_input"), dict) else {}
            if tool == "Bash":
                passes = handover_command(tin.get("command"))
            elif tool == "apply_patch":
                paths = patch_paths(tin.get("command"))
                passes = bool(paths) and all(AUTOPILOT_FILE.search(p) for p in paths)
            elif tool in AUTOPILOT_TOOLS:
                passes = bool(AUTOPILOT_FILE.search(str(tin.get("file_path") or tin.get("notebook_path") or "")))
            else:
                passes = mentions(data.get("tool_input"), escape)
            if passes:
                return
            emit("PreToolUse", permissionDecision="deny", permissionDecisionReason=(
                f"Session context is {fmt(tokens)} tokens, at or above the {fmt(block)} limit. {plan(True)}"))
            return
        if mentions(data.get("tool_input"), escape):
            return
        emit("PreToolUse", permissionDecision="deny", permissionDecisionReason=(
            f"Session context is {fmt(tokens)} tokens, at or above the {fmt(block)} limit: {gated} are closed, every "
            f"turn here is expensive. {todo} Only handing the work over passes: a tool input that names a "
            f"HANDOFF-*.md file or carries the marker handoff-ok (pattern: {escape.pattern})."))
        return

    raw_state = hc.setting("AGENT_HUB_STATE_DIR")
    state_dir = (Path(raw_state).expanduser() if raw_state else hc.root() / ".state") / "context-budget"
    state = load_state(state_dir, key)
    if tokens < warn:
        if state.get("bucket", -1) >= 0:  # dropped below (compact / new chain): re-arm
            save_state(state_dir, key, {"bucket": -1, "tokens": tokens})
        return
    bucket = (tokens - warn) // step
    if bucket <= state.get("bucket", -1):
        return
    save_state(state_dir, key, {"bucket": bucket, "tokens": tokens})
    extra = (f" The {fmt(block)} limit is already passed: {gated} pass only with a HANDOFF-*.md path or the "
             "marker handoff-ok." if tokens >= block
             else f" At {fmt(block)} new {gated} calls will be denied (except a handoff).")
    if hub_stage:
        emit(event, additionalContext=f"Context budget: {fmt(tokens)} tokens now, handoff threshold {fmt(warn)}. "
                                      f"{plan(tokens >= block)}")
        return
    emit(event, additionalContext=f"Context budget: {fmt(tokens)} tokens now, handoff threshold {fmt(warn)}. "
                                  f"{todo}{extra}")


if __name__ == "__main__":
    try:
        main()
    except Exception:  # noqa: BLE001 — fail-open
        pass
    sys.exit(0)
