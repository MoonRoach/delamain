#!/bin/bash
# Limit pace (bin/limit_pace.py): the pace model over fixture logs (Codex rollouts, Claude headless logs), the advice in
# launch's engine/model/effort, remaining-room comparisons, practical exhaustion and its --reason
# override, an owner-locked stage, stale data, one journal line per crossing (spawn and watchdog R6), the digest line and
# agent-top. Stand-in CLIs only; no model is called.
. "$(dirname "$0")/lib.sh"
new_home; export HUB_STAGE=stage-a HUB_TAG=hub-test CLAUDE_BIN=$T/fake_claude.py CODEX_BIN=$T/fake_codex.py
export HOME=$AGENT_HUB_HOME/home; mkdir -p "$HOME"
R=$AGENT_HUB_HOME; W=$R/w; mkdir -p $W; printf '# Brief: fixture work\n\nbody\n' > $W/b.md
FX(){ python3 "$T/limit_pace_fixture.py" "$@"; }
dry(){ local r=$1; shift; $B/agent spawn --role $r --cwd $W --brief $W/b.md --dry-run "$@" > $R/$r.out 2>&1; }
wait_dead(){ for i in $(seq 1 60); do $B/agent status $1 | grep -q 'ALIVE' || return 0; sleep 0.25; done; }
J=$R/stage-a/coordinator/work/journal-$(today).md
$B/ask plan --stage stage-a "plan for the tests" > /dev/null

# ---- 1. the pace model and the advice rules, against fixture logs read by the module itself
python3 - "$B" "$T" <<'PY'
import dataclasses, os, subprocess, sys
b, t = sys.argv[1:]
sys.path.insert(0, b)
import limit_pace as lp
import codex_rollouts

cache_file = lp.hc.state_dir() / "agent-top" / "limit-pace.json"

def fx(*args):
    subprocess.run([sys.executable, f"{t}/limit_pace_fixture.py", *args], check=True)

def read(cached=False):
    codex_rollouts.INDEX.checked = None
    return lp.read_all(cache=cache_file if cached else None)

fails = []
def check(cond, name):
    print(("PASS " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)

# no data: unknown, no advice, no refusal
fx("clear")
P = read()
check(P["codex"]["7d"].level == "unknown" and P["claude"]["7d"].level == "unknown", "no samples: both unknown")
a = lp.advise("codex", "gpt-6.1-sol", "high", "stage-a", P)
check(a.lines == [] and a.refuse is None, "unknown data: no advice, no refusal")

# Public advice seam: the matrix is symmetric across engines and independent of task class.
import shlex

def pair(engine, used, other_used, elapsed=40):
    fx("clear")
    fx(engine, str(used), "--elapsed-h", str(elapsed), "--span-h", "0")
    fx(lp.other(engine), str(other_used), "--elapsed-h", str(elapsed), "--span-h", "0")
    return read()

for engine in lp.ENGINES:
    for cls, model in (("mechanical", "luna"), ("bounded", "sol"), ("judgement", "astra")):
        for used, alternate, move, stop in ((4, 75, False, False), (75, 21, False, False),
                                            (85, 21, True, False), (85, 90, False, False),
                                            (90, 85, True, False), (98, 21, True, True),
                                            (98, 97, True, True), (98, 99, False, True),
                                            (99, 98, True, True), (97, 21, True, False),
                                            (80, 21, False, False), (85, 85, False, False)):
            P = pair(engine, used, alternate)
            a = lp.advise(engine, model, "medium", "stage-a", P, task_class=cls)
            text = "\n".join(a.lines)
            label = f"{engine}/{cls} {used}% vs {alternate}%"
            check(any("run this as" in l for l in a.lines) == move, label + ": move only this launch to more room")
            if move:
                check(lp.equivalent(engine, cls) in text, label + ": names equivalent model and effort")
            check(bool(a.refuse) == stop and a.stop == stop, label + ": practical exhaustion only")
            if used > 80 and alternate > 80:
                check("may run out before the reset" in text, label + ": both short, warn and run")
            surfaces = [text, a.refuse or "", lp.summary(engine, P), lp.compact(engine, P),
                        lp.ask_command("stage-a", P[engine]["7d"], None, P[lp.other(engine)]["7d"], cls)]
            check(not any(term in " ".join(surfaces).lower() for term in
                          ("defer", "after the reset", "urgent only", "night queue", "nice-to-have", "sequence:", "work that can wait")),
                  label + ": no scheduling advice on any surface")
            if stop:
                check(lp.advise(engine, model, "medium", "stage-a", P, cls, reason="incident").refuse is None,
                      label + ": --reason passes")
                os.environ["AGENT_HUB_LIMIT_PACE"] = "warn"
                check(lp.advise(engine, model, "medium", "stage-a", P, cls).refuse is None,
                      label + ": warn never refuses")
                del os.environ["AGENT_HUB_LIMIT_PACE"]

# Forecast alone, including the actual 4%-after-one-hour regression, never redirects or refuses.
for elapsed in (1, 5.99, 6, 40):
    P = pair("codex", 4, 21, elapsed)
    a = lp.advise("codex", "gpt-6.1-sol", "medium", "stage-a", P)
    check(a.refuse is None and not any("run this as" in l for l in a.lines), f"{elapsed}h: burn alone cannot move/refuse")
    if elapsed < 6:
        check("low-confidence" in lp.describe(P["codex"]["7d"]), f"{elapsed}h: early forecast labelled")
        early = P["codex"]["7d"]
        check(lp.note_crossing(f"early-{int(elapsed * 100)}", early, write=False) is None,
              f"{elapsed}h: no early dry-run alarm")
        check(lp.note_crossing(f"early-{int(elapsed * 100)}", early) is None and lp.note_crossing("*owner", early, journal=False) is None,
              f"{elapsed}h: no early journal alarm or owner notification crossing")
        check(not (lp.hc.state_dir() / "limit-pace" / "crossings.json").exists(),
              f"{elapsed}h: early observations do not consume crossing state")
    else:
        check("low-confidence" not in lp.describe(P["codex"]["7d"]), f"{elapsed}h: confidence boundary")
        if elapsed == 6:
            check(lp.note_crossing("early-boundary", P["codex"]["7d"]) is not None,
                  "6h: crossing is announced when the confidence boundary is reached")

P = pair("codex", 75, 21)
p = P["codex"]["7d"]
check(p.level == "exhaust" and p.confirmed and p.eta < p.resets_at, "forecast remains visible, separate from launch decision")
a = lp.advise("codex", "gpt-6.1-sol", "high", "stage-a", P)
check(any("routine bounded work runs at medium (asked: high)" in l for l in a.lines), "effort waste advice retained with room")
check(not any("asked: high" in l for l in lp.advise("codex", "sol", "high", "stage-a", P, "judgement").lines),
      "judgement class keeps effort")

# Engine locks offer an owner permission for this launch, defaulting to running on the locked engine.
os.environ["AGENT_HUB_STAGE_ENGINES"] = '{"stage-a": {"engine": "codex", "decision": "Q-T-1"}}'
lock = lp.stage_lock("stage-a")
check(lock == {"engine": "codex", "decision": "Q-T-1"}, "stage lock read")
for used, stop in ((85, False), (98, True)):
    P = pair("codex", used, 21)
    a = lp.advise("codex", "sol", "medium", "stage-a", P, lock=lock)
    text = "\n".join(a.lines)
    check("ask add --stage stage-a" in text and "Q-T-1" in text and "run this as" not in text,
          f"locked {used}%: ask owner, no move")
    cmd = shlex.split(lp.ask_command("stage-a", P["codex"]["7d"], lock, P["claude"]["7d"], "bounded"))
    check(cmd[cmd.index("--default") + 1] == "run this launch on the locked engine Codex", "locked default runs the work")
    check(bool(a.refuse) == stop, "lock does not turn extrapolation into refusal")
del os.environ["AGENT_HUB_STAGE_ENGINES"]

# Unknown/stale observations never establish refusal or a move, including practically exhausted requests.
for alternate in ("unknown", "stale"):
    P = pair("codex", 99, 21)
    P["claude"]["7d"] = dataclasses.replace(P["claude"]["7d"], level=alternate)
    a = lp.advise("codex", "sol", "medium", "stage-a", P)
    check(not a.stop and not a.refuse and not any("run this as" in l for l in a.lines), alternate + ": alternative unverified")
    P["codex"]["7d"] = dataclasses.replace(P["codex"]["7d"], level="stale")
    check(lp.advise("codex", "sol", "medium", "stage-a", P).refuse is None, "stale requested engine never refuses")

# Practical exhaustion with an unverified alternative is an explicit warning, never a quota gate.
for engine in lp.ENGINES:
    for alternate in ("unknown", "stale"):
        P = pair(engine, 99, 21)
        qengine = lp.other(engine)
        P[qengine]["7d"] = dataclasses.replace(P[qengine]["7d"], level=alternate)
        a = lp.advise(engine, "sol", "medium", "stage-a", P)
        for label, text in (("spawn", " ".join(a.lines)), ("summary", lp.summary(engine, P)),
                            ("compact", lp.compact(engine, P))):
            check("practically exhausted" in text and "probe" in text and "--reason" in text,
                  f"{engine}/{alternate}/{label}: probe or explicitly launch despite exhaustion")
            check(not any(term in text for term in ("launch: run on", "this launch: keep", "keep this launch")),
                  f"{engine}/{alternate}/{label}: no unconditional go advice")
        check(not a.stop and not a.refuse, f"{engine}/{alternate}: unknown data still creates no gate")

# Five-hour forecasts report the window, not a schedule for work.
P = pair("codex", 21, 25)
P["codex"]["5h"] = dataclasses.replace(P["codex"]["7d"], window="5h", level="exhaust")
a = lp.advise("codex", "sol", "medium", "stage-a", P)
check(not a.refuse and not any(t in " ".join(a.lines) for t in ("work that can wait", "starts after", "a pause")),
      "5h forecast has no waiting advice")

# parallel Claude logs: the log's mtime is not its event's time, so the points of one instant disagree by a point
for order in ("51,52", "52,51"):
    fx("clear"); fx("claude", order, "--span-h", "0"); fx("codex", "10,12")
    P = read()
    check(P["claude"]["7d"].used == 52, f"two logs of one instant ({order}): the higher utilisation stands")
# right after the weekly reset a long agent's last event still carries the old resetsAt, under the newest mtime
fx("clear"); fx("claude", "60", "--elapsed-h", "170", "--age-m", "1", "--tag", "old")
fx("claude", "3", "--elapsed-h", "0.1", "--age-m", "5", "--tag", "new"); fx("codex", "10,12")
P = read()
c = P["claude"]["7d"]
check(c.level == "ok" and c.used == 3, "an event of the old window under a newer mtime: the new instance stands, not stale")

# a window that restarted in the middle of the week (08.10): rates and the share come from the new instance only
fx("clear"); fx("claude", "20,21")
fx("codex", "90,98", "--span-h", "1", "--elapsed-h", "168", "--age-m", "125", "--tag", "old")
fx("codex", "0,0.5", "--span-h", "1.5", "--elapsed-h", "2", "--age-m", "1", "--tag", "new")
P = read()
p = P["codex"]["7d"]
check(p.used == 0.5 and abs(p.expected - 100 * 2 / 168) < 0.3, "restarted window: used and elapsed share of the new instance")
check(p.burn_recent is not None and abs(p.burn_recent - 0.5 / 1.5) < 0.1, "…burn_recent over the new instance's points only")
check(p.level == "ok", "…a fresh week on pace, not the old instance's 98%")

# crossings: once per stage, engine, window instance and level
fx("clear"); fx("codex", "60,75")
P = read()
p = P["codex"]["7d"]
first = lp.note_crossing("stage-x", p)
check(first is not None and first.startswith("@hub LIMIT"), "first crossing: an @hub LIMIT line")
check("choose engine/model/effort for this launch" in first and "after the reset" not in first,
      "alarm directs per-launch choice, not scheduling")
check(lp.note_crossing("stage-x", p) is None, "…the second time: nothing (no spam)")
check(lp.note_crossing("stage-y", p) is not None, "…another stage is told on its own")
calm = lp.Pace("codex", "7d", level="ahead", used=30, expected=20, resets_at=p.resets_at, seen_at=p.seen_at, age_s=1)
check(lp.note_crossing("stage-z", calm) is not None and lp.note_crossing("stage-z", p) is not None, "ahead, then exhaust: two crossings")
moved = lp.Pace("codex", "7d", level="exhaust", used=75, expected=20, resets_at=p.resets_at + 7 * 86400, seen_at=p.seen_at, age_s=1)
check(lp.note_crossing("stage-x", moved) is not None, "a new window instance is a new crossing")
check(lp.note_crossing("stage-q", lp.Pace("codex", "7d", level="ok", used=1, expected=5, resets_at=p.resets_at)) is None, "on pace: no line")
# the per-file cache: an unchanged log is not read again, a rewritten one is
fx("clear"); fx("codex", "60,75"); fx("claude", "20,21")
read()
check(not (lp.hc.state_dir() / "agent-top").exists(), "without a cache file nothing is written (dry runs stay dry)")
read(cached=True)
check(cache_file.exists(), "agent-top's cached read keeps the samples")
calls = []
orig_c, orig_x = lp._claude_file, lp._codex_file
lp._claude_file = lambda path: calls.append(path) or orig_c(path)
lp._codex_file = lambda path: calls.append(path) or orig_x(path)
P = read(cached=True)
check(calls == [] and P["codex"]["7d"].used == 75, "unchanged logs: served from the cache, same numbers")
fx("codex", "60,80")
P = read(cached=True)
check(len(calls) == 1 and P["codex"]["7d"].used == 80, "a rewritten rollout is read again")
lp._claude_file, lp._codex_file = orig_c, orig_x
print("RESULT", "FAIL" if fails else "PASS")
sys.exit(1 if fails else 0)
PY
check $? 0 "limit pace: model and advice rules"

# ---- 2. agent spawn: printed before the launch, the hard stop, --reason journalled, --dry-run writes nothing
FX clear; FX codex 10,12; FX claude 20,21
dry p1 --engine codex --model gpt-6.1-sol --effort medium; check $? 0 "on pace: spawn goes on"
grep -q 'limit pace' $R/p1.out; check $? 1 "…and prints no advice"
grep -q 'dry run: p1 would start on codex' $R/p1.out; check $? 0 "--dry-run says what it would start"
[ ! -e $R/stage-a/agents/p1 ]; check $? 0 "…and starts nothing"

FX clear; FX codex 75,85; FX claude 20,21
dry p2 --engine codex --model gpt-6.1-sol --effort medium; check $? 0 "Codex over pace, Claude has headroom: no refusal"
grep -q '2. move: .*run this as Claude Sonnet high' $R/p2.out; check $? 0 "…the advice moves the work to the equivalent class"
grep -q 'would journal \[pace\] @hub LIMIT Codex 7d' $R/p2.out; check $? 0 "…a dry run names the crossing line"
[ ! -s $J ] || ! grep -q 'LIMIT' $J; check $? 0 "…and does not write it"

AGENT_HUB_STAGE_ENGINES='{"stage-a": {"engine": "codex", "decision": "Q-T-1"}}' dry p3 --engine codex --model gpt-6.1-sol --effort medium
check $? 0 "owner-locked stage with room: allowed"
grep -q "ask add --stage stage-a" $R/p3.out && grep -q 'Q-T-1' $R/p3.out; check $? 0 "…with the owner question"
grep -q 'run this as' $R/p3.out; check $? 1 "…and no switch"

FX clear; FX codex 97,98; FX claude 98,99
dry p4 --engine codex --model gpt-6.1-sol --effort medium; check $? 1 "both engines run out before the reset: refused"
grep -q 'limit pace: Codex 7d' $R/p4.out && grep -q -- '--reason' $R/p4.out; check $? 0 "…saying why and how to pass"
[ ! -e $R/stage-a/agents/p4 ]; check $? 0 "…nothing was created"
dry p5 --engine codex --model gpt-6-luna --effort low; check $? 1 "practically exhausted mechanical work also needs --reason"
dry p6 --engine codex --model gpt-6.1-sol --effort medium --reason "prod incident fix"; check $? 0 "--reason passes"
$B/agent spawn --role p7 --cwd $W --brief $W/b.md --engine codex --model gpt-6.1-sol --effort medium \
  --reason "prod incident fix" > $R/p7.out 2>&1; check $? 0 "a real launch with --reason"; wait_dead p7
grep -q 'started headless agent p7 .*reason: prod incident fix, over the limit-pace stop (Codex 7d 98% used' $J; check $? 0 "…journalled as over the stop, with the numbers"
check "$(grep -c '\[pace\] @hub LIMIT Codex 7d' $J)" 1 "…one crossing line"
$B/agent spawn --role p8 --cwd $W --brief $W/b.md --engine codex --model gpt-6.1-sol --effort medium \
  --reason "second fix" > $R/p8.out 2>&1; wait_dead p8
check "$(grep -c '\[pace\] @hub LIMIT Codex 7d' $J)" 1 "a second launch: still one crossing line"

FX clear; FX codex 60,75 --age-m 240; FX claude 60,75
dry p9 --engine codex --model gpt-6.1-sol --effort medium; check $? 0 "stale Codex data: not refused"
grep -q 'data stale' $R/p9.out; check $? 0 "…and said to be stale"
AGENT_HUB_LIMIT_PACE=off dry p10 --engine claude --model sonnet; check $? 0 "AGENT_HUB_LIMIT_PACE=off: spawn goes on"
grep -q 'limit pace' $R/p10.out; check $? 1 "…with no advice"

# Early extrapolation and refusal overrides also pass through the actual CLI.
FX clear; FX codex 4 --elapsed-h 1 --span-h 0; FX claude 20,21
dry early --engine codex --model gpt-6.1-sol --effort medium; check $? 0 "early 4%: CLI allows launch"
grep -q 'low-confidence' $R/early.out; check $? 0 "…early forecast is labelled"
grep -q 'run this as' $R/early.out; check $? 1 "…forecast alone never moves launch"
FX clear; FX codex 97,98; FX claude 20,21
dry exhausted --engine codex --model gpt-6.1-sol --effort medium; check $? 1 "exhausted requested engine with alternative: CLI refuses"
AGENT_HUB_LIMIT_PACE=warn dry warn --engine codex --model gpt-6.1-sol --effort medium
check $? 0 "warn allows exhausted CLI launch"

# ---- 3. the digest line, agent-top, watchdog R6
FX clear; FX codex 75,85; FX claude 20,21
python3 - "$B" > $R/digest.out <<'PY'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("hubmod", sys.argv[1] + "/hub")
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("hubmod", loader)); loader.exec_module(m)
print(m.pace_digest("stage-a"))
PY
grep -q '^Codex week 85% used .*this launch.*Claude' $R/digest.out
check $? 0 "digest: Codex line with the action"
grep -q '^Claude week 21% used at 24% elapsed — on pace$' $R/digest.out; check $? 0 "digest: Claude line on pace, no advice"
[ "$(wc -c < $R/digest.out)" -lt 480 ]; check $? 0 "digest: the block fits its budget"
python3 - "$B" > $R/digest-broken.out <<'PY'
import importlib.machinery, importlib.util, sys
sys.path.insert(0, sys.argv[1])
import limit_pace
def boom(*a, **k): raise RuntimeError("fixture")
limit_pace.read_all = boom
loader = importlib.machinery.SourceFileLoader("hubmod", sys.argv[1] + "/hub")
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("hubmod", loader)); loader.exec_module(m)
print(m.pace_digest("stage-a"))
PY
check "$(cat $R/digest-broken.out)" "Limit pace: unavailable (RuntimeError)" "digest: a broken advisor says so, not an empty line"
$B/agent-top --once --width 200 --stage stage-a > $R/top.out 2>&1; check $? 0 "agent-top --once"
grep -q 'Limit pace' $R/top.out && grep -q 'Codex 7d 85% used .* over pace. Advice' $R/top.out; check $? 0 "agent-top --once: an advisor line per engine"
$B/agent-top --json --stage stage-a | python3 -c "import json,sys; d=json.load(sys.stdin)['limit_pace']; assert d['codex']['level']=='exhaust' and d['claude']['level']=='ok', d"
check $? 0 "agent-top --json: limit_pace levels"

export AGENT_HUB_WATCHDOG=on CLAUDE_BIN=$T/fake_claude_wd.py FAKE_WD_ROWS=$R/rows.json FAKE_WD_LOG=$R/claude.log
echo '[]' > $R/rows.json; unset AGENT_HUB_NOTIFY_CMD
FB=$R/fakebin; mkdir -p "$FB"; : > $R/notify.log
for n in osascript notify-send; do printf '#!/bin/sh\necho "local: $*" >> "%s"\n' "$R/notify.log" > "$FB/$n"; chmod +x "$FB/$n"; done
export PATH="$FB:$PATH"
mkdir -p $R/stage-w/coordinator/work
$B/roles set --stage stage-w hub 44444444-4444-4444-8444-444444444444 --kind cli --tag hub-1 > /dev/null
JW=$R/stage-w/coordinator/work/journal-$(today).md
$B/watchdog run --stage stage-w > $R/wd1.out 2>&1; check $? 0 "watchdog tick"
check "$(grep -c '\[pace\] @hub LIMIT Codex 7d' $JW)" 1 "watchdog R6: one @hub LIMIT line in the stage with a hub"
grep -q 'LIMIT Claude' $JW; check $? 1 "…none for the engine on pace"
check "$(grep -c 'Codex plan week projected to run out' $R/notify.log)" 1 "…the owner notified once"
$B/watchdog run --stage stage-w > $R/wd2.out 2>&1
check "$(grep -c '\[pace\] @hub LIMIT Codex 7d' $JW)" 1 "a second tick: no new line"
check "$(grep -c 'Codex plan week projected to run out' $R/notify.log)" 1 "…and no new notification"
# The actual watchdog must neither journal nor notify on the first hour's extrapolation.
FX clear; FX codex 4 --elapsed-h 1 --span-h 0; FX claude 20,21
mkdir -p $R/stage-early/coordinator/work
$B/roles set --stage stage-early hub 55555555-5555-4555-8555-555555555555 --kind cli --tag hub-1 > /dev/null
JE=$R/stage-early/coordinator/work/journal-$(today).md
$B/watchdog run --stage stage-early > $R/wd-early.out 2>&1; check $? 0 "early watchdog tick"
[ ! -f "$JE" ] || ! grep -q '@hub LIMIT' "$JE"; check $? 0 "early watchdog: no journal alarm"
check "$(grep -c 'Codex plan week projected to run out' $R/notify.log)" 1 "early watchdog: no owner notification after positive control"
exit $fail
