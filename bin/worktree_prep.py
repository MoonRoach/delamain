"""What a new agent worktree gets before the agent starts (`agent spawn --worktree`): a slot, the shared git-ignored
files of `.agents/linked` and the repository's own `.agents/prepare` script. The two file names are Delta's
(https://delta.dev/blog/escaping-the-tyranny-of-worktrees), so a repository prepared for Delta works unchanged.

- slot: a small integer (1, 2, …) per worktree, unique among the repository's live worktrees, stable for the life of the
  worktree. Recorded in `<git common dir>/delamain-worktrees.json` under a lock, so two concurrent spawns never get
  the same one; an entry whose directory is gone is dropped and its number is free again.
- `.agents/linked`: one relative path per line (`#` comments, blank lines ignored); each is symlinked in the worktree to
  the same path in the repository's primary checkout, which is where the git-ignored `.env` lives.
- `.agents/prepare`: an executable run once in the new worktree before the agent starts (cwd = the worktree root).
"""
from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
from pathlib import Path

import hubcore as hc

SLOTS_FILE = "delamain-worktrees.json"
LINKED = Path(".agents") / "linked"
PREPARE = Path(".agents") / "prepare"
DEFAULT_PREPARE_TIMEOUT = 300
TAIL_LINES = 15


class PrepareFailed(Exception):
    """`.agents/prepare` exited non-zero, timed out or could not be started; `tail` is the end of its log."""

    def __init__(self, why: str, tail: str):
        super().__init__(why)
        self.why, self.tail = why, tail


def common_dir(path: Path) -> Path | None:
    res = subprocess.run(["git", "-C", str(path), "rev-parse", "--path-format=absolute", "--git-common-dir"],
                         capture_output=True, text=True, env=hc.git_env())
    return Path(res.stdout.strip()) if res.returncode == 0 and res.stdout.strip() else None


def main_checkout(common: Path) -> Path | None:
    """The repository's primary worktree: the parent of `.git`. None when the git dir has another name (a bare
    repository, or `git init --separate-git-dir`: git itself does not know where the checkout is)."""
    return common.parent if common.name == ".git" else None


# ---------------------------------------------------------------- slots

def _load_slots(file: Path) -> dict:
    try:
        data = json.loads(file.read_text(encoding="utf-8"))
        if isinstance(data, dict):
            return {k: v for k, v in data.items() if isinstance(v, dict) and isinstance(v.get("slot"), int)}
    except FileNotFoundError:
        return {}
    except (OSError, ValueError):
        pass
    print(f"note: {file} is unreadable: worktree slots start afresh (the old file is kept as {file.name}.bad)",
          file=sys.stderr)
    try:
        os.replace(file, file.with_name(file.name + ".bad"))
    except OSError:
        pass
    return {}


def claim_slot(common: Path, wt: Path, created: bool) -> tuple[int, bool]:
    """(slot, prepared) of the worktree `wt`: its recorded slot, else the smallest number no live worktree of the
    repository holds (a worktree created by this spawn keeps the slot an earlier worktree at the same path had).
    `prepared` is False for a worktree created by this spawn (its prepare has not succeeded yet) and stays False until
    mark_prepared; a worktree met for the first time as "reused" (made by hand, or before slots
    existed) counts as prepared."""
    file, key = common / SLOTS_FILE, str(wt.resolve())
    with hc.Flock(common / (SLOTS_FILE + ".lock")):
        data = _load_slots(file)
        live = {k: v for k, v in data.items() if k == key or Path(k).is_dir()}
        entry = live.get(key)
        if entry is None:
            used = {v["slot"] for v in live.values()}
            slot = 1
            while slot in used:
                slot += 1
            entry = live[key] = {"slot": slot, "prepared": not created}
        elif created:
            # the directory was made again at a path with an old record (`git worktree remove`, then the same role
            # again): it is a new worktree, its prepare has not run
            entry["prepared"] = False
        if live != data:
            hc.atomic_write(file, json.dumps(live, indent=1, sort_keys=True) + "\n")
    return entry["slot"], bool(entry.get("prepared", True))


def mark_prepared(common: Path, wt: Path) -> None:
    file, key = common / SLOTS_FILE, str(wt.resolve())
    with hc.Flock(common / (SLOTS_FILE + ".lock")):
        data = _load_slots(file)
        if key in data and not data[key].get("prepared", True):
            data[key]["prepared"] = True
            hc.atomic_write(file, json.dumps(data, indent=1, sort_keys=True) + "\n")


# ---------------------------------------------------------------- .agents/linked

def read_linked(wt: Path) -> tuple[list[str], list[str]]:
    """(relative paths, complaints) of the worktree's .agents/linked; an absolute path, `..` or a path into .git is
    a complaint and is not linked."""
    try:
        text = (wt / LINKED).read_text(encoding="utf-8")
    except FileNotFoundError:
        return [], []
    except (OSError, ValueError) as e:
        return [], [f"{LINKED} is unreadable ({e}): nothing linked"]
    paths, bad = [], []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        rel = Path(line)
        parts = rel.parts
        if rel.is_absolute() or ".." in parts:
            bad.append(f"{LINKED}: {line!r} is not linked: only paths relative to the repository root, without `..`")
        elif parts and parts[0] == ".git":
            bad.append(f"{LINKED}: {line!r} is not linked: .git is git's own")
        elif line not in paths:
            paths.append(line)
    return paths, bad


def is_ignored(wt: Path, rel: str, src: Path) -> bool:
    """Whether git ignores `rel` in the worktree (a directory is tried with its trailing slash too). Only a definite
    "not ignored" answer (exit 1) says no: an error of git itself does not stop the link."""
    for name in ([rel, rel.rstrip("/") + "/"] if src.is_dir() else [rel]):
        res = subprocess.run(["git", "-C", str(wt), "check-ignore", "-q", "--", name], capture_output=True,
                             env=hc.git_env())
        if res.returncode != 1:
            return True
    return False


def link_shared(wt: Path, main: Path | None) -> list[str]:
    """Symlink every path of .agents/linked in `wt` to the same path of the primary checkout `main`. Returns what to
    tell the hub, one line each (`linked …`, `note: …`). Idempotent: a path that already is that link is silent. A path
    that exists in the worktree as a real file or directory, or links elsewhere, is reported and left alone; a path
    missing in the primary checkout is a note, not a failure."""
    paths, out = read_linked(wt)
    out = [f"note: {m}" for m in out]
    if not paths:
        return out
    if main is None or main.resolve() == wt.resolve():
        return out + [f"note: {LINKED}: the git dir of this repository is not `<checkout>/.git` (bare, or --separate-git-dir): no primary checkout to share from, nothing linked"]
    wt_real = wt.resolve()
    for rel in paths:
        src, dst = main / rel, wt / rel
        if not os.path.lexists(src):
            out.append(f"note: {rel} is not in the primary checkout {main}: not linked")
        elif os.path.islink(dst):
            if dst.resolve() != src.resolve():
                out.append(f"note: {rel} already links to {os.readlink(dst)}, not to {src}: left as it is")
        elif os.path.lexists(dst):
            out.append(f"note: {rel} exists in the worktree as a real {'directory' if dst.is_dir() else 'file'}: "
                       "not replaced by a link to the shared copy")
        elif not dst.parent.resolve().is_relative_to(wt_real):  # a directory of the path is a link leading out
            out.append(f"note: {rel}: its directory leads out of the worktree: not linked")
        elif not is_ignored(wt, rel, src):
            out.append(f"note: {rel} is not git-ignored in this repository: not linked (a link git sees would make "
                       "`git worktree remove` refuse and `git add -A` commit it); add it to .gitignore")
        else:
            try:
                dst.parent.mkdir(parents=True, exist_ok=True)
                os.symlink(src, dst)
            except OSError as e:
                out.append(f"note: {rel}: could not link ({e})")
            else:
                out.append(f"linked {rel} -> {src}")
    return out


# ---------------------------------------------------------------- .agents/prepare

def prepare_state(wt: Path) -> str:
    """"absent", "not-executable" or "ready" for the worktree's .agents/prepare."""
    script = wt / PREPARE
    if not script.is_file():
        return "absent"
    return "ready" if os.access(script, os.X_OK) else "not-executable"


def run_prepare(wt: Path, log: Path, env: dict, timeout_s: int) -> None:
    """Run the worktree's .agents/prepare (cwd = the worktree root, stdin closed, output to `log`) and wait for it;
    raise PrepareFailed on a non-zero exit, a timeout (its process group is killed) or a failure to start."""
    def tail() -> str:
        try:
            lines = log.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            return ""
        return "\n".join(lines[-TAIL_LINES:])

    with open(log, "wb") as out:
        try:
            proc = subprocess.Popen([str(wt / PREPARE)], cwd=wt, env=env, stdin=subprocess.DEVNULL, stdout=out,
                                    stderr=subprocess.STDOUT, start_new_session=True)
        except OSError as e:
            raise PrepareFailed(f"{PREPARE} could not be started ({e})", "") from None
        try:
            code = proc.wait(timeout=timeout_s)
        except subprocess.TimeoutExpired:
            for sig, grace in ((signal.SIGTERM, 5), (signal.SIGKILL, 5)):
                try:
                    os.killpg(proc.pid, sig)
                except ProcessLookupError:
                    break
                try:
                    proc.wait(timeout=grace)
                    break
                except subprocess.TimeoutExpired:
                    continue
            raise PrepareFailed(f"{PREPARE} did not finish in {timeout_s} s (AGENT_HUB_PREPARE_TIMEOUT), killed",
                                tail()) from None
    if code != 0:
        raise PrepareFailed(f"{PREPARE} exited with code {code}", tail())
