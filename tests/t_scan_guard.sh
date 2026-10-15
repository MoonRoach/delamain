#!/bin/bash
# hooks/scan_guard.py: a filesystem walk rooted at the home directory or `/` is refused before it runs. On macOS such a
# walk enters ~/Library (Mail, Messages, Safari, Containers…), App Data TCC asks "claude.app would like to access data
# from other apps", and the consent is not kept across agent processes, so the prompt keeps coming back (15.10: five
# prompts in an hour, one of them from `find ~ -name hive1.py` in a background session).
# Controls: both lists of the brief (refused / allowed), the per-command marker, the off switch, the Grep and Glob tools,
# Codex's registration, fail-open on malformed input and on a broken sibling module. Positive control first: a hook
# that does not run must fail the "allowed" half too, so every verdict also asks for exit 0 and no traceback.
. "$(dirname "$0")/lib.sh"
new_home; R=$AGENT_HUB_HOME; mkdir -p "$R"
python3 - "$T/.." "$R" <<'PY'
import json, os, shutil, subprocess, sys
from pathlib import Path

ROOT, WORK = Path(sys.argv[1]).resolve(), Path(sys.argv[2])
HOOK = ROOT / "hooks" / "scan_guard.py"
H = WORK / "home"          # the test's HOME: `~`, `$HOME` and the absolute path all mean this
W = WORK / "work"          # a session cwd that is not the home
for d in (H / "repos" / "app" / "src", H / "agent-hub", H / "Library" / "LaunchAgents", W):
    d.mkdir(parents=True, exist_ok=True)
HS, WS = str(H), str(W)
fail = 0


def check(ok, what):
    global fail
    print(("PASS " if ok else "FAIL ") + what)
    fail |= 0 if ok else 1


def env(**extra):
    e = {k: v for k, v in os.environ.items() if not k.startswith(("AGENT_HUB_", "HUB_", "CLAUDE_", "CODEX_", "PLUGIN_ROOT"))}
    e.update(HOME=HS, AGENT_HUB_HOME=str(WORK / "hub"), AGENT_HUB_TZ="UTC")
    e.update(extra)
    return e


def run(event, hook=HOOK, **extra):
    data = event if isinstance(event, bytes) else json.dumps(event).encode()
    return subprocess.run([sys.executable, str(hook)], input=data, capture_output=True, env=env(**extra), timeout=30)


def verdict(r):
    """'deny' | 'pass' | 'broken': a hook that crashed, did not start or printed garbage is neither of the first two."""
    if r.returncode != 0 or b"Traceback" in r.stderr:
        return "broken"
    if not r.stdout.strip():
        return "pass"
    try:
        out = json.loads(r.stdout)["hookSpecificOutput"]
    except (ValueError, KeyError, TypeError):
        return "broken"
    return "deny" if out.get("permissionDecision") == "deny" else "broken"


def bash(cmd, cwd=WS, **extra):
    return run({"hook_event_name": "PreToolUse", "tool_name": "Bash", "cwd": cwd, "tool_input": {"command": cmd.replace("@H@", HS)}}, **extra)


def tool(name, cwd=WS, **ti):
    return run({"hook_event_name": "PreToolUse", "tool_name": name, "cwd": cwd,
                "tool_input": {k: (v.replace("@H@", HS) if isinstance(v, str) else v) for k, v in ti.items()}})


def reason(r):
    """The refusal text, or "" when there is none: a check on it then fails instead of the script crashing."""
    return json.loads(r.stdout)["hookSpecificOutput"]["permissionDecisionReason"] if verdict(r) == "deny" else ""


# ---- positive control: the hook exists, runs, and refuses the incident command
check(HOOK.is_file(), "hooks/scan_guard.py exists")
check(verdict(bash("find ~ -name hive1.py -not -path '*/node_modules/*'")) == "deny", "the 15.10 incident command is refused")

# ---- refused: commands (cwd is not the home unless a pair says so)
REFUSED = [
    # the brief's list
    "find ~ -name x", "find @H@ -name x", "find $HOME -name x", "find ${HOME} -name x", "find \"$HOME\" -name x",
    "find ~/ -name x", "find @H@/ -name x", "find /Users -name x", "find / -name x",
    "rg foo ~", "grep -r foo ~", "du -sh ~/*", "fd x /", "cd ~ && find . -name x",
    # more shapes of the same walk
    "find ~ -name hive1.py -not -path '*/node_modules/*'", "find -L ~ -name x", "find ~ -type f -name '*.py' | head",
    "bfs ~ -name x", "find ~/Library -name x", "find ~/Library/Containers -name x",
    "find \"$HOME/Library/Group Containers\" -name x", "find ~/Library/Group\\ Containers -name x",
    "find ~/\"Library\" -name x", "find ~/./Library -name x", "find @H@/repos/.. -name x", "find ~/Library/.. -name x",
    "find ~/* -name x", "find ~/L* -name x", "find /* -name x", "find /Users/* -name x", "find ~/Library/* -name x",
    "rg -g '*.py' foo $HOME", "rg --files ~", "rg -e foo ~", "rg -t py -i foo ~", "rg --glob '*.md' foo / ",
    "grep -rn foo ~", "grep -R foo $HOME", "grep --recursive foo ~", "grep -e foo -r ~", "grep foo -rl ~", "egrep -ri 'a|b' ~",
    "grep -d recurse foo ~", "grep --directories=recurse foo ~", "grep -rn -A 3 foo ~",
    "du -sh ~", "du -sh $HOME/*", "du -d 1 ~", "du -sk /Users", "du -sh ~/Library",
    "fd x ~", "fd -e py . ~", "fd --hidden x /Users", "fd -t f -e py x $HOME", "fd --search-path ~ x",
    "ag foo ~", "ack foo ~", "ag -g '\\.py$' ~", "tree ~", "tree -L 3 ~", "tree -a /",
    "ls -R ~", "ls -laR $HOME", "ls -lR / ", "ls --recursive ~",
    # prefixes, pipelines, wrappers
    "sudo find / -name x", "env FOO=1 find ~ -name x", "timeout 20 find ~ -name x", "nohup find ~ -name x &",
    "FOO=1 find ~ -name x", "time find ~ -name x", "true && find ~ -name x", "ls; find ~ -name x", "x=1\nfind ~ -name x",
    "echo x | xargs find ~ -name", "echo x | xargs -I{} find ~ -name {}", "xargs -n1 find ~", "/usr/bin/find ~ -name x",
    "if find ~ -name x | grep -q .; then echo y; fi", "(find ~ -name x)", "{ find ~ -name x; }", "! find ~ -name x",
    "bash -c 'find ~ -name x'", "bash -c \"cd ~ && find . -name x\"", "echo 'find ~ -name x' | sh", "eval find ~ -name x",
    "eval \"grep -r foo ~\"", "echo $(find ~ -name x)", "x=$(rg foo ~)", "echo `du -sh ~`",
    "find ~ -name x &", "find ~ -name x 2>/dev/null", "find ~ -name x >out.txt 2>&1",
    # the effective cwd is the home through cd
    "cd ~ && rg foo", "cd $HOME; grep -r foo .", "cd; du -sh *", "cd \"$HOME\" && find . -name x", "cd @H@ && find -name x",
    "cd ~ && fd x", "cd ~ && tree", "cd ~ && ls -R", "cd ~/repos && cd ~ && find . -name x",
    "(cd ~ && find . -name x)", "pushd ~ && find . -name x", "cd ~ && find . -maxdepth 3 -name x",
]
for c in REFUSED:
    check(verdict(bash(c)) == "deny", f"refused: {c!r}")
# the effective cwd is the home because the session is there
CWD_HOME = ["find . -name x", "find -name x", "find ./ -name x", "rg foo", "rg foo .", "grep -r foo .", "grep -rn foo", "du -sh *",
            "du -sh .", "fd x", "tree", "ls -R", "ack foo", "ag foo", "find * -name x", "cd . && find . -name x", "cd ~/repos && cd .. && find . -name x"]
for c in CWD_HOME:
    check(verdict(bash(c, cwd=HS)) == "deny", f"refused with the session in the home: {c!r}")
check(verdict(bash("find . -name x", cwd=HS + "/")) == "deny", "refused with the session in the home written with a trailing slash")
check(verdict(bash("find . -name x", cwd="/Users")) == "deny", "refused with the session in /Users")
check(verdict(bash("find . -name x", cwd="/")) == "deny", "refused with the session in /")

# ---- allowed
ALLOWED = [
    # the brief's list
    "find ~/repos -name x", "find . -name x", "rg foo ~/agent-hub", "grep -r foo src", "find ~/Library/LaunchAgents -name '*.plist'",
    "ls ~", "du -sh ~/repos", "grep foo ~/.zshrc",
    # a named subdirectory, in every spelling
    "find $HOME/repos -name x", "find \"$HOME/repos\" -name x", "find @H@/repos/app -name x", "find ~/repos ~/agent-hub -name x",
    "find ~/repos/ -name x", "rg foo -- ~/repos", "rg -g '*.md' foo docs", "grep -r foo ~/.config", "grep -rn foo ~/Library/LaunchAgents",
    "fd x ~/repos", "fd -e py x", "ag foo ~/repos", "ack foo src", "tree ~/repos", "tree -L 2 src", "ls -R ~/repos", "ls -la ~", "ls ~/Library",
    "ls ~/*", "ls -d ~/*", "du -sh ~/*.md", "du -sh ~/.zsh*", "du -sh ~/repos/*", "du -sh /tmp /var/log", "find /tmp -name x", "find /usr/local -name x",
    "find ~/.* -maxdepth 0", "rg foo /etc", "grep -r foo /var/log",
    # not a walk, or a walk that stays in the home's first level
    "grep foo ~/.zshrc", "grep -n foo ~", "cat ~/.zshrc | grep foo", "cat x | rg foo", "cat x | grep -r foo", "rg foo < notes.txt",
    "find ~ -maxdepth 1 -name '.*'", "find ~ -maxdepth 0", "find / -maxdepth 1 -name x", "fd -d 1 x ~", "fd --max-depth 1 x /", "tree -L 1 ~",
    "rg --max-depth 1 foo ~", "ag --depth 1 foo ~", "ls ~/Library/Containers", "stat ~/Library", "cd ~ && ls", "cd ~ && ls -la", "cd ~ && pwd",
    "cd ~ && cat .zshrc", "cd ~ && grep foo .zshrc", "cd ~ && git status", "cd ~; echo done",
    # cd away from the home, in every spelling, before the walk
    "cd ~/repos && find . -name x", "cd ~ && cd repos && find . -name x", "cd $HOME/repos; rg foo", "cd @H@/repos/app && grep -r foo .",
    "cd ~ && cd repos/app && du -sh *", "cd /tmp && find . -name x", "(cd ~ && ls); find . -name x", "(cd ~/repos && find . -name x)",
    "cd ~ && cd /tmp && find . -name x",
    # quoted text no shell runs
    "echo \"find ~ -name x\"", "git commit -m \"find ~ -name x\"", "grep 'find ~' notes.md", "echo 'rg foo ~' > notes.txt", "printf 'du -sh ~\\n'",
    "cat > notes.md <<'EOF'\nfind ~ -name x\nEOF", "command -v find", "which find", "type rg", "man find", "git grep -n foo", "git ls-files",
    # a command that runs elsewhere
    "ssh host \"find ~ -name x\"", "ssh host find / -name x", "ssh host 'cd ~ && grep -r foo .'",
    # unresolved words are not guessed
    "find $(echo ~) -name x", "find $FOO -name x", "find ~user -name x", "find ${HOME:-/x} -name x", "find '~' -name x", "find '$HOME' -name x",
    "find \"~\" -name x", "find {a,b} -name x", "cd $SOMEWHERE && find . -name x", "cd - && find . -name x", "cd \"$(mktemp -d)\" && find . -name x",
    # other commands
    "git status", "ls", "echo hello", "python3 -c 'print(1)'", "tail -n 5 ~/.zshrc",
    # the per-command marker, for a walk the owner asked for
    "find ~ -name x  # scan-ok: owner asked for this walk", "grep -r foo ~ # scan-ok", "cd ~ && find . -name x # scan-ok: owner asked",
    "du -sh ~/* # scan-ok", "find ~ -name x\n# scan-ok: owner asked",
]
for c in ALLOWED:
    check(verdict(bash(c)) == "pass", f"allowed: {c!r}")
check(verdict(bash("find -name x", cwd=WS)) == "pass", "allowed: a walk with no path while the session is not in the home")
check(verdict(bash("find . -name x", cwd=HS + "/repos")) == "pass", "allowed: a relative walk in a project under the home")
check(verdict(bash("ls -R", cwd=HS + "/agent-hub")) == "pass", "allowed: ls -R in the hub home")
check(verdict(bash("find . -maxdepth 1 -name x", cwd=HS)) == "pass", "allowed: a one-level walk in the home")
check(verdict(bash("cat x | rg foo", cwd=HS)) == "pass", "allowed: rg reading a pipe while the session is in the home")
check(verdict(bash("find ~ -name x # scan-ok: asked", cwd=HS)) == "pass", "allowed: the marker with the session in the home")

# ---- the marker is the configured word; the switch turns the guard off; both are read from the environment
check(verdict(bash("find ~ -name x # kill-ok")) == "deny", "another guard's marker does not pass a walk")
check(verdict(bash("find ~ -name x # scan-okay")) == "deny", "the marker is a whole word")
check(verdict(bash("find ~ -name x # scan-ok", AGENT_HUB_SCAN_ESCAPE="walk-ok")) == "deny", "AGENT_HUB_SCAN_ESCAPE replaces the word")
check(verdict(bash("find ~ -name x # walk-ok", AGENT_HUB_SCAN_ESCAPE="walk-ok")) == "pass", "  and its word passes")
for off in ("off", "OFF", "0", "false", "no"):
    check(verdict(bash("find ~ -name x", AGENT_HUB_SCAN_GUARD=off)) == "pass", f"AGENT_HUB_SCAN_GUARD={off} turns it off")
check(verdict(bash("find ~ -name x", AGENT_HUB_SCAN_GUARD="on")) == "deny", "AGENT_HUB_SCAN_GUARD=on keeps it on")
cfg = WORK / "hub"
cfg.mkdir(parents=True, exist_ok=True)
(cfg / "config.json").write_text(json.dumps({"AGENT_HUB_SCAN_GUARD": "off"}))
check(verdict(bash("find ~ -name x")) == "pass", "the hub home's config.json can turn it off")
(cfg / "config.json").write_text(json.dumps({"AGENT_HUB_SCAN_GUARD": "on"}))
check(verdict(bash("find ~ -name x")) == "deny", "  and on")
(cfg / "config.json").unlink()

# ---- the refusal text: what happened, why, where to search instead, how to override
r = bash("find ~ -name hive1.py")
text = reason(r)
check("macOS" in text and "data from other apps" in text, "the reason names the macOS privacy prompt")
check("find ~ -name hive1.py" in text, "  quotes the command")
check("AGENT_HUB_HOME" in text and "subdirectory" in text, "  says where to search instead: the project, the hub home, a named subdirectory")
check("# scan-ok" in text, "  names the per-command marker")
check(0 < len(text.splitlines()) <= 12 and len(text) < 1200, f"  stays short ({len(text)} characters)")
text = reason(bash("find ~ -name x", AGENT_HUB_SCAN_ESCAPE="walk-ok"))
check("# walk-ok" in text and "# scan-ok" not in text, "  names the configured marker word")
check("filesystem" in reason(bash("find / -name x")), "  says what the root was for `/`")
check("current directory" in reason(bash("rg foo", cwd=HS)), "  says when the root is the current directory, which is the home")

# ---- the Grep and Glob tools
TOOL_REFUSED = [
    ("Grep", dict(pattern="foo", path="~")), ("Grep", dict(pattern="foo", path="@H@")), ("Grep", dict(pattern="foo", path="@H@/")),
    ("Grep", dict(pattern="foo", path="$HOME")), ("Grep", dict(pattern="foo", path="${HOME}")), ("Grep", dict(pattern="foo", path="~/")),
    ("Grep", dict(pattern="foo", path="/")), ("Grep", dict(pattern="foo", path="/Users")), ("Grep", dict(pattern="foo", path="~/Library")),
    ("Grep", dict(pattern="foo", path="@H@/Library/Containers", output_mode="files_with_matches")),
    ("Grep", dict(pattern="foo", path="@H@/Library/Group Containers")),
    ("Glob", dict(pattern="**/*.py", path="$HOME")), ("Glob", dict(pattern="**/*.py", path="~")), ("Glob", dict(pattern="**/x", path="@H@")),
    ("Glob", dict(pattern="**/x", path="/")), ("Glob", dict(pattern="**/x", path="~/Library")),
    ("Glob", dict(pattern="*.py", path="~")), ("Glob", dict(pattern="*", path="@H@")),
    ("Glob", dict(pattern="~/**/*.py")), ("Glob", dict(pattern="@H@/**/hive1.py")), ("Glob", dict(pattern="$HOME/**/x")),
]
for name, ti in TOOL_REFUSED:
    check(verdict(tool(name, **ti)) == "deny", f"refused: {name} {ti}")
for name, ti in (("Grep", dict(pattern="foo")), ("Glob", dict(pattern="**/*.py")), ("Grep", dict(pattern="foo", glob="*.py")),
                 ("Grep", dict(pattern="foo", path="."))):
    check(verdict(tool(name, cwd=HS, **ti)) == "deny", f"refused with the session in the home: {name} {ti}")
TOOL_ALLOWED = [
    ("Grep", dict(pattern="foo")), ("Grep", dict(pattern="foo", path="~/repos")), ("Grep", dict(pattern="foo", path="@H@/agent-hub")),
    ("Grep", dict(pattern="foo", path="$HOME/repos/app/src")), ("Grep", dict(pattern="foo", path="~/.zshrc")),
    ("Grep", dict(pattern="foo", path="~/Library/LaunchAgents")), ("Grep", dict(pattern="foo", path="/tmp")),
    ("Grep", dict(pattern="foo", path="src")), ("Grep", dict(pattern="foo", path=WS)),
    ("Glob", dict(pattern="**/*.py")), ("Glob", dict(pattern="**/*.py", path="$HOME/repos")),
    ("Glob", dict(pattern="~/*.md")), ("Glob", dict(pattern="~/repos/**/*.py")), ("Glob", dict(pattern="@H@/agent-hub/**/*.md")),
    ("Glob", dict(pattern="src/**/*.ts", path="~/repos/app")),
]
for name, ti in TOOL_ALLOWED:
    check(verdict(tool(name, **ti)) == "pass", f"allowed: {name} {ti}")
check(verdict(tool("Grep", cwd=HS + "/repos", pattern="foo")) == "pass", "allowed: Grep with no path in a project under the home")
check(verdict(tool("Grep", cwd=HS + "/repos", pattern="foo", path="src")) == "pass", "allowed: Grep with a relative path under the home")
check(verdict(tool("Grep", cwd=HS, pattern="foo", path="repos")) == "pass", "allowed: Grep with a relative subdirectory while the session is in the home")
r = tool("Grep", pattern="foo", path="~")
check("Bash" in reason(r), "the tool refusal says how a deliberate walk goes: through Bash with the marker")
check(verdict(run({"hook_event_name": "PreToolUse", "tool_name": "Grep", "cwd": WS, "tool_input": {"pattern": "x", "path": "~"}},
                  AGENT_HUB_SCAN_GUARD="off")) == "pass", "AGENT_HUB_SCAN_GUARD=off turns it off for Grep too")
for name in ("Read", "Write", "Edit", "WebFetch", "Agent"):
    r = run({"hook_event_name": "PreToolUse", "tool_name": name, "cwd": HS, "tool_input": {"file_path": HS, "path": "~", "pattern": "**"}})
    check(verdict(r) == "pass" and not r.stdout.strip(), f"other tools are untouched: {name}")

# ---- fail-open: malformed input, a broken configuration, a broken sibling module, pathological commands
deep = b"[" * 60000 + b"]" * 60000
BAD = {
    "empty": b"", "garbage": b"not json", "list": b"[]", "null": b"null", "string": b'"x"', "nested 60000 deep": deep,
    "tool_input is a string": b'{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":"x"}',
    "command is a number": b'{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":123},"cwd":"/"}',
    "command is null": b'{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":null}}',
    "cwd is a number": b'{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"find ~ -name x"},"cwd":5}',
    "no cwd": b'{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"find . -name x"}}',
    "invalid UTF-8": b'\xff\xfe{"a":1}',
    "lone surrogate": b'{"tool_name":"Bash","tool_input":{"command":"find ~ \\ud800 -name x"},"cwd":"/"}',
    "Grep path is a number": b'{"tool_name":"Grep","tool_input":{"pattern":"x","path":5},"cwd":"/"}',
    "Grep path is a list": b'{"tool_name":"Grep","tool_input":{"pattern":"x","path":["~"]},"cwd":"/"}',
    "Glob pattern is null": b'{"tool_name":"Glob","tool_input":{"pattern":null,"path":null},"cwd":"/"}',
    "Glob tool_input is null": b'{"tool_name":"Glob","tool_input":null,"cwd":"/"}',
}
bad = [f"{name}: {verdict(r)} {r.stderr[-80:]!r}" for name, data in BAD.items() for r in [run(data)] if verdict(r) == "broken"]
check(not bad, f"malformed input: exit 0 and no traceback ({len(BAD)} inputs)" + (f": {bad[:3]}" if bad else ""))
check(verdict(run(b'{"tool_name":"Bash","tool_input":{"command":"find ~ -name x"},"cwd":5}')) in ("pass", "deny"),
      "a cwd of the wrong type is read as no cwd")
bad = subprocess.run([sys.executable, str(HOOK)], stdin=subprocess.DEVNULL, capture_output=True, env=env(), timeout=30)
check(verdict(bad) == "pass", "stdin that is /dev/null: exit 0, no decision")
(WORK / "hubfile").write_text("not a directory")
check(verdict(bash("find ~ -name x", AGENT_HUB_HOME=str(WORK / "hubfile"))) == "deny", "an unusable hub home: the built-in defaults still apply")
(cfg / "config.json").write_text("{ broken json")
check(verdict(bash("find ~ -name x")) == "deny", "a broken config.json: the built-in defaults still apply")
(cfg / "config.json").unlink()
# a sibling module that cannot be imported: the fail-safe turns the crash into "no decision"
broken = WORK / "broken"
(broken / "hooks").mkdir(parents=True)
for f in (ROOT / "hooks").glob("*.py"):
    shutil.copy(f, broken / "hooks" / f.name)
(broken / "bin").symlink_to(ROOT / "bin")
(broken / "hooks" / "kill_guard.py").write_text("raise ImportError('sibling module is broken')\n")
r = run({"tool_name": "Bash", "cwd": WS, "tool_input": {"command": "find ~ -name x"}}, hook=broken / "hooks" / "scan_guard.py")
check(r.returncode == 0 and not r.stdout.strip(), f"a sibling module that fails to import: exit {r.returncode}, no output")
text = (broken / "hooks" / "scan_guard.py").read_text().replace("failsafe.install()", "pass")
(broken / "hooks" / "scan_guard_nofs.py").write_text(text)
r = run({"tool_name": "Bash", "cwd": WS, "tool_input": {"command": "find ~ -name x"}}, hook=broken / "hooks" / "scan_guard_nofs.py")
check(r.returncode != 0, f"negative control: the same break without the fail-safe is a crash (exit {r.returncode})")
# an error inside the check itself: the hook answers nothing instead of blocking
text = (ROOT / "hooks" / "scan_guard.py").read_text()
check("def check(" in text, "scan_guard.py has a check() the control below can break")
(broken / "hooks" / "kill_guard.py").write_text((ROOT / "hooks" / "kill_guard.py").read_text())
import re
polling = re.sub(r"(def views\([^\n]*\):\n)", r"\1    raise RuntimeError('boom')\n", (ROOT / "hooks" / "polling_guard.py").read_text(), count=1)
check("boom" in polling, "the control breaks polling_guard.views, which the scan guard reads commands through")
(broken / "hooks" / "polling_guard.py").write_text(polling)
r = run({"tool_name": "Bash", "cwd": WS, "tool_input": {"command": "find ~ -name x"}}, hook=broken / "hooks" / "scan_guard.py")
check(r.returncode == 0 and not r.stdout.strip(), "an exception inside the parser: exit 0, no decision (fail open)")
# pathological commands: bounded time, no traceback
import time
for label, cmd in (("nested substitutions", "x=$(" * 800 + "find ~" + ")" * 800), ("deep $( chain", "$(a " * 500 + "find ~ -name x" + ")" * 500),
                   ("5000 pipes", "a | " * 5000 + "b"), ("long argument list", "find ~ " + "-name x -o " * 20000),
                   ("many stages", "cd ~; " * 20000 + "ls"), ("many words", "rg foo " + "a " * 100000),
                   ("many quotes", "echo " + "'a' " * 30000 + "; find ~ -name x"), ("deep parentheses", "(" * 3000 + "find ~" + ")" * 3000)):
    t0 = time.time()
    r = bash(cmd)
    check(verdict(r) != "broken" and time.time() - t0 < 6, f"pathological command ({label}): answered in {time.time() - t0:.1f} s, exit {r.returncode}")

# ---- registration: Claude and Codex
claude = json.loads((ROOT / "hooks" / "hooks.json").read_text())["hooks"]["PreToolUse"]
codex = json.loads((ROOT / "hooks" / "codex-hooks.json").read_text())["hooks"]["PreToolUse"]


def registered(groups, matcher):
    return [g["matcher"] for g in groups if any("scan_guard.py" in h["command"] for h in g["hooks"]) and g["matcher"] == matcher]


check(bool(registered(claude, "Bash")), "hooks.json: scan_guard.py runs on Bash")
check(bool(registered(claude, "Grep|Glob")), "hooks.json: scan_guard.py runs on Grep|Glob")
check(bool(registered(codex, "Bash")), "codex-hooks.json: scan_guard.py runs on Bash (exec_command and its aliases)")
check(not any("Grep" in g["matcher"] and any("scan_guard" in h["command"] for h in g["hooks"]) for g in codex),
      "codex-hooks.json: no Grep/Glob matcher (Codex has no such tools to match)")
for label, groups, pattern in (("hooks.json", claude, "python3"), ("codex-hooks.json", codex, "run-python")):
    hooks = [h for g in groups for h in g["hooks"] if "scan_guard.py" in h["command"]]
    check(bool(hooks) and all(pattern in h["command"] and h["timeout"] == 10 for h in hooks), f"{label}: the command and the 10 s timeout follow the other guards")
sys.path.insert(0, str(ROOT / "hooks"))
import failsafe
check("scan_guard.py" in failsafe.DEADLINES, "failsafe.DEADLINES lists scan_guard.py")
sys.exit(fail)
PY
fail=$?
exit $fail
