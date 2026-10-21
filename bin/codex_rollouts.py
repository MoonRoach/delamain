"""Read-only discovery and normalization of Codex's local rollout JSONL files.

The persisted format is distinct from ``codex exec --json``. Unknown records are
ignored. No process registry or liveness is inferred from file activity. Forked rollouts can
include the parent's history: only tasks started after the child was created
belong to the child.
"""
from __future__ import annotations

import datetime as dt
import json
import math
import os
import re
import time
from pathlib import Path

import topcache

TTL = 30.0
HEADER_MAX = 256_000
META_VALUE_MAX = 4000             # a meta value larger than this (base_instructions) is not kept in the disk cache


def epoch(raw):
    try:
        return dt.datetime.fromisoformat(raw.replace("Z", "+00:00")).timestamp() if isinstance(raw, str) else None
    except ValueError:
        return None


def spawn_source(meta):
    source = meta.get("source")
    sub = source.get("subagent") if isinstance(source, dict) else None
    if not isinstance(sub, dict):
        return None
    spawn = sub.get("thread_spawn") or sub.get("spawn")
    return spawn if isinstance(spawn, dict) else None


def home():
    return Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex")


def latest_turn_context(path):
    """Latest complete context, scanning backwards with bounded memory.

    Tool output may put the context arbitrarily far from EOF. Read fixed chunks,
    skip oversized non-metadata lines and torn final writes, never load a log tail
    (or an unbounded JSON record) into memory.
    """
    with Path(path).open("rb") as f:
        f.seek(0, os.SEEK_END)
        pos = f.tell()
        if not pos:
            return None
        f.seek(pos - 1)
        torn = f.read(1) != b"\n"
        pending = None if torn else b""
        while pos:
            size = min(pos, 64 << 10)
            pos -= size
            f.seek(pos)
            parts = f.read(size).split(b"\n")
            right = parts[-1]
            parts[-1] = (right + pending if pending is not None and len(right) + len(pending) <= HEADER_MAX else None)
            if len(parts) > 1:
                if parts[-1] is None and not torn and re.match(
                        rb'^\s*\{\s*(?:"timestamp"\s*:\s*"[^"]*"\s*,\s*)?"type"\s*:\s*"turn_context"', right):
                    return {}  # latest metadata exceeds the bound: unknown, never inherit an older context
                torn = False
            for raw in reversed(parts[1:]):
                if raw is None or len(raw) > HEADER_MAX or b'"turn_context"' not in raw:
                    continue
                try:
                    ev = json.loads(raw)
                except ValueError:
                    if re.match(rb'^\s*\{\s*(?:"timestamp"\s*:\s*"[^"]*"\s*,\s*)?"type"\s*:\s*"turn_context"', raw):
                        return {}  # complete but malformed current metadata is not an older turn
                    continue
                if isinstance(ev, dict) and ev.get("type") == "turn_context":
                    return ev["payload"] if isinstance(ev.get("payload"), dict) else {}
            pending = parts[0] if len(parts[0] or b"") <= HEADER_MAX else None
        if pending and b'"turn_context"' in pending:
            try:
                ev = json.loads(pending)
                if isinstance(ev, dict) and ev.get("type") == "turn_context" and isinstance(ev.get("payload"), dict):
                    return ev["payload"]
            except ValueError:
                pass
    return None


class Index:
    """Cache metadata-only discovery, reading at most one bounded header per file. With a `store` (agent-top's disk
    cache) a header already read by an earlier process is not read again: a rollout only grows, so it is kept by path
    while the inode is the same and the file is not shorter; the meta's large values (base instructions) are not kept."""

    def __init__(self):
        self.checked, self.records = None, {}
        self.store = None
        self.kids = None

    def update(self):
        now = time.monotonic()
        if self.checked is not None and now - self.checked < TTL:
            return self
        root = home() / "sessions"
        heads = (self.store.get("rollout-heads", str(root)) if self.store else None) or {}
        fresh, changed = {}, False
        records = {}
        for path in sorted(root.glob("**/rollout-*.jsonl")):
            try:
                st = path.stat()
                hit = heads.get(str(path))
                # a header read before holds while the file is the same one, not shorter, and its first line's ends
                # are the bytes read (topcache.anchor: two 256-byte reads, not the line); "no header" holds only while
                # the file is untouched (a first line fixed or rewritten in place is read again)
                if hit and len(hit) == 5 and hit[0] == st.st_ino and (
                        st.st_size >= hit[1] and topcache.anchor(path, hit[4][0]) == hit[4][1] if hit[3] is not None
                        else st.st_mtime_ns == hit[2]):
                    head, mark = hit[3], hit[4]
                else:
                    got, changed = self._head(path), True
                    if got is False:
                        continue  # a first line still being written: read it again next time
                    head, mark = (None, None) if got is None else (got[:2], [got[2], topcache.anchor(path, got[2])])
                fresh[str(path)] = [st.st_ino, st.st_size, st.st_mtime_ns, head, mark]
                if head is None:
                    continue
                # A resumed session may have more than one file. Use its newest
                # file instead of showing duplicate sessions or duplicate children.
                sid, meta, mtime = head[0], head[1], st.st_mtime
                if sid not in records or mtime > records[sid][2]:
                    records[sid] = (path, meta, mtime)
            except OSError:
                continue
        if self.store and (changed or len(fresh) != len(heads)):
            self.store.put("rollout-heads", str(root), fresh)
        self.checked, self.records = now, records
        return self

    def _head(self, path):
        """[session id, meta, length of the line] of a rollout's session_meta line; None when it has none; False when
        the line is not complete yet."""
        try:
            with path.open("rb") as f:
                raw = f.readline(HEADER_MAX + 1)
        except OSError:
            return False
        if len(raw) > HEADER_MAX:
            return None
        if not raw.endswith(b"\n"):
            return False
        try:
            ev = json.loads(raw)
            meta = ev.get("payload")
            if ev.get("type") != "session_meta" or not isinstance(meta, dict) or not meta.get("id"):
                return None
        except (ValueError, AttributeError):
            return None
        if self.store:
            meta = {k: v for k, v in meta.items() if len(json.dumps(v, default=str)) <= META_VALUE_MAX}
        return [str(meta["id"]), meta, len(raw)]

    def session(self, sid):
        return self.update().records.get(sid)

    def children(self, sid):
        self.update()
        if self.kids is None or self.kids[0] is not self.records:
            kids = {}
            for aid, rec in self.records.items():
                parent = (spawn_source(rec[1]) or {}).get("parent_thread_id")
                if parent:
                    kids.setdefault(parent, []).append((aid, *rec))
            self.kids = (self.records, kids)   # by parent, built once per discovery (a hundred sessions ask)
        return list(self.kids[1].get(sid, ()))


class Normalizer:
    """Stateful persisted-event adapter, including fork-history filtering."""

    def __init__(self):
        self.sid = None
        self.birth = None
        self.own_task = True
        self.turn = None
        self.last_event_ts = None

    def observe(self, timestamp):
        at = epoch(timestamp)
        if at is not None and (self.last_event_ts is None or at > self.last_event_ts):
            self.last_event_ts = at

    def events(self, ev):
        typ, payload = ev.get("type"), ev.get("payload")
        if not isinstance(payload, dict):
            return []
        ts = ev.get("timestamp")

        def record(kind, **fields):
            return {"type": kind, "timestamp": ts, "_engine": "codex", **fields}

        if typ == "session_meta":
            if self.sid is not None:
                return []  # inherited metadata must not reset the child's identity
            # Native serialization can write the envelope in the next second.
            # Older formats omit payload.timestamp; an explicitly invalid birth
            # must stay unknown rather than fall back to the envelope.
            birth = payload.get("timestamp", ts)
            self.sid, self.birth = payload.get("id"), epoch(birth)
            self.observe(birth)
            self.own_task = not bool(spawn_source(payload))
            return [record("system", subtype="init", session_id=self.sid)]
        if typ == "event_msg" and payload.get("type") == "task_started":
            started = payload.get("started_at")
            if not self.own_task:
                if (isinstance(started, bool) or not isinstance(started, (int, float)) or
                        not math.isfinite(started) or self.birth is None or started < int(self.birth)):
                    return []
                self.own_task = True
            self.turn = payload.get("turn_id")
            self.observe(ts)
            return [record("codex_turn_start", turn_id=self.turn)]
        if not self.own_task:
            return []
        if (typ == "event_msg" and payload.get("type") in
                ("task_complete", "turn_aborted", "task_failed", "turn_failed") and
                payload.get("turn_id") and self.turn and payload["turn_id"] != self.turn):
            return []  # a late terminal record is not activity of the current turn
        self.observe(ts)
        if typ == "turn_context":
            return [record("codex_context", model=payload.get("model"), effort=payload.get("effort"))]
        if typ == "event_msg":
            ptype = payload.get("type")
            if ptype == "token_count":
                info = payload.get("info")
                if not isinstance(info, dict):
                    return []
                last = info.get("last_token_usage")
                last = last if isinstance(last, dict) else {}
                return [record("codex_usage", codex_usage=info.get("total_token_usage"),
                               context_tokens=last.get("input_tokens"), context_window=info.get("model_context_window"),
                               codex_usage_scope="session", codex_rate_limits=payload.get("rate_limits"))]
            if ptype in ("task_complete", "turn_aborted", "task_failed", "turn_failed"):
                failed = ptype in ("task_failed", "turn_failed")
                subtype = "interrupted" if ptype == "turn_aborted" else "error" if failed else "success"
                return [record("result", subtype=subtype, is_error=failed,
                               result=payload.get("last_agent_message") or payload.get("message") or payload.get("reason") or "")]
            return []  # item_completed duplicates the response_item stream
        if typ != "response_item":
            return []
        ptype = payload.get("type")
        if ptype == "message" and payload.get("role") in ("assistant", "user"):
            content = [{"type": "text", "text": b.get("text") or ""} for b in payload.get("content") or []
                       if isinstance(b, dict) and b.get("type") in ("input_text", "output_text")]
            return [record(payload["role"], _count_turn=False, message={"content": content})]
        if ptype == "reasoning":
            # Encrypted reasoning is never displayed or reconstructed.
            content = [{"type": "thinking", "thinking": b.get("text") or ""}
                       for b in payload.get("summary") or [] if isinstance(b, dict) and b.get("text")]
            return [record("assistant", _count_turn=False, message={"content": content})] if content else []
        if ptype in ("function_call", "custom_tool_call"):
            inp = payload.get("arguments") if ptype == "function_call" else payload.get("input")
            if isinstance(inp, str) and ptype == "function_call":
                try:
                    inp = json.loads(inp)
                except ValueError:
                    pass
            if not isinstance(inp, dict):
                inp = {"input": inp}
            block = {"type": "tool_use", "id": payload.get("call_id"), "name": payload.get("name"), "input": inp}
            return [record("assistant", _count_turn=False, message={"content": [block]})]
        if ptype in ("function_call_output", "custom_tool_call_output"):
            block = {"type": "tool_result", "tool_use_id": payload.get("call_id"), "content": payload.get("output")}
            return [record("user", message={"content": [block]})]
        return []


INDEX = Index()


class State:
    """Incremental completion evidence for Finder, independent of the UI reader."""

    def __init__(self, path):
        self.path = path
        self.ino, self.offset = None, 0
        self.normalizer = Normalizer()
        self.status = None
        self.model = self.effort = None
        self.last_event_ts = None

    def update(self):
        try:
            st = self.path.stat()
            if self.ino != st.st_ino or st.st_size < self.offset:
                self.ino, self.offset = st.st_ino, 0
                self.normalizer = Normalizer()
                self.status = self.model = self.effort = None
                self.last_event_ts = None
            with self.path.open("rb") as f:
                f.seek(self.offset)
                while True:
                    raw = f.readline()
                    if not raw or not raw.endswith(b"\n"):
                        break
                    self.offset += len(raw)
                    try:
                        ev = json.loads(raw)
                    except ValueError:
                        continue
                    if not isinstance(ev, dict):
                        continue
                    for norm in self.normalizer.events(ev):
                        if norm["type"] == "codex_turn_start":
                            self.status = None
                        elif norm["type"] == "result":
                            self.status = ("stopped" if norm.get("subtype") == "interrupted" else
                                           "failed" if norm.get("is_error") else "completed")
                        elif norm["type"] == "codex_context":
                            self.model, self.effort = norm.get("model"), norm.get("effort")
                    self.last_event_ts = self.normalizer.last_event_ts
        except OSError:
            pass
        return self
