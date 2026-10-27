"""Idle Claude Desktop sessions: `agent desktop-idle` (bin/agent) and the Desktop block of agent-top's summary.

A Desktop Code session keeps its `claude` process and the MCP servers it started (a few node processes each) alive for
as long as the session is not archived, and nobody archives them: a laptop ends with dozens of idle sessions that hold
gigabytes (issue #153). This module finds the idle ones that still hold processes, says what they hold, and sorts them
into archive candidates and sessions to leave alone. It only reads; nothing here stops a process or touches a session.

Sources:
- `<claude config>/sessions/<pid>.json`, one record per live CLI process: `hostSessionId` (the Desktop `local_…` id
  when Desktop runs the CLI), `status` (idle | busy | …), `statusUpdatedAt`, `startedAt`. A record whose pid is gone, or
  belongs to a process that started at another time, is stale and ignored.
- Desktop's own record of the session (hubcore.desktop_session): title, cwd, branch, lastActivityAt, isArchived.
- `ps`: resident memory of the CLI process and of everything below it. Command lines are never printed (an MCP server's
  carries its API key); only the executable's name is.

A session is a candidate when it has been idle for the limit or longer, is not the caller's own session, is not a role
registered in a hub home (a hub waiting for events looks idle too), and its working directory holds nothing that archiving
could lose: no changed or untracked file, no git operation under way, no commit on no remote ref, no open pull request
(`gh`; `glab` for a GitLab remote). What git or the forge cannot answer is "unknown" and keeps the session off the list.

Archiving is Desktop's: the `archive_session` tool of a Desktop-hosted session stops the session's process and, by default,
cleans up its worktree (the session stays in the Archived list). No command line or file does it; the procedure that
calls the tool after the owner's yes is in skills/status/SKILL.md.
"""
from __future__ import annotations

import concurrent.futures
import dataclasses
import datetime as dt
import json
import os
import re
import shutil
import subprocess
import time
from pathlib import Path
from typing import NamedTuple, Optional

import hubcore as hc
import session_effort
import worktrees

DEFAULT_IDLE = "12h"
PS_TIMEOUT_S = 10
FORGE_TIMEOUT_S = 30
WORKERS = 8
START_TOLERANCE_S = 120  # a pid record's startedAt is the CLI's own clock reading, a second or so after the process began
IDLE_STATUSES = {"idle"}
# the processes every session has: the CLI, and what runs MCP servers (a server often retitles itself `…-mcp`); any other
# child is named in the listing, because it dies with the session (a dev server the session started)
USUAL_PROCESSES = {"claude", "node", "npm", "npx", "sh", "bash", "zsh", "python", "python3", "uv", "uvx", "bun", "deno"}
# why a session is not a candidate: the order the reasons are shown in
REASON_ORDER = ("self", "role", "exempt", "shared", "gone", "not-git", "dirty", "operation", "unpushed", "pr", "unknown")


class Proc(NamedTuple):
    ppid: int
    rss_kb: int
    start: float  # epoch seconds
    name: str


PS_LINE = re.compile(r"\s*(\d+)\s+(\d+)\s+(\d+)\s+(\w{3}\s+\w{3}\s+\d+\s+\d\d:\d\d:\d\d\s+\d{4})\s+(.*)")


def proc_name(comm: str) -> str:
    """The executable's name from ps's `comm` column: the file name of a path, else the first word (a process may retitle
    itself with its arguments, API key included). Cut to a short, plain token."""
    comm = comm.strip()
    word = os.path.basename(comm) if comm.startswith("/") else os.path.basename((comm.split() or [""])[0])
    return re.sub(r"[^A-Za-z0-9._+@-]", "", word)[:32] or "?"


def process_table() -> Optional[dict]:
    """{pid: Proc} of every process, or None when `ps` is unusable."""
    try:
        res = subprocess.run(["ps", "-ww", "-axo", "pid=,ppid=,rss=,lstart=,comm="], capture_output=True, text=True,
                             timeout=PS_TIMEOUT_S, env=dict(os.environ, LC_ALL="C"), stdin=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError):
        return None
    if res.returncode != 0:
        return None
    table = {}
    for line in res.stdout.splitlines():
        m = PS_LINE.fullmatch(line)
        if not m:
            continue
        try:
            start = time.mktime(time.strptime(" ".join(m.group(4).split()), "%a %b %d %H:%M:%S %Y"))
        except (ValueError, OverflowError):
            start = 0.0
        table[int(m.group(1))] = Proc(int(m.group(2)), int(m.group(3)), start, proc_name(m.group(5)))
    return table or None


def descendants(table: dict, pid: int) -> list:
    """`pid` and every process below it."""
    kids: dict = {}
    for p, proc in table.items():
        kids.setdefault(proc.ppid, []).append(p)
    out, todo = [], [pid]
    while todo:
        p = todo.pop()
        if p in out:
            continue
        out.append(p)
        todo.extend(kids.get(p, []))
    return out


def cli_records() -> list:
    """The pid records of Claude Code processes that Desktop hosts (read-only)."""
    out = []
    for path in sorted((session_effort.claude_home() / "sessions").glob("*.json")):
        try:
            rec = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if isinstance(rec, dict) and isinstance(rec.get("pid"), int) and str(rec.get("hostSessionId") or "").startswith("local_"):
            out.append(rec)
    return out


def alive(rec: dict, table: dict) -> bool:
    """The record's pid runs, and is the process the record describes (a recycled pid started at another time)."""
    proc = table.get(rec["pid"])
    if proc is None:
        return False
    started = rec.get("startedAt")
    return not (isinstance(started, (int, float)) and proc.start and abs(proc.start - started / 1000) > START_TOLERANCE_S)


def registered_sessions(skip_stage: Optional[str] = None) -> dict:
    """{session id: "role of stage"} of every role registered in any known hub home: ids of a Desktop session and of its CLI.
    `skip_stage`: a stage being closed, whose roles protect nothing."""
    out: dict = {}
    try:
        homes = [Path(k.path) for k in hc.known_homes()]
    except (OSError, hc.Failure):
        homes = []
    for home in homes:
        for path in sorted(home.glob("*/roles.json")):
            try:
                roles = json.loads(path.read_text(encoding="utf-8")).get("roles")
            except (OSError, ValueError, AttributeError):
                continue
            for role, rec in ([] if path.parent.name == skip_stage else roles.items() if isinstance(roles, dict) else []):
                for key in ("session", "cli_session_id"):
                    sid = rec.get(key) if isinstance(rec, dict) else None
                    if isinstance(sid, str) and sid:
                        out.setdefault(sid, f"{role} of stage {path.parent.name}")
    return out


# ---------------------------------------------------------------- the working directory and the forge

def remote_host(url: str) -> str:
    """The host of a git remote URL (https://h/…, ssh://git@h:22/…, git@h:owner/repo.git)."""
    rest = re.sub(r"^[a-z+]+://", "", url.strip())
    rest = rest.rsplit("@", 1)[-1] if "@" in rest.split("/", 1)[0] else rest
    return re.split(r"[/:]", rest, maxsplit=1)[0].lower()


class Forge:
    """Pull / merge requests of a branch: `gh` for a github.com remote, `glab` for any other host. A missing tool answers
    "unknown" for every session that needs it."""

    def __init__(self, enabled: bool = True):
        self.enabled = enabled
        self.exe = {"gh": shutil.which("gh") if enabled else None, "glab": shutil.which("glab") if enabled else None}

    @staticmethod
    def remote(cwd: Path) -> Optional[str]:
        """The URL of origin, else of the first remote; None when there is none."""
        names = (worktrees._out(worktrees._git(cwd, "remote")) or "").split()
        if not names:
            return None
        return worktrees._out(worktrees._git(cwd, "remote", "get-url", "origin" if "origin" in names else names[0])) or None

    def _list(self, cwd: Path, branch: str, state: str) -> tuple:
        """(list of {number, url, headRefOid, baseRefName, mergedAt}, "") — `state` open or merged — or (None, why)."""
        url = self.remote(cwd)
        host = remote_host(url or "")
        tool = "gh" if host == "github.com" else "glab"
        if not self.enabled:
            return None, "pull requests not checked (--no-gh)"
        if not self.exe[tool]:
            return None, f"`{tool}` is not installed, so the requests of {host or 'this remote'} cannot be checked"
        if tool == "gh":
            argv = [self.exe[tool], "pr", "list", "--state", state, "--head", branch, "--limit", "20", "--json",
                    "number,url,headRefOid,baseRefName,mergedAt"]
        else:
            argv = [self.exe[tool], "mr", "list", "--source-branch", branch, "-F", "json"] + (["--merged"] if state == "merged" else [])
        env = dict(os.environ, GH_PROMPT_DISABLED="1", NO_PROMPT="1", NO_COLOR="1", GLAB_CHECK_UPDATE="false")
        env.pop("GIT_DIR", None)
        env.pop("GIT_WORK_TREE", None)
        try:
            res = subprocess.run(argv, cwd=cwd, capture_output=True, text=True, timeout=FORGE_TIMEOUT_S, env=env,
                                 stdin=subprocess.DEVNULL)
            if res.returncode != 0:
                first = (res.stderr.strip().splitlines() or [f"exit {res.returncode}"])[0]
                return None, f"`{tool}` failed on {host or 'this remote'}: {first[:140]}"
            data = json.loads(res.stdout or "[]")
        except subprocess.TimeoutExpired:
            return None, f"`{tool}` gave no answer in {FORGE_TIMEOUT_S} s"
        except (OSError, subprocess.SubprocessError, ValueError):
            return None, f"`{tool}` gave an unreadable answer"
        if not isinstance(data, list):
            return None, f"`{tool}` gave an unreadable answer"
        return [{"number": r.get("number", r.get("iid")), "url": r.get("url") or r.get("web_url") or "",
                 "headRefOid": r.get("headRefOid") or r.get("sha"), "baseRefName": r.get("baseRefName") or r.get("target_branch"),
                 "mergedAt": r.get("mergedAt") or r.get("merged_at")} for r in data if isinstance(r, dict)], ""

    def open_requests(self, cwd: Path, branch: Optional[str]) -> tuple:
        """([{number, url}], "") — the open requests of the branch — or (None, why) when they cannot be told."""
        if not self.remote(cwd) or not branch:
            return [], ""  # no remote, or a detached HEAD: nothing is open anywhere (unpushed commits are counted on their own)
        return self._list(cwd, branch, "open")

    def merged_requests(self, cwd: Path, branch: str) -> Optional[list]:
        """The merged requests of the branch (worktrees._apply_pr's shape), None when they cannot be told."""
        return self._list(cwd, branch, "merged")[0]


@dataclasses.dataclass
class DirState:
    """What archiving could lose in a session's working directory."""
    reasons: list  # [(code, text)]; empty: clean
    branch: Optional[str] = None
    dirty: Optional[int] = None
    unpushed: Optional[int] = None
    requests: Optional[list] = None  # open pull / merge requests; None: not told


def inspect_dir(cwd: str, forge: Forge) -> DirState:
    path = Path(cwd)
    if not cwd or not path.is_dir():
        return DirState([("gone", "its working directory is gone")])
    if worktrees._out(worktrees._git(path, "rev-parse", "--is-inside-work-tree")) != "true":
        return DirState([("not-git", "its working directory is not a git repository, so there is nothing to check")])
    head = worktrees._out(worktrees._git(path, "rev-parse", "HEAD")) or ""
    w = worktrees.Worktree(path=path, real=worktrees._real(path), head=head)
    worktrees._inspect(path, w, None)
    branch = worktrees._out(worktrees._git(path, "symbolic-ref", "--short", "-q", "HEAD")) or None
    if w.unpushed and branch and head:
        # a squash or rebase merge leaves the branch's commits on no remote ref: they are safe when HEAD is inside the head
        # commit of a request merged into the default branch (the same rule as `agent worktrees`)
        main = hc.main_tree(path)
        default_branch = hc.default_ref(main)[1] if main is not None else None
        prs = forge.merged_requests(path, branch) if default_branch else None
        if prs:
            worktrees._apply_pr(main, w, prs, default_branch)
    st = DirState([], branch=branch, dirty=w.dirty, unpushed=w.unpushed)
    if w.dirty is None:
        st.reasons.append(("unknown", "git status gave no answer"))
    elif w.dirty:
        st.reasons.append(("dirty", f"{w.dirty} changed file{'' if w.dirty == 1 else 's'}"))
    if w.operation:
        st.reasons.append(("operation", f"{w.operation} under way"))
    if w.unpushed is None:
        st.reasons.append(("unknown", "git could not count the commits on no remote"))
    elif w.unpushed:
        st.reasons.append(("unpushed", f"{w.unpushed} commit{'' if w.unpushed == 1 else 's'} on no remote"
                           + (f" ({w.merged_note})" if w.merged_note and "merged" in w.merged_note else "")))
    reqs, why = forge.open_requests(path, branch)
    st.requests = reqs
    if reqs is None:
        st.reasons.append(("unknown", why))
    elif reqs:
        st.reasons.append(("pr", "open PR/MR " + ", ".join(f"#{r['number']}" for r in reqs[:3])))
    return st


# ---------------------------------------------------------------- the report

@dataclasses.dataclass
class Session:
    id: str
    cli_id: str
    title: str
    cwd: str
    branch: Optional[str]
    pids: list
    idle_s: float
    rss_kb: int
    procs: int
    others: list  # names of the processes besides the usual ones: they end with the session
    exempt: bool = False
    reasons: list = dataclasses.field(default_factory=list)  # [(code, text)] why it is not a candidate; empty: candidate
    state: Optional[DirState] = None

    @property
    def candidate(self) -> bool:
        return not self.reasons


@dataclasses.dataclass
class Report:
    sessions: list  # idle for the limit or longer, with processes alive, longest idle first
    idle: dt.timedelta
    holding: int  # Desktop sessions with live processes (idle or not)
    holding_kb: int
    notes: list
    now: float

    @property
    def candidates(self) -> list:
        return [s for s in self.sessions if s.candidate]

    @property
    def kept(self) -> list:
        return [s for s in self.sessions if not s.candidate]


def collect(idle: dt.timedelta, use_forge: bool = True, now: Optional[float] = None, caller: Optional[str] = None,
            only: Optional[set] = None, skip_stage: Optional[str] = None) -> Report:
    """The idle Desktop sessions that hold processes. `caller`: the caller's own Desktop id (default
    $CLAUDE_CODE_HOST_SESSION_ID), which is never a candidate. `only`: just the sessions with these Desktop or CLI ids;
    `skip_stage`: the roles of this stage do not protect a session."""
    now = time.time() if now is None else now
    caller = caller if caller is not None else os.environ.get("CLAUDE_CODE_HOST_SESSION_ID", "")
    notes: list = []
    records = cli_records()
    if not records:  # no Desktop here (or no session running): no `ps`, no git
        return Report([], idle, 0, 0, notes, now)
    table = process_table()
    if table is None:
        return Report([], idle, 0, 0, ["`ps` gave no answer: nothing could be measured"], now)
    by_host: dict = {}
    for rec in records:
        if alive(rec, table):
            by_host.setdefault(rec["hostSessionId"], []).append(rec)
    roles = registered_sessions(skip_stage)
    forge = Forge(use_forge)
    sessions, holding, holding_kb = [], 0, 0
    users: dict = {}  # working directory -> [(Desktop id, title)] of every session with processes, idle or not
    for host, recs in by_host.items():
        meta = hc.desktop_session(host)
        if not isinstance(meta, dict) or meta.get("isArchived"):
            continue
        pids = sorted({p for r in recs for p in descendants(table, r["pid"])})
        rss = sum(table[p].rss_kb for p in pids)
        holding, holding_kb = holding + 1, holding_kb + rss
        title = str(meta.get("title") or "")
        users.setdefault(str(meta.get("cwd") or ""), []).append((host, title))
        if only is not None and not {host, str(meta.get("cliSessionId") or "")} & only:
            continue
        if not all(r.get("status") in IDLE_STATUSES for r in recs):
            continue
        marks = [meta.get("lastActivityAt")] + [r.get("statusUpdatedAt") or r.get("updatedAt") for r in recs]
        since = max((m for m in marks if isinstance(m, (int, float))), default=None)
        if since is None or now - since / 1000 < idle.total_seconds():
            continue
        sessions.append(Session(
            id=host, cli_id=str(meta.get("cliSessionId") or ""), title=title, cwd=str(meta.get("cwd") or ""),
            branch=meta.get("branch") if isinstance(meta.get("branch"), str) else None,
            pids=sorted(r["pid"] for r in recs), idle_s=now - since / 1000, rss_kb=rss, procs=len(pids),
            others=sorted({table[p].name for p in pids if table[p].name not in USUAL_PROCESSES and "mcp" not in table[p].name})[:5],
            exempt=bool(meta.get("autoArchiveExempt"))))
    for s in sessions:
        if s.id == caller:
            s.reasons.append(("self", "this is the session running the command"))
        who = roles.get(s.id) or roles.get(s.cli_id)
        if who:
            s.reasons.append(("role", f"registered as {who}"))
        if s.exempt:
            s.reasons.append(("exempt", "Desktop marks it exempt from auto-archiving"))
    # a directory some other session still uses stays: archiving cleans up the session's worktree
    listed = {s.id: s for s in sessions}
    for s in sessions:
        for oid, otitle in users.get(s.cwd, []):
            other = listed.get(oid)
            if oid != s.id and (other is None or other.reasons):
                s.reasons.append(("shared", "its directory is also used by " + (" ".join(otitle.split())[:40] or oid)
                                  + (" (active or idle for less than the limit)" if other is None else " (which stays)")))
                break
    # one working directory is checked once, however many sessions share it
    cwds = sorted({s.cwd for s in sessions})
    with concurrent.futures.ThreadPoolExecutor(max_workers=WORKERS) as pool:
        checked = dict(zip(cwds, pool.map(lambda c: inspect_dir(c, forge), cwds)))
    for s in sessions:
        st = checked[s.cwd]
        s.state = st
        s.reasons += st.reasons
        if st.branch and not s.branch:
            s.branch = st.branch
    for s in sessions:
        s.reasons.sort(key=lambda r: REASON_ORDER.index(r[0]))
    unknown = sorted({t for s in sessions for c, t in s.reasons if c == "unknown"})
    notes += [f"unknown: {t}" for t in unknown[:3]]
    sessions.sort(key=lambda s: -s.idle_s)
    return Report(sessions, idle, holding, holding_kb, notes, now)


# ---------------------------------------------------------------- output

def fmt_mem(kb: int) -> str:
    return f"{kb / 1048576:.1f} GB" if kb >= 1048576 else f"{kb / 1024:.0f} MB"


def fmt_idle(s: float) -> str:
    s = int(max(0, s))
    return f"{s // 86400} d" if s >= 2 * 86400 else (f"{s // 3600} h" if s >= 3600 else f"{s // 60} min")


def summary_line(rep: Report) -> str:
    """One line for a status view: how much the idle sessions hold and how many can be archived."""
    held = sum(s.rss_kb for s in rep.sessions)
    cand = rep.candidates
    return (f"{len(rep.sessions)} idle ≥ {fmt_idle(rep.idle.total_seconds())}, holding {fmt_mem(held)} "
            f"(all {rep.holding} Desktop sessions with processes: {fmt_mem(rep.holding_kb)}); "
            f"{len(cand)} to archive ({fmt_mem(sum(s.rss_kb for s in cand))}), {len(rep.kept)} to leave alone")


def _title(s: Session) -> str:
    t = " ".join(s.title.split()) or "(untitled)"
    return t if len(t) <= 48 else t[:47] + "…"


def render(rep: Report) -> str:
    if not rep.sessions:
        return (f"no Desktop session has been idle for {fmt_idle(rep.idle.total_seconds())} or more while holding processes "
                f"({rep.holding} Desktop session{'' if rep.holding == 1 else 's'} hold processes now, "
                f"{fmt_mem(rep.holding_kb)})\n" + "".join(f"note: {n}\n" for n in rep.notes))
    lines = ["Desktop sessions idle for " + fmt_idle(rep.idle.total_seconds()) + " or more, longest first — " + summary_line(rep), ""]
    cand = rep.candidates
    if cand:
        lines.append(f"Clean, to archive ({len(cand)}; archive_session id, after the owner's yes — skills/status/SKILL.md):")
        for s in cand:
            lines.append(f"  {s.id}  idle {fmt_idle(s.idle_s):>6}  {fmt_mem(s.rss_kb):>7} in {s.procs} procs  {_title(s)}"
                         + (f"  [{s.branch}]" if s.branch else "")
                         + (f"  ends with it: {', '.join(s.others)}" if s.others else ""))
    if rep.kept:
        lines += ["", f"Not touched ({len(rep.kept)}):"]
        for s in rep.kept:
            lines.append(f"  {s.id}  idle {fmt_idle(s.idle_s):>6}  {fmt_mem(s.rss_kb):>7} in {s.procs} procs  {_title(s)}"
                         + (f"  [{s.branch}]" if s.branch else ""))
            lines.append("      " + "; ".join(t for _, t in s.reasons))
    return "\n".join(lines + [""] + [f"note: {n}" for n in rep.notes]).rstrip() + "\n"


def as_dict(rep: Report) -> dict:
    def item(s: Session) -> dict:
        return {"id": s.id, "cli_session_id": s.cli_id, "title": s.title, "cwd": s.cwd, "branch": s.branch,
                "pids": s.pids, "idle_s": int(s.idle_s), "rss_kb": s.rss_kb, "procs": s.procs, "other_processes": s.others,
                "candidate": s.candidate, "reasons": [{"code": c, "text": t} for c, t in s.reasons],
                "dirty_files": s.state.dirty if s.state else None, "unpushed_commits": s.state.unpushed if s.state else None,
                "open_requests": s.state.requests if s.state else None}
    return {"idle_limit_s": int(rep.idle.total_seconds()), "holding": rep.holding, "holding_rss_kb": rep.holding_kb,
            "idle_rss_kb": sum(s.rss_kb for s in rep.sessions), "candidate_ids": [s.id for s in rep.candidates],
            "candidate_rss_kb": sum(s.rss_kb for s in rep.candidates), "sessions": [item(s) for s in rep.sessions],
            "notes": rep.notes, "summary": summary_line(rep)}


def stage_session_ids(data: dict) -> set:
    """Desktop and CLI session ids of every role of a stage, retired ones included (an earlier hub shift is a Desktop
    session that stays open after the takeover): `data` is hubcore.roles_load's."""
    recs = list((data.get("roles") or {}).values()) + list(data.get("retired") or [])
    return {sid for r in recs if isinstance(r, dict) for sid in (r.get("session"), r.get("cli_session_id"))
            if isinstance(sid, str) and sid}


def close_lines(stage: str, data: dict) -> list:
    """Lines for `hub close`: the stage's Desktop sessions that are idle and still hold processes — which are clean (to be
    archived with archive_session after the owner's yes) and which stay, with the reason. Empty when there are none."""
    ids = stage_session_ids(data)
    if not ids:
        return []
    rep = collect(dt.timedelta(0), only=ids, skip_stage=stage)
    shown = [s for s in rep.sessions if not any(c == "self" for c, _ in s.reasons)]
    if not shown:
        return []
    cand = [s for s in shown if s.candidate]
    lines = [f"Desktop sessions of stage {stage} that are idle and hold processes: {len(shown)}, "
             f"{fmt_mem(sum(s.rss_kb for s in shown))} ({len(cand)} clean)"]
    if cand:
        lines.append("  archive after the owner's yes, with archive_session from a Desktop session: "
                     + ", ".join(f"{s.id} ({_title(s)}, {fmt_mem(s.rss_kb)})" for s in cand))
    lines += [f"  left alone: {s.id} ({_title(s)}) — " + "; ".join(t for _, t in s.reasons) for s in shown if not s.candidate]
    return lines


def run(a) -> int:
    """`agent desktop-idle` (the argument parser is bin/agent's)."""
    if a.json and a.ids:
        raise hc.UsageError("--json and --ids are two outputs: pick one")
    rep = collect(hc.parse_duration(a.idle_for), use_forge=not a.no_gh)
    if a.json:
        print(json.dumps(as_dict(rep), ensure_ascii=False, indent=1))
    elif a.ids:
        for s in rep.candidates:
            print(s.id)
    else:
        print(render(rep), end="")
    return 0
