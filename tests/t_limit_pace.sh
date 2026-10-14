#!/bin/bash
# Limit pace (bin/limit_pace.py): the pace model over fixture logs (Codex rollouts, Claude headless logs), the advice in
# the owner's order (waste, move at an equivalent class, sequence, tell the owner), the one hard stop and its --reason
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

def fx(*args):
    subprocess.run([sys.executable, f"{t}/limit_pace_fixture.py", *args], check=True)

def read():
    codex_rollouts.INDEX.checked = None
    return lp.read_all()

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

# on pace: no advice at all
fx("codex", "10,12"); fx("claude", "20,21")
P = read()
check(P["codex"]["7d"].level == "ok" and P["claude"]["7d"].level == "ok", "on pace: both ok")
check(abs(P["codex"]["7d"].expected - 100 * 40 / 168) < 0.5, "elapsed share from resets_at and the window length")
check(P["claude"]["7d"].burn_recent is not None, "Claude burn rate from several logs' mtimes")
a = lp.advise("codex", "gpt-6.1-sol", "high", "stage-a", P)
check(a.lines == [] and a.refuse is None, "on pace: no advice even for Sol high")

# over pace on Codex, Claude on pace: move at the equivalent class, no refusal, no weaker model
fx("clear"); fx("codex", "60,75"); fx("claude", "20,21")
P = read()
p = P["codex"]["7d"]
check(p.level == "exhaust" and p.confirmed, "Codex 60→75% in 6 h at 24% of the week: exhaustion confirmed")
check(p.eta is not None and p.eta < p.resets_at, "…projected before the reset")
a = lp.advise("codex", "gpt-6.1-sol", "medium", "stage-a", P)
move = [l for l in a.lines if l.startswith("2. move")]
check(a.refuse is None, "over pace with headroom elsewhere: no refusal")
check(len(move) == 1 and "Claude Sonnet high" in move[0], "bounded Sol → Claude Sonnet high")
a = lp.advise("codex", "gpt-6-astra", "high", "stage-a", P)
move = [l for l in a.lines if l.startswith("2. move")][0]
check("Claude Opus high" in move and "Sonnet" not in move and "Haiku" not in move, "judgement Astra → Claude Opus, never a weaker class")
# the same numbers with the engines swapped: Claude over pace, Codex with headroom
SW = {"claude": {"7d": dataclasses.replace(p, engine="claude")}, "codex": {"7d": dataclasses.replace(P["claude"]["7d"], engine="codex")}}
a = lp.advise("claude", "opus", "high", "stage-a", SW)
move = [l for l in a.lines if l.startswith("2. move")][0]
check("Codex Astra high" in move and "Luna" not in move, "judgement Opus → Codex Astra, never Luna")
a = lp.advise("codex", "gpt-6.1-sol", "high", "stage-a", P)
check(any("routine bounded work runs at medium (asked: high)" in l for l in a.lines), "waste first: Sol high → medium for routine work")
check([l[:2] for l in a.lines if l[:2] in ("1.", "2.", "3.")] == ["1.", "2.", "3."], "advice in the owner's order: waste, move, sequence")
a = lp.advise("codex", "gpt-6.1-sol", "high", "stage-a", P, task_class="judgement")
check(not any("asked: high" in l for l in a.lines), "--task-class judgement: no effort-lowering advice")
a = lp.advise("claude", "sonnet", "xhigh", "stage-a", SW)
check(any("runs at high (asked: xhigh)" in l for l in a.lines), "waste: Sonnet xhigh → high")

# owner-locked stage: ask add with the numbers, never a move, refusal (no cheaper path)
os.environ["AGENT_HUB_STAGE_ENGINES"] = '{"stage-a": {"engine": "codex", "decision": "Q-T-1"}}'
lock = lp.stage_lock("stage-a")
check(lock == {"engine": "codex", "decision": "Q-T-1"}, "AGENT_HUB_STAGE_ENGINES read")
a = lp.advise("codex", "gpt-6.1-sol", "medium", "stage-a", P, lock=lock)
text = "\n".join(a.lines)
check("ask add --stage stage-a" in text and "Q-T-1" in text and "75% used" in text, "locked stage: an ask add with the numbers")
check("run this as" not in text, "locked stage: no switch proposed")
check(a.refuse is not None, "locked stage over pace: refused without --reason")
a = lp.advise("codex", "gpt-6.1-sol", "medium", "stage-a", P, reason="hotfix", lock=lock)
check(a.refuse is None and a.stop, "…--reason passes, the stop is still known (journalled)")
check(lp.stage_lock("stage-b") is None, "another stage is not locked")
del os.environ["AGENT_HUB_STAGE_ENGINES"]

# exhaustion before the reset on both engines: the one hard stop
fx("clear"); fx("codex", "60,75"); fx("claude", "60,75")
P = read()
a = lp.advise("codex", "gpt-6.1-sol", "medium", "stage-a", P)
check(a.refuse is not None and "--reason" in a.refuse, "both engines run out: refusal naming --reason")
check(any(l.startswith("4.") and "ask add" in l for l in a.lines), "…and the owner question with the numbers")
check(lp.advise("codex", "gpt-6.1-sol", "medium", "stage-a", P, reason="prod incident").refuse is None, "--reason passes")
check(lp.advise("codex", "gpt-6-luna", "low", "stage-a", P).refuse is None, "mechanical work (Luna) is never refused")
os.environ["AGENT_HUB_LIMIT_PACE"] = "warn"
a = lp.advise("codex", "gpt-6.1-sol", "medium", "stage-a", P)
check(a.refuse is None and a.stop and a.lines, "AGENT_HUB_LIMIT_PACE=warn: advice, no refusal")
del os.environ["AGENT_HUB_LIMIT_PACE"]

# below the floor (less than half the week used): advice, no refusal
fx("clear"); fx("codex", "30,40", "--elapsed-h", "10"); fx("claude", "60,75")
P = read()
check(P["codex"]["7d"].level == "exhaust" and P["codex"]["7d"].confirmed, "40% at 6% of the week: exhaustion confirmed")
check(lp.advise("codex", "gpt-6.1-sol", "medium", "stage-a", P).refuse is None, "…under the 50% floor: no refusal")

# a recent burst on a calm week: ahead, not exhaust; no refusal
fx("clear"); fx("codex", "10,25", "--elapsed-h", "100"); fx("claude", "60,75")
P = read()
p = P["codex"]["7d"]
check(p.level == "ahead" and p.burst and not p.confirmed, "a burst the window average does not confirm: ahead")
check(lp.advise("codex", "gpt-6.1-sol", "medium", "stage-a", P).refuse is None, "…never refused")

# stale data: said so, never refused
fx("clear"); fx("codex", "60,75", "--age-m", "240"); fx("claude", "60,75")
P = read()
check(P["codex"]["7d"].level == "stale", "a 4 h old sample is stale")
a = lp.advise("codex", "gpt-6.1-sol", "medium", "stage-a", P)
check(a.refuse is None and any("stale" in l for l in a.lines), "stale: says so, does not refuse")
fx("clear"); fx("codex", "60,75", "--elapsed-h", "170"); fx("claude", "60,75")
P = read()
check(P["codex"]["7d"].level == "stale" and "reset" in P["codex"]["7d"].why_stale, "a window that reset since the sample is stale")
check(lp.advise("codex", "gpt-6.1-sol", "medium", "stage-a", P).refuse is None, "…not refused")

# the other engine stale: no verified headroom, so no move is proposed
fx("clear"); fx("codex", "60,75"); fx("claude", "20,21", "--age-m", "240")
P = read()
a = lp.advise("codex", "gpt-6.1-sol", "medium", "stage-a", P)
check(not any("run this as" in l for l in a.lines) and a.refuse is not None, "headroom unknown elsewhere: no move, refusal stands")

# crossings: once per stage, engine, window instance and level
fx("clear"); fx("codex", "60,75")
P = read()
p = P["codex"]["7d"]
first = lp.note_crossing("stage-x", p)
check(first is not None and first.startswith("@hub LIMIT"), "first crossing: an @hub LIMIT line")
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
calls = []
orig_c, orig_x = lp._claude_file, lp._codex_file
lp._claude_file = lambda path: calls.append(path) or orig_c(path)
lp._codex_file = lambda path: calls.append(path) or orig_x(path)
P = read()
check(calls == [] and P["codex"]["7d"].used == 75, "unchanged logs: served from the cache, same numbers")
fx("codex", "60,80")
P = read()
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

FX clear; FX codex 60,75; FX claude 20,21
dry p2 --engine codex --model gpt-6.1-sol --effort medium; check $? 0 "Codex over pace, Claude has headroom: no refusal"
grep -q '2. move: .*run this as Claude Sonnet high' $R/p2.out; check $? 0 "…the advice moves the work to the equivalent class"
grep -q 'would journal \[pace\] @hub LIMIT Codex 7d' $R/p2.out; check $? 0 "…a dry run names the crossing line"
[ ! -s $J ] || ! grep -q 'LIMIT' $J; check $? 0 "…and does not write it"

AGENT_HUB_STAGE_ENGINES='{"stage-a": {"engine": "codex", "decision": "Q-T-1"}}' dry p3 --engine codex --model gpt-6.1-sol --effort medium
check $? 1 "owner-locked stage over pace: refused"
grep -q "ask add --stage stage-a" $R/p3.out && grep -q 'Q-T-1' $R/p3.out; check $? 0 "…with the owner question"
grep -q 'run this as' $R/p3.out; check $? 1 "…and no switch"

FX clear; FX codex 60,75; FX claude 60,75
dry p4 --engine codex --model gpt-6.1-sol --effort medium; check $? 1 "both engines run out before the reset: refused"
grep -q 'limit pace: Codex 7d' $R/p4.out && grep -q -- '--reason' $R/p4.out; check $? 0 "…saying why and how to pass"
[ ! -e $R/stage-a/agents/p4 ]; check $? 0 "…nothing was created"
dry p5 --engine codex --model gpt-6-luna --effort low; check $? 0 "mechanical work is not refused"
dry p6 --engine codex --model gpt-6.1-sol --effort medium --reason "prod incident fix"; check $? 0 "--reason passes"
$B/agent spawn --role p7 --cwd $W --brief $W/b.md --engine codex --model gpt-6.1-sol --effort medium \
  --reason "prod incident fix" > $R/p7.out 2>&1; check $? 0 "a real launch with --reason"; wait_dead p7
grep -q 'started headless agent p7 .*reason: prod incident fix, over the limit-pace stop (Codex 7d 75% used' $J; check $? 0 "…journalled as over the stop, with the numbers"
check "$(grep -c '\[pace\] @hub LIMIT Codex 7d' $J)" 1 "…one crossing line"
$B/agent spawn --role p8 --cwd $W --brief $W/b.md --engine codex --model gpt-6.1-sol --effort medium \
  --reason "second fix" > $R/p8.out 2>&1; wait_dead p8
check "$(grep -c '\[pace\] @hub LIMIT Codex 7d' $J)" 1 "a second launch: still one crossing line"

FX clear; FX codex 60,75 --age-m 240; FX claude 60,75
dry p9 --engine codex --model gpt-6.1-sol --effort medium; check $? 0 "stale Codex data: not refused"
grep -q 'data stale' $R/p9.out; check $? 0 "…and said to be stale"
AGENT_HUB_LIMIT_PACE=off dry p10 --engine claude --model sonnet; check $? 0 "AGENT_HUB_LIMIT_PACE=off: spawn goes on"
grep -q 'limit pace' $R/p10.out; check $? 1 "…with no advice"

# ---- 3. the digest line, agent-top, watchdog R6
FX clear; FX codex 60,75; FX claude 20,21
python3 - "$B" > $R/digest.out <<'PY'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("hubmod", sys.argv[1] + "/hub")
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("hubmod", loader)); loader.exec_module(m)
print(m.pace_digest("stage-a"))
PY
grep -q '^Codex week 75% used at 24% elapsed, runs out .* — over pace: routine at Sol medium; new work to Claude at the same class' $R/digest.out
check $? 0 "digest: Codex line with the action"
grep -q '^Claude week 21% used at 24% elapsed — on pace$' $R/digest.out; check $? 0 "digest: Claude line on pace, no advice"
[ "$(wc -c < $R/digest.out)" -lt 480 ]; check $? 0 "digest: the block fits its budget"
$B/agent-top --once --width 200 --stage stage-a > $R/top.out 2>&1; check $? 0 "agent-top --once"
grep -q 'Limit pace' $R/top.out && grep -q 'Codex 7d 75% used .* over pace. Advice' $R/top.out; check $? 0 "agent-top --once: an advisor line per engine"
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
exit $fail
