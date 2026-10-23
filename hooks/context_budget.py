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
<dir(transcript_path)>/<session_id>/subagents/agent-<agent_id>.jsonl). Lost established usage emits a truthful
unknown-state/checkpoint instruction. A fresh hub waiting for its first usage record is not a missing-usage alarm.

Events:
  UserPromptSubmit, PostToolUse  additionalContext once on crossing AGENT_HUB_CONTEXT_WARN and again every
                                 AGENT_HUB_CONTEXT_WARN_STEP tokens above it; a registered autopilot hub receives
                                 its response-and-handoff instruction on every UserPromptSubmit above warn
  PreToolUse                     deny the tools in AGENT_HUB_CONTEXT_BLOCK_TOOLS at AGENT_HUB_CONTEXT_BLOCK and above,
                                 unless the tool input matches AGENT_HUB_CONTEXT_ESCAPE (a HANDOFF-*.md path or the
                                 marker `handoff-ok`): handing the work over must stay possible

Autopilot (AGENT_HUB_AUTO_HANDOFF=on, bin/autopilot.py), in the main thread of a session registered as a stage's hub
(roles `hub`): WARN advises acknowledging the owner and preparing a handoff at the next quiet point — `hub
handoff`, `hub succeed` with the hub's model, effort (the hook input's `effort.level`) and permission mode filled in,
`jwait`. The due obligation survives usage decreases and repeats on owner prompts. Only at BLOCK are
Bash, Write, Edit and NotebookEdit gated too; a reached BLOCK barrier survives usage decreases/loss until
an explicit policy reset or a change of registered hub. Bash passes only when every command of
the line is a handoff command or a narrowly allowed settings/authority/path/HANDOFF read (no substitution, no subshell), a file tool only on a
HANDOFF-*.md file; the other gated tools pass on the usual escape. A UserPromptSubmit in that session whose prompt lacks the marker
"[agent-hub auto-handoff k/N]" (written under the name used before the rename; "[delamain auto-handoff k/N]" counts too)
and lacks the handoff-continuation markers and does not start with the watchdog's "[agent-hub watchdog]" (the name before the rename, still written; "[delamain watchdog]"
counts too) means the owner spoke and resets the stage's automatic-handoff chain.

Settings (hub home config.json or environment; only warn/block/step also accept private registered-hub stage
overrides, with precedence environment > stage > home > default; docs/reference.md "Agent discipline"):
  AGENT_HUB_CONTEXT_BUDGET       on | off (default on)
  AGENT_HUB_CONTEXT_WARN         300000      AGENT_HUB_CONTEXT_WARN_STEP  50000
  AGENT_HUB_CONTEXT_BLOCK        500000      AGENT_HUB_CONTEXT_BLOCK_TOOLS ["Agent", "Task", "SendMessage"]
  AGENT_HUB_CONTEXT_ESCAPE       regex, default HANDOFF-<name>.md or handoff-ok
  AGENT_HUB_CONTEXT_TODO         the "what to do" sentence of both messages
  AGENT_HUB_STATE_DIR            state directory (default <hub home>/.state); this hook uses <state>/context-budget/
Grilling (bin/grilling.py): a Skill call, a SKILL.md read or an owner prompt that loads the skill matching
AGENT_HUB_GRILLING_SKILL marks the hub's grilling; an owner prompt refreshes the mark. While it holds, the warning tells
the hub to finish the grilling and run `hub grilling end` instead of handing over (said again at once when the grilling
starts, ends or reaches the ceiling), and at the block threshold only the BLOCK_TOOLS stay closed (no autopilot gate on
Bash/Write/Edit). At AGENT_HUB_GRILLING_CEILING the mark records the ceiling and the autopilot gate returns, but the text
says to write the handoff now, carrying the grilling, and to ask the owner: `hub succeed` still wants --owner-asked.
Fail-open: unexpected errors -> exit 0; settings-enrichment errors retain the response/checkpoint instruction.
"""
from __future__ import annotations

if __name__ == "__main__":  # fail-safe first, before anything that can fail: see hooks/failsafe.py
    try:
        import failsafe

        failsafe.install()
    except Exception:  # noqa: BLE001 — without it the hook is as it was
        pass

import copy
import json
import fcntl
import hashlib
import io
import os
import re
import shlex
import shutil
import sys
import time
from contextlib import contextmanager, redirect_stdout
from datetime import datetime, timezone
from pathlib import Path

from codex_compat import patch_paths, policy_tool

CHUNK = 1 << 20
MAX_SCAN = 64 << 20  # give up (silently) after reading this much from the tail
PRUNE_AFTER_DAYS = 30
DEFAULTS = {"warn": 300_000, "step": 50_000, "block": 500_000}
DEFAULT_TOOLS = ["Agent", "Task", "SendMessage"]
DEFAULT_ESCAPE = r"HANDOFF-[^\s/\\'\"`]*\.md|handoff-ok"
AUTOPILOT_TOOLS = ("Bash", "Write", "Edit", "NotebookEdit", "apply_patch")
AUTOPILOT_FILE = re.compile(r"(?:^|[/\\])HANDOFF-[^/\\\s]*\.md$")
SEPARATORS = (";", "&&", "||", "|", "&")
BUDGET_KEYS = ("AGENT_HUB_CONTEXT_WARN", "AGENT_HUB_CONTEXT_BLOCK", "AGENT_HUB_CONTEXT_WARN_STEP")
CONTINUATION_MARKER = "[delamain handoff-continuation]"
READY_MARKER = "[delamain handoff-continuation-ready]"
PHASES = {"none": 0, "checkpoint": 1, "prepared": 2, "dispatching": 3,
          "submitted": 4, "bound": 5, "taking-over": 6, "taken-over": 7}
# These patterns record negative directives and explicit resumption only. They never establish a grant.
TRANSFER_STOP = re.compile(
    r"\b(?:do not|don't|never)\s+(?:continue\s+)?(?:the\s+)?(?:handoff|hand\s*over|transfer)\b|"
    r"\b(?:stop|pause|cancel|suspend)\s+(?:(?:the|this|any|all|automatic|stage|context)\s+)*(?:handoff|hand\s*over|transfer)\b|"
    r"\b(?:authority|grant|transfer) (?:absent|revoked|prohibited|forbidden)\b|"
    r"\b(?:do not|don't) (?:continue|resume)(?=\s*(?:[.!?;]|$|any(?:thing| work| activity)\b|all (?:work|activity)\b))|"
    r"\b(?:stop|pause|suspend)\s+(?:all (?:work|activity)|everything)\b|"
    r"(?:^|[.;!\n])\s*(?:please\s+)?stop\s+(?:working|the\s+current\s+task)(?=\s*(?:[.;!\n]|$))|"
    r"(?:^|[.;!\n])\s*(?:please\s+)?stop(?:\s+(?:now|here))?(?=\s*(?:[.;!\n]|$))|"
    r"не\s+(?:передавай(?:те)?|передавать)\b|(?:останови(?:те)?|отмени(?:те)?)\s+передачу|"
    r"передача (?:запрещена|отменена)|разрешение(?: на передачу)? отозвано|"
    r"не продолжай(?:те)?(?=\s*(?:[.!?;]|$|ничего|никакую (?:работу|деятельность)|всю (?:работу|деятельность)))|"
    r"ничего(?: больше)? не делай(?:те)?|"
    r"останови(?:те)?\s+(?:всю (?:работу|деятельность)|все действия|всё)|"
    r"(?:^|[.;!\n])\s*(?:пожалуйста[, ]+)?(?:остановись|стоп)(?=\s*(?:[.;!\n]|$))", re.IGNORECASE)
TRANSFER_RESUME = re.compile(
    r"(?:^|[.;!\n])\s*(?:please\s+)?(?:resume|re-enable|allow)\s+(?:(?:the|this|automatic)\s+)*(?:handoff|transfer)\b|"
    r"(?:^|[.;!\n])\s*(?:you may|please|now)\s+(?:resume\s+)?(?:transfer|hand\s*over|handoff)\b|"
    r"(?:^|[.;!\n])\s*(?:handoff|transfer)\s+(?:may|can)\s+(?:resume|continue)\b|"
    r"(?:^|[.;!\n])\s*(?:возобнови(?:те)?|разрешаю|продолжай(?:те)?)\s+(?:(?:автоматическую|контекстную)\s+)?передачу",
    re.IGNORECASE)
ASSISTANT_BLOCKER = re.compile(
    r"\b(?:authority|grant) (?:absent|revoked)|owner stopped|transfer (?:prohibited|revoked)|"
    r"(?:transport|access|settings) unavailable\b", re.IGNORECASE)
DIRECTIVE_KEYS = ("transfer_stop", "transfer_directives_seen", "transfer_scan_complete")


def transfer_directive(text):
    # A prohibition in the same source wins over resumption; implementation-only pauses match neither.
    if TRANSFER_STOP.search(text):
        return True
    if "?" not in text and TRANSFER_RESUME.search(text):
        return False
    return None


def explicit_transfer_blocker(data, path, state, owner_spoke):
    """Reconcile bounded human history with durable negative state; store no prompt bodies."""
    seen = list(state.get("transfer_directives_seen") or [])[-16:]
    unknown = False

    def observe(text, source=None):
        if not isinstance(text, str) or not owner_spoke(text):
            return False
        directive = transfer_directive(text)
        if directive is None:
            return False
        if source is None:  # a live UserPromptSubmit is a new directive even if its words repeat
            state["transfer_stop"] = directive
        elif source not in seen:
            state["transfer_stop"] = directive
            seen.append(source)
        return True

    if path is not None:
        try:
            info = path.stat()
            identity = [str(path.resolve()), info.st_dev, info.st_ino]
            previous = state.get("directive_cursor") or {}
            start = previous.get("offset", 0) if previous.get("identity") == identity else 0
            if (not isinstance(start, int) or start > info.st_size
                    or (info.st_size == start and previous.get("mtime") != info.st_mtime_ns)):
                start = 0
            complete = bool(start and state.get("transfer_scan_complete"))
            history_unknown = bool(start and previous.get("unknown"))
            boundary = start
            found = False
            for line, offset in transcript_lines(path, offsets=True, start=start):
                # An appending writer may leave its final JSON record incomplete. Retry it next time;
                # it is not evidence that a human has revoked authority.
                terminated = offset + len(line) < info.st_size
                if terminated:
                    boundary = max(boundary, offset + len(line) + 1)
                if b'"user_message"' not in line and b'"user"' not in line:
                    continue
                try:
                    record = json.loads(line)
                except ValueError:
                    if terminated:
                        unknown = True
                    continue
                payload = record.get("payload") or {}
                text = None
                if record.get("type") == "event_msg" and payload.get("type") == "user_message":
                    text = payload.get("message")
                elif record.get("type") == "response_item" and payload.get("role") == "user":
                    text = " ".join(part.get("text", "") for part in payload.get("content", []) if isinstance(part, dict))
                source = hashlib.sha256(str(offset).encode() + b":" + line).hexdigest()
                if observe(text, source):
                    found = True
                    break  # latest decisive human source, not the latest neutral query
            # A previously complete prefix says nothing about an appended gap larger than our tail
            # budget. Advancing the cursor past that gap must retain unknown history, not bless it.
            covered = info.st_size - start <= MAX_SCAN
            state["transfer_scan_complete"] = found or (covered and (complete or start == 0))
            if not state["transfer_scan_complete"]:
                unknown = True
            if not found:
                unknown = unknown or history_unknown
            state["directive_cursor"] = dict(identity=identity, offset=boundary, mtime=info.st_mtime_ns,
                                             unknown=unknown)
        except (OSError, ValueError, TypeError, AttributeError):
            unknown = True
    if data.get("hook_event_name") == "UserPromptSubmit":
        if observe(data.get("prompt")):  # the current owner input may not yet have reached the rollout
            unknown = False
            if "directive_cursor" in state:
                state["directive_cursor"]["unknown"] = False
                # This new human decision supersedes any older unobserved interval as well.
                state["transfer_scan_complete"] = True
    state["transfer_directives_seen"] = seen[-16:]
    return bool(state.get("transfer_stop") or unknown
                or ASSISTANT_BLOCKER.search(str(data.get("last_assistant_message") or "")))


def diagnostic(hc, data, stage, event, **fields):
    """The optional concurrent logger must never affect hook decisions."""
    try:
        from handoff_events import emit_handoff_event
        accepted = emit_handoff_event(event, root=hc.root(), session_id=str(data.get("session_id") or ""),
                           stage=stage, turn_id=data.get("turn_id"),
                           hook_event=data.get("hook_event_name"),
                           **{key: value for key, value in fields.items() if value is not None})
    except Exception:  # noqa: BLE001 — including an absent module during separate integration
        accepted = False
    if not accepted:
        try:
            print("delamain: handoff diagnostics unavailable", file=sys.stderr)
        except Exception:  # noqa: BLE001 — unavailable stderr cannot change the hook/handoff result
            pass


def canonical_progress(ap, stage, sid, state):
    """Only the exact predecessor/request can advance this obligation. Caller holds its session mutex."""
    with ap.state_lock(stage):
        pend = ap.load_state(stage).get("pending") or {}
    if not pend:
        return "none", None, False
    if pend.get("surface") != "desktop" or pend.get("predecessor") != sid:
        return "none", None, True
    request = pend.get("request_id")
    if not request or state.get("request_id") not in (None, request):
        return "none", None, True
    state["request_id"] = request
    phase = pend.get("phase", "none")
    # Dispatch reservation without a returned identity is an unknown result, never a retry invitation.
    blocked = bool(pend.get("last_error") or phase not in PHASES or phase in ("dispatching", "uncertain"))
    if phase in ("bound", "taking-over", "taken-over"):
        actual = pend.get("id")
        if (not isinstance(actual, str) or not re.fullmatch(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", actual)
                or actual == sid or actual == pend.get("client_thread_id")):
            blocked = True
        if state.get("actual_id") not in (None, actual):
            blocked = True
        if not blocked:
            state["actual_id"] = actual
    return phase, request, blocked


def metric_age(path, skip_side):
    """Freshness comes from the usage record itself, never from rollout mtime or unrelated tool activity."""
    if path is None:
        return None
    try:
        for line in transcript_lines(path):
            if classify(line, skip_side):
                stamp = json.loads(line).get("timestamp")
                observed = datetime.fromisoformat(str(stamp).replace("Z", "+00:00"))
                if observed.tzinfo is None:
                    return None
                age = (datetime.now(timezone.utc) - observed).total_seconds()
                return age if age >= 0 else None
    except (OSError, ValueError, TypeError):
        pass
    return None


def observation_source(path, skip_side):
    if path is not None:
        try:
            for line in transcript_lines(path):
                result = classify(line, skip_side)
                if result:
                    if result[0] != "usage":
                        break
                    return ("claude_input_usage" if json.loads(line).get("type") == "assistant"
                            else "provider_last_usage")
        except (OSError, ValueError):
            pass
    return "unavailable"


def budget_setting(hc, name: str, default: int, stage=None) -> int:
    """Private stage budget overrides, never a general stage settings capability."""
    return configured_budget(hc, name, stage) or default


def configured_budget(hc, name, stage=None):
    """Return only an actually configured valid threshold; absence is part of policy provenance."""
    if name not in BUDGET_KEYS:
        raise ValueError("not a context threshold")
    stage_value = None
    if stage and hc.STAGE_RE.fullmatch(stage):
        stage_value = hc.read_config(hc.root() / stage / "config.json", project=False).get(name)
    home_value = hc.read_config(hc.root() / "config.json", project=False).get(name)
    for raw in (os.environ.get(name), stage_value, home_value):
        if raw is None or isinstance(raw, bool):
            continue
        text = str(raw).strip()
        if re.fullmatch(r"[0-9]{1,10}", text) and 1 <= int(text) <= 2_147_483_647:
            return int(text)
    return None


def trusted_read_command(executable: str, name: str, native_reads=()) -> bool:
    """Check direct read commands against the plugin/system executable they will resolve to."""
    if name in ("path", "get-content"):
        # These are native bridge conversion / PowerShell cmdlet forms, not POSIX tools.
        return (executable.lower() == name and name in native_reads
                and os.environ.get("AGENT_HUB_NATIVE_CODEX_PATHS") == "1")
    root = (os.environ.get("PLUGIN_ROOT") or os.environ.get("CLAUDE_PLUGIN_ROOT")
            or str(Path(__file__).resolve().parent.parent))
    trusted = ((Path("/bin/cat"), Path("/usr/bin/cat")) if name == "cat" else (Path(root) / "bin" / name,))
    resolved = shutil.which(executable)
    if not resolved or not Path(resolved).is_absolute():
        return False
    try:
        return any(Path(resolved).resolve(strict=True) == path.resolve(strict=True) for path in trusted if path.is_file())
    except (OSError, RuntimeError):  # inaccessible paths and symlink loops are not trusted
        return False


def handover_read(seg) -> bool:
    name = os.path.basename(seg[0]).lower()
    return (name in ("ask", "path", "cat", "get-content")
            or (name == "hub" and len(seg) > 1 and seg[1] in ("effort", "home")))


def handover_query(seg, native_reads=()) -> bool:
    """Only literal reads/conversions needed by the handoff; no shell escape markers."""
    name = os.path.basename(seg[0]).lower()
    args = seg[1:]
    if handover_read(seg) and not trusted_read_command(seg[0], name, native_reads):
        return False
    if name == "hub" and args:
        if args[0] in ("handoff", "succeed", "grilling", "desktop-request", "desktop-bind", "desktop-fail", "desktop-status"):
            return True
        if args[0] == "effort":
            args = args[1:]
            while args:
                if args[0] == "--json":
                    args = args[1:]
                elif args[0] == "--session" and len(args) > 1 and not args[1].startswith("-"):
                    args = args[2:]
                else:
                    return False
            return True
        if args[0] == "home":
            args = args[1:]
            while args:
                if args[0] == "--json":
                    args = args[1:]
                elif args[0] == "--cwd" and len(args) > 1 and not args[1].startswith("-"):
                    args = args[2:]
                else:
                    return False
            return True
    if name == "ask" and args:
        # Reject mutation verbs even if a read-only word appears later in the command.
        return args[0] in ("search", "digest", "list") or (args[0] == "allow" and "--list" in args[1:]
            and all(arg in ("--list", "--all", "--stage", "--repo") or not arg.startswith("--") for arg in args[1:]))
    if name == "path":
        return len(args) == 2 and args[0] in ("--windows", "--linux") and not args[1].startswith("-")
    if name == "cat":
        return len(args) == 1 and bool(AUTOPILOT_FILE.search(args[0])) and not args[0].startswith("-")
    if name == "get-content":
        return len(args) == 2 and args[0].lower() == "-literalpath" and bool(AUTOPILOT_FILE.search(args[1]))
    return name in ("jlog", "jwait")


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


def grilling():
    """bin/grilling.py, or None when it cannot load — then no grilling holds a handoff back (fail-open)."""
    try:
        import grilling as gr  # noqa: E402  (bin/ is on sys.path once hubcore() ran)
    except Exception:  # noqa: BLE001
        return None
    return gr


def observe_grilling(gr, ap, event: str, data: dict, sid: str) -> None:
    """Mark a hub's grilling when its skill is loaded (bin/grilling.py), refresh the mark when the owner speaks."""
    tool, tin = data.get("tool_name"), data.get("tool_input") if isinstance(data.get("tool_input"), dict) else {}
    skill, source = None, ""
    if event == "PostToolUse" and tool == "Skill":
        skill, source = gr.skill_named(tin.get("skill")), "the Skill tool"
    elif event == "PostToolUse" and tool == "Bash":
        skill, source = gr.skill_read(tin.get("command")), "the skill's SKILL.md read"
    elif event == "UserPromptSubmit":
        skill, source = gr.prompt_invokes(data.get("prompt")), "the owner's prompt"
        if not skill and ap and ap.owner_spoke(data.get("prompt")):
            gr.touch(sid)
    if skill:
        stage = ap.hub_stage_of(sid) if ap else None
        if stage:
            gr.start(stage, sid, f"{skill}, {source}")


def handover_command(command, native_reads=(), also=()) -> bool:
    """True when every command is a handoff operation or narrowly allowed read (a leading VAR=value
    and redirections allowed for existing operations; reads forbid assignments). Anything the hook cannot read
    with certainty — a substitution, a subshell, unbalanced quotes — is not a handover command."""
    if not isinstance(command, str) or not command.strip() or "$(" in command or "`" in command:
        return False
    assignments, reads = False, False
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
                assignments = True
                seg = seg[1:]
            if not seg:
                continue
            if os.path.basename(seg[0]) not in also and not handover_query(seg, native_reads):
                return False
            reads = reads or handover_read(seg)
    return not (assignments and reads)


def hubcore():
    root = os.environ.get("PLUGIN_ROOT") or os.environ.get("CLAUDE_PLUGIN_ROOT") or os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
    sys.path.insert(0, os.path.join(root, "bin"))
    import hubcore as hc  # noqa: E402

    return hc


def fmt(n: int) -> str:
    return f"{n // 1000}k"


def classify(line: bytes, skip_sidechain: bool):
    """('usage', n) | ('compact', n) | None for one JSONL line."""
    if not any(t in line for t in (b'"assistant"', b"compact_boundary", b'"event_msg"', b'"compacted"', b'"token_usage_record"')):
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
    if o.get("type") in ("event_msg", "token_usage_record"):
        payload = o.get("payload") or {}
        if o.get("type") == "token_usage_record":
            usage = payload.get("usage")
        else:
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


def transcript_lines(path: Path, offsets=False, start=0):
    """Bounded reverse iterator; a long rollout never gets loaded into memory whole."""
    with open(path, "rb") as f:
        f.seek(0, os.SEEK_END)
        pos = f.tell()
        tail = b""
        scanned = 0
        while pos > start and scanned < MAX_SCAN:
            step = min(CHUNK, pos - start, MAX_SCAN - scanned)
            pos -= step
            f.seek(pos)
            buf = f.read(step) + tail
            scanned += step
            lines = buf.split(b"\n")
            tail = lines[0] if pos > start else b""
            body = lines[1:] if pos > start else lines
            offset = pos + len(buf) + 1
            for line in reversed(body):
                offset -= len(line) + 1
                if not line.strip():
                    continue
                yield (line, offset) if offsets else line


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
        elif record.get("type") == "token_usage_record":
            window = payload.get("model_context_window") or payload.get("context_window")
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


def codex_hook_identity(data, ap, hc):
    """Use the exact Codex rollout header when an app-server hook has no engine/session env."""
    configured = hc.setting("AGENT_HUB_ENGINE", cwd=data.get("cwd"))
    if configured:
        return configured == "codex"
    if os.environ.get("CODEX_THREAD_ID"):
        return os.environ["CODEX_THREAD_ID"] == data.get("session_id")
    path, _, _ = resolve_transcript(data)
    if path is None:
        return False
    head = ap.codex_rollouts.Index()._head(path)
    return bool(head and head[0] == data.get("session_id"))


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
        state = json.loads((state_dir / f"{key}.json").read_text(encoding="utf-8"))
        return state if isinstance(state, dict) else {}
    except Exception:  # noqa: BLE001
        return {}


def save_state(state_dir: Path, key: str, state: dict) -> bool:
    try:
        hubcore().atomic_write(state_dir / f"{key}.json", json.dumps(state))
        return True
    except Exception:  # noqa: BLE001
        return False


def reset_obligation(state):
    """Drop stage/request progress while retaining the session's observed human authority and usage."""
    retained = {name: state[name] for name in
                (*DIRECTIVE_KEYS, "directive_cursor", "hub_registry", "usage_seen") if name in state}
    state.clear()
    state.update(bucket=-1, **retained)


def reconcile_registered_obligation(state, stage, sid):
    if ((state.get("stage") is not None and state["stage"] != stage)
            or (state.get("predecessor") is not None and state["predecessor"] != sid)):
        reset_obligation(state)


def registered_stage(ap, hc, sid, state):
    """Cache membership, including misses; validate filesystem signatures before reusing it.

    Positive membership needs only its own roles.json. Negative membership checks cached stat signatures,
    not a glob and JSON parse of every stage on every tool. Atomic registration changes either the root
    or one of those signatures; in-place role edits also invalidate the cache.
    """
    root = hc.root()
    def signature(path):
        try:
            stat = path.stat()
            return [stat.st_ino, stat.st_size, stat.st_mtime_ns, stat.st_ctime_ns]
        except OSError:
            return None
    cache = state.get("hub_registry") or {}
    stage = cache.get("stage") or state.get("stage")
    if stage and hc.STAGE_RE.fullmatch(stage):
        try:
            roles = json.loads((root / stage / "roles.json").read_text(encoding="utf-8"))
            hub = (roles.get("roles") or {}).get("hub") or {}
            if sid in (hub.get("session"), hub.get("cli_session_id")):
                return stage
        except (OSError, ValueError, AttributeError):
            pass
    stamp = signature(root)
    entries = cache.get("entries")
    if (cache.get("root") == str(root) and cache.get("stamp") == stamp and entries is not None
            and all(signature(root / name / "roles.json") == saved for name, saved in entries)):
        return None
    paths = sorted(p / "roles.json" for p in root.iterdir()
                   if p.is_dir() and hc.STAGE_RE.fullmatch(p.name))
    stage = None
    for path in paths:
        try:
            hub = (json.loads(path.read_text(encoding="utf-8")).get("roles") or {}).get("hub") or {}
            if sid in (hub.get("session"), hub.get("cli_session_id")) and hc.STAGE_RE.fullmatch(path.parent.name):
                stage = path.parent.name
                break
        except (OSError, ValueError, AttributeError):
            continue
    state["hub_registry"] = dict(root=str(root), stamp=stamp, stage=stage,
                                 entries=[[p.parent.name, signature(p)] for p in paths])
    return stage


def prune_state(hc, state_dir):
    """Called under the directory guard: no hook can open a lock inode while it is being retired."""
    cutoff = time.time() - PRUNE_AFTER_DAYS * 86400
    keys = {p.stem for pattern in ("*.json", "*.lock") for p in state_dir.glob(pattern)
            if not p.name.startswith(".")}
    for key in keys:
        lock_path, record = state_dir / f"{key}.lock", state_dir / f"{key}.json"
        try:
            if any(p.exists() and p.stat().st_mtime >= cutoff for p in (lock_path, record)):
                continue
            with open(lock_path, "a") as mutex:
                try:
                    fcntl.flock(mutex, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    continue
                if record.exists():
                    state = json.loads(record.read_text(encoding="utf-8"))
                    # Negative owner authority and unfinished transfer obligations never expire with age.
                    if not isinstance(state, dict) or state.get("handoff_due") or state.get("transfer_stop"):
                        continue
                    record.unlink()
                lock_path.unlink()
        except (OSError, ValueError):
            continue


@contextmanager
def budget_mutex(hc, state_dir, key):
    """Acquire an inode under the pruning guard without letting a busy session stall other sessions."""
    while True:
        mutex = None
        with hc.Flock(state_dir / ".prune.lock"):
            marker = state_dir / ".pruned"
            if not marker.exists() or time.time() - marker.stat().st_mtime > 86400:
                prune_state(hc, state_dir)
                marker.touch()
            candidate = open(state_dir / f"{key}.lock", "a")
            try:
                fcntl.flock(candidate, fcntl.LOCK_EX | fcntl.LOCK_NB)
                os.utime(candidate.name, None)
                mutex = candidate
            except BlockingIOError:
                candidate.close()
            except BaseException:
                candidate.close()
                raise
        if mutex is not None:
            break
        # A waiter never owns an unlocked file descriptor outside the pruning guard. A pruner may
        # safely retire stale unlocked inodes, and the next attempt will open the current inode.
        time.sleep(.01)
    try:
        yield
    finally:
        fcntl.flock(mutex, fcntl.LOCK_UN)
        mutex.close()


def grilling_hold(gr, grill: dict, ceiling_k: str, auto: bool) -> str:
    """What a hub grilling the owner is told instead of the handoff steps."""
    stage = grill["stage"]
    return (f"A grilling with the owner is in progress in this hub (since {str(grill.get('since'))[11:16] or '?'}, "
            f"{grill.get('source')}): do not hand over until it ends — the owner finishes the conversation with this "
            f"session{', and `hub succeed` / `hub handoff` refuse meanwhile' if auto else ''}. When the topic's frontier is empty or the "
            f"owner stops the grilling, run `{gr.shell_tool('hub')} grilling end --stage {stage}`; the next budget note "
            f"then gives the handoff steps. If it has already ended, run that now. At {ceiling_k}, the context ceiling, "
            "you write the handoff, carrying the grilling, and ask the owner whether to hand over.")


def emit(event: str, **fields) -> None:
    print(json.dumps({"hookSpecificOutput": {"hookEventName": event, **fields}}, ensure_ascii=False))


def main() -> None:
    data = json.loads(sys.stdin.read() or "{}")
    if not isinstance(data, dict):
        return
    event = data.get("hook_event_name") or ""
    if event not in ("PreToolUse", "UserPromptSubmit", "PostToolUse", "Stop"):
        return
    hc = hubcore()
    hc.use_cwd(data.get("cwd"))  # the hub home of the session's directory, not of the hook process
    _, _, key = resolve_transcript(data)
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,180}", key):
        key = hashlib.sha256(key.encode()).hexdigest()
    raw_state = hc.setting("AGENT_HUB_STATE_DIR")
    state_dir = (Path(raw_state).expanduser() if raw_state else hc.root() / ".state") / "context-budget"
    # Serialize read/modify/reserve with atomic replacement. Never hold the stage mutex across a hook.
    try:
        with budget_mutex(hc, state_dir, key):
            handle(data, hc, state_dir, key)
    except OSError as error:
        diagnostic(hc, data, None, "failure", reason="state_io", error_type=type(error).__name__)
        if event != "Stop":
            handle(data, hc, state_dir, key, writable=False)


def context_estimate_advisory(data, hc, path):
    """Opt-in enrichment only: no budget/authority/state input comes from here."""
    if data.get("agent_id"):
        return ""
    eligible = False
    try:
        if (hc.setting("AGENT_HUB_CODEX_CONTEXT_ESTIMATE") or "off").strip().lower() not in ("on", "true", "1", "yes"):
            return ""
        ap = autopilot()
        stage = ap.hub_stage_of(str(data.get("session_id") or "")) if ap else None
        if not stage or not codex_hook_identity(data, ap, hc):
            return ""
        eligible = True
        from codex_context_accounting import estimate
        fields = estimate(path, data.get("session_id"), data if data.get("hook_event_name") == "PostToolUse" else None)
        diagnostic(hc, data, stage, "observation", **fields)
        if fields["estimate_state"] == "unknown":
            return " Experimental Codex context estimate: unknown (" + fields["estimate_reason"] + ")."
        return (f" Experimental Codex context estimate for persisted history: "
                f"{fields['estimate_lower_tokens']:,}–{fields['estimate_upper_tokens']:,} tokens "
                "(heuristic range, not guaranteed tokenizer bounds or measured provider usage). "
                "This observation does not change handoff policy or establish headroom.")
    except Exception:  # observational failures must not suppress provider policy
        if eligible:
            diagnostic(hc, data, stage, "observation", estimate_state="unknown", estimate_reason="unreadable_history")
            return " Experimental Codex context estimate: unknown (unreadable_history)."
        return ""


def handle(data, hc, state_dir, key, writable=True):
    """Enrich prompt/post-tool advisories only; gates never wait for estimation."""
    event = data.get("hook_event_name")
    if event not in ("UserPromptSubmit", "PostToolUse"):
        return handle_provider_policy(data, hc, state_dir, key, writable)
    try:
        enabled = (not data.get("agent_id") and
                   (hc.setting("AGENT_HUB_CODEX_CONTEXT_ESTIMATE") or "off").strip().lower() in ("on", "true", "1", "yes"))
    except Exception:
        enabled = False
    if not enabled:
        return handle_provider_policy(data, hc, state_dir, key, writable)
    output = io.StringIO()
    try:
        with redirect_stdout(output):
            handle_provider_policy(data, hc, state_dir, key, writable)
    except BaseException:
        print(output.getvalue(), end="")
        raise
    original = output.getvalue()
    enriched = original
    try:
        note = context_estimate_advisory(data, hc, resolve_transcript(data)[0])
        if note:
            message = json.loads(original) if original.strip() else {
                "hookSpecificOutput": {"hookEventName": event, "additionalContext": "Context observation:"}}
            fields = message.get("hookSpecificOutput", {})
            if isinstance(fields.get("additionalContext"), str):
                fields["additionalContext"] += note
                enriched = json.dumps(message, ensure_ascii=False) + "\n"
    except Exception:  # Never lose a provider denial/instruction to optional enrichment.
        pass
    print(enriched, end="")


def handle_provider_policy(data, hc, state_dir, key, writable=True):
    event = data.get("hook_event_name") or ""
    ap = autopilot()
    auto = bool(ap) and ap.enabled() and not data.get("agent_id")
    gr = grilling() if not data.get("agent_id") else None
    if gr:
        try:
            observe_grilling(gr, ap, event, data, str(data.get("session_id") or ""))
        except Exception:  # noqa: BLE001 — marking is best effort
            pass
    state = load_state(state_dir, key)
    saved_state = copy.deepcopy(state)

    def save_if_changed():
        nonlocal saved_state
        # The session mutex covers this snapshot and every atomic replacement. Keep real mutations
        # durable at their existing checkpoints, without fsync for repeated observations/cache hits.
        if state == saved_state:
            return True
        if not save_state(state_dir, key, state):
            return False
        saved_state = copy.deepcopy(state)
        return True

    sid = str(data.get("session_id") or "")
    hub_stage = None
    if auto and event == "UserPromptSubmit":
        hub_stage = registered_stage(ap, hc, sid, state)
        reconcile_registered_obligation(state, hub_stage, sid)
        if writable:
            writable = save_if_changed()
        if hub_stage and ap.owner_spoke(data.get("prompt")):
            # Owner input resets the automatic chain even when budget warnings are disabled.
            ap.reset_chain(hub_stage, "the owner spoke in the hub's session")
    if (hc.setting("AGENT_HUB_CONTEXT_BUDGET") or "on").strip().lower() in ("off", "0", "false", "no"):
        if event == "Stop":
            print("{}")
        return
    tools = hc.setting_json("AGENT_HUB_CONTEXT_BLOCK_TOOLS", DEFAULT_TOOLS)
    if isinstance(tools, str):  # "Agent,SendMessage"
        tools = [t.strip() for t in tools.split(",") if t.strip()]
    raw_tool = data.get("tool_name")
    tool = policy_tool(raw_tool)
    if event == "PreToolUse" and tool not in (tools or []) and raw_tool not in (tools or []):
        if not (auto and tool in AUTOPILOT_TOOLS):
            return
    if auto and event != "UserPromptSubmit":
        hub_stage = registered_stage(ap, hc, sid, state)
        reconcile_registered_obligation(state, hub_stage, sid)
        if writable:
            writable = save_if_changed()
    hook_codex = bool(hub_stage and codex_hook_identity(data, ap, hc))
    if event == "Stop" and not hook_codex:
        print("{}")
        return
    if event == "PreToolUse" and tool not in (tools or []) and raw_tool not in (tools or []):
        if not hub_stage:
            return
    path, skip_side, _ = resolve_transcript(data)
    observation_error = False
    try:
        tokens = context_tokens(path, skip_side) if path is not None and path.is_file() else None
    except OSError:
        # A stat/open/read race or unreadable rollout is an unknown usage observation.
        tokens = None
        observation_error = True
    if tokens is not None:
        state["usage_seen"] = True
        if writable:
            writable = save_if_changed()
    transfer_blocked = False
    if hub_stage and event in ("UserPromptSubmit", "Stop"):
        transfer_blocked = explicit_transfer_blocker(data, path, state, ap.owner_spoke)
        if writable:
            writable = save_if_changed()
    due = bool(hub_stage and state.get("handoff_due") and state.get("stage") == hub_stage)
    if tokens is None and not due:
        if hub_stage and event == "UserPromptSubmit" and (state.get("usage_seen") or observation_error):
            emit(event, additionalContext=(
                f"Context budget for stage {hub_stage}: current usage is unavailable. Acknowledge the latest human "
                "message first. Save that pending input and a checkpoint; explain the missing usage observation. "
                "Do not claim to be under budget or to have completed a handoff. Read the exact session's usage "
                "and recorded settings before deciding whether handoff is due; never substitute another session "
                "or guess settings. Do not compact or stop without replying to the owner."))
        return
    try:
        window = context_window(path) if path is not None and path.is_file() else None
    except OSError:
        # Optional window enrichment must not discard known usage or its work gate.
        window = None
    defaults = ({"warn": max(1, int(window * .60)), "block": max(1, int(window * .85)),
                 "step": max(1, int(window * .10))} if window else DEFAULTS)
    warn = budget_setting(hc, "AGENT_HUB_CONTEXT_WARN", defaults["warn"], hub_stage)
    block = budget_setting(hc, "AGENT_HUB_CONTEXT_BLOCK", defaults["block"], hub_stage)
    step = budget_setting(hc, "AGENT_HUB_CONTEXT_WARN_STEP", defaults["step"], hub_stage)
    grill, at_ceiling = None, False
    if gr:
        try:
            grill = gr.active(sid)
            at_ceiling = bool(grill) and tokens is not None and tokens >= gr.ceiling(window)
            if at_ceiling:
                gr.mark_ceiling(sid, tokens)  # preparing a handoff passes; succeeding still needs the owner's yes
                if auto and hub_stage is None:
                    hub_stage = grill["stage"]
        except Exception:  # noqa: BLE001 — fail-open: as without a grilling
            grill, at_ceiling = None, False
    # at the ceiling mid-grilling: write the handoff, carrying the grilling, and leave the move to the owner
    carry = (f"The context ceiling {fmt(gr.ceiling(window))} is reached mid-grilling. {gr.ceiling_note(grill['stage'])} "
             if at_ceiling else "")
    holding = bool(grill) and not at_ceiling  # the grilling holds the handoff back
    limit_text = f"the {fmt(gr.ceiling(window))} grilling ceiling" if at_ceiling else f"the {fmt(block)} limit"

    def asked(text: str) -> str:
        """At the ceiling mid-grilling the procedure runs only on the owner's yes, and says so in its commands."""
        if not at_ceiling:
            return text
        return text.replace("Hand over now", "On the owner's yes, hand over").replace(
            " succeed --stage ", " succeed --owner-asked --stage ")

    policy = [configured_budget(hc, name, hub_stage) for name in BUDGET_KEYS]
    if due and state.get("budget_policy") != policy:
        # Effective model-window/usage changes do not clear due. An explicit policy edit/removal does.
        reset_obligation(state)
        due = False
        if writable:
            writable = save_if_changed()
    metric_source = observation_source(path, skip_side) if tokens is not None else "unavailable"
    observation = dict(metric_source=metric_source, warn=warn, block=block)
    if tokens is not None:
        observation["tokens"] = tokens
    if window:
        observation["window"] = window
    if hub_stage:
        diagnostic(hc, data, hub_stage, "observation", **observation)
    if hub_stage and not holding and not due and tokens is not None and (tokens >= warn or at_ceiling):
        # A fresh stage obligation must never inherit an old request, identity, or reached barrier.
        reset_obligation(state)
        state.update(handoff_due=True, stage=hub_stage, predecessor=sid, due_since_tokens=tokens,
                     stop_continuations=0, progress_rank=0, no_progress_count=0, budget_policy=policy)
        due = True
        if writable and save_if_changed():
            diagnostic(hc, data, hub_stage, "due_latched", due_since_tokens=tokens, reason="first_warn")
        else:
            writable = False
            diagnostic(hc, data, hub_stage, "failure", reason="state_io")
    if due and not holding and tokens is not None and tokens >= block and not state.get("block_due"):
        # WARN remains advisory; once actually reached, BLOCK survives compaction and lost usage just
        # like the handoff obligation. The explicit policy reset above is the same reset boundary.
        state["block_due"] = True
        if writable:
            writable = save_if_changed()
    block_due = bool(due and state.get("block_due"))
    phase, request, blocked = "none", None, False
    progressed = False
    if due:
        try:
            phase, request, blocked = canonical_progress(ap, hub_stage, sid, state)
            rank = PHASES.get(phase, 0)
            progressed = not blocked and rank > state.get("progress_rank", 0)
            if progressed:
                state["progress_rank"] = rank
                state["phase"] = phase
                state["no_progress_count"] = 0
                diagnostic(hc, data, hub_stage, "progress", phase=phase, request_id=request, reason="canonical_progress")
            elif event in ("PostToolUse", "Stop"):
                state["no_progress_count"] = min(255, state.get("no_progress_count", 0) + 1)
            if writable:
                writable = save_if_changed()
        except Exception as error:  # noqa: BLE001 — retain the work gate even when progress cannot be read
            blocked = True
            diagnostic(hc, data, hub_stage, "failure", reason="progress_unavailable", error_type=type(error).__name__)
    todo = hc.setting("AGENT_HUB_CONTEXT_TODO") or default_todo()
    escape_src = hc.setting("AGENT_HUB_CONTEXT_ESCAPE") or DEFAULT_ESCAPE
    try:
        escape = re.compile(escape_src)
    except re.error:
        escape = re.compile(DEFAULT_ESCAPE)
    gated = "/".join(tools or [])
    if holding:
        if event == "Stop":
            print("{}")
            return
        if event == "PreToolUse":
            if tokens is None or tokens < block or (tool not in (tools or []) and raw_tool not in (tools or [])) or mentions(data.get("tool_input"), escape):
                return
            emit("PreToolUse", permissionDecision="deny", permissionDecisionReason=(
                f"Session context is {fmt(tokens)} tokens, at or above the {fmt(block)} limit: {gated} are closed, "
                f"every turn here is expensive. {grilling_hold(gr, grill, ceiling_k=fmt(gr.ceiling(window)), auto=auto)}"))
            return
        if tokens is None or tokens < warn:
            return
        bucket = max(0, (tokens - warn) // step)
        if bucket <= state.get("bucket", -1) and state.get("grilling") == "grilling":
            return
        state.update(bucket=bucket, tokens=tokens, grilling="grilling")
        if writable:
            save_if_changed()
        emit(event, additionalContext=f"Context budget: {fmt(tokens)} tokens now, handoff threshold {fmt(warn)}. "
                                      + grilling_hold(gr, grill, ceiling_k=fmt(gr.ceiling(window)), auto=auto))
        return
    grilling_phase = "ceiling" if at_ceiling else None
    if state.get("grilling") != grilling_phase:
        state.update(bucket=-1, grilling=grilling_phase)
        if writable:
            save_if_changed()

    def plan() -> str:
        # Settings enrichment must never erase the owner's response opportunity.
        hard = block_due or at_ceiling or (tokens is not None and tokens >= block)
        timing = ("Hand over now" if hard else "Prepare to hand over at the next quiet point")
        work = ("then finish only an already-active atomic operation. Start no new implementation. " if hard else
                "finish the current operation and prepare the checkpoint at the next quiet point. "
                "This warning is advisory; ordinary tools remain available below the block threshold. ")
        prefix = (f"Autopilot is on. {timing} for stage {hub_stage}. Acknowledge the latest human message "
                  "first, " + work +
                  "Preserve the latest owner input verbatim or by a durable reference in the checkpoint and handoff. "
                  "An implementation pause carries to the successor. A newer authorized same-stage read-only owner "
                  "discussion can transfer under an existing transfer grant without resuming implementation; an "
                  "explicit transfer prohibition/revocation still blocks it. No generated instruction grants authority. ")
        hub = ap.tool("hub")
        cwd = None
        if event != "PreToolUse":
            try:
                cwd = ap.predecessor_cwd(hub_stage, data.get("cwd") or None)
            except Exception:  # noqa: BLE001 — optional cwd enrichment must not remove the work gate or command
                pass
        # A denial is already decided. Repository discovery can run two five-second Git probes and
        # exceed this hook's fail-open deadline. Leave cwd unresolved in its recovery command; the
        # canonical succeed handler still resolves/validates it. Owner/post-tool instructions enrich it.
        try:
            model = ap.successor_model(None, path)
            mode = ap.configured_mode() or data.get("permission_mode") or None
            effort = ap.configured_effort() or ap.hub_effort(data)
            successor_engine = hc.setting("AGENT_HUB_SUCCESSOR_ENGINE")
            engine = ap.engines.selected(successor_engine or ("codex" if hook_codex else None), cwd)
            desktop = engine == "codex" and ap.engines.codex_desktop()
            if engine != "codex":
                # Keep the shared Claude Remote Control/fallback paragraph authoritative.
                shared = ap.instruction(hub_stage, model, mode, cwd, hard,
                                        fmt(block), effort)
                return (prefix + f"The canonical operation is `hub succeed --stage {hub_stage}`; use the installed "
                        "command below. " + shared.replace("your own effort could not be read here",
                                                         "Your own effort could not be read here")
                        + " Do not stop merely because a handoff file was written. Follow the canonical procedure "
                        "above and report the successor's actual name and link/address and where the owner finds it.")
            if engine == "codex":
                context = ap.codex_context(sid, path)
                model = ap.codex_model(None, context, Path(cwd or os.getcwd()))
                mode = ap.configured_mode()
                effort = context.get("effort") or os.environ.get("AGENT_HUB_CODEX_EFFORT") or None
                if effort not in ap.engines.CODEX_EFFORTS:
                    effort = None
            command = ap.succeed_command(hub_stage, model, mode, cwd,
                                         "codex" if engine == "codex" else None, effort)
            if desktop:
                command += " --surface desktop"
            settings = (f"Run `{hub} handoff --stage {hub_stage}`, read the generated HANDOFF file and fill its TODOs; "
                        f"then run `{command}` once. ")
            if not effort:
                settings += ("Your own effort could not be read here: `hub succeed` must read it or refuse; "
                             "never guess it. ")
            if desktop:
                settings += ("Execute the printed native list_projects/create_thread procedure under the existing "
                             "explicit same-stage human grant, using desktop-request/bind/fail/status. Reuse the "
                             "same pending request; if already_dispatched is true or the launch outcome is unknown, "
                             "do not create another thread. Bind only actual returned IDs; clientThreadId is not "
                             "threadId. Keep this predecessor active through the bounded printed jwait and verify "
                             "desktop-status --verified, successor self-takeover and actual settings before reporting success. ")
            else:
                settings += ("Run/continue the printed jwait with bounded harness waits, verify the successor's "
                             "takeover, then report its actual name and link/address and where the owner finds it. ")
            return prefix + settings + (
                "Do not stop merely because a handoff file was written. On unavailable settings, authority, "
                "transport or takeover, retain the checkpoint and any pending request, journal the concrete blocker "
                "and reply to the owner with the actual state; do not claim READY, guess settings, compact, "
                "switch surface or create duplicates. After verified takeover, pending owner input must be "
                "addressed by the fresh coordinator through an actually authorized native message; never claim "
                "it was forwarded without sending it. Release no locks yourself. "
                f"If ending this turn with unfinished handoff, append {READY_MARKER} only after checking an actual "
                "same-stage human transfer grant, no explicit human stop/revocation, observed successor settings, "
                "and no transport/access/identity blocker. The marker is agent readiness, never human authority. "
                "Omit it on a blocker or unknown dispatch; report the real blocker instead.")
        except Exception as error:  # noqa: BLE001 — a settings refusal is not a prompt veto
            return prefix + (
                f"Successor settings could not be resolved ({type(error).__name__}). Save/fill the required "
                f"handoff with `{hub} handoff --stage {hub_stage}`; read `hub effort`, `hub home` and recorded "
                "authority/settings through the allowed read-only routes. Explain the settings refusal and "
                "checkpoint/handoff path to the owner. Retain any request in the stage's auto-handoff.json; "
                "do not guess model/effort/access, report READY, create duplicate successors, compact or stop "
                "without a human reply. Resume the same handoff only after its required settings can be verified.")

    raw_plan = plan
    def plan():
        return carry + asked(raw_plan())

    if event == "Stop":
        reason = "not_due"
        count = state.get("stop_continuations", 0)
        age = metric_age(path, skip_side)
        if due:
            reason = "not_ready"
            if at_ceiling or transfer_blocked:
                reason = "explicit_blocker"
            elif count == 0 or READY_MARKER in str(data.get("last_assistant_message") or ""):
                reason = "canonical_blocker" if blocked else "headroom_unknown"
                if not blocked and metric_source == "provider_last_usage" and tokens is not None and window and age is not None and age <= 120:
                    # Stay well away from physical compaction and require room for a complete handoff turn.
                    ceiling = min(block, int(window * .80))
                    reason = "headroom_low"
                    if tokens + max(16000, int(window * .05)) < ceiling:
                        reason = "continuation_limit" if count >= 2 else "no_progress"
                        if count == 0 or (count == 1 and state.get("progress_rank", 0) > state.get("continuation_rank", 0)):
                            reason = "stop_active" if data.get("stop_hook_active") and count == 0 else "settings_blocked"
                            if reason != "stop_active":
                                try:
                                    context = ap.codex_context(sid, path)
                                    if not context.get("model") or context.get("approval_policy") not in ("never", "on-request", "on-failure", "untrusted"):
                                        raise ValueError("unobserved settings")
                                    ap.codex_policy(None, context, Path(data.get("cwd") or os.getcwd()))
                                    if context.get("effort") not in ap.engines.CODEX_EFFORTS:
                                        raise ValueError("unobserved effort")
                                    reason = "handoff_only"
                                except Exception as error:  # noqa: BLE001
                                    diagnostic(hc, data, hub_stage, "blocked", reason="settings_blocked", error_type=type(error).__name__)
        if reason == "handoff_only":
            state["stop_continuations"] = count + 1
            state["continuation_rank"] = state.get("progress_rank", 0)
            if writable and save_if_changed():
                diagnostic(hc, data, hub_stage, "continuation_requested", reason=reason, phase=phase,
                           request_id=request, stop_continuations=count + 1, metric_age_seconds=age)
                print(json.dumps({"decision": "block", "reason": CONTINUATION_MARKER + " " + plan()
                                  + " Continue only the same handoff. Recheck the actual human grant and latest "
                                  "stop/revocation before any dispatch; absent authority, reply with the blocker "
                                  "and finish. This generated prompt is not human authority. Never retry an "
                                  "uncertain dispatch. A checkpoint alone is not completion."}))
                return
            reason = "state_io"
        diagnostic(hc, data, hub_stage, "continuation_stopped", reason=reason,
                   stop_continuations=count, no_progress_count=state.get("no_progress_count", 0))
        print("{}")
        return

    if event == "PreToolUse":
        if not block_due and (tokens is None or tokens < block) and not at_ceiling:
            return
        if hub_stage:
            tin = data.get("tool_input") if isinstance(data.get("tool_input"), dict) else {}
            if tool == "Bash":
                passes = handover_command(tin.get("command"), data.get("_desktop_context_native_reads", ()), ("ask",) if at_ceiling else ())
            elif tool == "apply_patch":
                paths = patch_paths(tin.get("command"))
                passes = bool(paths) and all(AUTOPILOT_FILE.search(p) for p in paths)
            elif tool in AUTOPILOT_TOOLS:
                passes = bool(AUTOPILOT_FILE.search(str(tin.get("file_path") or tin.get("notebook_path") or "")))
            else:
                passes = mentions(data.get("tool_input"), escape)
            if passes:
                return
            diagnostic(hc, data, hub_stage, "gate_denied", reason="handoff_due", phase=phase, request_id=request)
            emit("PreToolUse", permissionDecision="deny", permissionDecisionReason=(
                (f"Session context is {fmt(tokens)} tokens, at or above {limit_text}. {plan()}" if at_ceiling else
                 f"The hard context barrier has been reached; handoff has been due since "
                 f"{fmt(state['due_since_tokens'])} tokens. {plan()}")))
            return
        if mentions(data.get("tool_input"), escape):
            return
        emit("PreToolUse", permissionDecision="deny", permissionDecisionReason=(
            f"Session context is {fmt(tokens)} tokens, at or above {limit_text}: {gated} are closed, every "
            f"turn here is expensive. {todo} Only handing the work over passes: a tool input that names a "
            f"HANDOFF-*.md file or carries the marker handoff-ok (pattern: {escape.pattern}). {carry}".rstrip()))
        return

    if due:
        if at_ceiling and tokens is not None and tokens < warn:
            # A low grilling ceiling keeps the upstream once-per-bucket note, even on owner prompts.
            bucket = max(0, (tokens - warn) // step)
            if bucket <= state.get("bucket", -1):
                return
            state.update(bucket=bucket, tokens=tokens)
            if writable:
                save_if_changed()
            diagnostic(hc, data, hub_stage, "instruction_emitted", reason="handoff_due", phase=phase, request_id=request)
            emit(event, additionalContext=f"Context budget: {fmt(tokens)} tokens now. {plan()}")
            return
        if tokens is not None and tokens < warn:
            # Re-arm only the informational bucket. The obligation and continuation counters survive.
            state["bucket"] = -1
            if writable:
                save_if_changed()
            if event != "UserPromptSubmit" and not progressed:
                return
        bucket = (tokens - warn) // step if tokens is not None and tokens >= warn else state.get("bucket", -1)
        if bucket <= state.get("bucket", -1) and event != "UserPromptSubmit" and not progressed:
            return
        state.update(bucket=bucket)
        if writable:
            save_if_changed()
        diagnostic(hc, data, hub_stage, "instruction_emitted", reason="handoff_due", phase=phase, request_id=request)
        observed = f"{fmt(tokens)} tokens now" if tokens is not None else "current usage is unavailable"
        emit(event, additionalContext=f"Context budget: {observed}, durable handoff due. {plan()}")
        return
    if tokens is None:
        return
    if tokens < warn:
        if state.get("bucket", -1) >= 0:  # dropped below (compact / new chain): re-arm
            state.update(bucket=-1, tokens=tokens)
            save_if_changed()
        return
    bucket = (tokens - warn) // step
    if bucket <= state.get("bucket", -1) and not (hub_stage and event == "UserPromptSubmit"):
        return
    state.update(bucket=bucket, tokens=tokens)
    save_if_changed()
    extra = (f" The {fmt(block)} limit is already passed: {gated} pass only with a HANDOFF-*.md path or the "
             "marker handoff-ok." if tokens >= block
             else f" At {fmt(block)} new {gated} calls will be denied (except a handoff).")
    if hub_stage:
        emit(event, additionalContext=f"Context budget: {fmt(tokens)} tokens now, handoff threshold {fmt(warn)}. "
                                      f"{plan()}")
        return
    emit(event, additionalContext=f"Context budget: {fmt(tokens)} tokens now, handoff threshold {fmt(warn)}. {carry}{todo}{extra}")


if __name__ == "__main__":
    try:
        main()
    except Exception:  # noqa: BLE001 — malformed input and unavailable observations fail open silently
        pass
    sys.exit(0)
