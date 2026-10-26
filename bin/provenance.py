"""Commit provenance: the trailers an agent's commits carry, and `hub why`, which walks back from a commit to its run.

Every run of an agent (spawn or resume, bin/agent `launch`) gets an id (meta.json runs[].id, prompt-<id>.txt) and, when
its working directory is in a git repository, an environment that points its git at bin/git-hooks/ through
GIT_CONFIG_PARAMETERS. The shim there chains every hook to the project's own and, in prepare-commit-msg, appends

    Delamain-Stage: <stage>
    Delamain-Role: <role>
    Delamain-Run: <run id>

to commits made in that repository. A commit may be pushed to a public repository: the trailers name no path, no
session id and nothing of the machine; `hub why` resolves the rest from the run records of this machine's hub homes.
AGENT_HUB_PROVENANCE=off (environment, the project's or the home's config.json) leaves the agent's git alone.
"""
from __future__ import annotations

import datetime as dt
import json
import os
import re
import subprocess
from pathlib import Path
from typing import Optional

import hubcore as hc

HOOKS_DIR = hc.BIN / "git-hooks"
SETTING = "AGENT_HUB_PROVENANCE"
RUN_ENV = "AGENT_HUB_RUN"                 # the run id; the shim adds trailers only while it is set
REPO_ENV = "AGENT_HUB_PROVENANCE_REPO"    # the common git dir of the agent's repository: other repositories get none
STAGE_KEY, ROLE_KEY, RUN_KEY = "Delamain-Stage", "Delamain-Role", "Delamain-Run"
JOURNAL_WINDOW = dt.timedelta(minutes=30)
JOURNAL_MAX = 12
RUN_EARLY = dt.timedelta(minutes=1)       # a run's window for a guess: from its start minus this (clock rounding) …
RUN_LATE = dt.timedelta(minutes=5)        # … to its log's last write (now, while it runs) plus this
# reflog subjects of an entry that created a commit (not a fast-forward, reset, checkout or a rebase's finish)
CREATED_RE = re.compile(r"^(commit|cherry-pick|revert|rebase[^:]*\((pick|reword|edit|squash|fixup|continue)\))"
                        r"|^(merge|pull)\b[^:]*: Merge made by")


# ---------------------------------------------------------------- the agent's environment

def git(*argv, cwd) -> subprocess.CompletedProcess:
    """git in `cwd`, never in a repository chosen by the caller's GIT_DIR / GIT_WORK_TREE."""
    env = {k: v for k, v in os.environ.items() if k not in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE",
                                                           "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY")}
    return subprocess.run(["git", *argv], cwd=cwd, env=env, capture_output=True, text=True, timeout=30)


_COMMON: dict = {}


def common_dir(path) -> Optional[Path]:
    """The resolved common git dir of the repository at `path`, None when there is none (or no such directory)."""
    key = str(path)
    if key not in _COMMON:
        try:
            r = git("rev-parse", "--git-common-dir", cwd=path)
            _COMMON[key] = (Path(path) / r.stdout.strip()).resolve() if r.returncode == 0 and r.stdout.strip() else None
        except (OSError, subprocess.SubprocessError):
            _COMMON[key] = None
    return _COMMON[key]


def sq(text: str) -> str:
    """Single-quote a value the way git writes GIT_CONFIG_PARAMETERS (sq_quote_buf)."""
    return "'" + text.replace("'", "'\\''").replace("!", "'\\!'") + "'"


def enabled(cwd=None) -> bool:
    return str(hc.setting(SETTING, cwd=cwd) or "on").strip().lower() not in ("off", "0", "false", "no")


def agent_env(cwd, run_id: str, env: dict) -> dict:
    """The variables to add to a run's environment so its commits carry the run's trailers: core.hooksPath -> the shim
    (appended last to GIT_CONFIG_PARAMETERS, which survives Codex's *KEY* environment filter where GIT_CONFIG_KEY_<n>
    would not), the run id and the agent's repository. Empty when provenance is off or `cwd` is not in a repository."""
    if not enabled(cwd) or not (HOOKS_DIR / "delamain-hook").is_file():
        return {}
    repo = common_dir(cwd)
    if repo is None:
        return {}
    entry = sq(f"core.hooksPath={HOOKS_DIR}")
    params = " ".join(p for p in (env.get("GIT_CONFIG_PARAMETERS", "").replace(entry, "").strip(), entry) if p)
    return {"GIT_CONFIG_PARAMETERS": params, RUN_ENV: run_id, REPO_ENV: str(repo)}


# ---------------------------------------------------------------- run records

def _when(raw) -> Optional[dt.datetime]:
    try:
        t = dt.datetime.fromisoformat(str(raw))
    except (TypeError, ValueError):
        return None
    return t if t.tzinfo else t.replace(tzinfo=hc.TZ)


def run_records(stage: Optional[str] = None) -> list:
    """meta.json of every agent in every known hub home (a re-spawned role's earlier directories too), each with
    `_home` and `_dir` (where it is now)."""
    out = []
    for kh in hc.known_homes():
        base = Path(kh.path)
        try:
            stages = [stage] if stage else sorted(d.name for d in base.iterdir()
                                                  if d.is_dir() and hc.STAGE_RE.fullmatch(d.name))
        except OSError:
            continue
        for st in stages:
            for mp in sorted((base / st / "agents").glob("*/meta.json")):
                try:
                    meta = json.loads(mp.read_text(encoding="utf-8"))
                except (OSError, ValueError):
                    continue
                if isinstance(meta, dict) and meta.get("role"):
                    meta.update(_home=str(base), _dir=str(mp.parent))
                    meta.setdefault("stage", st)
                    out.append(meta)
    return out


def _alive(meta: dict) -> bool:
    try:
        os.kill(int(meta.get("pid") or 0), 0)
        return bool(meta.get("pid"))
    except (OSError, ValueError, TypeError):
        return False


def run_windows(meta: dict) -> list:
    """[(run, start, end)] of an agent's runs: each run ends where the next starts, the last at the log's last write
    (now, while its process lives)."""
    runs = [r for r in meta.get("runs") or [] if isinstance(r, dict) and _when(r.get("at"))]
    if not runs and _when(meta.get("started_at")):
        runs = [{"at": meta["started_at"], "kind": "spawn"}]
    try:
        last = dt.datetime.fromtimestamp((Path(meta["_dir"]) / "log.jsonl").stat().st_mtime, hc.TZ)
    except (OSError, KeyError):
        last = None
    if runs and _alive(meta):
        last = hc.now()
    out = []
    for i, r in enumerate(runs):
        start = _when(r["at"])
        end = _when(runs[i + 1]["at"]) if i + 1 < len(runs) else max(filter(None, [last, start]))
        out.append((r, start, end))
    return out


def run_at(meta: dict, when: dt.datetime):
    """The run of `meta` whose window holds `when`, else None."""
    for r, start, end in run_windows(meta):
        if start - RUN_EARLY <= when <= end + RUN_LATE:
            return r
    return None


def find_run(stage: str, role: str, run_id: str):
    """(meta, run) of a trailer's run: the run id first, then a lone agent of that role as a fallback (run None)."""
    metas = run_records(stage)
    for meta in metas:
        for r in meta.get("runs") or []:
            if isinstance(r, dict) and (r.get("id") == run_id or r.get("prompt") == f"prompt-{run_id}.txt"):
                return meta, r
    same = [m for m in metas if m.get("role") == role]
    return (same[-1], None) if len(same) == 1 else (None, None)


# ---------------------------------------------------------------- the commit

def resolve(target: str, cwd: Path) -> tuple:
    """(sha, repo dir, line note) of `<rev>` or `<file>:<line>` (the line's last commit, from git blame)."""
    m = re.fullmatch(r"(.+):(\d+)", target)
    if m and Path(cwd, m.group(1)).is_file():
        f = Path(cwd, m.group(1)).resolve()
        r = git("blame", "--porcelain", "-L", f"{m.group(2)},{m.group(2)}", "--", str(f), cwd=f.parent)
        if r.returncode:
            raise hc.UsageError(f"git blame {target}: {r.stderr.strip() or 'failed'}")
        sha = r.stdout.split(" ", 1)[0]
        if not sha.strip("0"):
            raise hc.Failure(f"{target}: the line is not committed yet")
        return sha, f.parent, f"{m.group(1)}:{m.group(2)}"
    r = git("rev-parse", "--verify", "--quiet", f"{target}^{{commit}}", cwd=cwd)
    if r.returncode:
        raise hc.UsageError(f"{target}: neither a commit of the repository at {cwd} nor <file>:<line>")
    return r.stdout.strip(), cwd, None


def commit_info(sha: str, repo: Path) -> dict:
    r = git("show", "-s", "--format=%H%x00%ct%x00%at%x00%an%x00%s%x00%(trailers:only,unfold)", sha, cwd=repo)
    if r.returncode:
        raise hc.Failure(f"git show {sha}: {r.stderr.strip()}")
    full, ct, at, author, subject, trailers = (r.stdout.rstrip("\n").split("\x00") + [""] * 6)[:6]
    found = {}
    for line in trailers.splitlines():
        key, _, value = line.partition(":")
        for k in (STAGE_KEY, ROLE_KEY, RUN_KEY):
            if key.strip().lower() == k.lower() and value.strip():
                found[k] = value.strip()
    return {"sha": full, "subject": subject, "author": author,
            "committed": dt.datetime.fromtimestamp(int(ct), hc.TZ), "authored": dt.datetime.fromtimestamp(int(at), hc.TZ),
            "trailers": found}


def reflog_created(repo: Path, ref: str, sha: str) -> Optional[dt.datetime]:
    """When the reflog of `ref` records creating `sha` (a commit, merge, cherry-pick, rebase pick), else None."""
    r = git("log", "-g", "--date=unix", "--format=%H%x00%gd%x00%gs", ref, "--", cwd=repo)
    if r.returncode:
        return None
    for line in r.stdout.splitlines():
        h, _, rest = line.partition("\x00")
        sel, _, subj = rest.partition("\x00")
        m = re.search(r"@\{(\d+)\}$", sel)
        if h == sha and m and CREATED_RE.search(subj):
            return dt.datetime.fromtimestamp(int(m.group(1)), hc.TZ)
    return None


def guesses(info: dict, repo: Path) -> list:
    """[(meta, run, how, strength)] for a commit without trailers, from the runs of this repository whose window holds
    its commit time. A guess: a reflog entry that created it in the worktree or branch spawn made for the agent
    (--worktree). A weak guess: such an entry in a checkout the agent shared with others, or a branch of the agent's
    that contains it — neither tells who typed the commit."""
    me = common_dir(repo)
    strong, weak = [], []
    for meta in run_records():
        run = run_at(meta, info["committed"])
        if run is None:
            continue
        cwd = meta.get("cwd")
        here = bool(cwd) and Path(cwd).is_dir()
        if here and common_dir(cwd) != me:
            continue
        own = (meta.get("worktree") or {}).get("branch")
        refs = [f"refs/heads/{own}"] if own else []
        shared = [f"refs/heads/agent/{meta['role']}"] if not own else []
        if here:
            cur = git("symbolic-ref", "--quiet", "HEAD", cwd=cwd).stdout.strip()
            if cur and cur not in refs:
                shared.append(cur)
        hit = None
        for where, ref, place in ([(Path(cwd), "HEAD", f"the HEAD reflog of its worktree {cwd}")] if here else []) + \
                [(repo, r, f"the reflog of {r.removeprefix('refs/heads/')}") for r in refs + shared]:
            when = reflog_created(where, ref, info["sha"])
            if when:
                hit = (f"{place} records creating it at {when:%Y-%m-%d %H:%M}, during the run",
                       "guess" if own and (ref in refs or ref == "HEAD") else "weak guess")
                break
        if not hit:
            for ref in refs + shared:
                if git("merge-base", "--is-ancestor", info["sha"], ref, cwd=repo).returncode == 0:
                    hit = (f"branch {ref.removeprefix('refs/heads/')} contains it and it was committed during the run "
                           "(no reflog entry)", "weak guess")
                    break
        if hit:
            (strong if hit[1] == "guess" else weak).append((meta, run, *hit))
    return (strong or weak)[:3]


# ---------------------------------------------------------------- what the run left

def journal_lines(home: str, stage: str, tag: str, at: dt.datetime) -> tuple:
    """(lines, more): the journal lines of `tag` (and its sub-tags) within JOURNAL_WINDOW of `at`, at most JOURNAL_MAX
    (the nearest), and how many more there were."""
    local = at.astimezone(hc.TZ)
    lo, hi = local - JOURNAL_WINDOW, local + JOURNAL_WINDOW
    found = []
    for day in sorted({lo.date(), hi.date()}):
        path = Path(home) / stage / "coordinator" / "work" / f"journal-{day.isoformat()}.md"
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for line in text.splitlines():
            parsed = hc.parse_journal_line(line)
            if not parsed or not hc.tag_is(parsed[1], tag):
                continue
            hh, mm = map(int, parsed[0].split(":"))
            when = dt.datetime.combine(day, dt.time(hh, mm), tzinfo=hc.TZ)
            if lo <= when <= hi:
                found.append((when, f"{day.isoformat()} {line[2:]}" if lo.date() != hi.date() else line[2:]))
    near = sorted(found, key=lambda x: abs((x[0] - local).total_seconds()))[:JOURNAL_MAX]
    return [s for _, s in sorted(near, key=lambda x: x[0])], len(found) - len(near)


def transcript(meta: dict) -> Optional[str]:
    sid = meta.get("session_id")
    if not sid:
        return None
    if meta.get("engine") == "codex":
        import codex_rollouts
        rec = codex_rollouts.Index().session(sid)
        return str(rec[0]) if rec else None
    import session_effort
    path = session_effort.find_transcript(sid)
    return str(path) if path else None


def describe(meta: dict, run, at: dt.datetime, info: dict) -> dict:
    """What a run record tells about a commit; a missing piece is None and named in notes, never filled in."""
    notes = []
    brief = meta.get("brief")
    if not brief or not Path(brief).is_file():
        copy = Path(meta["_dir"]) / "brief.md"
        if copy.is_file():
            notes.append(f"brief {brief or '?'} is gone; the copy taken at spawn is kept")
            brief = str(copy)
        else:
            brief = None
    report = meta.get("report")
    start = _when((run or {}).get("at") or meta.get("started_at"))
    if start and info["authored"] < start - dt.timedelta(minutes=1):
        notes.append(f"authored {info['authored']:%Y-%m-%d %H:%M}, before this run started: the run amended or "
                     "replayed it")
    lines, more = journal_lines(meta["_home"], meta["stage"], meta.get("tag") or meta["role"], at)
    tr = transcript(meta)
    model = meta.get("resolved_model") or meta.get("model")
    if meta.get("resolved_model") and meta.get("model") and meta["resolved_model"] != meta["model"]:
        model += f" (asked for {meta['model']})"
    return {"stage": meta["stage"], "role": meta["role"], "tag": meta.get("tag") or meta["role"],
            "run": (run or {}).get("id") or (str((run or {}).get("prompt") or "")[7:-4] or None),
            "run_kind": (run or {}).get("kind"), "run_at": (run or {}).get("at"),
            "engine": meta.get("engine") or "claude", "model": model, "effort": meta.get("effort"),
            "brief": brief, "report": report, "report_exists": bool(report) and Path(report).is_file(),
            "agent_dir": meta["_dir"], "session_id": meta.get("session_id") or None,
            "transcript": tr, "journal": lines, "journal_more": more, "notes": notes}


def why(target: str, cwd: Path) -> dict:
    sha, repo, line = resolve(target, cwd)
    info = commit_info(sha, repo)
    out = {"commit": {"sha": info["sha"], "subject": info["subject"], "author": info["author"],
                      "committed": info["committed"].isoformat(timespec="seconds")}, "line": line,
           "trailers": info["trailers"], "source": None, "agents": [], "notes": []}
    tr = info["trailers"]
    if RUN_KEY in tr or (STAGE_KEY in tr and ROLE_KEY in tr):
        out["source"] = "trailers"
        stage, role, run_id = tr.get(STAGE_KEY, ""), tr.get(ROLE_KEY, ""), tr.get(RUN_KEY, "")
        meta = run = None
        if hc.STAGE_RE.fullmatch(stage or ""):
            meta, run = find_run(stage, role, run_id)
        if meta is None:
            out["notes"].append(f"no run record of stage {stage or '?'}, role {role or '?'}, run {run_id or '?'} in "
                                f"this machine's hub homes: the commit was made elsewhere or the stage was deleted")
            out["agents"].append({"stage": stage or None, "role": role or None, "run": run_id or None})
        else:
            if run is None:
                out["notes"].append(f"run {run_id or '?'} is not among the role's recorded runs: the role's only agent "
                                    "is shown")
            out["agents"].append(describe(meta, run, info["committed"], info))
        return out
    found = guesses(info, repo)
    if not found:
        out["source"] = "none"
        out["notes"].append("not an agent commit as far as this machine knows: no Delamain trailers, and no agent run of this repository on this "
                            "machine covers its time with a reflog entry or a branch that contains it")
        return out
    out["source"] = found[0][3]
    for meta, run, how, strength in found:
        d = describe(meta, run, info["committed"], info)
        d["guess"] = f"{strength.upper()} — no Delamain trailers; {how}" if not out["agents"] else f"{strength}: {how}"
        out["agents"].append(d)
    return out


def render(res: dict) -> str:
    c = res["commit"]
    out = [f"commit {c['sha'][:12]} {c['committed'][:16].replace('T', ' ')} {c['author']}: {c['subject'][:80]}"]
    if res["line"]:
        out[0] = f"{res['line']} <- {out[0]}"
    if res["source"] == "trailers":
        out.append("agent commit (trailers " + ", ".join(f"{k.split('-', 1)[1]} {v}" for k, v in res["trailers"].items())
                   + ")")
    elif res["source"] == "none":
        out += [f"  {n}" for n in res["notes"]]
        return "\n".join(out)
    for i, a in enumerate(res["agents"]):
        run = f"run {a.get('run') or '?'}"
        if i:  # the first guess in full, the others in a line each
            out.append(f"  also: stage {a['stage']}, role {a['role']}, {run} — {a['guess']}")
            continue
        if a.get("guess"):
            out.append(a["guess"])
        if "agent_dir" not in a:
            continue
        run += f" ({a['run_kind']} at {a['run_at']})" if a.get("run_at") else ""
        mins = int(JOURNAL_WINDOW.total_seconds() // 60)
        out.append(f"  stage {a['stage']}, role {a['role']} (tag {a['tag']}), {run}")
        out.append(f"  engine {a['engine']}, model {a['model'] or '?'}{', effort ' + a['effort'] if a['effort'] else ''}")
        out.append(f"  brief      {a['brief'] or '— not found'}")
        out.append(f"  report     " + (f"{a['report']}{'' if a['report_exists'] else ' (not written, or moved)'}"
                                     if a["report"] else "— not recorded"))
        out.append(f"  session    {a['session_id'] or '— not recorded'}")
        out.append(f"  transcript {a['transcript'] or '— not on this machine'}")
        out.append(f"  agent dir  {a['agent_dir']}")
        if a["journal"]:
            out.append(f"  journal (±{mins} min, tag {a['tag']}):")
            out += [f"    {ln[:150]}" for ln in a["journal"]]
            if a["journal_more"]:
                out.append(f"    … {a['journal_more']} more of the tag in the window (the journal files have them)")
        else:
            out.append(f"  journal    no lines of {a['tag']} within ±{mins} min")
        out += [f"  note: {n}" for n in a["notes"]]
    out += [f"note: {n}" for n in res["notes"]]
    return "\n".join(out)


def cmd_why(a) -> int:
    res = why(a.target, Path(a.cwd or os.getcwd()).resolve())
    if a.json:
        print(json.dumps(res, ensure_ascii=False, indent=1))
    else:
        print(render(res))
    return 0
