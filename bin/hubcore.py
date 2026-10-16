"""Shared helpers for the hub tools: jlog, jwait, roles, hub, agent, agent-top.

Layout under the hub home (where it is: home(); default ~/agent-hub):
  <stage>/coordinator/work/journal-YYYY-MM-DD.md   stage journal, one line per event:
                                                   "- HH:MM [tag] text" (hub time zone, see below)
  <stage>/roles.json                               role registry (tool `roles`)
  <stage>/agents/<role>/                           headless agents (tool `agent`)
  <stage>/questions.md                             owner-question register (tool `ask`)
  board.md                                         lock board (tool `lock`)
  .jwait-state/<caller>.json                       what jwait has already shown each caller

Time zone: $AGENT_HUB_TZ (an IANA name such as Europe/Berlin), else the system's local zone.
Python 3.10+ stdlib only.
"""
from __future__ import annotations

import contextlib
import datetime as dt
import fcntl
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
from pathlib import Path
from typing import NamedTuple, Optional

BIN = Path(os.path.dirname(os.path.realpath(__file__)))
DEFAULT_STAGE = "default"
STAGE_RE = re.compile(r"[a-z0-9][a-z0-9_-]*")
# "- 14:35 [hub-16] text"; the tag may hold spaces ("[qa-2 r5b]").
JOURNAL_LINE_RE = re.compile(r"^- (\d{1,2}:\d{2}) \[([^\]]+)\]\s?(.*)$")
CONFIG_DIRNAME = ".agent-hub"
EFFORTS = ("low", "medium", "high", "xhigh", "max")  # what `claude --effort` takes
MODEL_ALIASES = ("opus", "sonnet", "haiku", "fable")
# The oldest supported Claude Code CLI: it runs the agent-top mod (2.1.287) and resolves the aliases to the latest models
# (sonnet-5-5, opus-5-5, haiku-4-5, fable-5-1, as 2.1.285 did); an older CLI is unsupported and resolves the same aliases
# to older models. `haiku` is haiku-5-5 only from 2.1.296; the minimum is not raised for it, since both Haiku models take
# `--effort`. The plugin pins no ids: the alias follows the CLI.
MIN_CLI_VERSION = (2, 1, 287)
# Managed settings files, which win over every other settings file (Claude Code's settings precedence): macOS, Linux.
MANAGED_SETTINGS = (Path("/Library/Application Support/ClaudeCode/managed-settings.json"),
                    Path("/etc/claude-code/managed-settings.json"))
IDLE_CHECK_OFF_ENV = "AGENT_HUB_NO_IDLE_COMPACTION_CHECK"  # environment only, like NO_NAMING: scripted environments, tests
# A full model id, `claude-` plus letters, digits and . _ : @ [ ] - ("claude-opus-4-7[1m]", the Vertex id
# "claude-sonnet-4-5@20250929"): nothing a shell treats as syntax, so an id from a repository's config cannot carry a
# command into a line the hub runs; and a length cap, so a value cannot flood what the hub reads.
MODEL_ID_RE = re.compile(r"claude-[A-Za-z0-9._:@\[\]-]{1,100}")
MODEL_ALIAS_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")
# What an alias of AGENT_HUB_MODEL_MAP may stand for: any provider's model id (a Bedrock "us.anthropic.claude-…:0" or
# an inference-profile ARN, a Vertex "…@2025…", a `claude-…` id) — the same characters plus "/", no `claude-` prefix.
MODEL_VALUE_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:@\[\]/-]{0,199}")
# Settings that only the hub home's config.json may set: every tool sharing a hub home must agree on them.
HUB_WIDE_KEYS = ("AGENT_HUB_TZ", "AGENT_HUB_SEND_CAP", "AGENT_HUB_NIGHT", "AGENT_HUB_HANDOFF_MAX_BYTES",
                 "AGENT_HUB_JWAIT_MATCH", "AGENT_HUB_JWAIT_FOR", "AGENT_HUB_SCOPE_DIRS", "AGENT_HUB_GENERIC_STAGE_WORDS")
# Settings a repository's .agent-hub/config.json may set as well (the repository's value wins over the home's).
PROJECT_KEYS = ("AGENT_HUB_MODEL_MAP", "AGENT_HUB_DEFAULT_EFFORT", "AGENT_HUB_PERMISSION_MODE",
                "AGENT_HUB_DEFAULT_REPO", "AGENT_HUB_TAKE_MAIN_MERGE", "CLAUDE_BIN", "AGENT_INIT_TIMEOUT",
                "AGENT_HUB_BG_WAIT_CEILING_MS")
PROJECT_KEYS += ("AGENT_HUB_ENGINE", "CODEX_BIN", "AGENT_HUB_CODEX_MODEL_MAP", "AGENT_HUB_CODEX_DEFAULT_MODEL",
                 "AGENT_HUB_CODEX_PERMISSION_MODE", "AGENT_HUB_CODEX_HOOK_TRUST")
# Yes/no settings: a JSON boolean is accepted for them (read with truthy()).
BOOL_KEYS = ("AGENT_HUB_TAKE_MAIN_MERGE",)
# Status words: what the hub's digest jwait wakes on and what counts as an agent's clean ending. EXIT, ENDED and
# REVIEWED are the words `agent` itself writes when a run ends (EXIT: abnormally or killed; ENDED: normally, with a
# result but no status word of the agent's own; REVIEWED: the same for a review role), so they never count as the
# agent's own status. GRILLED is the report of a grilling session (`hub grill done`). $AGENT_HUB_JWAIT_MATCH adds alternatives (a regex) for a team whose scripts or briefs use other words.
STATUS_WORDS = r"\b(MERGED|STOP|DONE|BLOCKED|EXIT|QUESTION|ENDED|REVIEWED|GRILLED)\b|AWAITING ANSWER"
AGENT_END_WORDS = ("EXIT", "ENDED", "REVIEWED")
# How long one `jwait` waits when --for/--until is not given ($AGENT_HUB_JWAIT_FOR, a duration like 50m or 1h30m).
# The prompt cache of a session lives one hour: a wake after a longer sleep re-writes the whole context into it. Claude
# Code 2.1.299 also compacts a 200K+ conversation left idle ~54 minutes (idle_compaction_warning), and the old 55m wait
# always ended after that point; a hub that did not turn the compaction off would have woken up on a summary. 50m ends
# before it, and costs about one extra wake an hour, a turn that reads a warm cache.
DEFAULT_JWAIT_FOR = "50m"
# Claude Code's idle compaction (2.1.290+) starts at 200K tokens unless this raises the minimum; a detached `claude -p` worker
# (`agent spawn`/`agent send`) that waits on a `jwait` should never be compacted behind its hub's back (the owner forbids
# compaction), so it gets a minimum above any context window. The caller's own value wins. Older CLIs ignore the variable.
IDLE_COMPACT_ENV = "CLAUDE_CODE_IDLE_COMPACT_MIN_TOKENS"
IDLE_COMPACT_NEVER = "100000000"
MAX_JWAIT_FOR_S = 24 * 3600  # a longer value is a typo, and a huge one overflows the deadline's date
# Agent-discipline hooks (hooks/context_budget.py, polling_guard.py, delegation.py). The user's own limits —
# context budget and the delegation dial — come from the hub home only, so a cloned repository cannot loosen them;
# the polling guard is a team convention a repository may set; a repository's effort rules apply in addition to the
# user's, never instead (bin/subagent_rules.py evaluates both).
HUB_WIDE_KEYS += ("AGENT_HUB_CONTEXT_BUDGET", "AGENT_HUB_CONTEXT_WARN", "AGENT_HUB_CONTEXT_WARN_STEP",
                  "AGENT_HUB_CONTEXT_BLOCK", "AGENT_HUB_CONTEXT_BLOCK_TOOLS", "AGENT_HUB_CONTEXT_ESCAPE",
                  "AGENT_HUB_CONTEXT_TODO",
                  "AGENT_HUB_DELEGATION", "AGENT_HUB_DELEGATION_DEFAULT", "AGENT_HUB_DELEGATION_LEVELS",
                  "AGENT_HUB_DELEGATION_COMMON", "AGENT_HUB_DELEGATION_RULES",
                  "AGENT_HUB_STATE_DIR")
PROJECT_KEYS += ("AGENT_HUB_POLL_GUARD", "AGENT_HUB_POLL_MAX_SLEEP", "AGENT_HUB_POLL_MAX_BOUNDED_WAIT",
                 "AGENT_HUB_POLL_ESCAPE", "AGENT_HUB_CI_STATUS_DENY", "AGENT_HUB_CI_STATUS_ALLOW",
                 "AGENT_HUB_WAIT_HINT", "AGENT_HUB_EFFORT_RULES")
# Reviewers (bin/reviewers.py): the list, and the model and effort of a built-in `agent` reviewer. A repository may
# set them all; a `check` command in a repository's list is never run (see reviewers.py).
PROJECT_KEYS += ("AGENT_HUB_REVIEWERS", "AGENT_HUB_REVIEW_MODEL", "AGENT_HUB_REVIEW_EFFORT", "AGENT_HUB_REVIEW_HELPER_LINES")
# Spawn policy (bin/spawn_policy.py): the default effort per model is the repository's to set, like the default effort;
# what needs a reason and how large a context a resume may start from are the user's own limits (hub home only).
PROJECT_KEYS += ("AGENT_HUB_EFFORT_DEFAULTS",)
# MCP servers of a Claude agent (`agent spawn --mcp`): a repository may choose inherit or none, never a config file —
# a file's servers are commands the CLI starts without the approval a project's .mcp.json needs (bin/agent mcp_choice).
PROJECT_KEYS += ("AGENT_HUB_SPAWN_MCP",)
HUB_WIDE_KEYS += ("AGENT_HUB_REASON_MODELS", "AGENT_HUB_REASON_POLICY", "AGENT_HUB_RESUME_MAX_CTX")
# The scan guard (hooks/scan_guard.py) protects the machine's owner from macOS privacy prompts: a cloned repository must
# not switch it off, so it is the hub home's (and the environment's) to set.
HUB_WIDE_KEYS += ("AGENT_HUB_SCAN_GUARD", "AGENT_HUB_SCAN_ESCAPE")
BOOL_KEYS += ("AGENT_HUB_CONTEXT_BUDGET", "AGENT_HUB_POLL_GUARD", "AGENT_HUB_DELEGATION", "AGENT_HUB_SCAN_GUARD")
# Autopilot (bin/autopilot.py): hub home only — a cloned repository must not start background sessions or choose their
# permission mode.
HUB_WIDE_KEYS += ("AGENT_HUB_AUTO_HANDOFF", "AGENT_HUB_AUTO_HANDOFF_CHAIN", "AGENT_HUB_SUCCESSOR_MODEL",
                  "AGENT_HUB_SUCCESSOR_EFFORT", "AGENT_HUB_SUCCESSOR_PERMISSION_MODE", "AGENT_HUB_SUCCESSOR_TIMEOUT")
HUB_WIDE_KEYS += ("AGENT_HUB_SUCCESSOR_ENGINE", "AGENT_HUB_DESKTOP_CLI_HANDOFF")
# Grilling (bin/grilling.py): what holds an automatic handoff back is the autopilot's, hub home only.
HUB_WIDE_KEYS += ("AGENT_HUB_GRILLING_SKILL", "AGENT_HUB_GRILLING_STALE_MIN", "AGENT_HUB_GRILLING_CEILING")
BOOL_KEYS += ("AGENT_HUB_AUTO_HANDOFF", "AGENT_HUB_DESKTOP_CLI_HANDOFF")
# Watchdog (bin/watchdog): hub home only. It starts commands (a notification channel, a resume of a hub), so a cloned
# repository must not set any of it; one job serves one hub home, so every tool sharing the home must agree.
HUB_WIDE_KEYS += ("AGENT_HUB_WATCHDOG", "AGENT_HUB_WATCHDOG_EVERY", "AGENT_HUB_WATCHDOG_WAKE_AFTER",
                  "AGENT_HUB_WATCHDOG_BACKOFF_MAX", "AGENT_HUB_WATCHDOG_NIGHT_QUEUE", "AGENT_HUB_WATCHDOG_API_ERROR",
                  "AGENT_HUB_NOTIFY_LOCAL", "AGENT_HUB_NOTIFY_CMD", "AGENT_HUB_SPAWN_HOLD_LOAD", "AGENT_HUB_SPAWN_HOLD")
BOOL_KEYS += ("AGENT_HUB_WATCHDOG", "AGENT_HUB_WATCHDOG_NIGHT_QUEUE", "AGENT_HUB_WATCHDOG_API_ERROR",
              "AGENT_HUB_NOTIFY_LOCAL")
# Settings whose config.json value may be a JSON list or object; setting() returns it as a JSON string and
# setting_json() parses it (the environment variable holds the same JSON text).
JSON_KEYS = ("AGENT_HUB_CONTEXT_BLOCK_TOOLS", "AGENT_HUB_DELEGATION_LEVELS", "AGENT_HUB_DELEGATION_RULES",
             "AGENT_HUB_EFFORT_RULES", "AGENT_HUB_CI_STATUS_DENY", "AGENT_HUB_CI_STATUS_ALLOW", "AGENT_HUB_REVIEWERS")
JSON_KEYS += ("AGENT_HUB_CODEX_MODEL_MAP", "AGENT_HUB_EFFORT_DEFAULTS", "AGENT_HUB_REASON_MODELS",
              "AGENT_HUB_NOTIFY_CMD")
# Classes of action a standing permission covers only when it names them (bin/ask; {"class": ["stem", …]}). Hub home
# only: a cloned repository must not loosen what needs the owner's explicit word.
HUB_WIDE_KEYS += ("AGENT_HUB_SENSITIVE_CLASSES",)
JSON_KEYS += ("AGENT_HUB_SENSITIVE_CLASSES",)
# Silence after which the hub opens its reply with `ask inbox` (bin/ask; a duration like 3h): hub home only.
HUB_WIDE_KEYS += ("AGENT_HUB_OWNER_DIGEST_AFTER",)
# The limit-pace advisor (bin/limit_pace.py): on | warn | off, and the owner's engine decision per stage. Hub home only:
# a repository must not unlock a stage the owner locked to an engine.
HUB_WIDE_KEYS += ("AGENT_HUB_LIMIT_PACE", "AGENT_HUB_STAGE_ENGINES")
JSON_KEYS += ("AGENT_HUB_STAGE_ENGINES",)


# ---------------------------------------------------------------- the hub home
#
# Where the hub keeps its files (journals, inboxes, the question register, the lock board, handoffs), most specific
# first:
#   1. $AGENT_HUB_HOME — any path (the user's shell, or `env` of their Claude Code settings); every child the tools
#      start gets it set to the parent's resolved home, so parent and children never resolve differently;
#   2. the project layer: AGENT_HUB_HOME in <repo>/.agent-hub/config.json, "project" (<main checkout>/.agent-hub/local/,
#      shared by every worktree of the repository) or "user" (3-4) — nothing else: a cloned repository must not choose
#      arbitrary paths the tools write to;
#   3. the user default ~/agent-hub;
#   4. legacy: ~/.claude/agent-hub while ~/agent-hub does not exist (the default before 0.7). Claude Code protects
#      .claude directories: an edit there is prompted (or classified, or denied) whatever the allow rules say, and the
#      Bash sandbox refuses writes there — `hub home migrate` moves it.
# Hooks resolve for the session's directory (use_cwd with the hook input's cwd), the tools for their working directory.

HOME_KEY = "AGENT_HUB_HOME"
HOME_CHOICES = ("project", "user")
LOCAL_HOME = "local"  # <main checkout>/.agent-hub/local/


class Home(NamedTuple):
    path: Path
    layer: str  # "env", "project", "user" (the project layer chose the user default), "default", "legacy"
    source: str  # what chose it, for `hub home`


def user_home() -> Path:
    return Path.home() / "agent-hub"


def legacy_home() -> Path:
    return Path.home() / ".claude" / "agent-hub"


_SESSION_CWD: Optional[str] = None
_LOCAL = threading.local()  # in_home(): the home one thread works in (agent-top reads other homes than the resolved one)
_HOME_CACHE: dict = {}
_HOME_WARNED: set = set()
_STAGE_GUARD = True
_STAGE_SEEN: set = set()


def use_cwd(cwd, stage_guard: bool = False) -> None:
    """For a hook: resolve the hub home (and the settings of the home layer) for the session's directory — the hook
    input's `cwd` — instead of the process's. A hook never raises over a stage found in another home (stage_guard)."""
    global _SESSION_CWD, _STAGE_GUARD, TZ, TZ_LABEL
    _SESSION_CWD = str(cwd) if isinstance(cwd, str) and cwd else None
    _STAGE_GUARD = stage_guard
    _HOME_CACHE.clear()
    _STAGE_SEEN.clear()
    TZ = _zone()
    TZ_LABEL = dt.datetime.now(TZ).strftime("%Z") or "local"


def _git_top(d: Path) -> Optional[Path]:
    for p in [d] + list(d.parents):
        if (p / ".git").exists():
            return p
    return None


def project_home(proj: Path) -> Path:
    """The "project" hub home of the repository whose .agent-hub/ is in `proj`: under the main checkout (a linked
    worktree with its own committed .agent-hub/ still shares the main checkout's), <…>/.agent-hub/local/."""
    top = _git_top(proj)
    if top is None:
        return proj / CONFIG_DIRNAME / LOCAL_HOME
    main = (main_checkout(top) if (top / ".git").is_file() else None) or top
    return main / proj.relative_to(top) / CONFIG_DIRNAME / LOCAL_HOME


def _exclude_project_home(home: Path) -> None:
    """Add the project home to the main checkout's .git/info/exclude once (like .worktrees/), so it never shows as
    untracked. Best effort: a read-only .git costs a note, never a tool."""
    top = _git_top(home.parent.parent)
    if top is None or not (top / ".git").is_dir():
        return
    line = "/" + home.relative_to(top).as_posix() + "/"
    exclude = top / ".git" / "info" / "exclude"
    try:
        lines = exclude.read_text(encoding="utf-8").splitlines() if exclude.exists() else []
        if line in lines:
            return
        exclude.parent.mkdir(parents=True, exist_ok=True)
        with open(exclude, "a", encoding="utf-8") as fh:
            fh.write(("" if not lines or lines[-1] == "" else "\n") + line + "\n")
    except OSError as e:
        _warn(f"could not add {line} to {exclude}: {e}")


def home(cwd=None) -> Home:
    """The hub home and the layer that chose it (see the order above). `cwd`: the directory whose repository's
    .agent-hub/config.json counts (default: the hook's session directory, else the working directory)."""
    scoped = getattr(_LOCAL, "home", None)
    if scoped is not None:
        return scoped
    raw = os.environ.get(HOME_KEY)
    if raw:
        # absolute: a relative value pinned into a child in another directory would name another home
        return Home(Path(raw).expanduser().absolute(), "env", "the environment ($AGENT_HUB_HOME)")
    start = cwd or _SESSION_CWD
    if start is None:
        try:
            start = os.getcwd()
        except OSError:
            start = None
    key = str(start)
    if key in _HOME_CACHE:
        return _HOME_CACHE[key]
    proj = project_dir(start) if start else None
    choice, cfg = None, None
    if proj:
        cfg = proj / CONFIG_DIRNAME / "config.json"
        val = read_config(cfg, project=True).get(HOME_KEY)
        if val in HOME_CHOICES:
            choice = val
        elif val and (str(cfg), val) not in _HOME_WARNED:
            _HOME_WARNED.add((str(cfg), val))
            _warn(f"{cfg}: AGENT_HUB_HOME={val[:80]!r} ignored — a repository chooses only \"project\" or \"user\" "
                  "(another path: set AGENT_HUB_HOME in the environment)")
    if choice == "project":
        path = project_home(proj)
        _exclude_project_home(path)
        out = Home(path, "project", f'{cfg}: AGENT_HUB_HOME "project"')
    else:
        user, legacy = user_home(), legacy_home()
        if not user.exists() and legacy.is_dir():
            out = Home(legacy, "legacy", "the legacy default: ~/agent-hub does not exist, ~/.claude/agent-hub does")
        elif choice == "user":
            out = Home(user, "user", f'{cfg}: AGENT_HUB_HOME "user" (the user default)')
        else:
            out = Home(user, "default", "the user default (~/agent-hub)")
    _HOME_CACHE[key] = out
    return out


def root(cwd=None) -> Path:
    """The hub home's path (home())."""
    return home(cwd).path


@contextlib.contextmanager
def in_home(path, layer: str = "registry"):
    """Within the block this thread's home() is `path`, whatever the environment and the working directory say. For a
    reader of several homes (agent-top walks every known home); no tool that writes uses it, and the resolution order
    above is untouched for everyone else. Per thread, so a reader's helper thread never changes the main thread's home."""
    prev = getattr(_LOCAL, "home", None)
    _LOCAL.home = Home(Path(path), layer, "a known home (registry of homes)")
    try:
        yield
    finally:
        _LOCAL.home = prev


def is_protected(path) -> bool:
    """Whether `path` lies under a directory named .claude, which Claude Code protects from edits."""
    return ".claude" in Path(path).expanduser().parts


def under(path, parent) -> bool:
    """Whether `path` is `parent` or inside it (both resolved)."""
    try:
        p, d = Path(path).expanduser().resolve(), Path(parent).expanduser().resolve()
    except (OSError, ValueError, RuntimeError):
        return False
    return p == d or d in p.parents


def stage_elsewhere(stage: str) -> Optional[Path]:
    """Another home (the user default, the legacy one) that has this stage while the resolved home does not."""
    here = root()
    if (here / stage).is_dir():
        return None
    for other in dict.fromkeys((user_home(), legacy_home())):
        if not under(other, here) and not under(here, other) and (other / stage).is_dir():
            return other
    return None


# ---------------------------------------------------------------- registry of homes
#
# A project home lives inside an arbitrary repository, so nothing can find it by scanning; a tool that shows what runs on
# the machine (agent-top) needs a list. One JSON file outside every home: ${XDG_CONFIG_HOME:-~/.config}/delamain/homes.json,
# {"version": 1, "homes": [{"path", "layer", "repo", "first_seen", "last_seen"}]}. A home is registered when a stage is
# registered in it (roles_save, `agent spawn`) — not on every hook call — and `last_seen` is refreshed at most once a day,
# so a call that changes nothing writes nothing. The registry is a convenience: failing to read or write it never fails
# the calling tool (the current home is always known), and at most one stderr line says so, outside hooks.

REGISTRY_REFRESH_S = 24 * 3600
_REGISTERED: set = set()
_REGISTRY_WARNED: set = set()


class KnownHome(NamedTuple):
    path: Path
    label: str  # "" for ~/agent-hub, the repository's directory name for a project home, else the ~-abbreviated path
    layer: str
    repo: Optional[str]  # the main checkout of a project home, else None


def registry_path() -> Path:
    raw = os.environ.get("XDG_CONFIG_HOME", "")
    base = Path(raw).expanduser() if raw and os.path.isabs(os.path.expanduser(raw)) else Path.home() / ".config"
    return base / "delamain" / "homes.json"


def real_path(path) -> str:
    try:
        return str(Path(path).expanduser().resolve())
    except (OSError, ValueError, RuntimeError):
        return str(path)


_real = real_path

# How much a registry entry says about where a home came from: a child tool resolves its home from the pinned
# $AGENT_HUB_HOME (child_env), so the same home is seen as "env" by a child and as "project" by its parent; a
# registration never replaces a more specific provenance with a less specific one.
_LAYER_RANK = {"env": 0, "registry": 0, "legacy": 1, "user": 2, "default": 2, "project": 3}


def _tilde(path) -> str:
    p = str(path)
    h = str(Path.home())
    return "~" + p[len(h):] if h not in ("", "/") and (p == h or p.startswith(h + "/")) else p


def _registry_read() -> tuple:
    """(entries, state): state is "ok", "absent" or "bad" (unreadable or not the registry's shape)."""
    try:
        data = json.loads(registry_path().read_text(encoding="utf-8"))
    except FileNotFoundError:
        return [], "absent"
    except (OSError, ValueError):
        return [], "bad"
    ents = data.get("homes") if isinstance(data, dict) else None
    if not isinstance(ents, list):
        return [], "bad"
    return [e for e in ents if isinstance(e, dict) and isinstance(e.get("path"), str) and e["path"]], "ok"


def registry_load() -> list:
    """The registered homes' entries; [] when there is no registry or it cannot be read."""
    return _registry_read()[0]


def _registry_warn(msg: str) -> None:
    if _STAGE_GUARD and msg not in _REGISTRY_WARNED:  # a hook (stage_guard off) never writes to stderr
        _REGISTRY_WARNED.add(msg)
        _warn(msg)


def _home_provenance(h: Home) -> tuple:
    """(layer, repo) of the home `h`: a project home (the layer says so, or the path has the shape of one — a child's
    pinned $AGENT_HUB_HOME names it) has its main checkout as `repo`."""
    if h.layer == "project" or (h.path.name == LOCAL_HOME and h.path.parent.name == CONFIG_DIRNAME):
        return "project", str(h.path.parent.parent)
    return h.layer, None


def _more_specific(layer: str, repo: Optional[str], entry: dict) -> bool:
    old_layer = entry.get("layer") if isinstance(entry.get("layer"), str) else "env"
    return _LAYER_RANK.get(layer, 0) > _LAYER_RANK.get(old_layer, 0) or (bool(repo) and not entry.get("repo"))


def register_home(h: Optional[Home] = None) -> None:
    """Record the resolved home (or `h`) in the registry of homes. Once per process; a missing home is dropped on the
    way; best effort — nothing here raises."""
    try:
        h = h or home()
        path = _real(h.path)
        if path in _REGISTERED:
            return
        _REGISTERED.add(path)
        ents, state = _registry_read()
        stamp = now().isoformat(timespec="seconds")
        if state == "bad":
            _registry_warn(f"{registry_path()} is unreadable or not a registry of homes: delete it to start a new one "
                           "(agent-top lists the current home and ~/agent-hub meanwhile)")
            return
        layer, repo = _home_provenance(h)
        if _registry_current(ents, path, layer, repo):
            return
        reg = registry_path()
        with Flock(reg.with_name(reg.name + ".lock")):
            ents, state = _registry_read()
            if state == "bad":
                return
            keep, found = [], None
            for e in ents:
                if _real(e["path"]) == path:
                    found = e
                elif Path(e["path"]).is_dir():  # a deleted home is dropped on the next write
                    keep.append(e)
            if found is None:
                found = {"path": path, "layer": layer, "repo": repo, "first_seen": stamp}
            elif _more_specific(layer, repo, found):   # never downgrade: only a more specific provenance replaces it
                found.update(layer=layer, repo=repo)
            found.update(path=path, last_seen=stamp)
            atomic_write(reg, json.dumps({"version": 1, "homes": keep + [found]}, ensure_ascii=False, indent=1) + "\n")
    except Exception as e:  # noqa: BLE001 — the registry must never fail the tool that called it
        try:
            _registry_warn(f"could not update {registry_path()}: {e}")
        except Exception:  # noqa: BLE001
            pass


def _registry_current(ents: list, path: str, layer: str, repo: Optional[str]) -> bool:
    """Whether the registry already says what a registration would write: the home is in it with at least this
    provenance, seen within a day, and no entry of a deleted home is left to drop."""
    found = None
    for e in ents:
        if _real(e["path"]) == path:
            found = e
        elif not Path(e["path"]).is_dir():
            return False
    if found is None or _more_specific(layer, repo, found):
        return False
    try:
        seen = dt.datetime.fromisoformat(str(found.get("last_seen")))
        if seen.tzinfo is None:
            seen = seen.replace(tzinfo=TZ)
        return 0 <= (now() - seen).total_seconds() < REGISTRY_REFRESH_S
    except (ValueError, TypeError):
        return False


def known_homes() -> list:
    """Every hub home on this machine as far as the tools know, as KnownHome in a stable order: the resolved home (even
    when it does not exist yet), ~/agent-hub, the legacy home and $AGENT_HUB_HOME (each while it exists), then the
    registered homes whose path still exists; deduplicated by real path."""
    seen: dict = {}

    def add(path, layer, repo=None, must_exist=True):
        real = _real(path)
        if real in seen:   # the same home seen twice: the more specific provenance names it
            if _more_specific(layer, repo, {"layer": seen[real][1], "repo": seen[real][2]}):
                seen[real][1:] = [layer, repo]
            return
        if must_exist and not Path(real).is_dir():
            return
        seen[real] = [Path(path), layer, repo]

    cur = home()
    add(cur.path, *_home_provenance(cur), must_exist=False)
    add(user_home(), "default")
    add(legacy_home(), "legacy")
    raw = os.environ.get(HOME_KEY)
    if raw:
        add(Path(raw).expanduser().absolute(), "env")
    for e in sorted(registry_load(), key=lambda e: e["path"]):
        add(e["path"], e.get("layer") if isinstance(e.get("layer"), str) else "env",
            e.get("repo") if isinstance(e.get("repo"), str) else None)
    user = _real(user_home())
    labels = []
    for real, (path, layer, repo) in seen.items():
        if real == user:
            labels.append("")
        elif repo and Path(repo).name:
            labels.append(Path(repo).name)
        else:
            labels.append(_tilde(path))
    for i, (real, (path, layer, repo)) in enumerate(seen.items()):
        if labels[i] and labels.count(labels[i]) > 1:  # two checkouts called alike: the paths tell them apart
            labels[i] = _tilde(repo or path)
    return [KnownHome(p, labels[i], layer, repo) for i, (p, layer, repo) in enumerate(seen.values())]


def stage_in_known_homes(stage: str) -> list:
    """The known homes other than the resolved one that have a directory for `stage`."""
    here = _real(root())
    return [k for k in known_homes() if _real(k.path) != here and (k.path / stage).is_dir()]


def elsewhere_hint(stage: str) -> str:
    """" — stage S exists in home <path>; …" for a "stage not found" error when a known home has it, else ""."""
    try:
        other = stage_in_known_homes(stage)
    except Exception:  # noqa: BLE001 — a hint never fails the error it decorates
        return ""
    if not other:
        return ""
    k = other[0]
    return (f" — stage {stage} exists in home {k.path}; run from that project or set AGENT_HUB_HOME={k.path}")


# ---------------------------------------------------------------- configuration
#
# One mechanism, three layers of the same directory shape (most specific first):
#   <hub home>/<stage>/          stage layer   (files only)
#   <repo>/.agent-hub/           project layer (found from the working directory, see project_dir)
#   <hub home>/                  home layer
# Files: config.json (settings, see setting()), lock-rules.json (the lock hook; project + home rules
# together), brief-footer.md, handoff-facts.sh, takeover.sh (first layer that has the file wins).

def project_dir(start=None) -> Optional[Path]:
    """The directory holding `.agent-hub/`, searched upwards from `start` (default: the working directory)
    up to the enclosing git root; None outside such a repository."""
    try:
        p = Path(start or os.getcwd()).expanduser().resolve()
    except (OSError, ValueError):
        return None
    for d in [p] + list(p.parents):
        if (d / CONFIG_DIRNAME).is_dir():
            return d
        if (d / ".git").is_file():
            # a linked worktree without its own .agent-hub/ (not committed, or not yet) uses the main checkout's:
            # a guard configured there must not vanish in an agent's worktree
            main = main_checkout(d)
            return main if main is not None and (main / CONFIG_DIRNAME).is_dir() else None
        if (d / ".git").exists():
            return None
    return None


def _git(cwd, *argv, locale: bool = False, timeout: int = 5, env: Optional[dict] = None):
    """CompletedProcess of a bounded git call in `cwd`, None when git cannot run at all (missing, timed out)."""
    env = dict(env if env is not None else git_env())
    if locale:
        env["LC_ALL"] = "C"  # the "not a git repository" test below reads git's message
    try:
        return subprocess.run(["git", "-C", str(cwd), *argv], capture_output=True, text=True, timeout=timeout, env=env,
                              stdin=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError):
        return None


def project_warnings(cwd=None) -> list:
    """Why a hub or agent working in `cwd` runs without the project's rules, locks and brief footer, one line each:
    (a) the directory is not in a git repository (a Desktop session started under "No folder" runs in ~ or a temp
    dir); (b) the checkout has no .agent-hub/ while the remote default branch (origin/HEAD, else origin/main) has it.
    A warning, never a refusal; bounded and silent when git fails or there is no remote."""
    where = Path(cwd or os.getcwd()).expanduser()
    if project_dir(where) is not None:
        return []
    res = _git(where, "rev-parse", "--show-toplevel", locale=True)
    if res is None:
        return []
    if res.returncode != 0:
        if "not a git repository" not in res.stderr:
            return []
        return [f"no project folder: {where} is not inside a git repository, so the project's {CONFIG_DIRNAME}/ rules, "
                "locks and brief footer are not applied; a Desktop session started under 'No folder' runs in ~ or a "
                "temp dir: open it from the project's folder group"]
    top = res.stdout.strip()
    ref = _git(top, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD")
    remote = ref.stdout.strip() if ref is not None and ref.returncode == 0 else ""
    if not remote:
        fallback = _git(top, "rev-parse", "--verify", "--quiet", "refs/remotes/origin/main")
        remote = "origin/main" if fallback is not None and fallback.returncode == 0 else ""
    if not remote:
        return []
    tree = _git(top, "ls-tree", "--name-only", remote, "--", CONFIG_DIRNAME)
    if tree is None or tree.returncode != 0 or not tree.stdout.strip():
        return []
    br = _git(top, "branch", "--show-current")
    branch = (br.stdout.strip() if br is not None and br.returncode == 0 else "") or "(detached HEAD)"
    return [f"the checkout {top} on branch {branch} has no {CONFIG_DIRNAME}/ but {remote} has it: project rules, locks "
            f"and the brief footer are not applied; run from a worktree of {remote}"]


# ---------------------------------------------------------------- where a hub may run
#
# A hub runs in a linked worktree of its project that has the project's .agent-hub/ (a session in the main clone works
# on whatever branch the clone has checked out; one under "No folder" works in ~ or a temp dir, and has no project at
# all). `hub start` and `hub takeover` call check_location() before they register, journal or lock anything: a good
# place is refreshed, a bad one gets a fresh worktree of origin's default branch and the order to move there (exit 4).

NO_PROJECT_ENV = "AGENT_HUB_NO_PROJECT"  # environment only (a cloned repository must not switch the rule off)
STAGE_FILE = "stage.json"  # <stage dir>: {"repo": main clone of the stage's project} / {"no_project": true}, {"goal": "…"},
#                           {"closed": {"at", "why", "by", "hub"}} while the stage is closed (`hub close`)
LOCATION_EXIT = 4
FETCH_TIMEOUT_S = 30
HUB_WORKTREES = ".claude/worktrees"  # <repo>/…/<stage>-hub-<n>, where Claude Code puts its own worktrees


class Located(NamedTuple):
    code: Optional[int]  # None: go on; LOCATION_EXIT: the session must move first (nothing was registered or locked)
    repo: Optional[Path]  # the project's main working tree; None without a project
    note: str  # for the start line, "" when there is nothing to say


def _same(a, b) -> bool:
    try:
        return Path(a).resolve() == Path(b).resolve()
    except (OSError, ValueError, RuntimeError):
        return False


def _git_line(cwd, *argv, timeout: int = 5) -> str:
    """First line of a git call's stdout; "" when it fails or prints nothing."""
    res = _git(cwd, *argv, timeout=timeout)
    return res.stdout.strip().splitlines()[0] if res is not None and res.returncode == 0 and res.stdout.strip() else ""


def git_toplevel(path) -> Optional[Path]:
    """The working tree root of the repository `path` is in (a linked worktree's own root); None outside git."""
    top = _git_line(path, "rev-parse", "--show-toplevel")
    return Path(top) if top else None


def main_tree(path) -> Optional[Path]:
    """The main working tree of the repository `path` is in (itself for the main checkout); None outside git."""
    top = git_toplevel(path)
    return None if top is None else (main_checkout(top) or top)


def default_ref(repo) -> tuple:
    """(remote ref, branch) of the repository's default branch: origin/HEAD, else origin/main, else origin/master — the
    first that names a commit; (None, local default branch or None) when there is no such remote branch."""
    candidates = []
    head = _git_line(repo, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD")
    if head.startswith("origin/"):
        candidates.append(head)
    candidates += ["origin/main", "origin/master"]
    for ref in candidates:
        if _git_line(repo, "rev-parse", "--verify", "--quiet", f"refs/remotes/{ref}^{{commit}}"):
            return ref, ref[len("origin/"):]
    for branch in ("main", "master"):
        if _git_line(repo, "rev-parse", "--verify", "--quiet", f"refs/heads/{branch}"):
            return None, branch
    return None, None


def fetch_default(repo, branch: str) -> str:
    """`git fetch origin <branch>`, bounded; "" when it worked, else why not."""
    env = git_env()
    env["GIT_TERMINAL_PROMPT"] = "0"  # a credential prompt would hold the command for good
    env.setdefault("GIT_SSH_COMMAND", "ssh -o BatchMode=yes")
    res = _git(repo, "fetch", "--quiet", "origin", branch, timeout=FETCH_TIMEOUT_S, env=env)
    if res is None:
        return f"did not finish in {FETCH_TIMEOUT_S} s"
    return "" if res.returncode == 0 else (res.stderr.strip().splitlines() or [f"exit {res.returncode}"])[-1][:200]


def tree_has(repo, ref: str, name: str) -> bool:
    res = _git(repo, "ls-tree", "--name-only", ref, "--", name)
    return res is not None and res.returncode == 0 and bool(res.stdout.strip())


def stage_record(stage: str) -> dict:
    try:
        data = json.loads((root() / stage / STAGE_FILE).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def record_stage_project(stage: str, repo: Optional[Path]) -> None:
    """Remember the stage's project (`repo`; None: the stage has none) for the next hub, which may start outside git."""
    data = stage_record(stage)
    if repo is not None:
        want = dict(data, repo=str(repo))
        want.pop("no_project", None)
    else:  # the latest choice wins: a recorded repo would overrule it at the next folderless start
        want = dict(data, no_project=True)
        want.pop("repo", None)
    if want != data:
        atomic_write(root() / stage / STAGE_FILE, json.dumps(want, ensure_ascii=False, indent=1) + "\n")


def project_cwd_problem(stage: str, cwd) -> Optional[str]:
    """Why `cwd` is no place to start the stage's successor hub from, None when it is: outside git, or in another
    repository than the stage's recorded project. A stage with no project (`--no-project`, or AGENT_HUB_NO_PROJECT in the
    environment) accepts any directory."""
    if truthy(os.environ.get(NO_PROJECT_ENV)) or stage_record(stage).get("no_project"):
        return None
    here = main_tree(cwd)
    if here is None:
        if _git(cwd, "rev-parse", "--git-dir") is None:  # a timeout or no git at all says nothing about the directory
            return f"git did not answer for {cwd} (not installed, or no reply in 5 s): cannot tell whether it is in a repository"
        return f"{cwd} is not inside a git repository"
    repo = stage_record(stage).get("repo")
    project = main_tree(Path(str(repo)).expanduser()) if repo else None
    if project is not None and not _same(here, project):
        return f"{cwd} is in {here}, not in a worktree of the project of stage {stage} ({project})"
    return None


def stage_project(stage: str) -> Optional[Path]:
    """The main checkout of the stage's recorded project (stage.json `repo`); None when the stage has none, or it is gone."""
    repo = stage_record(stage).get("repo")
    if not repo or stage_record(stage).get("no_project"):
        return None
    try:
        return main_tree(Path(str(repo)).expanduser())
    except (RuntimeError, OSError):  # `~user` that does not exist
        return None


def registered_worktree(stage: str) -> Optional[Path]:
    """The worktree the stage's registered hub recorded at takeover (roles.json, hub.worktree) while it is still a good
    place for a successor (project_cwd_problem); None when nothing was recorded or it is gone."""
    path = (roles_load(stage)["roles"].get("hub") or {}).get("worktree")
    if not path or not Path(str(path)).is_dir() or project_cwd_problem(stage, path):
        return None
    return Path(str(path))


def stage_closed(stage: str) -> Optional[dict]:
    """The stage's `closed` record ({"at", "why", "by", "hub"}) once `hub close` closed it, else None. A closed stage
    is left out of agent-top's default view, the watchdog, the night queue and the questions summary; a takeover
    (or `hub start`) reopens it."""
    rec = stage_record(stage).get("closed")
    return rec if isinstance(rec, dict) else None


def record_stage_closed(stage: str, rec: Optional[dict]) -> None:
    """Write the stage's `closed` record into stage.json; None removes it (the stage is open again)."""
    data = stage_record(stage)
    want = dict(data, closed=rec) if rec else {k: v for k, v in data.items() if k != "closed"}
    if want != data:
        atomic_write(root() / stage / STAGE_FILE, json.dumps(want, ensure_ascii=False, indent=1) + "\n")


# ---------------------------------------------------------------- the stage's name and goal

# A stage name made only of these words (plus numbers and one-letter marks: `hub-09`, `stage-2`, `wave-a`, `wp3`) says
# nothing about the work. $AGENT_HUB_GENERIC_STAGE_WORDS (comma or space separated, hub-wide) replaces the list.
GENERIC_STAGE_WORDS = ("hub", "stage", "wave", "wp", "task", "work", "test", "tmp", "new", "default", "stream", "sprint")
NAMING_OFF_ENV = "AGENT_HUB_NO_NAMING"  # environment only, like NO_PROJECT_ENV: scripted environments and the test suite
GOAL_MAX = 200  # characters kept of a stage's goal
TITLE_GOAL_MAX = 60  # characters of it in a hub's title


def generic_stage_words() -> frozenset:
    raw = setting("AGENT_HUB_GENERIC_STAGE_WORDS")
    words = re.split(r"[\s,]+", raw.lower()) if raw else GENERIC_STAGE_WORDS
    return frozenset(w for w in words if w)


def naming_enforced() -> bool:
    return not truthy(os.environ.get(NAMING_OFF_ENV))


def stage_name_problem(stage: str) -> Optional[str]:
    """Why `stage` names no work (None: it does). A word is empty once its digits are removed, a single letter, or one
    of the generic words."""
    generic = generic_stage_words()
    for word in re.split(r"[-_]+", stage):
        rest = re.sub(r"\d+", "", word)
        if len(rest) > 1 and rest not in generic:
            return None
    return (f"stage name {stage!r} says nothing about the work: it holds only generic words ({', '.join(sorted(generic))}), "
            "numbers and single letters — name the goal in 1–3 words (retro-fixes, yc-move)")


def clean_goal(raw) -> str:
    """A goal as one line, whitespace collapsed, cut to GOAL_MAX characters."""
    text = " ".join(str(raw or "").split())
    return text if len(text) <= GOAL_MAX else text[:GOAL_MAX - 1].rstrip() + "…"


def title_goal(goal) -> str:
    """The goal as a hub's title carries it: cleaned, cut to TITLE_GOAL_MAX characters."""
    goal = clean_goal(goal)
    return goal if len(goal) <= TITLE_GOAL_MAX else goal[:TITLE_GOAL_MAX - 1].rstrip() + "…"


def stage_goal(stage: str) -> str:
    return clean_goal(stage_record(stage).get("goal"))


def record_stage_goal(stage: str, goal: str) -> None:
    data = stage_record(stage)
    if goal and data.get("goal") != goal:
        atomic_write(root() / stage / STAGE_FILE, json.dumps(dict(data, goal=goal), ensure_ascii=False, indent=1) + "\n")


def hub_title(stage: str, n: int, goal: Optional[str] = None) -> str:
    """The registered title of hub #n: `Hub <stage> #N`, plus ` — <goal>` (trimmed) when the stage has a goal. Handoff
    titles and the successor's number stay on the plain `Hub <stage> #N`."""
    goal = title_goal(stage_goal(stage) if goal is None else goal)
    return f"Hub {stage} #{n}" + (f" — {goal}" if goal else "")


def refresh_worktree(top, ref: str) -> str:
    """Fast-forward the clean worktree `top` to `ref` when its HEAD is an ancestor (no commits of its own); the line
    to print ("refreshed to origin/main abc1234"), else "" — also when it is there already."""
    head = _git_line(top, "rev-parse", "HEAD")
    target = _git_line(top, "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}")
    if not head or not target or head == target:
        return ""
    status = _git(top, "status", "--porcelain")
    ancestor = _git(top, "merge-base", "--is-ancestor", head, target)
    if status is None or status.returncode != 0 or status.stdout.strip() or ancestor is None or ancestor.returncode != 0:
        return ""
    res = _git(top, "merge", "--ff-only", "--quiet", ref, timeout=30)
    return f"refreshed to {ref} {target[:7]}" if res is not None and res.returncode == 0 else ""


def _exclude_hub_worktrees(repo) -> None:
    """/.claude/worktrees/ in the repository's info/exclude (like .worktrees/): no untracked noise in the main clone."""
    common = _git_line(repo, "rev-parse", "--path-format=absolute", "--git-common-dir")
    if not common:
        return
    exclude = Path(common) / "info" / "exclude"
    line = f"/{HUB_WORKTREES}/"
    try:
        lines = exclude.read_text(encoding="utf-8").splitlines() if exclude.exists() else []
        if line not in lines:
            exclude.parent.mkdir(parents=True, exist_ok=True)
            with open(exclude, "a", encoding="utf-8") as fh:
                fh.write(("" if not lines or lines[-1] == "" else "\n") + line + "\n")
    except OSError as e:
        _warn(f"could not add {line} to {exclude}: {e}")


def hub_worktree(repo, name: str, base: str, dry_run: bool) -> tuple:
    """(path, created, base commit) of the hub's worktree <repo>/.claude/worktrees/<name> on a new branch
    worktree-<name> from `base`. A path that is already a clean worktree of the repository at `base` is reused; any
    other taken name (a directory, a branch) moves on to <name>-2, <name>-3…. A dry run creates nothing."""
    sha = _git_line(repo, "rev-parse", "--verify", "--quiet", f"{base}^{{commit}}")
    if not sha and base == "HEAD":
        raise Failure(f"the repository {repo} has no commits yet — make a first commit (`git commit --allow-empty -m "
                      "\"first commit\"`), then run the command again: a hub works in a worktree, which needs a commit to start from")
    if not sha:
        raise Failure(f"cannot make the hub's worktree: {base} does not name a commit in {repo}")
    res = _git(repo, "worktree", "list", "--porcelain")
    listed = [Path(ln[len("worktree "):]) for ln in (res.stdout.splitlines() if res is not None else [])
              if ln.startswith("worktree ")]
    for i in range(1, 100):
        label = name if i == 1 else f"{name}-{i}"
        path, branch = Path(repo) / HUB_WORKTREES / label, f"worktree-{label}"
        if path.exists():
            status = _git(path, "status", "--porcelain")
            if (any(_same(path, w) for w in listed) and status is not None and status.returncode == 0
                    and not status.stdout.strip() and _git_line(path, "rev-parse", "HEAD") == sha):
                return path, False, sha
            continue
        if _git_line(repo, "rev-parse", "--verify", "--quiet", f"refs/heads/{branch}"):
            continue
        if dry_run:
            return path, True, sha
        _exclude_hub_worktrees(repo)
        path.parent.mkdir(parents=True, exist_ok=True)
        add = _git(repo, "worktree", "add", "--quiet", "--no-track", "-b", branch, str(path), base, timeout=60)
        if add is None or add.returncode != 0:
            raise Failure("git worktree add: " + ((add.stderr.strip() or add.stdout.strip()) if add is not None else "timed out"))
        return path, True, sha
    raise Failure(f"no free worktree name {name} … {name}-99 under {Path(repo) / HUB_WORKTREES}")


def check_location(stage: str, n: int, rerun: str, repo_arg: Optional[str] = None, no_project: bool = False,
                   dry_run: bool = False, cwd=None) -> Located:
    """The location rule of `hub start` and `hub takeover` (the module comment above). The project's repository R: the
    main working tree of --repo, else of the working directory's repository, else the stage's recorded project
    (stage.json); with none of them the command needs --repo or, for a stage that has no repository, --no-project.
    The place is good when the working directory is in a linked worktree of R that has .agent-hub/ whenever R's default
    branch has it. A good place is fast-forwarded to origin's default branch when it has no commits of its own and is
    clean. Otherwise: a worktree of origin's default branch, the order to move there, exit 4. `rerun` is the command
    line to repeat after the move. Prints what it does; the caller adds `note` to its start line."""
    try:
        where = Path(cwd or os.getcwd()).expanduser()
    except OSError:  # the working directory was deleted (a Desktop scratch directory): outside git, as far as we can tell
        where = Path.home()
    if no_project and repo_arg:
        raise UsageError("--repo and --no-project exclude each other")
    if truthy(os.environ.get(NO_PROJECT_ENV)):
        return Located(None, None, "")
    if no_project:
        return Located(None, None, f"no project (--no-project): started in place, {where}")
    R, stale = None, ""
    if repo_arg:
        R = main_tree(Path(repo_arg).expanduser())
        if R is None:
            raise UsageError(f"--repo {repo_arg}: not inside a git repository")
    else:
        R = main_tree(where)
        if R is None:
            rec = stage_record(stage)
            if rec.get("repo"):
                R = main_tree(Path(str(rec["repo"])).expanduser())
                if R is None:
                    stale = f"the project recorded for stage {stage} ({rec['repo']}) is not a git repository any more"
            elif rec.get("no_project"):
                return Located(None, None, f"no project (recorded for stage {stage}): started in place, {where}")
    if R is None:
        print(f"NO PROJECT: {where} is not inside a git repository and "
              + (stale or f"stage {stage} has no recorded project") + ".\n"
              "A hub works in a fresh worktree of the project its task is about. Find that project (its main clone, "
              "under ~/repos/ or where the brief points) and re-run with --repo <main clone>; a stage that has no "
              "repository at all starts with --no-project.\n"
              f"re-run: {rerun} --repo <main clone of the project>")
        return Located(LOCATION_EXIT, None, "")
    ref, branch = default_ref(R)
    if ref and not dry_run:
        failed = fetch_default(R, branch)
        if failed:
            print(f"ATTENTION: fetch of origin {branch} failed ({failed}): using the local {ref}")
    top = git_toplevel(where)
    linked = top is not None and (m := main_checkout(top)) is not None and _same(m, R)
    needs_config = bool(ref) and tree_has(R, ref, CONFIG_DIRNAME)
    if linked and (not needs_config or (top / CONFIG_DIRNAME).is_dir()):
        line = refresh_worktree(top, ref) if ref and not dry_run else ""
        if line:
            print(line)
        return Located(None, R, line)
    if linked:
        reason = f"{top} is a worktree of {R} without {CONFIG_DIRNAME}/, which {ref} has"
    elif top is None:
        reason = f"{where} is not inside a git repository"
    elif _same(top, R):
        on = _git_line(R, "branch", "--show-current") or "a detached HEAD"
        reason = f"{R} is the main clone, which has {on} checked out, not the default branch"
    else:
        reason = f"{where} is in another repository ({top}), not in a worktree of {R}"
    base = ref or branch or "HEAD"
    path, created, sha = hub_worktree(R, f"{stage}-hub-{n}", base, dry_run)
    print(f"MOVE {path}")
    print(f"A hub works in a fresh worktree of its project, and {reason}.")
    if not created:
        print(f"Reused the clean worktree {path} at {base} {sha[:7]}.")
    else:
        print(f"{'[plan] would create' if dry_run else 'Created'} the worktree {path} on a new branch from {base} {sha[:7]}.")
    print("Move this session there before anything else:\n"
          f"  Claude Code: EnterWorktree with path={path}. If it refuses (the session was launched outside the "
          "repository, e.g. a Desktop session under \"No folder\"): mcp__ccd_directory__change_directory with "
          f"path={R} — the main clone, not the worktree: Desktop files a session in the sidebar under the folder it "
          "moved to, and the main clone is usually trusted already (a new worktree waits for the owner's trust prompt, "
          "which expires in 5 minutes). It applies when the turn ends: start no background command, end the turn "
          f"at once; next turn check `pwd` is {R}, call EnterWorktree with path={path}, make no edits in the main "
          "clone.\n"
          f"  Codex: run every later command with the workdir {path}.\n"
          f"Then re-run: {rerun}")
    return Located(LOCATION_EXIT, R, "")


def main_checkout(worktree: Path) -> Optional[Path]:
    """The main working tree of a linked worktree (its `.git` file names a gitdir with a `commondir`); None for
    anything else, a submodule included."""
    try:
        m = re.match(r"gitdir:\s*(.+)", (worktree / ".git").read_text(encoding="utf-8").strip())
        if not m:
            return None
        gitdir = Path(m.group(1).strip())
        gitdir = gitdir if gitdir.is_absolute() else (worktree / gitdir)
        common = (gitdir / (gitdir / "commondir").read_text(encoding="utf-8").strip()).resolve()
    except (OSError, ValueError):
        return None
    return common.parent if common.name == ".git" else None


def git_repo_name(path) -> Optional[str]:
    """Name of the git repository enclosing `path` (a `.git` directory or file found upwards from it); a worktree
    resolves to its main repository. None outside any repository. The board hook names the repository of a command
    this way, so a lock taken with this name is matched there."""
    try:
        p = Path(os.path.realpath(os.path.expanduser(str(path))))  # a symlinked checkout and its worktrees agree
    except (OSError, ValueError):
        return None
    for d in [p] + list(p.parents):
        g = d / ".git"
        if g.is_dir():
            return d.name
        if g.is_file():  # a worktree or submodule: "gitdir: <main>/.git/worktrees/<name>"
            try:
                m = re.match(r"gitdir:\s*(.+)", g.read_text(encoding="utf-8").strip())
            except OSError:
                return d.name
            if m:
                gitdir = Path(m.group(1).strip())
                if not gitdir.is_absolute():
                    gitdir = (d / gitdir).resolve()
                parts = gitdir.parts
                if ".git" in parts:
                    return parts[parts.index(".git") - 1]
            return d.name
    return None


def default_repo(cwd=None) -> Optional[str]:
    """The repository a lock taken from `cwd` guards: AGENT_HUB_DEFAULT_REPO (env, the project's config.json, the hub
    home's), else the name of the git repository enclosing `cwd` (a worktree resolves to its main repository), else
    None: the caller falls back to "*" (every repository) only outside any checkout."""
    return setting("AGENT_HUB_DEFAULT_REPO", cwd=cwd) or git_repo_name(cwd or os.getcwd())


def in_scope(path) -> bool:
    """Whether the plugin's session-wide hooks (handoff size, the owner-questions line) apply at `path`: inside the
    hub home, inside a repository with `.agent-hub/`, or under a directory of AGENT_HUB_SCOPE_DIRS (paths separated
    by ':', `~` expanded). Elsewhere a session on the same machine is left alone."""
    try:
        p = Path(path).expanduser().resolve()
    except (OSError, ValueError, TypeError):
        return False
    dirs = [root()]
    for d in (setting("AGENT_HUB_SCOPE_DIRS") or "").split(":"):
        if d.strip():
            try:
                full = Path(d.strip()).expanduser()  # ~unknownuser raises RuntimeError
            except RuntimeError as e:
                _warn(f"AGENT_HUB_SCOPE_DIRS: {d.strip()!r}: {e}; ignored")
                continue
            if not full.is_absolute():
                _warn(f"AGENT_HUB_SCOPE_DIRS: {d.strip()!r} is not an absolute path (or ~/…); ignored")
                continue
            dirs.append(full)
    for d in dirs:
        try:
            if p == d.resolve() or d.resolve() in p.parents:
                return True
        except OSError:
            continue
    return project_dir(p if p.is_dir() else p.parent) is not None


def git_env() -> dict:
    """The environment for the tools' own git calls: without GIT_DIR / GIT_WORK_TREE (a dotfiles setup exports them),
    so git answers about the directory it is pointed at — the way project_dir and the hook walk the filesystem."""
    return {k: v for k, v in os.environ.items() if k not in ("GIT_DIR", "GIT_WORK_TREE")}


def config_dirs(stage: Optional[str] = None, cwd=None) -> list:
    """Existing config layers, most specific first: <home>/<stage>/, <project>/.agent-hub/, <home>/."""
    out = []
    if stage:
        out.append(root() / stage)
    proj = project_dir(cwd)
    if proj:
        out.append(proj / CONFIG_DIRNAME)
    out.append(root())
    return [d for d in out if d.is_dir()]


def config_file(name: str, stage: Optional[str] = None, cwd=None) -> Optional[Path]:
    """The first layer's copy of a config file (brief-footer.md, handoff-facts.sh, takeover.sh), or None."""
    for d in config_dirs(stage, cwd):
        if (d / name).is_file():
            return d / name
    return None


_CONFIG_CACHE: dict = {}


def _warn(msg: str) -> None:
    print(f"delamain: {msg}", file=sys.stderr)


warn = _warn  # for the tools that report a bad setting themselves (bin/reviewers.py, `hub reviewer`)


def read_config(path: Path, project: bool) -> dict:
    """Settings of one config.json as {NAME: str}. A broken file or a key the layer may not set is reported on
    stderr and ignored, so a typo never stops a tool (but never passes silently either)."""
    key = (str(path), project)
    if key in _CONFIG_CACHE:
        return _CONFIG_CACHE[key]
    out: dict = {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            raise ValueError("not a JSON object")
    except FileNotFoundError:
        data = {}
    except (OSError, ValueError) as e:
        _warn(f"{path} ignored: {e}")
        data = {}
    allowed = PROJECT_KEYS + (HOME_KEY,) if project else PROJECT_KEYS + HUB_WIDE_KEYS
    for name, value in data.items():
        if name.startswith("_"):  # "_comment" and the like
            continue
        if name not in allowed:
            hint = (" (hub-wide: set it in the hub home's config.json)" if name in HUB_WIDE_KEYS else
                    " (the environment or a repository's .agent-hub/config.json chooses the hub home)"
                    if name == HOME_KEY else "")
            _warn(f"{path}: {name} is not a setting this file may set{hint}; ignored")
            continue
        if name in JSON_KEYS and isinstance(value, (list, dict)):
            out[name] = json.dumps(value, ensure_ascii=False)
            continue
        if isinstance(value, dict):  # {"sonnet": "claude-…"} for AGENT_HUB_MODEL_MAP
            value = ",".join(f"{k}={v}" for k, v in value.items())
        if isinstance(value, bool):  # a JSON boolean: "true" / "false", what truthy() reads
            if name not in BOOL_KEYS:
                _warn(f"{path}: {name} is not a yes/no setting (true/false); ignored")
                continue
            value = "true" if value else "false"
        if not isinstance(value, (str, int, float)):
            _warn(f"{path}: {name} must be a string or a number; ignored")
            continue
        out[name] = str(value)
    _CONFIG_CACHE[key] = out
    return out


def setting_origin(name: str, default: Optional[str] = None, cwd=None) -> tuple:
    """(value, origin) of a setting, origin one of "env", "project", "home", "default": which layer supplied it.
    A setting whose meaning depends on who wrote it (a command a repository must not run) asks for it."""
    raw = os.environ.get(name)
    if raw:
        return raw, "env"
    if name in PROJECT_KEYS:
        proj = project_dir(cwd)
        if proj:
            val = read_config(proj / CONFIG_DIRNAME / "config.json", project=True).get(name)
            if val:
                return val, "project"
    val = read_config(root() / "config.json", project=False).get(name)
    return (val, "home") if val else (default, "default")


def setting(name: str, default: Optional[str] = None, cwd=None) -> Optional[str]:
    """$NAME if set and non-empty, else the project's .agent-hub/config.json (for PROJECT_KEYS; the project is
    found from `cwd`, default the working directory), else <hub home>/config.json, else `default`."""
    return setting_origin(name, default, cwd)[0]


def setting_json(name: str, default=None, cwd=None):
    """A JSON_KEYS setting parsed (list or object). A value that does not start like JSON ([ { ") is returned as the
    plain string (e.g. "Agent,SendMessage" from the environment); broken JSON is reported on stderr and gives
    `default`."""
    raw = setting(name, cwd=cwd)
    if not raw:
        return default
    if not raw.lstrip().startswith(("[", "{", '"')):
        return raw
    try:
        return json.loads(raw)
    except ValueError as e:
        _warn(f"{name}: not valid JSON ({e}); using the default")
        return default


def _zone() -> dt.tzinfo:
    name = (setting("AGENT_HUB_TZ") or "").strip()
    if name:
        try:
            from zoneinfo import ZoneInfo
            return ZoneInfo(name)
        except Exception:  # noqa: BLE001 — an unknown zone name falls back to local time
            print(f"delamain: unknown AGENT_HUB_TZ {name!r}, using local time", file=sys.stderr)
    return dt.datetime.now().astimezone().tzinfo


TZ = _zone()
TZ_LABEL = dt.datetime.now(TZ).strftime("%Z") or "local"
DEFAULT_MESSAGE_CAP = 10


_MAP_WARNED: set = set()


def model_map(cwd=None) -> dict:
    """Alias -> full id from AGENT_HUB_MODEL_MAP ("sonnet=claude-…,opus=claude-…"; env, else the agent's repo
    .agent-hub/config.json, else the hub home's config.json); empty = pass aliases through. A pair whose alias or
    id has characters outside MODEL_ALIAS_RE / MODEL_VALUE_RE is reported once and left out: what a repository's
    config maps an alias to goes into the agent's command line and its journal."""
    out = {}
    for part in (setting("AGENT_HUB_MODEL_MAP", cwd=cwd) or "").split(","):
        if "=" in part:
            k, v = part.split("=", 1)
            k, v = k.strip(), v.strip()
            if not (k and v):
                continue
            if not (MODEL_ALIAS_RE.fullmatch(k) and MODEL_VALUE_RE.fullmatch(v)):
                if (k, v) not in _MAP_WARNED:
                    _MAP_WARNED.add((k, v))
                    _warn(f"AGENT_HUB_MODEL_MAP: {k[:30]!r}={v[:30]!r}{'…' if len(v) > 30 else ''} is not an alias "
                          "and a model id (letters, digits and . _ : @ [ ] / - only); left out")
                continue
            out[k] = v
    return out


def model_problem(model, cwd=None) -> Optional[str]:
    """None when `agent spawn --model` takes `model`: an alias (opus, sonnet, haiku, fable), an alias of
    AGENT_HUB_MODEL_MAP, or a full id claude-… — and in each case only the characters above; else the reason."""
    if not isinstance(model, str) or not model:
        return "not a model name"
    if model in MODEL_ALIASES:
        return None
    if MODEL_ALIAS_RE.fullmatch(model) and model in model_map(cwd):
        return None
    if MODEL_ID_RE.fullmatch(model):
        return None
    return (f"one of {', '.join(MODEL_ALIASES)}, an alias from AGENT_HUB_MODEL_MAP, or a full id claude-… "
            "(letters, digits and . _ : @ [ ] - only)")


def int_setting(name: str, default: int, minimum: int = 1) -> int:
    """An integer setting; a value that is not a whole number >= minimum is reported on stderr and replaced by the
    default (a typo in config.json must not break every tool at import)."""
    raw = setting(name)
    if raw is None or raw == "":
        return default
    try:
        val = int(str(raw).strip())
        if val < minimum:
            raise ValueError
        return val
    except ValueError:
        _warn(f"{name}={raw!r} is not a whole number >= {minimum}; using {default}")
        return default


def message_cap() -> int:
    """Claude Desktop pauses a session's outgoing cross-session sends after this many messages without the user
    typing in it; `roles` counts sends against it. $AGENT_HUB_SEND_CAP (hub-wide), default 10."""
    return int_setting("AGENT_HUB_SEND_CAP", DEFAULT_MESSAGE_CAP)


def __getattr__(name: str):
    # MESSAGE_CAP is read when used, not at import: a bad value then costs a warning, not every tool.
    if name == "MESSAGE_CAP":
        return message_cap()
    raise AttributeError(name)


def status_pattern(exit_word: bool = True) -> str:
    """STATUS_WORDS plus $AGENT_HUB_JWAIT_MATCH (hub-wide), if set and a valid regex. exit_word=False leaves out
    the words `agent` itself writes when a run ends (AGENT_END_WORDS): EXIT, ENDED, REVIEWED."""
    extra = (setting("AGENT_HUB_JWAIT_MATCH") or "").strip()
    if extra:
        try:
            re.compile(extra)
        except re.error as e:
            _warn(f"AGENT_HUB_JWAIT_MATCH is not a valid regex ({e}); ignored")
            extra = ""
    base = STATUS_WORDS
    if not exit_word:
        for word in AGENT_END_WORDS:
            base = base.replace(f"|{word}", "")
    return f"{base}|{extra}" if extra else base


def jwait_for() -> str:
    """The default `jwait --for` ($AGENT_HUB_JWAIT_FOR, hub-wide; 50m). A value that is not a duration between zero
    (exclusive) and 24h is reported on stderr and replaced by the default."""
    raw = (setting("AGENT_HUB_JWAIT_FOR") or "").strip()
    if not raw:
        return DEFAULT_JWAIT_FOR
    try:
        if 0 < parse_duration(raw).total_seconds() <= MAX_JWAIT_FOR_S:
            return raw
    except (UsageError, OverflowError):
        pass
    _warn(f"AGENT_HUB_JWAIT_FOR is not a duration like 50m or 1h30m between 1s and 24h ({raw!r}); "
          f"using {DEFAULT_JWAIT_FOR}")
    return DEFAULT_JWAIT_FOR


def truthy(raw: Optional[str]) -> bool:
    return (raw or "").strip().lower() in ("1", "true", "yes", "on")


def misleading_claude_config(value) -> bool:
    """Whether CLAUDE_CONFIG_DIR names ~/.claude while ~/.claude.json exists. Not a neutral value: unset, the claude
    CLI reads ~/.claude.json; set, <dir>/.claude.json — here a file without the owner's trusted folders and login, so
    every `claude --bg --resume` failed "Workspace not trusted" (a watchdog job installed from a Codex shell, 08.10).
    Without ~/.claude.json the directory may hold the real config, and it is kept."""
    try:
        home = Path.home()
        return (bool(value) and Path(value).expanduser().resolve() == (home / ".claude").resolve()
                and (home / ".claude.json").exists())
    except (OSError, RuntimeError):
        return False


def child_env(extra: Optional[dict] = None) -> dict:
    """Environment for calling the sibling tools and the agents: the resolved home pinned in $AGENT_HUB_HOME (a child
    in another directory must not resolve another one), this bin/ first on PATH and in $HUB_BIN; a misleading
    CLAUDE_CONFIG_DIR (misleading_claude_config) is dropped, so the claude CLI reads the owner's own config."""
    env = dict(os.environ)
    if misleading_claude_config(env.get("CLAUDE_CONFIG_DIR")):
        del env["CLAUDE_CONFIG_DIR"]
    env["AGENT_HUB_HOME"] = str(root())
    env["PATH"] = str(BIN) + os.pathsep + env.get("PATH", "")
    env["HUB_BIN"] = str(BIN)  # for a brief written by an older run: rebuilt at every spawn and resume, so it follows updates
    if extra:
        env.update(extra)
    return env


def add_dir_args(cwd) -> list:
    """`--add-dir <hub home>` for a CLI started in `cwd`, unless the home is under it: the session may then read and
    write the hub's files without a prompt, and the Bash sandbox lets its tools write there."""
    h = root()
    return [] if under(h, cwd) else ["--add-dir", str(h)]


# ---------------------------------------------------------------- the CLI and the PATH

# `claude --version` prints "<version> (Claude Code)". A wrapper (a version manager's shim) may print other lines with
# other version numbers first: take the line in that format, else a last line that starts with a version.
_CLI_VERSION_RE = re.compile(r"^\s*(\d+)\.(\d+)\.(\d+)\s+\(Claude Code\)\s*$", re.M)
_LEADING_VERSION_RE = re.compile(r"^\s*v?(\d+)\.(\d+)\.(\d+)(?![\w.])")
_VERSION_CACHE: dict = {}
VERSION_TIMEOUT = 5  # seconds `<cli> --version` may take; a hanging shim must not stall every spawn


def parse_version(text) -> Optional[tuple]:
    text = str(text or "")
    m = _CLI_VERSION_RE.search(text)
    if not m:
        lines = [ln for ln in text.splitlines() if ln.strip()]
        m = _LEADING_VERSION_RE.match(lines[-1]) if lines else None
    return tuple(int(x) for x in m.groups()) if m else None


def fmt_version(v) -> str:
    return ".".join(str(x) for x in v)


def state_dir() -> Path:
    """<hub home>/.state, or $AGENT_HUB_STATE_DIR (hub-wide)."""
    raw = setting("AGENT_HUB_STATE_DIR")
    return Path(raw).expanduser() if raw else root() / ".state"


def _version_cache_file() -> Path:
    return state_dir() / "cli-version" / "cache.json"


def cli_version(path: str, cwd=None, persist: bool = True) -> Optional[tuple]:
    """`<path> --version` parsed as (major, minor, patch); None when the CLI does not run, takes longer than
    VERSION_TIMEOUT or prints no version. Cached per process, and on disk by path, size and modification time (a CLI
    update changes them): a spawn costs no extra process. A failure is cached for the process only. The disk cache is
    read always and written only when `persist` and the hub home exists (a dry run writes nothing)."""
    if path in _VERSION_CACHE:
        return _VERSION_CACHE[path]
    try:
        st = os.stat(shutil.which(path) or path)
        stamp = {"mtime_ns": st.st_mtime_ns, "size": st.st_size}
    except OSError:
        stamp = None
    cache_file, disk = _version_cache_file(), {}
    if stamp:
        try:
            disk = json.loads(cache_file.read_text(encoding="utf-8"))
            hit = disk.get(path) if isinstance(disk, dict) else None
            if isinstance(hit, dict) and hit.get("mtime_ns") == stamp["mtime_ns"] and hit.get("size") == stamp["size"]:
                v = parse_version(hit.get("version"))
                if v:
                    _VERSION_CACHE[path] = v
                    return v
        except (OSError, ValueError):
            disk = {}
    try:
        res = subprocess.run([path, "--version"], capture_output=True, text=True, timeout=VERSION_TIMEOUT,
                             stdin=subprocess.DEVNULL, cwd=str(cwd) if cwd else None)
        version = parse_version(res.stdout) if res.returncode == 0 else None
    except (OSError, subprocess.SubprocessError):
        version = None
    _VERSION_CACHE[path] = version
    if version and stamp and persist and root().is_dir():
        disk = disk if isinstance(disk, dict) else {}
        disk.pop(path, None)
        disk[path] = dict(stamp, version=fmt_version(version))
        try:
            atomic_write(cache_file, json.dumps(dict(list(disk.items())[-20:]), indent=1) + "\n")
        except OSError:
            pass
    return version


def desktop_cli() -> Optional[tuple]:
    """(version, path) of the newest CLI bundled with Claude Desktop on macOS (the directory name is the version);
    None when there is none. Both layouts: <version>/claude.app and <version>/<build hash>/claude.app (Desktop since
    2.1.29x)."""
    base = Path.home() / "Library/Application Support/Claude/claude-code"
    found = []
    for pattern in ("*/claude.app/Contents/MacOS/claude", "*/*/claude.app/Contents/MacOS/claude"):
        for d in base.glob(pattern):
            v = parse_version(d.relative_to(base).parts[0])
            if v and os.access(d, os.X_OK):
                found.append((v, str(d)))
    return max(found) if found else None


class Cli(NamedTuple):
    path: str
    version: Optional[tuple]
    how: str  # why this one

    def describe(self) -> str:
        return f"{self.path} ({fmt_version(self.version) if self.version else 'version unknown'}; {self.how})"


def find_claude(cwd=None, persist: bool = True) -> Optional[Cli]:
    """The CLI the tools start. $CLAUDE_BIN (a path or a name on PATH; `desktop` = the newest CLI bundled with Claude
    Desktop, which survives Desktop updates) wins. Otherwise the newer of `claude` on PATH and the newest bundled with
    Claude Desktop: an old `claude` on PATH must not hold the agents back on old models (PATH keeps a tie and a
    version it cannot read). None when there is no CLI at all. persist=False: do not write the version cache."""
    b = setting("CLAUDE_BIN", cwd=cwd)
    if b and b.strip().lower() == "desktop":
        app = desktop_cli()
        if not app:
            raise Failure("CLAUDE_BIN=desktop, but no CLI bundled with Claude Desktop was found under "
                          f"{Path.home() / 'Library/Application Support/Claude/claude-code'}")
        return Cli(app[1], app[0], "CLAUDE_BIN=desktop")
    if b:
        return Cli(b, cli_version(b, cwd, persist), "CLAUDE_BIN")
    on_path, app = shutil.which("claude"), desktop_cli()
    if on_path:
        pv = cli_version(on_path, cwd, persist)
        if app and pv is not None and app[0] > pv:
            return Cli(app[1], app[0], f"the newest bundled with Claude Desktop; `claude` on PATH is older: "
                                       f"{on_path} {fmt_version(pv)}")
        return Cli(on_path, pv, "claude on PATH" + (f"; the Claude Desktop bundle is {fmt_version(app[0])}"
                                                    if app and app[0] != pv else ""))
    return Cli(app[1], app[0], "bundled with Claude Desktop; no claude on PATH") if app else None


def cli_warning(cli: Optional[Cli]) -> Optional[str]:
    """One line when the chosen CLI is older than MIN_CLI_VERSION, else None."""
    if cli is None or cli.version is None or cli.version >= MIN_CLI_VERSION:
        return None
    return (f"Claude Code {fmt_version(cli.version)} ({cli.path}) is older than {fmt_version(MIN_CLI_VERSION)}, the "
            "oldest version Delamain supports: update Claude Code; with an older CLI the aliases (opus, sonnet, haiku, "
            "fable) resolve to older models and the agent-top mod does not run")


def idle_compaction_source(cwd: Optional[Path] = None) -> tuple:
    """(value, file) of the settings file that decides `idleCompaction` for a session started in `cwd`, in Claude
    Code's precedence: managed, the local project settings (.claude/settings.local.json, which a linked worktree reads
    from its main checkout), the shared ones (`cwd`/.claude/settings.json), the user's ($CLAUDE_CONFIG_DIR, else
    ~/.claude); (None, None) when none sets it. A file that cannot be read or parsed is skipped. Not visible from here:
    command-line `--settings` (what `hub succeed` gives its background successors) and managed settings that do not
    come from a file (MDM, server-delivered)."""
    files = list(MANAGED_SETTINGS)
    if cwd is not None:
        local = [(main_tree(cwd) or cwd) / ".claude" / "settings.local.json", cwd / ".claude" / "settings.local.json"]
        files += list(dict.fromkeys(local)) + [cwd / ".claude" / "settings.json"]
    files.append(Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude") / "settings.json")
    for f in files:
        try:
            data = json.loads(f.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if isinstance(data, dict) and "idleCompaction" in data:
            return data["idleCompaction"], f
    return None, None


def idle_compaction_warning(cwd: Optional[Path] = None) -> Optional[str]:
    """One line unless the settings that decide it (idle_compaction_source) turn idle compaction off. Claude Code
    2.1.290+ compacts a 200K+ conversation left idle ~54 min (on by default since 2.1.299), and a hub waiting on a long
    `jwait` is one: compacted, the context budget reads the smaller size and the hub goes on from a summary instead of
    handing over. Not gated on a CLI version: the running hub's own version is not known here, and the key is harmless
    to a CLI without the feature. $AGENT_HUB_NO_IDLE_COMPACTION_CHECK=1 skips it (scripted environments, the tests)."""
    if truthy(os.environ.get(IDLE_CHECK_OFF_ENV)):
        return None
    value, where = idle_compaction_source(cwd)
    if value is False:
        return None
    user = Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude") / "settings.json"
    state = f"{where} sets \"idleCompaction\": {json.dumps(value)}" if where else "no settings file sets \"idleCompaction\""
    return (f"Claude Code 2.1.290+ compacts a conversation over 200K tokens left idle ~54 min, and {state}: a hub waiting "
            f"on a long jwait would go on from a summary instead of handing over — set \"idleCompaction\": false in "
            f"{where or user} (the background successors of `hub succeed` get it on their command line)")


def desktop_compaction_note() -> Optional[str]:
    """One line for a hub that runs in Claude Desktop (`hub start`/`takeover` with a local_… session), unless
    $AGENT_HUB_NO_IDLE_COMPACTION_CHECK=1. Desktop runs its own bundled CLI, which can be older than the terminal's
    (2.1.295 against 2.1.299 on 14.10); neither the changelog nor the docs say whether that session reads
    `idleCompaction` from settings.json, whether the setting reaches it at all, or whether Desktop compacts on a schedule
    of its own, and nothing here can observe it. So the handoff threshold of the context budget is what has to come
    first, and the line says where that threshold stands against the 200K minimum of idle compaction."""
    if truthy(os.environ.get(IDLE_CHECK_OFF_ENV)):
        return None
    cli = desktop_cli()
    warn = int_setting("AGENT_HUB_CONTEXT_WARN", 300_000)
    version = fmt_version(cli[0]) if cli else "version unknown"
    where = (f"the context budget warns at {warn // 1000}k tokens, above the 200K at which idle compaction starts: set "
             f"AGENT_HUB_CONTEXT_WARN to 150000 in the hub home's config.json (hub-wide) if the handoff must come first"
             if warn >= 200_000 else f"the context budget warns at {warn // 1000}k tokens, below the 200K at which idle "
             "compaction starts")
    return (f"this hub runs in Claude Desktop, with Desktop's own Claude Code ({version} bundled here); whether it honours "
            f"\"idleCompaction\": false from settings.json, or compacts on its own, is not verified and cannot be seen from "
            f"here, so the handoff threshold has to fire before any compaction: {where}")


def plugin_tools() -> list:
    """The plugin's commands: every executable file of this bin/ without an extension (the .py files are modules)."""
    try:
        return sorted(p.name for p in BIN.iterdir() if "." not in p.name and p.is_file() and os.access(p, os.X_OK))
    except OSError:
        return []


# A personal wrapper that dispatches into the plugin (a shim in ~/.local/bin that picks the newest installed `bin/`)
# says so with this comment line near the top of its file; the shadow check then treats it as the plugin's own.
DISPATCHER_MARKER = "# delamain: dispatcher"
# Wrappers written before the product was renamed carry the old line; they stay recognised.
LEGACY_DISPATCHER_MARKER = "# agent-hub: dispatcher"  # rename:keep
DISPATCHER_MARKERS = (DISPATCHER_MARKER, LEGACY_DISPATCHER_MARKER)

# Folder names of the plugin in an installed cache (`<marketplace>/<name>/<version>`): the current name first, then the
# one a copy installed before the rename still has.
PLUGIN_CACHE_NAMES = ("delamain", "agent-hub")  # rename:keep


def plugin_version(bin_dir, engine=None) -> Optional[tuple]:
    """(major, minor, patch) of the plugin that owns `bin_dir`: its manifest's version (.claude-plugin or
    .codex-plugin), else a cache folder named <version>; None when neither says."""
    root = Path(bin_dir).parent
    manifests = (".codex-plugin", ".claude-plugin") if engine == "codex" else (".claude-plugin", ".codex-plugin")
    for folder in manifests:
        manifest = root / folder / "plugin.json"
        try:
            raw = json.loads(manifest.read_text(encoding="utf-8")).get("version")
        except (OSError, ValueError, AttributeError):
            continue
        m = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", str(raw or ""))
        if m:
            return tuple(int(x) for x in m.groups())
    m = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", root.name)
    return tuple(int(x) for x in m.groups()) if m else None


def host_engine() -> str:
    """Actual host from its environment, independent of configured executor defaults."""
    if os.environ.get("CODEX_THREAD_ID", "").strip():
        return "codex"
    return os.environ.get("AGENT_HUB_ENGINE", "").strip() or "claude"


# One line for a hub's context (SessionStart hook hooks/session_cards.py; the digest of `hub start` / `hub takeover`).
DESKTOP_CARDS_LINE = ("In this hub, Desktop's follow-up-card rules are superseded: follow-ups go to `agent spawn` or "
                      "`ask add`; `wrap_up` is fine.")


def plugin_runtime_line(engine=None) -> str:
    """Actual runtime root/version, plus a newer cache for this engine only; read-only."""
    engine = engine or host_engine()
    running = BIN.resolve()
    current = plugin_version(running, engine)
    label = fmt_version(current) if current else "version unknown"
    line = f"Plugin runtime: delamain {label} ({engine}; {running})"
    config = Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex") if engine == "codex" else Path(
        os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude")
    newer = []
    for candidate in cached_plugin_bins(config / "plugins" / "cache"):
        if not candidate.is_dir():
            continue
        version = plugin_version(candidate, engine)
        if current and version and version > current:
            newer.append((version, str(candidate.resolve())))
    if newer:
        version, path = max(newer)
        line += f"; ATTENTION: newer {engine} plugin {fmt_version(version)} installed at {path}; restart with that runtime"
    return line


def review_helper_lines() -> int:
    """Changed-line threshold for judgement helpers, configurable in the usual layers."""
    raw = (setting("AGENT_HUB_REVIEW_HELPER_LINES", "300") or "").strip()
    try:
        if not re.fullmatch(r"[0-9]+", raw):
            raise ValueError
        return int(raw)
    except ValueError:
        warn("AGENT_HUB_REVIEW_HELPER_LINES must be a non-negative integer; using default 300")
        return 300


def cached_plugin_bins(cache: Path) -> list:
    """The `bin/` directories of the plugin in a plugin cache: `<cache>/<marketplace>/<name>/<version>/bin` for each
    name in PLUGIN_CACHE_NAMES, so a copy installed before the rename is found too."""
    return [d for name in PLUGIN_CACHE_NAMES for d in cache.glob(f"*/{name}/*/bin")]


def installed_plugin_bins() -> list:
    """Real paths of the installed Delamain plugin `bin/` directories that are not older than this plugin: the Claude
    and Codex plugin caches (`<config>/plugins/cache/*/<name>/*/bin`, <name> from PLUGIN_CACHE_NAMES: the current plugin
    name and the one before the rename) and a marketplace folder that is the plugin itself
    (`<config>/plugins/marketplaces/*/bin` holding hubcore.py), of $CLAUDE_CONFIG_DIR / ~/.claude and
    $CODEX_HOME / ~/.codex. An older copy stays a shadow: it is the old tool on PATH the warning exists for (a version
    nobody can read counts as current)."""
    home = Path.home()
    current = plugin_version(BIN)
    out = []
    for config in (Path(os.environ.get("CLAUDE_CONFIG_DIR") or home / ".claude"),
                   Path(os.environ.get("CODEX_HOME") or home / ".codex")):
        plugins = config / "plugins"
        found = cached_plugin_bins(plugins / "cache") + [
            d for d in plugins.glob("marketplaces/*/bin") if (d / "hubcore.py").is_file()]
        for d in found:
            version = plugin_version(d)
            if current is None or version is None or version >= current:
                out.append(os.path.realpath(d))
    return out


def is_dispatcher(path) -> bool:
    """Whether the file `path` (symlinks resolved) carries a DISPATCHER_MARKERS line (the current one or the one from
    before the rename) among its first lines."""
    try:
        with open(os.path.realpath(path), "rb") as fh:
            head = fh.read(2048).decode("utf-8", "replace")
    except OSError:
        return False
    return any(line.strip() in DISPATCHER_MARKERS for line in head.splitlines()[:10])


def shadowed_tools(path=None) -> list:
    """[(tool, path found)] for each of the plugin's commands (plugin_tools) that PATH resolves to a file that is not
    the plugin's own (`command -v`: the first match on PATH). Ours: a file whose real path is in this bin/ (a symlink
    into it counts) or in an installed Delamain plugin's bin/ that is not older than this one
    (installed_plugin_bins), or a personal dispatcher that carries a DISPATCHER_MARKERS line (is_dispatcher)."""
    path = os.environ.get("PATH", "") if path is None else path
    out = []
    installed = None
    for name in plugin_tools():
        found = shutil.which(name, path=path)
        if not found:
            continue
        folder = os.path.dirname(os.path.realpath(found))
        if folder == str(BIN):
            continue
        if installed is None:
            installed = installed_plugin_bins()
        if folder in installed or is_dispatcher(found):
            continue
        out.append((name, found))
    return out


def shadow_warning(shadowed: list) -> Optional[str]:
    """One line naming every shadowing path and the fix, or None."""
    if not shadowed:
        return None
    names = ", ".join(f"`{n}` is {p}" for n, p in shadowed)
    return (f"{names} — not the plugin's own tool in {BIN}. A same-named command earlier on PATH answers instead "
            "(GitHub CLI `hub` from Homebrew is the usual one): put the plugin's bin/ first on PATH, or remove the old "
            f"tool; until then call the plugin's tools by absolute path ({BIN}/<tool>)")


def sessions_dir() -> Path:
    """Claude Desktop session metadata (macOS); override with $CLAUDE_SESSIONS_DIR."""
    raw = os.environ.get("CLAUDE_SESSIONS_DIR")
    return Path(raw) if raw else Path.home() / "Library" / "Application Support" / "Claude" / "claude-code-sessions"


def now() -> dt.datetime:
    return dt.datetime.now(TZ)


def default_stage() -> str:
    return os.environ.get("HUB_STAGE") or DEFAULT_STAGE


def check_stage(stage: str) -> str:
    """The stage name, checked; and the stage must not live in another hub home than the resolved one (a stage split
    across two homes loses half its journal): Failure naming where it is."""
    if not STAGE_RE.fullmatch(stage or ""):
        raise UsageError(f"bad stage name {stage!r} (lowercase letters, digits, '-' and '_')")
    if _STAGE_GUARD and stage not in _STAGE_SEEN:
        other = stage_elsewhere(stage)
        if other is not None:
            h = home()
            # the whole-home move fits only legacy -> the user default; into another home (a project's) it would carry
            # every other project's stages along
            move = ("move the old home with `hub home migrate`" if under(other, legacy_home())
                    and under(h.path, user_home()) else
                    f"move the stage (`mv {other / stage} {h.path}/`; its records keep the old paths)")
            raise Failure(f"stage {stage} is not in the hub home {h.path} ({h.source}) but in {other}: {move}, or work "
                          f"there with AGENT_HUB_HOME={other}; to start the stage afresh here, `mkdir -p {h.path / stage}`")
        _STAGE_SEEN.add(stage)
    return stage


class UsageError(Exception):
    """Bad arguments: exit 2."""


class Failure(Exception):
    """A step failed: exit 1."""


# ---------------------------------------------------------------- time

def parse_deadline(raw: str, base: Optional[dt.datetime] = None) -> dt.datetime:
    """'HH:MM' or 'HH:MM:SS' (hub time zone; a time already past today means tomorrow), ISO datetime with or without
    seconds (naive = hub zone)."""
    base = base or now()
    raw = raw.strip()
    m = re.fullmatch(r"(\d{1,2}):(\d{2})(?::(\d{2}))?", raw)
    if m:
        try:
            t = base.replace(hour=int(m.group(1)), minute=int(m.group(2)), second=int(m.group(3) or 0), microsecond=0)
        except ValueError:
            raise UsageError(f"cannot parse time {raw!r}: use HH:MM, HH:MM:SS or 2026-09-29T20:23:05") from None
        if t <= base:
            t += dt.timedelta(days=1)
        return t
    try:
        t = dt.datetime.fromisoformat(raw)
    except ValueError:
        raise UsageError(f"cannot parse time {raw!r}: use HH:MM, HH:MM:SS or 2026-09-29T20:23:05") from None
    return (t.replace(tzinfo=TZ) if t.tzinfo is None else t).astimezone(TZ)


def parse_duration(raw: str) -> dt.timedelta:
    """'90s', '30m', '6h', '1h30m', '2d'."""
    parts = re.findall(r"(\d+)([smhd])", raw.strip())
    if not parts or "".join(n + u for n, u in parts) != raw.strip():
        raise UsageError(f"cannot parse duration {raw!r}: use 90s, 30m, 6h, 1h30m")
    secs = sum(int(n) * {"s": 1, "m": 60, "h": 3600, "d": 86400}[u] for n, u in parts)
    return dt.timedelta(seconds=secs)


def age(t: Optional[dt.datetime], at: Optional[dt.datetime] = None) -> str:
    if t is None:
        return "—"
    s = int(((at or now()) - t).total_seconds())
    if s < 0:
        s = 0
    if s < 90:
        return f"{s} s"
    if s < 90 * 60:
        return f"{s // 60} min"
    if s < 48 * 3600:
        return f"{s // 3600} h {s % 3600 // 60:02d} min"
    return f"{s // 86400} d"


# ---------------------------------------------------------------- files

def atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
        if path.exists():
            os.chmod(tmp, path.stat().st_mode & 0o777)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


class Flock:
    def __init__(self, path: Path):
        self.path = path

    def __enter__(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.fh = open(self.path, "a")
        fcntl.flock(self.fh, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        fcntl.flock(self.fh, fcntl.LOCK_UN)
        self.fh.close()


# ---------------------------------------------------------------- journal

def work_dir(stage: str) -> Path:
    return root() / check_stage(stage) / "coordinator" / "work"


def journal_path(stage: str, day: Optional[dt.date] = None) -> Path:
    day = day or now().date()
    return work_dir(stage) / f"journal-{day.isoformat()}.md"


def one_line(text: str) -> str:
    return " ".join(text.split())


def journal_append(stage: str, tag: str, text: str) -> str:
    """Append '- HH:MM [tag] text' to today's journal; return the line."""
    text, tag = one_line(text), one_line(tag)
    if not text:
        raise UsageError("empty text")
    if not tag or "]" in tag or "[" in tag:
        raise UsageError(f"bad tag {tag!r}")
    t = now()
    line = f"- {t:%H:%M} [{tag}] {text}"
    path = journal_path(stage, t.date())
    path.parent.mkdir(parents=True, exist_ok=True)
    with Flock(path.parent / ".journal.lock"):
        prefix = ""
        try:
            with open(path, "rb") as fh:
                fh.seek(0, os.SEEK_END)
                if fh.tell() > 0:
                    fh.seek(-1, os.SEEK_END)
                    if fh.read(1) != b"\n":
                        prefix = "\n"
        except FileNotFoundError:
            pass
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        try:
            os.write(fd, (prefix + line + "\n").encode("utf-8"))
        finally:
            os.close(fd)
    return line


def parse_journal_line(line: str):
    """(time, tag, text) or None."""
    m = JOURNAL_LINE_RE.match(line)
    return (m.group(1), m.group(2).strip(), m.group(3)) if m else None


def tag_is(tag: str, base: str) -> bool:
    """tag equals base or is its sub-tag base/…; the first word counts too ('qa-2 r5b' is 'qa-2')."""
    if not tag or not base:
        return False
    cands = {tag, tag.split()[0]}
    return any(c == base or c.startswith(base + "/") for c in cands)


def mentions(text: str, tag: str, stage: Optional[str] = None) -> bool:
    """text addresses @tag; with a stage, also its stage-qualified form @<stage>-<tag> (how another stage's hub signs
    and answers: `@core-c-hub-30`). The leading and trailing guards keep @hub-30 apart from @hub-300 and
    @xcore-c-hub-30."""
    names = [tag] + ([f"{stage}-{tag}"] if stage else [])
    return any(re.search(r"(?<![\w@])@" + re.escape(n) + r"(?![\w-])", text) for n in names)


def last_line_by_tag(stage: str, tag: str, days: int = 2) -> Optional[dt.datetime]:
    """Time of the latest journal line with this tag (or a sub-tag) in the last `days` journals."""
    today = now().date()
    for back in range(days):
        day = today - dt.timedelta(days=back)
        try:
            lines = journal_path(stage, day).read_text(encoding="utf-8", errors="replace").splitlines()
        except FileNotFoundError:
            continue
        for line in reversed(lines):
            p = parse_journal_line(line)
            if p and tag_is(p[1], tag):
                hh, mm = map(int, p[0].split(":"))
                return dt.datetime.combine(day, dt.time(hh, mm), tzinfo=TZ)
    return None


# ---------------------------------------------------------------- desktop sessions

def normalize_local_id(raw: str) -> str:
    raw = raw.strip()
    return raw if raw.startswith("local_") else f"local_{raw}"


def desktop_session(local_id: str) -> Optional[dict]:
    """Metadata of a Claude Desktop session (read-only), or None when not found."""
    local_id = normalize_local_id(local_id)
    hits = glob.glob(str(sessions_dir() / "*" / "*" / f"{glob.escape(local_id)}.json"))
    if not hits:
        return None
    try:
        with open(hits[0], encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


# ---------------------------------------------------------------- roles registry

def roles_path(stage: str) -> Path:
    return root() / check_stage(stage) / "roles.json"


def roles_load(stage: str) -> dict:
    try:
        data = json.loads(roles_path(stage).read_text(encoding="utf-8"))
    except FileNotFoundError:
        data = {}
    except ValueError as e:
        raise Failure(f"{roles_path(stage)} is not valid JSON ({e}); fix it by hand") from None
    data.setdefault("version", 1)
    data.setdefault("roles", {})
    data.setdefault("retired", [])
    data.setdefault("sends", [])
    return data


# The hub's number in its roles tag: "hub-26", a legacy "хаб-25" (hubs registered by hand before the plugin), any tag
# that ends in "-<n>".
HUB_NUMBER_RE = re.compile(r".+-(\d+)")


def detached(stage: str, rec: dict, engine: Optional[str] = None):
    """The `agent` meta of the headless run that is this registry record's session (a hub started by `agent spawn`,
    including a worker promoted to hub), else None. `engine` limits it to one engine ("codex"); the default is any."""
    ids = {x for x in (rec.get("session"), rec.get("cli_session_id")) if x}
    for path in (root() / stage / "agents").glob("*/meta.json"):
        try:
            meta = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        if (isinstance(meta, dict) and (engine is None or meta.get("engine") == engine)
                and meta.get("session_id") in ids and meta.get("role") == path.parent.name):
            return meta
    return None


def hub_number(tag) -> Optional[int]:
    m = HUB_NUMBER_RE.fullmatch(tag.strip()) if isinstance(tag, str) else None
    return int(m.group(1)) if m else None


def roles_save(stage: str, data: dict) -> None:
    atomic_write(roles_path(stage), json.dumps(data, ensure_ascii=False, indent=1) + "\n")
    register_home()  # a stage with a registry makes its home known to agent-top (registry of homes)


def roles_lock(stage: str) -> Flock:
    return Flock(root() / check_stage(stage) / ".roles.lock")


def session_matches(rec: dict, sid: str, host: str = "") -> bool:
    """Match an explicit session id to a registry record, including a verified Desktop restart.

    An inherited host id alone proves nothing: Desktop must name this CLI session. Keep this read-only and
    lightweight, since session hooks use it too; callers that refresh the registry own their locks and writes.
    """
    if not isinstance(rec, dict) or not isinstance(sid, str) or not sid:
        return False
    if sid in (rec.get("session"), rec.get("cli_session_id")):
        return True
    return bool(isinstance(host, str) and host.startswith("local_") and rec.get("session") == host
                and (desktop_session(host) or {}).get("cliSessionId") == sid)


def role_for_session(stage: str, sid: str) -> Optional[tuple]:
    """(role, record) whose session or cli session id is sid."""
    if not sid:
        return None
    for name, rec in roles_load(stage).get("roles", {}).items():
        if session_matches(rec, sid):
            return name, rec
    return None


def session_id() -> str:
    """Identity of the current host session, also usable from detached workers."""
    if os.environ.get("AGENT_HUB_ENGINE") == "codex" or os.environ.get("CODEX_THREAD_ID"):
        return os.environ.get("CODEX_THREAD_ID", "").strip() or os.environ.get("AGENT_SESSION_ID", "").strip()
    return os.environ.get("CLAUDE_CODE_SESSION_ID", "").strip() or os.environ.get("AGENT_SESSION_ID", "").strip()


def role_for_caller(stage: str) -> Optional[tuple]:
    """(role, record) of the calling session in the registry of `stage`: by its session id (role_for_session), else
    for a Claude Desktop session whose CLI restarted (a new $CLAUDE_CODE_SESSION_ID under the same `local_…` id) by the
    Desktop id the host exposes in $CLAUDE_CODE_HOST_SESSION_ID — and only when Desktop's own record of that session
    names this very CLI session. The variable alone proves nothing: every child of a session inherits it, a headless
    agent and a `claude --bg` session started by a daemon included, and Desktop's record of the id names the one CLI
    session that is current. A hit refreshes the record's cli_session_id (best effort), so the next call finds it by
    the first rule."""
    sid = session_id()
    hit = role_for_session(stage, sid)
    if hit or not sid or sid != os.environ.get("CLAUDE_CODE_SESSION_ID", "").strip():
        return hit
    host = os.environ.get("CLAUDE_CODE_HOST_SESSION_ID", "").strip()
    if not host.startswith("local_"):
        return None
    for name, rec in roles_load(stage)["roles"].items():
        if rec.get("session") == host:  # the registry first: Desktop's metadata is only read for a candidate
            if not session_matches(rec, sid, host):
                return None
            try:
                with roles_lock(stage):
                    # what was read before the lock is stale by now if a `roles set` or another restart ran while we waited
                    # for it: the registration and Desktop's binding are checked again, and a caller that no longer
                    # matches neither writes nor gets the candidate's tag
                    data = roles_load(stage)
                    now = data["roles"].get(name) or {}
                    if now.get("session") != host or not session_matches(now, sid, host):
                        return role_for_session(stage, sid)
                    data["roles"][name]["cli_session_id"] = sid
                    roles_save(stage, data)
                    rec = data["roles"][name]
            except (OSError, Failure):
                pass  # a read-only home still gets its tag, only the refresh is skipped
            return name, rec
    return None


def caller_tag(stage: str) -> Optional[str]:
    """HUB_TAG, else the registry tag of this session (role_for_caller)."""
    if os.environ.get("HUB_TAG"):
        return os.environ["HUB_TAG"].strip()
    try:
        hit = role_for_caller(stage)
    except Failure:
        return None
    if hit:
        return hit[1].get("tag") or hit[0]
    return None


def registered_tag(stage: str) -> Optional[str]:
    """The tag this session has in the registry of `stage` (role_for_caller), else None."""
    try:
        hit = role_for_caller(stage)
    except (Failure, UsageError):
        return None
    return (hit[1].get("tag") or hit[0]) if hit else None


def other_stage_tag(target: str, tag: Optional[str] = None) -> Optional[tuple]:
    """(stage, tag) of this session in the registry of a stage other than `target`; with `tag`, only a registration
    carrying that tag. None when there is none or more than one (ambiguous: the caller must not guess a stage)."""
    if not session_id():
        return None
    try:
        names = sorted(d.name for d in root().iterdir() if d.name != target and (d / "roles.json").is_file())
    except OSError:
        return None
    hits = [(n, t) for n in names for t in [registered_tag(n)] if t and (tag is None or t == tag)]
    return hits[0] if len(hits) == 1 else None


def own_stage(tag: Optional[str]) -> Optional[str]:
    """The caller's own stage: $HUB_STAGE, else the only registry that lists this session under `tag`; None when it
    cannot be told."""
    own = os.environ.get("HUB_STAGE", "").strip()
    if own:
        return own if STAGE_RE.fullmatch(own) else None
    found = other_stage_tag("", tag)
    return found[0] if found else None


def signing_tag(stage: str) -> Optional[str]:
    """The tag a line written to `stage` is signed with. Another stage's hub or agent signs `<its stage>-<tag>`
    (`core-c-hub-30` in the Dolya journal), so the reader's @-answer names the writer's stage and the writer's jwait
    hears it. The caller's own stage is $HUB_STAGE when set (a role in a third stage does not override it), else the
    one registry that lists this session under the tag ($HUB_TAG) or, without a tag, the only one that lists it. Same
    stage, or an own stage that cannot be told (none, or several candidates): caller_tag(stage) as it is."""
    tag = caller_tag(stage)
    env_tag = bool(os.environ.get("HUB_TAG"))
    own = os.environ.get("HUB_STAGE", "").strip()
    if own == stage or (tag and not env_tag):  # same stage; or this stage's own registry named the caller
        return tag
    if own:
        tag = tag or registered_tag(own)
    else:
        if tag and registered_tag(stage) == tag:  # registered here under that very tag: a line of this stage
            return tag
        found = other_stage_tag(stage, tag)
        if found is None:
            return tag
        own, tag = found[0], tag or found[1]
    return f"{own}-{tag}" if tag and STAGE_RE.fullmatch(own) else tag


def run_main(fn, argv) -> int:
    try:
        return fn(argv)
    except UsageError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    except Failure as e:
        print(f"FAILED: {e}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130
