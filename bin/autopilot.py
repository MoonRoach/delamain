"""Autopilot: the hub hands its shift to a successor session by itself (`hub succeed`, hooks/context_budget.py).

At the context budget's warn threshold the hook tells a stage hub to hand over at its next quiet point: `hub handoff`,
fill the TODOs, `hub succeed`. Codex console successors are detached `agent spawn --engine codex` sessions;
actual app hubs prepare a native desktop request that the current app agent executes.
Claude starts the successor as a background Remote Control session
(`claude --bg --remote-control`), reachable from the phone or claude.ai and from a terminal (`claude attach <id>`);
when that cannot start, as a headless hub (`agent spawn`) the owner talks to through `ask` and `agent send`. Either
starts from the main checkout of the hub's directory in a new worktree of its own (outside git: in the directory).

Settings (the hub home's config.json or the environment only — a cloned repository must not start background
sessions or choose their permission mode):
  AGENT_HUB_AUTO_HANDOFF               off | on (default off)
  AGENT_HUB_AUTO_HANDOFF_CHAIN         automatic handoffs in a row without the owner (default 10; 0 = never)
  AGENT_HUB_SUCCESSOR_ENGINE           inherit the selected engine, or claude | codex
  AGENT_HUB_SUCCESSOR_MODEL            the successor's model (default: the hub's own, from its transcript)
  AGENT_HUB_SUCCESSOR_EFFORT           the Claude successor's effort: low | medium | high | xhigh | max (default: the hub's
                                       own, read from its session by bin/session_effort.py — `hub effort` shows it and
                                       its source; when it cannot be read `hub succeed` refuses, it never guesses)
  AGENT_HUB_SUCCESSOR_PERMISSION_MODE  inherit (default: the hub's own mode) or a `claude --permission-mode` value
  AGENT_HUB_SUCCESSOR_TIMEOUT          seconds to wait for the successor's takeover line (default 600)
Chain state: <hub home>/<stage>/auto-handoff.json — `chain` (automatic handoffs since the owner last spoke) and
`pending` (the successor started last). `hub succeed` adds one; a takeover that is not the pending successor's, and a
prompt in the hub's session without the autopilot marker (the owner spoke), reset it. The marker is written as
"[agent-hub auto-handoff k/N]", the form used before the rename, for one release: hubs on an older plugin copy read only
that form. "[delamain auto-handoff k/N]" counts as well.
"""
from __future__ import annotations

import contextlib
import uuid
import importlib.machinery
import importlib.util
import json
import os
import re
import shlex
import subprocess
import sys
import time
from pathlib import Path
from typing import Optional

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import hubcore as hc  # noqa: E402
import engines  # noqa: E402
import codex_rollouts  # noqa: E402
import session_effort  # noqa: E402

# The tag of the plugin's own informational journal lines (a chain reset): not `hub`, which every hub's `jwait --tag hub`
# wakes on, so the line stays readable in the journal and wakes nobody.
SERVICE_TAG = "autopilot"
# Delamain's own prompts in a hub's session (not the owner speaking): the successor's take-over prompt carries MARKER_RE
# anywhere in the text, the watchdog's wake text starts with one of WATCHDOG_MARKERS. The one list of them: `owner_spoke`.
# Both the new and the former product name are read, so that a successor or a wake sent by an older version keeps its chain.
# What is WRITTEN stays on the former name for one release: marker_text() and WATCHDOG_MARKER, which `bin/watchdog` uses.
MARKER_RE = re.compile(r"\[(?:delamain|agent-hub) auto-handoff (\d+)/(\d+)\]")  # rename:keep
# The watchdog's wake prefix, as written. It stays on the former name for one release (rename:keep) because a hub that
# still runs an older plugin copy has the older UserPromptSubmit hook, which does not know the new form and would take
# the wake for the owner speaking. WATCHDOG_MARKERS is what owner_spoke reads: both forms.
WATCHDOG_MARKER = "[agent-hub watchdog]"  # rename:keep rename:transition: the former name for one release, older hooks read only it
WATCHDOG_MARKERS = (WATCHDOG_MARKER, "[delamain watchdog]")


def marker_text(k, limit) -> str:
    """The marker a successor's prompt ends with: the only thing that tells a hub's UserPromptSubmit hook that the prompt
    is not the owner speaking. It stays on the former name for one release (rename:keep) because a hub that still runs
    an older plugin copy has the older hook, which knows only that form and would reset the chain on the new one.
    MARKER_RE reads both; the switch to the new form comes in a later release."""
    return f"[agent-hub auto-handoff {k}/{limit}]"  # rename:keep rename:transition: the former name for one release, older hooks read only it


LINK_RE = re.compile(r"https?://claude\.ai/code/session_[A-Za-z0-9_-]+|claude\.ai/code/session_[A-Za-z0-9_-]+")
BG_ID_RE = re.compile(r"backgrounded\s*·\s*(\S+)")
ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[@-Z\\-_]")
# `claude --permission-mode` values; "default" (what a hook's input says for the normal mode) means no flag.
MODES = ("default", "manual", "acceptEdits", "auto", "bypassPermissions", "dontAsk", "plan")
# Environment a child CLI must not inherit: the parent session's identity, and the old hub's journal tag.
# AGENT_SESSION_ID: a headless hub's own id (`agent spawn` sets it); inherited, the successor's `--session self` would
# name the old hub.
STRIP_ENV = ("CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_SSE_PORT",
             "HUB_TAG", "AGENT_ROLE", "AGENT_SESSION_ID", "CODEX_THREAD_ID", "AGENT_HUB_CODEX_MODEL",
             "AGENT_HUB_CODEX_EFFORT") + engines.CODEX_APP_ENV
# The hub's own commands and the hub home, allowed in the successor (`--settings`) unless it runs in bypass mode: a
# background session in the default mode otherwise stops at the permission prompt of its takeover, then at reading the
# handoff outside the project, with nobody there to answer (smoke test, CLI 2.1.285). Everything else still asks — the
# owner answers over Remote Control.
HUB_ALLOW = ("hub takeover", "hub handoff", "hub succeed", "jlog", "jwait", "ask", "roles", "lock list", "agent status")
# Every background successor, bypass or not: Claude Code 2.1.290+ compacts a 200K+ conversation left idle ~54 min (on by
# default since 2.1.299), and a hub waiting on a long `jwait` is such a conversation. The context budget then reads the
# smaller post-compaction size (hooks/context_budget.py), so the hub goes on from a summary instead of handing over.
NO_IDLE_COMPACTION = {"idleCompaction": False}
LINK_WAIT_S = 90
BG_TIMEOUT_S = 60  # one `claude --bg` call
# How long a reservation of `hub succeed` / `--fallback` blocks the shift: login (30 s), up to three `claude --bg` tries
# and `claude agents` (30 s). A phase that starts later (the headless start) refreshes it; a reservation older than
# this belongs to a run that died.
START_BUDGET_S = 240
IN_PROGRESS = ("starting", "falling-back")


# What the outgoing hub tells the owner about a background successor (bin/autopilot.py `instruction` and `report`): where to
# find it. Claude Desktop groups sessions by the repository's address, and derives an owner for github.com only.
FIND_SUCCESSOR = ("it is a background Remote Control session named \"{name}\": in Claude Desktop it is listed under the "
                  "repository's address group (for a repository not hosted on github.com that is a separate group from the "
                  "folder group), on the phone in the Remote Control list")


def tool(name: str) -> str:
    """A plugin tool as the commands this module writes call it: by the absolute path of this bin/, so a same-named
    command earlier on PATH (GitHub CLI `hub`) cannot answer instead, and with no shell expansion ($HUB_BIN), which an
    allow rule would not match."""
    return shlex.quote(str(hc.BIN / name))
TAIL_CHARS = 600


# ---------------------------------------------------------------- settings

def enabled() -> bool:
    return hc.truthy(hc.setting("AGENT_HUB_AUTO_HANDOFF"))


def chain_limit() -> int:
    return hc.int_setting("AGENT_HUB_AUTO_HANDOFF_CHAIN", 10, minimum=0)


def takeover_timeout() -> int:
    return hc.int_setting("AGENT_HUB_SUCCESSOR_TIMEOUT", 600)


def configured_model() -> Optional[str]:
    return (hc.setting("AGENT_HUB_SUCCESSOR_MODEL") or "").strip() or None


# The successor continues the hub's own work at the hub's own model and effort; `agent spawn` asks for a reason when
# either is above the default (AGENT_HUB_REASON_POLICY=refuse would otherwise stop the hand-over chain).
SUCCESSOR_REASON = "hub successor: keeps the model and effort of the hub it replaces"


def configured_effort() -> Optional[str]:
    """The Claude successor's effort from the setting; None = unset."""
    raw = (hc.setting("AGENT_HUB_SUCCESSOR_EFFORT") or "").strip()
    if raw and raw not in hc.EFFORTS:
        raise hc.UsageError(f"AGENT_HUB_SUCCESSOR_EFFORT {raw!r}: one of {', '.join(hc.EFFORTS)}")
    return raw or None


def configured_mode() -> Optional[str]:
    """The successor's permission mode from the setting; None = inherit the hub's own."""
    raw = (hc.setting("AGENT_HUB_SUCCESSOR_PERMISSION_MODE") or "inherit").strip()
    return None if raw == "inherit" else raw


# ---------------------------------------------------------------- chain state

def state_path(stage: str) -> Path:
    return hc.root() / hc.check_stage(stage) / "auto-handoff.json"


def load_state(stage: str) -> dict:
    try:
        data = json.loads(state_path(stage).read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            raise ValueError
    except (OSError, ValueError):
        data = {}
    data.setdefault("chain", 0)
    data.setdefault("pending", None)
    return data


def save_state(stage: str, data: dict) -> None:
    hc.atomic_write(state_path(stage), json.dumps(data, ensure_ascii=False, indent=1) + "\n")


def state_lock(stage: str) -> hc.Flock:
    # Locking must not create an unknown stage or require write access to a read-only stage directory.
    # All launch/bind/takeover paths use this shared mutex in the writable hub home.
    return hc.Flock(hc.root() / f".auto-handoff-{hc.check_stage(stage)}.lock")


def reset_chain(stage: str, why: str) -> bool:
    """Chain back to 0 (the owner is here), and a pending successor that has not taken over within the takeover
    timeout is dropped, so the shift is not blocked by a dead one (its session is not stopped: the owner decides).
    A successor still in its window, or a `hub succeed` still running, is kept. True when anything changed; then it is
    journaled."""
    with state_lock(stage):
        data = load_state(stage)
        pend = data.get("pending") or {}
        stale = (pend and not pend.get("taken_over") and pend.get("kind") not in IN_PROGRESS
                 and pend.get("surface") != "desktop" and _age(pend) >= takeover_timeout())
        if not data["chain"] and not stale:
            return False
        was = data["chain"]
        data["chain"] = 0
        if stale:
            data["pending"] = None
        save_state(stage, data)
    dropped = (f"; dropped the pending hub-{pend.get('n')} ({pend.get('kind')} {pend.get('id') or pend.get('role')}), "
               "which did not take over in time — its session is not stopped" if stale else "")
    hc.journal_append(stage, SERVICE_TAG, f"auto-handoff chain reset ({was} → 0): {why}{dropped}")
    return True


def on_takeover(stage: str, n: int, auto: bool = False, session: str = "", locked: bool = False) -> None:
    """Called by `hub takeover` once it is done: the pending automatic successor (its takeover carries
    --auto-handoff, which only `hub succeed` writes) keeps the chain; so does a takeover of the shift that successor
    already took over (a replacement of it, by hand or by `hub succeed --replace`): the record stays and only its
    session id is rewritten. Any other takeover resets the chain — a takeover by hand means the owner is involved,
    even when it gets the number of a successor that has not taken over yet."""
    with contextlib.nullcontext() if locked else state_lock(stage):
        data = load_state(stage)
        pend = data.get("pending") or {}
        if (pend.get("surface") == "desktop" and pend.get("kind") == "desktop"
                and pend.get("taken_over") and pend.get("n") == n and session == pend.get("id")
                and hc.roles_load(stage)["roles"].get("hub", {}).get("session") == session
                and hc.roles_load(stage)["roles"].get("hub", {}).get("tag") == f"hub-{n}"):
            # Refreshing the exact native successor is not a manual replacement.
            return
        if pend.get("n") == n and (auto or pend.get("taken_over")):
            changed = False
            if not pend.get("taken_over"):
                pend["taken_over"] = hc.now().isoformat(timespec="seconds")
                changed = True
            if not auto and session and (pend.get("id") != session[:8] or pend.get("kind") != "manual"):
                # a session started by hand holds the shift now: the launch the record described (a background
                # session, a headless role) is gone, and `--replace` must not act on it
                pend["id"], pend["kind"], changed = session[:8], "manual", True
                for key in ("role", "link", "worktree", "bg_id", "why"):
                    pend.pop(key, None)
            if changed:
                save_state(stage, data)
            return
        if not data["chain"] and not pend:
            return
        was = data["chain"]
        data["chain"], data["pending"] = 0, None
        save_state(stage, data)
    if was:
        hc.journal_append(stage, f"hub-{n}", f"auto-handoff chain reset ({was} → 0): a takeover by hand")


def pending_number(stage: str, handoff) -> Optional[int]:
    """The number `hub succeed` gave the successor it started from `handoff` (the pending record), for that
    successor's `hub takeover --auto-handoff`: the name it was started under, its journal tag and the chain agree
    whatever the registry says by then. None when no pending record names that handoff."""
    pend = load_state(stage).get("pending") or {}
    if handoff is None or not isinstance(pend.get("n"), int) or not pend.get("handoff"):
        return None
    try:
        return pend["n"] if Path(pend["handoff"]).resolve() == Path(handoff).expanduser().resolve() else None
    except (OSError, ValueError):
        return None


def hub_stage_of(sid: str) -> Optional[str]:
    """The stage whose registered hub is the session `sid` (a CLI uuid or a local_… id), or None."""
    if not sid:
        return None
    for path in sorted(hc.root().glob("*/roles.json")):
        try:
            rec = (json.loads(path.read_text(encoding="utf-8")).get("roles") or {}).get("hub") or {}
        except (OSError, ValueError, AttributeError):
            continue
        if sid in (rec.get("session"), rec.get("cli_session_id")) and hc.STAGE_RE.fullmatch(path.parent.name):
            return path.parent.name
    return None


def owner_spoke(prompt) -> bool:
    """A prompt typed by a person: none of Delamain's own markers (the successor's, the watchdog's) and not a harness
    notice (they start with an XML-like tag)."""
    text = prompt if isinstance(prompt, str) else ""
    head = text.lstrip()
    return bool(text.strip()) and not MARKER_RE.search(text) and not head.startswith(WATCHDOG_MARKERS + ("<",))


# ---------------------------------------------------------------- the hub's own model and mode

def find_transcript(sid: str) -> Optional[Path]:
    return session_effort.find_transcript(sid)


def transcript_model(path) -> Optional[str]:
    """message.model of the last real assistant record of the main thread."""
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - (4 << 20)))
            lines = f.read().split(b"\n")
    except (OSError, TypeError):
        return None
    for line in reversed(lines):
        if b'"assistant"' not in line:
            continue
        try:
            o = json.loads(line)
        except ValueError:
            continue
        if not isinstance(o, dict) or o.get("type") != "assistant" or o.get("isSidechain") is True:
            continue
        model = (o.get("message") or {}).get("model")
        if isinstance(model, str) and model and model != "<synthetic>":
            return model
    return None


def successor_model(given: Optional[str], transcript=None) -> Optional[str]:
    return given or configured_model() or transcript_model(
        transcript or find_transcript(os.environ.get("CLAUDE_CODE_SESSION_ID", "")))


def hub_effort(data: dict) -> Optional[str]:
    """What the hub of a hook input runs at now: the hook input's own `effort.level`, else the other sources
    (session_effort). None = unknown; the instruction then names no --effort and `hub succeed` reads it itself, or
    refuses."""
    try:
        return session_effort.current_effort(str(data.get("session_id") or "") or None, session_effort.hook_level(data))[0]
    except hc.Failure:
        return None


def codex_context() -> dict:
    """The latest persisted turn settings of this exact Codex session, if present."""
    hit = codex_rollouts.INDEX.session(hc.session_id())
    if hit:
        try:
            with hit[0].open("rb") as f:
                f.seek(0, os.SEEK_END)
                f.seek(max(0, f.tell() - (4 << 20)))
                lines = f.read().splitlines()
            for line in reversed(lines):
                try:
                    ev = json.loads(line)
                except ValueError:
                    continue
                if isinstance(ev, dict) and ev.get("type") == "turn_context" and isinstance(ev.get("payload"), dict):
                    return dict(ev["payload"], _rollout_found=True)
        except OSError:
            pass
    # A detached coordinator knows its launch policy even before a rollout is discoverable.
    role = os.environ.get("AGENT_ROLE")
    stage = os.environ.get("HUB_STAGE")
    if role and stage and hc.STAGE_RE.fullmatch(role):
        try:
            meta = json.loads((hc.root() / hc.check_stage(stage) / "agents" / role / "meta.json").read_text())
            if meta.get("engine") == "codex" and meta.get("session_id") == hc.session_id():
                return {"model": meta.get("model"), "effort": meta.get("effort"), "sandbox_policy": meta.get("sandbox_policy") or {"type": meta.get("sandbox")},
                        "approval_policy": meta.get("approval_policy", "never")}
        except (OSError, ValueError, hc.Failure):
            pass
    return {}


def codex_model(given: Optional[str], context: dict, cwd: Path) -> Optional[str]:
    return (given or configured_model() or context.get("model") or os.environ.get("AGENT_HUB_CODEX_MODEL")
            or hc.setting("AGENT_HUB_CODEX_DEFAULT_MODEL", cwd=cwd) or None)


def codex_policy(given: Optional[str], context: dict, cwd: Path) -> tuple:
    override = given or configured_mode()
    if override:
        return engines.permission_policy(override, cwd=cwd), "never"
    sandbox = context.get("sandbox_policy")
    sandbox = sandbox.get("type") if isinstance(sandbox, dict) else sandbox
    if context and sandbox not in engines.SANDBOXES:
        raise hc.UsageError(f"unsupported or missing inherited Codex sandbox {sandbox!r}; "
                            "choose an explicit supported --permission-mode")
    if not sandbox:
        sandbox = engines.permission_policy(cwd=cwd)
    # Detached successors cannot surface approvals. Keep the sandbox and fail denied tools without a prompt.
    return sandbox, "never"


def successor_effort(given: Optional[str], notes: Optional[list] = None, hook: Optional[str] = None) -> str:
    """--effort, else AGENT_HUB_SUCCESSOR_EFFORT, else the effort this session runs at now (session_effort); when that
    cannot be read, a refusal (hc.Failure) — a guess would start the hub below its predecessor and nobody would see it.
    The successor's model does not matter: a Haiku successor gets an effort like any other (Haiku 5.5 has the setting,
    Haiku 4.5 takes the flag and ignores it). `notes` receives where an inherited effort came from; `hook` is
    `effort.level` of the hook input this runs for."""
    if given is not None and given not in hc.EFFORTS:
        raise hc.UsageError(f"--effort {given!r}: one of {', '.join(hc.EFFORTS)}")
    effort = given or configured_effort()
    if effort:
        return effort
    try:
        found = session_effort.resolve(hook=hook)
    except hc.Failure as e:
        raise hc.Failure(f"{e}. No successor is started on a guessed effort: pass --effort <level> (the hub's own) or "
                         "set AGENT_HUB_SUCCESSOR_EFFORT") from None
    if notes is not None:
        notes.append(f"effort {found.effort} inherited from this hub (source: {found.source} — {found.note})")
    return found.effort


def successor_mode(given: Optional[str], hub_mode: Optional[str] = None) -> str:
    return given or configured_mode() or hub_mode or "default"


def mode_flag(mode: str) -> tuple:
    """(value for --permission-mode or None, note): default and plan start the successor in the normal mode."""
    if mode in ("default", ""):
        return None, ""
    if mode == "plan":
        return None, "the hub was in plan mode; the successor starts in the default mode"
    return mode, ""


def fallback_mode(model: str) -> str:
    """Instead of bypassPermissions when its disclaimer was never accepted."""
    return "acceptEdits" if "haiku" in model.lower() else "auto"


# ---------------------------------------------------------------- instructions for the hub (the hook)

def succeed_command(stage: str, model: Optional[str], mode: Optional[str], cwd: Optional[str], engine=None,
                    effort: Optional[str] = None) -> str:
    parts = [tool("hub"), "succeed", "--stage", stage, "--handoff", "<the draft>"]
    if engine:
        parts += ["--engine", engine]
    if model:
        parts += ["--model", shlex.quote(model)]
    if effort:
        parts += ["--effort", shlex.quote(effort)]
    if mode:
        parts += ["--permission-mode", shlex.quote(mode)]
    if cwd:
        parts += ["--cwd", shlex.quote(cwd)]
    return " ".join(parts)


def predecessor_cwd(stage: str, hint: Optional[str]) -> Optional[str]:
    """The directory the budget hook's `hub succeed --cwd` names: the hub's registered worktree, else `hint` (the hook
    input's directory, which drifts with the hub's shell) when it is a good place, else None (`hub succeed` then decides
    and refuses a bad directory itself)."""
    recorded = hc.registered_worktree(stage)
    if recorded is not None:
        return str(recorded)
    if hint and hc.project_cwd_problem(stage, hint) is None:
        return hint
    return None


def instruction(stage: str, model: Optional[str], mode: Optional[str], cwd: Optional[str], now_block: bool,
                block_k: str, effort: Optional[str] = None) -> str:
    """The autopilot paragraph of the context budget's warning and deny reason. `effort`: what the hub runs at now (the
    hook input's); without one the command carries none and `hub succeed` reads it itself, or refuses."""
    when = ("Hand over now" if now_block else
            "Hand your shift to a successor yourself at the next quiet point (no agent waiting for your reply, no "
            "merge or lock operation in flight)")
    if engines.selected(hc.setting("AGENT_HUB_SUCCESSOR_ENGINE"), cwd) == "codex":
        context = codex_context()
        model = codex_model(None, context, Path(cwd or os.getcwd()))
        # Hook inputs may carry Claude-shaped permission names; inherit the exact Codex rollout at execution.
        effort = context.get("effort") or os.environ.get("AGENT_HUB_CODEX_EFFORT") or None
        command = succeed_command(stage, model, configured_mode(), cwd, "codex",
                                  effort if effort in engines.CODEX_EFFORTS else None)
        if engines.codex_desktop():
            return (f"Autopilot is on. {when}: write/fill `{tool('hub')} handoff --stage {stage}`, then "
                    f"run `{command} --surface desktop`. Execute its native list_projects/create_thread procedure "
                    "yourself, using desktop-request/bind/fail; clientThreadId is not threadId. Native APIs cannot "
                    "set sandbox/approval or promise Full Access. Keep this predecessor active until verified "
                    "takeover; continue the printed jwait through the shell harness. No invisible CLI fallback. "
                    f"At {block_k} only the handoff procedure passes.")
        return (f"Autopilot is on (AGENT_HUB_AUTO_HANDOFF). {when}: (1) `{tool('hub')} handoff --stage {stage}` "
                f"and fill its TODOs; (2) `{command}` starts a detached Codex successor and prints one `jwait`; "
                "(3) run/continue that waiter through the Codex shell harness, with individual waits bounded. "
                "On the successor's start line, tell the owner its name and `agent send` command, then stop: "
                "release no locks and make no more tool calls. On ALARM, check `agent status`; retry with --again "
                "only when the successor is dead. A chain limit stops automatic launches until the owner responds. "
                f"At {block_k} only handoff/succeed, jlog/jwait and the HANDOFF file pass.")
    effort = configured_effort() or effort
    unread = ("" if effort else
              " (your own effort could not be read here: `hub succeed` reads it itself and stops if it cannot — then "
              "add --effort <your effort>)")
    return (f"Autopilot is on (AGENT_HUB_AUTO_HANDOFF). {when}: (1) `{tool('hub')} handoff --stage {stage}` and fill "
            "its TODOs; "
            f"(2) `{succeed_command(stage, model, mode, cwd, effort=effort)}`{unread} (Bash timeout 300000: it may take minutes) — it starts the successor (a background Remote Control "
            "session, else a headless hub) and prints a `jwait` command; (3) run that `jwait` with Bash "
            "run_in_background: true. When it delivers the successor's start line, tell the owner one line — the "
            "successor's name and link from `hub succeed`, and plainly where it is: a background Remote Control session; "
            "in Claude Desktop it is listed under the repository's address group (for a repository not hosted on "
            "github.com a separate group from the folder group), on the phone in the Remote Control list — and stop: "
            "no more tool calls, release no locks (the "
            f"successor's takeover moves them). If it ends with ALARM: `{tool('hub')} succeed --stage {stage} --fallback` "
            "(Bash timeout 300000). If "
            "`hub succeed` reports the chain limit, stop after the handoff and wait for the owner. "
            f"At {block_k} only `hub handoff`, `hub succeed`, `jlog`, `jwait` and the HANDOFF file pass.")


# ---------------------------------------------------------------- starting the successor

def child_env() -> dict:
    return {k: v for k, v in hc.child_env().items() if k not in STRIP_ENV}


def clean(text: str) -> str:
    return ANSI_RE.sub("", text or "").replace("\r", "")


def tail(text: str, limit: int = TAIL_CHARS) -> str:
    lines = [ln.strip() for ln in clean(text).splitlines() if ln.strip()]
    return hc.one_line(" / ".join(lines[-15:]))[-limit:]


class Start(Exception):
    """The background successor could not start; the message says why (it goes to the journal)."""


def followthrough_summary() -> str:
    """Point every successor surface at the hub skill's authoritative procedure."""
    return """For Codex, apply the hub skill's Terminal follow-through (`references/codex-hub.md`): consume the report/result, verify resource ownership and
remaining approved Business DoD, then start/resume next independent authorized ready work before waiting/final.
Otherwise record the exact item/blocker, owner/resource and expected event. An executor's artifact/call-budget STOP ends its brief;
continuation remains hub-owned within actual authority. Reconcile the finite queue snapshot against Business DoD;
finish only at completed DoD, explicit owner stop or a genuine business/authority boundary. Preserve source/scope."""


class Successor:
    def __init__(self, stage: str, n: int, handoff: Path, model: str, mode: str, cwd: Path, k: int, limit: int,
                 succ: Optional[int] = None, effort: Optional[str] = None):
        # The successor starts where a Desktop session does: in the repository's main checkout (the root), in a new
        # worktree of its own — never in the hub's directory, which may be a Desktop session's worktree that goes
        # when that session is archived. Outside git: in `cwd` itself, no worktree.
        self.root = main_checkout(cwd)
        self.stage, self.n, self.handoff, self.model, self.mode = stage, n, handoff, model, mode
        self.cwd = self.root or cwd
        self.k, self.limit = k, limit
        self.cli_model = hc.model_map(cwd).get(model, model)  # `claude --bg` gets the id an AGENT_HUB_MODEL_MAP alias names
        self.effort = successor_effort(effort)
        self.succ = succ or n + 1
        self.worktree: Optional[Path] = None  # the successor's worktree once started
        self.tag = f"hub-{n}"
        self.rc_name = f"{stage}-hub-{self.succ}"
        self.title = hc.hub_title(stage, self.succ)
        self.wt_name = ""  # the name `claude --worktree` gets, picked once per background start
        self.notes: list = []
        self.env = child_env()
        cli = hc.find_claude(cwd)  # $CLAUDE_BIN, else the newer of `claude` on PATH and Claude Desktop's
        if cli is None:
            raise hc.Failure("claude not found on PATH, and no CLI is bundled with Claude Desktop (set $CLAUDE_BIN)")
        self.claude = cli.path
        old = hc.cli_warning(cli)
        if old:
            self.notes.append(old)
        self.since_ms = 0  # `claude agents` rows started before this are not ours (an earlier chain's)

    @property
    def marker(self) -> str:
        return marker_text(self.k, self.limit)

    def takeover_cmd(self) -> str:
        # no shell expansion (`--session self`, no AGENT_HUB_HOME= prefix: the session inherits the environment, E14,
        # E20): a command with `$VAR` in it asks for permission even under the allow rule of HUB_ALLOW (CLI 2.1.285)
        return (f"{tool('hub')} takeover --stage {self.stage} --session self --auto-handoff "
                f"--handoff {shlex.quote(str(self.handoff))}")

    def prompt(self) -> str:
        return (f"/delamain:hub take over stage {self.stage} from {self.handoff}: run `{self.takeover_cmd()}`, then "
                f"follow its digest and the handoff. \"Hub {self.stage} #{self.n}\" handed over automatically and "
                f"stopped; the owner may be away and reaches you here through Remote Control. {self.marker}")

    def run(self, argv: list, cwd=None, timeout: int = 60) -> subprocess.CompletedProcess:
        try:
            return subprocess.run([self.claude] + argv, capture_output=True, text=True, timeout=timeout,
                                  cwd=str(cwd or self.cwd), env=self.env, stdin=subprocess.DEVNULL)
        except subprocess.TimeoutExpired:
            return subprocess.CompletedProcess(argv, 124, "", f"claude {argv[0]} did not finish in {timeout} s")
        except OSError as e:
            return subprocess.CompletedProcess(argv, 127, "", str(e))

    def check_login(self) -> None:
        res = self.run(["auth", "status", "--json"], timeout=30)
        try:
            data = json.loads(res.stdout)
        except ValueError:
            self.notes.append(f"`claude auth status` unreadable (exit {res.returncode}) — trying anyway")
            return
        if isinstance(data, dict) and data.get("loggedIn") is False:
            raise Start("the claude CLI is not logged in (`claude auth status`: loggedIn false) — run `claude auth "
                        "login` once in a terminal")

    def bg_argv(self, mode: str, cwd=None) -> list:
        flag, note = mode_flag(mode)
        if note and note not in self.notes:
            self.notes.append(note)
        # the hub home, writable also under the sandbox; before another option: --add-dir takes several values and
        # would swallow the prompt
        argv = ["--bg", "--remote-control", self.rc_name, "-n", self.title]
        if self.root:
            self.wt_name = self.wt_name or free_worktree_name(self.root, self.rc_name)
            argv += ["--worktree", self.wt_name]
        argv += hc.add_dir_args(cwd or self.cwd)
        argv += ["--model", self.cli_model]
        if self.effort:
            argv += ["--effort", self.effort]
        if flag:
            argv += ["--permission-mode", flag]
        settings = successor_settings() if flag != "bypassPermissions" else {}
        settings.update(NO_IDLE_COMPACTION)
        argv += ["--settings", json.dumps(settings, separators=(",", ":"))]
        return argv + [self.prompt()]

    def started(self, bg_id: str, mode: str) -> dict:
        self.mode = mode
        if self.root:  # where `claude --bg --worktree` puts it (E26)
            self.worktree = self.root / ".claude" / "worktrees" / self.wt_name
        return {"id": bg_id, "cwd": str(self.cwd), "mode": mode, "worktree": str(self.worktree or "")}

    def start_bg(self) -> dict:
        """Start the background session from the root, in a new worktree; retry once without bypass (its disclaimer
        was never accepted). Returns {id, cwd, mode, worktree}; the link is read afterwards (wait_link), once the id
        is recorded."""
        self.check_login()
        mode, cwd = self.mode, self.cwd
        tried_bypass = False
        self.since_ms = int(time.time() * 1000) - 2000  # a little slack for the daemon's clock
        while True:
            res = self.run(self.bg_argv(mode, cwd), cwd=cwd, timeout=BG_TIMEOUT_S)
            out = clean(res.stdout + "\n" + res.stderr)
            if res.returncode == 0:
                break
            if res.returncode == 124:
                # `claude --bg` hung: the session may exist all the same — never start a second one beside it
                bg_id = self.id_from_agents()
                if bg_id:
                    self.notes.append(f"`claude --bg` did not return in {BG_TIMEOUT_S} s; its session {bg_id} is "
                                      "listed by `claude agents`")
                    return self.started(bg_id, mode)
                stopped = self.stop_late()
                raise Start(f"`claude --bg` did not return in {BG_TIMEOUT_S} s and `claude agents` lists no session of "
                            f"it" + (f"; stopped the late ones {', '.join(stopped)}" if stopped else ""))
            if "disclaimer" in out.lower() and mode == "bypassPermissions" and not tried_bypass:
                tried_bypass, mode = True, fallback_mode(self.cli_model)
                self.notes.append(f"bypassPermissions needs its disclaimer accepted once (`claude "
                                  f"--dangerously-skip-permissions` in a terminal) — started in {mode} instead")
                continue
            if "not trusted" in out.lower():
                raise Start(f"{cwd} is not trusted by the claude CLI — run `claude` there once and accept the trust "
                            f"prompt (`claude --bg` exited {res.returncode})")
            raise Start(f"`claude --bg` exited {res.returncode}: {tail(out, 300) or 'no output'}")
        m = BG_ID_RE.search(out)
        bg_id = m.group(1) if m else self.id_from_agents()
        if not bg_id:
            raise Start(f"`claude --bg` printed no session id: {tail(out, 300) or 'no output'}")
        return self.started(bg_id, mode)

    def our_rows(self) -> list:
        """Active background sessions (`claude agents --json`) with the successor's name started since this start —
        a same-named one from an earlier chain is not ours. Oldest first."""
        res = self.run(["agents", "--json"], timeout=30)
        try:
            rows = json.loads(res.stdout)
        except ValueError:
            return []
        hits = [r for r in (rows if isinstance(rows, list) else []) if isinstance(r, dict)
                and r.get("kind") == "background" and r.get("name") in (self.rc_name, self.title)
                and isinstance(r.get("startedAt"), (int, float)) and r["startedAt"] >= self.since_ms]
        return sorted(hits, key=lambda r: r["startedAt"])

    def id_from_agents(self) -> Optional[str]:
        hits = self.our_rows()
        return (hits[-1].get("id") or hits[-1].get("sessionId")) if hits else None

    def stop_late(self) -> list:
        """After a `claude --bg` that hung and is not listed: stop whatever of that name shows up after all, so no
        background successor runs beside the headless one. Returns the ids stopped."""
        ids = [r.get("id") or r.get("sessionId") for r in self.our_rows()]
        for bg_id in ids:
            self.remove(bg_id, rm=False)
        return ids

    def wait_link(self, bg_id: str) -> str:
        """The Remote Control link from `claude logs`, polled up to min(90 s, the takeover timeout); "" when it never
        shows. A session that says it is not logged in is stopped and reported."""
        deadline = time.monotonic() + min(LINK_WAIT_S, takeover_timeout())
        while True:
            text = clean(self.run(["logs", bg_id], timeout=30).stdout)
            m = LINK_RE.search(text) or LINK_RE.search(text.replace("\n", ""))
            if m:
                link = m.group(0)
                return link if link.startswith("http") else "https://" + link
            if "not logged in" in text.lower():
                self.remove(bg_id, rm=True)
                raise Start("the background session is not logged in (`claude logs`: \"Not logged in\") — run "
                            "`claude auth login` once in a terminal")
            if time.monotonic() >= deadline:
                return ""
            time.sleep(1)

    def remove(self, bg_id: str, rm: bool) -> None:
        self.run(["stop", bg_id], timeout=30)
        if rm:
            self.run(["rm", bg_id], timeout=30)

    def brief(self, why: str) -> Path:
        path = hc.work_dir(self.stage) / f"hub-{self.succ}-takeover-brief.md"
        hc.atomic_write(path, f"""# Takeover brief: "{self.title}" — stage {self.stage}

You are the next hub of stage `{self.stage}`. "Hub {self.stage} #{self.n}" handed over automatically and stopped; a
background Remote Control session could not start ({why}), so you run headless. The owner may be away: they reach you
through `ask` (the question register) and `agent send hub-{self.succ} "…"`.

1. Load the hub skill (`/delamain:hub`) and take over: `{self.takeover_cmd()}`
   (`self` is this session: $CLAUDE_CODE_SESSION_ID, else the $AGENT_SESSION_ID `agent spawn` exports).
   Then follow the digest and the handoff `{self.handoff}`.
2. You are a `claude -p` run: the end of your turn ends the process, and a background `jwait` dies with it. Wait with
   `"$HUB_BIN/jwait"` in the foreground (Bash `timeout` 600000, `--for 9m`). When nothing is left to wait for, write a
   status line with `"$HUB_BIN/jlog"` and end your turn; `agent send` resumes this session.
3. The footer below is written for executors: for you "the hub" is the owner — questions go to `ask add` and a
   `"$HUB_BIN/jlog" "@owner …"` line, never to chat.
4. Your own context budget applies as it did to your predecessor: hand over the same way when it says so.

{self.marker}
""")
        return path

    def start_headless(self, why: str) -> dict:
        role = f"hub-{self.succ}"
        brief = self.brief(why)
        argv = [sys.executable, str(hc.BIN / "agent"), "spawn", "--stage", self.stage, "--role", role, "--tag", role,
                "--cwd", str(self.cwd), "--model", self.model, "--brief", str(brief), "--title", self.title,
                "--reason", SUCCESSOR_REASON]
        if self.effort:
            argv += ["--effort", self.effort]
        if self.root:
            # agent spawn's own worktree: <root>/.worktrees/<branch>, a new branch from origin's default branch
            branch = free_worktree_name(self.root, self.rc_name)
            argv += ["--worktree", branch]
            self.worktree = self.root / ".worktrees" / branch
        res = subprocess.run(argv, capture_output=True, text=True, env=dict(self.env, HUB_TAG=self.tag),
                             stdin=subprocess.DEVNULL)
        if res.returncode != 0:
            if f"agent {role} is already running" in res.stderr + res.stdout:
                # a previous run (killed before it could record it) started it: the successor is there
                self.notes.append(f"the headless {role} was already running (started by an earlier run)")
                self.worktree = None  # its worktree is wherever that run put it (`agent status {role}`)
                return {"role": role, "brief": str(brief), "worktree": ""}
            raise hc.Failure(f"the headless successor did not start either: {tail(res.stderr or res.stdout, 400)}")
        return {"role": role, "brief": str(brief), "worktree": str(self.worktree or "")}

    def where(self) -> str:
        """Where the successor works, for the journal line."""
        if self.worktree:
            return f"in the new worktree {self.worktree} of {self.root}"
        return f"in {self.root} (a worktree of it)" if self.root else f"in {self.cwd}"


class CodexSuccessor(Successor):
    """Detached successor without a Claude login check or Remote Control fallback."""
    def __init__(self, stage, n, handoff, model, mode, cwd, k, limit, approval="never", sandbox_policy=None, effort=None, succ=None):
        self.root = main_checkout(cwd)
        self.stage, self.n, self.handoff, self.model, self.mode = stage, n, handoff, model, mode
        self.cwd = self.root or cwd
        self.k, self.limit, self.succ = k, limit, succ or n + 1
        self.tag, self.title = f"hub-{n}", hc.hub_title(stage, self.succ)
        self.rc_name = f"{stage}-hub-{self.succ}"
        self.worktree = None
        self.wt_name = ""
        self.notes, self.env, self.approval = [], child_env(), approval
        self.sandbox_policy = sandbox_policy or {"type": mode}
        self.effort = effort
        self.codex = engines.codex_bin(cwd)
        self.cli_model = engines.model_map(cwd).get(model, model) if model else None

    def brief_text(self):
        skill = hc.BIN.parent / "skills" / "hub" / "SKILL.md"
        return f"""# Takeover brief: "{self.title}" — stage {self.stage}

You are the next hub of stage `{self.stage}`. Your predecessor handed over automatically and stopped.
The owner may be away; they reach you through `ask` and `agent send hub-{self.succ} "…"`.

1. Read the bundled hub skill at `{skill}` (or invoke the installed `delamain:hub` skill) and its `references/codex-hub.md`
   and `references/autopilot.md`, then run
   `{self.takeover_cmd()}`. `self` resolves this worker's own session id. Follow its digest and `{self.handoff}`.
2. Run the digest's first `jwait` once unconditionally to replay handover events.
   {followthrough_summary()}
   Wait only while work or external events remain, through the shell harness with the digest's jwait;
   preserve its execution id and exit status. Keep individual tool waits bounded so you can read the inbox and respond.
   At a verified stopping boundary, journal the result and finish; `agent send` resumes this same Codex thread.
3. The executor footer's "hub" means the owner here: record questions with `ask add` and journal `@owner …`.
4. Hand over at your context budget as your predecessor did. Preserve your engine, model and permission policy.

{self.marker}
"""

    def brief(self, why):
        path = hc.work_dir(self.stage) / f"hub-{self.succ}-takeover-brief.md"
        hc.atomic_write(path, self.brief_text())
        return path

    def argv(self, brief):
        role = f"hub-{self.succ}"
        argv = [sys.executable, str(hc.BIN / "agent"), "spawn", "--engine", "codex", "--stage", self.stage,
                "--role", role, "--tag", role, "--cwd", str(self.cwd), "--brief", str(brief), "--title", self.title,
                "--sandbox-policy", json.dumps(self.sandbox_policy, separators=(",", ":")), "--reason", SUCCESSOR_REASON]
        if self.model:
            argv += ["--model", self.model]
        if self.effort:
            argv += ["--effort", self.effort]
        if self.root and self.wt_name:
            argv += ["--worktree", self.wt_name]
        return argv

    def start_headless(self, why):
        role, brief = f"hub-{self.succ}", self.brief(why)
        if self.root:
            self.wt_name = free_worktree_name(self.root, self.rc_name)
            self.worktree = self.root / ".worktrees" / self.wt_name
        res = subprocess.run(self.argv(brief), capture_output=True, text=True, env=dict(self.env, HUB_TAG=self.tag),
                             stdin=subprocess.DEVNULL)
        if res.returncode:
            if f"agent {role} is already running" in res.stdout + res.stderr:
                self.notes.append(f"the headless {role} was already running (started by an earlier run)")
                self.worktree = None
            else:
                raise hc.Failure(f"the Codex successor did not start: {tail(res.stderr or res.stdout, 400)}")
        return {"role": role, "brief": str(brief), "worktree": str(self.worktree or "")}

    def dry_spawn_argv(self):
        """The actual launcher command, with a prospective brief path and worktree; no filesystem writes."""
        if self.root:
            self.wt_name = free_worktree_name(self.root, self.rc_name)
            self.worktree = self.root / ".worktrees" / self.wt_name
        brief = hc.work_dir(self.stage) / f"hub-{self.succ}-takeover-brief.md"
        return self.argv(brief)

    def dry_argv(self):
        meta = {"cwd": str(self.cwd), "model": self.cli_model, "sandbox": self.mode,
                "approval_policy": self.approval, "sandbox_policy": self.sandbox_policy, "effort": self.effort}
        return engines.codex_argv(meta, self.brief_text())


def successor_settings() -> dict:
    """Permissions of a successor not in bypass mode: the hub's commands, reading and writing in the hub home (its
    journal, the handoff, the next handoff). Both spellings of the home when a symlink is in its path (/tmp)."""
    homes = list(dict.fromkeys([str(hc.root()), str(hc.root().resolve())]))
    allow = ([f"Bash({c}:*)" for c in HUB_ALLOW] + [f"Bash({tool(c.split()[0])}{c[len(c.split()[0]):]}:*)" for c in HUB_ALLOW]
             + [f"Edit(/{h}/**)" for h in homes])
    return {"permissions": {"allow": allow, "additionalDirectories": homes}}


def main_checkout(cwd: Path) -> Optional[Path]:
    """The main checkout of the repository `cwd` is in (itself, when it is the main checkout); None outside git."""
    res = subprocess.run(["git", "-C", str(cwd), "rev-parse", "--show-toplevel"], capture_output=True, text=True,
                         env=hc.git_env())
    top = Path(res.stdout.strip()) if res.returncode == 0 and res.stdout.strip() else None
    if top is None:
        return None
    return hc.main_checkout(top) or top


def free_worktree_name(root: Path, base: str) -> str:
    """`base`, else `base-2`, `base-3`…: the first name no worktree directory of `root` (`.claude/worktrees/` of
    `claude --worktree`, `.worktrees/` of `agent spawn`) and no branch (`worktree-<name>`, `<name>`) holds yet.
    `claude --bg --worktree` with a taken name does not fail: it joins the existing worktree (E26)."""
    def taken(name: str) -> bool:
        if (root / ".claude" / "worktrees" / name).exists() or (root / ".worktrees" / name).exists():
            return True
        return any(subprocess.run(["git", "-C", str(root), "show-ref", "--verify", "--quiet", f"refs/heads/{b}"],
                                  capture_output=True, env=hc.git_env()).returncode == 0
                   for b in (f"worktree-{name}", name))
    for name in [base] + [f"{base}-{i}" for i in range(2, 100)]:
        if not taken(name):
            return name
    raise Start(f"no free worktree name {base}-2 … {base}-99 under {root}")


def jwait_command(stage: str, succ: int, since: str, timeout_s: int) -> str:
    match = shlex.quote(r"\[hub-" + str(succ) + r"\] start:")
    return (f"{tool('jwait')} --journal --stage {stage} --match {match} --since {since} "
            f"--settle 1 --for {timeout_s}s --note \"no takeover by hub-{succ}\"")


def report(stage: str, s: Successor, pend: dict, timeout_s: int) -> None:
    """The journal line and what the hub does next."""
    since = pend["at"][11:16]
    if pend["kind"] == "bg":
        where = (f"Remote Control {pend['link']}" if pend.get("link")
                 else f"Remote Control link not shown yet (`claude logs {pend['id']}`)")
        line = (f"auto-handoff {s.k}/{s.limit}: started \"{s.title}\" ({s.model}, {pend['mode']}) as background "
                f"session {pend['id']} — {where}; terminal: claude attach {pend['id']}; {s.where()}; waiting for its "
                f"takeover (≤ {timeout_s} s)")
    else:
        line = (f"auto-handoff {s.k}/{s.limit}: started \"{s.title}\" ({s.model or 'CLI configured model'}) headless as agent {pend['role']} "
                f"because {pend['why']} — the owner reaches it through `ask` and `agent send {pend['role']} \"…\"`; "
                f"{s.where()}; waiting for its takeover (≤ {timeout_s} s)")
    if s.notes:
        line += "; " + "; ".join(s.notes)
    hc.journal_append(stage, s.tag, line)
    print(line)
    waiting = ("continue through the Codex shell execution harness" if pend.get("engine") == "codex"
               else "run in the background (Bash run_in_background: true)")
    print(f"\nNext: {waiting}:\n  "
          + jwait_command(stage, s.succ, since, timeout_s))
    if pend["kind"] == "bg":
        print(f"Exit 0 (its start line) → tell the owner one line: \"{s.title}\" took over — "
              f"{pend.get('link') or 'claude attach ' + pend['id']}; "
              + FIND_SUCCESSOR.format(name=s.rc_name) + "; then stop: no more tool calls.\n"
              f"ALARM (exit 3) → {tool('hub')} succeed --stage {stage} --fallback")
    else:
        print(f"Exit 0 → tell the owner one line: \"{s.title}\" took over headless — `agent send {pend['role']} \"…\"`; "
              "then stop: no more tool calls.\nALARM (exit 3) → if `agent status " + pend['role'] + "` says it is not "
              f"running: `{tool('hub')} succeed --stage {stage} --again --handoff <the handoff>`; else tell the owner the "
              "handoff did not complete and wait for them.")


def _age(pend: dict) -> float:
    """Seconds since the record's `at`; infinite when it cannot be read."""
    try:
        return (hc.now() - hc.dt.datetime.fromisoformat(pend["at"])).total_seconds()
    except (KeyError, ValueError, TypeError):
        return float("inf")


def blocking(pend: dict, succ: int) -> bool:
    """A successor for this shift is being started (a reservation younger than START_BUDGET_S: an older one is a run
    that died) or was started and has not taken over (until `--fallback`, `--again` or the owner drops it)."""
    if pend.get("n") != succ or pend.get("taken_over"):
        return False
    if pend.get("kind") in IN_PROGRESS:
        return _age(pend) < START_BUDGET_S
    return True


def wait_hint(stage: str, pend: dict) -> str:
    """What to do about a blocking record: when to retry, and the ready `jwait` that wakes then."""
    succ = pend.get("n")
    match = shlex.quote(r"\[hub-" + str(succ) + r"\] start:|auto-handoff")
    if pend.get("kind") in IN_PROGRESS:
        left = max(30, int(START_BUDGET_S - _age(pend)) + 5)
        at = (hc.now() + hc.dt.timedelta(seconds=left)).strftime("%H:%M")
        return (f"a run of `hub succeed` holds the shift until about {at}; wait (Bash run_in_background: true): "
                f"{tool('jwait')} --journal --stage {stage} --match {match} --settle 1 --for {left}s "
                f"--note \"retry hub succeed\" — then retry")
    left = max(30, int(takeover_timeout() - _age(pend)))
    alive = (f"`claude agents` lists {pend.get('id')}" if pend.get("kind") == "bg"
             else f"`agent status {pend.get('role')}` says it runs")
    return (f"wait for its takeover (Bash run_in_background: true): {tool('jwait')} --journal --stage {stage} "
            f"--match {match} --settle 1 --for {left}s --note \"no takeover by hub-{succ}\"; on ALARM: "
            + (f"`{tool('hub')} succeed --stage {stage} --fallback`" if pend.get("kind") == "bg" else
               f"`{tool('hub')} succeed --stage {stage} --again --handoff <the handoff>` unless {alive}"))


def _agent_module():
    loader = importlib.machinery.SourceFileLoader("agent_cli", str(hc.BIN / "agent"))
    spec = importlib.util.spec_from_loader("agent_cli", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def successor_alive(stage: str, pend: dict, cwd) -> bool:
    """Whether the recorded successor still runs: a background session listed by `claude agents`, a headless agent
    whose process is alive. When it cannot be told, alive (never drop a record of a live successor)."""
    if pend.get("kind") == "headless":
        try:
            ag = _agent_module()
            return ag.alive(ag.load_meta(stage, pend["role"]))
        except (hc.Failure, KeyError, OSError, ValueError):
            return False  # no agent directory or meta: nothing runs
    cli = hc.find_claude(cwd)
    if cli is None:
        return True
    try:
        res = subprocess.run([cli.path, "agents", "--json"], capture_output=True, text=True, timeout=30,
                             env=child_env(), stdin=subprocess.DEVNULL)
        rows = json.loads(res.stdout)
    except (OSError, subprocess.SubprocessError, ValueError):
        return True
    return any(isinstance(r, dict) and pend.get("id") in (r.get("id"), r.get("sessionId")) for r in rows or [])


def drop_dead(stage: str, n: int, cwd, succ: int) -> None:
    """`hub succeed --again`: the recorded successor of this shift did not take over and does not run — drop its
    record and give back its count. A live one is refused, a run in progress too."""
    pend = load_state(stage).get("pending") or {}
    if pend.get("n") != succ or pend.get("taken_over"):
        return
    if pend.get("kind") in IN_PROGRESS and blocking(pend, succ):
        raise hc.Failure(f"hub-{succ} is being started right now — {wait_hint(stage, pend)}")
    if pend.get("kind") not in IN_PROGRESS and successor_alive(stage, pend, cwd):
        stop = (f"claude stop {pend.get('id')}" if pend.get("kind") == "bg" else f"agent stop {pend.get('role')}")
        raise hc.Failure(f"--again: the successor hub-{succ} ({pend.get('kind')} {pend.get('id') or pend.get('role')}) "
                         f"is still running — wait for it, or stop it first (`{stop}`)")
    with state_lock(stage):
        data = load_state(stage)
        if data.get("pending") != pend:
            raise hc.Failure("--again: the pending record changed meanwhile — look again (`hub succeed` once more)")
        data["pending"] = None
        if pend.get("k") and data["chain"] == pend["k"]:
            data["chain"] -= 1
        save_state(stage, data)
    hc.journal_append(stage, f"hub-{n}", f"auto-handoff: dropped hub-{succ} ({pend.get('kind')} "
                                         f"{pend.get('id') or pend.get('role')}): it did not take over and is not running")


def list_agents(cli_path: str, cwd=None) -> Optional[list]:
    """The rows of `claude agents --json`; None when the call fails (never an empty list for a failure)."""
    try:
        res = subprocess.run([cli_path, "agents", "--json"], capture_output=True, text=True, timeout=30,
                             env=child_env(), stdin=subprocess.DEVNULL, cwd=str(cwd) if cwd else None)
        rows = json.loads(res.stdout)
    except (OSError, subprocess.SubprocessError, ValueError):
        return None
    return [r for r in rows if isinstance(r, dict)] if isinstance(rows, list) else None


def stop_recorded(stage: str, pend: dict, cwd, force: bool) -> str:
    """Stop the recorded successor (a background session: `claude stop`, history kept, never `claude rm`; a headless
    agent: `agent stop`) and say what happened. A session that is working now (`busy`; a running headless agent always
    is) is left alone unless `force`. Raises hc.Failure when it cannot be told or stopped: replacing blind would start
    a second hub beside the first."""
    own = hc.session_id()
    if pend.get("kind") == "headless":
        ag = _agent_module()
        try:
            meta = ag.load_meta(stage, pend["role"])
        except (hc.Failure, KeyError, OSError, ValueError):
            return f"the headless agent {pend.get('role')} was already gone"
        if not ag.alive(meta):
            return f"the headless agent {pend.get('role')} was not running"
        if own and own == meta.get("session_id"):
            raise hc.Failure("--replace: that is the session running this command")
        if not force:
            raise hc.Failure(f"--replace: the headless successor {pend.get('role')} is running (working now) — --force stops it too")
        res = subprocess.run([sys.executable, str(hc.BIN / "agent"), "stop", "--stage", stage, pend["role"]],
                             capture_output=True, text=True, env=child_env(), stdin=subprocess.DEVNULL)
        if res.returncode != 0:
            raise hc.Failure(f"--replace: `agent stop {pend['role']}` failed: {tail(res.stderr or res.stdout, 300)}")
        return f"stopped the headless agent {pend['role']}"
    bg_id = pend.get("id") or ""
    cli = hc.find_claude(cwd)
    if cli is None:
        raise hc.Failure("--replace: claude not found on PATH (set $CLAUDE_BIN): the successor cannot be stopped")
    rows = list_agents(cli.path, cwd)
    if rows is None:
        raise hc.Failure("--replace: `claude agents --json` failed, so whether hub-%s still runs is unknown — not starting a "
                         "second one blind; retry, or `claude stop %s` by hand and use --again" % (pend.get("n"), bg_id))
    row = next((r for r in rows if bg_id and (bg_id in (r.get("id"), r.get("sessionId"))
                                              or str(r.get("sessionId") or "").startswith(bg_id))), None)
    if row is None:
        return f"background session {bg_id} was not running"
    if own and own in (row.get("sessionId"), row.get("id")):
        raise hc.Failure("--replace: that is the session running this command")
    if row.get("status") == "busy" and not force:
        raise hc.Failure(f"--replace: the successor hub-{pend.get('n')} ({bg_id}) is working now (status busy) — wait for it "
                         "to go idle, or --force")
    res = subprocess.run([cli.path, "stop", row.get("id") or bg_id], capture_output=True, text=True, timeout=30,
                         env=child_env(), stdin=subprocess.DEVNULL, cwd=str(cwd) if cwd else None)
    if res.returncode != 0:
        raise hc.Failure(f"--replace: `claude stop {bg_id}` failed (exit {res.returncode}): {tail(res.stderr or res.stdout, 300)}")
    return f"stopped background session {bg_id} (`claude stop`; its history stays: `claude attach {bg_id}`)"


def replace_successor(stage: str, n: int, cwd, succ: int, force: bool) -> str:
    """`hub succeed --replace`: the recorded successor of this shift — one that took over, or one that runs — is
    stopped and its place in the chain given back, so that the successor started next takes the same number and the
    same chain position. Returns what happened to the old one."""
    pend = load_state(stage).get("pending") or {}
    if pend.get("n") == succ and pend.get("kind") == "manual":
        raise hc.Failure(f"--replace: hub-{succ} was taken over by hand (session {pend.get('id')}), not started by "
                         "`hub succeed`: the plugin cannot stop it — stop that session yourself and take the shift over again")
    if pend.get("n") != succ or pend.get("kind") not in ("bg", "headless"):
        if pend.get("n") == succ and pend.get("kind") in IN_PROGRESS:
            raise hc.Failure(f"--replace: hub-{succ} is being started right now — {wait_hint(stage, pend)}")
        raise hc.Failure(f"--replace: no started successor hub-{succ} is recorded (pending: "
                         f"{'hub-' + str(pend['n']) if pend.get('n') else 'none'}); `hub succeed` starts one, "
                         "`--again` replaces one that did not take over and does not run")
    done = stop_recorded(stage, pend, cwd, force)
    with state_lock(stage):
        data = load_state(stage)
        if data.get("pending") != pend:
            raise hc.Failure("--replace: the pending record changed meanwhile — look again (`hub succeed --replace` once more)")
        data["pending"] = None
        if pend.get("k") and data["chain"] == pend["k"]:
            data["chain"] -= 1
        save_state(stage, data)
    hc.journal_append(stage, f"hub-{n}", f"auto-handoff: replacing hub-{succ} ({pend.get('kind')} "
                                         f"{pend.get('id') or pend.get('role')}): {done}")
    return done


def owns_pending(previous: dict, expected: dict) -> bool:
    """Only the same CLI launch may publish/release a reservation, never a native or manual successor."""
    return (previous.get("surface") != "desktop" and previous.get("kind") != "manual"
            and bool(expected.get("at")) and previous.get("n") == expected.get("n")
            and previous.get("at") == expected.get("at") and previous.get("k") == expected.get("k"))


def _record(stage: str, succ: int, pend: dict, reservation: Optional[dict] = None) -> None:
    """Publish only into this launch's reservation; a late result cannot replace another launch."""
    expected = reservation if reservation is not None else pend
    with state_lock(stage):
        data = load_state(stage)
        previous = data.get("pending") or {}
        if previous.get("n") == succ and owns_pending(previous, expected):
            if previous.get("taken_over"):
                pend = dict(pend, taken_over=previous["taken_over"])
            if previous.get("author") and not pend.get("author"):
                pend = dict(pend, author=previous["author"])
            data["pending"] = pend
            save_state(stage, data)


def _release(stage: str, succ: int, k: int, at: Optional[str] = None) -> None:
    """Refund only this launch's reservation; another launch's pending state and chain stay intact."""
    with state_lock(stage):
        data = load_state(stage)
        if not owns_pending(data.get("pending") or {}, {"n": succ, "k": k, "at": at}):
            return
        data["pending"] = None
        if data["chain"] == k:
            data["chain"] = k - 1
        save_state(stage, data)


def require_cli_handoff_permission():
    """An app agent's CLI flag is not an owner's choice to leave the native surface."""
    if not engines.codex_desktop():
        return
    # Read the trusted home directly: neither an agent's env nor a cloned repo can grant this permission.
    allowed = hc.read_config(hc.root() / "config.json", project=False).get("AGENT_HUB_DESKTOP_CLI_HANDOFF")
    if not hc.truthy(allowed):
        raise hc.UsageError("Desktop handoff must stay native: keep the predecessor active and prepare/reuse "
                            "--surface desktop while awaiting the owner's explicit native creation request. "
                            "CLI from Desktop requires the owner's opt-in AGENT_HUB_DESKTOP_CLI_HANDOFF "
                            "in the hub home's config.json; --surface cli/--headless/--force are not owner authorization.")


def succeed(stage: str, n: int, handoff: Path, model: Optional[str], mode: Optional[str], cwd: Path,
            headless: bool = False, dry_run: bool = False, again: bool = False, engine=None,
            succ: Optional[int] = None, notes: tuple = (), effort_arg: Optional[str] = None,
            replace: bool = False, force: bool = False, surface="auto", branch=None, desktop_worktree=False) -> int:
    limit = chain_limit()
    tag, succ = f"hub-{n}", succ or n + 1
    predecessor = hc.roles_load(stage)["roles"].get("hub") or {}
    caller_sid = hc.session_id()
    retry = (load_state(stage).get("pending") or {}) if again or replace else {}
    if retry.get("n") != succ or (retry.get("taken_over") and not replace):
        retry = {}  # --replace starts from the record of a successor that took over; --again only from one that did not
    engine = engines.selected(engine or hc.setting("AGENT_HUB_SUCCESSOR_ENGINE") or retry.get("engine"), cwd)
    if surface not in ("auto", "desktop", "cli"):
        raise hc.UsageError("--surface: auto, desktop or cli")
    if headless and surface == "desktop":
        raise hc.UsageError("--headless conflicts with --surface desktop")
    if headless:
        surface = "cli"
    elif surface == "auto":
        surface = "desktop" if engine == "codex" and engines.codex_desktop() else "cli"
    if surface == "cli":
        require_cli_handoff_permission()
    if surface == "desktop" and engine != "codex":
        raise hc.UsageError("desktop surface requires --engine codex")
    if (branch or desktop_worktree) and surface != "desktop":
        raise hc.UsageError("--branch/--desktop-worktree are only supported for desktop requests")
    # A desktop retry reuses its reservation, including an uncertain native launch. Never spawn a fallback.
    existing = load_state(stage).get("pending") or {}
    if existing.get("surface") == "desktop" and (not existing.get("taken_over") or existing.get("n") == succ):
        if existing.get("taken_over"):
            raise hc.Failure("desktop successor already took over")
        if not again:
            raise hc.Failure("desktop request already reserved; use --again to inspect/retry the same request")
        if (surface != "desktop" or existing.get("n") != succ
                or Path(existing["handoff"]).resolve() != handoff.resolve()):
            raise hc.Failure("retry must keep the same desktop surface and handoff")
        desktop_report(stage, existing)
        return 0
    approval, sandbox_policy, effort, effort_notes = "never", None, None, []
    if engine == "codex":
        context = codex_context()
        if retry.get("engine") == "codex":
            context = dict(context, model=retry.get("model"), effort=retry.get("effort"),
                           sandbox_policy=retry.get("sandbox_policy") or {"type": retry.get("mode")},
                           approval_policy=retry.get("approval_policy", "never"))
        effort = effort_arg or context.get("effort")
        if effort is None and retry.get("engine") != "codex":
            effort = os.environ.get("AGENT_HUB_CODEX_EFFORT") or None
        if effort is not None and effort not in engines.CODEX_EFFORTS:
            raise hc.UsageError(f"unsupported inherited Codex effort {effort!r}")
        model = codex_model(model, context, cwd)
        problem = engines.model_problem(model, cwd) if model else None
        explicit_mode = mode or configured_mode()
        mode, approval = codex_policy(mode, context, cwd)
        sandbox_policy = (context.get("sandbox_policy") if not explicit_mode else None)
        if not isinstance(sandbox_policy, dict):
            sandbox_policy = {"type": mode}
        sandbox_policy = engines.sandbox_policy(sandbox_policy)
    else:
        model = successor_model(model or (retry.get("model") if replace else None))
        if not model:
            raise hc.UsageError("no model for the successor: pass --model (the hub's transcript was not found and "
                                "AGENT_HUB_SUCCESSOR_MODEL is not set)")
        # --again without a new --effort: the previous attempt's effort, not the hub's own now
        effort = successor_effort(effort_arg or (retry.get("effort") if retry.get("engine") != "codex" else None),
                                  effort_notes)
        problem = hc.model_problem(model, cwd)
        mode = successor_mode(mode or (retry.get("mode") if replace else None))
        if mode not in MODES:
            raise hc.UsageError(f"permission mode {mode!r}: one of {', '.join(MODES)}")
    if problem:
        raise hc.UsageError(f"--model {model!r}: {problem}")
    if surface == "desktop":
        return prepare_desktop(stage, n, succ, handoff, cwd, model, effort, sandbox_policy,
                               context.get("approval_policy"), branch, dry_run, desktop_worktree)
    if again and not dry_run:
        drop_dead(stage, n, cwd, succ)
    def check_predecessor():
        current = hc.roles_load(stage)["roles"].get("hub") or {}
        number = hc.hub_number(current.get("tag"))
        expected_n = succ if replace and retry.get("taken_over") else n
        caller_wrong = (caller_sid and retry.get("author") and caller_sid != retry["author"] if replace else
                        caller_sid and caller_sid not in (current.get("session"), current.get("cli_session_id")))
        if (not current or current.get("session") != predecessor.get("session")
                or current.get("cli_session_id") != predecessor.get("cli_session_id")
                or number is not None and number != expected_n or caller_wrong):
            raise hc.Failure("the registered predecessor changed before reservation; no successor launched")

    replaced = ""
    if replace:
        with state_lock(stage):
            check_predecessor()
        if dry_run:
            print(f"[plan] --replace: stop the recorded successor hub-{succ} "
                  f"({retry.get('kind') or '?'} {retry.get('id') or retry.get('role') or '?'}), then start a new one "
                  f"with the same number and chain position {retry.get('k') or '?'}")
        else:
            replaced = replace_successor(stage, n, cwd, succ, force)
    started = hc.now().isoformat(timespec="seconds")
    # One successor per shift and the chain counted under the lock, before anything starts: a second `hub succeed`
    # (a retry after a Bash timeout, a parallel call) sees the reservation, and an owner's reset is never overwritten.
    with state_lock(stage):
        data = load_state(stage)
        pend = data.get("pending") or {}
        # Desktop may reserve a different successor after the earlier precheck but before this mutex.
        if pend.get("surface") == "desktop" and not pend.get("taken_over"):
            raise hc.Failure("unfinished desktop request already reserved; retain it instead of launching CLI")
        check_predecessor()
        if blocking(pend, succ) and not dry_run:
            raise hc.Failure(f"a successor hub-{succ} is already {'being started' if pend.get('kind') in IN_PROGRESS else 'started'} "
                             f"({pend.get('kind')} {pend.get('id') or pend.get('role') or ''}, at {pend.get('at', '?')[11:16]}): "
                             + wait_hint(stage, pend))
        at_limit = data["chain"] >= limit
        k = data["chain"] + 1
        reservation = {"n": succ, "at": started, "k": k}
        if not at_limit and not dry_run:
            data["chain"] = k
            data["pending"] = {"n": succ, "kind": "starting", "at": started, "handoff": str(handoff),
                               "model": model, "k": k, "engine": engine, "mode": mode, "approval_policy": approval, "sandbox_policy": sandbox_policy, "effort": effort,
                               "author": hc.session_id()}
            save_state(stage, data)
    if at_limit:
        line = (f"auto-handoff chain limit {limit} reached — waiting for the owner; handoff {handoff}. "
                f"No successor started.")
        if not dry_run:
            hc.journal_append(stage, tag, line)
        print(line + "\nTell the owner one line (the handoff path) and stop; the owner starts the next hub.")
        return 3
    try:
        s = (CodexSuccessor(stage, n, handoff, model, mode, cwd, k, limit, approval, sandbox_policy, effort, succ) if engine == "codex"
             else Successor(stage, n, handoff, model, mode, cwd, k, limit, succ, effort))
        s.notes.extend(notes)
        s.notes.extend(effort_notes)
        if replaced:
            s.notes.append(f"replaces the earlier hub-{succ}: {replaced}")
        if engine == "codex" and context.get("approval_policy") not in (None, "never"):
            s.notes.append(f"inherited sandbox {mode}; approval policy {context['approval_policy']} becomes never "
                           "for the unattended successor (denied tools fail without broadening permissions)")
    except hc.Failure as e:
        if not dry_run:
            _release(stage, succ, k, reservation["at"])
            hc.journal_append(stage, tag, f"BLOCKED auto-handoff: no successor started ({e}) — waiting for the owner; "
                                          f"handoff {handoff}")
        raise
    if dry_run:
        print(f"[plan] auto-handoff {s.k}/{limit}: start \"{s.title}\" from {s.cwd}"
              + (" in a new worktree" if s.root else "") + ":\n  "
              + " ".join(shlex.quote(x) for x in (s.dry_spawn_argv() if engine == "codex"
                                                 else [s.claude] + s.bg_argv(mode))))
        if engine == "codex":
            print("\nCodex exec policy preview:\n  " + " ".join(shlex.quote(x) for x in s.dry_argv()))
        for note in effort_notes:
            print(f"[plan] {note}")
        return 0
    if engine == "codex":
        why = "the Codex engine uses a detached successor"
    elif headless:
        why = "--headless was given"
    else:
        try:
            got = s.start_bg()
            pend = {"n": succ, "kind": "bg", "at": started, "handoff": str(handoff), "model": model, "k": k,
                    "effort": effort, "link": "", **got}
            _record(stage, succ, pend, reservation)  # the id first: a crash while the link is read leaves it findable
            pend["link"] = s.wait_link(got["id"])
            _record(stage, succ, pend, reservation)
            report(stage, s, pend, takeover_timeout())
            return 0
        except Start as e:
            why = str(e)
    loud = (f"auto-handoff: WARNING background successor not started — {why}; falling back to a headless hub (agent "
            "spawn): it is NOT listed in Claude Desktop or Remote Control. To get a visible one, fix the reason above and "
            f"run `{tool('hub')} succeed --stage {stage} --replace --force`")
    hc.journal_append(stage, tag, loud)
    print(loud + "\n")
    phase = {"n": succ, "kind": "starting", "at": hc.now().isoformat(timespec="seconds"),
             "handoff": str(handoff), "model": model, "k": k, "engine": engine, "mode": mode,
             "approval_policy": approval, "sandbox_policy": sandbox_policy, "effort": effort}
    _record(stage, succ, phase, reservation)  # fresh start budget, still owned by this launcher
    reservation = phase
    got = headless_or_owner(stage, s, why, replacing=replace, reservation=reservation)
    pend = {"n": succ, "kind": "headless", "at": started, "handoff": str(handoff), "model": model, "k": k,
            "why": why, "cwd": str(s.cwd), "engine": engine, "mode": mode, "approval_policy": approval, "sandbox_policy": sandbox_policy, "effort": effort, **got}
    _record(stage, succ, pend, reservation)
    report(stage, s, pend, takeover_timeout())
    return 0


# ---------------------------------------------------------------- supported desktop request / confirmation protocol

def desktop_authority_sources(stage, pend):
    """Rule pointers use the predecessor's config layers, never the replay caller's checkout."""
    cwd = pend.get('predecessor_cwd')
    if not cwd or not Path(cwd).is_dir():
        return ("Authority rule provenance unknown: predecessor cwd was not recorded or is unavailable. "
                "Before create_thread, retain this request and predecessor until the app agent verifies the actual "
                "predecessor cwd and its hub-home/repository/stage rules using the supported config-layer resolution. "
                "Do not infer that source from the saved project main checkout or replay caller cwd.")
    rules = [str(d / 'hub-rules.md') for d in reversed(hc.config_dirs(stage, cwd=cwd))]
    return "Authority rule sources (home, repository, stage order): " + ", ".join(rules)


def desktop_report(stage, pend):
    req = pend['request_id']
    print(f"Desktop request {req} {pend['phase']}: {pend['brief']}\n"
          "No successor is verified yet. Keep the predecessor active until actual takeover.\n"
          "Native APIs cannot set sandbox/approval; Full Access is a UI/project-default limitation.\n"
          "Before create_thread, check explicit human authority in the current user instruction, inherited handoff/approved plan, "
          "answered question or standing owner permission; verify scope and revocation. Sources: "
          f"{desktop_authority_sources(stage, pend)}; {pend['handoff']}, and the stage question register/ask allow list. "
          "An empty allow list does not negate a recorded human instruction or answer. "
          "An explicit standing owner grant for automatic same-stage context handoff satisfies the native explicit-user requirement "
          "until revoked: continue without new per-transfer approval; carry its precise source/reference and scope in the handoff. "
          "For absent/revoked authority or new business scope/unrelated/parallel task, retain this request and predecessor and ask once. "
          "If transport/access/identity is unavailable, retain the same request and report that blocker. "
          "Configuration or CLI flags do not grant authority; never override policy or switch to CLI to avoid a prompt.\n"
          "Under matching human authority, the current app agent calls native list_projects; choose the unique saved project whose normalized "
          f"main checkout is {pend['project_root']}. Then run:\n"
          f"  {tool('hub')} desktop-request --stage {stage} --request {req} "
          "--project-id <returned projectId> --project-path <returned project path>\n"
          "With explicit human authorization, call native create_thread with its create_thread JSON only when already_dispatched=false. "
          "Persist the native result with desktop-bind --request <request> --stage <stage> "
          "--project-id <projectId> --thread-id <actual threadId> and/or --client-thread-id <clientThreadId>. "
          "A client ID is not a real thread ID. If pending, use supported app APIs/list_threads or successor "
          "registration to learn the real ID; never invent one. For uncertain results, desktop-fail --why <reason> "
          "retains the reservation; use --no-thread-created only for confirmed rejection before creation. "
          "--again reuses the request and never silently starts a CLI.\n"
          "Continue the takeover waiter through the shell execution harness:\n  "
          + jwait_command(stage, pend['n'], pend['at'][:16], takeover_timeout())
          + f"\nAfter the start line verify `{tool('hub')} desktop-status --stage {stage} --request {req} --verified` "
            "before stopping; exit 0 requires the actual thread/cwd, observed policy and completed takeover. "
            f"On ALARM tell the owner one line: request {req} unconfirmed, handoff {pend['handoff']}; "
            "keep the predecessor active and retain the request while awaiting the owner. Never create another thread for an uncertain result.")


def prepare_desktop(stage, n, succ, handoff, cwd, model, effort, policy, approval, branch, dry_run, desktop_worktree=False):
    root = main_checkout(cwd) or cwd.resolve()
    predecessor_cwd = str(cwd.resolve())
    authority_sources = desktop_authority_sources(stage, {'predecessor_cwd': predecessor_cwd})
    if branch:
        res = subprocess.run(['git', '-C', str(root), 'show-ref', '--verify', '--quiet', f'refs/heads/{branch}'],
                             capture_output=True, env=hc.git_env())
        if res.returncode:
            raise hc.UsageError('--branch must name an existing branch explicitly requested by the user')
    if (desktop_worktree or branch) and not main_checkout(root):
        raise hc.UsageError('desktop worktree/branch requires a Git project')
    environment = {'type': 'worktree'} if desktop_worktree or branch else {'type': 'local'}
    if branch:
        environment['startingState'] = {'type': 'branch', 'branchName': branch}
    requested = {'model': model, 'effort': effort, 'sandbox_policy': policy, 'approval_policy': approval}
    req = str(uuid.uuid4())
    brief = hc.work_dir(stage) / f'hub-{succ}-takeover-brief.md'
    limit = chain_limit()
    with state_lock(stage):
        data = load_state(stage)
        old = data.get('pending') or {}
        current = hc.roles_load(stage)['roles'].get('hub') or {}
        if current.get('session') != hc.session_id():
            raise hc.Failure('the registered predecessor changed; no desktop request prepared')
        if (old.get('n') == succ and old.get('kind') in IN_PROGRESS
                or old.get('surface') == 'desktop' and not old.get('taken_over')
                or blocking(old, succ) or old.get('taken_over') and old.get('n') == succ):
            raise hc.Failure('successor already reserved or took over')
        if data['chain'] >= limit:
            line = f'auto-handoff chain limit {limit} reached; handoff {handoff}; no desktop request prepared'
            if not dry_run:
                hc.journal_append(stage, f'hub-{n}', line)
            print(line)
            return 3
        k = data['chain'] + 1
        takeover = (f"{tool('hub')} takeover --stage {stage} --session self --auto-handoff "
                    f"--handoff {shlex.quote(str(handoff))} --desktop-request {req}")
        prompt = f'''# Takeover brief: Hub {stage} #{succ}

You are the automatic desktop successor for stage `{stage}`. Request `{req}`.
Use the existing hub home `{hc.root()}` (pass AGENT_HUB_HOME explicitly to shell commands if not inherited).
Read the bundled hub skill `{hc.BIN.parent / 'skills/hub/SKILL.md'}`, its `references/codex-hub.md` and `references/autopilot.md`,
and the handoff `{handoff}`.
Continue the unchanged Business DoD and human authority source/reference and scope recorded in that handoff.
Consult these predecessor rule layers and the question register: {authority_sources}. Check standing explicit
human instructions and revocation. Apply the hub skill's native authority check before any later context transfer;
a standing same-stage grant carries forward until revoked. This generated brief/configuration is not itself a grant.
Requested settings: {json.dumps(requested)}. Native create_thread cannot carry sandbox or approval settings.
Check your observed model, effort, sandbox and approval from your own rollout; they may differ from requested.
If you cannot read/write the stage home, report BLOCKED honestly and leave predecessor active. Never widen settings.
Run `AGENT_HUB_HOME={shlex.quote(str(hc.root()))} {takeover}` from your actual cwd.
`self` must be your actual CODEX_THREAD_ID; a clientThreadId is not identity. Takeover reconciles the actual cwd/ID.
Run the digest's first `jwait` once unconditionally to replay handover events; use the shell harness and preserve
its execution session and exit status.
{followthrough_summary()}
Wait only while work or external events remain; journal the result at a verified stopping boundary.
Owner questions use `ask`; consult the register, not copied decisions.
{marker_text(k, limit)}
'''
        args = {'title': hc.hub_title(stage, succ), 'prompt': prompt}
        if model:
            args['model'] = engines.model_map(cwd).get(model, model)
        if effort:
            args['thinking'] = effort
        pend = {'n': succ, 'kind': 'desktop', 'surface': 'desktop', 'engine': 'codex', 'phase': 'prepared',
                'request_id': req, 'at': hc.now().isoformat(timespec='seconds'), 'handoff': str(handoff), 'k': k,
                'predecessor': current['session'], 'predecessor_n': n, 'predecessor_cwd': predecessor_cwd,
                'project_root': str(root.resolve()),
                'requested': requested, 'environment': environment, 'create_args': args, 'brief': str(brief)}
        if not dry_run:
            # Brief precedes reservation: a write failure leaves no dispatchable incomplete request.
            hc.atomic_write(brief, prompt)
            data['chain'], data['pending'] = k, pend
            save_state(stage, data)
            hc.journal_append(stage, f'hub-{n}',
                              f'auto-handoff {k}/{limit}: desktop request {req} prepared, handoff {handoff}')
    desktop_report(stage, pend)
    return 0


def desktop_pending(stage, request):
    data = load_state(stage)
    pend = data.get('pending') or {}
    if pend.get('surface') != 'desktop' or pend.get('request_id') != request:
        raise hc.Failure('stale or unknown desktop request')
    current = hc.roles_load(stage)['roles'].get('hub') or {}
    expected = pend.get('id') if pend.get('taken_over') else pend['predecessor']
    allowed = {expected}
    if pend['phase'] == 'taking-over':
        allowed.add(pend.get('id'))  # A partial takeover may already have written the registry.
    expected_n = pend['n'] if current.get('session') == pend.get('id') else pend['predecessor_n']
    number = hc.hub_number(current.get('tag'))
    if current.get('session') not in allowed or number is not None and number != expected_n:
        raise hc.Failure('a later hub replaced this desktop request; no state changed')
    return data, pend


def desktop_request(stage, request, project_id, project_path):
    if not project_id.strip():
        raise hc.UsageError('use the actual projectId from native list_projects')
    project = Path(project_path).expanduser().resolve()
    if not project.is_dir():
        raise hc.UsageError('saved project path does not exist on this host')
    normalized = (main_checkout(project) or project).resolve()
    with state_lock(stage):
        data, pend = desktop_pending(stage, request)
        if pend.get('taken_over'):
            raise hc.Failure('desktop successor already took over; do not create another thread')
        if str(normalized) != pend['project_root']:
            raise hc.Failure('saved project main checkout differs from requested project')
        if pend.get('project_id') and pend['project_id'] != project_id:
            raise hc.Failure('projectId differs from the already selected project')
        dispatched = pend['phase'] != 'prepared'
        pend['project_id'] = project_id
        args = dict(pend['create_args'], target={'type':'project', 'projectId':project_id, 'environment':pend['environment']})
        # Refresh rule pointers from saved provenance; legacy requests explicitly require app-side verification.
        args['prompt'] = desktop_authority_sources(stage, pend) + '\n\n' + args['prompt']
        if not dispatched:
            # Reserve dispatch BEFORE the API call; interruption is uncertain, never an invitation to duplicate.
            pend['phase'] = 'dispatching'
        save_state(stage, data)
    print(json.dumps({'request_id': request, 'already_dispatched': dispatched, 'create_thread': args}, ensure_ascii=False))
    return 0


def desktop_bind(stage, request, thread_id=None, client_thread_id=None, project_id=None):
    if not thread_id and not client_thread_id:
        raise hc.UsageError('bind needs actual --thread-id or --client-thread-id from native APIs')
    if thread_id and not re.fullmatch(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", thread_id):
        raise hc.UsageError('actual thread ID must be a full UUID returned by native APIs')
    if client_thread_id and (len(client_thread_id) > 512 or any(c.isspace() for c in client_thread_id)):
        raise hc.UsageError('use the opaque clientThreadId returned by the native API')
    with state_lock(stage):
        data, pend = desktop_pending(stage, request)
        if not pend.get('project_id'):
            raise hc.Failure('select the saved project with desktop-request before binding')
        if project_id and project_id != pend['project_id']:
            raise hc.Failure('binding belongs to a different project')
        if thread_id and thread_id in (client_thread_id, pend.get('client_thread_id'), pend['predecessor']):
            raise hc.Failure('client/predecessor identity cannot be the actual successor')
        if pend.get('id') and thread_id and pend['id'] != thread_id:
            raise hc.Failure('conflicting actual thread ID; existing successor retained')
        if pend.get('client_thread_id') and client_thread_id and pend['client_thread_id'] != client_thread_id:
            raise hc.Failure('conflicting client ID; reservation retained')
        if client_thread_id and client_thread_id == pend.get('id'):
            raise hc.Failure('actual thread identity cannot be reclassified as a client ID')
        if thread_id:
            pend['id'] = thread_id
            pend.setdefault('actual_thread_id', thread_id)
        if client_thread_id:
            pend['client_thread_id'] = client_thread_id
        if not pend.get('taken_over') and pend['phase'] != 'taking-over':
            pend['phase'] = 'bound' if pend.get('id') else 'submitted'
        save_state(stage, data)
    print('Desktop confirmation recorded; actual takeover is ' + ('verified' if pend.get('taken_over') else 'not yet verified'))
    return 0


def desktop_fail(stage, request, why, no_thread_created=False):
    with state_lock(stage):
        data, pend = desktop_pending(stage, request)
        if pend.get('taken_over') or pend['phase'] == 'taking-over':
            raise hc.Failure('cannot fail a verified or partially applied takeover; resume takeover')
        if no_thread_created and (pend.get('id') or pend.get('client_thread_id')):
            raise hc.Failure('a native identity already exists; cannot assert no thread was created')
        pend['last_error'] = why
        pend['phase'] = 'prepared' if no_thread_created else 'uncertain'
        save_state(stage, data)
        hc.journal_append(stage, f"hub-{pend['predecessor_n']}",
                          f"auto-handoff: desktop request {request} {pend['phase']}: {why}; handoff {pend['handoff']}")
    print('Desktop failure recorded; predecessor remains active; --again reuses this reservation')
    return 0


def desktop_preflight(stage, request, session, handoff):
    """Called under the state lock before ANY takeover mutation; later hubs and failed policy stay untouched."""
    data, pend = desktop_pending(stage, request)
    if pend.get('taken_over'):
        if handoff is None or Path(handoff).resolve() != Path(pend['handoff']).resolve():
            raise hc.Failure('takeover handoff differs from the desktop reservation')
        return desktop_identity_proof(stage, request, session, allow_move=True)[1]
    cwd = Path.cwd().resolve()
    if (not engines.codex_desktop() or session != os.environ.get('CODEX_THREAD_ID')
            or session in (pend['predecessor'], pend.get('client_thread_id'))):
        raise hc.Failure('desktop takeover needs this actual app successor CODEX_THREAD_ID')
    if pend.get('id') and session != pend['id']:
        raise hc.Failure('takeover identity conflicts with confirmed real thread ID')
    if not pend.get('project_id') or pend['phase'] == 'prepared':
        raise hc.Failure('desktop request has not been dispatched to a saved project')
    if handoff is None or Path(handoff).resolve() != Path(pend['handoff']).resolve():
        raise hc.Failure('takeover handoff differs from the desktop reservation')
    if str((main_checkout(cwd) or cwd).resolve()) != pend['project_root']:
        raise hc.Failure('actual successor cwd belongs to a different main project')
    observed = codex_context()
    if not observed.get('_rollout_found'):
        raise hc.Failure('actual desktop rollout settings unavailable; retry after they are persisted')
    policy = engines.sandbox_policy(observed.get('sandbox_policy'))
    observed = {k: observed.get(k) for k in ('model', 'effort', 'approval_policy')} | {'sandbox_policy': policy}
    # Full access is never inferred from a requested policy or approval=never.
    home = hc.root().resolve()
    writable = policy['type'] == 'danger-full-access'
    if policy['type'] == 'workspace-write':
        roots = [cwd] + [Path(p).resolve() for p in policy.get('writable_roots', [])]
        writable = any(home.is_relative_to(p) for p in roots)
    if not writable:
        pend['observed'], pend['last_error'] = observed, 'observed sandbox cannot write the stage home'
        save_state(stage, data)
        raise hc.Failure('observed desktop sandbox cannot write the stage home; Full Access was not preserved; predecessor remains active')
    # Exercise the actual stage filesystem too, under the observed app policy.
    probe = hc.root() / stage / f'.desktop-access-{request}'
    try:
        with probe.open('w') as f:
            f.write('access check\n')
        probe.unlink()
    except OSError as e:
        raise hc.Failure(f'cannot write stage home: {e}; predecessor remains active') from None
    pend.setdefault('actual_thread_id', session)
    pend['id'], pend['cwd'], pend['observed'] = session, str(cwd), observed
    pend['phase'] = 'taking-over'
    save_state(stage, data)
    return pend



DESKTOP_REGISTRATION_KEYS = ('session', 'cli_session_id', 'tag', 'set_at', 'surface', 'engine',
                             'host', 'cwd', 'project_id', 'observed')


def desktop_registration(current):
    return {key: current.get(key) for key in DESKTOP_REGISTRATION_KEYS}


def desktop_identity_proof(stage, request, session, recovery=False, allow_move=False):
    """Read-only self proof. Never accept a prefix or relax desktop_pending's later-hub fence."""
    data = load_state(stage)
    pend = data.get('pending') or {}
    current = hc.roles_load(stage)['roles'].get('hub') or {}
    if (pend.get('surface') != 'desktop' or pend.get('request_id') != request
            or pend.get('phase') != 'taken-over' or not pend.get('taken_over')):
        raise hc.Failure('recovery/refresh needs this completed desktop request')
    if (not re.fullmatch(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", session or '')
            or not engines.codex_desktop() or session != hc.session_id()
            or current.get('session') != session or current.get('cli_session_id') != session
            or current.get('tag') != f"hub-{pend.get('n')}"
            or current.get('engine') != 'codex' or current.get('host') != 'codex-app'
            or session in (pend.get('predecessor'), pend.get('client_thread_id'))):
        raise hc.Failure('desktop recovery/refresh requires the exact current app hub UUID and shift')
    if recovery:
        if pend.get('kind') not in ('desktop', 'manual') or pend.get('id') not in (session, session[:8]):
            raise hc.Failure('not the recognized same-hub native identity corruption')
    elif pend.get('kind') != 'desktop' or pend.get('id') != session:
        raise hc.Failure('native identity is damaged; use desktop-recover from the current hub')
    binding = pend.get('actual_thread_id')
    if binding and binding != session:
        raise hc.Failure('original actual UUID conflicts with this hub; no state changed')
    registration = pend.get('registration')
    if registration:
        if (registration.get('session') != session or registration.get('cli_session_id') != session
                or registration.get('tag') != current.get('tag')
                or registration.get('set_at') != current.get('set_at')
                or registration.get('cwd') != pend.get('cwd')
                or registration.get('project_id') != pend.get('project_id')
                or registration.get('surface') != 'desktop'
                or registration.get('observed') != pend.get('observed')):
            raise hc.Failure('original native registration boundary differs; no state changed')
    elif recovery:
        # Legacy records have no immutable UUID. Require the original full registration line,
        # not a prefix match against discovered threads. Journal timestamps have minute precision.
        try:
            boundary = hc.dt.datetime.fromisoformat(pend['taken_over'])
        except (ValueError, TypeError):
            raise hc.Failure('invalid legacy takeover boundary; no state changed') from None
        if current.get('set_at') != pend['taken_over']:
            raise hc.Failure('legacy registration/takeover boundary is ambiguous; no state changed')
        try:
            lines = hc.journal_path(stage, boundary.date()).read_text(encoding='utf-8').splitlines()
        except OSError:
            raise hc.Failure('original registration journal unavailable; no state changed') from None
        try:
            prepared_at = hc.dt.datetime.fromisoformat(pend['at'])
            prepared_lines = hc.journal_path(stage, prepared_at.date()).read_text(encoding='utf-8').splitlines()
        except (OSError, ValueError, TypeError, KeyError):
            raise hc.Failure('original request preparation proof unavailable; no state changed') from None
        preparation = re.compile(rf"^auto-handoff {pend.get('k')}/[0-9]+: " + re.escape(
            hc.one_line(f"desktop request {request} prepared, handoff {pend.get('handoff')}")) + r"$")
        if prepared_at > boundary or not any(
                parsed and parsed[0] == prepared_at.strftime('%H:%M')
                and parsed[1] == f"hub-{pend.get('predecessor_n')}" and preparation.fullmatch(parsed[2])
                for line in prepared_lines if (parsed := hc.parse_journal_line(line))):
            raise hc.Failure('legacy request does not match its original reservation; no state changed')
        identities = set()
        original = False
        pattern = re.compile(r'^start: "[^"\n]*" \(([0-9a-fA-F-]{36}), sid [0-9a-fA-F]{8}\) ')
        for line in lines:
            parsed = hc.parse_journal_line(line)
            if not parsed or parsed[1] != current['tag']:
                continue
            match = pattern.match(parsed[2])
            if match:
                identities.add(match[1])
                original |= (parsed[0] == boundary.strftime('%H:%M') and match[1] == session
                             and '; locks:' in parsed[2] and 'roles updated' in parsed[2])
        if not original or identities != {session}:
            raise hc.Failure('legacy original full UUID registration is absent or ambiguous; no state changed')
    if not recovery and (current.get('surface') != 'desktop' or current.get('project_id') != pend.get('project_id')
          or current.get('observed') != pend.get('observed')):
        raise hc.Failure('native registration evidence differs; no state changed')
    cwd = Path.cwd().resolve()
    if (not pend.get('cwd') or not allow_move and str(cwd) != pend['cwd']
            or current.get('cwd') != pend['cwd']
            or not pend.get('project_id')
            or str((main_checkout(cwd) or cwd).resolve()) != pend.get('project_root')):
        raise hc.Failure('actual cwd/project differs from the native takeover; no state changed')
    observed = codex_context()
    if not observed.get('_rollout_found'):
        raise hc.Failure('actual desktop rollout settings unavailable; no state changed')
    observed = {key: observed.get(key) for key in ('model', 'effort', 'approval_policy')} | {
        'sandbox_policy': engines.sandbox_policy(observed.get('sandbox_policy'))}
    if observed != pend.get('observed'):
        raise hc.Failure('observed native settings differ from verified takeover; no state changed')
    policy = observed['sandbox_policy']
    roots = [cwd] + [Path(p).resolve() for p in policy.get('writable_roots', [])]
    if not (policy['type'] == 'danger-full-access' or policy['type'] == 'workspace-write'
            and any(hc.root().resolve().is_relative_to(p) for p in roots)):
        raise hc.Failure('observed sandbox cannot write the stage home; no state changed')
    return data, pend, current


def desktop_recover(stage, request):
    """The current native hub alone repairs a proven legacy self-refresh; no takeover or launch."""
    with state_lock(stage):
        data, pend, current = desktop_identity_proof(stage, request, hc.session_id(), recovery=True)
        with hc.roles_lock(stage):
            roles = hc.roles_load(stage)
            if roles['roles'].get('hub') != current:
                raise hc.Failure('hub registration changed during proof; no state changed')
            restored = dict(current, surface='desktop', project_id=pend['project_id'], observed=pend['observed'])
            pend['id'], pend['kind'] = current['session'], 'desktop'
            pend.setdefault('actual_thread_id', current['session'])
            pend.setdefault('registration', desktop_registration(restored))
            # Identity is repaired first; interruption before role restoration is safely repeatable.
            save_state(stage, data)
            roles['roles']['hub'] = restored
            hc.roles_save(stage, roles)
    print('Desktop identity recovered for the exact current hub; request, chain and takeover boundary retained')
    return 0


def desktop_status(stage, request, verified=False):
    with state_lock(stage):
        data, pend = desktop_pending(stage, request)
        actual = hc.roles_load(stage)['roles'].get('hub') or {}
        done = bool(pend.get('taken_over') and actual.get('session') == pend.get('id')
                    and actual.get('surface') == 'desktop' and actual.get('cwd') == pend.get('cwd'))
        status = {'request_id': request, 'phase': pend['phase'], 'verified': done, 'chain': data['chain'],
                  **{k: pend.get(k) for k in ('id', 'client_thread_id', 'project_id', 'cwd', 'requested', 'observed', 'last_error')}}
    print(json.dumps(status, ensure_ascii=False))
    return 0 if done or not verified else 1


def desktop_complete(stage, request):
    data, pend = desktop_pending(stage, request)
    pend['taken_over'] = pend.get('taken_over') or hc.now().isoformat(timespec='seconds')
    pend['phase'] = 'taken-over'
    pend.setdefault('registration', desktop_registration(hc.roles_load(stage)['roles'].get('hub') or {}))
    save_state(stage, data)


def headless_or_owner(stage: str, s: Successor, why: str, replacing: bool = False,
                      reservation: Optional[dict] = None) -> dict:
    try:
        if isinstance(s, CodexSuccessor):
            # A manual takeover while this command prepared its successor ends our reservation.
            # Keep the lock until spawn has returned its init handshake; takeover then proceeds normally.
            # Under --replace the registered hub is the successor just stopped (the new one's number), which is expected.
            with state_lock(stage):
                current = hc.roles_load(stage)["roles"].get("hub") or {}
                pending = load_state(stage).get("pending") or {}
                number = hc.hub_number(current.get("tag"))
                expected = (s.n, s.succ) if replacing else (s.n,)
                if not current or (number is not None and number not in expected) or not owns_pending(pending, reservation or {}) or pending.get("taken_over"):
                    raise hc.Failure("the hub changed while the successor was prepared; no Codex process started")
                return s.start_headless(why)
        return s.start_headless(why)
    except hc.Failure as e:
        _release(stage, s.succ, s.k, (reservation or {}).get("at"))
        hc.journal_append(stage, s.tag, f"BLOCKED auto-handoff: no successor started ({e}) — waiting for the owner; "
                                        f"handoff {s.handoff}")
        raise


def fallback(stage: str, n: int, why: Optional[str], succ: Optional[int] = None) -> int:
    """The background successor did not take over in time: journal its log tail, stop it, start a headless one from
    the same handoff (the chain is not counted again). Only for this hub's own successor (hub-<succ>, default n + 1).
    Reserved under the lock like `hub succeed`, so a retry after a killed run is refused rather than doubled."""
    now = hc.now().isoformat(timespec="seconds")
    succ = succ or n + 1
    with state_lock(stage):
        data = load_state(stage)
        pend = data.get("pending") or {}
        if pend.get("n") != succ:
            print(f"auto-handoff: no successor of hub-{n} pending (pending: "
                  f"{'hub-' + str(pend['n']) if pend.get('n') else 'none'}) — nothing to fall back from")
            return 1
        if pend.get("surface") == "desktop":
            raise hc.UsageError("desktop request cannot fall back to a hidden CLI; use desktop-status/bind/fail on the same request")
        require_cli_handoff_permission()
        if pend.get("taken_over"):
            print(f"hub-{pend.get('n')} already took over at {pend['taken_over'][:16]} — nothing to fall back from")
            return 0
        if pend.get("kind") in IN_PROGRESS and blocking(pend, succ):
            print(f"auto-handoff: hub-{succ} is being started right now — {wait_hint(stage, pend)}")
            return 1
        if pend.get("kind") == "headless":
            line = (f"auto-handoff: the headless successor {pend.get('role')} did not take over either — waiting for "
                    "the owner")
            hc.journal_append(stage, f"hub-{n}", line)
            print(line + "; if it is not running: "
                  + wait_hint(stage, dict(pend, at="1970-01-01T00:00:00+00:00")).split("on ALARM: ", 1)[-1])
            return 1
        if pend.get("kind") == "starting" or not pend.get("id"):
            print(f"auto-handoff: the run that was starting hub-{succ} died before it started anything — "
                  f"`{tool('hub')} succeed --stage {stage} --handoff {shlex.quote(str(pend.get('handoff', '<the handoff>')))}`")
            return 1
        bg = dict(pend, kind="bg") if pend.get("kind") == "falling-back" else pend  # a stale run of --fallback
        # a bad setting, or an effort that cannot be read, is refused before the reservation is saved
        effort = successor_effort(bg.get("effort"))
        reservation = dict(bg, kind="falling-back", at=now, bg_at=bg.get("bg_at") or bg.get("at"))
        data["pending"] = reservation
        save_state(stage, data)
    timeout_s = takeover_timeout()
    try:
        s = Successor(stage, n, Path(bg["handoff"]), bg["model"], bg.get("mode") or "default",
                      Path(bg.get("cwd") or os.getcwd()), bg.get("k") or data["chain"], chain_limit(), succ,
                      effort)
    except hc.Failure:
        _record(stage, succ, bg, reservation)
        raise
    logs = tail(s.run(["logs", bg["id"]], timeout=30).stdout)
    with state_lock(stage):
        # the successor may have registered while its logs were read: then it is taking over — do not stop it
        rec = hc.roles_load(stage)["roles"].get("hub") or {}
        num = hc.hub_number(rec.get("tag"))  # a tag with no number (`hub`) is the old hub's: a takeover tags `hub-N`
        if num is not None and num != n:
            data = load_state(stage)
            if owns_pending(data.get("pending") or {}, reservation):
                data["pending"] = bg
                save_state(stage, data)
            print(f"auto-handoff: the hub is now {rec.get('tag')} ({rec.get('title') or rec.get('session')}) — "
                  f"{bg['id']} is taking over; not stopped")
            return 0
        s.remove(bg["id"], rm=False)
    why = why or f"background session {bg['id']} wrote no takeover line in {timeout_s} s"
    hc.journal_append(stage, s.tag, f"auto-handoff: {why}; stopped it (`claude attach {bg['id']}` shows it); "
                                    f"claude logs tail: {logs or '—'}; falling back to a headless hub")
    got = headless_or_owner(stage, s, why, reservation=reservation)
    new = {"n": s.succ, "kind": "headless", "at": hc.now().isoformat(timespec="seconds"), "handoff": bg["handoff"],
           "model": bg["model"], "k": s.k, "why": why, "cwd": str(s.cwd), "bg_id": bg["id"], "effort": s.effort, **got}
    _record(stage, s.succ, new, reservation)
    report(stage, s, new, timeout_s)
    return 0
