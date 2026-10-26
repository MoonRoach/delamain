#!/bin/bash
# Packaging controls of the agent-top mod (hooks/agent-top.tsx): hooks/hooks.json still parses, keeps every settings hook
# the plugin had before the mod, and names the module; the module's files exist; the Codex hooks file is untouched in kind.
# Where a Claude Code with mods is installed (MOD_CLAUDE, else `claude` on PATH) it also runs `plugin validate --strict`
# (the calls the mod makes are the ones meant: no file writes, network, prompts or model calls) and `plugin test`.
# Without one (CI) that part prints SKIP. Every check has a negative control: the same checker fails on a broken copy.
. "$(dirname "$0")/lib.sh"
ROOT="$(cd "$T/.." && pwd)"
export PYTHONDONTWRITEBYTECODE=1

# ---- the hooks file: parses, keeps every previous settings hook (event, matcher, command, timeout, in order), names the module
CHECK=$(mktemp)
cat > "$CHECK" <<'PY'
import json, sys

# The settings hooks of 0.7.1 / main 027c95a, before the mod: all must stay, in this order (timeouts of board_locks and
# polling_guard raised 5 -> 10 with the hook fail-safe: its deadline is 1.5 s under the timeout, see hooks/failsafe.py).
BEFORE = [
    ("SessionStart", None, 'python3 "${CLAUDE_PLUGIN_ROOT}/hooks/questions.py"', 10),
    ("SessionStart", None, 'python3 "${CLAUDE_PLUGIN_ROOT}/hooks/delegation.py" session-start', 10),
    ("SessionStart", None, 'python3 "${CLAUDE_PLUGIN_ROOT}/hooks/path_shadow.py"', 10),
    ("PreToolUse", "Bash", 'python3 "${CLAUDE_PLUGIN_ROOT}/hooks/board_locks.py"', 10),
    ("PreToolUse", "Bash", 'python3 "${CLAUDE_PLUGIN_ROOT}/hooks/polling_guard.py"', 10),
    ("PreToolUse", "Write|Edit", 'python3 "${CLAUDE_PLUGIN_ROOT}/hooks/handoff_size.py"', 10),
    ("PreToolUse", "Agent|Task|Workflow", 'python3 "${CLAUDE_PLUGIN_ROOT}/hooks/delegation.py" pre-tool', 10),
    ("PreToolUse", "*", 'python3 "${CLAUDE_PLUGIN_ROOT}/hooks/context_budget.py"', 10),
    ("UserPromptSubmit", None, 'python3 "${CLAUDE_PLUGIN_ROOT}/hooks/delegation.py" prompt', 10),
    ("UserPromptSubmit", None, 'python3 "${CLAUDE_PLUGIN_ROOT}/hooks/context_budget.py"', 10),
    ("PostToolUse", "*", 'python3 "${CLAUDE_PLUGIN_ROOT}/hooks/context_budget.py"', 10),
]
MODULE = "./agent-top.tsx"


def flat(doc):
    out = []
    for event, groups in doc["hooks"].items():
        for g in groups:
            for h in g["hooks"]:
                out.append((event, g.get("matcher"), h["command"], h.get("timeout")))
    return out


def problems(doc):
    p = []
    have = flat(doc)
    # BEFORE must be a subsequence of the file's hooks (per event the order is the file's order)
    it = iter(have)
    for want in BEFORE:
        if not any(h == want for h in it):
            p.append("settings hook lost or reordered: %r" % (want,))
    if doc.get("modules") != [MODULE]:
        p.append('"modules" is %r, want [%r]' % (doc.get("modules"), MODULE))
    return p


doc = json.load(open(sys.argv[1]))
fails = 0


def chk(name, ok):
    global fails
    print(("PASS " if ok else "FAIL ") + name)
    fails += 0 if ok else 1


chk("hooks.json parses and the checker finds nothing wrong", problems(doc) == [])
# negative controls: the same checker must flag a lost hook, a changed timeout, a reordered pair and a missing module
lost = json.loads(json.dumps(doc)); del lost["hooks"]["PostToolUse"]
chk("negative control: a dropped settings hook is flagged", problems(lost) != [])
slow = json.loads(json.dumps(doc)); slow["hooks"]["SessionStart"][0]["hooks"][0]["timeout"] = 99
chk("negative control: a changed timeout is flagged", problems(slow) != [])
swap = json.loads(json.dumps(doc)); h = swap["hooks"]["SessionStart"][0]["hooks"]; h[0], h[1] = h[1], h[0]
chk("negative control: a reordered pair is flagged", problems(swap) != [])
nomod = json.loads(json.dumps(doc)); del nomod["modules"]
chk("negative control: a missing module is flagged", problems(nomod) != [])
chk("modules is exactly the one module", doc.get("modules") == [MODULE])
chk("modules sits beside hooks (same object, settings hooks not nested under it)", "hooks" in doc and "modules" in doc)
sys.exit(1 if fails else 0)
PY
python3 "$CHECK" "$ROOT/hooks/hooks.json"; [ $? = 0 ] || fail=1
rm -f "$CHECK"

# ---- the module's files
check "$([ -f "$ROOT/hooks/agent-top.tsx" ] && echo yes || echo no)" yes "module file hooks/agent-top.tsx exists"
check "$([ -f "$ROOT/hooks/agent-top-model.ts" ] && echo yes || echo no)" yes "helper hooks/agent-top-model.ts exists"
check "$(grep -c "from './agent-top-model'" "$ROOT/hooks/agent-top.tsx" | tr -d ' ')" 2 "the module imports its helper (values and types)"
check "$([ -f "$ROOT/hooks/broadcast.tsx" ] && grep -q "from './broadcast'" "$ROOT/hooks/agent-top.tsx" && echo yes || echo no)" yes "the module imports /broadcast from hooks/broadcast.tsx"
check "$([ -x "$ROOT/bin/broadcast" ] && echo yes || echo no)" yes "bin/broadcast is executable (the mod runs it by path)"
check "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("no" if "modules" in d else "ok")' "$ROOT/hooks/codex-hooks.json")" ok "codex-hooks.json parses and has no modules key"
check "$([ -x "$ROOT/bin/agent-top" ] && echo yes || echo no)" yes "bin/agent-top is executable (the mod runs it by path)"
# read-only by construction: the module names no write, network, prompt or model call
check "$(grep -cE '\$\.(fs\.write|http\.|prompt\.|model\.|store\.set|state\.set|process\.spawn)' "$ROOT/hooks/agent-top.tsx" | tr -d ' ')" 0 "module source: no fs.write/http/prompt/model/store/state/spawn call"
check "$(printf '%s\n' 'await $.fs.write(p, x)' | grep -cE '\$\.(fs\.write|http\.|prompt\.|model\.|store\.set|state\.set|process\.spawn)' | tr -d ' ')" 1 "negative control: the same grep flags an fs.write"

# ---- with a Claude Code that has mods: validate --strict and plugin test
MC="${MOD_CLAUDE:-$(command -v claude 2>/dev/null || true)}"
capable=no
if [ -n "$MC" ] && command -v "$MC" > /dev/null 2>&1; then
  "$MC" plugin test --help > /dev/null 2>&1 && capable=yes
fi
if [ "$capable" = yes ]; then
  OUT=$(mktemp -d)
  ( cd "$ROOT" && "$MC" plugin validate .claude-plugin/plugin.json --strict > "$OUT/validate.txt" 2>&1 ); rc=$?
  check "$rc" 0 "plugin validate --strict passes ($("$MC" --version 2>/dev/null | head -1))"
  check "$(grep -c 'agent-top.tsx hooks: .*session.start' "$OUT/validate.txt" | tr -d ' ')" 1 "validate lists the module's hooks"
  CALLS=$(grep 'agent-top.tsx calls:' "$OUT/validate.txt" || true)
  check "$(printf '%s' "$CALLS" | grep -cE 'process\.run' | tr -d ' ')" 1 "validate: the mod runs its CLI with process.run"
  check "$(printf '%s' "$CALLS" | grep -cE 'fs\.write|http\.|prompt\.submit|model\.|process\.spawn|store\.set' | tr -d ' ')" 0 "validate: no write, network, prompt or model call"
  check "$(printf '%s' '$.fs.write (via x), $.process.run' | grep -cE 'fs\.write|http\.|prompt\.submit|model\.|process\.spawn|store\.set' | tr -d ' ')" 1 "negative control: the same pattern flags an fs.write in a calls line"
  ( cd "$ROOT" && "$MC" plugin test . > "$OUT/test.txt" 2>&1 ); rc=$?
  if [ $rc != 0 ] && grep -q "hooks modules are turned off" "$OUT/test.txt"; then
    echo "SKIP plugin test: $(grep -m1 'hooks modules are turned off' "$OUT/test.txt")"
  else
    check "$rc" 0 "plugin test passes"
    check "$(grep -c '^(fail)' "$OUT/test.txt" | tr -d ' ')" 0 "plugin test: no failing test"
    check "$([ "$(grep -c '^(pass)' "$OUT/test.txt")" -ge 10 ] && echo yes || echo no)" yes "plugin test: at least 10 tests ran"
  fi
  rm -rf "$OUT"
else
  echo "SKIP validate and plugin test: no Claude Code with mods (MOD_CLAUDE or claude on PATH) here"
fi
exit $fail
