#!/bin/bash
# Claude Code 2.1.299 blocks the action when a plugin hook cannot hand back its answer (it crashes, times out, prints
# half a document). hooks/failsafe.py makes every hook of the plugin answer "no decision" instead. Controls:
#   positive - malformed input to every hook: exit 0 and empty or complete JSON, never a traceback status;
#              a deliberate deny survives a crash after it; the deadlines sit below the configured timeouts
#   negative - the same hooks WITHOUT the fail-safe (a copy of the plugin with the install call removed) do crash, so
#              the controls can fail
. "$(dirname "$0")/lib.sh"
new_home; R=$AGENT_HUB_HOME; mkdir -p "$R"
python3 - "$T/.." "$R" <<'PY'
import json, os, shutil, subprocess, sys, time
from pathlib import Path

ROOT, WORK = Path(sys.argv[1]).resolve(), Path(sys.argv[2])
fail = 0


def check(ok, what):
    global fail
    print(("PASS " if ok else "FAIL ") + what)
    fail |= 0 if ok else 1


HOOKS = [("questions.py", []), ("delegation.py", ["session-start"]), ("delegation.py", ["prompt"]),
         ("delegation.py", ["pre-tool"]), ("path_shadow.py", []), ("board_locks.py", []), ("polling_guard.py", []),
         ("handoff_size.py", []), ("context_budget.py", [])]
deep = b"[" * 60000 + b"]" * 60000
INPUTS = {
    "empty": b"", "garbage": b"not json", "list": b"[]", "null": b"null", "string": b'"x"',
    "tool_input is a string": b'{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":"x"}',
    "command is a number": b'{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":123},"cwd":"/"}',
    "nested 60000 deep": deep,
    "tool_input nested 60000 deep": b'{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls","x":' + deep + b"}}",
    "invalid UTF-8": b'\xff\xfe{"a":1}',
    "lone surrogate in the command": b'{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo \\ud800 gh pr merge 1"},"cwd":"/"}',
    "fields of the wrong type": b'{"hook_event_name":"PreToolUse","cwd":5,"session_id":7,"tool_name":"Write","tool_input":{"file_path":7,"content":9}}',
    "edit of a missing handoff": b'{"hook_event_name":"PreToolUse","cwd":"/nonexistent/x","tool_name":"Edit","tool_input":{"file_path":"/nonexistent/HANDOFF-x.md","old_string":"a","new_string":"b"}}',
    "3 MB input": b'{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"/tmp/x","content":"' + b"a" * 3_000_000 + b'"}}',
    "prompt is an object": b'{"hook_event_name":"UserPromptSubmit","session_id":"s","cwd":"/","prompt":{"a":[1]}}',
}


def env_for(plugin_root):
    env = {k: v for k, v in os.environ.items() if not k.startswith(("HUB_", "CLAUDE_", "CODEX_", "PLUGIN_ROOT", "AGENT_HUB_HOOK"))}
    env.update(AGENT_HUB_HOME=str(WORK / "hub"), AGENT_HUB_TZ="UTC")
    return env


def run(plugin_root, hook, args, data, env=None, timeout=30):
    return subprocess.run([sys.executable, str(plugin_root / "hooks" / hook), *args], input=data, capture_output=True,
                          env=env or env_for(plugin_root), timeout=timeout)


def answered(r):
    """Exit 0 and either nothing or one complete JSON object."""
    if r.returncode != 0:
        return False
    if not r.stdout.strip():
        return True
    try:
        return isinstance(json.loads(r.stdout), dict)
    except ValueError:
        return False


# -- positive: malformed input never costs the user a tool call
bad = [f"{h} {' '.join(a)} / {name}: exit {r.returncode}, {r.stdout[:60]!r}"
       for h, a in HOOKS for name, data in INPUTS.items() for r in [run(ROOT, h, a, data)] if not answered(r)]
check(not bad, f"every hook answers every malformed input with exit 0 and no output or one JSON object ({len(HOOKS) * len(INPUTS)} runs)" + (f": {bad[:3]}" if bad else ""))
bad = [f"{h} {' '.join(a)}" for h, a in HOOKS
       if not answered(subprocess.run([sys.executable, str(ROOT / "hooks" / h), *a], stdin=subprocess.DEVNULL, capture_output=True, env=env_for(ROOT), timeout=30))]
check(not bad, "every hook copes with a stdin that is /dev/null" + (f": {bad}" if bad else ""))


# -- a copy of the plugin to break: bin/ is shared, hooks/ is copied
def plugin_copy(name, install=True):
    root = WORK / name
    (root / "hooks").mkdir(parents=True)
    for f in (ROOT / "hooks").glob("*.py"):
        text = f.read_text()
        if not install:
            text = text.replace("failsafe.install()", "pass")
        (root / "hooks" / f.name).write_text(text)
    (root / "bin").symlink_to(ROOT / "bin")
    (root / ".claude-plugin").symlink_to(ROOT / ".claude-plugin")
    (root / "skills").symlink_to(ROOT / "skills")
    return root


# a sibling module that cannot be imported: the module-level import of the hook fails before main() runs
for install, label in ((False, "negative control, no fail-safe"), (True, "with the fail-safe")):
    root = plugin_copy("broken-" + label.split(",")[0].replace(" ", "-"), install)
    (root / "hooks" / "codex_compat.py").write_text("raise ImportError('sibling module is broken')\n")
    ev = json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Write", "tool_input": {"file_path": "x", "content": "y"}, "session_id": "s", "cwd": "/"}).encode()
    codes = {h: run(root, h, a, ev).returncode for h, a in (("context_budget.py", []), ("handoff_size.py", []), ("delegation.py", ["pre-tool"]))}
    if install:
        check(all(c == 0 for c in codes.values()), f"{label}: a sibling module that fails to import still gives exit 0 {codes}")
    else:
        check(all(c != 0 for c in codes.values()), f"{label}: the same break is a crash (so the control can fail) {codes}")

# a decision survives what comes after it; a half-written answer does not
PROBES = (
    ("a deny printed before a crash is delivered", 'print(json.dumps({"hookSpecificOutput": {"permissionDecision": "deny"}}))\nraise RuntimeError("late")', "deny"),
    ("a half-written document before a crash is dropped", 'print(\'{"hookSpecificOutput": {"permissionDec\')\nraise RuntimeError("late")', ""),
    ("sys.exit(3) becomes exit 0", "sys.exit(3)", ""),
)
for install in (True, False):
    root = plugin_copy("probe-" + str(install), install)
    for what, body, want in PROBES:
        arm = "failsafe.install()" if install else "pass"
        (root / "hooks" / "probe.py").write_text("import json, sys\nif __name__ == '__main__':\n    import failsafe\n    " + arm + "\n"
                                                 + "\n".join("    " + l for l in body.split("\n")) + "\n")
        r = run(root, "probe.py", [], b"{}")
        if install:
            check(r.returncode == 0 and (want in r.stdout.decode()) and (bool(want) == bool(r.stdout.strip())), f"fail-safe: {what}")
        else:
            check(r.returncode != 0, f"negative control, no fail-safe: the same probe ends with exit {r.returncode} ({what})")

# -- a hook that never gets its input or stalls is cut at its deadline, not at the harness's timeout
for install in (True, False):
    root = plugin_copy("stall-" + str(install), install)
    env = env_for(root)
    env["AGENT_HUB_HOOK_DEADLINE_S"] = "1"
    t0 = time.time()
    p = subprocess.Popen([sys.executable, str(root / "hooks" / "board_locks.py")], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, env=env)  # stdin stays open (communicate() would close it): json.load waits
    try:
        p.wait(timeout=6 if install else 3)
        took = time.time() - t0
        check(install and p.returncode == 0 and not p.stdout.read().strip() and took < 5,
              f"deadline: a hook stuck reading stdin answers exit 0, no output, at the deadline ({took:.1f} s)" if install
              else f"negative control: without the fail-safe the stalled hook should still be waiting ({took:.1f} s)")
    except subprocess.TimeoutExpired:
        p.kill(); p.wait()
        check(not install, "negative control, no fail-safe: the stalled hook runs until the harness kills it" if not install
              else "deadline: the stalled hook was not cut at its deadline")
    for f in (p.stdin, p.stdout, p.stderr):
        f.close()

# the deadlines stay below the timeouts the configs give the same hooks
import re
sys.path.insert(0, str(ROOT / "hooks"))
import failsafe
bad = []
seen = set()
for cfg in ("hooks.json", "codex-hooks.json"):
    for groups in json.loads((ROOT / "hooks" / cfg).read_text())["hooks"].values():
        for g in groups:
            for h in g["hooks"]:
                m = re.search(r"hooks/([\w-]+\.py)", h["command"])
                if not m:
                    continue
                seen.add(m.group(1))
                d = failsafe.DEADLINES.get(m.group(1), failsafe.DEFAULT_DEADLINE_S)
                if not d <= h["timeout"] - 1:
                    bad.append(f"{cfg}: {m.group(1)} deadline {d} vs timeout {h['timeout']}")
check(not bad and seen == set(failsafe.DEADLINES), f"every hook script has a deadline at least 1 s under its configured timeout ({sorted(seen)}) {bad}")
sys.exit(fail)
PY
fail=$?
exit $fail
