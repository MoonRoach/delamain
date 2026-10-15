"""Reviewer choice for `hub reviewer`: which reviewer to start for a change, and exactly how.

The list is the setting AGENT_HUB_REVIEWERS — a JSON list, first available entry wins — read from the environment,
a repository's .agent-hub/config.json or the hub home's config.json (the usual order, see hubcore.setting). Entry:

  {"name": "my-review-skill", "kind": "skill", "skill": "my-review-skill",
   "check": "my-limits --ok", "until": "2026-12-31", "for": ["code", "risky"]}
  {"name": "agent", "kind": "agent", "model": "opus", "effort": "high"}

  name    required, unique; becomes the role `review-<name>` of an `agent` reviewer
  kind    required: `agent` (an ordinary `agent spawn`) or `skill` (a reviewer skill the user plugged in)
  skill   kind skill, required: the skill's name
  model, effort   kind agent: default from AGENT_HUB_REVIEW_MODEL (opus) and AGENT_HUB_REVIEW_EFFORT (high)
  check   optional shell command, exit 0 = available now; run in the hub home (never in the repository), with a
          timeout, and never taken from a repository's config (a cloned repository must not run commands through
          the hub): such an entry is skipped
  until   optional YYYY-MM-DD: available through that day, not after
  for     optional list of change classes the entry serves; absent = every class

The change's author — who really wrote it, not which host runs `hub reviewer` — comes from `--author` (a role of the
stage, or `engine[/model]`). A `check` sees it as AGENT_HUB_REVIEW_AUTHOR_ENGINE and AGENT_HUB_REVIEW_AUTHOR_MODEL
(both removed from its environment when the author is unknown); the built-in default entry takes the other engine.

A broken entry is reported on stderr and skipped; a list with no valid entry gives the built-in default, one
`agent` entry. Every value that reaches the line the hub is told to run, or the text it reads — name, skill, model,
effort, change classes — is checked against a strict pattern, whichever layer it comes from.
"""
from __future__ import annotations

import datetime as dt
import json
import os
import math
import re
import shlex
import shutil
import signal
import subprocess
import tempfile
from pathlib import Path
from typing import Optional

import hubcore as hc
import engines

SETTING = "AGENT_HUB_REVIEWERS"
AUTHOR_ENGINE_VAR, AUTHOR_MODEL_VAR = "AGENT_HUB_REVIEW_AUTHOR_ENGINE", "AGENT_HUB_REVIEW_AUTHOR_MODEL"
MODEL_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:@\[\]/-]{0,99}")
KINDS = ("agent", "skill")
FIELDS = ("name", "kind", "skill", "model", "effort", "check", "until", "for", "engine")
NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")                       # name, change class: 64 at most
SKILL_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}(?::[A-Za-z0-9][A-Za-z0-9._-]{0,63})?")  # skill, plugin:skill
SHOWN = 30  # characters of a rejected key or value that are echoed back: enough to find it, too few to carry text
DATE_RE = re.compile(r"\d{4}-\d{2}-\d{2}")
DEFAULT_MODEL, DEFAULT_EFFORT = "opus", "high"
CHECK_TIMEOUT_S = 10.0  # $AGENT_HUB_REVIEW_CHECK_TIMEOUT (seconds) overrides it; the tests use that
OUTPUT_CHARS = 300


def show(value, limit: int = SHOWN) -> str:
    """A value of a config file as it may be echoed: escaped (repr) and cut."""
    text = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False, default=str)
    return repr(text[:limit]) + ("…" if len(text) > limit else "")


class Entry:
    """One valid reviewer entry. model/effort are filled in for kind agent (settings supply the defaults)."""

    def __init__(self, index: int, raw: dict):
        self.index = index
        self.name = raw["name"]
        self.kind = raw["kind"]
        self.skill = raw.get("skill")
        self.model = raw.get("model")
        self.effort = raw.get("effort")
        self.engine = raw.get("engine") or engines.selected()
        self.explicit_engine = "engine" in raw
        self.check = raw.get("check")
        self.until = raw.get("until")
        self.classes = raw.get("for")

    def as_dict(self) -> dict:
        out = {"name": self.name, "kind": self.kind}
        if self.kind == "agent" and (self.explicit_engine or self.engine == "codex"):
            out["engine"] = self.engine
        for key, value in (("skill", self.skill), ("model", self.model), ("effort", self.effort),
                           ("check", self.check), ("until", self.until), ("for", self.classes)):
            if value:
                out[key] = value
        return out


class Verdict:
    """ran: the entry's `check` command was run. Only then is its text reported (--json): a command that was never
    run — a repository's, or one an `until` / class mismatch passed over — is not the hub's to repeat."""

    def __init__(self, entry: Entry, available: bool, why: str, output: str = "", ran: bool = False):
        self.entry, self.available, self.why, self.output, self.ran = entry, available, why, output, ran


class Loaded:
    """The parsed list: valid entries in order, the problems found, and which layer the list came from."""

    def __init__(self, entries: list, problems: list, origin: str):
        self.entries, self.problems, self.origin = entries, problems, origin


class Author:
    """Who wrote the change: engine (claude | codex) and, when known, the model; `source` says where it was read."""

    def __init__(self, engine: str, model: Optional[str], source: str):
        self.engine, self.model, self.source = engine, model, source

    def __str__(self) -> str:
        return f"{self.engine}/{self.model}" if self.model else self.engine

    def env(self) -> dict:
        return {AUTHOR_ENGINE_VAR: self.engine, AUTHOR_MODEL_VAR: self.model or ""}

    def as_dict(self) -> dict:
        return {"engine": self.engine, "model": self.model, "source": self.source}


def parse_author(spec: str, stage: Optional[str] = None) -> Author:
    """`--author` as an Author: `claude` / `codex`, `engine/model`, or a role of the stage (its agent's meta.json
    gives the engine — absent means Claude, as everywhere — and the model it ran with). UsageError when it is none
    of them: a wrong author must not quietly become the host."""
    spec = (spec or "").strip()
    if "/" in spec:
        engine, _, model = spec.partition("/")
        if engine not in engines.ENGINES:
            raise hc.UsageError(f"--author {show(spec)}: the engine before '/' is one of {', '.join(engines.ENGINES)}")
        if not MODEL_RE.fullmatch(model):
            raise hc.UsageError(f"--author {show(spec)}: the model after '/' is letters, digits and . _ : @ [ ] / - only")
        return Author(engine, model, "--author")
    if spec in engines.ENGINES:
        return Author(spec, None, "--author")
    if not stage:
        raise hc.UsageError(f"--author {show(spec)}: not an engine (claude, codex, claude/MODEL) and there is no stage "
                            "to look a role up in — pass --stage or set HUB_STAGE")
    if not NAME_RE.fullmatch(spec):
        raise hc.UsageError(f"--author {show(spec)}: neither an engine[/model] nor a role name")
    path = hc.root() / hc.check_stage(stage) / "agents" / spec / "meta.json"
    try:
        meta = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        raise hc.UsageError(f"--author {show(spec)}: no agent with that role in stage {stage} ({path} is missing or "
                            "unreadable); use engine[/model] if the author is not an agent of this stage") from None
    if not isinstance(meta, dict):
        raise hc.UsageError(f"--author {show(spec)}: {path} is not a JSON object")
    engine = meta.get("engine") or "claude"
    if engine not in engines.ENGINES:
        raise hc.UsageError(f"--author {show(spec)}: {path} names engine {show(engine)}")
    model = meta.get("resolved_model") or meta.get("model")
    model = model if isinstance(model, str) and MODEL_RE.fullmatch(model) else None
    return Author(engine, model, f"role {spec}")


# ---------------------------------------------------------------- reading the list

def _review_defaults(cwd=None, engine="claude") -> tuple:
    """(model, effort) of an `agent` reviewer that names none: AGENT_HUB_REVIEW_MODEL / _EFFORT, else opus / high."""
    # Review is judgement work. Do not inherit a Sol implementation default or
    # the standalone CLI's ordinary-work model for a Codex reviewer.
    default_model = DEFAULT_MODEL if engine == "claude" else "gpt-6-astra"
    model = (hc.setting("AGENT_HUB_REVIEW_MODEL", cwd=cwd) or default_model or "").strip() or None
    effort = (hc.setting("AGENT_HUB_REVIEW_EFFORT", cwd=cwd) or DEFAULT_EFFORT).strip()
    problem = (hc.model_problem(model, cwd) if engine == "claude" else engines.model_problem(model, cwd)) if model else None
    if problem:
        hc.warn(f"AGENT_HUB_REVIEW_MODEL={show(model)}: {problem}; using {DEFAULT_MODEL}")
        model = default_model
    efforts = hc.EFFORTS if engine == "claude" else engines.CODEX_EFFORTS
    if effort not in efforts:
        hc.warn(f"AGENT_HUB_REVIEW_EFFORT={show(effort)}: one of {', '.join(hc.EFFORTS)}; using {DEFAULT_EFFORT}")
        effort = DEFAULT_EFFORT
    return model, effort


def _validate(item, seen: set, cwd=None) -> dict:
    """The entry as a dict, or ValueError with the reason."""
    if not isinstance(item, dict):
        raise ValueError("not a JSON object")
    item = {k: v for k, v in item.items() if not str(k).startswith("_")}  # "_comment" and the like
    unknown = sorted(set(item) - set(FIELDS))
    if unknown:
        raise ValueError(f"unknown field {', '.join(show(u) for u in unknown[:5])}"
                         f"{' …' if len(unknown) > 5 else ''} (known: {', '.join(FIELDS)})")
    name = item.get("name")
    if not isinstance(name, str) or not NAME_RE.fullmatch(name):
        raise ValueError("`name` is required: letters, digits, '.', '_' and '-' only")
    if name in seen:
        raise ValueError(f"duplicate name {show(name)}")
    kind = item.get("kind")
    if kind not in KINDS:
        raise ValueError(f"`kind` is required: one of {', '.join(KINDS)}")
    if kind == "skill":
        if not isinstance(item.get("skill"), str) or not SKILL_RE.fullmatch(item["skill"]):
            raise ValueError("kind skill needs `skill`, the skill's name (letters, digits, '.', '_', '-', and one ':' "
                             "for plugin:skill)")
        for field in ("model", "effort", "engine"):
            if field in item:
                raise ValueError(f"`{field}` is for kind agent")
    else:
        engine = item.get("engine") or engines.selected(cwd=cwd)
        if engine not in engines.ENGINES:
            raise ValueError("`engine` must be claude or codex")
        if "skill" in item:
            raise ValueError("`skill` is for kind skill")
        if "model" in item:
            problem = hc.model_problem(item["model"], cwd) if engine == "claude" else engines.model_problem(item["model"], cwd)
            if problem:
                raise ValueError(f"`model` must be {problem}")
        if "effort" in item and item["effort"] not in (hc.EFFORTS if engine == "claude" else engines.CODEX_EFFORTS):
            raise ValueError(f"`effort` must be one of {', '.join(hc.EFFORTS)}")
    if "check" in item and (not isinstance(item["check"], str) or not item["check"].strip()):
        raise ValueError("`check` must be a non-empty shell command")
    if "until" in item:
        until = item["until"]
        try:
            if not isinstance(until, str) or not DATE_RE.fullmatch(until):
                raise ValueError
            dt.date.fromisoformat(until)
        except ValueError:
            raise ValueError(f"`until` must be a date YYYY-MM-DD, got {show(until)}") from None
    if "for" in item:
        classes = item["for"]
        if (not isinstance(classes, list) or not classes
                or not all(isinstance(c, str) and NAME_RE.fullmatch(c) for c in classes)):
            raise ValueError("`for` must be a non-empty list of change classes — letters, digits, '.', '_' and '-' "
                             "only — e.g. [\"code\", \"risky\"]")
    return item


def load(cwd=None, author: Optional[Author] = None) -> Loaded:
    """Parse AGENT_HUB_REVIEWERS. Problems are collected (and reported by the caller), never raised. With a known
    author the built-in default entry (no valid list) is the other engine's reviewer — a Codex change gets Claude,
    a Claude change gets Codex when the codex CLI is installed — so the default is never the author's own engine."""
    raw, origin = hc.setting_origin(SETTING, cwd=cwd)
    problems: list = []
    data = None
    if raw:
        try:
            data = json.loads(raw)
            if not isinstance(data, list):
                raise ValueError("it must be a JSON list of entries")
        except ValueError as e:
            problems.append(f"{SETTING}: {e}")
            data = None
    entries: list = []
    if data is not None:
        seen: set = set()
        for i, item in enumerate(data, 1):
            label = item.get("name") if isinstance(item, dict) and isinstance(item.get("name"), str) else None
            if label is not None and not NAME_RE.fullmatch(label):
                label = show(label)  # not a valid name: shown escaped and cut, never raw
            try:
                clean = _validate(item, seen, cwd)
            except ValueError as e:
                problems.append(f"{SETTING} entry {i}{f' ({label})' if label else ''}: {e}; skipped")
                continue
            seen.add(clean["name"])
            entries.append(Entry(i, clean))
        if not entries:
            problems.append(f"{SETTING}: no valid entry; using the built-in default (one `agent` reviewer)")
    if not entries:
        raw_default = {"name": "agent", "kind": "agent"}
        if author and author.engine == "codex":
            raw_default["engine"] = "claude"
        elif author and author.engine == "claude" and shutil.which(hc.setting("CODEX_BIN", cwd=cwd) or "codex"):
            raw_default["engine"] = "codex"
        entries, origin = [Entry(1, raw_default)], "default"
    for e in entries:
        if e.kind == "agent":
            model, effort = _review_defaults(cwd, e.engine)
            e.model, e.effort = e.model or model, e.effort or effort
    return Loaded(entries, problems, origin)


# ---------------------------------------------------------------- availability

_TIMEOUT_WARNED: set = set()


def _check_timeout() -> float:
    """CHECK_TIMEOUT_S, or $AGENT_HUB_REVIEW_CHECK_TIMEOUT when it is a finite number of seconds above 0."""
    raw = os.environ.get("AGENT_HUB_REVIEW_CHECK_TIMEOUT")
    if not raw:
        return CHECK_TIMEOUT_S
    if raw in _TIMEOUT_WARNED:
        return CHECK_TIMEOUT_S
    try:
        value = float(raw)
        if not math.isfinite(value) or value <= 0:
            raise ValueError
        return value
    except ValueError:
        _TIMEOUT_WARNED.add(raw)  # once per process, not once per checked entry
        hc.warn(f"AGENT_HUB_REVIEW_CHECK_TIMEOUT={show(raw)} is not a finite number of seconds above 0; "
                f"using {CHECK_TIMEOUT_S:g}")
        return CHECK_TIMEOUT_S


def _check_dir() -> Path:
    """Where a `check` runs: the hub home, never the repository the hub happens to be in — a command such as
    `make quota` or `./quota-ok` would run that repository's code. The user's home if there is no hub home yet."""
    home = hc.root()
    return home if home.is_dir() else Path.home()


def check_env(author: Optional[Author]) -> dict:
    """The environment of a `check`: the hub's own, with the author variables set from --author — or removed when the
    author is unknown, so a value left in the caller's shell never passes for it."""
    env = {k: v for k, v in os.environ.items() if k not in (AUTHOR_ENGINE_VAR, AUTHOR_MODEL_VAR)}
    if author:
        env.update(author.env())
    return env


def run_check(command: str, timeout: float, env: Optional[dict] = None) -> tuple:
    """(exit code or None, output) of a `check` command, run in the hub home in its own process group. The verdict
    is the exit of the shell itself; its output goes to a file, so a child that keeps the output open after the shell
    exited cannot hold the answer up. On the timeout the whole group is killed."""
    with tempfile.TemporaryFile() as out:
        proc = subprocess.Popen(["/bin/sh", "-c", command], stdin=subprocess.DEVNULL, stdout=out,
                                stderr=subprocess.STDOUT, start_new_session=True, cwd=_check_dir(), env=env)
        code: Optional[int]
        try:
            code = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                proc.kill()
            proc.wait()
            code = None
        out.seek(0)
        return code, out.read(4 * OUTPUT_CHARS).decode("utf-8", errors="replace").strip()


def _short(text: str) -> str:
    text = " ".join(text.split())
    return text if len(text) <= OUTPUT_CHARS else text[:OUTPUT_CHARS - 1] + "…"


def judge(entry: Entry, change_class: Optional[str], origin: str, author: Optional[Author] = None) -> Verdict:
    """Whether the entry can review a change of this class now. The cheap tests come first; the `check` command
    runs only for an entry that passed them."""
    if entry.until and hc.now().date() > dt.date.fromisoformat(entry.until):
        return Verdict(entry, False, f"until {entry.until} has passed")
    if change_class and entry.classes and change_class.strip().lower() not in {c.strip().lower() for c in entry.classes}:
        return Verdict(entry, False, f"not for class {show(change_class)} (it serves {', '.join(entry.classes)})")
    if entry.check:
        if origin == "project":
            hc.warn(f"{SETTING} entry {entry.index} ({entry.name}): `check` in a repository's config is never run "
                     "(a cloned repository must not run commands through the hub); skipped — set the list in the "
                     "environment or in the hub home's config.json")
            return Verdict(entry, False, "its `check` comes from a repository's config and is never run")
        timeout = _check_timeout()
        try:
            code, out = run_check(entry.check, timeout, check_env(author))
        except OSError as e:
            return Verdict(entry, False, f"check could not run: {e}")
        if code is None:
            return Verdict(entry, False, f"check did not finish in {timeout:g} s", _short(out), ran=True)
        if code != 0:
            return Verdict(entry, False, f"check exited {code}", _short(out), ran=True)
        return Verdict(entry, True, "check exited 0", _short(out), ran=True)
    return Verdict(entry, True, "no check")


def walk(loaded: Loaded, change_class: Optional[str], every: bool = False, author: Optional[Author] = None) -> tuple:
    """(verdicts, chosen): the entries judged in order, up to and including the first available one — or all of
    them with `every`. chosen is the first available verdict, or None."""
    verdicts, chosen = [], None
    for entry in loaded.entries:
        v = judge(entry, change_class, loaded.origin, author)
        verdicts.append(v)
        if v.available and chosen is None:
            chosen = v
            if not every:
                break
    return verdicts, chosen


# ---------------------------------------------------------------- how to start it

def start_line(entry: Entry, stage: str | None = None) -> str:
    """What the hub does to start this reviewer. An `agent` reviewer only reads: no --worktree. With a stage the
    `agent spawn` line names it, so the reviewer joins that stage whatever the shell's HUB_STAGE is."""
    if entry.kind == "skill":
        return (f"load skill `{entry.skill}`; give it the brief file, the repository, the base sha and the head ref "
                "(the skill reviewer contract: docs/reviewers.md)")
    effort = f" --effort {shlex.quote(entry.effort)}"
    engine = f" --engine {entry.engine}" if entry.explicit_engine or entry.engine == "codex" else ""
    sandbox = " --sandbox read-only" if entry.engine == "codex" else ""
    model = f" --model {shlex.quote(entry.model)}" if entry.model else ""
    in_stage = f" --stage {shlex.quote(stage)}" if stage else ""
    return (f"agent spawn --role {shlex.quote('review-' + entry.name)} --cwd <REPO>{engine}{sandbox}{model}"
            f"{effort}{in_stage} --brief <BRIEF>")


def describe(entry: Entry) -> str:
    return f"skill {entry.skill}" if entry.kind == "skill" else f"agent {entry.model}/{entry.effort}"


def entry_json(v: Verdict) -> dict:
    out = v.entry.as_dict()
    if not v.ran:
        out.pop("check", None)
    out.update({"available": v.available, "why": v.why})
    return out
