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
    "find ~/* -name x", "find ~/L* -name x", "find /* -name x", "find /Users/* -name x", "find /Users/*/Library -name x", "du -sh /Users/*/Library/Containers", "find ~/Library/* -name x",
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
    # found by the review: dot-globs reach `.` and `..`, a `(` after a keyword, a cd that stays inside bash -c, wrappers by path
    "du -sh ~/.*", "cd ~ && du -sh .*", "cd ~ && find .* -name x", "find ~/.* -name x", "cd ~ && rg foo .*",
    "for d in a; do (cd ~ && find . -name x); done", "if (find ~ -name x); then echo; fi", "! (find ~ -name x)", "time (find ~ -name x)",
    "( (find ~ -name x) )", "cd ~ && bash -c \"cd /tmp\" && find . -name x", "cd ~ && sh -c 'cd /tmp' && rg foo",
    "/usr/bin/env find ~ -name x", "/usr/bin/env -i find ~ -name x", "/usr/bin/time find ~ -name x", "gtimeout 10 find ~ -name x",
    "caffeinate -i find ~ -name x", "setsid -f find ~ -name x", "exec -a x find ~ -name x", "command -p find ~ -name x",
    "find /Users/*/Library -name x", "du -sh /Users/*/Library/Containers", "find ~/Library/.. -name x",
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
    # ssh, a container and a pod run the string elsewhere; a case-sensitive glob does not reach Library
    "x=$(ssh host \"find / -name x\")", "echo $(ssh host \"find / -name x\")", "docker exec c sh -c 'find / -name x'",
    "kubectl exec pod -- sh -c 'du -sh /'", "sudo docker exec c bash -c \"cd ~ && grep -r foo .\"", "docker run --rm img find / -name x",
    "find ~/[a-z]* -name x", "find ~/l* -name x", "bash -c 'cd ~ && ls'; find . -name x", "bash -c 'cd ~' && find . -name x",
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
for c in ("fd --version", "find --version", "tree --help", "du --version", "rg --version", "ag --list-file-types", "ack --help-types", "grep -r -V",
          "cd ~ && tree --version", "for d in */; do (cd \"$d\" && find . -name x); done", "cd repos && bash -c 'cd ~ && ls' && find . -name x",
          "grep -r foo <<EOF\nfoo\nEOF", "rg foo <<-EOF\nfoo\nEOF", "cd repos && find . -name x", "ls -R repos"):
    check(verdict(bash(c, cwd=HS)) == "pass", f"allowed with the session in the home: {c!r}")

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
TOOL_REFUSED += [("Glob", dict(pattern="../**/*.py"), "@H@/repos"), ("Glob", dict(pattern="**/x", path=".."), "@H@/repos"),
                 ("Grep", dict(pattern="x", path=".."), "@H@/repos")]
for name, ti in [x[:2] for x in TOOL_REFUSED if len(x) == 2]:
    check(verdict(tool(name, **ti)) == "deny", f"refused: {name} {ti}")
for name, ti in (("Grep", dict(pattern="foo")), ("Glob", dict(pattern="**/*.py")), ("Grep", dict(pattern="foo", glob="*.py")),
                 ("Grep", dict(pattern="foo", path="."))):
    check(verdict(tool(name, cwd=HS, **ti)) == "deny", f"refused with the session in the home: {name} {ti}")
for name, ti, cwd in [x for x in TOOL_REFUSED if len(x) == 3]:
    check(verdict(tool(name, cwd=cwd.replace("@H@", HS), **ti)) == "deny", f"refused from a project under the home: {name} {ti}")
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
for ti in (dict(pattern="repos/**/*.py"), dict(pattern="agent-hub/**/*.md"), dict(pattern="repos/*.py")):
    check(verdict(tool("Glob", cwd=HS, **ti)) == "pass", f"allowed: Glob {ti} while the session is in the home: the walk starts in a subdirectory")
check(verdict(tool("Glob", cwd=HS, pattern="repos/**/*.py", path="@H@")) == "pass", "allowed: Glob path=home with a pattern that names a subdirectory")
check(verdict(tool("Glob", cwd=HS, pattern="**/*.py", path="@H@")) == "deny", "refused: Glob path=home with a pattern that names none")
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

# ---- round 2 of the review (Codex Astra, PR #104): heredoc delimiters and per-command heredocs, printed `bash -c`, `env -C`, `cd` scope
R2_PASS = [
    # a heredoc whose delimiter has a dash or a dot, bare or quoted: its body is text, whatever it says
    "cat <<'END-NOTES'\nfind ~ -name x\nEND-NOTES", "cat <<'END.NOTES'\nfind ~ -name x\nEND.NOTES", "cat <<\"END-NOTES\"\nfind ~ -name x\nEND-NOTES",
    "cat <<END-NOTES\nfind ~ -name x\nEND-NOTES", "cat <<\\END-NOTES\nfind ~ -name x\nEND-NOTES", "cat <<-'END-NOTES'\n\tfind ~ -name x\n\tEND-NOTES",
    "python3 - <<'PY-CODE'\n# example\nfind ~ -name x\nPY-CODE", "cat > notes.md <<'EOF'\nfind ~ -name x\nEOF\ncat notes.md",
    "cat <<'EOF' > ~/notes.md\nfind ~ -name x\nEOF", "cat <<'E'\"O\"F\nfind ~ -name x\nEOF",
    # the heredoc of a command that runs it elsewhere
    "ssh host bash <<'EOF'\nfind ~ -name x\nEOF", "cat <<EOF | ssh host bash\nfind ~ -name x\nEOF",
    # a string printed, logged or passed on that happens to read like `bash -c '…'`: no shell runs it
    "echo bash -c 'find ~ -name x'", "printf '%s\\n' bash -c 'find ~ -name x'", "jlog bash -c 'find ~ -name x'", "echo sh -c \"find ~ -name x\"",
    "echo eval 'find ~ -name x'", "echo sudo bash -c 'find ~ -name x'", "jlog PROGRESS bash -lc 'find ~ -name x' && echo ok",
    "sleep 1 & echo bash -c 'find ~ -name x'", "true & jlog bash -c 'find ~ -name x'",
    "git commit -m \"$(cat <<'EOF'\nfix: find ~ -name x is refused\nEOF\n)\"",
    # `cd` in a pipeline or in the background does not move the shell
    "cd ~ | cat; find . -name x", "cd ~ & wait; find . -name x", "echo x | cd ~; find . -name x", "cd ~ |& cat; find . -name x",
    "cd ~ && ls & find . -name x", "true & cd ~ & find . -name x",
    # `env -C` / `--chdir` / `sudo -D` give the child its own directory
    "env -C /tmp find . -name x", "env --chdir=/tmp find . -name x", "env --chdir /tmp find . -name x", "env -C ~/repos find . -name x",
    "env -C /tmp -i FOO=1 find . -name x", "env -C ~/repos rg foo", "sudo -D /tmp find . -name x", "env -C \"$(mktemp -d)\" find . -name x",
    "env -C /tmp bash -c 'find . -name x'",
]
for c in R2_PASS:
    check(verdict(bash(c)) == "pass", f"round 2, allowed: {c!r}")
for c in ("env -C /tmp find . -name x", "env --chdir=/tmp find . -name x", "env --chdir /tmp rg foo", "env -C ~/repos find . -name x", "env -C \"$(mktemp -d)\" find . -name x",
          "rg foo <<EOF\nx\nEOF", "cat <<EOF | rg foo\nx\nEOF", "rg foo <<'END-NOTES'\nx\nEND-NOTES", "rg foo <<< \"x\"", "cat <<'E-1'\nrg foo\nE-1",
          "cat <<'E-1'\nfind ~ -name x\nE-1\ncd repos\nrg foo"):
    check(verdict(bash(c, cwd=HS)) == "pass", f"round 2, allowed with the session in the home: {c!r}")
R2_REFUSED = [
    # a heredoc that a shell reads still runs its body; what follows the opener on its line is not part of the body
    "bash <<'END-NOTES'\nfind ~ -name x\nEND-NOTES", "cat <<'END-NOTES' | sh\nfind ~ -name x\nEND-NOTES", "bash <<END.NOTES\nfind ~ -name x\nEND.NOTES",
    "cat <<EOF && find ~ -name x\nhi\nEOF", "cat <<'END-NOTES'; find ~ -name x\nhi\nEND-NOTES", "cat <<EOF | xargs find ~ -name\nhi\nEOF",
    "cat <<'END-NOTES'\nhi\nEND-NOTES\nfind ~ -name x", "cat <<-EOF\n\thi\n\tEOF\nfind / -name x", "bash <<'EOF' && find ~ -name x\ncd /tmp\nEOF",
    # more than a hundred `<<` is no reason to stop reading
    "echo x " + "<<A " * 150 + "; find ~ -name x", "echo '<<' " * 150 + "; find ~ -name x",
    # a `bash -c` / `eval` string at the command position, behind every wrapper, still runs
    "bash -c 'find ~ -name x'", "sudo bash -c 'find ~ -name x'", "env FOO=1 bash -c 'find ~ -name x'", "timeout 5 bash -c 'find ~ -name x'",
    "nohup bash -c 'find ~ -name x' &", "echo x | xargs -I{} sh -c 'find ~ -name x'", "time bash -lc 'find ~ -name x'", "(bash -c 'find ~ -name x')",
    "if bash -c 'find ~ -name x'; then echo y; fi", "env -C /tmp bash -c 'find ~ -name x'", "bash -eo pipefail -c 'find ~ -name x'",
    "find . -name y -exec bash -c 'find ~ -name x' _ {} \\;", "watch bash -c 'find ~ -name x'", "FOO=bar bash -c 'find ~ -name x'",
    "echo ok; bash -c 'find ~ -name x'", "echo ok && eval 'find ~ -name x'", "sleep 1 & bash -c 'find ~ -name x'",
    "echo hi &bash -c 'find ~ -name x'", "echo hi & eval 'find ~ -name x'", "true & echo ok & sudo env X=1 sh -c 'find ~ -name x'", "echo \"$(find ~ -name x)\"", "jlog \"$(find ~ -name x)\"",
    "echo bash -c \"$(find ~ -name x)\"", "printf 'find ~ -name x' | bash",
    # `env -C` moves the child into the home
    "env -C ~ find . -name x", "env -C @H@ rg foo", "env --chdir=$HOME find . -name x", "env --chdir ~ du -sh *", "env -C ~ -i find . -name x",
    "env -C ~/repos find ~ -name x", "sudo -D ~ find . -name x", "env -C ~ FOO=1 find -name x",
    # `cd` that does move the shell
    "cd ~ && find . -name x", "cd ~ || true; find . -name x", "cd ~ && ls | head; find . -name x", "true & cd ~; find . -name x",
    "(cd ~ | cat) && cd ~ && find . -name x",
    # a heredoc belongs to its own command, not to every search after it
    "bash -c 'cd ~' ; cat <<EOF\nx\nEOF\nfind ~ -name x",
]
for c in R2_REFUSED:
    check(verdict(bash(c)) == "deny", f"round 2, refused: {c!r}")
for c in ("cat <<EOF\nx\nEOF\nrg foo", "cat <<'EOF' >/dev/null\nx\nEOF\ngrep -r foo", "echo \"x<<y\"; rg foo", "cat <<EOF; rg foo\nx\nEOF",
          "cat <<EOF >out && rg foo\nx\nEOF", "cd repos | cat; find . -name x", "cd repos & find . -name x", "cd repos && ls & find . -name x",
          "echo x | cd repos; rg foo", "env -C ~ find . -name x", "env -C ~/repos find ~ -name x", "echo bash -c 'x'; rg foo"):
    check(verdict(bash(c, cwd=HS)) == "deny", f"round 2, refused with the session in the home: {c!r}")
for c in ("env -C ~ find . -name x", "env -C ~/repos find ~ -name x"):
    check(verdict(bash(c, cwd=HS + "/repos")) == "deny", f"round 2, refused from a project under the home: {c!r}")


# ---- round 3 of the review: a wrapper before a printing command, the options of a wrapper with their values, and the directory of
# `env -C` / `sudo -D` reaching the body of `bash -c` and the next `env -C`. Each case that flips with the session's directory is
# run from both sides (the home and a project): a one-sided test cannot tell a rule from a constant.
R3_PASS = [
    # what a wrapper runs is the printing command, whose `bash -c '…'` arguments are only text
    "command echo bash -c 'find ~ -name x'", "env printf '%s\\n' bash -c 'find ~ -name x'", "sudo -u root echo bash -c 'find ~ -name x'",
    "env -i FOO=1 echo bash -c 'find ~ -name x'", "nice -n 5 echo sh -c 'find ~ -name x'", "timeout 5 echo bash -c 'find ~ -name x'",
    "timeout -k 5 10 printf '%s\\n' bash -c 'find ~ -name x'", "xargs echo bash -c 'find ~ -name x'", "nohup echo eval 'find ~ -name x'",
    "sudo -nu root jlog bash -c 'find ~ -name x'", "env -C /tmp echo bash -c 'find ~ -name x'", "time command echo bash -c 'find ~ -name x'",
    "sudo -p 'pw: ' echo bash -c 'find ~ -name x'", "exec -a x echo bash -c 'find ~ -name x'", "command -p printf '%s' bash -c 'find ~ -name x'",
    # the value of an option is not another option: `sudo -p -D/ …` is the prompt `-D/`, not a change of directory
    "sudo -p -D/ find . -name x", "sudo -p '-D/' find . -name x", "sudo -p-D/ find . -name x", "sudo --prompt=-D/ find . -name x",
    "env -u -C find . -name x", "sudo -u -D/ find . -name x",
    # `env -C` reaches the body of a shell and the next wrapper; a body that stays in /tmp or a project is no walk of the home
    "env -C /tmp bash -c 'find . -name x'", "env -C '/tmp' zsh -c 'rg foo'", "env -C ~/repos bash -c 'find . -name x'",
    "env -C ~ env -C repos bash -c 'find . -name x'", "env -C ~ env -C repos find . -name x", "env -C ~ sh -c 'cd repos && find . -name x'",
    "env -C ~ bash -c 'find ~/repos -name x'", "sudo -D /tmp bash -c 'find . -name x'", "env --chdir=/tmp bash -c 'rg foo'",
    "env -C ~ env -C /tmp find . -name x", "env -C ~ env -C /tmp bash -c 'find . -name x'",
]
for c in R3_PASS:
    check(verdict(bash(c)) == "pass", f"round 3, allowed: {c!r}")
for c in ("env -C /tmp bash -c 'find . -name x'", "env -C /tmp env -C . find . -name x", "env -C /tmp env -C . bash -c 'find . -name x'",
          "env -C ~/repos env -C app find . -name x", "sudo -D /tmp bash -c 'find . -name x'", "env --chdir=/tmp bash -c 'rg foo'",
          "env -C '/tmp' bash -c 'find . -name x'", "env -C \"/tmp\" env -C . find . -name x", "env -C /tmp env -C ~/repos find . -name x",
          "env -C ~/repos bash -c 'find . -name x'", "command echo bash -c 'find ~ -name x'", "env printf '%s' bash -c 'rg foo'"):
    check(verdict(bash(c, cwd=HS)) == "pass", f"round 3, allowed with the session in the home: {c!r}")
R3_REFUSED = [
    # the wrapper's own command is a shell, behind every kind of option and value
    "command bash -c 'find ~ -name x'", "env bash -c 'find ~ -name x'", "sudo -u root bash -c 'find ~ -name x'", "sudo -nu root bash -c 'find ~ -name x'",
    "timeout -k 5 10 bash -c 'find ~ -name x'", "nice -n 5 bash -c 'find ~ -name x'", "env -i FOO=1 bash -c 'find ~ -name x'",
    "xargs -0I{} sh -c 'find ~ -name x'", "time -p sh -c 'find ~ -name x'", "sudo -p 'pw: ' bash -c 'find ~ -name x'", "exec -a x bash -c 'find ~ -name x'",
    "sudo env bash -c 'find ~ -name x'", "env -C /tmp env -C ~ bash -c 'find . -name x'", "sudo -u root -- bash -c 'find ~ -name x'",
    "sudo -p -D/ find ~ -name x", "sudo -nu root find ~ -name x", "env -C /tmp bash -c 'find ~ -name x'", "env -C /tmp bash -c 'cd ~ && find . -name x'",
    # `env -C ~` / `sudo -D ~` reach the body of a shell, and a second `env -C` is read relative to the first
    "env -C ~ bash -c 'find . -name x'", "env -C @H@ zsh -c 'rg foo'", "env -C ~ sh -c 'find . -name x'", "sudo -D ~ bash -c 'find . -name x'",
    "env -C ~ env -C . find . -name x", "env -C ~ env -C . bash -c 'find . -name x'", "env --chdir=$HOME bash -c 'find . -name x'",
    "env -C \"$HOME\" bash -c 'find . -name x'", "env -C /tmp env -C ~ find . -name x", "env -C ~ -i bash -c 'find . -name x'",
]
for c in R3_REFUSED:
    check(verdict(bash(c)) == "deny", f"round 3, refused: {c!r}")
for c in ("env -u -C find . -name x", "env -C /tmp bash -c 'find ~ -name x'", "env -C ~ bash -c 'find . -name x'", "sudo -p -D/ find . -name x",
          "env -C /tmp env -C ~ find . -name x", "env -C ~ env -C . find . -name x"):
    check(verdict(bash(c, cwd=HS)) == "deny", f"round 3, refused with the session in the home: {c!r}")


import resource
import time


def timed(cmd, **extra):
    """(verdict, CPU seconds, wall seconds) of a command. The limits below are on the hook's CPU time (user + system of the
    child): the suite runs several scripts at once, so wall time on a loaded runner measures the load (6-8 s for a 1.6 s check),
    not the hook. A hook that hangs without burning CPU is caught by the wall-clock timeout, which is a hang guard and not a
    speed limit; the hook's own fail-safe timer (8.5 s) is set out of the way, or it would answer "no decision" for a hang
    and the check would read that as a fast pass. Children run one at a time, so the difference of getrusage is this one's."""
    event = json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Bash", "cwd": WS, "tool_input": {"command": cmd}}).encode()
    u0, t0 = resource.getrusage(resource.RUSAGE_CHILDREN), time.time()
    try:
        r = subprocess.run([sys.executable, str(HOOK)], capture_output=True, env=env(AGENT_HUB_HOOK_DEADLINE_S="60", **extra), timeout=30, input=event)
    except subprocess.TimeoutExpired:
        return "broken", float("inf"), time.time() - t0
    u1 = resource.getrusage(resource.RUSAGE_CHILDREN)
    return verdict(r), (u1.ru_utime - u0.ru_utime) + (u1.ru_stime - u0.ru_stime), time.time() - t0


# the reviewer's input: one heredoc opener inside quotes, 50000 blank lines and no terminator took 12 s and more (a regex holds the
# interpreter, so the fail-safe's timer cannot answer for it); the answer now has to cost well under the harness's 10 s of CPU
LATENCY = {
    "50000 blank lines after an opener with no terminator": "printf '%s' '<<EOF\n" + "\n" * 50000 + "END'",
    "50000 blank lines, then the terminator": "cat <<EOF\n" + "\n" * 50000 + "EOF\nrg foo",
    "20000 openers, one per line, no terminator": "cat <<EOF\n" * 20000,
    "10000 distinct delimiters, no terminator": "".join(f"cat <<D{i}\n" for i in range(10000)),
    "10000 heredocs one after another": "cat <<A\nx\nA\n" * 10000 + "find ~ -name x",
    "10000 `bash -c` words after echo": "echo " + "bash -c 'a' " * 10000,
    "10000 `bash -c` words after xargs": "xargs " + "bash -c 'a' " * 10000,
    "a 200 kB line of heredoc openers": "cat " + "<<A " * 50000 + "\nA",
}
for label, cmd in LATENCY.items():
    v, cpu, wall = timed(cmd)
    check(v != "broken" and cpu < 2.0, f"latency ({label}): {cpu:.2f} s of CPU ({wall:.2f} s wall), {v}")
check(timed("printf '%s' '<<EOF\n" + "\n" * 50000 + "END'")[0] == "pass", "latency: the reviewer's input is an ordinary printf, allowed")
check(timed("cat <<A\nx\nA\n" * 10000 + "find ~ -name x")[0] == "deny", "latency: a walk after 10000 heredocs is still refused")

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
# pathological commands: bounded CPU time, no traceback
for label, cmd in (("nested substitutions", "x=$(" * 800 + "find ~" + ")" * 800), ("deep $( chain", "$(a " * 500 + "find ~ -name x" + ")" * 500),
                   ("5000 pipes", "a | " * 5000 + "b"), ("long argument list", "find ~ " + "-name x -o " * 20000),
                   ("many stages", "cd ~; " * 20000 + "ls"), ("many words", "rg foo " + "a " * 100000),
                   ("many quotes", "echo " + "'a' " * 30000 + "; find ~ -name x"), ("deep parentheses", "(" * 3000 + "find ~" + ")" * 3000),
                   ("20000 heredoc openers", "<<EOF " * 20000 + "find ~ -name x"), ("a pile of brackets", "find ~/" + "[" * 50000),
                   ("many globs", "find ~/" + "*/" * 5000 + "x")):
    v, cpu, wall = timed(cmd)
    check(v != "broken" and cpu < 6, f"pathological command ({label}): {cpu:.1f} s of CPU ({wall:.1f} s wall), {v}")

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
