#!/bin/bash
# hub grill: the hub launches a separate interactive grilling session over the stage's open questions. The brief and the
# pending launch; one session per stage; the launch per host (Claude Desktop start_session arguments that the
# session_cards hook lets through, Codex app create_thread arguments, `claude --bg --remote-control` through a stand-in
# CLI, the manual command); join registers role `grill`; done tallies the register, writes "@hub GRILLED …" that wakes the
# hub's jwait, and retires the role.
. "$(dirname "$0")/lib.sh"
unset AGENT_ROLE   # a Codex app thread is never a detached worker (engines.codex_desktop)
new_home; R=$AGENT_HUB_HOME; O=$(mktemp -d); export CLAUDE_SESSIONS_DIR=$R/sessions
HUB=11111111-1111-4111-8111-111111111111
G1=22222222-2222-4222-8222-222222222222
G2=33333333-3333-4333-8333-333333333333
LOC=44444444-4444-4444-8444-444444444444      # a Desktop hub: its local_ id …
LOCCLI=55555555-5555-4555-8555-555555555555   # … and its CLI session
grill(){ (cd "$O" && "$B/hub" grill "$@"); }
launchid(){ sed -n 's/^launch: //p' "$1"; }
statusre(){ python3 -c 'import re,sys; sys.path.insert(0,sys.argv[1]); import hubcore as hc; sys.exit(0 if re.search(hc.status_pattern(), sys.stdin.read()) else 1)' "$B"; }

$B/roles --stage stage-a set hub $HUB --kind cli --tag hub-1 >/dev/null; check $? 0 "register the hub of stage-a"
Q1=$($B/ask add --stage stage-a --print-id --blocks "the release" --default "ship" "Ship on Friday?")
Q2=$($B/ask add --stage stage-a --print-id "Which colour for the badge?")
Q3=$($B/ask add --stage stage-a --print-id "Already answered one")
$B/ask close $Q3 --answer "yes" >/dev/null
D1=$($B/ask decided --stage stage-a 2>/dev/null "Use the old parser" | head -1 | awk '{print $1}')
QB=$($B/ask add --stage stage-b --print-id "A question of stage-b")
mkdir -p $R/stage-c

# ---- nothing to grill
grill --stage stage-c --host desktop > $O/none.out 2>&1; check $? 1 "no open questions: exit 1"
grep -q "nothing to grill" $O/none.out; check $? 0 "…and says so"
test ! -e $R/stage-c/grill.json; check $? 0 "…and records no launch"

# ---- dry run: the brief and the launch printed, nothing written
grill --stage stage-a --host desktop --dry-run > $O/dry.out 2>&1; check $? 0 "dry run: exit 0"
grep -q "Q-A-001" $O/dry.out; check $? 0 "dry run: prints the brief"
test ! -e $R/stage-a/grill.json; check $? 0 "dry run: no pending launch"
check "$(find $R/stage-a -name 'grill-*-brief.md' | wc -l | tr -d ' ')" 0 "dry run: no brief file"

# ---- Claude Desktop launch: brief, pending launch, start_session arguments with user_asked
CLAUDE_CODE_SESSION_ID=$HUB grill --stage stage-a --host desktop --owner-words "погриль по открытым" --topic "the release" > $O/d.out 2>&1
check $? 0 "desktop: exit 0"
BRIEF=$(sed -n 's/^brief: //p' $O/d.out)
test -f "$BRIEF"; check $? 0 "desktop: the brief is written"
for q in $Q1 $Q2; do grep -q "$q" "$BRIEF"; check $? 0 "brief lists the open question $q"; done
grep -q "$Q3" "$BRIEF"; check $? 1 "brief leaves out an answered question"
grep -q "$QB" "$BRIEF"; check $? 1 "brief leaves out another stage's question"
grep -q "$D1" "$BRIEF"; check $? 1 "brief leaves out an agent's decision"
L0=$(launchid $O/d.out)
test -n "$L0"; check $? 0 "desktop: prints the launch id"
for w in "grill join --stage stage-a --launch $L0 --session self" "grill done --stage stage-a" "ask close <id> --answer" \
         "grilling\` skill" "never taken on silence" "jlog --stage stage-a" "погриль по открытым" "the release" "Execute nothing" "--by grill"; do
  grep -qF -- "$w" "$BRIEF"; check $? 0 "brief says: $w"
done
python3 - "$O/d.out" "$BRIEF" > $O/d.json <<'PY'
import json, sys
line = next(l for l in open(sys.argv[1]) if l.startswith('{"start_session"'))
d = json.loads(line)["start_session"]
assert d["initiation"] == "user_asked", d
assert sys.argv[2] in d["prompt"] and "grill join" in d["prompt"], d
print(json.dumps(d))
PY
check $? 0 "desktop: start_session arguments with initiation user_asked and the brief in the prompt"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); p=d["pending"]; assert p["host"]=="desktop" and p["questions"]==[sys.argv[2],sys.argv[3]] and p["brief"]==sys.argv[4], p' \
  $R/stage-a/grill.json $Q1 $Q2 "$BRIEF"; check $? 0 "desktop: the pending launch is recorded with its questions"
grep "grill: grilling session launched (desktop, launch $L0)" "$(journal)" > $O/launch.line; check $? 0 "desktop: a journal line"
grep -q "\[hub-1\]" $O/launch.line; check $? 0 "…signed with the hub's tag"
statusre < $O/launch.line; check $? 1 "…with no status word: it wakes nobody"

# ---- the session_cards hook lets the printed start through in a hub, and still refuses a card
hookrun(){ python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d.update(json.loads(sys.argv[2])); print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"mcp__ccd_session__start_session","session_id":sys.argv[3],"cwd":sys.argv[4],"tool_input":d}))' \
  $O/d.json "$1" $HUB "$R" | python3 $HOOKS/session_cards.py pre-tool; }
check "$(hookrun '{}' | wc -c | tr -d ' ')" 0 "session_cards: the grilling start (user_asked) passes in a hub"
hookrun '{"initiation":"offer"}' | grep -q '"permissionDecision": "deny"'; check $? 0 "control: the same start as a card (offer) is denied in the hub"

# ---- one at a time: a pending launch refuses another, --again replaces it
grill --stage stage-a --host desktop > $O/again.out 2>&1; check $? 2 "a pending launch refuses a second one"
grep -q "has not joined yet" $O/again.out; check $? 0 "…and says why"
AGENT_HUB_GRILL_JOIN_MIN=1 python3 - $R/stage-a/grill.json <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["pending"]["ts"] -= 120; json.dump(d, open(p, "w"))
PY
AGENT_HUB_GRILL_JOIN_MIN=1 grill --stage stage-a --host desktop > $O/la.out 2>&1; check $? 0 "a pending launch past its join window does not hold"
LA=$(launchid $O/la.out)
grill --stage stage-a --host desktop --again > $O/lb.out 2>&1; check $? 0 "--again replaces a pending launch"
LB=$(launchid $O/lb.out)
CLAUDE_CODE_SESSION_ID=$G2 $B/hub grill join --stage stage-a --launch $LA --session self > $O/stale.out 2>&1; check $? 2 "join of a replaced launch: refused"
grep -q "not the pending one" $O/stale.out; check $? 0 "…and says so"
CLAUDE_CODE_SESSION_ID=$G2 $B/hub grill join --stage stage-a --session self > /dev/null 2>&1; check $? 2 "join without a launch id: refused"
$B/roles --stage stage-a get grill >/dev/null 2>&1; check $? 1 "…nothing registered"

# ---- join: the new session registers as role grill
CLAUDE_CODE_SESSION_ID=$G1 $B/hub grill join --stage stage-a --launch $LB --session self > $O/j.out 2>&1; check $? 0 "join: exit 0"
check "$($B/roles --stage stage-a get grill)" $G1 "join: role grill holds the session's full id"
python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))["roles"]["grill"]; assert r["tag"]=="grill" and r["questions"]==[sys.argv[2],sys.argv[3]] and r["brief"].endswith("-brief.md") and r["launched"]=="desktop", r' \
  $R/stage-a/roles.json $Q1 $Q2; check $? 0 "join: tag grill, the questions and the brief in the record"
python3 -c 'import json,sys; assert "pending" not in json.load(open(sys.argv[1]))' $R/stage-a/grill.json 2>/dev/null || test ! -e $R/stage-a/grill.json
check $? 0 "join: the pending launch is cleared"
grep -q "\[grill\] grill join: grilling session $G1" "$(journal)"; check $? 0 "join: a journal line by the grill tag"
CLAUDE_CODE_SESSION_ID=$G1 $B/jlog --stage stage-a "a line of the grilling session" >/dev/null
grep -q "\[grill\] a line of the grilling session" "$(journal)"; check $? 0 "jlog in the grilling session signs with tag grill"
CLAUDE_CODE_SESSION_ID=$G1 $B/hub grill join --stage stage-a --launch $LB --session self >/dev/null 2>&1; check $? 0 "join again by the same session: fine"
CLAUDE_CODE_SESSION_ID=$G2 $B/hub grill join --stage stage-a --launch $LB --session self > $O/j2.out 2>&1; check $? 2 "join by another session: refused (one per stage)"
check "$($B/roles --stage stage-a get grill)" $G1 "…the role stays with the first"
grill --stage stage-a --host desktop --again > $O/busy.out 2>&1; check $? 2 "a registered grilling session refuses a launch, even with --again"
grep -q "is registered" $O/busy.out; check $? 0 "…and names it"
$B/tell stage-a --role grill --address > $O/addr.out 2>&1; check $? 0 "tell finds the grilling session by its role"
grep -q $G1 $O/addr.out; check $? 0 "…by its full id"

# ---- the session records answers; done tallies them, wakes the hub's jwait and retires the role
$B/ask close $Q1 --answer "ship on Friday" >/dev/null
QN=$($B/ask add --stage stage-a --by grill --print-id "A new question from the grilling")
$B/ask close $QN --answer "no" >/dev/null
CLAUDE_CODE_SESSION_ID=$G2 $B/hub grill done --stage stage-a --summary "late" > $O/late.out 2>&1; check $? 2 "done from another session without --why: refused"
check "$($B/roles --stage stage-a get grill)" $G1 "…the role stays"
grep -q "GRILLED" "$(journal)"; check $? 1 "…and nothing is reported"
( armed $O/w.out; CLAUDE_CODE_SESSION_ID=$G1 $B/hub grill done --stage stage-a --summary "release decided, colour open" > $O/done.out 2>&1; echo $? > $O/done.rc ) &
HUB_TAG=hub-1 $B/jwait --journal --stage stage-a --hub-events --settle 1 --for 30s > $O/w.out 2>&1; rc=$?
wait
check $rc 0 "done: wakes jwait --hub-events"
check "$(cat $O/done.rc)" 0 "done: exit 0"
grep -q "@hub GRILLED 1 answered, 0 withdrawn, 1 open of 2; 1 new" $O/w.out; check $? 0 "done: the line counts answered/open/new from the register"
grep -q "answered $Q1" $O/w.out && grep -q "open $Q2" $O/w.out && grep -q "new $QN" $O/w.out; check $? 0 "done: names the ids"
grep -q "release decided, colour open" $O/w.out; check $? 0 "done: carries the summary"
grep -q "\[grill\] @hub GRILLED" "$(journal)"; check $? 0 "done: signed by the grill tag"
$B/roles --stage stage-a get grill >/dev/null 2>&1; check $? 1 "done: the role is retired"
python3 -c 'import json,sys; r=[x for x in json.load(open(sys.argv[1]))["retired"] if x["role"]=="grill"]; assert r and "release decided" in r[-1]["retired_why"], r' $R/stage-a/roles.json
check $? 0 "done: the retired record keeps why"
# the digest's jwait of the hub (--tag hub, no --hub-events) wakes on it too: run a fresh caller over the same line
HUB_TAG=hub-1 $B/jwait --journal --stage stage-a --tag hub-1 --tag hub --since 00:00 --settle 0 --for 5s > $O/w2.out 2>&1
grep -q "@hub GRILLED" $O/w2.out; check $? 0 "done: the digest's jwait (--tag hub) delivers it"
CLAUDE_CODE_SESSION_ID=$G1 $B/hub grill done --stage stage-a > $O/d2.out 2>&1; check $? 1 "done with nothing registered or pending: exit 1"

# ---- done by the hub drops a launch that never joined
grill --stage stage-a --host desktop > $O/ld.out 2>&1; check $? 0 "a new launch after done"
HUB_TAG=hub-1 $B/hub grill done --stage stage-a --why "the owner went away" > $O/drop.out 2>&1; check $? 0 "done --why drops a pending launch"
python3 -c 'import json,sys; assert "pending" not in json.load(open(sys.argv[1]))' $R/stage-a/grill.json 2>/dev/null || test ! -e $R/stage-a/grill.json
check $? 0 "…the pending launch is gone"
grep "pending grilling launch is dropped — the owner went away" "$(journal)" | statusre; check $? 1 "…its journal line wakes nobody"
CLAUDE_CODE_SESSION_ID=$G1 $B/hub grill join --stage stage-a --launch $(launchid $O/ld.out) --session self >/dev/null 2>&1; check $? 2 "a dropped launch cannot join"

# ---- the hub ends a session that went away (--why); other stages' answers are named in the report
grill --stage stage-a --host desktop --also-stage stage-b --questions "$Q2,$Q2,$QB" > $O/lm.out 2>&1; check $? 0 "a launch over two stages"
python3 -c 'import json,sys; p=json.load(open(sys.argv[1]))["pending"]; assert p["questions"]==[sys.argv[2],sys.argv[3]] and p["stages"]==["stage-a","stage-b"], p' $R/stage-a/grill.json $Q2 $QB
check $? 0 "--questions: a repeated id counts once; the stages are recorded"
CLAUDE_CODE_SESSION_ID=$G1 $B/hub grill join --stage stage-a --launch $(launchid $O/lm.out) --session self >/dev/null 2>&1; check $? 0 "join"
$B/ask close $QB --answer "b answered" >/dev/null
HUB_TAG=hub-1 $B/hub grill done --stage stage-a --why "the session window was closed" > $O/adm.out 2>&1; check $? 0 "done --why by the hub ends the registered session"
grep -q "@hub GRILLED 1 answered, 0 withdrawn, 1 open of 2" $O/adm.out; check $? 0 "…counted from the register, a repeated id once"
grep -q "ended by hub-1: the session window was closed" $O/adm.out; check $? 0 "…says who ended it and why"
grep -q "ask list --pending --stage stage-a; ask list --pending --stage stage-b" $O/adm.out; check $? 0 "…names the pending answers of every stage grilled over"
grep -q "\[hub-1\] @hub GRILLED" "$(journal)"; check $? 0 "…signed by the hub, not by the grill tag"
$B/roles --stage stage-a get grill >/dev/null 2>&1; check $? 1 "…the role is retired"
grill --stage stage-a --host desktop --questions "$QB" > /dev/null 2>&1; check $? 0 "a launch over another stage's question only"
python3 -c 'import json,sys; p=json.load(open(sys.argv[1]))["pending"]; assert p["stages"]==["stage-a","stage-b"], p' $R/stage-a/grill.json
check $? 0 "…keeps the launching stage in its stages (new questions are recorded there)"
HUB_TAG=hub-1 $B/hub grill done --stage stage-a --why "test" >/dev/null 2>&1

# ---- question selection: --questions, --also-stage
grill --stage stage-a --host desktop --questions "$D1,$QB" --dry-run > $O/sel.out 2>&1; check $? 0 "--questions: exit 0"
grep -q "$D1" $O/sel.out && grep -q "$QB" $O/sel.out; check $? 0 "--questions: takes entries by id, any kind and stage"
grep -q "$Q2" $O/sel.out; check $? 1 "--questions: …and only those"
grill --stage stage-a --host desktop --questions "Q-ZZ-999" --dry-run > /dev/null 2>&1; check $? 2 "--questions: an unknown id is a usage error"
QB2=$($B/ask add --stage stage-b --print-id "Another question of stage-b")
grill --stage stage-a --host desktop --also-stage stage-b --dry-run > $O/also.out 2>&1; check $? 0 "--also-stage: exit 0"
grep -q "$QB2" $O/also.out && grep -q "$Q2" $O/also.out; check $? 0 "--also-stage: the named stage's open questions join the stage's own"

# ---- host detection (dry runs)
CODEX_THREAD_ID=$G2 CODEX_INTERNAL_ORIGINATOR_OVERRIDE="Codex Desktop" CODEX_APP_TOOLS_PIPE_PATH=/tmp/pipe \
  grill --stage stage-a --dry-run > $O/h1.out 2>&1; grep -q "host codex-app" $O/h1.out; check $? 0 "auto: a Codex app thread → codex-app"
CODEX_THREAD_ID=$G2 grill --stage stage-a --dry-run > $O/h2.out 2>&1; grep -q "host manual" $O/h2.out; check $? 0 "auto: another Codex host → manual"
mkdir -p $CLAUDE_SESSIONS_DIR/a/b
printf '{"sessionId":"local_%s","cliSessionId":"%s","title":"Hub stage-a","isArchived":false}' $LOC $LOCCLI > $CLAUDE_SESSIONS_DIR/a/b/local_$LOC.json
CLAUDE_CODE_SESSION_ID=$LOCCLI CLAUDE_CODE_HOST_SESSION_ID=local_$LOC grill --stage stage-a --dry-run > $O/h3.out 2>&1
grep -q "host desktop" $O/h3.out; check $? 0 "auto: a Claude Desktop session (Desktop's record names it) → desktop"
AGENT_HUB_ENGINE=codex CLAUDE_CODE_SESSION_ID=$LOCCLI CLAUDE_CODE_HOST_SESSION_ID=local_$LOC grill --stage stage-a --dry-run > $O/h5.out 2>&1
grep -q "host desktop" $O/h5.out; check $? 0 "auto: AGENT_HUB_ENGINE=codex (executors) does not turn a Claude Desktop hub into a Codex one"
CLAUDE_CODE_SESSION_ID=$G2 CLAUDE_CODE_HOST_SESSION_ID=local_$LOC CLAUDE_BIN=$T/fake_claude_bg.py grill --stage stage-a --dry-run > $O/h4.out 2>&1
grep -q "would start: claude --bg --remote-control stage-a-grill" $O/h4.out; check $? 0 "auto: a child that only inherited the host id → bg"

# ---- Codex app: create_thread arguments for the app agent
CODEX_THREAD_ID=$G2 CODEX_INTERNAL_ORIGINATOR_OVERRIDE="Codex Desktop" CODEX_APP_TOOLS_PIPE_PATH=/tmp/pipe \
  grill --stage stage-a > $O/c.out 2>&1; check $? 0 "codex-app: exit 0"
python3 - $O/c.out <<'PY'
import json, sys
line = next(l for l in open(sys.argv[1]) if l.startswith('{"create_thread"'))
d = json.loads(line)
a = d["create_thread"]
assert a["title"] == "Grill stage-a" and "grill join" in a["prompt"], a
assert a["target"]["type"] == "project" and a["target"]["environment"] == {"type": "local"}, a
assert "list_projects" in a["target"]["projectId"] and d["project_root"], d
PY
check $? 0 "codex-app: create_thread arguments with the project to look up"
grep -q "list_projects" $O/c.out && grep -q "once" $O/c.out; check $? 0 "codex-app: the procedure (list_projects, create_thread once)"
CODEX_THREAD_ID=$G2 $B/hub grill join --stage stage-a --launch $(launchid $O/c.out) --session self >/dev/null 2>&1; check $? 0 "codex: the thread joins by CODEX_THREAD_ID"
python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))["roles"]["grill"]; assert r["session"]==sys.argv[2] and r["engine"]=="codex" and r["launched"]=="codex-app", r' $R/stage-a/roles.json $G2
check $? 0 "codex: registered with engine codex"
CODEX_THREAD_ID=$G2 $B/hub grill done --stage stage-a --summary "x" >/dev/null 2>&1; check $? 0 "codex: done"

# ---- manual (a Codex terminal hub)
CODEX_THREAD_ID=$G2 grill --stage stage-a > $O/m.out 2>&1; check $? 0 "manual: exit 0"
grep -q "codex 'You are the grilling session of stage stage-a" $O/m.out; check $? 0 "manual: the command for the owner"
HUB_TAG=hub-1 $B/hub grill done --stage stage-a --why "test" >/dev/null 2>&1

# ---- another Claude host: claude --bg --remote-control through the stand-in CLI
export CLAUDE_BIN=$T/fake_claude_bg.py FAKE_BG_LOG=$O/bg.log
AGENT_HUB_ENGINE=codex CLAUDE_CODE_SESSION_ID=$HUB grill --stage stage-a --host bg --model opus --effort high > $O/bg.out 2>&1; check $? 0 "bg: exit 0"
grep -q "https://claude.ai/code/session_01AbC-xyz" $O/bg.out; check $? 0 "bg: prints the Remote Control link for the owner"
grep -q "bg-1234abcd" $O/bg.out; check $? 0 "bg: names the background session"
python3 - $O/bg.log "$R" <<'PY'
import json, sys
calls = [json.loads(l) for l in open(sys.argv[1])]
bg = next(c for c in calls if c["argv"][:1] == ["--bg"])
a = bg["argv"]
assert a[1:3] == ["--remote-control", "stage-a-grill"] and a[a.index("-n") + 1] == "Grill stage-a", a
assert a[a.index("--effort") + 1] == "high" and "--model" in a, a
s = json.loads(a[a.index("--settings") + 1])
allow = s["permissions"]["allow"]
assert any(x.endswith("hub grill:*)") for x in allow) and "Bash(ask:*)" in allow, allow
assert s.get("idleCompaction") is False, s
assert a[-1].startswith("You are the grilling session of stage stage-a"), a[-1]
assert bg["env"]["CLAUDE_CODE_SESSION_ID"] is None and bg["env"]["HUB_TAG"] is None, bg["env"]
assert bg["env"]["AGENT_HUB_ENGINE"] is None, bg["env"]
assert bg["env"]["AGENT_HUB_HOME"] == sys.argv[2], bg["env"]
assert any(c["argv"][:2] == ["logs", "bg-1234abcd"] for c in calls), calls
PY
check $? 0 "bg: --remote-control <stage>-grill, the settings allow ask/hub grill, no idle compaction, the hub's identity stripped"
python3 -c 'import json,sys; p=json.load(open(sys.argv[1]))["pending"]; assert p["host"]=="bg" and p["bg_id"]=="bg-1234abcd" and p["link"].startswith("https://"), p' $R/stage-a/grill.json
check $? 0 "bg: the pending launch keeps the session id and the link"
AGENT_HUB_ENGINE=codex CLAUDE_CODE_SESSION_ID=$G1 $B/hub grill join --stage stage-a --launch $(launchid $O/bg.out) --session self >/dev/null 2>&1
check $? 0 "bg: the session joins with AGENT_HUB_ENGINE=codex set"
python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))["roles"]["grill"]; assert r["session"]==sys.argv[2] and r["engine"]=="claude" and r["launched"]=="bg", r' $R/stage-a/roles.json $G1
check $? 0 "…registered by its Claude id, engine claude"
CLAUDE_CODE_SESSION_ID=$G1 $B/hub grill done --stage stage-a --summary "x" >/dev/null 2>&1; check $? 0 "…and reports"
printf 'none\nlate\n' > $O/seq
FAKE_BG=noid FAKE_AGENT_NAME=stage-a-grill FAKE_AGENTS_SEQ=$O/seq grill --stage stage-a --host bg > $O/bgn.out 2>&1; check $? 0 "bg printed no id, \`claude agents\` lists it: exit 0"
grep -q "bg-from-list" $O/bgn.out; check $? 0 "…the session id is taken from \`claude agents\`"
HUB_TAG=hub-1 $B/hub grill done --stage stage-a --why "test" >/dev/null 2>&1
# a session of the same name listed before this start (a launch replaced a moment ago) is not taken for this one
printf 'late\nlate\n' > $O/seq
FAKE_BG=noid FAKE_AGENT_NAME=stage-a-grill FAKE_AGENTS_SEQ=$O/seq grill --stage stage-a --host bg > $O/bgp.out 2>&1; check $? 1 "bg: only a session listed before the start: not taken, exit 1"
grep -q "bg-from-list" $O/bgp.out; check $? 1 "…its id is not recorded"
HUB_TAG=hub-1 $B/hub grill done --stage stage-a --why "test" >/dev/null 2>&1
printf 'fail\nlate\n' > $O/seq
FAKE_BG=noid FAKE_AGENT_NAME=stage-a-grill FAKE_AGENTS_SEQ=$O/seq grill --stage stage-a --host bg > $O/bgf.out 2>&1; check $? 1 "bg: the list before the start unreadable: no id recovered, exit 1"
grep -q "bg-from-list" $O/bgf.out; check $? 1 "…no id is recorded"
HUB_TAG=hub-1 $B/hub grill done --stage stage-a --why "test" >/dev/null 2>&1
FAKE_BG=noid FAKE_AGENTS=none grill --stage stage-a --host bg > $O/bgu.out 2>&1; check $? 1 "bg printed no id and nothing is listed: exit 1"
grep -q "may still come up" $O/bgu.out; check $? 0 "…says the session may still come up"
python3 -c 'import json,sys; p=json.load(open(sys.argv[1]))["pending"]; assert p["host"]=="bg" and not p.get("bg_id"), p' $R/stage-a/grill.json
check $? 0 "…and the launch stays recorded"
grill --stage stage-a --host bg > /dev/null 2>&1; check $? 2 "…so a second launch is refused, not started beside it"
HUB_TAG=hub-1 $B/hub grill done --stage stage-a --why "test" >/dev/null 2>&1
HUB_TAG=hub-1 $B/hub grill done --stage stage-a --why "test" >/dev/null 2>&1
FAKE_LOGS=none AGENT_HUB_GRILL_LINK_WAIT_S=0 grill --stage stage-a --host bg > $O/bg2.out 2>&1; check $? 0 "bg without a link yet: exit 0"
grep -q "claude attach bg-1234abcd" $O/bg2.out; check $? 0 "…and says how to reach it"
HUB_TAG=hub-1 $B/hub grill done --stage stage-a --why "test" >/dev/null 2>&1
FAKE_BG=untrusted FAKE_TRUSTED=/nowhere grill --stage stage-a --host bg > $O/bg3.out 2>&1; check $? 1 "bg in an untrusted folder: exit 1"
grep -q "not trusted" $O/bg3.out; check $? 0 "…and says what to do"
python3 -c 'import json,sys; assert "pending" not in json.load(open(sys.argv[1]))' $R/stage-a/grill.json 2>/dev/null || test ! -e $R/stage-a/grill.json
check $? 0 "…and records no pending launch"

exit $fail
