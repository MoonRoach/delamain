#!/bin/bash
# Tests for agent-top on fake stages (no real agent, stand or role is touched): states of agents incl. negative controls,
# --once/--json, big-log tail reading, "writes nothing" fingerprint, narrow widths, curses UI in a pty with a stub `agent`.
set -u
. "$(dirname "$0")/isolate.sh"   # no test touches the real HOME, ~/agent-hub or the registry of homes
. "$(dirname "$0")/temp_dirs.sh"
B="$(cd "$(dirname "$0")/../bin" && pwd)"
T="$(cd "$(dirname "$0")" && pwd)"
export PYTHONDONTWRITEBYTECODE=1
export AGENT_HUB_HOME=$(mktemp -d) HUB_STAGE=stage-a
unset HUB_TAG CLAUDE_CODE_SESSION_ID AGENT_BOARD_FILE
fail=0
check(){ if [ "$1" = "$2" ]; then echo "PASS $3"; else echo "FAIL $3 (got $1 want $2)"; fail=1; fi; }
R=$AGENT_HUB_HOME
SID_A=11111111-aaaa-4aaa-8aaa-111111111111; SID_Q=22222222-bbbb-4bbb-8bbb-222222222222
# the sleeper's command line holds both session ids: "pid alive AND session id in its command line" is the liveness rule
python3 -c 'import time; time.sleep(900)' $SID_A $SID_Q &
SLEEPER=$!
trap 'kill $SLEEPER 2>/dev/null; test_cleanup' EXIT
python3 $T/agent_top_fixture.py $R $SLEEPER $SID_A $SID_Q > $R/fixture.out; check $? 0 "fixture built"
python3 $B/ask add --stage stage-a --blocks "test" --default "nothing" --due 2020-01-01T00:00 --by test --source test "Test question?" > $R/ask.out 2>&1
check $? 0 "fixture: overdue question registered"
# agent-top's own read cache (<hub home>/.state/agent-top/, bin/topcache.py) is the one place it writes: left out here,
# its existence checked after the runs
fingerprint(){ python3 - "$R" <<'PY'
import hashlib, os, sys
out = []
cache = os.path.join(sys.argv[1], ".state", "agent-top")
for d, _, files in os.walk(sys.argv[1]):
    if d == cache or d.startswith(cache + os.sep):
        continue
    for f in files:
        p = os.path.join(d, f)
        if f.endswith(".lock") or f in ("fixture.out", "ask.out") or f.startswith(("fp-", "st-", "stub-")):
            continue
        st = os.stat(p)
        out.append(f"{p} {st.st_size} {st.st_mtime_ns} {hashlib.sha1(open(p, 'rb').read()).hexdigest()}")
print("\n".join(sorted(out)))
PY
}
fingerprint > $R/fp-before.txt

# ---- --json: states, fields, negative controls
$B/agent-top --json > $R/st-json.out 2> $R/st-json.err; check $? 0 "--json exit 0"
python3 - $R/st-json.out <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
fails = 0
def chk(name, cond):
    global fails
    print(("PASS " if cond else "FAIL ") + name)
    fails += 0 if cond else 1
A = {(a["stage"], a["dir_name"]): a for a in d["agents"]}
def g(n, stage="stage-a"):
    return A.get((stage, n))
chk("json: alive1 is live", g("alive1")["state"] == "live" and g("alive1")["alive"])
chk("json: quiet1 is live and quiet (log silent 15 min)", g("quiet1")["state"] == "live" and g("quiet1")["quiet"])
chk("json: negative — alive1 is not quiet", not g("alive1")["quiet"])
chk("json: done1 is done, not failed", g("done1")["state"] == "done" and g("done1")["result"]["subtype"] == "success")
chk("json: crash1 (no process, no result) is dead", g("crash1")["state"] == "dead" and not g("crash1")["alive"])
chk("json: err1 (result is_error) is error", g("err1")["state"] == "error" and g("err1")["result"]["is_error"])
chk("json: resumed1 (init after the last result, no process) is dead", g("resumed1")["state"] == "dead")
chk("json: reused pid (alive process, other session id) is NOT live", g("reused")["state"] == "dead")
chk("json: old and archived hidden by default", g("oldie") is None and g("done1.20260114-233047") is None)
chk("json: big1 shown", g("big1") is not None)
a = g("alive1")
chk("json: alive1 action is the pending Bash call", a["action"] and a["action"]["tool"] == "Bash" and a["action"]["text"] == "run the tests"
    and a["action"]["detail"] == "pytest -x tests/" and 20 <= a["action"]["elapsed_s"] <= 60)
chk("json: alive1 last text", a["last_text"] == "Running the tests")
chk("json: alive1 turns 4 own + 1 sub-agent (half-written last line ignored)", a["turns"] == 4 and a["sub_turns"] == 1)
chk("json: alive1 context size", a["ctx_tokens"] == 42003)
chk("json: ctx_window by model id (opus-5 -> 1M; no result yet)", a["ctx_window"] == 1000000)
chk("json: ctx_window reported by the result's modelUsage wins over the table (own model, not the sub-agent's)", g("done1")["ctx_window"] == 777000)
chk("json: negative — a reported window differs from the table's", g("done1")["ctx_window"] != a["ctx_window"])
chk("json: every agent row has a positive ctx_window", all(isinstance(x.get("ctx_window"), int) and x["ctx_window"] > 0 for x in d["agents"]))
chk("json: alive1 unread = only the message no tool call has read", [u["msg"] for u in a["unread"]] == ["new message from the hub"])
chk("json: finished agents have no action and no unread", g("done1")["action"] is None and g("done1")["unread"] == [])
chk("json: done1 cost and last text", g("done1")["cost_usd"] == 1.25 and g("done1")["last_text"] == "finished: task 1")
chk("json: err1 cost", g("err1")["cost_usd"] == 0.5)
chk("json: alive1 in registry, crash1 is not", not a["retired"] and g("crash1")["retired"])
chk("json: model and effort", a["model"] == "claude-opus-5-5" and a["effort"] == "high" and g("b1", "stage-b")["model"] == "claude-sonnet-5-5")
chk("json: counts", d["counts"] == {"live": 2, "done": 3, "error": 1, "dead": 3})
chk("json: order — live first, failed next, done last", [x["group"] for x in d["agents"]] == sorted(x["group"] for x in d["agents"]))
chk("json: stages discovered", d["stages"] == ["empty", "stage-a", "stage-b"])
chk("json: locks — two, one active", len(d["locks"]) == 2 and [l["active"] for l in d["locks"]] == [True, False] and d["locks"][0]["kind"] == "main-merge")
q = d["questions"]["stage-a"]
chk("json: ask summary parsed — 1 open, 1 overdue", q["open"] == 1 and q["overdue"] == 1)
chk("json: hub first in roles", d["roles"]["stage-a"][0]["role"] == "hub" and d["roles"]["stage-a"][0]["kind"] == "desktop")
chk("json: role state joined from the agent", [r["state"] for r in d["roles"]["stage-a"] if r["role"] == "alive1"] == ["live"])
chk("json: role journal age from the journal by tag", [r["journal_age_s"] is not None for r in d["roles"]["stage-a"] if r["role"] == "alive1"] == [True])
chk("json: plan limits from rate_limit_event", d["limits"]["info"]["unifiedWindows"]["five_hour"]["utilization"] == 0.07)
chk("json: journal tail of both stages", any("ran the tests" in j["text"] for j in d["journal_tail"]) and any(j["stage"] == "stage-b" for j in d["journal_tail"]))
sys.exit(fails)
PY
[ $? -eq 0 ] || fail=1

# ---- ctx_window: the model's context window (reported, else by model id, else 200k; never below the context used)
python3 - "$B/agent-top" <<'PY'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("agent_top_bin", sys.argv[1])
spec = importlib.util.spec_from_loader("agent_top_bin", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
fails = 0
def chk(name, cond):
    global fails
    print(("PASS " if cond else "FAIL ") + name)
    fails += 0 if cond else 1
chk("ctx_window: reported wins", m.ctx_window("claude-haiku-4-5", 123456, 1000) == 123456)
chk("ctx_window: table opus-5 / sonnet-5 / fable-5 -> 1M", all(m.ctx_window(x, None, 0) == 1000000 for x in ("claude-opus-5-5", "claude-sonnet-5-5", "claude-fable-5-1")))
chk("ctx_window: table haiku-4 -> 200k", m.ctx_window("claude-haiku-4-5-20251001", None, 0) == 200000)
chk("ctx_window: [1m] suffix -> 1M", m.ctx_window("some-model[1m]", None, 0) == 1000000)
chk("ctx_window: unknown model -> 200k default", m.ctx_window("gpt-6.1-sol", None, 5) == 200000 and m.ctx_window(None, None, None) == 200000)
chk("ctx_window: a context above the guess means a 1M window", m.ctx_window("mystery", None, 300000) == 1000000)
chk("model_usage_window: own model's entry, not the sub-agent's", m.model_usage_window({"claude-haiku-4-5": {"contextWindow": 200000}, "claude-opus-5-5": {"contextWindow": 1000000}}, "claude-opus-5-5") == 1000000)
chk("model_usage_window: [1m] model id matches its base entry", m.model_usage_window({"claude-opus-5-5": {"contextWindow": 1000000}}, "claude-opus-5-5[1m]") == 1000000)
chk("model_usage_window: negative — no entry of the model -> 0", m.model_usage_window({"claude-haiku-4-5": {"contextWindow": 200000}}, "claude-opus-5-5") == 0)
chk("model_usage_window: negative — junk -> 0", m.model_usage_window("x", "m") == 0 and m.model_usage_window({"m": {"contextWindow": "big"}}, "m") == 0)
sys.exit(fails)
PY
[ $? -eq 0 ] || fail=1

# ---- --all, --stage, unknown things
$B/agent-top --json --all > $R/st-all.out; check $? 0 "--json --all exit 0"
python3 - $R/st-all.out <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
A = {(a["stage"], a["dir_name"]): a for a in d["agents"]}
ok = A[("stage-a", "oldie")]["state"] == "done" and A[("stage-a", "done1.20260114-233047")]["archived"] and len(d["agents"]) == 11
print(("PASS" if ok else "FAIL") + " --all: old and archived agents shown (11 agents), archive flagged")
sys.exit(0 if ok else 1)
PY
[ $? -eq 0 ] || fail=1
$B/agent-top --json --stage stage-b > $R/st-stage-b.out; check "$(python3 -c "import json;d=json.load(open('$R/st-stage-b.out'));print(d['stages'],[a['role'] for a in d['agents']])")" "['stage-b'] ['b1']" "--stage stage-b limits the view"
$B/agent-top --once --stage empty --width 80 > $R/st-empty.out; check $? 0 "--stage empty: exit 0"
grep -q 'no agents' $R/st-empty.out; check $? 0 "--stage empty: says there are no agents"
$B/agent-top --json --agent nosuch > /dev/null 2>&1; check $? 1 "negative: unknown --agent -> exit 1"
$B/agent-top --stage 'bad/name' --once > /dev/null 2>&1; check $? 2 "negative: bad stage name -> exit 2"
$B/agent-top --interval 0.1 > /dev/null 2>&1; check $? 2 "negative: --interval 0.1 -> exit 2"
$B/agent-top < /dev/null > $R/st-notty.out 2>&1; check $? 2 "negative: interactive mode without a terminal -> exit 2"
grep -q -- '--once' $R/st-notty.out; check $? 0 "no terminal: the message points to --once/--json"

# no terminal and a flag that asks for a feed (the status skill suggests them): printed once, not an error, and promptly
timeout 60 $B/agent-top --stage stage-a --agent alive1 --feed 4 < /dev/null > $R/st-feed.out 2>&1; check $? 0 "no terminal: --agent --feed acts as --once (exit 0)"
grep -q 'interactive mode needs a terminal' $R/st-feed.out; check $? 1 "no terminal: --agent --feed does not error"
grep -q 'alive1' $R/st-feed.out; check $? 0 "no terminal: --agent --feed prints the agent's card"
timeout 60 $B/agent-top --stage stage-a --feed 4 < /dev/null > $R/st-feed2.out 2>&1; check $? 0 "no terminal: --feed alone acts as --once (exit 0)"
grep -q 'alive1' $R/st-feed2.out; check $? 0 "no terminal: --feed alone prints the picture"
timeout 60 $B/agent-top --stage stage-a --width 100 < /dev/null > $R/st-w.out 2>&1; check $? 2 "negative: --width alone is not a feed flag, bare console still needs a terminal"

# ---- --once picture
$B/agent-top --once --width 120 > $R/st-once-all.out; check $? 0 "--once exit 0 (all stages)"
grep -Eq '^✓ stage-b +b1 ' $R/st-once-all.out; check $? 0 "once: several stages in view -> stage column"
$B/agent-top --once --stage stage-a --width 110 > $R/st-once.out; check $? 0 "--once --stage stage-a exit 0"
head -20 $R/st-once.out
grep -Eq '^● alive1 +Fixture alive1 +live ' $R/st-once.out; check $? 0 "once: live agent shown as live"
grep -Eq '^✗ crash1 +Fixture crash1 +died ' $R/st-once.out; check $? 0 "once: dead agent shown as dead (positive control)"
grep -Eq '^✗ err1 +Fixture err1 +error ' $R/st-once.out; check $? 0 "once: failed run shown as error"
grep -Eq '^✓ done1 +Fixture done1 +done ' $R/st-once.out; check $? 0 "once: finished agent shown as done"
grep -Eq '^✗ reused +Fixture reused +died ' $R/st-once.out; check $? 0 "once: reused pid shown as dead"
grep -Eq '^● quiet1 +Fixture quiet1 +quiet ' $R/st-once.out; check $? 0 "once: silent live agent flagged"
grep -E '^● alive1' $R/st-once.out | grep -q 'alive1-tag)'; check $? 1 "negative: the task column drops the title's (tag) suffix"
$B/agent-top --once --stage stage-a --width 56 > $R/st-once-narrow.out
grep -Eq '^● alive1 +Fixture' $R/st-once-narrow.out; check $? 0 "once: the task column stays at width 56"
$B/agent-top --once --stage stage-a --width 44 > $R/st-once-tiny.out
grep -q 'TASK' $R/st-once-tiny.out; check $? 1 "negative: no task column at width 44"
grep -E '^✓ done1' $R/st-once.out | grep -q '✗'; check $? 1 "negative: a done agent's line has no failure mark"
grep -E '^● alive1' $R/st-once.out | grep -q '✉1'; check $? 0 "once: unread inbox shown"
grep -E '^● alive1' $R/st-once.out | grep -q 'run the tests'; check $? 0 "once: current action shown"
grep -q 'oldie' $R/st-once.out; check $? 1 "negative: old agent hidden without --all"
$B/agent-top --widget --stage stage-a > $R/st-widget.out; check $? 0 "--widget exit 0"
grep -q '/agent-top &lt;role&gt;' $R/st-widget.out; check $? 0 "widget: names the feed command (skill form)"
grep -q 'agent-top --once --agent &lt;role&gt;' $R/st-widget.out; check $? 0 "widget: names the feed command (CLI form)"
grep -q '>Fixture alive1<' $R/st-widget.out; check $? 0 "widget: task shown without the (tag) suffix"
grep -Eq '<script|<button|onclick=|sendPrompt' $R/st-widget.out; check $? 1 "negative: widget has no scripts, buttons or sendPrompt (sendPrompt reaches nothing in the Code tab)"
grep -c 'var(--text-danger)">died<' $R/st-widget.out | grep -qx 3; check $? 0 "widget: the three dead agents shown as dead"
grep -q 'overdue 1' $R/st-once.out; check $? 0 "once: overdue owner question shown"
grep -q 'main-merge demo-repo\|main-merge.*merging main' $R/st-once.out; check $? 0 "once: lock shown"
grep -q 'ran the tests, all green' $R/st-once.out; check $? 0 "once: journal tail shown"
$B/agent-top --once --agent alive1 --width 100 --lines 30 > $R/st-agent.out; check $? 0 "--once --agent exit 0"
grep -q '▸ Bash: run the tests' $R/st-agent.out && grep -q '✎ Running the tests' $R/st-agent.out; check $? 0 "once --agent: feed has command and thought"
grep -qF 'Half-written thought' $R/st-agent.out; check $? 1 "negative: half-written last line is not in the feed"
# control: the same line, once complete, is in the feed (the bare id "mZ" also matched random temp paths in the output)
HW=$(mktemp -d); cp -R $R/. $HW/
python3 - $HW/stage-a/agents/alive1/log.jsonl <<'PY'
import json, sys
p = sys.argv[1]; body, half = open(p, encoding="utf-8").read().rsplit("\n", 1)
prev = json.loads(body.rsplit("\n", 1)[-1] if "\n" in body else body)
done = json.loads(half + '}]},"session_id":"%s"}' % prev.get("session_id", ""))
done["timestamp"] = next(json.loads(l)["timestamp"] for l in reversed(body.split("\n")) if '"timestamp"' in l)
open(p, "w", encoding="utf-8").write(body + "\n" + json.dumps(done) + "\n")
PY
AGENT_HUB_HOME=$HW $B/agent-top --once --agent alive1 --width 100 --lines 30 > $R/st-agent-complete.out
grep -qF 'Half-written thought' $R/st-agent-complete.out; check $? 0 "control: the same line completed is in the feed"
python3 - $B/agent-top $R <<'PY'
import subprocess, sys, unicodedata
def w(s):
    return sum(0 if unicodedata.category(c) in ("Mn", "Me", "Cf") else 2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)
bad = []
for width in (40, 60, 80, 120):
    for extra in ([], ["--agent", "alive1"], ["--all"]):
        out = subprocess.run([sys.argv[1], "--once", "--width", str(width)] + extra, capture_output=True, text=True).stdout
        bad += [(width, extra, w(l)) for l in out.splitlines() if w(l) > width]
print(("PASS" if not bad else "FAIL") + f" once: no line wider than --width (40/60/80/120, plain, --agent, --all){'' if not bad else ' ' + str(bad[:3])}")
sys.exit(1 if bad else 0)
PY
[ $? -eq 0 ] || fail=1

# ---- big log: tail reading
python3 - $B/agent-top <<'PY'
import json, os, subprocess, sys, time
top = sys.argv[1]
size = os.path.getsize(os.path.join(os.environ["AGENT_HUB_HOME"], "stage-a/agents/big1/log.jsonl"))
def run(env):
    t = time.time()
    out = subprocess.run([top, "--json"], capture_output=True, text=True, env=dict(os.environ, **env)).stdout
    return json.loads(out), time.time() - t
d, secs = run({})
b = [a for a in d["agents"] if a["role"] == "big1"][0]
fails = 0
def chk(name, cond):
    global fails
    print(("PASS " if cond else "FAIL ") + name)
    fails += 0 if cond else 1
chk(f"big log ({size // 1000} KB): all 5000 turns counted, state done, cost", b["turns"] == 5000 and not b["turns_approx"] and b["state"] == "done" and b["cost_usd"] == 2.0)
chk(f"big log: whole snapshot in {secs:.2f} s (< 4 s)", secs < 4)
d, secs = run({"AGENT_TOP_SCAN_MAX": "1000000"})   # another cap is another cache generation: not resumed from the full read above
b = [a for a in d["agents"] if a["role"] == "big1"][0]
chk("big log with a 1 MB scan cap: scanned from the tail, marked approximate, result still found", b["turns_approx"] and 0 < b["turns"] < 5000 and b["state"] == "done" and b["cost_usd"] == 2.0)
sys.exit(fails)
PY
[ $? -eq 0 ] || fail=1

# ---- owner questions in --json: full id list beyond the 12 display lines, questions_ok, unknown on a failed ask
QH=$(mktemp -d)
for i in 1 2 3 4 5; do
  AGENT_HUB_HOME=$QH python3 $B/ask add --stage stage-q --blocks "test" --default "nothing" --due 2030-01-01T00:00 --by test --source test "Question $i?" > /dev/null 2>&1 || fail=1
done
AGENT_HUB_HOME=$QH $B/agent-top --json --stage stage-q > $R/st-q.out 2> $R/st-q.err; check $? 0 "questions: --json exit 0 (5 open questions in a fresh home)"
python3 - $R/st-q.out <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
q = d["questions"]["stage-q"]
ok = (q["open"] == 5 and len(q["items"]) == 12 and q["ids"] == [f"Q-Q-00{i}" for i in range(1, 6)] and d["questions_ok"] is True)
print(("PASS" if ok else "FAIL") + " questions: ids carry all 5 open questions while items are cut to 12 lines; questions_ok true")
sys.exit(0 if ok else 1)
PY
[ $? -eq 0 ] || fail=1
if [ "$(id -u)" != 0 ]; then
  chmod 000 $QH/stage-q/questions.md
  AGENT_HUB_HOME=$QH $B/agent-top --json --stage stage-q > $R/st-q-bad.out 2> /dev/null; check $? 0 "questions: --json still exits 0 when the register cannot be read"
  chmod 600 $QH/stage-q/questions.md
  python3 - $R/st-q-bad.out <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
ok = d["questions_ok"] is False and d["questions"] == {}
print(("PASS" if ok else "FAIL") + " questions: a failed ask summary gives questions_ok false (negative control: not 'no registers')")
sys.exit(0 if ok else 1)
PY
  [ $? -eq 0 ] || fail=1
fi

# ---- nothing written by the non-interactive runs
fingerprint > $R/fp-after.txt
diff -q $R/fp-before.txt $R/fp-after.txt > /dev/null; check $? 0 "agent-top --once/--json wrote nothing but its cache (sha1+mtime of every other file under the hub home)"
[ -s $R/.state/agent-top/cache.sqlite ]; check $? 0 "positive control: the cache left out of that check is there (.state/agent-top/cache.sqlite)"

# ---- rendering portability: exercise capabilities, not fixed palette literals
python3 - "$B/agent-top" "$R/st-json.out" <<'PYTEST'
import copy, curses, json, os, runpy, sys, time
from unittest.mock import patch
m = runpy.run_path(sys.argv[1])
styles = m["make_styles"]
fails = 0
def chk(name, ok):
    global fails
    print(("PASS " if ok else "FAIL ") + name)
    fails += not ok

class Terminal:
    error = curses.error
    def __init__(self, colors=256, pairs=64, defaults=True, reject=False):
        for name in dir(curses):
            if name.startswith(("A_", "COLOR_")):
                setattr(self, name, getattr(curses, name))
        self.COLORS, self.COLOR_PAIRS = colors, pairs
        self.defaults, self.reject, self.pairs, self.started = defaults, reject, {}, False
    def has_colors(self): return self.COLORS > 0
    def start_color(self): self.started = True
    def use_default_colors(self):
        if not self.defaults: raise self.error("no default colors")
    def init_pair(self, i, fg, bg):
        assert 0 < i < self.COLOR_PAIRS and -1 <= fg < self.COLORS and -1 <= bg < self.COLORS
        if self.reject: raise self.error("pair rejected")
        self.pairs[i] = (fg, bg)
    def color_pair(self, i): return i << 8
    def pair(self, attrs): return self.pairs[(attrs >> 8) & 255]

def render(term, no_color=None):
    env = dict(os.environ)
    env.pop("NO_COLOR", None)
    if no_color is not None: env["NO_COLOR"] = no_color
    with patch.dict(styles.__globals__, curses=term), patch.dict(os.environ, env, clear=True):
        return styles()

for value in ("", "1"):
    term = Terminal()
    st = render(term, value)
    chk("NO_COLOR=%r never starts color; focus and errors remain marked" % value,
        not term.started and not term.pairs and bool(st["sel"] & curses.A_REVERSE) and bool(st["err"] & curses.A_BOLD))
term = Terminal(colors=0)
render(term)
chk("colorless terminal never starts colors", not term.started)
for colors, pairs, defaults in ((256, 64, True), (8, 64, True), (8, 64, False), (2, 3, True)):
    term = Terminal(colors, pairs, defaults)
    st = render(term)
    chk("%s colors/%s pairs: only available indices used or monochrome focus retained" % (colors, pairs),
        bool(term.pairs) if colors >= 8 else not term.pairs and bool(st["sel"] & curses.A_REVERSE))
    if colors >= 8:
        chk("%s colors: red errors differ from warnings and success" % colors,
            term.pair(st["err"])[0] == curses.COLOR_RED and
            len({term.pair(st[n])[0] for n in ("err", "warn", "live")}) == 3)
        chk("%s colors: navigation differs from warning; selection is bold" % colors,
            term.pair(st["tool"])[0] != term.pair(st["warn"])[0] and bool(st["sel"] & curses.A_BOLD))
        chk("%s colors: body uses terminal defaults or safe black" % colors,
            term.pair(st["live"])[1] == (-1 if defaults else curses.COLOR_BLACK))
        chk("%s colors: panels use extended colors only when supported" % colors,
            (term.pair(st["head"])[1] >= 16) == (colors >= 256))
term = Terminal(reject=True)
st = render(term)
chk("rejected pairs keep a readable monochrome focus", not term.pairs and bool(st["sel"] & curses.A_REVERSE))

snap = json.load(open(sys.argv[2]))
snap["now"] = time.time()
snap["agents"][0]["role"] = '<script>alert("role")</script>'
snap["agents"][0]["title"] = '<b>hostile & task</b>'
widget = m["render_widget"](snap)
chk("widget escapes untrusted role and task markup", '<script>' not in widget and '&lt;script&gt;' in widget and '&lt;b&gt;hostile &amp; task&lt;/b&gt;' in widget)
chk("widget is a fragment with a visible identity and host surfaces", '<html' not in widget and 'at-title">agent-top</h3>' in widget and 'DELAMAIN</span>' in widget and 'var(--surface-1' in widget)
# A known injected tag is the negative control for the escaping check.
chk("negative control: the unsafe role would be caught", '<script>' in snap["agents"][0]["role"])
sys.exit(1 if fails else 0)
PYTEST
check $? 0 "renderer portability and escaping controls"

# ---- curses UI in a pty with a stub `agent` (no real send/stop)
cat > $R/stub-agent.sh <<'SH'
#!/bin/sh
echo "HUB_TAG=$HUB_TAG $*" >> "$STUB_LOG"
echo "ok: $1 $2"
SH
chmod +x $R/stub-agent.sh
python3 $T/agent_top_pty.py ui $R $R/stub-agent.sh $R/stub-calls.log > $R/st-ui.out 2>&1; uirc=$?
cat $R/st-ui.out
check $uirc 0 "curses UI scenarios (pty, 100x30 and 50x12)"
fingerprint > $R/fp-after-ui.txt
diff -q $R/fp-before.txt $R/fp-after-ui.txt > /dev/null; check $? 0 "the UI session wrote nothing to the agents' files either"
echo "root=$R"; exit $fail
