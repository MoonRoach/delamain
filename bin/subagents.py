"""Sub-agents (the Agent tool) of Claude Code sessions: where their transcripts are, whether their parent session
runs, how each one ended. Shared by `agent-top` (the console lists them) and `hub handoff` (refuses to hand over
while one still runs). Read-only: nothing here writes a file. Python 3.10+ stdlib only.

A sub-agent is found in its parent session's transcript folder (<claude config>/projects/*/<session>/subagents/).
It is done / error / dead from the parent's completion notice (a foreground one: the result of its Agent call);
without one it is live while the parent session runs (<claude config>/sessions/<pid>.json with a live claude pid)
and dead once it is gone — where that folder does not exist, dead after 30 min of silence.
"""
from __future__ import annotations

import datetime as dt
import json
import os
import re
import subprocess
import time
from pathlib import Path

import codex_rollouts
import topcache

UUID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
TOOL_ID_RE = re.compile(rb'"tool_use_id"\s*:\s*"([^"]+)"')
NOTICE_RE = re.compile(rb"<task-id>([\w-]+)</task-id>.*?<status>(\w+)</status>", re.S)
SUB_RECENT_S = 3600               # finished sub-agents older than this are hidden unless asked for
CODEX_UNKNOWN_TTL_S = 3600        # expire unknown observation, never infer death; known-live actors do not expire
SUB_LOST_S = 1800                 # no notice, silent this long, parent's liveness unknown: count it as died
SUB_DIRS_TTL = 30.0               # how long a session's sub-agent folders are cached before the next glob
SUB_STATE = {"completed": "done", "failed": "error"}   # any other notice status (killed, stopped) is "dead"
TAIL_BYTES = 1_000_000            # how much of a transcript's end tail_last_user_ts reads
_CTRL_RE = re.compile(r"[\x00-\x08\x0b-\x1f\x7f]")


# ---------------------------------------------------------------- small readers

def parse_ts(raw):
    if not isinstance(raw, str):
        return None
    try:
        return dt.datetime.fromisoformat(raw.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def loads(line: bytes):
    try:
        ev = json.loads(line)
    except ValueError:
        return None
    return ev if isinstance(ev, dict) else None


def line_ts(line: bytes):
    """Epoch of a transcript line's own top-level "timestamp", or None (a tool result may nest its own)."""
    ev = loads(line)
    return parse_ts(ev.get("timestamp")) if ev else None


def read_json(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def tail_last_user_ts(path: Path):
    """Epoch of the newest user line (a prompt or a tool result) in the last TAIL_BYTES of a sub-agent's transcript,
    or None. The default answer to "was it written to after it ended" where nothing reads the log incrementally."""
    try:
        with open(path, "rb") as fh:
            size = os.fstat(fh.fileno()).st_size
            start = max(0, size - TAIL_BYTES)
            fh.seek(start)
            if start:
                fh.readline()                 # a partial line
            best = None
            for line in fh:
                if not line.endswith(b"\n") or not line.startswith(b'{"parentUuid"') or b'"user"' not in line:
                    continue
                ev = loads(line)
                ts = parse_ts(ev.get("timestamp")) if ev and ev.get("type") == "user" else None
                if ts is not None and (best is None or ts > best):
                    best = ts
            return best
    except OSError:
        return None


# ---------------------------------------------------------------- processes and sessions

def process_table():
    """{pid: command line} of every process, or None when `ps` is unusable."""
    return process_table_finish(process_table_start())


def process_table_start():
    """Starts `ps` and returns at once, so a caller can read files while it runs (process_table_finish)."""
    try:
        return subprocess.Popen(["ps", "-ww", "-axo", "pid=,command="], stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, text=True)
    except OSError:
        return None


def process_table_finish(proc):
    """The table of a `ps` started by process_table_start, or None when it failed or took over 10 s."""
    if proc is None:
        return None
    try:
        out, _ = proc.communicate(timeout=10)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.communicate()
        return None
    if proc.returncode != 0:
        return None
    table = {}
    for ln in out.splitlines():
        parts = ln.strip().split(None, 1)
        if len(parts) == 2 and parts[0].isdigit():
            table[int(parts[0])] = parts[1]
    return table or None


def is_alive(meta: dict, table) -> bool:
    pid, sid = meta.get("pid"), meta.get("process_token") or meta.get("session_id") or ""
    if not isinstance(pid, int) or not pid:
        return False
    if table is None:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            pass
        return True
    return bool(sid) and sid in table.get(pid, "")   # a reused pid runs another command line


def live_sessions(table):
    """{session id: pid} of running Claude Code processes, from <claude config>/sessions/<pid>.json (the CLI writes
    one per process and removes it on exit); None when that folder does not exist (liveness unknown)."""
    d = Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude") / "sessions"
    if not d.is_dir():
        return None
    out = {}
    for f in d.glob("*.json"):
        rec = read_json(f)
        if not isinstance(rec, dict) or not isinstance(rec.get("pid"), int) or not rec.get("sessionId"):
            continue
        pid = rec["pid"]
        if table is not None:
            # the file is named by pid, so a new CLI on a reused pid overwrites it; a reuse by anything else is
            # caught here (an interactive session's command line holds no session id, only the binary)
            if "claude" not in table.get(pid, ""):
                continue
        else:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                continue
            except PermissionError:
                pass
        out[str(rec["sessionId"])] = pid
    return out


def projects_root() -> Path:
    """Where Claude Code keeps session transcripts: $CLAUDE_CONFIG_DIR/projects, else ~/.claude/projects."""
    return Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude") / "projects"


def parent_alive(rec: dict, sid: str, table, live):
    """Whether a session runs: True / False, or None when there is no session registry to ask (the caller then
    falls back to the silence rule). `rec` is the session's role record: a headless agent is judged by its pid."""
    pid = rec.get("pid")
    if rec.get("kind") == "headless" and isinstance(pid, int) and is_alive({**rec, "session_id": sid}, table):
        return True
    if rec.get("engine") == "codex" or codex_rollouts.INDEX.session(sid):
        # Native Codex has no Claude-style per-pid session registry. An unrelated
        # Claude registry must not turn an unknown Codex parent into a dead one.
        if sid == os.environ.get("CODEX_THREAD_ID"):
            return True  # the invoking native session is confirmed current, even when quiet
        if isinstance(pid, int):
            return is_alive({**rec, "session_id": sid}, table)
        return None
    if live is not None:
        return sid in live
    return None


# ---------------------------------------------------------------- completion notices

class Notices:
    """How the sub-agents of one parent session ended, read incrementally from the parent's transcript.
    by_id: {agent id: (status, epoch)} from <task-notification> blocks — the last one wins (a resumed sub-agent
    notifies again); only notices the CLI queued count (a queue-operation, a queued_command attachment or a user
    message that is the notice itself), not text that quotes one. results: {tool_use_id: (is_error, epoch)} of every
    tool result — a foreground sub-agent gets no notice, its Agent call just returns. The whole file is read once
    (only lines holding a marker are parsed), then only what was appended."""

    def __init__(self, path: Path):
        self.path, self.ino, self.offset, self.by_id, self.results = path, None, 0, {}, {}

    def update(self) -> "Notices":
        try:
            st = os.stat(self.path)
        except OSError:
            return self
        if st.st_ino != self.ino or st.st_size < self.offset:
            self.ino, self.offset, self.by_id, self.results = st.st_ino, 0, {}, {}
        if st.st_size <= self.offset:
            return self
        try:
            with open(self.path, "rb") as fh:
                fh.seek(self.offset)
                while True:
                    line = fh.readline()
                    if not line or not line.endswith(b"\n"):
                        break
                    self.offset += len(line)
                    if b"<task-notification>" in line:
                        self._notice(line)
                    if b'"tool_result"' in line and TOOL_ID_RE.search(line):
                        self._results(line)
        except OSError:
            pass
        return self

    def _results(self, line: bytes) -> None:
        ev = loads(line)
        if not ev or ev.get("type") != "user":
            return
        at = parse_ts(ev.get("timestamp"))
        content = (ev.get("message") or {}).get("content")
        for b in content if isinstance(content, list) else []:
            if isinstance(b, dict) and b.get("type") == "tool_result" and b.get("tool_use_id"):
                self.results[str(b["tool_use_id"])] = (bool(b.get("is_error")), at)

    def _notice(self, line: bytes) -> None:
        ev = loads(line)
        if not ev:
            return
        typ = ev.get("type")
        if typ == "queue-operation" and ev.get("operation") == "enqueue":
            text = ev.get("content")
        elif typ == "attachment" and isinstance(ev.get("attachment"), dict) and ev["attachment"].get("type") == "queued_command":
            text = ev["attachment"].get("prompt")
        elif typ == "user":
            text = (ev.get("message") or {}).get("content")
        else:
            return
        if not isinstance(text, str) or not text.lstrip().startswith("<task-notification>"):
            return
        at = parse_ts(ev.get("timestamp"))
        for m in NOTICE_RE.finditer(text.encode("utf-8", "replace")):
            self.by_id[m.group(1).decode("utf-8", "replace")] = (m.group(2).decode("ascii", "replace"), at)


# ---------------------------------------------------------------- the sub-agents of a session

class Sub:
    """One sub-agent on disk: live / done / error / dead / unknown / stopped."""
    __slots__ = ("aid", "log", "meta", "mtime", "status", "state", "background", "last_event_ts", "expired")

    def __init__(self, aid, log, meta, mtime, status, state, background, last_event_ts=None, expired=False):
        self.aid, self.log, self.meta, self.mtime = aid, log, meta, mtime
        self.status, self.state, self.background = status, state, background
        self.last_event_ts = last_event_ts
        self.expired = expired

    @property
    def alive(self) -> bool:
        return self.state == "live"

    @property
    def unresolved(self) -> bool:
        return self.state == "live" or self.state == "unknown" and not self.expired

    @property
    def description(self) -> str:
        return " ".join(_CTRL_RE.sub(" ", str(self.meta.get("description") or "")).split())

    def age(self, now: float):
        at = self.last_event_ts if self.meta.get("engine") == "codex" else self.mtime
        return None if at is None else max(0, now - at)


class Finder:
    """Finds the sub-agents of sessions and decides their state; caches the session folders, the metas and the parents'
    notices between calls. `last_user_ts(log path)` answers "was the transcript written to by a user line after the
    sub-agent ended" (a resumed sub-agent): agent-top passes its incremental log reader, the default reads the
    transcript's tail. `store` (agent-top's disk cache, bin/topcache.py) keeps the parents' notices and the Codex
    rollout readers between processes, so a new process reads only what those files gained."""

    def __init__(self, last_user_ts=None, store=None):
        self.last_user_ts = last_user_ts or tail_last_user_ts
        self.store = store or topcache.Null()
        self.notices, self.sub_dirs, self.metas = {}, {}, {}
        self.codex_states = {}
        self.session_dirs, self.session_dirs_at = {}, None

    def _reader(self, cache: dict, kind: str, path: Path, cls, nested=None):
        """The reader of `path` from this process's cache, else restored from the disk store, else a new one; then
        brought up to date, and stored again when it read anything."""
        obj = cache.get(path)
        if obj is None:
            obj = cache[path] = cls(path)
            topcache.load_into(obj, self.store.get(kind, str(path)), nested)
        before = (obj.ino, obj.offset)
        obj.update()
        if (obj.ino, obj.offset) != before:
            self.store.put(kind, str(path), obj)
        return obj

    def codex_session(self, sid, parent_is_alive, now, show_all=False):
        rec = codex_rollouts.INDEX.session(sid)
        return self._codex_sub(sid, *rec, parent_is_alive, now, show_all) if rec else None

    def _codex_sub(self, aid, log, meta, mtime, parent_is_alive, now, show_all):
        # Unknown observations have a bounded discovery/handoff lifetime. Expiry
        # is not evidence of death: show-all retains unknown with its actual clock.
        # Use filesystem freshness only for TTL when native event/birth time is absent.
        reader = self._reader(self.codex_states, "rollout-state", log, codex_rollouts.State,
                              {"normalizer": codex_rollouts.Normalizer})
        old = reader.last_event_ts is None or now - reader.last_event_ts > SUB_RECENT_S
        status = reader.status
        if status is not None:
            state = "stopped" if status == "stopped" else SUB_STATE.get(status, "dead")
        elif parent_is_alive is False:
            state = "dead"
        elif parent_is_alive is True:
            state = "live"
        else:
            state = "unknown"
        ttl_at = reader.last_event_ts if reader.last_event_ts is not None else mtime
        expired = state == "unknown" and ttl_at is not None and now - ttl_at > CODEX_UNKNOWN_TTL_S
        if not show_all and (expired or old and state not in ("live", "unknown")):
            return None
        spawn = codex_rollouts.spawn_source(meta) or {}
        info = {**meta, "engine": "codex", "model": reader.model, "effort": reader.effort,
                "description": spawn.get("agent_path") or spawn.get("agent_nickname") or "",
                "agentType": spawn.get("agent_role") or "codex sub-agent"}
        return Sub(aid, log, info, mtime, status, state, True, reader.last_event_ts, expired)

    def dirs(self, sid: str) -> list:
        """<claude config>/projects/*/<sid>/subagents folders of a session. One listing of every project folder
        answers all sessions (a glob per session stats every project folder again: seconds for a hundred sessions)."""
        hit = self.sub_dirs.get(sid)
        if hit and time.monotonic() - hit[0] < SUB_DIRS_TTL:
            return hit[1]
        if self.session_dirs_at is None or time.monotonic() - self.session_dirs_at >= SUB_DIRS_TTL:
            self.session_dirs, self.session_dirs_at = self._scan_projects(), time.monotonic()
        dirs = sorted(d / "subagents" for d in self.session_dirs.get(sid, ()) if (d / "subagents").is_dir())
        self.sub_dirs[sid] = (time.monotonic(), dirs)
        return dirs

    @staticmethod
    def _scan_projects() -> dict:
        """{session id: [<project>/<session id> folders]} of every project folder (what `*/<sid>` would match)."""
        out = {}
        try:
            projects = [e for e in os.scandir(projects_root()) if not e.name.startswith(".") and e.is_dir()]
        except OSError:
            return out
        for proj in projects:
            try:
                for e in os.scandir(proj.path):
                    if UUID_RE.fullmatch(e.name) and e.is_dir():
                        out.setdefault(e.name, []).append(Path(e.path))
            except OSError:
                continue
        return out

    def meta(self, path: Path) -> dict:
        try:
            key = (path, os.stat(path).st_mtime_ns)
        except OSError:
            return {}
        hit = self.metas.get(key)
        if hit is None:
            hit = read_json(path)
            hit = self.metas[key] = hit if isinstance(hit, dict) else {}
        return hit

    def of_session(self, sid: str, parent_is_alive, now: float, show_all: bool = False) -> list:
        """The sub-agents of one session (a full uuid). Finished or orphaned ones older than SUB_RECENT_S are left
        out unless `show_all`; those are not even read."""
        out = []
        for aid, log, meta, mtime in codex_rollouts.INDEX.children(sid):
            sub = self._codex_sub(aid, log, meta, mtime, parent_is_alive, now, show_all)
            if sub:
                out.append(sub)
        for sdir in self.dirs(sid):
            path = sdir.parent.parent / f"{sid}.jsonl"
            notes = []                          # the parent's notices, read once the first sub-agent needs them

            def get_notes(path=path, notes=notes):
                if not notes:
                    notes.append(self._reader(self.notices, "notices", path, Notices))
                return notes[0]

            for mp in sorted(sdir.glob("agent-*.meta.json")):
                sub = self._sub(mp, get_notes, parent_is_alive, now, show_all)
                if sub:
                    out.append(sub)
        return out

    def _sub(self, meta_path: Path, get_notes, parent_is_alive, now: float, show_all: bool):
        aid = meta_path.name[len("agent-"):-len(".meta.json")]
        log = meta_path.with_name(f"agent-{aid}.jsonl")
        try:
            mtime = log.stat().st_mtime
        except OSError:
            mtime = None
        old = mtime is None or now - mtime > SUB_RECENT_S
        if not show_all and old and parent_is_alive is not True:
            return None                       # finished or orphaned long ago: neither it nor its parent's notices are read
        notes = get_notes()
        meta = self.meta(meta_path)
        status, at = notes.by_id.get(aid, (None, None))
        # a foreground call ends with its tool result; with no known shape only a notice counts (a background
        # call's tool result is just "launched")
        if status is None and meta.get("requestShape") == "foreground" and meta.get("toolUseId") in notes.results:
            err, at = notes.results[meta["toolUseId"]]
            status = "failed" if err else "completed"
        if not show_all and old and status is not None:
            return None                       # finished long ago: not even its transcript is read
        # resumed (SendMessage) after it ended: its transcript got a new user line after the end; compared on the
        # CLI's own timestamps, not on file times
        last_user = self.last_user_ts(log) if status is not None and at is not None else None
        resumed = last_user is not None and last_user > at
        finished = status is not None and not resumed
        if finished:
            state = SUB_STATE.get(status, "dead")
        elif parent_is_alive is True:
            state = "live"
        elif parent_is_alive is False or mtime is None or now - mtime > SUB_LOST_S:
            state = "dead"
        else:
            state = "live"
        return Sub(aid, log, meta, mtime, status if finished else None, state, meta.get("requestShape") == "background")
