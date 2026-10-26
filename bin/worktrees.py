"""The ledger of a repository's git worktrees: `agent worktrees` (bin/agent).

Nothing in Delamain removes a worktree it made (agent spawn --worktree, hub start / takeover), and Desktop and people
make their own, so a long-lived repository ends with dozens of them and nobody knows which are finished. This module
lists every worktree of one repository with what decides whether it can go, and removes the finished ones.

Per worktree: who made it (an agent run's meta.json in any known hub home; a hub's `<stage>-hub-<n>` directory; a
registered role; else "other" — Desktop, manual), whether something uses it (a live agent, the stage's registered hub,
any process whose working directory is inside it — "unknown" when none of these says so and the worktree is not one
Delamain made), whether it is dirty (`git status`, untracked files count, ignored ones do not), whether its commits
are on a remote, whether its branch is merged (ancestor of the remote default branch, or HEAD is inside a merged
pull request found with `gh`), and how long since the last change (the last commit, reflog entry or edited file).

Prune removes a worktree only when every check passes: merged, clean, nothing unpushed, no git operation under way,
not locked, not the caller's directory, not in use — and, where use is "unknown", unchanged for longer than the idle
limit. `git worktree remove` without --force is the only removal. Work that is not on a remote is never removed.
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
from pathlib import Path
from typing import Callable, Optional

import hubcore as hc

GIT_TIMEOUT_S = 30
FETCH_TIMEOUT_S = 60
GH_TIMEOUT_S = 30
PROCESS_TIMEOUT_S = 30
WORKERS = 8
DEFAULT_IDLE = "24h"
# <stage>-hub-<n> (a taken name moves on to -2, -3…): the directory hub start / takeover / succeed give a hub's worktree
HUB_DIR_RE = re.compile(r"(?P<stage>[a-z0-9][a-z0-9_-]*)-hub-(?P<n>\d+)(?:-\d+)?")
# files in the git directory that say a git operation is under way (or running)
OPERATIONS = (("rebase-merge", "rebase"), ("rebase-apply", "rebase"), ("MERGE_HEAD", "merge"),
              ("CHERRY_PICK_HEAD", "cherry-pick"), ("REVERT_HEAD", "revert"), ("BISECT_LOG", "bisect"),
              ("index.lock", "a running git command"))
# the order a worktree's "kept" reasons are reported and tallied in: the first is the primary one
REASON_ORDER = ("main", "bare", "locked", "caller", "live", "dirty", "operation", "unpushed", "unmerged", "idle")


@dataclasses.dataclass
class Worktree:
    path: Path
    real: str
    head: str = ""
    branch: Optional[str] = None
    is_main: bool = False
    bare: bool = False
    locked: Optional[str] = None
    prunable: Optional[str] = None
    kind: str = "other"  # main | agent | hub | role | other
    who: str = "other"
    stage: Optional[str] = None
    role: Optional[str] = None
    hub_number: Optional[int] = None
    live: str = "unknown"  # yes | no | unknown
    live_by: list = dataclasses.field(default_factory=list)
    dirty: Optional[int] = None  # changed files (untracked included); None: git could not say
    operation: Optional[str] = None
    unpushed: Optional[int] = None  # commits on no remote ref, less those inside a merged pull request
    unpushed_raw: Optional[int] = None
    merged: Optional[bool] = None  # None: cannot be told
    merged_by: Optional[str] = None  # ancestry | pr
    merged_note: str = ""
    pr: Optional[dict] = None
    last_change: Optional[dt.datetime] = None
    caller: bool = False
    reasons: list = dataclasses.field(default_factory=list)  # [(code, text)] why prune keeps it; empty: removable
    gitdir: Optional[Path] = None

    @property
    def exists(self) -> bool:
        return self.prunable is None and self.path.is_dir()

    @property
    def removable(self) -> bool:
        return not self.reasons and not self.is_main and not self.bare and self.exists


@dataclasses.dataclass
class Ledger:
    main: Path
    default_ref: Optional[str]
    default_branch: Optional[str]
    items: list
    notes: list
    gh: str  # ok | off | missing | unavailable: <why>
    now: dt.datetime
    idle: dt.timedelta


def _real(path) -> str:
    try:
        return os.path.realpath(str(path))
    except (OSError, ValueError):
        return str(path)


def _git(cwd, *argv, timeout: int = GIT_TIMEOUT_S):
    """CompletedProcess of a bounded git call in `cwd` (no optional locks: listing must not rewrite an index), None
    when git cannot run or does not answer in time."""
    env = hc.git_env()
    env["LC_ALL"] = "C"
    env["GIT_TERMINAL_PROMPT"] = "0"
    try:
        return subprocess.run(["git", "--no-optional-locks", "-C", str(cwd), *argv], capture_output=True, text=True,
                              timeout=timeout, env=env, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError):
        return None


def _out(res) -> Optional[str]:
    return res.stdout.strip() if res is not None and res.returncode == 0 else None


def _first_line(res) -> str:
    if res is None:
        return "git did not answer"
    lines = (res.stderr.strip() or res.stdout.strip()).splitlines()
    return lines[0][:200] if lines else f"exit {res.returncode}"


# ---------------------------------------------------------------- the worktrees of a repository

def list_worktrees(main: Path) -> list:
    """Every worktree of the repository from `git worktree list --porcelain`, the main one first."""
    res = _git(main, "worktree", "list", "--porcelain")
    if res is None or res.returncode != 0:
        raise hc.Failure(f"git worktree list in {main}: {_first_line(res)}")
    items, cur = [], None
    for line in res.stdout.splitlines() + [""]:
        if not line:
            if cur is not None:
                items.append(cur)
            cur = None
            continue
        key, _, val = line.partition(" ")
        if key == "worktree":
            cur = Worktree(path=Path(val), real=_real(val))
        elif cur is None:
            continue
        elif key == "HEAD":
            cur.head = val
        elif key == "branch":
            cur.branch = val[len("refs/heads/"):] if val.startswith("refs/heads/") else val
        elif key == "bare":
            cur.bare = True
        elif key == "locked":
            cur.locked = val or "locked"
        elif key == "prunable":
            cur.prunable = val or "prunable"
    if items:
        items[0].is_main = True
    return items


# ---------------------------------------------------------------- who made it, who uses it

def _hub_homes() -> list:
    try:
        return [Path(k.path) for k in hc.known_homes()]
    except (OSError, hc.Failure):
        return []


def _agent_index(homes: list) -> dict:
    """{real path: [(started_at, stage, role, meta)]} of every agent run (the current one and the finished runs kept as
    `<role>.<stamp>`) whose worktree or working directory is that path."""
    index: dict = {}
    for home in homes:
        for meta_path in sorted(home.glob("*/agents/*/meta.json")):
            try:
                meta = json.loads(meta_path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                continue
            if not isinstance(meta, dict):
                continue
            wt = meta.get("worktree") if isinstance(meta.get("worktree"), dict) else {}
            stage = meta.get("stage") or meta_path.parent.parent.parent.name
            role = meta.get("role") or meta_path.parent.name
            for p in {wt.get("path"), meta.get("cwd")}:
                if isinstance(p, str) and p:
                    index.setdefault(_real(p), []).append((str(meta.get("started_at") or ""), stage, role, meta))
    return index


def _role_index(homes: list) -> tuple:
    """({real path: [(stage, role, record)]} of registered roles that name a worktree or cwd, {stage: highest registered
    hub number}) from the roles.json of every stage of every known home."""
    by_path: dict = {}
    hubs: dict = {}
    for home in homes:
        for roles_path in sorted(home.glob("*/roles.json")):
            try:
                data = json.loads(roles_path.read_text(encoding="utf-8"))
                roles = data.get("roles") if isinstance(data, dict) else None
            except (OSError, ValueError):
                continue
            if not isinstance(roles, dict):
                continue
            stage = roles_path.parent.name
            hubs.setdefault(stage, 0)
            for role, rec in roles.items():
                if not isinstance(rec, dict):
                    continue
                if role == "hub":
                    hubs[stage] = max(hubs[stage], hc.hub_number(rec.get("tag")) or 0)
                for p in {rec.get("worktree"), rec.get("cwd")}:
                    if isinstance(p, str) and p:
                        by_path.setdefault(_real(p), []).append((stage, role, rec))
    return by_path, hubs


def process_cwds() -> Optional[list]:
    """[(pid, command, real working directory)] of the processes whose directory can be read; None when this host can
    tell nothing (no /proc and no lsof)."""
    out = []
    proc = Path("/proc")
    if (proc / "self" / "cwd").exists():
        for d in proc.iterdir():
            if not d.name.isdigit():
                continue
            try:
                out.append((int(d.name), (d / "comm").read_text(encoding="utf-8").strip(), _real(os.readlink(d / "cwd"))))
            except OSError:
                continue
        return out
    lsof = shutil.which("lsof")
    if not lsof:
        return None
    try:
        res = subprocess.run([lsof, "-w", "-a", "-d", "cwd", "-F", "pcn"], capture_output=True, text=True,
                             timeout=PROCESS_TIMEOUT_S, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError):
        return None
    if res.returncode not in (0, 1):
        return None
    pid, cmd = 0, ""
    for line in res.stdout.splitlines():
        if line.startswith("p") and line[1:].isdigit():
            pid, cmd = int(line[1:]), ""
        elif line.startswith("c"):
            cmd = line[1:]
        elif line.startswith("n") and pid:
            out.append((pid, cmd, _real(line[1:])))
    return out


def _assign_processes(items: list, procs: Optional[list]) -> dict:
    """{real path of a worktree: [(pid, command)]}: each process goes to the deepest worktree its directory is inside
    (the main checkout contains the others), this process left out."""
    found: dict = {w.real: [] for w in items}
    if not procs:
        return found
    roots = sorted(found, key=len, reverse=True)
    for pid, cmd, cwd in procs:
        if pid == os.getpid():
            continue
        for r in roots:
            if cwd == r or cwd.startswith(r + os.sep):
                found[r].append((pid, cmd))
                break
    return found


def attribute(main: Path, items: list, alive: Callable[[dict], bool], procs: Optional[list]) -> None:
    """Fill kind, who, stage, role, live and live_by of every worktree."""
    homes = _hub_homes()
    agents = _agent_index(homes)
    roles, hubs = _role_index(homes)
    in_use = _assign_processes(items, procs)
    main_real = _real(main)
    for w in items:
        runs = sorted(agents.get(w.real, []), key=lambda r: r[0])
        registered = roles.get(w.real, [])
        rel = Path(os.path.relpath(w.real, main_real)).parts if w.real.startswith(main_real + os.sep) else ()
        hub = None
        if (rel[:2] == (".claude", "worktrees") and len(rel) == 3) or (rel[:1] == (".worktrees",) and len(rel) > 1):
            hub = HUB_DIR_RE.fullmatch(rel[-1])
        live_by = []
        for _, stage, role, meta in runs:
            if alive(meta):
                live_by.append(f"agent {role} (stage {stage}, pid {meta.get('pid')})")
        for stage, role, rec in registered:
            live_by.append(f"registered {role} of stage {stage}")
        for pid, cmd in in_use.get(w.real, []):
            live_by.append(f"{cmd or 'process'} (pid {pid})")
        known_not_live = False
        if w.is_main:
            w.kind, w.who = "main", "main checkout"
        elif runs:
            _, w.stage, w.role, _ = runs[-1]
            w.kind, w.who = "agent", f"agent {w.role} (stage {w.stage})"
            known_not_live = True
        elif registered:
            w.stage, w.role = registered[0][0], registered[0][1]
            n = hc.hub_number(registered[0][2].get("tag")) if w.role == "hub" else None
            w.kind, w.who = "role", (f"hub of {w.stage} #{n}" if n else f"{w.role} (stage {w.stage})")
            w.hub_number = n
        elif hub:
            w.kind, w.stage, w.hub_number = "hub", hub.group("stage"), int(hub.group("n"))
            w.who = f"hub of {w.stage} #{w.hub_number}"
            current = hubs.get(w.stage)
            known_not_live = current is not None and current > w.hub_number  # a later hub took the stage over
        else:
            w.kind, w.who = "other", "other (Desktop session or manual)"
        w.live_by = live_by
        if live_by:
            w.live = "yes"
        else:
            w.live = "no" if known_not_live and procs is not None else "unknown"


# ---------------------------------------------------------------- git facts

def _inspect(main: Path, w: Worktree, default_ref: Optional[str]) -> None:
    """dirty, operation, unpushed, ancestry-merged and last_change of one worktree."""
    if not w.exists:
        return
    status = _git(w.path, "status", "--porcelain", "-z", "--untracked-files=normal")
    stamps = []
    if status is not None and status.returncode == 0:
        tokens = status.stdout.split("\0")
        files, i = [], 0
        while i < len(tokens):
            tok = tokens[i]
            if len(tok) > 3:
                files.append(tok[3:])
                if tok[0] in "RC":
                    i += 1  # the source path of a rename follows as its own token
            i += 1
        w.dirty = len(files)
        for f in files[:200]:
            try:
                stamps.append((w.path / f).lstat().st_mtime)
            except OSError:
                continue
    gitdir = _out(_git(w.path, "rev-parse", "--absolute-git-dir"))
    if gitdir:
        w.gitdir = Path(gitdir)
        for name, label in OPERATIONS:
            if (w.gitdir / name).exists():
                w.operation = label
                break
        try:
            stamps.append((w.gitdir / "logs" / "HEAD").stat().st_mtime)
        except OSError:
            pass
    try:
        stamps.append(w.path.stat().st_mtime)
    except OSError:
        pass
    if w.head and not set(w.head) <= {"0"}:
        ahead = _out(_git(w.path, "rev-list", "--count", "HEAD", "--not", "--remotes"))
        if ahead is not None and ahead.isdigit():
            w.unpushed = w.unpushed_raw = int(ahead)
        stamp = _out(_git(w.path, "log", "-1", "--format=%ct", "HEAD"))
        if stamp and stamp.isdigit():
            stamps.append(float(stamp))
        if default_ref and not w.is_main:
            res = _git(w.path, "merge-base", "--is-ancestor", "HEAD", default_ref)
            if res is not None and res.returncode in (0, 1):
                w.merged = res.returncode == 0
                if w.merged:
                    w.merged_by = "ancestry"
    else:
        w.unpushed = w.unpushed_raw = 0  # an unborn branch has no commits to lose
        w.merged_note = "no commits yet"
    if stamps:
        w.last_change = dt.datetime.fromtimestamp(max(stamps), hc.TZ)


class GitHub:
    """Merged pull requests of a branch through `gh`; one failed probe switches it off for the rest of the run."""

    def __init__(self, main: Path, enabled: bool):
        self.main = main
        self.exe = shutil.which("gh") if enabled else None
        self.state = "off" if not enabled else ("ok" if self.exe else "missing")

    def merged_prs(self, branch: str) -> Optional[list]:
        if self.state != "ok":
            return None
        env = dict(os.environ, GH_PROMPT_DISABLED="1", NO_COLOR="1")
        env.pop("GIT_DIR", None)
        env.pop("GIT_WORK_TREE", None)
        try:
            res = subprocess.run([self.exe, "pr", "list", "--state", "merged", "--head", branch, "--limit", "20", "--json",
                                  "number,url,headRefOid,baseRefName,mergedAt"],
                                 cwd=self.main, capture_output=True, text=True, timeout=GH_TIMEOUT_S, env=env,
                                 stdin=subprocess.DEVNULL)
            if res.returncode != 0:
                raise OSError((res.stderr.strip().splitlines() or [f"exit {res.returncode}"])[0][:160])
            prs = json.loads(res.stdout or "[]")
        except subprocess.TimeoutExpired:
            raise OSError(f"no answer in {GH_TIMEOUT_S} s") from None
        except (subprocess.SubprocessError, ValueError) as e:
            raise OSError(f"unreadable answer ({type(e).__name__})") from None
        return prs if isinstance(prs, list) else []


def _apply_pr(main: Path, w: Worktree, prs: list, default_branch: Optional[str]) -> None:
    """Merged by a pull request: it was merged into the default branch and HEAD is inside its head commit, so everything
    the worktree has is in the merged PR (a squash or rebase merge leaves no ancestry to see)."""
    seen = []
    for pr in prs:
        if not isinstance(pr, dict) or not pr.get("mergedAt") or pr.get("baseRefName") != default_branch:
            continue
        seen.append(pr)
        oid = str(pr.get("headRefOid") or "")
        res = _git(main, "merge-base", "--is-ancestor", w.head, oid) if oid else None
        if res is not None and res.returncode == 0:
            w.merged, w.merged_by, w.pr = True, "pr", pr
            w.unpushed = 0
            return
    if seen:
        w.merged = False
        w.merged_note = (f"PR #{seen[0].get('number')} was merged, but the branch has commits it does not contain "
                         "(or its head is not in this clone)")


def _fetch(main: Path, notes: list) -> None:
    res = _git(main, "fetch", "--quiet", "origin", timeout=FETCH_TIMEOUT_S)
    if res is None or res.returncode != 0:
        notes.append(f"git fetch origin failed ({_first_line(res)}): remote refs are as last fetched")


def collect(repo: Path, alive: Callable[[dict], bool], idle: dt.timedelta, use_gh: bool = True, fetch: bool = False,
            caller_cwd: Optional[Path] = None) -> Ledger:
    """Everything the ledger and the prune decide on, for the repository `repo` is in. Read-only (a fetch with `fetch`)."""
    main = hc.main_tree(repo)
    if main is None:
        raise hc.UsageError(f"{repo} is not inside a git repository with a working tree")
    notes: list = []
    if fetch:
        _fetch(main, notes)
    items = list_worktrees(main)
    default_ref, default_branch = hc.default_ref(main)
    if default_ref is None:
        notes.append("no remote default branch (origin/HEAD, origin/main, origin/master): merge state is unknown, "
                     "nothing can be pruned")
    procs = process_cwds()
    if procs is None:
        notes.append("this host cannot list processes' directories (no /proc, no lsof): use is judged from agent runs only")
    attribute(main, items, alive, procs)
    with concurrent.futures.ThreadPoolExecutor(WORKERS) as pool:
        list(pool.map(lambda w: _inspect(main, w, default_ref), items))
    gh = GitHub(main, use_gh)
    pending = [w for w in items if w.branch and not w.is_main and w.merged is False and w.exists
               and w.branch != default_branch]
    gh_failed = ""
    if pending and gh.state == "ok":
        try:
            _apply_pr(main, pending[0], gh.merged_prs(pending[0].branch) or [], default_branch)
        except OSError as e:
            gh.state = f"unavailable ({e})"
        rest = pending[1:] if gh.state == "ok" else []

        def lookup(w: Worktree) -> None:
            try:
                _apply_pr(main, w, gh.merged_prs(w.branch) or [], default_branch)
            except OSError as e:
                w.merged, w.merged_note = None, f"gh failed ({e})"

        with concurrent.futures.ThreadPoolExecutor(WORKERS) as pool:
            list(pool.map(lookup, rest))
    if pending and gh.state != "ok":
        gh_failed = gh.state
        for w in pending:
            w.merged, w.merged_note = None, "merge state unknown for squash-merged branches (no gh)"
    if gh_failed and gh_failed != "off":
        notes.append("gh is " + ("not installed" if gh_failed == "missing" else gh_failed)
                     + ": merge state unknown for squash-merged branches")
    elif gh_failed == "off":
        notes.append("--no-gh: merge state unknown for squash-merged branches")
    now = hc.now()
    here = _real(caller_cwd) if caller_cwd else None
    holder = next((w for w in sorted(items, key=lambda w: len(w.real), reverse=True)
                   if here and (here == w.real or here.startswith(w.real + os.sep))), None)  # the deepest one holds it
    for w in items:
        w.caller = w is holder
        w.reasons = keep_reasons(w, now, idle, default_ref)
    return Ledger(main, default_ref, default_branch, items, notes, gh.state, now, idle)


def keep_reasons(w: Worktree, now: dt.datetime, idle: dt.timedelta, default_ref: Optional[str] = None) -> list:
    """[(code, text)]: why prune keeps the worktree; empty means it is finished and may go."""
    if w.is_main:
        return [("main", "main checkout")]
    if w.bare:
        return [("bare", "bare repository")]
    if w.prunable is not None:
        return []
    r = []
    if w.locked is not None:
        r.append(("locked", "locked" if w.locked == "locked" else f"locked: {w.locked}"))
    if w.caller:
        r.append(("caller", "your current directory"))
    if w.live == "yes":
        r.append(("live", "in use: " + "; ".join(w.live_by)))
    if w.dirty is None:
        r.append(("dirty", "dirty state unknown (git status failed)"))
    elif w.dirty:
        r.append(("dirty", f"dirty: {w.dirty} changed file{'s' if w.dirty != 1 else ''}"))
    if w.operation:
        r.append(("operation", f"{w.operation} in progress"))
    if w.unpushed is None:
        r.append(("unpushed", "its commits could not be inspected"))
    elif w.unpushed:
        r.append(("unpushed", f"{w.unpushed} commit{'s' if w.unpushed != 1 else ''} on no remote"))
    if w.merged is not True:
        r.append(("unmerged", w.merged_note or (f"branch not merged into {default_ref}" if default_ref
                                                else "merge state unknown (no remote default branch)")))
    if w.live == "unknown":
        since = None if w.last_change is None else now - w.last_change
        if since is None or since < idle:
            r.append(("idle", "use unknown, changed " + (hc.age(w.last_change, now) + " ago" if since is not None
                                                          else "at an unknown time") + f" (limit {fmt_delta(idle)})"))
    return sorted(r, key=lambda x: REASON_ORDER.index(x[0]))


def fmt_delta(d: dt.timedelta) -> str:
    s = int(d.total_seconds())
    return f"{s // 86400} d" if s and s % 86400 == 0 else (f"{s // 3600} h" if s and s % 3600 == 0 else f"{s // 60} min")


# ---------------------------------------------------------------- prune

@dataclasses.dataclass
class Outcome:
    removed: list  # [(Worktree, branch action)]
    kept: list  # [(Worktree, [(code, text)])]
    stale: list  # [Worktree] entries whose directory is gone
    dry_run: bool


def prune(ledger: Ledger, dry_run: bool, delete_branches: bool) -> Outcome:
    """Remove the finished worktrees (git worktree remove, never --force), then clear stale entries; delete a branch
    only when it is merged by ancestry (git branch -d), a squash-merged one only with `delete_branches` (git branch -D,
    for a branch whose merged pull request holds everything it has). A worktree that changed since the listing is kept."""
    removed, kept, stale = [], [], []
    main = ledger.main
    for w in ledger.items:
        if w.is_main or w.bare:
            continue
        if w.prunable is not None:
            if w.locked is None:
                stale.append(w)
            else:
                kept.append((w, [("locked", f"stale entry, locked ({w.locked})")]))
            continue
        if not w.removable:
            kept.append((w, w.reasons))
            continue
        if dry_run:
            removed.append((w, branch_plan(w, delete_branches, ledger.default_branch)))
            continue
        now_head = _out(_git(w.path, "rev-parse", "HEAD"))
        if now_head != w.head:
            kept.append((w, [("operation", "its HEAD moved while pruning")]))
            continue
        res = _git(main, "worktree", "remove", str(w.path))
        if res is None or res.returncode != 0:
            kept.append((w, [("dirty", f"git refused to remove it: {_first_line(res)}")]))
            continue
        removed.append((w, delete_branch(main, w, delete_branches, ledger.default_branch)))
    if stale and not dry_run:
        _git(main, "worktree", "prune")
    return Outcome(removed, kept, stale, dry_run)


def branch_plan(w: Worktree, delete_branches: bool, default_branch: Optional[str]) -> str:
    if not w.branch:
        return "detached HEAD, no branch"
    if w.branch == default_branch:
        return f"branch {w.branch} kept (the default branch)"
    if w.merged_by == "ancestry":
        return f"branch {w.branch} would be deleted (git branch -d)"
    if delete_branches:
        return f"branch {w.branch} would be deleted (PR #{(w.pr or {}).get('number')} is merged)"
    return f"branch {w.branch} kept (squash-merged; --delete-branches removes it)"


def delete_branch(main: Path, w: Worktree, delete_branches: bool, default_branch: Optional[str]) -> str:
    if not w.branch:
        return "detached HEAD, no branch"
    if w.branch == default_branch:
        return f"branch {w.branch} kept (the default branch)"
    if w.merged_by == "ancestry":
        res = _git(main, "branch", "-d", w.branch)
        return f"branch {w.branch} deleted" if res is not None and res.returncode == 0 else \
            f"branch {w.branch} kept (git branch -d: {_first_line(res)})"
    if delete_branches and w.merged_by == "pr":
        res = _git(main, "branch", "-D", w.branch)
        return f"branch {w.branch} deleted (PR #{(w.pr or {}).get('number')} is merged)" if res is not None and res.returncode == 0 \
            else f"branch {w.branch} kept (git branch -D: {_first_line(res)})"
    return f"branch {w.branch} kept (squash-merged; --delete-branches removes it)"


# ---------------------------------------------------------------- output

def _rel(main: Path, w: Worktree) -> str:
    main_real = _real(main)
    if w.real == main_real:
        return "."
    if w.real.startswith(main_real + os.sep):
        return os.path.relpath(w.real, main_real)
    home = str(Path.home())
    return "~" + str(w.path)[len(home):] if str(w.path).startswith(home + os.sep) else str(w.path)


def _cells(ledger: Ledger, w: Worktree) -> list:
    def plural(n, word):
        return f"{n} {word}{'s' if n != 1 else ''}"
    if w.prunable is not None:
        return ["gone", "-", "-", "-", "-", "stale entry (directory gone)"]
    dirty = "?" if w.dirty is None else ("clean" if not w.dirty else plural(w.dirty, "file"))
    if w.merged_by == "pr":
        pushed, merged = f"PR #{w.pr.get('number')}", f"PR #{w.pr.get('number')}"
    else:
        pushed = "?" if w.unpushed is None else ("yes" if not w.unpushed else f"no ({plural(w.unpushed, 'commit')})")
        merged = "-" if w.is_main else ("?" if w.merged is None else ("yes" if w.merged else "no"))
    age = hc.age(w.last_change, ledger.now)
    if w.is_main:
        verdict = "main checkout"
    elif w.bare:
        verdict = "bare"
    elif w.removable:
        verdict = "removable"
    else:
        verdict = "kept: " + "; ".join(t for _, t in w.reasons)
    return [dirty, pushed, merged, age, w.live, verdict]


def render(ledger: Ledger) -> str:
    rows = [["PATH", "BRANCH", "WHO", "LIVE", "DIRTY", "ON REMOTE", "MERGED", "AGE", "PRUNE"]]
    for w in ledger.items:
        dirty, pushed, merged, age, live, verdict = _cells(ledger, w)
        branch = w.branch or ("(detached)" if w.head else "(bare)")
        rows.append([_rel(ledger.main, w), branch if len(branch) <= 36 else branch[:35] + "…", w.who, live, dirty,
                     pushed, merged, age, verdict])
    widths = [max(len(r[i]) for r in rows) for i in range(len(rows[0]) - 1)]
    lines = [f"worktrees of {ledger.main} (default branch: {ledger.default_ref or 'unknown'})"]
    for r in rows:
        lines.append("  ".join(c.ljust(widths[i]) for i, c in enumerate(r[:-1])) + "  " + r[-1])
    removable = [w for w in ledger.items if w.removable]
    lines.append(f"{len(ledger.items)} worktrees, {len(removable)} removable by `agent worktrees --prune` "
                 f"(unknown use counts as free after {fmt_delta(ledger.idle)} without a change)")
    lines += [f"note: {n}" for n in ledger.notes]
    return "\n".join(lines)


def render_outcome(ledger: Ledger, out: Outcome) -> str:
    verb = "would remove" if out.dry_run else "removed"
    lines = []
    if out.dry_run:
        lines.append("dry run: nothing was removed")
    lines.append(f"{verb} {len(out.removed)}:" if out.removed else f"{verb} 0")
    lines += [f"  {_rel(ledger.main, w)} — {action}" for w, action in out.removed]
    if out.stale:
        lines.append(("would clear" if out.dry_run else "cleared") + f" {len(out.stale)} stale entr"
                     + ("y" if len(out.stale) == 1 else "ies") + " (directory gone):")
        lines += [f"  {_rel(ledger.main, w)}" for w in out.stale]
    tally: dict = {}
    for w, reasons in out.kept:
        tally.setdefault(reasons[0][0], []).append((w, reasons))
    lines.append(f"kept {len(out.kept)}" + (":" if out.kept else ""))
    for code in REASON_ORDER:
        group = tally.get(code, [])
        if group:
            lines.append(f"  {code} ({len(group)}):")
            lines += [f"    {_rel(ledger.main, w)} — " + "; ".join(t for _, t in reasons) for w, reasons in group]
    mains = sum(1 for w in ledger.items if w.is_main or w.bare)
    summary = ", ".join(f"{c} {len(g)}" for c in REASON_ORDER if (g := tally.get(c)))
    lines.append(f"{verb} {len(out.removed)}, kept {len(out.kept)}" + (f" ({summary})" if summary else "")
                 + (f", main checkout {mains}" if mains else ""))
    lines += [f"note: {n}" for n in ledger.notes]
    return "\n".join(lines)


def _item(ledger: Ledger, w: Worktree) -> dict:
    return {"path": str(w.path), "branch": w.branch, "head": w.head, "main": w.is_main, "bare": w.bare,
            "locked": w.locked, "stale": w.prunable is not None,
            "kind": w.kind, "who": w.who, "stage": w.stage, "role": w.role, "hub_number": w.hub_number,
            "live": w.live, "live_by": w.live_by,
            "dirty": None if w.dirty is None else bool(w.dirty), "dirty_files": w.dirty, "operation": w.operation,
            "pushed": None if w.unpushed is None else w.unpushed == 0, "unpushed_commits": w.unpushed,
            "merged": w.merged, "merged_by": w.merged_by, "merged_note": w.merged_note or None,
            "pr": None if not w.pr else {k: w.pr.get(k) for k in ("number", "url", "headRefOid", "mergedAt")},
            "last_change": w.last_change.isoformat(timespec="seconds") if w.last_change else None,
            "age_seconds": int((ledger.now - w.last_change).total_seconds()) if w.last_change else None,
            "caller": w.caller, "removable": w.removable,
            "keep": [{"code": c, "reason": t} for c, t in w.reasons]}


def as_json(ledger: Ledger, out: Optional[Outcome] = None) -> str:
    data = {"repo": str(ledger.main), "default_ref": ledger.default_ref, "default_branch": ledger.default_branch,
            "gh": ledger.gh, "idle_seconds": int(ledger.idle.total_seconds()),
            "generated_at": ledger.now.isoformat(timespec="seconds"), "notes": ledger.notes,
            "worktrees": [_item(ledger, w) for w in ledger.items]}
    if out is not None:
        data["prune"] = {"dry_run": out.dry_run,
                         "removed": [{"path": str(w.path), "branch": w.branch, "branch_action": action} for w, action in out.removed],
                         "kept": [{"path": str(w.path), "branch": w.branch,
                                   "reasons": [{"code": c, "reason": t} for c, t in reasons]} for w, reasons in out.kept],
                         "stale": [str(w.path) for w in out.stale]}
    return json.dumps(data, ensure_ascii=False, indent=1)


def run(a, alive: Callable[[dict], bool]) -> int:
    """`agent worktrees` (the argument parser is bin/agent's)."""
    if (a.dry_run or a.delete_branches) and not a.prune:
        raise hc.UsageError("--dry-run and --delete-branches go with --prune (without it the command only lists)")
    idle = hc.parse_duration(a.idle_for)
    try:
        caller = Path.cwd()
    except OSError:
        caller = None
    repo = Path(a.repo).expanduser() if a.repo else (caller or Path("/"))
    if not repo.is_dir():
        raise hc.UsageError(f"--repo {repo}: not a directory")
    ledger = collect(repo, alive, idle, use_gh=not a.no_gh, fetch=a.fetch, caller_cwd=caller)
    outcome = prune(ledger, a.dry_run, a.delete_branches) if a.prune else None
    if a.json:
        print(as_json(ledger, outcome))
    else:
        print(render(ledger) if outcome is None else render_outcome(ledger, outcome))
    return 0
