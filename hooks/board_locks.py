#!/usr/bin/env python3
"""PreToolUse(Bash) hook: refuse an action on a shared resource under another session's lock.

Text rules ("ask the merge owner first") do not stop a busy agent; the lock board (<hub home>/board.md,
CLI `lock`) makes the holder explicit and this hook enforces it.

Built-in actions (per shell segment; text inside quotes, heredocs and echo/printf/cat is not a command):
  merge into main   gh pr merge …; glab mr merge|accept …;
                    gh api / glab api with -X PUT …/pulls/<n>/merge or …/merge_requests/<n>/merge;
                    git push <remote> … <ref> where the target branch is protected (main, master) -> main-merge
Project resources (deploy windows, shared environments, migration heads — any name the project chooses): the
rules of <repo>/.agent-hub/lock-rules.json of the repository the command runs in (found from the cwd, `cd` and
`git -C`), plus <hub home>/lock-rules.json (or $AGENT_HUB_LOCK_RULES); rules of both apply, the repository's first.
Format and validation: bin/lockrules.py; `lock rules` shows, edits and checks them.
  `match` is a Python regex searched in the segment's words joined by single spaces.
  A resource with no rule is informational; nothing is refused for it.

Decision: an active lock of a relevant kind held by another session_id -> deny with holder, until,
reason. Own lock, expired lock, no lock -> no decision. `# lock-ok: <reason>` anywhere in the
command -> no decision. Fail-open: any own error (broken board, bad JSON, import failure) exits 0
without a decision. A broken lock-rules.json (bad JSON, a rule without `match`, a bad regex, `kinds` that is not
a non-empty list of resource names or names an undeclared one) does NOT switch the guard off: that file is skipped, the built-in rules and
the other file still apply, and a warning goes to stderr and to the user (`systemMessage`) on every Bash call
until it is fixed. The same warning is given for a configured rules path that is a dangling symlink, and for
$AGENT_HUB_LOCK_RULES naming a missing file.

Repo scoping: a lock guards one repo (default "*": every repo). The action's repo is taken from
`-R/--repo`, a `repos/<owner>/<name>` or `projects/<group%2Fname>` API path, `git -C`/`cd` in the
command, or the event cwd: the name of the enclosing git repository (a worktree resolves to its main
repository). Unknown repo matches every lock (conservative).
"""
from __future__ import annotations

if __name__ == "__main__":  # fail-safe first, before anything that can fail: see hooks/failsafe.py
    try:
        import failsafe

        failsafe.install()
    except Exception:  # noqa: BLE001 — without it the hook is as it was
        pass

import json
import os
import re
import shlex
import sys
from pathlib import Path
from urllib.parse import unquote

from polling_guard import strip_heredocs

ESCAPE_HATCH = re.compile(r"#\s*lock-ok\b")
_PRINTING = ("echo", "printf", "cat")
_PREFIX_WORDS = ("command", "env", "sudo", "time", "nohup", "exec")
_PUNCT = set(";&|()<>")


def plugin_bin() -> str:
    root = os.environ.get("PLUGIN_ROOT") or os.environ.get("CLAUDE_PLUGIN_ROOT") or os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
    return os.path.join(root, "bin")


def segments(command: str) -> list[list[str]]:
    """Simple commands of a shell line as token lists; quoted text stays inside its token."""
    command = strip_heredocs(command, preserve_shell=False)
    try:
        lex = shlex.shlex(command, posix=True, punctuation_chars=";&|()<>")
        lex.whitespace_split = True
        lex.commenters = "#"
        tokens = list(lex)
    except ValueError:  # unbalanced quotes: fall back to a crude split
        tokens = []
        for part in re.split(r"(\|\||&&|[;|()\n])", command):
            tokens += part.split() if part.strip() and not re.fullmatch(r"\|\||&&|[;|()\n]", part) else [";"]
    segs, cur = [], []
    for t in tokens:
        if t and set(t) <= _PUNCT:
            if cur:
                segs.append(cur)
            cur = []
        else:
            cur.append(t)
    if cur:
        segs.append(cur)
    out = []
    for seg in segs:
        seg = _strip_prefix(seg)
        if not seg:
            continue
        # bash -c '...' / zsh -c: recurse into the script
        if os.path.basename(seg[0]) in ("bash", "sh", "zsh") and "-c" in seg:
            i = seg.index("-c")
            if i + 1 < len(seg):
                out += segments(seg[i + 1])
            continue
        out.append(seg)
    return out


def _strip_prefix(seg: list[str]) -> list[str]:
    i = 0
    while i < len(seg):
        t = seg[i]
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", t):
            i += 1
        elif t in _PREFIX_WORDS:
            i += 1
        elif t in ("timeout", "gtimeout"):
            i += 1
            while i < len(seg) and (seg[i].startswith("-") or re.fullmatch(r"[\d.]+[smhd]?", seg[i])):
                i += 1
        else:
            break
    return seg[i:]


def _api_method(seg: list[str]) -> str:
    """HTTP method of a `gh api` / `glab api` call: explicit -X/--method, else POST if fields given, else GET."""
    for i, t in enumerate(seg):
        if t in ("-X", "--method") and i + 1 < len(seg):
            return seg[i + 1].upper()
        m = re.match(r"^(?:-X|--method=)(\w+)$", t)
        if m:
            return m.group(1).upper()
    if any(t in ("-f", "-F", "--field", "--raw-field", "--input") or t.startswith(("--field=", "--raw-field="))
           for t in seg):
        return "POST"
    return "GET"


def _git_repo_name(path: str) -> str | None:
    """Name of the git repository enclosing `path`; a worktree resolves to its main repository. The same function
    names the repository of `lock take` (hubcore.default_repo), so a lock and the commands it guards agree."""
    if plugin_bin() not in sys.path:
        sys.path.insert(0, plugin_bin())
    import hubcore  # noqa: E402

    return hubcore.git_repo_name(path)


def _repo_of(seg: list[str], cwd: str | None) -> str | None:
    for i, t in enumerate(seg):
        if t in ("-R", "--repo") and i + 1 < len(seg):
            return seg[i + 1].rstrip("/").split("/")[-1]
        if t.startswith("--repo="):
            return t.split("=", 1)[1].rstrip("/").split("/")[-1]
        m = re.search(r"(?:^|/)repos/[^/\s]+/([^/\s]+)", t)
        if m and not m.group(1).startswith((":", "{")):
            return m.group(1)
        m = re.search(r"projects/([^/\s]+)", t)
        if m and not m.group(1).startswith(":"):
            proj = unquote(m.group(1))
            if not proj.isdigit():
                return proj.rstrip("/").split("/")[-1]
        if t == "-C" and seg[0] == "git" and i + 1 < len(seg):
            return _git_repo_name(seg[i + 1])
    return _git_repo_name(cwd) if cwd else None


def _lockrules():
    sys.path.insert(0, plugin_bin())
    import lockrules  # noqa: E402

    return lockrules


WARNINGS: list = []


def rule_files(cwd: str | None) -> list[tuple[str, bool]]:
    """The lock-rules.json files that apply to a command run in `cwd` (see bin/lockrules.py)."""
    return _lockrules().files(cwd)


def load_rules(cwd: str | None = None) -> dict:
    """Rules of every applicable file together, the repository's first, then the hub home's (bin/lockrules.py). A
    file that cannot be used is skipped with a warning (WARNINGS); the others and the built-ins still apply."""
    out = _lockrules().load(cwd)
    for msg in out["warnings"]:
        if msg not in WARNINGS:
            WARNINGS.append(msg)
    return out


def _seg_cwd(seg: list[str], cwd: str | None) -> str | None:
    """Directory the segment acts in: `git -C DIR`, else the (cd-tracked) cwd."""
    if seg and seg[0] == "git" and "-C" in seg:
        i = seg.index("-C")
        if i + 1 < len(seg):
            return os.path.join(cwd or "", os.path.expanduser(seg[i + 1]))
    return cwd


def classify(seg: list[str], rules: dict) -> tuple[str, tuple[str, ...]] | None:
    """(action description, lock kinds it needs) or None for anything else."""
    if not seg:
        return None
    prog = os.path.basename(seg[0])
    args = seg[1:]
    if any(a in ("-h", "--help") for a in args):
        return None
    joined = " ".join(seg)
    for r in rules["rules"]:
        if r["re"].search(joined):
            return (r["action"], r["kinds"])
    if prog == "gh" and len(args) >= 2 and args[0] == "pr" and args[1] == "merge":
        return ("merge a PR (gh pr merge)", ("main-merge",))
    if prog == "glab" and len(args) >= 2 and args[0] == "mr" and args[1] in ("merge", "accept"):
        return ("merge an MR (glab mr merge)", ("main-merge",))
    if prog in ("gh", "glab") and args and args[0] == "api":
        method = _api_method(args)
        tail = " ".join(args) + " "
        if method == "PUT" and re.search(r"(?:pulls|merge_requests)/\d+/merge(?:$|[?\s\"'])", tail):
            return ("merge a PR/MR through the API", ("main-merge",))
        return None
    if prog == "git" and "push" in args:
        after = args[args.index("push") + 1:]
        if any(a in ("-n", "--dry-run") for a in after):
            return None
        positional = [a for a in after if not a.startswith("-")]
        protected = set(rules["protected_branches"])
        for ref in positional[1:]:
            target = ref.split(":", 1)[1] if ":" in ref else ref
            target = target.lstrip("+")
            if target.startswith("refs/heads/"):
                target = target[len("refs/heads/"):]
            if target in protected:
                return (f"push to {target}", ("main-merge",))
    return None


def blocking_lock(kinds, repo, session_id, locks, board):
    at = board.now()
    for kind in kinds:
        for rec in locks:
            if rec.get("kind") != kind or not board.repo_matches(rec, repo):
                continue
            if not board.is_active(rec, at):
                continue
            if session_id and rec.get("session_id") == session_id:
                continue
            return rec
    return None


def decide(event: dict, board, rules: dict | None = None) -> str | None:
    """Deny reason, or None for no decision."""
    if event.get("tool_name") != "Bash":
        return None
    ti = event.get("tool_input") or {}
    command = ti.get("command")
    if not isinstance(command, str) or ESCAPE_HATCH.search(command):
        return None
    cwd = event.get("cwd")
    hits = []
    for seg in segments(command):
        if os.path.basename(seg[0]) in _PRINTING:
            continue
        if seg[0] == "cd" and len(seg) > 1:
            cwd = os.path.join(cwd or "", os.path.expanduser(seg[1]))
            continue
        c = classify(seg, rules if rules is not None else load_rules(_seg_cwd(seg, cwd)))
        if c:
            hits.append((c, _repo_of(seg, cwd)))
    if not hits:
        return None
    locks = board.load()  # BoardError -> caller fails open
    sid = event.get("session_id") or ""
    for (action, kinds), repo in hits:
        rec = blocking_lock(kinds, repo, sid, locks, board)
        if rec:
            holder = rec.get("owner_name") or "?"
            hid = rec.get("session_id") or "no session_id recorded"
            return (
                f"Command refused by the board_locks hook: {action}.\n"
                f"The resource is under another session's `{rec['kind']}` lock ({rec.get('repo') or '*'}): held by "
                f"\"{holder}\" ({hid}) until {rec['until']}. Reason: {rec.get('why') or '—'}.\n"
                f"Message the holder (SendMessage to \"{holder}\") and wait for the answer; the board is "
                f"`lock list` ({board.BOARD}).\n"
                f"If you are the holder's successor — `lock take {rec['kind']} --force --until … --why …`. If the "
                "action certainly does not touch the resource, add `# lock-ok: <reason>` to the command; the reason "
                "stays in the transcript."
            )
    return None


def main() -> int:
    try:
        event = json.load(sys.stdin)
        sys.path.insert(0, plugin_bin())
        import hubcore  # noqa: E402

        hubcore.use_cwd(event.get("cwd") if isinstance(event, dict) else None)  # before board reads its path
        import board  # noqa: E402

        reason = decide(event, board)
    except Exception as e:  # fail-open: never break the user's sessions
        print(f"board_locks: fail-open ({type(e).__name__}: {e})" + "".join(" " + w for w in WARNINGS),
              file=sys.stderr)
        return 0
    out: dict = {}
    if WARNINGS:
        warning = "board_locks: " + " ".join(WARNINGS)
        print(warning, file=sys.stderr)
        out["systemMessage"] = warning
    if reason:
        out["hookSpecificOutput"] = {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    if out:
        print(json.dumps(out, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
