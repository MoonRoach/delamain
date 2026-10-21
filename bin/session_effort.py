"""The effort a Claude Code session runs at *now* (`hub effort`, the autopilot's successor).

A session's effort changes in the session (`/effort`, the Desktop picker, a control request) while the flag it was
started with stays in its argv, so the sources are read most-current first and every one is validated against
hc.EFFORTS. Each source was proved with a throw-away session at a known effort, and again after an in-session change
(CLI 2.1.289):

  hook        `effort.level` of a hook's input (PreToolUse and the like): the turn's effort; the caller passes it in.
  env         $CLAUDE_EFFORT of the Bash tool: the CLI sets it for every command from the turn's effort, whatever it
              inherited — except on a model without an effort setting (Haiku 4.5), where it is left as inherited (see
              effortless_model). Not in a `claude --bg` session, whose environment is the daemon's (it also has the
              daemon's stale $HUB_BIN and $CLAUDE_CODE_HOST_SESSION_ID): there the transcript and the job answer.
              Only in the session's own process tree: another session's cannot be read.
  transcript  `effort` of the last assistant record of the main thread in ~/.claude/projects/*/<session>.jsonl: the
              effort of the last turn; absent for a model without an effort setting (Haiku 4.5).
  job         `--effort` of `respawnFlags` in ~/.claude/jobs/<id>/state.json (a `claude --bg` session; its process
              argv carries none): the daemon rewrites it on /effort.
  desktop     `effort` of the Desktop session record whose `cliSessionId` is the session. Matches the CLI's argv and
              transcript for every live session checked; not proved to follow the picker (not tried: that is the
              owner's UI), hence below the transcript.
  argv        `--effort` of the session's CLI process: fixed at launch, stale after an in-session change, and absent
              when the session started on the default (a Desktop session, a `--bg` one). The last resort.

A session whose last turn ran on Haiku 4.5 has no effort: env, job, desktop and argv are then no answer, since they hold an
ancestor's leftover or what the session was started with. Haiku 5.5 is not such a model: its turn has the setting, so it
is read like any other (CLI 2.1.296, `claude -p --model claude-haiku-5-5 --effort low` with $CLAUDE_EFFORT=xhigh
inherited: the assistant record has `effort: low`, the hook input `effort.level: low`, the Bash tool $CLAUDE_EFFORT=low;
the same run on claude-haiku-4-5-20251001: no `effort` in the record, none in the hook input, $CLAUDE_EFFORT=xhigh).

Not sources: `effortLevel` / `modelSettings.<model>.effortLevel` in settings and $CLAUDE_CODE_EFFORT_LEVEL are the
defaults of *new* sessions (the running session already folded them in, and /effort rewrites them), and
$CLAUDE_JOB_DIR / $CLAUDE_CODE_HOST_SESSION_ID are inherited by every child of a session, so in an agent they name its
ancestor's job and Desktop session; the job and the record are found by the session id instead.
"""
from __future__ import annotations

import glob
import json
import os
import re
import subprocess
from pathlib import Path
from typing import NamedTuple, Optional

import hubcore as hc

ORDER = ("hook", "env", "transcript", "job", "desktop", "argv")
TAIL_BYTES = 4 << 20
CLAUDE_CMD_RE = re.compile(r"^(?:\S*/)?claude(?:\s|$)|/claude\.app/Contents/MacOS/claude(?:\s|$)")
EFFORT_FLAG_RE = re.compile(r"(?:^|\s)--effort(?:=|\s+)(\S+)")
SESSION_FLAGS = ("--session-id", "--resume", "-r")


class Reading(NamedTuple):
    source: str
    effort: Optional[str]
    note: str  # where it was read, or why this source has no answer


def claude_home() -> Path:
    return Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude")


def valid(raw) -> Optional[str]:
    raw = raw.strip() if isinstance(raw, str) else ""
    return raw if raw in hc.EFFORTS else None


def bad(raw, where: str) -> str:
    return f"{where}: {raw!r} is not one of {', '.join(hc.EFFORTS)}"


# ---------------------------------------------------------------- transcript

def find_transcript(sid: str) -> Optional[Path]:
    if not sid:
        return None
    hits = sorted(claude_home().glob(f"projects/*/{sid}.jsonl"), key=lambda p: p.stat().st_mtime)
    return hits[-1] if hits else None


def last_assistant(path) -> Optional[dict]:
    """The last real assistant record of the main thread: not a sidechain's, not an API error's (<synthetic>)."""
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            f.seek(max(0, f.tell() - TAIL_BYTES))
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
        if (isinstance(o, dict) and o.get("type") == "assistant" and o.get("isSidechain") is not True
                and (o.get("message") or {}).get("model") != "<synthetic>"):
            return o
    return None


def transcript_effort(path) -> tuple:
    """(effort, note): `effort` of the last assistant record. Only that record: an earlier one may belong to a model
    with an effort setting that the session has since left."""
    o = last_assistant(path)
    if o is None:
        return None, f"{path}: no assistant record yet"
    raw = o.get("effort")
    if raw is None:
        return None, f"{path}: the last assistant record has no effort (a model without an effort setting)"
    return (valid(raw), f"{path}, last assistant record") if valid(raw) else (None, bad(raw, str(path)))


def effortless_model(sid: str) -> Optional[str]:
    """The model of the session's last turn when it is a Haiku whose record carries no effort (Haiku 4.5, which has no
    effort setting), else None; a Haiku 5.5 turn records its effort, so it is not one. The CLI does not set
    $CLAUDE_EFFORT for such a turn (probed: a Haiku 4.5 session's Bash shows the value its ancestor had, or none), and
    a flag, a state.json or a record only holds what the session was started with, so none of them is its effort."""
    path = find_transcript(sid)
    o = last_assistant(path) if path else None
    model = str(((o or {}).get("message") or {}).get("model") or "")
    return model if "haiku" in model.lower() and o.get("effort") is None else None


# ---------------------------------------------------------------- job (claude --bg)

def job_record(sid: str) -> Optional[tuple]:
    """(path, state) of the `claude --bg` job whose session is `sid`: found by the id inside state.json, not by
    $CLAUDE_JOB_DIR, which every child of a session inherits."""
    for state in sorted(glob.glob(str(claude_home() / "jobs" / "*" / "state.json"))):
        try:
            d = json.loads(Path(state).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if isinstance(d, dict) and sid in (d.get("sessionId"), d.get("resumeSessionId")):
            return state, d
    return None


def job_effort(sid: str) -> tuple:
    hit = job_record(sid)
    if hit:
        state, d = hit
        flags = d.get("respawnFlags")
        flags = flags if isinstance(flags, list) else []
        raw = None
        for i, flag in enumerate(flags[:-1]):  # the last one: /effort appends its own
            if flag == "--effort":
                raw = flags[i + 1]
        if raw is None:
            return None, f"{state}: respawnFlags has no --effort"
        return (valid(raw), f"{state}, respawnFlags") if valid(raw) else (None, bad(raw, state))
    return None, f"no {claude_home()}/jobs/<id>/state.json for this session (not a `claude --bg` session)"


# ---------------------------------------------------------------- Desktop record

def desktop_record(sid: str) -> Optional[tuple]:
    """(path, record) of the Desktop session whose CLI session is `sid`."""
    base = hc.sessions_dir()
    own = os.environ.get("CLAUDE_CODE_HOST_SESSION_ID", "").strip()  # inherited by children: only a hint, checked below
    names = [f"{glob.escape(hc.normalize_local_id(own))}.json"] if own else []
    for pat in names + ["local_*.json"]:
        for path in glob.glob(str(base / "*" / "*" / pat)):
            try:
                d = json.loads(Path(path).read_text(encoding="utf-8"))
            except (OSError, ValueError):
                continue
            if isinstance(d, dict) and d.get("cliSessionId") == sid:
                return path, d
    return None


def desktop_effort(sid: str) -> tuple:
    hit = desktop_record(sid)
    if not hit:
        return None, f"no Desktop session record in {hc.sessions_dir()} for this session"
    path, d = hit
    raw = d.get("effort")
    if raw is None:
        return None, f"{path}: no effort in the record"
    return (valid(raw), path) if valid(raw) else (None, bad(raw, path))


# ---------------------------------------------------------------- process argv

def _ps(*argv) -> str:
    try:
        return subprocess.run(["ps", *argv], capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def _before_prompt(cmd: str) -> str:
    """The options of a command line, not the prompt after `-p`: a prompt may quote `--effort`."""
    return re.split(r"\s(?:-p|--print)(?:\s|$)", cmd, maxsplit=1)[0]


def _argv_reading(pid: str, cmd: str) -> tuple:
    m = EFFORT_FLAG_RE.search(_before_prompt(cmd))
    if not m:
        return None, f"pid {pid}: no --effort in the process argv (started on the default, or a background session)"
    return (valid(m.group(1)), f"pid {pid} argv") if valid(m.group(1)) else (None, bad(m.group(1), f"pid {pid} argv"))


def _names_session(cmd: str, sid: str) -> bool:
    """Whether the launch options of a command line (before the prompt: a prompt may quote any flag) carry this session id
    as a whole token: `--session-id B`, `--resume B`, `-r B` or the `=` forms."""
    opts = _before_prompt(cmd).split()
    return any((tok in SESSION_FLAGS and i + 1 < len(opts) and opts[i + 1] == sid)
               or tok in (f"{flag}={sid}" for flag in SESSION_FLAGS) for i, tok in enumerate(opts))


def argv_effort(sid: str, own: bool) -> tuple:
    if own:  # the nearest claude ancestor of this process
        pid = str(os.getppid())
        for _ in range(12):
            row = _ps("-o", "ppid=,command=", "-p", pid).strip()
            if not row:
                break
            ppid, _, cmd = row.partition(" ")
            cmd = cmd.strip()
            if CLAUDE_CMD_RE.search(cmd):
                return _argv_reading(pid, cmd)
            if not ppid.isdigit() or ppid in ("0", "1", pid):
                break
            pid = ppid
        return None, "no claude process among the ancestors of this one"
    for row in _ps("-axo", "pid=,command=").splitlines():
        pid, _, cmd = row.strip().partition(" ")
        if CLAUDE_CMD_RE.search(cmd.strip()) and _names_session(cmd, sid):
            return _argv_reading(pid, cmd.strip())
    return None, f"no claude process with --session-id/--resume {sid}"


# ---------------------------------------------------------------- the survey

def hook_level(data) -> Optional[str]:
    """`effort.level` of a hook's input, validated; None when the hook carries none."""
    eff = data.get("effort") if isinstance(data, dict) else None
    return valid(eff.get("level")) if isinstance(eff, dict) else None


def transcript_reading(sid: str) -> tuple:
    path = find_transcript(sid)
    return transcript_effort(path) if path else (None, f"no transcript of {sid} under {claude_home()}/projects")


def survey(session_id: Optional[str] = None, hook: Optional[str] = None, first_only: bool = False) -> list:
    """Every source's Reading, in ORDER (`first_only`: up to the first that answers — the file sources are not read for
    nothing). `session_id` None = the session running this command; otherwise a CLI session uuid or a Desktop `local_…`
    id. `hook` = `effort.level` of the hook input this runs for."""
    sid = (session_id or "").strip()
    if sid.startswith("local_"):  # a Desktop id names the record; the CLI session is in it
        sid = str((hc.desktop_session(sid) or {}).get("cliSessionId") or "")
        if not sid:
            raise hc.Failure(f"no Desktop session record for {session_id} in {hc.sessions_dir()}")
    here = hc.session_id()
    own = not sid or sid == here
    sid = sid or here
    codex = own and (os.environ.get("AGENT_HUB_ENGINE") == "codex" or bool(os.environ.get("CODEX_THREAD_ID")))
    hook = valid(hook)
    effortless = None if hook or not sid else effortless_model(sid)

    def hook_reading() -> tuple:
        return hook, "effort.level of the hook input" if hook else "no effort in the hook input"

    def env_reading() -> tuple:
        if not own:
            return None, "the environment of another session is not readable"
        if codex:
            return None, "this is a Codex session: a $CLAUDE_EFFORT here belongs to its launcher"
        if sid and job_record(sid):
            return None, "a `claude --bg` session: its environment is the daemon's, which may hold another $CLAUDE_EFFORT"
        raw = os.environ.get("CLAUDE_EFFORT", "").strip()
        return valid(raw), "$CLAUDE_EFFORT" if valid(raw) else bad(raw, "$CLAUDE_EFFORT") if raw else "$CLAUDE_EFFORT is not set"

    def by_session(fn):
        return lambda: fn(sid) if sid else (None, "no session id ($CLAUDE_CODE_SESSION_ID is not set)")

    def unless_effortless(read):
        return lambda: (None, f"the last turn ran on {effortless}, which recorded no effort (no effort setting): what is "
                              "here is not its effort") if effortless else read()

    readers = (("hook", hook_reading), ("env", unless_effortless(env_reading)),
               ("transcript", by_session(transcript_reading)),
               ("job", unless_effortless(by_session(job_effort))),
               ("desktop", unless_effortless(by_session(desktop_effort))),
               ("argv", unless_effortless(lambda: (None, "this is a Codex session") if codex
                                          else argv_effort(sid, own))))
    out = []
    for source, read in readers:
        out.append(Reading(source, *read()))
        if first_only and out[-1].effort:
            break
    return out


def best(readings: list) -> Optional[Reading]:
    """The answer: the first Reading, in ORDER (survey returns them so), that has an effort."""
    return next((r for r in readings if r.effort), None)


def tried(readings: list) -> str:
    return "; ".join(f"{r.source}: {r.note}" for r in readings)


def resolve(session_id: Optional[str] = None, hook: Optional[str] = None) -> Reading:
    """The Reading of the first source in ORDER that answers. Raises hc.Failure naming every source it tried when none
    does, so the caller never starts anything on a guess."""
    readings = survey(session_id, hook, first_only=True)
    found = best(readings)
    if found is None:
        raise hc.Failure(f"cannot determine the effort of {f'session {session_id}' if session_id else 'this session'}; "
                         f"tried {tried(readings)}")
    return found


def current_effort(session_id: Optional[str] = None, hook: Optional[str] = None) -> tuple:
    """(effort, source) of the session now; hc.Failure when no source answers (see resolve)."""
    r = resolve(session_id, hook)
    return r.effort, r.source


def describe(readings: list) -> str:
    """Human text: the answer, then the sources that disagree with it."""
    found = best(readings)
    if found is None:
        return f"effort undetermined; tried {tried(readings)}"
    lines = [f"{found.effort}  (source: {found.source} — {found.note})"]
    for r in readings:
        if r.effort and r.effort != found.effort:
            lag = " (the process argv is fixed at launch: it lags an in-session change)" if r.source == "argv" else ""
            lines.append(f"note: {r.source} says {r.effort}{lag}")
    return "\n".join(lines)
