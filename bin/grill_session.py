"""A grilling session of its own (`hub grill`): when the owner asks a stage hub to grill over the stage's open
questions, the hub does not grill in its own context (owner, 15.10; D-AUDIT-008). It prepares a brief and launches a
separate interactive session; that session grills the owner, records every answer in the `ask` register and reports to
the hub with one journal line. The hub then acts on the answers. A long grilling costs the hub's context nothing.

  hub grill [open] --stage S [--questions ID,…] [--also-stage S2 …] [--topic TEXT] [--owner-words TEXT]
                   [--host auto|desktop|codex-app|bg|manual] [--model M] [--effort E] [--again] [--dry-run]
  hub grill join   --stage S --launch ID --session self
  hub grill done   --stage S [--summary TEXT] [--why TEXT]

open     collects the questions: by default the stage's unresolved owner questions (Q entries open or default-taken),
         plus those of each --also-stage the owner named; --questions takes entries by id instead, of any kind and stage.
         Writes the brief <stage>/coordinator/work/grill-<stamp>-brief.md, records the pending launch in
         <stage>/grill.json under a launch id (before the start, so a start that hangs still holds the stage) and launches
         by host (--host auto tells them apart):
           desktop    a Claude Desktop hub: prints the arguments of mcp__ccd_session__start_session with initiation
                      "user_asked". The hub calls it in the turn of the owner's request: the app starts a session only in
                      a turn the owner typed, and the session_cards hook lets `user_asked` through in a hub
           codex-app  a Codex app hub: prints create_thread arguments. The hub finds the project with native
                      list_projects, fills its projectId and calls create_thread once, under the owner's request
           bg         any other Claude host (a terminal, `claude --bg`): starts `claude --bg --remote-control <stage>-grill`
                      in this directory and prints the session's Remote Control link for the owner
           manual     any other Codex host: prints the command the owner runs in a terminal
         Refused (exit 2) while a grilling session of the stage is registered, or a launch is pending that is younger
         than AGENT_HUB_GRILL_JOIN_MIN minutes (default 30; --again drops it). Exit 1 when there is nothing to grill.
join     the new session runs it first, with the launch id of its brief: it is registered as role `grill` (tag `grill`)
         under its full session id (a Codex thread by $CODEX_THREAD_ID, a Claude Desktop session by its local_ id), so
         agent-top, `tell <stage> --role grill` and the hub see it, and the pending launch is cleared. Refused (exit 2)
         while another session holds the role (one per stage) and for a launch that was replaced or dropped.
done     the grilling session runs it when the frontier is empty or the owner stops: one journal line
         "[grill] @hub GRILLED <a> answered, <w> withdrawn, <o> open of <n>; <k> new … — <summary>", which wakes the
         hub's `jwait --hub-events` and `--tag hub`, and names `ask list --pending` for every stage grilled over; then the
         role is retired. Only the registered session reports (exit 2 for another); the hub or the owner ends one that
         went away with --why. With no session registered it drops a pending launch.
No lock is taken: the session reads the register and writes answers into it, nothing else.
"""
from __future__ import annotations

import importlib.machinery
import importlib.util
import json
import os
import shlex
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Optional

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import hubcore as hc  # noqa: E402
import autopilot  # noqa: E402
import engines  # noqa: E402

ROLE = "grill"
HOSTS = ("auto", "desktop", "codex-app", "bg", "manual")
OPEN_STATES = ("open", "default-taken")       # an owner question still waiting for the owner's words
DEFAULT_JOIN_MIN = 30
LINK_WAIT_S = 90
# what the background session may run without asking: the register, its report, the journal; the owner answers the rest
GRILL_ALLOW = ("ask", "jlog", "hub grill", "tell")
SKILL_HINT = ("the companion `grilling` skill (Claude Code: the Skill tool, e.g. `mattpocock-skills:grilling`; "
              "Codex: `$grilling`, or read its SKILL.md)")


def tool(name: str) -> str:
    return autopilot.tool(name)


def ask_module():
    mod = sys.modules.get("ask_cli")
    if mod is None:
        path = str(hc.BIN / "ask")
        loader = importlib.machinery.SourceFileLoader("ask_cli", path)
        mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("ask_cli", loader))
        sys.modules["ask_cli"] = mod  # dataclasses in `ask` look their module up here
        loader.exec_module(mod)
    return mod


def roles_module():
    mod = sys.modules.get("roles_cli")
    if mod is None:
        loader = importlib.machinery.SourceFileLoader("roles_cli", str(hc.BIN / "roles"))
        mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("roles_cli", loader))
        sys.modules["roles_cli"] = mod
        loader.exec_module(mod)
    return mod


# ---------------------------------------------------------------- state: the pending launch

def state_path(stage: str) -> Path:
    return hc.root() / hc.check_stage(stage) / "grill.json"


def state_lock(stage: str) -> hc.Flock:
    return hc.Flock(hc.root() / hc.check_stage(stage) / ".grill.lock")


def load_state(stage: str) -> dict:
    try:
        data = json.loads(state_path(stage).read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {}
    except ValueError as e:
        raise hc.Failure(f"{state_path(stage)} is not valid JSON ({e}); remove it or fix it by hand") from None
    return data if isinstance(data, dict) else {}


def save_state(stage: str, data: dict) -> None:
    if data:
        hc.atomic_write(state_path(stage), json.dumps(data, ensure_ascii=False, indent=1) + "\n")
    else:
        try:
            state_path(stage).unlink()
        except FileNotFoundError:
            pass


def join_window_s() -> int:
    return hc.int_setting("AGENT_HUB_GRILL_JOIN_MIN", DEFAULT_JOIN_MIN) * 60


def registered(stage: str) -> Optional[dict]:
    return hc.roles_load(stage)["roles"].get(ROLE)


def busy(stage: str, state: dict) -> Optional[str]:
    """Why a new launch must wait: a registered grilling session, or a pending launch inside its join window."""
    rec = registered(stage)
    if rec:
        return (f"a grilling session of stage {stage} is registered: \"{rec.get('title')}\" {rec.get('session')} since "
                f"{str(rec.get('set_at'))[:16]} — the owner talks to it; it ends with `{tool('hub')} grill done --stage "
                f"{stage}` (the hub may run it with --why when the session went away)")
    pend = state.get("pending") or {}
    age = time.time() - float(pend.get("ts") or 0)
    if pend and age < join_window_s():
        return (f"a grilling session of stage {stage} was launched {int(age // 60)} min ago ({pend.get('host')}) and "
                f"has not joined yet — wait for its `grill join` line, or run again with --again (the earlier launch "
                f"can then no longer join)")
    return None


# ---------------------------------------------------------------- the questions

def entry_facts(e) -> dict:
    f = e.fields
    return {"id": e.id, "stage": e.stage, "state": e.state, "title": hc.one_line(e.title),
            "blocks": f.get("blocks", ""), "default": f.get("default", ""), "due": f.get("due", ""),
            "by": f.get("by", "")}


def collect(stage: str, also: list, ids: list) -> list:
    ask = ask_module()
    if ids:
        out = []
        for qid in dict.fromkeys(ids):
            try:
                e = ask.find_entry(qid)
            except SystemExit as err:
                raise hc.UsageError(f"--questions: {err}") from None
            out.append(entry_facts(e))
        return out
    out = []
    for s in dict.fromkeys([stage] + list(also)):  # a stage named twice is read once
        _, entries = ask.load(hc.check_stage(s))
        out += [entry_facts(e) for e in entries if e.kind_letter == "Q" and e.state in OPEN_STATES]
    return out


def question_lines(questions: list) -> str:
    lines = []
    for q in questions:
        lines.append(f"- **{q['id']}** ({q['stage']}, {q['state']}) — {q['title']}")
        extra = [f"{k}: {q[k]}" for k in ("blocks", "default", "due") if q.get(k) and q[k] != "not set"]
        if extra:
            lines.append("  " + "; ".join(extra))
    return "\n".join(lines)


# ---------------------------------------------------------------- the brief and the prompt

def brief_text(stage: str, launch: str, questions: list, topic: str, owner_words: str, launched_by: str) -> str:
    hub, ask, jlog = tool("hub"), tool("ask"), tool("jlog")
    home = shlex.quote(str(hc.root()))
    source = f"\nThe owner's request: «{owner_words}».\n" if owner_words else ""
    focus = f"\nThe owner's focus for this grilling: {topic}\n" if topic else ""
    return f"""# Grilling brief — stage {stage}

You are the grilling session of stage `{stage}`: an interactive session with the owner. The stage's hub
({launched_by}) started you so that a long grilling does not fill its own context. You do not plan, build, spawn
agents or change code: you grill, record the answers and report. The hub acts on them.
{source}
## 1. Register first, before you greet the owner

`{hub} grill join --stage {stage} --launch {launch} --session self`

It registers you as role `grill` (agent-top, `tell {stage} --role grill` and the hub see you). Exit 2: another
grilling session of this stage is registered, or this launch was replaced or dropped — tell the owner and stop. If a command says the stage does not exist,
the hub home is {home}: put `AGENT_HUB_HOME={home}` before each command.

## 2. The questions

{question_lines(questions)}

An entry in full: `{ask} show <id>`. Decisions already on record are settled: `{ask} search <words>`.
{focus}
## 3. Grill

Load {SKILL_HINT} and run it as written over these questions: rounds of numbered questions, each with your
recommended answer and what each answer changes, until the frontier is empty — every question above answered,
withdrawn or left open by the owner's choice, and every new question the grilling raised settled the same way. Facts
you can look up (the register, the repository, the journal) are yours to look up, not questions. A recommendation is
never taken on silence: only the owner's own words close a question.

## 4. Record every answer as it comes

- An answer to a listed question: `{ask} close <id> --answer "<the owner's answer, short, in their words>"`.
- The owner withdraws a question: `{ask} withdraw <id> --reason "<why>"`.
- A new question the owner answered: `{ask} add --stage {stage} --by {ROLE} --print-id "<question>"`, then
  `{ask} close <the printed id> --answer "…"`.
- The owner tells you to decide something yourself: `{ask} decided --stage {stage} --by {ROLE} "<decision>"`.

Record nothing the owner did not say. Execute nothing: acting on the answers is the hub's.

## 5. Report and end

When the frontier is empty or the owner stops the grilling:

`{hub} grill done --stage {stage} --summary "<one line: what was decided, what stays open>"`

It writes one journal line to the hub (`@hub GRILLED …`, counted from the register) and retires your role. Then tell
the owner that the answers are recorded, the hub acts on them, and this session may be closed. A question for the hub
meanwhile: `{jlog} --stage {stage} "@hub …"` (its answer comes through the owner or `tell {stage} --role grill`).
"""


def prompt_text(stage: str, brief: Path, launch: str) -> str:
    return (f"You are the grilling session of stage {stage} (Delamain). Read the brief {brief} and follow it: first "
            f"run `{tool('hub')} grill join --stage {stage} --launch {launch} --session self`, then grill the owner over "
            f"the open questions it lists with the companion grilling skill, record every answer with `ask`, and end with "
            f"`{tool('hub')} grill done --stage {stage} --summary \"…\"`.")


def title_text(stage: str) -> str:
    return f"Grill {stage}"


# ---------------------------------------------------------------- hosts

def detect_host() -> str:
    """Where the calling hub runs: a Codex app thread, another Codex host, a Claude Desktop session (the host id is
    trusted only when Desktop's own record of it names this very CLI session — a child inherits the variable), else a
    Claude host that can start a background session."""
    if engines.codex_desktop():
        return "codex-app"
    if os.environ.get("CODEX_THREAD_ID", "").strip():  # the host itself, not AGENT_HUB_ENGINE (the executors' engine)
        return "manual"
    host = os.environ.get("CLAUDE_CODE_HOST_SESSION_ID", "").strip()
    sid = os.environ.get("CLAUDE_CODE_SESSION_ID", "").strip()
    if host.startswith("local_") and sid and (hc.desktop_session(host) or {}).get("cliSessionId") == sid:
        return "desktop"
    return "bg"


def bg_settings() -> dict:
    homes = list(dict.fromkeys([str(hc.root()), str(hc.root().resolve())]))
    allow = ([f"Bash({c}:*)" for c in GRILL_ALLOW]
             + [f"Bash({tool(c.split()[0])}{c[len(c.split()[0]):]}:*)" for c in GRILL_ALLOW])
    settings = {"permissions": {"allow": allow, "additionalDirectories": homes}}
    settings.update(autopilot.NO_IDLE_COMPACTION)
    return settings


def bg_argv(stage: str, prompt: str, cwd: Path, model: Optional[str], effort: Optional[str]) -> list:
    # --add-dir before the other options: it takes several values and would swallow the prompt
    argv = ["--bg", "--remote-control", f"{stage}-{ROLE}", "-n", title_text(stage)] + hc.add_dir_args(cwd)
    if model:
        argv += ["--model", hc.model_map(cwd).get(model, model)]
    if effort:
        argv += ["--effort", effort]
    return argv + ["--settings", json.dumps(bg_settings(), separators=(",", ":")), prompt]


def bg_env() -> dict:
    """The hub's identity stripped (autopilot.child_env), and AGENT_HUB_ENGINE too: the new session is a Claude session
    whatever engine the hub gives its executors."""
    env = autopilot.child_env()
    env.pop("AGENT_HUB_ENGINE", None)
    return env


def run_cli(cli: str, argv: list, cwd: Path, timeout: int) -> subprocess.CompletedProcess:
    try:
        return subprocess.run([cli] + argv, capture_output=True, text=True, timeout=timeout, cwd=str(cwd),
                              env=bg_env(), stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(argv, 124, "", f"claude {argv[0]} did not finish in {timeout} s")
    except OSError as e:
        return subprocess.CompletedProcess(argv, 127, "", str(e))


class Unsure(hc.Failure):
    """`claude --bg` gave no clear answer: a session may exist all the same, so the launch stays recorded."""


def bg_rows(cli: str, cwd: Path, names: tuple) -> Optional[list]:
    """Background sessions with one of `names` that `claude agents --json` lists; None when it cannot be read."""
    try:
        rows = json.loads(run_cli(cli, ["agents", "--json"], cwd, 30).stdout)
    except ValueError:
        return None
    return [r for r in (rows if isinstance(rows, list) else []) if isinstance(r, dict)
            and r.get("kind") == "background" and r.get("name") in names]


def row_id(r: dict) -> str:
    return r.get("id") or r.get("sessionId") or ""


def listed_bg(cli: str, cwd: Path, names: tuple, since_ms: int, before: Optional[set]) -> Optional[str]:
    """The id of the session this start made: named so, started since `since_ms`, and not listed before the start (a
    launch replaced a moment ago has the same name and may have started within the clock slack). None also when the
    list before the start could not be read: then no listed session can be told apart from an earlier one."""
    if before is None:
        return None
    hits = sorted((r for r in bg_rows(cli, cwd, names) or [] if row_id(r) not in before
                   and isinstance(r.get("startedAt"), (int, float)) and r["startedAt"] >= since_ms),
                  key=lambda r: r["startedAt"])
    return row_id(hits[-1]) if hits else None


def start_bg(cli: str, argv: list, cwd: Path, names: tuple) -> tuple:
    """(background session id, Remote Control link or "") of a `claude --bg` start. Failure when it surely did not
    start; Unsure when it hung or printed no id and `claude agents` does not list it either."""
    rows = bg_rows(cli, cwd, names)
    before = None if rows is None else {row_id(r) for r in rows}
    since_ms = int(time.time() * 1000) - 2000  # a little slack for the daemon's clock
    res = run_cli(cli, argv, cwd, autopilot.BG_TIMEOUT_S)
    out = autopilot.clean(res.stdout + "\n" + res.stderr)
    if res.returncode not in (0, 124):
        if "not trusted" in out.lower():
            raise hc.Failure(f"{cwd} is not trusted by the claude CLI — run `claude` there once and accept the trust "
                             f"prompt, then `hub grill` again")
        raise hc.Failure(f"`claude --bg` exited {res.returncode}: {autopilot.tail(out, 300) or 'no output'}")
    m = autopilot.BG_ID_RE.search(out) if res.returncode == 0 else None
    bg_id = m.group(1) if m else listed_bg(cli, cwd, names, since_ms, before)
    if not bg_id:
        what = "did not return" if res.returncode == 124 else "printed no session id"
        raise Unsure(f"`claude --bg` {what} and `claude agents` lists no session \"{names[0]}\" yet: it may still come up "
                     f"and join by itself — the launch stays recorded ({autopilot.tail(out, 200) or 'no output'})")
    deadline = time.monotonic() + hc.int_setting("AGENT_HUB_GRILL_LINK_WAIT_S", LINK_WAIT_S, minimum=0)
    while True:
        text = autopilot.clean(run_cli(cli, ["logs", bg_id], cwd, 30).stdout)
        link = autopilot.LINK_RE.search(text) or autopilot.LINK_RE.search(text.replace("\n", ""))
        if link:
            url = link.group(0)
            return bg_id, url if url.startswith("http") else "https://" + url
        if "not logged in" in text.lower():
            run_cli(cli, ["stop", bg_id], cwd, 30)
            raise hc.Failure("the background session is not logged in (`claude logs`: \"Not logged in\") — run "
                             "`claude auth login` once in a terminal")
        if time.monotonic() >= deadline:
            return bg_id, ""
        time.sleep(1)


# ---------------------------------------------------------------- commands

def caller_label(stage: str) -> str:
    return hc.caller_tag(stage) or "the owner at a terminal"


def act_on(stages: list) -> str:
    return "; ".join(f"ask list --pending --stage {s}" for s in stages)


def cmd_open(a) -> int:
    stage = hc.check_stage(a.stage)
    host = detect_host() if a.host == "auto" else a.host
    ids = [q for chunk in (a.questions or []) for q in chunk.replace(",", " ").split()]
    also = [hc.check_stage(s) for chunk in (a.also_stage or []) for s in chunk.replace(",", " ").split()]
    questions = collect(stage, also, ids)
    if not questions:
        where = ", ".join(dict.fromkeys([stage] + also))
        print(f"hub grill: no open owner questions in {where} (`ask list --open --stage {stage}`) — nothing to grill; "
              f"a grilling about a new topic runs in the hub itself", file=sys.stderr)
        return 1
    cwd = Path.cwd()
    launch_id = uuid.uuid4().hex[:12]
    brief = hc.work_dir(stage) / f"grill-{hc.now():%Y%m%d-%H%M%S}-brief.md"
    prompt = prompt_text(stage, brief, launch_id)
    tag = hc.caller_tag(stage) or ""
    # the questions' stages, and this stage always: the brief records new questions and decisions here
    stages = list(dict.fromkeys([stage] + [q["stage"] for q in questions]))
    launch = {"title": title_text(stage), "prompt": prompt}
    with state_lock(stage):
        state = load_state(stage)
        why = busy(stage, state)
        if why and not (a.again and not registered(stage)):
            print(f"hub grill: {why}", file=sys.stderr)
            return 2
        text = brief_text(stage, launch_id, questions, a.topic or "", a.owner_words or "", tag or caller_label(stage))
        argv = cli = None
        if host == "bg":
            cli = hc.find_claude(cwd)
            if cli is None:
                raise hc.Failure("claude not found on PATH, and no CLI is bundled with Claude Desktop (set $CLAUDE_BIN)")
            argv = bg_argv(stage, prompt, cwd, a.model, a.effort)
        if a.dry_run:
            print(f"(dry run) brief {brief}:\n{text}")
            if argv:
                print("(dry run) would start: claude " + " ".join(shlex.quote(x) for x in argv))
            print(f"(dry run) host {host}; nothing recorded")
            return 0
        hc.atomic_write(brief, text)
        pend = {"launch": launch_id, "at": hc.now().isoformat(timespec="seconds"), "ts": time.time(), "host": host,
                "brief": str(brief), "questions": [q["id"] for q in questions], "stages": stages, "by": tag,
                "cwd": str(cwd)}
        # recorded before the start: a start that hangs still holds the stage, and a replaced launch cannot join
        state["pending"] = pend
        save_state(stage, state)
        if host == "bg":
            try:
                bg_id, link = start_bg(cli.path, argv, cwd, (f"{stage}-{ROLE}", title_text(stage)))
            except Unsure:
                raise
            except hc.Failure:
                state.pop("pending", None)  # it surely did not start: nothing to hold the stage for
                save_state(stage, state)
                raise
            pend.update(bg_id=bg_id, link=link)
            save_state(stage, state)
    hc.journal_append(stage, tag or autopilot.SERVICE_TAG,
                      f"grill: grilling session launched ({host}, launch {launch_id}) over {len(questions)} owner "
                      f"question(s), brief {brief}")
    print(f"brief: {brief}\nlaunch: {launch_id}\nquestions: {', '.join(pend['questions'])}")
    if host == "desktop":
        args = dict(launch, initiation="user_asked")
        print(json.dumps({"start_session": args, "folder": str(cwd)}, ensure_ascii=False))
        print("Call mcp__ccd_session__start_session with these arguments now, in this turn of the owner's request "
              "(the folder in the tool's folder field, if it has one). Only \"user_asked\": the hook refuses a card "
              "(offer, own_initiative) in a hub. If the app refuses the start (not a turn the owner typed), run "
              f"`{tool('hub')} grill --stage {stage} --host bg --again` and give the owner its link.")
    elif host == "codex-app":
        root = autopilot.main_checkout(cwd) or cwd.resolve()
        args = dict(launch, target={"type": "project", "projectId": "<projectId from list_projects>",
                                    "environment": {"type": "local"}})
        print(json.dumps({"create_thread": args, "project_root": str(root)}, ensure_ascii=False))
        print("Under the owner's request to grill (this turn), the app agent: native list_projects → the one saved "
              "project whose path, normalized to its main checkout, is project_root → put its projectId into target → "
              "native create_thread with these arguments, once. An unknown result is not retried: the session announces "
              "itself with `grill join` in the journal. No project matches: tell the owner and run the manual launch "
              f"(`{tool('hub')} grill --stage {stage} --host manual --again`).")
    elif host == "bg":
        print(f"started: background session {pend['bg_id']} \"{title_text(stage)}\" (claude --bg --remote-control)")
        if pend.get("link"):
            print(f"Give the owner this link to the grilling session: {pend['link']}")
        else:
            print(f"No Remote Control link yet: `claude logs {pend['bg_id']}` shows it; from a terminal the owner "
                  f"joins with `claude attach {pend['bg_id']}`.")
    else:
        cmd = f"codex {shlex.quote(prompt)}" if os.environ.get("CODEX_THREAD_ID") else f"claude {shlex.quote(prompt)}"
        print(f"The owner starts it in a terminal, in {cwd}:\n  cd {shlex.quote(str(cwd))} && {cmd}")
    print(f"When it reports, a line \"@hub GRILLED …\" wakes your jwait: act on `{act_on(stages)}`.")
    return 0


def own_session() -> tuple:
    """(session id to record, cli id, kind, engine) of the calling session, by the host's own identity variables (not
    AGENT_HUB_ENGINE, the executors' engine): a Codex thread by $CODEX_THREAD_ID; a Claude Desktop session by its
    local_ id when Desktop's record of $CLAUDE_CODE_HOST_SESSION_ID names this CLI session; else the CLI uuid."""
    codex = os.environ.get("CODEX_THREAD_ID", "").strip()
    if codex:
        return codex, codex, "cli", "codex"
    sid = os.environ.get("CLAUDE_CODE_SESSION_ID", "").strip() or os.environ.get("AGENT_SESSION_ID", "").strip()
    if not sid:
        raise hc.UsageError("--session self: no session id in this environment ($CLAUDE_CODE_SESSION_ID or "
                            "$CODEX_THREAD_ID); pass the full id")
    host = os.environ.get("CLAUDE_CODE_HOST_SESSION_ID", "").strip()
    if host.startswith("local_") and (hc.desktop_session(host) or {}).get("cliSessionId") == sid:
        return host, sid, "desktop", "claude"
    return sid, sid, "cli", "claude"


def cmd_join(a) -> int:
    stage = hc.check_stage(a.stage)
    roles = roles_module()
    if a.session == "self":
        session, cli, kind, engine = own_session()
        roles.validate_session(session, kind)
    else:
        kind = roles.infer_kind(a.session)
        facts = roles.validate_session(a.session, kind)
        session, cli, engine = facts["session"], facts["cli_session_id"], hc.host_engine()
    with state_lock(stage):
        state = load_state(stage)
        pend = state.get("pending") or {}
        t = hc.now().isoformat(timespec="seconds")
        with hc.roles_lock(stage):
            data = hc.roles_load(stage)
            prev = data["roles"].get(ROLE)
            again = bool(prev) and session in (prev.get("session"), prev.get("cli_session_id"))
            if prev and not again:
                print(f"hub grill join: another grilling session of stage {stage} is registered: {prev.get('session')} "
                      f"since {str(prev.get('set_at'))[:16]} — one per stage; tell the owner and stop", file=sys.stderr)
                return 2
            if not again and (not a.launch or pend.get("launch") != a.launch):
                print(f"hub grill join: launch {a.launch or '(none given)'} of stage {stage} is not the pending one "
                      f"(replaced by a newer launch, or dropped) — tell the owner this session is not needed and stop",
                      file=sys.stderr)
                return 2
            src = prev if again else pend
            rec = {"session": session, "cli_session_id": cli, "kind": kind, "tag": ROLE, "title": title_text(stage),
                   "note": f"grilling session, brief {src.get('brief') or '?'}",
                   "set_at": (prev or {}).get("set_at") if again else t, "engine": engine,
                   "launch": src.get("launch") or "", "brief": src.get("brief") or "",
                   "questions": src.get("questions") or [], "stages": src.get("stages") or [stage],
                   "launched": src.get("launched") if again else src.get("host") or "unknown"}
            data["roles"][ROLE] = rec
            hc.roles_save(stage, data)
        if not again:
            state.pop("pending", None)
            save_state(stage, state)
    if not again:
        hc.journal_append(stage, ROLE, f"grill join: grilling session {session} registered as role {ROLE} "
                                       f"({len(rec['questions'])} question(s), brief {rec['brief'] or '?'})")
    print(f"{ROLE}: {session} ({kind}, tag {ROLE}) — questions: {', '.join(rec['questions']) or 'see the brief'}")
    return 0


def tally(rec: dict) -> dict:
    """The listed questions by their state now, and the entries the grilling session added (`--by grill`) to the
    stages it grilled over since it joined."""
    ask = ask_module()
    out = {"answered": [], "withdrawn": [], "open": [], "new": []}
    for qid in rec.get("questions") or []:
        try:
            e = ask.find_entry(qid)
        except SystemExit:
            out["open"].append(qid)
            continue
        out["answered" if e.state == "answered" else "withdrawn" if e.state == "withdrawn" else "open"].append(qid)
    since = str(rec.get("set_at") or "")[:10]
    listed = set(rec.get("questions") or [])
    for s in rec.get("stages") or []:
        _, entries = ask.load(s)
        out["new"] += [e.id for e in entries if e.id not in listed and e.fields.get("by", "").strip() == ROLE
                       and e.fields.get("asked", "")[:10] >= since]
    return out


def ids_text(ids: list, cap: int = 8) -> str:
    return ", ".join(ids[:cap]) + (f" +{len(ids) - cap}" if len(ids) > cap else "")


def is_caller(rec: dict) -> bool:
    """The calling session is the registered grilling session."""
    try:
        session, cli, _, _ = own_session()
    except hc.UsageError:
        return False
    return bool({session, cli} & {rec.get("session"), rec.get("cli_session_id")} - {None, ""})


def cmd_done(a) -> int:
    stage = hc.check_stage(a.stage)
    with state_lock(stage):
        state = load_state(stage)
        rec = registered(stage)
        if not rec:
            if state.get("pending"):
                state.pop("pending")
                save_state(stage, state)
                hc.journal_append(stage, hc.caller_tag(stage) or autopilot.SERVICE_TAG,
                                  f"grill: the pending grilling launch is dropped — {a.why or a.summary or 'no reason given'}")
                print(f"hub grill done: no grilling session was registered; the pending launch of stage {stage} is dropped")
                return 0
            print(f"hub grill done: no grilling session of stage {stage} is registered and none is pending",
                  file=sys.stderr)
            return 1
        own = is_caller(rec)
        if not own and not a.why:
            print(f"hub grill done: the grilling session of stage {stage} is {rec.get('session')}, not this session — "
                  f"only it reports; the hub or the owner ends it with --why \"…\"", file=sys.stderr)
            return 2
        t = tally(rec)
        n = len(rec.get("questions") or [])
        parts = [f"{len(t['answered'])} answered", f"{len(t['withdrawn'])} withdrawn", f"{len(t['open'])} open of {n}"]
        detail = []
        if t["answered"]:
            detail.append(f"answered {ids_text(t['answered'])}")
        if t["open"]:
            detail.append(f"open {ids_text(t['open'])}")
        if t["new"]:
            detail.append(f"new {ids_text(t['new'])}")
        summary = hc.one_line(a.summary or "")
        ended = "" if own else f" [ended by {caller_label(stage)}: {hc.one_line(a.why)}]"
        line = (f"@hub GRILLED {', '.join(parts)}; {len(t['new'])} new" + (f" ({'; '.join(detail)})" if detail else "")
                + (f" — {summary}" if summary else "") + ended
                + f". Act on: {act_on(rec.get('stages') or [stage])}")
        roles_module().retire_role(stage, ROLE, f"grilling ended: {summary or hc.one_line(a.why or '') or 'done'}")
    hc.journal_append(stage, ROLE if own else (hc.caller_tag(stage) or autopilot.SERVICE_TAG), line)
    print(line)
    return 0


def main(a) -> int:
    return {"open": cmd_open, "join": cmd_join, "done": cmd_done}[a.action](a)


def add_parser(sub, stage_opt) -> None:
    g = sub.add_parser("grill", parents=[stage_opt],
                       help="grill the owner over the stage's open questions in a separate interactive session")
    g.add_argument("action", nargs="?", default="open", choices=("open", "join", "done"),
                   help="open (default): brief and launch; join: the new session registers; done: report and retire")
    g.add_argument("--questions", action="append", metavar="ID,…", help="open: these entries instead of the stage's "
                   "open questions (repeatable, comma-separated)")
    g.add_argument("--also-stage", action="append", metavar="S,…", help="open: also another stage's open questions — "
                   "only a stage the owner named (repeatable)")
    g.add_argument("--topic", help="open: the owner's focus, one line, for the brief")
    g.add_argument("--owner-words", help="open: the owner's request in their words (the authority for the launch)")
    g.add_argument("--host", choices=HOSTS, default="auto", help="open: how to launch (default: from this session)")
    g.add_argument("--model", help="open --host bg: the session's model (default: the CLI's)")
    g.add_argument("--effort", choices=hc.EFFORTS, help="open --host bg: the session's effort (default: the CLI's)")
    g.add_argument("--again", action="store_true", help="open: drop a pending launch that never joined")
    g.add_argument("--dry-run", action="store_true", help="open: print the brief and the launch, record nothing")
    g.add_argument("--session", default="self", help="join: the session to register (default: self)")
    g.add_argument("--launch", help="join: the launch id of the brief (a replaced or dropped launch cannot join)")
    g.add_argument("--summary", help="done: one line — what was decided, what stays open")
    g.add_argument("--why", help="done: why it ends, when the session itself does not run it")
