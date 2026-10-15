#!/bin/bash
# Hubs that say what they do: `hub start` refuses a stage name with no word about the work and wants --goal, the goal
# goes into the hub's title / digest / handoff / agent-top, takeover never refuses on the name, and `hub rename` moves a
# stage whose agents are all gone. Positive and negative controls.
. "$(dirname "$0")/lib.sh"
unset AGENT_HUB_NO_NAMING AGENT_HUB_GENERIC_STAGE_WORDS   # the rule under test is on
new_home; R=$AGENT_HUB_HOME; P=$(mktemp -d)/t
H1=11111111-1111-4111-8111-111111111111; H2=22222222-2222-4222-8222-222222222222; H3=33333333-3333-4333-8333-333333333333
roles_json(){ python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))["roles"]; print(r[sys.argv[2]][sys.argv[3]])' "$R/$1/roles.json" "$2" "$3"; }

# ---- generic names are refused, nothing is created
for n in hub-7731 stage-2 wave-a wp3 hub test_1 x1; do
  $B/hub start --stage $n --goal "Some goal" --session $H1 > $P.gen.out 2> $P.gen.err; check "$?:$([ -e $R/$n ] && echo made || echo none)" "2:none" "negative: start of the generic stage name $n is refused, nothing made"
done
grep -q "name the goal in 1–3 words" $P.gen.err; check $? 0 "…the hint says to name the goal in 1–3 words"
$B/hub start --stage retro-fixes --session $H1 > $P.nogoal.out 2> $P.nogoal.err; check "$?:$([ -e $R/retro-fixes ] && echo made || echo none)" "2:none" "negative: a good name without --goal is refused"
grep -q -- '--goal' $P.nogoal.err; check $? 0 "…and the hint names --goal"
$B/hub start --stage retro-fixes --goal "   " --session $H1 > /dev/null 2>&1; check $? 2 "negative: a blank --goal is no goal"
AGENT_HUB_GENERIC_STAGE_WORDS="retro,fixes" $B/hub start --stage retro-fixes --goal "g" --session $H1 --dry-run > /dev/null 2> $P.set.err; check $? 2 "the generic words are a setting: retro-fixes is generic when the setting says so"
AGENT_HUB_GENERIC_STAGE_WORDS="retro fixes" $B/hub start --stage hub-7731 --goal "g" --session $H1 --dry-run > /dev/null 2>&1; check $? 0 "…and hub-7731 passes when the setting replaces the list"
AGENT_HUB_NO_NAMING=1 $B/hub start --stage hub-7731 --session $H1 --dry-run > /dev/null 2>&1; check $? 0 "AGENT_HUB_NO_NAMING=1 (scripted environments) skips both checks"

# ---- start with a good name and a goal
before=$(snap $R); $B/hub start --stage retro-fixes --goal "Fix the retro findings" --session $H1 --dry-run > /dev/null 2>&1; check $? 0 "start --dry-run with a goal"
check "$(snap $R)" "$before" "…writes nothing"
GOAL="Fix what the retro found in the hub: names, spawn, hygiene, permissions — one wave   with a long tail that is cut in the title"
CLAUDE_CODE_SESSION_ID=$H1 $B/hub start --stage retro-fixes --goal "$GOAL" --session $H1 > $P.start.out 2>&1; check $? 0 "start with a good name and --goal"
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["goal"]==" ".join(sys.argv[2].split())' $R/retro-fixes/stage.json "$GOAL"; check $? 0 "…the goal is stored in stage.json, on one line"
python3 -c 'import sys; t=sys.argv[1]; g=" ".join(sys.argv[2].split()); head="Hub retro-fixes #1 — "; assert t.startswith(head+g[:50]) and t.endswith("…") and len(t)-len(head)<=60 and g not in t, t' "$(roles_json retro-fixes hub title)" "$GOAL"; check $? 0 "…the registered title is 'Hub <stage> #1 — <goal>', trimmed"
grep -q "^Goal of stage retro-fixes: Fix what the retro found" $P.start.out; check $? 0 "…the digest shows the goal"
grep -q "^- [0-9:]* \[hub-1\] start: \"Hub retro-fixes #1 — Fix what" $(journal retro-fixes); check $? 0 "…and the start line carries the title"
CLAUDE_CODE_SESSION_ID=$H1 $B/hub start --stage retro-fixes --session $H1 > /dev/null 2>&1; check $? 0 "a re-run of start by the registered hub needs no --goal"

# ---- agent-top, handoff, takeover carry it
python3 $B/agent-top --json --stage retro-fixes > $P.top.json 2>&1; python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); t=d["roles"]["retro-fixes"][0]["title"]; assert t.startswith("Hub retro-fixes #1 — Fix what"), t' $P.top.json; check $? 0 "agent-top's hub row shows the goal"
CLAUDE_CODE_SESSION_ID=$H1 $B/hub handoff --stage retro-fixes --out $R/retro-fixes/coordinator/HANDOFF-hub-retro-fixes-1.md > /dev/null; check $? 0 "handoff"
grep -q '^# Handoff "Hub retro-fixes #1" → "Hub retro-fixes #2"' $R/retro-fixes/coordinator/HANDOFF-hub-retro-fixes-1.md; check $? 0 "…its title keeps the plain 'Hub <stage> #N' the numbers are read from"
grep -q "^Goal of the stage: Fix what the retro found" $R/retro-fixes/coordinator/HANDOFF-hub-retro-fixes-1.md; check $? 0 "…and the goal is on a line of its own"
CLAUDE_CODE_SESSION_ID=$H2 $B/hub takeover --stage retro-fixes --session $H2 > $P.tk.out 2>&1; check $? 0 "takeover of the stage"
case "$(roles_json retro-fixes hub title)" in "Hub retro-fixes #2 — Fix what"*) r=0;; *) r=1;; esac; check $r 0 "…the new hub's title carries the goal"
grep -q "^Goal of stage retro-fixes:" $P.tk.out; check $? 0 "…and its digest"
CLAUDE_CODE_SESSION_ID=$H2 $B/hub takeover --stage retro-fixes --session $H3 --goal "New goal" > $P.tk3.out 2>&1; check $? 0 "takeover --goal replaces the goal"
[ "$(roles_json retro-fixes hub title)" = "Hub retro-fixes #3 — New goal" ]; check $? 0 "…title of #3"
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["goal"]=="New goal"' $R/retro-fixes/stage.json; check $? 0 "…stored"
HUB_NAME_CHECK=$($B/hub takeover --stage retro-fixes --session $H3 --dry-run 2>&1 | head -1); case "$HUB_NAME_CHECK" in "Hub retro-fixes #3 — New goal:"*) r=0;; *) r=1;; esac; check $r 0 "a dry-run takeover names the hub with the goal too"

# ---- takeover never refuses on the name; a stage with no goal keeps today's title
mkdir -p $R/stage-old/coordinator/work
$B/hub takeover --stage stage-old --session $H1 > $P.old.out 2>&1; check $? 0 "takeover of an existing stage with a generic name is not refused"
[ "$(roles_json stage-old hub title)" = "Hub stage-old #1" ]; check $? 0 "…a stage without a goal keeps the title 'Hub <stage> #N'"
! grep -q "^Goal of stage" $P.old.out; check $? 0 "…and no goal line in the digest"

# ---- rename
$B/hub start --stage yc-move --goal "Move Sentinel to YC" --session $H1 > /dev/null 2>&1
mkdir -p $R/yc-move/agents/a1 $R/yc-move/coordinator/work
TOKEN=fake-agent-token-$$
bash -c 'sleep 300; :' $TOKEN > /dev/null 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null; test_cleanup' EXIT
cat > $R/yc-move/agents/a1/meta.json <<JSON
{"role": "a1", "tag": "a1", "model": "sonnet", "stage": "yc-move", "session_id": "$H2", "process_token": "$TOKEN", "pid": $PID,
 "dir": "$R/yc-move/agents/a1", "brief": "$R/yc-move/coordinator/work/brief.md", "title": "agent a1 (yc-move)", "engine": "claude"}
JSON
echo '{"type":"result","subtype":"success","is_error":false}' > $R/yc-move/agents/a1/log.jsonl
$B/roles --stage yc-move set a1 $H2 --kind headless --tag a1 --title "agent a1 (yc-move)" > /dev/null
CLAUDE_CODE_SESSION_ID=$H1 $B/lock take main-merge --repo web --until +1h --why "yc-move: the deploy window" --owner-name "Hub yc-move #1" > /dev/null 2>&1; check $? 0 "setup: a lock whose notes name the stage"
CLAUDE_CODE_SESSION_ID=$H3 $B/lock take main-merge --repo other --until +1h --why "unrelated: the move to a cheaper cloud" --owner-name "Hub other #1" > /dev/null 2>&1; check $? 0 "setup: a lock of another stage"
before=$(snap $R); $B/hub rename --stage yc-move --to yc-cutover > $P.rn1.out 2> $P.rn1.err; check "$?:$([ -d $R/yc-move ] && echo kept || echo gone)" "2:kept" "negative: a stage with a live agent is not renamed"
grep -q "live agents: a1" $P.rn1.err; check $? 0 "…the refusal lists the live agent"
check "$(snap $R)" "$before" "…and nothing changed"
kill $PID; wait $PID 2>/dev/null; sleep 0.3
$B/hub rename --stage yc-move --to yc-cutover --dry-run > $P.rn2.out 2>&1; check $? 0 "rename --dry-run of a stage whose agent is gone"
check "$(snap $R)" "$before" "…writes nothing"
grep -q "board: main-merge (web)" $P.rn2.out; check $? 0 "…and lists the board's lock note it would change"
$B/hub rename --stage yc-move --to hub-3 > /dev/null 2> $P.rn3.err; check $? 2 "negative: the new name is checked like start's"
$B/hub rename --stage yc-move --to retro-fixes > /dev/null 2> $P.rn4.err; check $? 2 "negative: an existing stage is not overwritten"
$B/hub rename --stage nosuch --to yc-cutover > /dev/null 2>&1; check $? 2 "negative: an unknown stage"
$B/hub rename --stage yc-move --to yc-cutover > $P.rn5.out 2>&1; check "$?:$([ -d $R/yc-move ] && echo kept || echo gone):$([ -d $R/yc-cutover ] && echo there || echo none)" "0:gone:there" "rename of a stage with no live agent"
$B/roles --stage yc-cutover list > $P.rl.out 2>&1; check $? 0 "roles list --stage NEW works"
grep -q 'Hub yc-cutover #1 — Move Sentinel to YC' $P.rl.out && grep -q 'agent a1 (yc-cutover)' $P.rl.out; check $? 0 "…titles carry the new name"
$B/agent status --stage yc-cutover a1 > $P.as.out 2>&1; check $? 0 "agent status --stage NEW works"
grep -q "ALIVE" $P.as.out; check $? 1 "…and finds the agent (finished, not alive)"
python3 - $R/yc-cutover/agents/a1/meta.json $R <<'PY'
import json, sys
m = json.load(open(sys.argv[1])); r = sys.argv[2]
assert m["stage"] == "yc-cutover" and m["title"] == "agent a1 (yc-cutover)", m
assert m["dir"] == f"{r}/yc-cutover/agents/a1" and m["brief"] == f"{r}/yc-cutover/coordinator/work/brief.md", m
PY
check $? 0 "…the agent's meta: stage, title and paths"
python3 -c 'import json,sys; roles=json.load(open(sys.argv[1]))["roles"]; assert roles["a1"]["title"]=="agent a1 (yc-cutover)" and roles["hub"]["title"].startswith("Hub yc-cutover #1")' $R/yc-cutover/roles.json; check $? 0 "…roles.json"
head -1 $R/yc-cutover/questions.md 2>/dev/null | grep -q "yc-cutover" || [ ! -e $R/yc-cutover/questions.md ]; check $? 0 "…the question register's heading, when there is one"
$B/lock list > $P.ll.out 2>&1; grep -q 'Hub yc-cutover #1' $P.ll.out && grep -q 'yc-cutover: the deploy window' $P.ll.out && ! grep -q 'yc-move' $P.ll.out; check $? 0 "…the board's lock notes name the new stage"
grep -q 'unrelated: the move to a cheaper cloud' $P.ll.out; check $? 0 "…and another stage's lock is left alone"

# ---- the recovery hints carry the goal placeholder
$B/jlog --stage nosuch-stage "x" > /dev/null 2> $P.h1.err; grep -q -- 'hub start --stage S --goal' $P.h1.err; check $? 0 "jlog's no-tag hint shows hub start with --goal"
$B/tell retro-fixes "x" > /dev/null 2> $P.h2.err; grep -q -- 'hub start --stage S --goal' $P.h2.err; check $? 0 "tell's no-tag hint shows hub start with --goal"
$B/hub takeover --stage nosuch-stage --session $H1 > /dev/null 2> $P.h3.err; grep -q -- 'hub start --stage nosuch-stage --goal' $P.h3.err; check $? 0 "takeover of a missing stage points at hub start with --goal"

# ---- a rename that cannot go through leaves the stage where and what it was
$B/hub start --stage fix-quotes --goal "Fix quotes" --session $H1 > /dev/null 2>&1; check $? 0 "setup: a stage to rename"
echo '{"chain": 1, "pending": {' > $R/fix-quotes/auto-handoff.json
before=$(snap $R); $B/hub rename --stage fix-quotes --to quotes-fixed > $P.bad.out 2> $P.bad.err; check "$?:$([ -d $R/fix-quotes ] && echo kept || echo gone):$([ -e $R/quotes-fixed ] && echo made || echo none)" "1:kept:none" "negative: a corrupt json file stops the rename before anything moves"
grep -q "auto-handoff.json cannot be read as JSON" $P.bad.err && grep -q "nothing was renamed" $P.bad.err; check $? 0 "…the message names the file"
check "$(snap $R)" "$before" "…and nothing changed"
echo '{"chain": 1, "pending": null}' > $R/fix-quotes/auto-handoff.json
if [ "$(id -u)" != 0 ]; then
  mkdir -p $R/fix-quotes/agents/b1; echo '{"role": "b1", "stage": "fix-quotes", "pid": 999999}' > $R/fix-quotes/agents/b1/meta.json; chmod 555 $R/fix-quotes/agents/b1
  before=$(snap $R); $B/hub rename --stage fix-quotes --to quotes-fixed > $P.wf.out 2> $P.wf.err; rc=$?; chmod 755 $R/fix-quotes/agents/b1 $R/quotes-fixed/agents/b1 2> /dev/null
  check "$rc:$([ -d $R/fix-quotes ] && echo kept || echo gone):$([ -e $R/quotes-fixed ] && echo made || echo none)" "1:kept:none" "negative: a write that fails half-way is rolled back (directory back, nothing at the new name)"
  grep -q "rolled back" $P.wf.err; check $? 0 "…and says so"
  check "$(snap $R)" "$before" "…every json file is as it was"
  rm -rf $R/fix-quotes/agents/b1
else
  echo "SKIP rollback of a failed write (running as root: a read-only directory does not stop it)"
fi
$B/hub rename --stage fix-quotes --to quotes-fixed > $P.ok.out 2>&1; check "$?:$([ -d $R/quotes-fixed ] && echo there || echo none)" "0:there" "control: once the cause is gone, the same rename goes through"

# ---- a rename holds the stage's roles lock from its first read: a concurrent `roles set` is not overwritten
$B/hub start --stage lock-race --goal "Race the lock" --session $H1 > /dev/null 2>&1; check $? 0 "setup: a stage for the lock race"
python3 - $R/lock-race $B $H2 > $P.holder.out 2>&1 <<'PY' &
import sys, time, json, fcntl
stage, B, sid = sys.argv[1:4]
sys.path.insert(0, B)
import hubcore as hc
with open(f"{stage}/.roles.lock", "a") as fh:      # the lock a `roles set` of the stage's own hub holds
    fcntl.flock(fh, fcntl.LOCK_EX)
    print("locked", flush=True)
    time.sleep(3)
    path = f"{stage}/roles.json"
    data = json.load(open(path))
    data["roles"]["late"] = {"session": sid, "cli_session_id": sid, "kind": "headless", "tag": "late", "title": "agent late (lock-race)"}
    json.dump(data, open(path, "w"), indent=1)
PY
HOLDER=$!
for i in $(seq 1 100); do grep -q locked $P.holder.out 2>/dev/null && break; sleep 0.1; done
$B/hub rename --stage lock-race --to race-lock > $P.race.out 2>&1; check $? 0 "rename while the roles lock is held by a writer"
wait $HOLDER
python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))["roles"]; assert "late" in r and r["late"]["tag"]=="late" and r["hub"]["title"].startswith("Hub race-lock #1"), sorted(r)' $R/race-lock/roles.json; check $? 0 "…waits for it: the role written meanwhile is in the renamed stage, not overwritten by a stale snapshot"

# ---- Ctrl-C between two writes rolls the rename back (KeyboardInterrupt is not an Exception)
$B/hub start --stage int-stage --goal "Interrupt me" --session $H1 > /dev/null 2>&1; check $? 0 "setup: a stage for the interrupt"
python3 - $B $R > $P.int.out 2>&1 <<'PY'
import argparse, importlib.machinery, importlib.util, json, os, sys
B, R = sys.argv[1:3]
sys.path.insert(0, B)
import hubcore as hc
loader = importlib.machinery.SourceFileLoader("hub_cli", f"{B}/hub")
mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("hub_cli", loader)); loader.exec_module(mod)
before = open(f"{R}/int-stage/roles.json").read()
real, calls = hc.atomic_write, []
def interrupted(path, text):
    calls.append(path)
    if len(calls) == 2:
        raise KeyboardInterrupt
    return real(path, text)
hc.atomic_write = interrupted
try:
    mod.cmd_rename(argparse.Namespace(stage="int-stage", to="stage-int", dry_run=False))
    print("NO-INTERRUPT")
except KeyboardInterrupt:
    print("INTERRUPTED")
hc.atomic_write = real
assert os.path.isdir(f"{R}/int-stage") and not os.path.exists(f"{R}/stage-int"), "directory not back"
assert open(f"{R}/int-stage/roles.json").read() == before, "roles.json not restored"
print("RESTORED")
PY
grep -q INTERRUPTED $P.int.out && grep -q RESTORED $P.int.out; check $? 0 "Ctrl-C after the first rewritten file: the original interrupt is re-raised and the stage is back where and what it was"
$B/hub rename --stage int-stage --to stage-int > /dev/null 2>&1; check "$?:$([ -d $R/stage-int ] && echo there || echo none)" "0:there" "…so the same rename can be run again"
exit $fail
