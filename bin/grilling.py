"""Grilling in progress: while a stage hub grills the owner (the companion `grilling` skill), nothing hands the hub over
automatically — the owner finishes the conversation with the same session (owner, 15.10: a successor started
mid-grilling lost the thread of questions and answers).

The marker is one file per hub session, <state>/grilling/<session id>.json (<state> = AGENT_HUB_STATE_DIR, default
<hub home>/.state): the stage, when it was set and by what, and when the owner last spoke. It counts only while that
session is the registered hub of its stage, so a takeover ends it without a step of its own.
  set      hooks/context_budget.py, in the main thread of a session registered as a stage's hub: a Skill tool call whose
           skill name matches AGENT_HUB_GRILLING_SKILL (Claude Code), a shell command that reads such a skill's
           SKILL.md (how Codex loads a skill), an owner prompt that invokes one (`/…grilling`, `$grilling`); and
           `hub grilling start`, which the hub skill tells the hub to run on either engine
  refresh  every owner prompt in that session (one after the bound does not revive a lapsed mark)
  cleared  `hub grilling end` — the hub runs it once the topic's frontier is empty or the owner stops the grilling; the
           owner can run it at a terminal with --stage
  lapses   AGENT_HUB_GRILLING_STALE_MIN minutes after the owner last spoke (default 240), so a forgotten marker cannot
           hold handoffs for ever; the lapse is journaled
While it holds: the budget hook does not tell the hub to hand over (it says to finish the grilling and to run `hub
grilling end`), the autopilot's Bash/Write/Edit gate at the block threshold stays open (the owner's answers still go to
`ask`), and `hub succeed` / `hub handoff` with the autopilot on refuse unless --owner-asked (the owner asked for this
handoff). At the ceiling AGENT_HUB_GRILLING_CEILING (default 95% of a Codex rollout's context window, else 900000
tokens) the session cannot go on for long: the hook records it in the marker and tells the hub to write the handoff now,
carrying the grilling in its § 0 (`hub handoff` passes), and to ask the owner whether to hand over; `hub succeed` still
wants --owner-asked. A successor started that way resumes the grilling. While the mark holds without --owner-asked, an
automatic takeover (`hub takeover --auto-handoff`) of a successor started before the grilling began is refused too.
"""
from __future__ import annotations

import json
import os
import re
import shlex
import sys
import time
from pathlib import Path
from typing import Optional

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import hubcore as hc  # noqa: E402

DEFAULT_SKILL = r"grill"
DEFAULT_STALE_MIN = 240
DEFAULT_CEILING = 900_000
CEILING_SHARE = 0.95
SERVICE_TAG = "autopilot"  # the tag of the plugin's own journal lines: wakes no `jwait --tag hub`
# a command that reads the file (a reader at the head of a shell segment), not one that only names it (ls, test, git)
SKILL_FILE_RE = re.compile(r"(?:^|[;&|\n(])\s*(?:[A-Za-z_]\w*=\S*\s+)*(?:\S*/)?(?:cat|sed|head|tail|nl|less|more|bat)"
                           r"\s[^;&|\n]*?skills/([^/\s'\"`]+)/SKILL\.md")
PROMPT_SKILL_RE = re.compile(r"^\s*/([\w.:-]+)|(?:^|\s)\$([\w.:-]+)")
SID_RE = re.compile(r"[A-Za-z0-9_.:-]{1,120}")


def state_dir() -> Path:
    raw = hc.setting("AGENT_HUB_STATE_DIR")
    return (Path(raw).expanduser() if raw else hc.root() / ".state") / "grilling"


def skill_pattern() -> re.Pattern:
    try:
        return re.compile(hc.setting("AGENT_HUB_GRILLING_SKILL") or DEFAULT_SKILL, re.IGNORECASE)
    except re.error:
        return re.compile(DEFAULT_SKILL, re.IGNORECASE)


def stale_seconds() -> int:
    return hc.int_setting("AGENT_HUB_GRILLING_STALE_MIN", DEFAULT_STALE_MIN) * 60


def ceiling(window: Optional[int]) -> int:
    """The context size at which a grilling hub must hand over all the same."""
    return hc.int_setting("AGENT_HUB_GRILLING_CEILING", int(window * CEILING_SHARE) if window else DEFAULT_CEILING)


def skill_named(name) -> Optional[str]:
    """`name` when it is a grilling skill's name, else None."""
    return name if isinstance(name, str) and name and skill_pattern().search(name) else None


def skill_read(command) -> Optional[str]:
    """The grilling skill whose SKILL.md the shell command names (a Codex hub loads a skill by reading it), else None."""
    if not isinstance(command, str) or "SKILL.md" not in command:
        return None
    return next((m.group(1) for m in SKILL_FILE_RE.finditer(command) if skill_named(m.group(1))), None)


def prompt_invokes(prompt) -> Optional[str]:
    """The grilling skill an owner prompt invokes by name (`/plugin:grilling …` in Claude Code, `$grilling` in
    Codex), else None. Words about grilling are not an invocation: the model loads the skill then, and that is seen."""
    if not isinstance(prompt, str):
        return None
    return next((n for m in PROMPT_SKILL_RE.finditer(prompt) for n in m.groups() if skill_named(n)), None)


def _path(sid: str) -> Optional[Path]:
    return state_dir() / f"{sid}.json" if isinstance(sid, str) and SID_RE.fullmatch(sid) else None


def _load(sid: str) -> Optional[dict]:
    p = _path(sid)
    try:
        data = json.loads(p.read_text(encoding="utf-8")) if p else None
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) and isinstance(data.get("stage"), str) else None


def _save(sid: str, data: dict) -> None:
    hc.atomic_write(_path(sid), json.dumps(data, ensure_ascii=False, indent=1) + "\n")


def hub_record(stage: str) -> Optional[dict]:
    """The stage's `hub` record; {} when there is none, None when the registry cannot be read (unknown, not "gone")."""
    try:
        return hc.roles_load(stage)["roles"].get("hub") or {}
    except Exception:  # noqa: BLE001
        return None


def hub_sessions(stage: str) -> Optional[list]:
    """Every id of the stage's registered hub (CLI uuid first, then a Desktop local_… id); None: registry unreadable."""
    rec = hub_record(stage)
    if rec is None:
        return None
    return [s for s in (rec.get("cli_session_id"), rec.get("session")) if isinstance(s, str) and s]


def canonical(stage: str, sid: str) -> str:
    """The one id a hub's mark is kept under, whichever alias names it: the CLI session id, which the hooks see."""
    ids = hub_sessions(stage) or []
    return ids[0] if sid in ids else sid


def _journal(stage: str, text: str) -> None:
    try:
        hc.journal_append(stage, SERVICE_TAG, text)
    except Exception:  # noqa: BLE001 — the journal line is a courtesy
        pass


def start(stage: str, sid: str, source: str, topic: str = "") -> dict:
    """Mark the grilling of `sid`, the hub of `stage`; a second start keeps the first one's time and refreshes it."""
    sid = canonical(stage, sid)
    if _path(sid) is None:
        raise hc.UsageError(f"bad session id {sid!r}")
    old = _load(sid)
    t = time.time()
    if old and old.get("stage") == stage:
        old["touched"] = t
        if topic:
            old["topic"] = topic
        _save(sid, old)
        return old
    data = {"stage": stage, "session": sid, "since": hc.now().isoformat(timespec="seconds"), "since_ts": t,
            "touched": t, "source": source}
    if topic:
        data["topic"] = topic
    _save(sid, data)
    _journal(stage, f"grilling in progress ({source}{': ' + topic if topic else ''}): automatic handoffs of hub "
                    f"session {sid[:8]} wait until `hub grilling end`")
    return data


def touch(sid: str) -> None:
    """The owner spoke in `sid`: an existing marker is fresh again."""
    data = _load(sid) if sid else None
    if data and active(sid):  # a mark past its bound lapses first; the prompt after a long pause does not revive it
        data["touched"] = time.time()
        _save(sid, data)


def mark_owner_asked(stage: str) -> None:
    """`hub succeed --owner-asked` ran: the successor's automatic takeover may go ahead mid-grilling."""
    for sid in hub_sessions(stage) or []:
        data = _load(sid)
        if data:
            data["owner_asked"] = hc.now().isoformat(timespec="seconds")
            _save(sid, data)


def mark_ceiling(sid: str, tokens: int) -> None:
    data = _load(sid)
    if data and not data.get("ceiling"):
        data["ceiling"] = hc.now().isoformat(timespec="seconds")
        _save(sid, data)
        _journal(data["stage"], f"grilling: the context ceiling is reached ({tokens // 1000}k tokens) — hub session "
                                f"{sid[:8]} writes a handoff that carries the grilling and asks the owner whether to hand over")


def end(sid: str, why: str = "") -> Optional[dict]:
    data = _load(sid)
    if data is None:
        return None
    try:
        _path(sid).unlink()
    except FileNotFoundError:
        pass
    except OSError as e:
        raise hc.Failure(f"cannot remove the grilling mark {_path(sid)}: {e} — it still holds") from None
    _journal(data["stage"], f"grilling ended{': ' + why if why else ''} — hub session {sid[:8]} may hand over again")
    return data


def active(sid: str) -> Optional[dict]:
    """The marker of `sid` while it holds: the session is still the registered hub of the marker's stage and the
    owner spoke within the staleness bound. A marker that no longer holds is removed (a lapse is journaled)."""
    data = _load(sid) if sid else None
    if data is None:
        return None
    idle = time.time() - float(data.get("touched") or 0)
    if idle >= stale_seconds():  # first: whatever the registry says, a mark past its bound lapses
        try:
            _path(sid).unlink()
        except OSError:
            pass
        _journal(data["stage"], f"grilling marker of hub session {sid[:8]} lapsed: the owner has not spoken for "
                                f"{int(idle // 60)} min (AGENT_HUB_GRILLING_STALE_MIN) — automatic handoffs resume")
        return None
    ids = hub_sessions(data["stage"])
    if ids is None:  # the registry cannot be read now: unknown is not a takeover, the mark keeps holding
        return data
    if sid not in ids:
        try:
            _path(sid).unlink()
        except OSError:
            pass
        return None
    return data


def active_stage(stage: str) -> Optional[dict]:
    """The holding marker of the stage's registered hub, if any."""
    return next((m for m in map(active, hub_sessions(stage) or []) if m), None)


def refusal(command: str, stage: str, data: dict) -> str:
    hub = shell_tool("hub")
    return (f"hub {command}: a grilling with the owner is in progress in the hub of stage {stage} (since "
            f"{str(data.get('since'))[11:16] or '?'}, {data.get('source')}): no automatic handoff until it ends — the "
            f"owner finishes the conversation with this session. When the topic's frontier is empty or the owner stops "
            f"the grilling, run `{hub} grilling end --stage {stage}`, then hand over. If the owner asked for this "
            f"handoff now, pass --owner-asked: the handoff then carries the grilling (§ 0) and the successor resumes it"
            + (" (the context ceiling is reached: write the handoff and ask the owner)." if data.get("ceiling") else "."))


def ceiling_note(stage: str) -> str:
    """At the ceiling mid-grilling: prepare the handoff, carrying the grilling, and leave the move to the owner."""
    return (f"The grilling still holds the handoff back: do not hand over by yourself. Stop at the end of this round "
            f"and write the handoff now (`{shell_tool('hub')} handoff --stage {stage}` passes at the ceiling) and carry "
            f"the grilling in its § 0: the topic, the questions asked with the owner's answers (their `ask` ids), the "
            f"open frontier and the next round — a successor loads the grilling skill, runs `hub grilling start` and "
            f"resumes from there. Then tell the owner in one line that the context is at its ceiling, the handoff is "
            f"ready and the grilling would go on in a new session, and ask whether to hand over now. Only on their "
            f"yes: the handoff procedure, with --owner-asked added to `hub succeed`.")


def shell_tool(name: str) -> str:
    """A plugin tool by the absolute path of this bin/ (as autopilot.tool): no same-named command on PATH answers."""
    return shlex.quote(str(hc.BIN / name))
