"""Subagent rules: one rule format for the delegation hook (in-session Agent/Task/Workflow calls) and `agent spawn`
(headless agents). No model or agent name is built in; everything comes from configuration.

A rule list is JSON, evaluated top to bottom; the first rule whose `when` matches decides:

    [{"when": {"subagent_type": "fork"}, "decision": "deny", "reason": "A fork inherits the parent's effort."},
     {"when": {"model": "*haiku*"}, "decision": "allow"},
     {"when": {"effort": ["inherit", "max"]}, "decision": "deny", "reason": "Pin the effort ({subagent_type})."}]

No matching rule = allow. `when` keys (all must match; a value is a glob or a list of globs, case-insensitive):

    tool           Agent | Task | Workflow | agent-spawn
    level          the delegation level "0".."5", or "off" when the dial is off
    subagent_type  the Agent call's subagent_type ("" when not given; plugin agents as "plugin:name"); this plugin's
                   agents match a glob written for either of its names: `delamain:worker-high` and
                   `agent-hub:worker-high` (the name before the rename) are one agent
    defined        "true" when a definition file for subagent_type was found, else "false"
    model          the model the subagent runs on: the call's `model`, else the definition's `model:`, else
                   "inherit"; for agent spawn both the alias given and the id it maps to are tried
    model_from     param | definition | inherit
    effort         the definition's pinned `effort:`, else "inherit"; for agent spawn the effort used

`reason` may name any of these fields in braces: "{model} at {effort} is not allowed".

AGENT_HUB_EFFORT_RULES is read from two places, each evaluated on its own, and a deny from either wins: the user's
(environment, else the hub home's config.json) and the repository's .agent-hub/config.json — a repository can only
add restrictions. It may also be the shorthand object {"<model>": "<effort>|<effort>", …}: each model (a glob, or a
plain word matched anywhere in the model name) runs only at the listed efforts. {"sonnet": "high|xhigh"} is

    [{"when": {"model": "*sonnet*", "effort": ["high", "xhigh"]}, "decision": "allow"},
     {"when": {"model": "*sonnet*"}, "decision": "deny", "reason": "…"}]
"""
from __future__ import annotations

import fnmatch
import json
import os
import sys
from pathlib import Path
from typing import Optional

FIELDS = ("tool", "level", "subagent_type", "defined", "model", "model_from", "effort")
DECISIONS = ("allow", "deny")
PLUGIN_ROOT = Path(os.path.dirname(os.path.dirname(os.path.realpath(__file__))))


LEGACY_PLUGIN_NAME = "agent-hub"  # rename:keep


def plugin_name() -> str:
    try:
        return json.loads((PLUGIN_ROOT / ".claude-plugin" / "plugin.json").read_text(encoding="utf-8"))["name"]
    except (OSError, ValueError, KeyError):
        return "delamain"


def named(local: str, plugin: Optional[str] = None) -> str:  # rename:transition
    """A skill or agent of this plugin as the texts that hooks and tools inject must name it for one release: the
    current name and, because a session started before the rename knows the plugin only under the old name,
    `agent-hub:<same name>` with a short note (rename:keep). Built from plugin_name() and LEGACY_PLUGIN_NAME, like
    current_type(), so the two forms cannot drift apart."""
    plugin = plugin or plugin_name()
    current = f"`{plugin}:{local}`"
    if plugin == LEGACY_PLUGIN_NAME:
        return current
    return f"{current} (`{LEGACY_PLUGIN_NAME}:{local}` in a session started before the rename)"


def current_type(typ) -> str:
    """A subagent type with the plugin prefix from before the rename (the old plugin name and a colon) turned into this
    plugin's (`delamain:worker-high`); anything else as it is. A rule written for the old prefix, an agent called by
    it and the definition lookup all go through here, so they mean the same agent."""
    typ = str(typ)
    prefix = LEGACY_PLUGIN_NAME + ":"
    if typ.lower().startswith(prefix):
        name = plugin_name()
        if name != LEGACY_PLUGIN_NAME:
            return name + ":" + typ[len(prefix):]
    return typ


def _warn(msg: str) -> None:
    print(f"delamain: {msg}", file=sys.stderr)


# ------------------------------------------------------------------ agent definitions

def _frontmatter(path: Path) -> Optional[dict]:
    """Lower-cased `key: value` pairs of a definition's YAML front matter; {} for a file without one."""
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return None
    if not text.startswith("---"):
        return {}
    fm: dict = {}
    for line in text.split("\n")[1:]:
        if line.strip() == "---":
            break
        k, sep, v = line.partition(":")
        if sep and not k.startswith((" ", "\t")):
            fm[k.strip().lower()] = v.strip().strip("\"'").lower()
    return fm


def _find_in(dirs, name: str) -> Optional[dict]:
    for d in dirs:
        f = d / f"{name}.md"
        fm = _frontmatter(f) if f.is_file() else None
        if fm is not None:
            return fm
    for d in dirs:  # a definition whose `name:` differs from its file name
        try:
            files = sorted(d.glob("*.md"))
        except OSError:
            continue
        for f in files:
            fm = _frontmatter(f)
            if fm and fm.get("name") == name.lower():
                return fm
    return None


def plugin_agent_dirs(plugin: str) -> list:
    """agents/ of an installed plugin: this plugin's own directory, else the newest cached version of another."""
    if plugin == plugin_name():
        return [PLUGIN_ROOT / "agents"]
    base = Path(os.environ.get("CLAUDE_CONFIG_DIR") or (Path.home() / ".claude")) / "plugins" / "cache"
    found = sorted(base.glob(f"*/{plugin}/*/agents"), key=lambda p: p.stat().st_mtime, reverse=True)
    return found[:1]


def agent_definition(name: str, cwd=None) -> Optional[dict]:
    """Front matter of the definition `name` resolves to, or None when none is found.

    "plugin:agent" (or "plugin:ns:agent") looks in that plugin's agents/; a bare name in <cwd>/.claude/agents,
    ~/.claude/agents, then this plugin's agents/ (an unambiguous plugin agent may be called without its prefix)."""
    if not name or "/" in name or name.startswith("."):
        return None
    name = current_type(name)
    if ":" in name:
        parts = name.split(":")
        return _find_in(plugin_agent_dirs(parts[0]), parts[-1])
    dirs = []
    if cwd:
        dirs.append(Path(cwd) / ".claude" / "agents")
    dirs.append(Path(os.environ.get("CLAUDE_CONFIG_DIR") or (Path.home() / ".claude")) / "agents")
    dirs.append(PLUGIN_ROOT / "agents")
    return _find_in(dirs, name)


# ------------------------------------------------------------------ calls and rules

def agent_call(tool: str, tool_input: dict, cwd=None, level=None) -> dict:
    """The rule fields of an in-session Agent/Task/Workflow call."""
    typ = str(tool_input.get("subagent_type") or "").strip()
    param = str(tool_input.get("model") or "").strip().lower()
    fm = agent_definition(typ, cwd) if typ else None
    def_model = (fm or {}).get("model", "")
    if param:
        model, source = param, "param"
    elif def_model and def_model != "inherit":
        model, source = def_model, "definition"
    else:
        model, source = "inherit", "inherit"
    return {"tool": tool, "level": "off" if level is None else str(level), "subagent_type": typ,
            "defined": "true" if fm is not None else "false", "model": model, "model_from": source,
            "effort": (fm or {}).get("effort") or "inherit"}


def spawn_call(model_given: str, model_id: str, effort: Optional[str]) -> dict:
    """The rule fields of `agent spawn`."""
    models = [m.lower() for m in dict.fromkeys([model_given, model_id]) if m]
    return {"tool": "agent-spawn", "level": "off", "subagent_type": "", "defined": "false", "model": models,
            "model_from": "param", "effort": (effort or "none").lower()}


def problems(rules) -> list:
    """Why a rule list is malformed (empty list = fine)."""
    if not isinstance(rules, list):
        return ["rules must be a JSON list"]
    out = []
    for i, r in enumerate(rules):
        if not isinstance(r, dict):
            out.append(f"rule {i}: not an object")
            continue
        when = r.get("when", {})
        if not isinstance(when, dict):
            out.append(f"rule {i}: `when` must be an object")
        else:
            for k, v in when.items():
                if k not in FIELDS:
                    out.append(f"rule {i}: unknown field {k!r} (one of {', '.join(FIELDS)})")
                elif not (isinstance(v, (str, int)) or (isinstance(v, list) and all(isinstance(x, (str, int)) for x in v))):
                    out.append(f"rule {i}: {k} must be a glob or a list of globs")
        if r.get("decision") not in DECISIONS:
            out.append(f"rule {i}: decision must be one of {DECISIONS}")
    return out


def _match(value, pattern) -> bool:
    values = value if isinstance(value, list) else [value]
    pats = pattern if isinstance(pattern, list) else [pattern]
    return any(fnmatch.fnmatchcase(str(v).lower(), str(p).lower()) for v in values for p in pats)


def type_forms(typ) -> list:
    """Every spelling of a subagent type that means the same agent. This plugin's agents have two: under the current
    plugin name and under the one before the rename (`delamain:worker-high`, `agent-hub:worker-high`); any other
    namespace, and a bare name, has only its own."""
    typ = str(typ)
    current = current_type(typ)
    forms = [typ]
    if current != typ:
        forms.append(current)
    elif current.lower().startswith(plugin_name().lower() + ":"):
        forms.append(LEGACY_PLUGIN_NAME + ":" + current[len(plugin_name()) + 1:])
    return forms


def _rule_matches(rule: dict, call: dict) -> bool:
    """Whether every `when` key of `rule` matches `call`. subagent_type is the one key compared through the rename: a
    pattern (as written, and in the current plugin name's form) is tried against every form of the call's type
    (type_forms). So a rule for `delamain*` or for `agent-hub*` (the name before the rename) means the same agents
    whichever of the two names the call or the rule uses. The first matching rule still decides (evaluate)."""
    for k, pattern in (rule.get("when") or {}).items():
        value = call.get(k, "")
        if k == "subagent_type":
            values = value if isinstance(value, list) else [value]
            value = [form for v in values for form in type_forms(v)]
            pats = pattern if isinstance(pattern, list) else [pattern]
            pattern = [form for p in pats for form in dict.fromkeys([str(p), current_type(p)])]
        if not _match(value, pattern):
            return False
    return True


class _Fields(dict):
    def __missing__(self, key):
        return "{" + key + "}"


def evaluate(rules, call: dict, label: str = "rules"):
    """(decision, reason, index) of the first matching rule, or None. A malformed list is reported and skipped
    as a whole (fail-open: a typo must not stop every subagent)."""
    if not rules:
        return None
    errs = problems(rules)
    if errs:
        _warn(f"{label} ignored: " + "; ".join(errs))
        return None
    for i, r in enumerate(rules):
        if _rule_matches(r, call):
            shown = {k: ("/".join(v) if isinstance(v, list) else v) or "-" for k, v in call.items()}
            reason = str(r.get("reason") or f"denied by {label} #{i}")
            try:
                reason = reason.format_map(_Fields(shown))
            except (ValueError, IndexError):
                pass
            return r["decision"], reason, i
    return None


def expand(rules):
    """A rule list as is; the shorthand {"<model>": "<effort>|…"} as the equivalent rule list."""
    if not isinstance(rules, dict):
        return rules
    out = []
    for model, efforts in rules.items():
        if str(model).startswith("_"):
            continue
        pat = model if any(ch in model for ch in "*?[") else f"*{model}*"
        allowed = [e.strip() for e in str(efforts).split("|") if e.strip()]
        out.append({"when": {"model": pat, "effort": allowed}, "decision": "allow"})
        out.append({"when": {"model": pat}, "decision": "deny",
                    "reason": f"{model} runs only at effort {' or '.join(allowed)} (got {{effort}}, type "
                              f"{{subagent_type}})."})
    return out


def _hubcore():
    sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
    import hubcore  # noqa: E402

    return hubcore


def _parse(name: str, raw: str):
    if not raw.lstrip().startswith(("[", "{")):
        _warn(f"{name}: not a JSON list or object; ignored")
        return None
    try:
        return json.loads(raw)
    except ValueError as e:
        _warn(f"{name}: not valid JSON ({e}); ignored")
        return None


def effort_rule_sets(cwd=None) -> list:
    """[(label, rules)] of AGENT_HUB_EFFORT_RULES: the user's (the environment, else the hub home's config.json),
    then the repository's at `cwd`. Each set is evaluated on its own and a deny from any of them wins, so a
    repository can add restrictions but never loosen the user's."""
    hc = _hubcore()
    name = "AGENT_HUB_EFFORT_RULES"
    layers = []
    env = os.environ.get(name)
    if env:
        layers.append((f"{name} (environment)", env))
    else:
        layers.append((f"{name} (hub home)", hc.read_config(hc.root() / "config.json", project=False).get(name)))
    proj = hc.project_dir(cwd) if cwd else None
    if proj:
        layers.append((f"{name} ({proj.name}/{hc.CONFIG_DIRNAME})",
                       hc.read_config(proj / hc.CONFIG_DIRNAME / "config.json", project=True).get(name)))
    out = []
    for label, raw in layers:
        rules = expand(_parse(label, raw)) if raw else None
        if rules:
            out.append((label, rules))
    return out


def check_effort(call: dict, cwd=None) -> Optional[str]:
    """The first deny any effort rule set gives `call`, with the set and rule named; None = allowed."""
    for label, rules in effort_rule_sets(cwd):
        reason = deny_reason(evaluate(rules, call, label), label)
        if reason:
            return reason
    return None


def deny_reason(res, label: str) -> Optional[str]:
    """The reason of a deny result of evaluate(), with the rule named; None for allow / no match."""
    if not res or res[0] != "deny":
        return None
    return f"{res[1]} [{label} rule {res[2]}]"


def check_spawn(model_given: str, model_id: str, effort: Optional[str], cwd=None) -> Optional[str]:
    """The deny reason AGENT_HUB_EFFORT_RULES gives an `agent spawn` (the user's and the agent repository's)."""
    return check_effort(spawn_call(model_given, model_id, effort), cwd)
