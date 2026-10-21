#!/bin/bash
# Autopilot: `hub succeed` (command construction, link capture, every fallback, the chain and its limit), the chain
# reset by a manual takeover and by an owner prompt, and the context budget hook's autopilot messages at warn and block.
# The CLI is tests/fake_claude_bg.py: no real `claude --bg` is ever started.
. "$(dirname "$0")/lib.sh"
unset PLUGIN_ROOT CLAUDE_PLUGIN_ROOT $(env | sed -n 's/^\(AGENT_HUB_\(CONTEXT\|AUTO\|SUCCESSOR\|STATE\)[A-Z_]*\)=.*/\1/p') FAKE_BG FAKE_LOGIN FAKE_LOGS FAKE_TRUSTED
export CLAUDE_BIN=$T/fake_claude_bg.py CLAUDE_SESSIONS_DIR=$(mktemp -d) AGENT_HUB_SUCCESSOR_TIMEOUT=2 AGENT_HUB_AUTO_HANDOFF=on
# the effort of the hub running `hub succeed` (the Bash tool's $CLAUDE_EFFORT): the successor's, unless something says otherwise
export CLAUDE_EFFORT=high
NO_PS=$(fake_ps /dev/null)  # a PATH directory whose ps shows no claude process: with CLAUDE_EFFORT unset nothing answers
BR_BIN=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$B")  # the plugin bin/ as the tools resolve it
HUB1=11111111-1111-4111-8111-111111111111; HUB2=22222222-2222-4222-8222-222222222222
HUB3=33333333-3333-4333-8333-333333333333

# a fresh hub home with stage-a, hub #1 registered, a handoff file and a work directory for the successor
setup(){
  new_home; R=$AGENT_HUB_HOME; export FAKE_BG_LOG=$R/bg.log
  $B/hub start --stage stage-a --session $HUB1 > $R/start.out 2>&1 || { echo "FAIL setup: hub start"; cat $R/start.out; fail=1; }
  H=$R/stage-a/coordinator/HANDOFF-hub-stage-a-2026-10-01-1200.md
  printf '# Handoff "Hub stage-a #1" → "Hub stage-a #2" — stage-a\n\n## 0. First steps\n1. take over\n' > $H
  H=$(cd "$(dirname $H)" && pwd -P)/$(basename $H)  # as `hub succeed` resolves it
  W=$R/work; mkdir -p $W
}
J(){ cat "$(journal stage-a)" 2>/dev/null; }
chain(){ python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("chain"))' $R/stage-a/auto-handoff.json 2>/dev/null || echo none; }
pending(){ python3 -c 'import json,sys; p=json.load(open(sys.argv[1])).get("pending") or {}; print(p.get(sys.argv[2]))' $R/stage-a/auto-handoff.json "$1" 2>/dev/null || echo none; }
# the n-th (1-based; -1 = last) call to the fake CLI whose first argument is $1 ("--bg", "logs", "stop", …): field $2
call(){ python3 - "$FAKE_BG_LOG" "$1" "$2" "${3:--1}" <<'PY'
import json, sys
log, first, field, idx = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
try:
    calls = [json.loads(l) for l in open(log) if l.strip()]
except FileNotFoundError:
    calls = []
calls = [c for c in calls if c["argv"] and c["argv"][0] == first]
if not calls:
    print("none"); sys.exit()
c = calls[idx if idx < 0 else idx - 1]
if field == "count":
    print(len(calls))
elif field == "argv":
    print(" ".join(a for a in c["argv"][:-1]))
elif field == "prompt":
    print(c["argv"][-1])
elif field == "cwd":
    print(c["cwd"])
else:
    print(c["env"].get(field))
PY
}
succeed(){ $B/hub succeed --stage stage-a --handoff $H --cwd $W "$@"; }

# Review H1/L4: replacement before takeover, legacy author and refusal before stop.
replace_r1(){
  setup; CLAUDE_CODE_SESSION_ID=$HUB1 succeed --model opus > $R/initial.out 2>&1
  FAKE_AGENTS=prev FAKE_PREV_SID=bg-1234abcd CLAUDE_CODE_SESSION_ID=$HUB1 $B/hub succeed --stage stage-a --cwd $W --replace --dry-run --model opus > $R/dryreplace.out 2>&1
  check "$?:$(call stop count):$(call --bg count):$(chain)" "0:none:1:1" "r1 replace: not-taken-over dry run leaves predecessor and chain intact"
  FAKE_AGENTS=prev FAKE_PREV_SID=bg-1234abcd CLAUDE_CODE_SESSION_ID=$HUB1 $B/hub succeed --stage stage-a --cwd $W --replace --model opus > $R/replace.out 2>&1
  check "$?:$(call stop count):$(call --bg count):$(chain):$(pending kind)" "0:1:2:1:bg" "r1 replace: running successor before takeover is stopped and replaced, chain unchanged"
  setup; CLAUDE_CODE_SESSION_ID=$HUB1 succeed --model opus > /dev/null 2>&1
  python3 - "$R/stage-a/roles.json" <<'PYROLE'
import json,sys
p=sys.argv[1];d=json.load(open(p));d['roles']['hub']['tag']='hub-9';json.dump(d,open(p,'w'))
PYROLE
  FAKE_AGENTS=prev FAKE_PREV_SID=bg-1234abcd CLAUDE_CODE_SESSION_ID=$HUB1 $B/hub succeed --stage stage-a --cwd $W --replace --model opus > $R/stale.out 2>&1
  check "$?:$(call stop count):$(call --bg count):$(chain):$(pending kind)" "1:none:1:1:bg" "r1 replace: invalid predecessor is refused before stopping the recorded successor"
  setup; CLAUDE_CODE_SESSION_ID=$HUB1 succeed --model opus > /dev/null 2>&1
  CLAUDE_CODE_SESSION_ID=$HUB2 $B/hub takeover --stage stage-a --session self --auto-handoff --handoff $H > /dev/null 2>&1
  python3 - "$R/stage-a/auto-handoff.json" <<'PYAUTHOR'
import json,sys
p=sys.argv[1];d=json.load(open(p));d['pending'].pop('author',None);json.dump(d,open(p,'w'))
PYAUTHOR
  FAKE_AGENTS=prev FAKE_PREV_SID=bg-1234abcd CLAUDE_CODE_SESSION_ID=$HUB1 $B/hub succeed --stage stage-a --cwd $W --replace --model opus > $R/legacy.out 2>&1
  check "$?:$(call stop count):$(call --bg count):$(chain)" "0:1:2:1" "r1 replace: a taken-over legacy record without author permits the predecessor caller"
}
replace_r1
[ "${AUTOPILOT_REPLACE_R1_ONLY:-0}" != 1 ] || exit $fail

# ================================================================== the background successor
setup
CLAUDECODE=1 CLAUDE_CODE_ENTRYPOINT=cli HUB_TAG=hub-1 succeed --model opus --permission-mode default > $R/s1.out 2>&1; rc=$?
check $rc 0 "succeed: exit 0"
call --bg argv | grep -q -- "^--bg --remote-control stage-a-hub-2 -n Hub stage-a #2 --add-dir $R --model opus --effort high --settings {"; check $? 0 "succeed: --bg command (name, title, the hub home granted — --cwd is inside it, not around it — model; no mode flag for default)"
call --bg argv | python3 -c 'import json,sys,os; a=sys.stdin.read().split(" --settings ",1)[1]; p=json.loads(a)["permissions"]; r=os.path.realpath(sys.argv[1]); assert "Bash(hub takeover:*)" in p["allow"] and "Bash("+os.path.realpath(sys.argv[2])+"/hub takeover:*)" in p["allow"] and "Bash(jwait:*)" in p["allow"] and "Bash(jlog:*)" in p["allow"]; assert sys.argv[1] in p["additionalDirectories"] and r in p["additionalDirectories"]; assert "Edit(/"+r+"/**)" in p["allow"]; assert not any("agent spawn" in x for x in p["allow"]); assert json.loads(a)["idleCompaction"] is False' "$R" "$BR_BIN"; check $? 0 "succeed: --settings allows the hub's commands and the hub home, not agent spawn, and turns idle compaction off"
check "$(call --bg cwd)" "$(cd $W && pwd -P)" "succeed: started in --cwd"
call --bg argv | grep -q -- "--worktree"; check $? 1 "succeed: outside git no --worktree"
call --bg prompt | grep -qF "/delamain:hub take over stage stage-a from $H: run \`$BR_BIN/hub takeover --stage stage-a --session self --auto-handoff --handoff $H\`"; check $? 0 "succeed: prompt = hub skill + exact takeover command (no shell expansion)"
check "$(call --bg AGENT_HUB_HOME)" "$R" "succeed: the hub home reaches the successor through its environment"
call --bg prompt | grep -qF "[agent-hub auto-handoff 1/10]"; check $? 0 "succeed: prompt carries the marker 1/10, written under the former name for one release (older hooks read only it)"  # rename:keep
call --bg prompt | grep -qF "[delamain auto-handoff"; check $? 1 "rename: the prompt written now does not carry the new form of the marker yet"
call --bg prompt | python3 -c 'import re,sys; sys.exit(0 if re.search(r"\[agent-hub auto-handoff (\d+)/(\d+)\]", sys.stdin.read()) else 1)'; check $? 0 "rename: the written marker matches the pattern an older hub's hook uses (so the chain survives there)"  # rename:keep
call --bg prompt | grep -qF "/delamain:hub take over stage"; check $? 0 "rename: the successor's slash command is the new name (the successor is a new session)"
check "$(call --bg CLAUDECODE):$(call --bg CLAUDE_CODE_ENTRYPOINT):$(call --bg HUB_TAG)" "None:None:None" "succeed: parent session identity and hub tag stripped from the child env"
check "$(call auth count)" 1 "succeed: login checked first (claude auth status)"
J | grep -q '\[hub-1\] auto-handoff 1/10: started "Hub stage-a #2" (opus, default) as background session bg-1234abcd — Remote Control https://claude.ai/code/session_01AbC-xyz; terminal: claude attach bg-1234abcd'; check $? 0 "succeed: journal line with bg id, Remote Control link (ANSI stripped) and attach command"
check "$(chain):$(pending kind):$(pending id)" "1:bg:bg-1234abcd" "succeed: chain 1, pending bg successor recorded"
grep -qF "$BR_BIN/jwait --journal --stage stage-a" $R/s1.out && grep -q "jwait --journal --stage stage-a --match '\\\\\[hub-2\\\\\] start:' --since [0-9:]* --settle 1 --for 2s" $R/s1.out; check $? 0 "succeed: prints the exact jwait command"
grep -qF "ALARM (exit 3) → $BR_BIN/hub succeed --stage stage-a --fallback" $R/s1.out; check $? 0 "succeed: says what to do on ALARM"
grep -q 'tell the owner one line: "Hub stage-a #2" took over — https://claude.ai/code/session_01AbC-xyz; it is a background Remote Control session named "stage-a-hub-2": in Claude Desktop it is listed under the repository.s address group (for a repository not hosted on github.com that is a separate group from the folder group), on the phone in the Remote Control list' $R/s1.out; check $? 0 "succeed: the owner line says where the successor is (background Remote Control session, Desktop group, phone list)"
succeed --model opus > $R/s1b.out 2>&1; check $? 1 "succeed: refused while the started successor has not taken over"
check "$(call --bg count)" 1 "…no second background session"
# the successor takes over: its jwait wakes, the chain is kept
CLAUDE_CODE_SESSION_ID=$HUB2 $B/hub takeover --stage stage-a --session self --auto-handoff --handoff $H > $R/take2.out 2>&1; check $? 0 "takeover by the successor (--session self)"
check "$($B/roles --stage stage-a get hub)" $HUB2 "--session self registers \$CLAUDE_CODE_SESSION_ID"
JW=$(sed -n 's/^  \(.*jwait .*\)$/\1/p' $R/s1.out)
case "$JW" in "$BR_BIN/jwait "*) check 0 0 "the printed jwait is the plugin's own, by absolute path";; *) check "$JW" "$BR_BIN/jwait …" "the printed jwait is the plugin's own, by absolute path";; esac
eval "$JW" > $R/jw.out 2>&1; check $? 0 "the printed jwait delivers the successor's start line"
grep -q '\[hub-2\] start:' $R/jw.out; check $? 0 "…and it is the start line"
check "$(chain)" 1 "chain kept by the pending successor's takeover"
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["pending"]["taken_over"]' $R/stage-a/auto-handoff.json; check $? 0 "…pending marked taken over"
$B/hub takeover --stage stage-a --session $HUB2 --auto-handoff --handoff $H > /dev/null 2>&1; check "$(chain)" 1 "a re-run of that takeover keeps the chain"
# only the registered hub hands over
CLAUDE_CODE_SESSION_ID=$HUB1 succeed --model opus > $R/stale.out 2>&1; check "$?:$(grep -c 'is not the hub of stage stage-a' $R/stale.out)" 2:1 "succeed: a stale hub (session) is refused"
HUB_TAG=hub-1 succeed --model opus > $R/stale.out 2>&1; check "$?:$(grep -c 'HUB_TAG hub-1 is not the hub of stage stage-a' $R/stale.out)" 2:1 "succeed: a stale hub (HUB_TAG) is refused"
HUB_TAG=hub-1 $B/hub succeed --stage stage-a --fallback > $R/stale.out 2>&1; check "$?:$(grep -c 'is not the hub of stage stage-a' $R/stale.out)" 2:1 "fallback: a stale hub is refused"
# hub #2 hands over in turn: the marker counts on
CLAUDE_CODE_SESSION_ID=$HUB2 succeed --model opus > $R/s2.out 2>&1; check $? 0 "second succeed (by the registered hub's session)"
call --bg argv | grep -q -- "--remote-control stage-a-hub-3 -n Hub stage-a #3"; check $? 0 "…successor #3"
call --bg prompt | grep -qF "[agent-hub auto-handoff 2/10]"; check $? 0 "…marker 2/10"  # rename:keep
check "$(chain)" 2 "…chain 2"
$B/hub takeover --stage stage-a --session self --dry-run > /dev/null 2>&1; check $? 2 "--session self without \$CLAUDE_CODE_SESSION_ID: usage error"
# a takeover by hand resets the chain — even with the pending successor's own number (hub-3)
$B/hub takeover --stage stage-a --session $HUB3 --handoff $H > /dev/null 2>&1
check "$($B/roles --stage stage-a get hub | head -c 36)" $HUB3 "a takeover by hand gets the natural number"
check "$(chain):$(pending n)" "0:None" "a takeover by hand resets the chain and drops the pending successor"
J | grep -q "\[hub-3\] auto-handoff chain reset (2 → 0): a takeover by hand"; check $? 0 "…and journals it"
# one successor per shift: a reservation by a running (or retried) `hub succeed` blocks; a stale one does not
setup
python3 -c 'import json,sys,datetime as d; json.dump({"chain":0,"pending":{"n":2,"kind":"starting","at":d.datetime.now().astimezone().isoformat(timespec="seconds")}},open(sys.argv[1],"w"))' $R/stage-a/auto-handoff.json
succeed --model opus > $R/res.out 2>&1; check "$?:$(call --bg count)" "1:none" "reservation: a second hub succeed while one is starting is refused"
$B/hub succeed --stage stage-a --fallback > $R/fbs.out 2>&1; check "$?:$(grep -c 'being started right now' $R/fbs.out)" "1:1" "reservation: --fallback while starting waits"
python3 -c 'import json,sys; json.dump({"chain":0,"pending":{"n":2,"kind":"starting","at":"2020-01-01T00:00:00+00:00"}},open(sys.argv[1],"w"))' $R/stage-a/auto-handoff.json
succeed --model opus > /dev/null 2>&1; check "$?:$(call --bg count):$(chain)" "0:1:1" "reservation: a stale one (a dead hub succeed) does not block"
python3 -c 'import json,sys; json.dump({"chain":0,"pending":{"n":5,"kind":"bg","id":"x","at":"2020-01-01T00:00:00+00:00"}},open(sys.argv[1],"w"))' $R/stage-a/auto-handoff.json
$B/hub succeed --stage stage-a --fallback > $R/fbn.out 2>&1; check "$?:$(call stop count)" "1:none" "fallback: another shift's successor is not touched"
# nothing starts at all: the reservation and its count are given back, the journal says BLOCKED
setup
FAKE_LOGIN=no FAKE_CLAUDE=die succeed --model opus > $R/none.out 2>&1; check $? 1 "no successor at all: exit 1"
check "$(chain):$(pending n)" "0:None" "no successor at all: count given back, no pending record"
J | grep -q "BLOCKED auto-handoff: no successor started (the headless successor did not start either"; check $? 0 "no successor at all: journal says BLOCKED and why"

# ================================================================== chain limit
setup; export AGENT_HUB_AUTO_HANDOFF_CHAIN=1
succeed --model opus > /dev/null 2>&1
$B/hub takeover --stage stage-a --session $HUB2 --auto-handoff --handoff $H > /dev/null 2>&1
succeed --model opus > $R/lim.out 2>&1; rc=$?
check $rc 3 "chain limit: exit 3"
check "$(call --bg count)" 1 "chain limit: no successor started"
J | grep -q '\[hub-2\] auto-handoff chain limit 1 reached — waiting for the owner'; check $? 0 "chain limit: journaled"
grep -q "Tell the owner" $R/lim.out; check $? 0 "chain limit: tells the hub to stop and wait"
AGENT_HUB_AUTO_HANDOFF_CHAIN=0 succeed --model opus > /dev/null 2>&1; check $? 3 "chain 0: never an automatic successor"
unset AGENT_HUB_AUTO_HANDOFF_CHAIN

# ================================================================== model and permission mode
setup
mkdir -p $HOME/.claude/projects/p
echo '{"type":"assistant","message":{"model":"claude-fable-5-1","usage":{"input_tokens":5}}}' > $HOME/.claude/projects/p/$HUB1.jsonl
echo '{"type":"assistant","isSidechain":true,"message":{"model":"claude-haiku-4-5","usage":{"input_tokens":5}}}' >> $HOME/.claude/projects/p/$HUB1.jsonl
CLAUDE_CODE_SESSION_ID=$HUB1 succeed > /dev/null 2>&1
call --bg argv | grep -q -- "--model claude-fable-5-1 --effort high --settings"; check $? 0 "model: inherited from the hub's transcript (sidechain skipped)"
setup
echo '{"AGENT_HUB_SUCCESSOR_MODEL": "sonnet", "AGENT_HUB_SUCCESSOR_PERMISSION_MODE": "acceptEdits"}' > $R/config.json
CLAUDE_CODE_SESSION_ID=$HUB1 succeed > /dev/null 2>&1
call --bg argv | grep -q -- "--model sonnet --effort high --permission-mode acceptEdits --settings"; check $? 0 "model and mode: hub home settings win over inheritance"
rm $R/config.json
setup
mkdir -p $W/.agent-hub; echo '{"AGENT_HUB_SUCCESSOR_PERMISSION_MODE": "bypassPermissions"}' > $W/.agent-hub/config.json; mkdir -p $W/.git
(cd $W && succeed --model opus) > $R/proj.out 2>&1
check "$(call --bg count)" 1 "mode: started with a repository's config.json present"
call --bg argv | grep -q -- "--permission-mode"; check $? 1 "mode: a repository's config.json cannot set the successor's mode"
rm -rf $W/.agent-hub $W/.git
setup
succeed --model 'opus; rm -rf /' > $R/bad.out 2>&1; check "$?:$(grep -c "^error: --model 'opus; rm -rf /'" $R/bad.out)" 2:1 "model: a value with shell syntax is refused"
succeed --model opus --permission-mode yolo > $R/bad.out 2>&1; check "$?:$(grep -c "^error: permission mode 'yolo'" $R/bad.out)" 2:1 "mode: an unknown mode is refused"
check "$(call --bg count)" none "…neither started anything"
succeed --model opus --permission-mode plan > /dev/null 2>&1
check "$(call --bg count)" 1 "mode: plan — started"
call --bg argv | grep -q -- "--permission-mode"; check $? 1 "mode: plan starts the successor in the default mode"
J | grep -q "the hub was in plan mode; the successor starts in the default mode"; check $? 0 "…and the journal says so"
setup
succeed --model opus --dry-run > $R/dry.out 2>&1; check $? 0 "dry run: exit 0"
grep -q "^\[plan\] auto-handoff 1/10: start \"Hub stage-a #2\"" $R/dry.out; check $? 0 "dry run: prints the plan"
check "$(call --bg count):$(chain)" "none:none" "dry run: nothing started, no state"

# ================================================================== fallbacks
# bypass without the accepted disclaimer -> auto (acceptEdits for haiku)
setup; export FAKE_BG=bypass
succeed --model opus --permission-mode bypassPermissions > /dev/null 2>&1; check $? 0 "bypass: exit 0"
check "$(call --bg count)" 2 "bypass: retried once"
call --bg argv 1 | grep -q -- '--permission-mode bypassPermissions --settings {"idleCompaction":false}$'; check $? 0 "bypass: the first try has no allow list (moot in bypass), only idle compaction off"
call --bg argv | grep -q -- "--permission-mode auto --settings"; check $? 0 "bypass: retried in auto for opus"
J | grep -q "(opus, auto) as background session.*bypassPermissions needs its disclaimer accepted once"; check $? 0 "bypass: journal names the mode used and why"
setup
succeed --model haiku --permission-mode bypassPermissions > /dev/null 2>&1
call --bg argv | grep -q -- "--permission-mode acceptEdits --settings"; check $? 0 "bypass: acceptEdits for haiku"
unset FAKE_BG
# the hub in a worktree, the root trusted: started from the root at once (the worktree's trust does not matter)
setup; export FAKE_BG=untrusted
mkrepo(){ M=$R/main; mkdir -p $M; git -C $M init -q; git -C $M -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C $M worktree add -q $R/wt -b wt 2>/dev/null; MR=$(cd $M && pwd -P); }
mkrepo
FAKE_TRUSTED=$M $B/hub succeed --stage stage-a --handoff $H --cwd $R/wt --model opus > /dev/null 2>&1; check $? 0 "trusted root: exit 0"
check "$(call --bg count):$(call --bg cwd):$(pending kind)" "1:$MR:bg" "trusted root: started from the main checkout at once"
# an untrusted root -> headless hub, and the journal says why
setup; mkrepo
$B/hub succeed --stage stage-a --handoff $H --cwd $R/wt --model opus > $R/hl.out 2>&1; check $? 0 "untrusted root: exit 0 (headless fallback)"
check "$(call --bg count):$(pending kind):$(pending role)" "1:headless:hub-2" "untrusted root: one --bg, then the headless successor recorded"
J | grep -q "background successor not started — $MR is not trusted by the claude CLI — run \`claude\` there once and accept the trust prompt.*falling back to a headless hub"; check $? 0 "untrusted root: journal names the root, the fix and the fallback"
check "$($B/roles --stage stage-a get hub-2 2>/dev/null | head -c 36 | wc -c | tr -d ' ')" 36 "untrusted root: agent spawn registered hub-2"
BR=$R/stage-a/coordinator/work/hub-2-takeover-brief.md
grep -qF "$BR_BIN/hub takeover --stage stage-a --session self --auto-handoff --handoff $H" $BR && grep -qF "[agent-hub auto-handoff 1/10]" $BR; check $? 0 "headless: brief has the takeover command and the marker"  # rename:keep
grep -q "agent send hub-2" $R/hl.out; check $? 0 "headless: tells how the owner reaches it"
check "$(chain)" 1 "headless: counts in the chain"
unset FAKE_BG
# not logged in -> no --bg at all
setup; FAKE_LOGIN=no succeed --model opus > /dev/null 2>&1; check $? 0 "not logged in: exit 0"
check "$(call --bg count):$(pending kind)" "none:headless" "not logged in: falls back before any --bg"
J | grep -q "the claude CLI is not logged in.*claude auth login"; check $? 0 "not logged in: journaled with the fix"
# the session itself says "Not logged in" -> stopped, removed, headless
setup; FAKE_LOGS=notloggedin succeed --model opus > /dev/null 2>&1
check "$(call stop count):$(call rm count):$(pending kind)" "1:1:headless" "logs say not logged in: bg session stopped and removed, headless started"
# no link in the logs by the deadline -> still the bg successor, the journal says where to look
setup; FAKE_LOGS=none succeed --model opus > /dev/null 2>&1
J | grep -q "Remote Control link not shown yet (\`claude logs bg-1234abcd\`)"; check $? 0 "no link: journal points at claude logs"
check "$(pending kind)" bg "no link: still the background successor"
# no id printed -> taken from `claude agents --json`
setup; FAKE_BG=noid succeed --model opus > /dev/null 2>&1
check "$(pending id)" bg-from-list "no id printed: id read from claude agents --json (the newest of that name)"
# an AGENT_HUB_MODEL_MAP alias reaches claude --bg as the id it names
setup; AGENT_HUB_MODEL_MAP=fast=claude-sonnet-9-9 succeed --model fast > /dev/null 2>&1
call --bg argv | grep -q -- "--model claude-sonnet-9-9 "; check $? 0 "model map: claude --bg gets the mapped id"
# --headless right away
setup; succeed --model opus --headless > /dev/null 2>&1
check "$(call --bg count):$(pending kind)" "none:headless" "--headless: agent spawn without trying --bg"
# a refusing reason policy must not stop the chain: the successor keeps the hub's effort (high), above this default
setup; AGENT_HUB_REASON_POLICY=refuse AGENT_HUB_EFFORT_DEFAULTS='{"opus": "low"}' succeed --model opus --headless > $R/rsn.out 2>&1
check "$(pending kind)" headless "reason policy refuse: the headless successor still starts"
grep -q 'hub successor' $R/stage-a/agents/hub-2/meta.json; check $? 0 "…with a reason in its meta.json"
# AGENT_HUB_SPAWN_MCP is for executors: a headless hub successor keeps the MCP servers its predecessor had
setup; AGENT_HUB_SPAWN_MCP=none succeed --model opus --headless > /dev/null 2>&1
grep -q '"mcp": "inherit"' $R/stage-a/agents/hub-2/meta.json; check $? 0 "AGENT_HUB_SPAWN_MCP=none: the headless successor still inherits MCP servers"
# no takeover by the deadline -> --fallback: log tail journaled, bg stopped (kept), headless from the same handoff
setup; succeed --model opus > /dev/null 2>&1
$B/hub succeed --stage stage-a --fallback > $R/fb.out 2>&1; check $? 0 "fallback: exit 0"
check "$(call stop count):$(call rm count)" "1:none" "fallback: bg session stopped, not removed"
J | grep -q "auto-handoff: background session bg-1234abcd wrote no takeover line in 2 s; stopped it.*claude logs tail: /remote-control is active"; check $? 0 "fallback: journal has the reason and the log tail"
check "$(pending kind):$(pending bg_id):$(chain)" "headless:bg-1234abcd:1" "fallback: headless successor, chain not counted twice"
$B/hub succeed --stage stage-a --fallback > /dev/null 2>&1; check $? 1 "fallback after the headless one: nothing further"
J | grep -q "the headless successor hub-2 did not take over either — waiting for the owner"; check $? 0 "…journaled"

# ================================================================== the successor's effort
# --effort beats AGENT_HUB_SUCCESSOR_EFFORT (env or the hub home's config.json), which beats the hub's own effort
# ($CLAUDE_EFFORT, high above); when that cannot be read there is no default: a refusal
meta_effort(){ python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("effort"))' $R/stage-a/agents/hub-2/meta.json 2>/dev/null || echo none; }
setup; AGENT_HUB_SUCCESSOR_EFFORT=low succeed --model opus --effort max > /dev/null 2>&1
call --bg argv | grep -q -- "--model opus --effort max --settings"; check "$? $(pending effort)" "0 max" "effort: --effort beats the environment"
setup; AGENT_HUB_SUCCESSOR_EFFORT=xhigh succeed --model opus > /dev/null 2>&1
call --bg argv | grep -q -- "--model opus --effort xhigh --settings"; check "$? $(pending effort)" "0 xhigh" "effort: the environment beats the hub's own"
setup; echo '{"AGENT_HUB_SUCCESSOR_EFFORT": "medium"}' > $R/config.json; succeed --model opus > /dev/null 2>&1
call --bg argv | grep -q -- "--model opus --effort medium --settings"; check $? 0 "effort: the hub home's config.json sets it"
setup; succeed --model haiku > /dev/null 2>&1
call --bg argv | grep -q -- "--model haiku --effort high --settings"; check "$? $(pending effort)" "0 high" "effort: Haiku gets an effort like any model — the hub's own"
setup; succeed --model haiku --effort medium > /dev/null 2>&1
call --bg argv | grep -q -- "--model haiku --effort medium --settings"; check "$? $(pending effort)" "0 medium" "effort: …--effort beats it for Haiku too"
setup; AGENT_HUB_SUCCESSOR_EFFORT=xhigh succeed --model haiku > /dev/null 2>&1
call --bg argv | grep -q -- "--model haiku --effort xhigh --settings"; check "$? $(pending effort)" "0 xhigh" "effort: …and so does AGENT_HUB_SUCCESSOR_EFFORT"
setup; succeed --model haiku --headless > /dev/null 2>&1; check "$(meta_effort):$(pending effort)" "high:high" "effort: a headless Haiku hub (agent spawn) gets it as well"
setup; succeed --model opus --effort bogus > $R/bad.out 2>&1; check "$?:$(call --bg count)" "2:none" "effort: an unknown --effort is refused, nothing started"
setup; AGENT_HUB_SUCCESSOR_EFFORT=bogus succeed --model opus > $R/bad.out 2>&1; check "$?:$(grep -c "AGENT_HUB_SUCCESSOR_EFFORT 'bogus'" $R/bad.out):$(call --bg count)" "2:1:none" "effort: an unknown AGENT_HUB_SUCCESSOR_EFFORT is refused, nothing started"
setup; succeed --model opus --effort xhigh --dry-run > $R/dry.out 2>&1; grep -qF -- "--model opus --effort xhigh --settings" $R/dry.out; check "$?:$(call --bg count)" "0:none" "effort: the dry run shows it"
setup; AGENT_HUB_SUCCESSOR_EFFORT=max succeed --model opus --headless > /dev/null 2>&1; check "$(meta_effort):$(pending effort)" "max:max" "effort: the headless hub (agent spawn) gets it"
setup; succeed --model opus --effort xhigh > /dev/null 2>&1
$B/hub succeed --stage stage-a --fallback > /dev/null 2>&1; check "$(meta_effort):$(pending effort)" "xhigh:xhigh" "effort: --fallback's headless hub keeps the effort of the background one"

# --fallback of a record without an effort (state from before the upgrade) with a bad setting: refused before the
# reservation, so the retry is not blocked
setup; succeed --model opus > /dev/null 2>&1
python3 - $R/stage-a/auto-handoff.json <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["pending"].pop("effort"); json.dump(d, open(sys.argv[1], "w"))
PY
AGENT_HUB_SUCCESSOR_EFFORT=bogus $B/hub succeed --stage stage-a --fallback > $R/fbb.out 2>&1
check "$?:$(grep -c "AGENT_HUB_SUCCESSOR_EFFORT 'bogus'" $R/fbb.out):$(pending kind):$(call stop count)" "2:1:bg:none" "effort: --fallback with a bad setting is refused before the reservation"
CLAUDE_EFFORT=max $B/hub succeed --stage stage-a --fallback > /dev/null 2>&1
check "$?:$(pending kind):$(pending effort)" "0:headless:max" "effort: …and the retry is not blocked (an old record gets the hub's own effort)"

# the hub's own effort is inherited, and said so; with no way to read it nothing starts (no silent default)
setup; CLAUDE_EFFORT=xhigh succeed --model opus > $R/inh.out 2>&1
call --bg argv | grep -q -- "--model opus --effort xhigh --settings"; check "$? $(pending effort)" "0 xhigh" "effort: inherited from the hub's own session"
J | grep -qF 'effort xhigh inherited from this hub (source: env — $CLAUDE_EFFORT)'; check $? 0 "effort: …and the journal line says where it came from"
setup; CLAUDE_EFFORT=max succeed --model opus --dry-run > $R/inhd.out 2>&1
grep -qF -- "--model opus --effort max --settings" $R/inhd.out && grep -qF '[plan] effort max inherited from this hub (source: env' $R/inhd.out; check "$?:$(call --bg count)" "0:none" "effort: the dry run shows the inherited effort and its source"
setup; CLAUDE_EFFORT=xhigh succeed --model opus --headless > /dev/null 2>&1; check "$(meta_effort):$(pending effort)" "xhigh:xhigh" "effort: the headless hub gets the inherited effort"
setup; env -u CLAUDE_EFFORT PATH=$NO_PS:$PATH $B/hub succeed --stage stage-a --handoff $H --cwd $W --model opus > $R/ref.out 2>&1; rc=$?
check "$rc:$(call --bg count):$(chain):$(pending n)" "1:none:none:none" "effort: unreadable → exit 1, nothing started, the chain not counted, no reservation"
grep -q '^FAILED: cannot determine the effort of this session; tried hook: .*env: \$CLAUDE_EFFORT is not set; transcript: .*job: .*desktop: .*argv: .*No successor is started on a guessed effort: pass --effort' $R/ref.out; check $? 0 "effort: …the refusal names every source tried and what to do"
env -u CLAUDE_EFFORT PATH=$NO_PS:$PATH $B/hub succeed --stage stage-a --handoff $H --cwd $W --model opus --headless > /dev/null 2>&1; check "$?:$(call --bg count):$(pending n)" "1:none:none" "effort: …also for --headless"
env -u CLAUDE_EFFORT PATH=$NO_PS:$PATH $B/hub succeed --stage stage-a --handoff $H --cwd $W --model opus --dry-run > /dev/null 2>&1; check $? 1 "effort: …and for a dry run (it would refuse the real one)"
env -u CLAUDE_EFFORT PATH=$NO_PS:$PATH $B/hub succeed --stage stage-a --handoff $H --cwd $W --model opus --effort low > /dev/null 2>&1
call --bg argv | grep -q -- "--model opus --effort low --settings"; check $? 0 "effort: …but --effort given needs no reading"
setup; env -u CLAUDE_EFFORT PATH=$NO_PS:$PATH AGENT_HUB_SUCCESSOR_EFFORT=medium $B/hub succeed --stage stage-a --handoff $H --cwd $W --model opus > /dev/null 2>&1
call --bg argv | grep -q -- "--model opus --effort medium --settings"; check $? 0 "effort: …and so does AGENT_HUB_SUCCESSOR_EFFORT"
setup; env -u CLAUDE_EFFORT PATH=$NO_PS:$PATH $B/hub succeed --stage stage-a --handoff $H --cwd $W --model haiku > $R/hkref.out 2>&1; rc=$?
check "$rc:$(call --bg count):$(grep -c 'cannot determine the effort of this session' $R/hkref.out)" "1:none:1" "effort: negative — an unreadable effort refuses a Haiku successor like any other, nothing starts"
# a hub on Haiku 4.5 has no effort: the $CLAUDE_EFFORT its Bash shows is an ancestor's leftover (probed), not inherited
TRH=$HOME/.claude/projects/p/$HUB1.jsonl; mkdir -p $(dirname $TRH); [ -f $TRH ] && cp $TRH $TRH.keep
echo '{"type":"assistant","message":{"model":"claude-haiku-4-5-20251001","usage":{"input_tokens":5}}}' > $TRH
setup; CLAUDE_CODE_SESSION_ID=$HUB1 CLAUDE_EFFORT=xhigh succeed --model opus > $R/hk.out 2>&1
check "$?:$(call --bg count):$(grep -c 'which recorded no effort' $R/hk.out)" "1:none:1" "effort: a Haiku 4.5 hub handing over to Opus — its inherited \$CLAUDE_EFFORT is not used, nothing starts"
setup; CLAUDE_CODE_SESSION_ID=$HUB1 CLAUDE_EFFORT=xhigh succeed --model opus --effort high > /dev/null 2>&1
call --bg argv | grep -q -- "--model opus --effort high --settings"; check $? 0 "effort: …unless --effort says it"
setup; CLAUDE_CODE_SESSION_ID=$HUB1 CLAUDE_EFFORT=xhigh succeed > $R/hk2.out 2>&1
check "$?:$(call --bg count):$(grep -c 'which recorded no effort' $R/hk2.out)" "1:none:1" "effort: …and so is a Haiku successor of a Haiku 4.5 hub (the hub's effort is unreadable)"
setup; CLAUDE_CODE_SESSION_ID=$HUB1 CLAUDE_EFFORT=xhigh succeed --effort medium > /dev/null 2>&1
call --bg argv | grep -q -- "--model claude-haiku-4-5-20251001 --effort medium --settings"; check $? 0 "effort: …unless --effort says it: a Haiku successor of a Haiku hub is started with it"
# a Haiku 5.5 hub has the setting: its record carries the effort and its $CLAUDE_EFFORT is the turn's (probed, CLI 2.1.296)
echo '{"type":"assistant","message":{"model":"claude-haiku-5-5","usage":{"input_tokens":5}},"effort":"medium","perTurnEffort":"medium"}' > $TRH
setup; CLAUDE_CODE_SESSION_ID=$HUB1 CLAUDE_EFFORT=xhigh succeed --model opus > /dev/null 2>&1
call --bg argv | grep -q -- "--model opus --effort xhigh --settings"; check "$? $(pending effort)" "0 xhigh" "effort: positive control — a Haiku 5.5 hub's \$CLAUDE_EFFORT is inherited (a Haiku 4.5 hub's is not)"
setup; env -u CLAUDE_EFFORT CLAUDE_CODE_SESSION_ID=$HUB1 PATH=$NO_PS:$PATH $B/hub succeed --stage stage-a --handoff $H --cwd $W --model opus > /dev/null 2>&1
call --bg argv | grep -q -- "--model opus --effort medium --settings"; check "$? $(pending effort)" "0 medium" "effort: …and so is the effort in its transcript"
setup; CLAUDE_CODE_SESSION_ID=$HUB1 CLAUDE_EFFORT=xhigh succeed > /dev/null 2>&1
call --bg argv | grep -q -- "--model claude-haiku-5-5 --effort xhigh --settings"; check "$? $(pending effort)" "0 xhigh" "effort: …a Haiku 5.5 successor of a Haiku 5.5 hub starts with the effort too"
rm -f $TRH; [ -f $TRH.keep ] && mv $TRH.keep $TRH
# a hub that is a `claude --bg` session: its environment is the daemon's, so the job's respawnFlags answer, not $CLAUDE_EFFORT
JD=$HOME/.claude/jobs/${HUB1:0:8}; mkdir -p $JD
python3 -c 'import json,sys; json.dump({"sessionId": sys.argv[2], "respawnFlags": ["--effort", "medium", "--model", "opus"]}, open(sys.argv[1] + "/state.json", "w"))' $JD $HUB1
setup; CLAUDE_CODE_SESSION_ID=$HUB1 CLAUDE_EFFORT=high succeed --model opus > /dev/null 2>&1
call --bg argv | grep -q -- "--model opus --effort medium --settings"; check "$? $(pending effort)" "0 medium" "effort: a --bg hub — the job's effort, not the daemon's \$CLAUDE_EFFORT"
rm -rf $JD
setup; CLAUDE_EFFORT=bogus env PATH=$NO_PS:$PATH $B/hub succeed --stage stage-a --handoff $H --cwd $W --model opus > $R/bogus.out 2>&1
check "$?:$(grep -c 'is not one of low, medium, high, xhigh, max' $R/bogus.out):$(call --bg count)" "1:1:none" "effort: a \$CLAUDE_EFFORT that is not an effort level is no answer"
setup; succeed --model opus > /dev/null 2>&1
python3 - $R/stage-a/auto-handoff.json <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["pending"].pop("effort"); json.dump(d, open(sys.argv[1], "w"))
PY
env -u CLAUDE_EFFORT PATH=$NO_PS:$PATH $B/hub succeed --stage stage-a --fallback > $R/fbr.out 2>&1
check "$?:$(pending kind):$(call stop count)" "1:bg:none" "effort: --fallback of an old record with nothing readable is refused before the reservation"

# ================================================================== review round 2
setst(){ python3 - $R/stage-a/auto-handoff.json "$@" <<'PY'
import json, sys, datetime as d
path, chain, kind, age = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4])
extra = dict(a.split("=", 1) for a in sys.argv[5:])
at = (d.datetime.now().astimezone() - d.timedelta(seconds=age)).isoformat(timespec="seconds")
pend = None if kind == "none" else dict({"n": 2, "kind": kind, "at": at, "handoff": "/x/h.md", "model": "opus", "k": 1}, **extra)
json.dump({"chain": chain, "pending": pend}, open(path, "w"))
PY
}
# (3) autopilot off: hub succeed refuses unless --force
setup
AGENT_HUB_AUTO_HANDOFF=off succeed --model opus > $R/off.out 2>&1; check "$?:$(grep -c 'autopilot is off' $R/off.out):$(call --bg count)" "2:1:none" "r2(3): autopilot off — hub succeed refused, nothing started"
AGENT_HUB_AUTO_HANDOFF=off succeed --model opus --force > /dev/null 2>&1; check "$?:$(call --bg count)" "0:1" "r2(3): --force (the owner by hand) starts it"
# (4) a reservation blocks only for the start budget, and the refusal says when to retry, with a ready jwait
setup; setst 1 starting 60
succeed --model opus > $R/r4.out 2>&1; check "$?:$(grep -c 'holds the shift until about' $R/r4.out):$(grep -c "jwait --journal --stage stage-a --match .* --for [0-9]*s" $R/r4.out)" "1:1:1" "r2(4): a fresh reservation refuses with the retry time and a ready jwait"
setst 1 starting 300
succeed --model opus > /dev/null 2>&1; check "$?:$(call --bg count)" "0:1" "r2(4): a reservation older than the start budget (300 s) does not block"
setup; setst 1 bg 10 id=bg-x
succeed --model opus > $R/r4b.out 2>&1; check "$?:$(grep -c "wait for its takeover (Bash run_in_background: true): .*jwait --journal --stage stage-a --match .* --for [0-9]*s" $R/r4b.out)" "1:1" "r2(4): a started successor's refusal says how to wait for it"
# (1) --fallback reserves under the lock: a second run while one runs is refused
setup; setst 1 falling-back 20 id=bg-1234abcd
$B/hub succeed --stage stage-a --fallback > $R/r1.out 2>&1; check "$?:$(grep -c 'being started right now' $R/r1.out):$(call stop count)" "1:1:none" "r2(1): --fallback while another --fallback runs is refused, nothing stopped"
# (1) an earlier --fallback started the headless hub and was killed before recording it: the retry finds it running
setup
FAKE_HOLD=40 succeed --model opus --headless > /dev/null 2>&1
setst 1 bg 700 id=bg-1234abcd cwd=$W
FAKE_HOLD=40 $B/hub succeed --stage stage-a --fallback > $R/r1b.out 2>&1; rc=$?
check "$rc:$(pending kind):$(chain)" "0:headless:1" "r2(1): agent spawn's 'already running' = the successor is there, not a failure"
J | grep -q "BLOCKED"; check $? 1 "r2(1): …no BLOCKED line"
grep -q "already running (started by an earlier run)" $R/r1b.out; check $? 0 "r2(1): …and it says so"
$B/agent stop hub-2 --stage stage-a > /dev/null 2>&1
# (2) --again drops the record of a successor that is not running; a running one is refused
setup; setst 1 headless 700 role=hub-2
succeed --model opus --again > $R/r2.out 2>&1; check "$?:$(pending kind):$(chain)" "0:bg:1" "r2(2): --again — a dead headless successor's record dropped, a new one started, counted once"
J | grep -q "dropped hub-2 (headless hub-2): it did not take over and is not running"; check $? 0 "r2(2): …journaled"
setup; setst 1 bg 700 id=bg-from-list
succeed --model opus --again > $R/r2b.out 2>&1; check "$?:$(grep -c 'is still running' $R/r2b.out):$(call --bg count)" "1:1:none" "r2(2): --again refuses while the bg successor still runs"
setup; setst 1 bg 700 id=bg-gone
FAKE_AGENTS=stale succeed --model opus --again > /dev/null 2>&1; check "$?:$(call --bg count)" "0:1" "r2(2): --again with the bg session gone starts a new one"
# --again reuses the previous attempt's effort unless a new --effort is given
setup; setst 1 headless 700 role=hub-2 effort=max
succeed --model opus --again > /dev/null 2>&1; call --bg argv | grep -q -- "--model opus --effort max --settings"; check "$? $(pending effort)" "0 max" "effort: --again reuses the recorded effort"
setup; setst 1 headless 700 role=hub-2 effort=max
succeed --model opus --again --effort low > /dev/null 2>&1; call --bg argv | grep -q -- "--model opus --effort low --settings"; check "$? $(pending effort)" "0 low" "effort: --again with --effort uses the new one"
# (6) `claude --bg` hangs past its timeout: only a session started since this start counts; a late one is stopped
bgrun(){ python3 - "$B" "$H" "$W" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import autopilot
autopilot.BG_TIMEOUT_S = 1
sys.exit(autopilot.succeed("stage-a", 1, Path(sys.argv[2]), "opus", "default", Path(sys.argv[3])))
PY
}
setup; FAKE_BG=hang FAKE_HANG=3 FAKE_AGENTS=late bgrun > /dev/null 2>&1
check "$(pending kind):$(pending id)" "bg:bg-from-list" "r2(6): hung --bg — the session started since is taken"
setup; FAKE_BG=hang FAKE_HANG=3 FAKE_AGENTS=stale bgrun > /dev/null 2>&1
check "$(pending kind):$(call stop count)" "headless:none" "r2(6): hung --bg — a same-named session from an earlier chain is not taken"
J | grep -q "lists no session of it"; check $? 0 "r2(6): …journaled"
setup; printf 'none
late
' > $R/seq; FAKE_BG=hang FAKE_HANG=3 FAKE_AGENTS_SEQ=$R/seq bgrun > /dev/null 2>&1
check "$(pending kind):$(call stop count)" "headless:1" "r2(6): hung --bg — a session listed late is stopped before the headless start"
setup; FAKE_BG=noid FAKE_AGENTS=stale succeed --model opus > /dev/null 2>&1
check "$(pending kind)" headless "r2(6): no id printed and only an earlier chain's session listed — not taken"
# (7) the headless successor's takeover does not depend on $CLAUDE_CODE_SESSION_ID
setup; succeed --model opus --headless > /dev/null 2>&1
SIDX=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["session_id"])' $R/stage-a/agents/hub-2/meta.json)
check "$(call -p-run AGENT_SESSION_ID)" "$SIDX" "r2(7): agent spawn exports AGENT_SESSION_ID (the run's own id)"
AGENT_SESSION_ID=$SIDX $B/hub takeover --stage stage-a --session self --auto-handoff --handoff $H > /dev/null 2>&1
check "$($B/roles --stage stage-a get hub | head -c 36)" "$SIDX" "r2(7): --session self falls back to AGENT_SESSION_ID"
# (8) --fallback re-reads the registry before stopping: a successor registering meanwhile is not stopped
setup; succeed --model opus > /dev/null 2>&1
FAKE_ON_LOGS="$B/roles --stage stage-a set hub $HUB2 --kind cli --tag hub-2 > /dev/null" $B/hub succeed --stage stage-a --fallback > $R/r8.out 2>&1
check "$?:$(call stop count):$(pending kind)" "0:none:bg" "r2(8): the successor registered while its logs were read — not stopped, record kept"
grep -q "is taking over; not stopped" $R/r8.out; check $? 0 "r2(8): …and it says so"

# ================================================================== where the successor starts
# The successor starts from the repository's main checkout (the root) in a new worktree of its own, as a Desktop
# session does — never in the hub's own directory, which may be a Desktop session's worktree that goes when that
# session is archived. Outside git: in --cwd itself (above).
wtrepo(){ M=$R/repo; mkdir -p $M; git -C $M init -q; git -C $M -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C $M worktree add -q $M/.claude/worktrees/x -b claude/x 2>/dev/null; git -C $M worktree add -q $M/.worktrees/x -b x 2>/dev/null
  MR=$(cd $M && pwd -P); }
for hubdir in .claude/worktrees/x .worktrees/x .; do
  setup; wtrepo
  $B/hub succeed --stage stage-a --handoff $H --cwd $M/$hubdir --model opus > $R/wt.out 2>&1; rc=$?
  check "$rc:$(call --bg cwd)" "0:$MR" "worktree ($hubdir): started from the main checkout"
  call --bg argv | grep -q -- "^--bg --remote-control stage-a-hub-2 -n Hub stage-a #2 --worktree stage-a-hub-2 "; check $? 0 "worktree ($hubdir): --worktree stage-a-hub-2"
  check "$(pending cwd):$(pending worktree)" "$MR:$MR/.claude/worktrees/stage-a-hub-2" "worktree ($hubdir): root and worktree recorded"
  J | grep -q "terminal: claude attach bg-1234abcd; in the new worktree $MR/.claude/worktrees/stage-a-hub-2 of $MR; waiting"; check $? 0 "worktree ($hubdir): the journal line names the worktree and the root"
done
# a taken name (a worktree directory, or the branch `claude --worktree` would create) -> the next free one
setup; wtrepo; mkdir -p $M/.claude/worktrees/stage-a-hub-2; git -C $M branch worktree-stage-a-hub-2-2
$B/hub succeed --stage stage-a --handoff $H --cwd $M/.worktrees/x --model opus > /dev/null 2>&1
call --bg argv | grep -q -- " --worktree stage-a-hub-2-3 "; check $? 0 "worktree: a taken name (directory, branch) gets the next free suffix"
# --dry-run says where it would start
setup; wtrepo
$B/hub succeed --stage stage-a --handoff $H --cwd $M/.claude/worktrees/x --model opus --dry-run > $R/dry.out 2>&1
grep -q "start \"Hub stage-a #2\" from $MR in a new worktree:" $R/dry.out && grep -q -- "--worktree stage-a-hub-2 " $R/dry.out; check $? 0 "worktree: --dry-run shows the root and --worktree"
# the headless successor: agent spawn --cwd <root> --worktree <branch> -> <root>/.worktrees/<branch> from the root's HEAD
setup; wtrepo
$B/hub succeed --stage stage-a --handoff $H --cwd $M/.claude/worktrees/x --model opus --headless > $R/wh.out 2>&1; check $? 0 "headless worktree: exit 0"
check "$(pending kind):$(pending cwd):$(pending worktree)" "headless:$MR:$MR/.worktrees/stage-a-hub-2" "headless worktree: root and worktree recorded"
check "$(git -C $M worktree list --porcelain | grep -c "^worktree $MR/.worktrees/stage-a-hub-2$"):$(git -C $M show-ref --verify --quiet refs/heads/stage-a-hub-2 && echo branch)" "1:branch" "headless worktree: agent spawn created it on its own branch"
check "$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$(call -p-run cwd)")" "$MR/.worktrees/stage-a-hub-2" "headless worktree: the headless hub runs in it"
J | grep -q "headless as agent hub-2.*in the new worktree $MR/.worktrees/stage-a-hub-2 of $MR"; check $? 0 "headless worktree: the journal line names it"

# ================================================================== the numbers of a hub with a legacy tag
# A hub registered as `хаб-25` (by hand, before the plugin) wrote the handoff #25 -> #26. `hub succeed` acts as hub-25,
# names its successor #26, and that successor's takeover (--auto-handoff) is the pending one: the chain is kept.
legacy(){ setup
  python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["roles"]["hub"]["tag"]=sys.argv[2]; json.dump(d,open(p,"w"),ensure_ascii=False)' $R/stage-a/roles.json "$1"
  H25=$R/stage-a/coordinator/HANDOFF-hub-stage-a-2026-10-02-1100.md
  printf '# Handoff "Hub stage-a #25" → "Hub stage-a #26" — stage-a\n\n## 0. First steps\n1. take over\n' > $H25
  touch -t 203001010000 $H25; H25=$(cd "$(dirname $H25)" && pwd -P)/$(basename $H25); }
legacy 'хаб-25'
$B/hub succeed --stage stage-a --handoff $H25 --cwd $W --model opus > $R/lg.out 2>&1; check $? 0 "legacy tag: succeed exit 0"
call --bg argv | grep -q -- "--remote-control stage-a-hub-26 -n Hub stage-a #26 "; check $? 0 "legacy tag: the successor is named #26"
J | grep -q '\[hub-25\] auto-handoff 1/10: started "Hub stage-a #26"'; check $? 0 "legacy tag: the hub journals as hub-25"
check "$(pending n)" 26 "legacy tag: pending successor 26"
CLAUDE_CODE_SESSION_ID=$HUB2 $B/hub takeover --stage stage-a --session self --auto-handoff --handoff $H25 > $R/lgt.out 2>&1; check $? 0 "legacy tag: the successor's takeover"
J | grep -q '\[hub-26\] start:'; check $? 0 "legacy tag: it takes over as hub-26 (the jwait of hub succeed matches)"
check "$(chain):$(pending taken_over | cut -c1-2)" "1:20" "legacy tag: the chain is kept, the pending successor marked taken over"
J | grep -q "chain reset"; check $? 1 "legacy tag: no chain reset"
# a tag with no number at all: the handoff given to `hub succeed` names the hub (its outgoing #25), not a guess from
# the latest handoff (its successor #26)
legacy 'hub'
$B/hub succeed --stage stage-a --handoff $H25 --cwd $W --model opus > /dev/null 2>&1
check "$(call --bg argv | grep -c -- '--remote-control stage-a-hub-26 '):$(J | grep -c '\[hub-25\] auto-handoff 1/10')" "1:1" "no number in the tag: --handoff's outgoing #25 wins over the guess"
# …and when that successor never takes over, --fallback stops it and starts the headless hub (the numberless tag is the
# old hub's, not a successor that registered meanwhile)
$B/hub succeed --stage stage-a --fallback > $R/lgf.out 2>&1; rc=$?
check "$rc:$(call stop count):$(pending kind):$(pending role)" "0:1:headless:hub-26" "no number in the tag: --fallback stops the bg hub-26 and starts the headless one"
# a hint for choosing the numbers that `hub succeed` can follow (it has no --n)
legacy 'hub'; rm -f $R/stage-a/coordinator/HANDOFF-*.md; printf '# no title\n' > $R/plain.md
$B/hub succeed --stage stage-a --handoff $R/plain.md --cwd $W --model opus > $R/nn.out 2>&1
check "$?:$(grep -c 'pass --n' $R/nn.out):$(grep -c 'hub handoff --stage stage-a --n <your number>' $R/nn.out)" "2:0:1" "no number anywhere: hub succeed points at hub handoff --n, not at its own (absent) --n"
# the pending successor's takeover takes the number it was started under, whatever the registry says by then
setup
python3 -c 'import json,sys; json.dump({"chain":1,"pending":{"n":7,"kind":"bg","id":"bg-x","k":1,"handoff":sys.argv[2],"at":"2026-10-02T11:00:00+00:00"}},open(sys.argv[1],"w"))' $R/stage-a/auto-handoff.json "$H"
$B/hub takeover --stage stage-a --session $HUB2 --auto-handoff --handoff $H > /dev/null 2>&1
check "$($B/roles --stage stage-a list 2>/dev/null | grep -c 'hub-7'):$(chain)" "1:1" "takeover --auto-handoff: the pending successor's number (hub-7), chain kept"

# ================================================================== hub succeed --replace; a retaken shift keeps the chain
# hub #1 started successor #2 (bg-1234abcd), which took over (--auto-handoff). Then:
took2(){ setup; CLAUDE_CODE_SESSION_ID=$HUB1 succeed --model opus > $R/rp0.out 2>&1
         CLAUDE_CODE_SESSION_ID=$HUB2 $B/hub takeover --stage stage-a --session self --auto-handoff --handoff $H > $R/rp1.out 2>&1; }
replace(){ $B/hub succeed --stage stage-a --cwd $W "$@"; }
took2; check "$(chain):$(pending author):$(call --bg count)" "1:$HUB1:1" "replace: setup — successor #2 took over, chain 1, the record names its author"
FAKE_AGENTS=prev FAKE_PREV_SID=bg-1234abcd CLAUDE_CODE_SESSION_ID=$HUB1 replace --replace --model opus > $R/rp2.out 2>&1; rc=$?
check "$rc:$(call stop count):$(grep -c '"argv": \["stop", "bg-1234a"\]' $FAKE_BG_LOG)" "0:1:1" "replace: the successor that took over is stopped (claude stop <id>), by the hub that handed over"
check "$(call rm count)" none "…never removed (no claude rm)"
check "$(call --bg count)" 2 "…and a new background successor is started"
call --bg argv | grep -q -- "--remote-control stage-a-hub-2 -n Hub stage-a #2 "; check $? 0 "…with the same number (hub-2)"
call --bg prompt | grep -qF "[agent-hub auto-handoff 1/10]" && call --bg prompt | grep -qF -- "--auto-handoff --handoff $H"; check $? 0 "…the same chain position (1/10) and the same --auto-handoff takeover command"  # rename:keep
check "$(chain):$(pending kind):$(pending taken_over):$(pending author)" "1:bg:None:$HUB1" "…chain still 1; a fresh pending record (not yet taken over), same author"
J | grep -q '\[hub-1\] auto-handoff: replacing hub-2 (bg bg-1234abcd): stopped background session bg-1234abcd'; check $? 0 "…journaled"
grep -q 'replaces the earlier hub-2' $R/rp2.out; check $? 0 "…and the journal line of the new successor says so"
# the new successor takes over: the shift is retaken, the chain stays
CLAUDE_CODE_SESSION_ID=$HUB3 $B/hub takeover --stage stage-a --session self --auto-handoff --handoff $H > $R/rp3.out 2>&1; check $? 0 "replace: the new successor's takeover (--auto-handoff)"
J | grep -q "\[hub-2\] start: .*re-took shift #2 (replaces 22222222), handoff by #1"; check $? 0 "…'re-took shift #2 (replaces <id8>), handoff by #1', not 'took over from #2'"
check "$(chain):$(pending taken_over | cut -c1-2)" "1:20" "…the chain is kept"
# who may replace
took2
FAKE_AGENTS=prev FAKE_PREV_SID=bg-1234abcd CLAUDE_CODE_SESSION_ID=$HUB3 replace --replace --model opus > $R/rp4.out 2>&1; check "$?:$(call stop count)" "2:none" "replace: a session that is not the author is refused"
FAKE_AGENTS=prev FAKE_PREV_SID=bg-1234abcd CLAUDE_CODE_SESSION_ID=$HUB2 replace --replace --model opus > $R/rp4.out 2>&1; check "$?:$(call stop count)" "2:none" "replace: the successor itself is refused"
FAKE_AGENTS=prev FAKE_PREV_SID=bg-1234abcd HUB_TAG=hub-5 replace --replace --model opus > $R/rp4.out 2>&1; check "$?:$(call stop count)" "2:none" "replace: a foreign HUB_TAG is refused"
FAKE_AGENTS=prev FAKE_PREV_SID=bg-1234abcd replace --replace --model opus > $R/rp5.out 2>&1; check "$?:$(call stop count):$(call --bg count)" "0:1:2" "replace: the owner at a terminal (no session, no tag) may"
# busy: refused unless --force
took2
FAKE_AGENTS=prevbusy FAKE_PREV_SID=bg-1234abcd CLAUDE_CODE_SESSION_ID=$HUB1 replace --replace --model opus > $R/rp6.out 2>&1
check "$?:$(call stop count):$(call --bg count):$(grep -c 'working now (status busy)' $R/rp6.out)" "1:none:1:1" "replace: a busy successor is not stopped, nothing started"
check "$(chain):$(pending kind)" "1:bg" "…the record is untouched"
FAKE_AGENTS=prevbusy FAKE_PREV_SID=bg-1234abcd CLAUDE_CODE_SESSION_ID=$HUB1 replace --replace --force --model opus > $R/rp7.out 2>&1
check "$?:$(call stop count):$(call --bg count)" "0:1:2" "replace --force: stops it and starts the new one"
# failures never start a second hub beside the first
took2
FAKE_STOP=fail FAKE_AGENTS=prev FAKE_PREV_SID=bg-1234abcd CLAUDE_CODE_SESSION_ID=$HUB1 replace --replace --model opus > $R/rp8.out 2>&1
check "$?:$(call --bg count):$(pending kind):$(chain)" "1:1:bg:1" "replace: claude stop failing → failure, nothing started, record kept"
FAKE_AGENTS=fail CLAUDE_CODE_SESSION_ID=$HUB1 replace --replace --model opus > $R/rp9.out 2>&1
check "$?:$(call stop count):$(call --bg count)" "1:1:1" "replace: the session list failing → failure (whether it runs is unknown), no further stop, nothing started"
FAKE_AGENTS=none CLAUDE_CODE_SESSION_ID=$HUB1 replace --replace --model opus > $R/rp10.out 2>&1
check "$?:$(call stop count):$(call --bg count)" "0:1:2" "replace: a successor that is gone is not stopped again (the one earlier attempt stays the only stop); a new one starts"
setup; replace --replace --model opus > $R/rp11.out 2>&1; check "$?:$(call --bg count)" "1:none" "replace: nothing recorded → nothing to replace"
took2; FAKE_AGENTS=prev FAKE_PREV_SID=bg-1234abcd replace --replace --dry-run --model opus > $R/rp12.out 2>&1
check "$?:$(call stop count):$(call --bg count):$(grep -c '^\[plan\] --replace: stop the recorded successor hub-2' $R/rp12.out)" "0:none:1:1" "replace --dry-run: a plan, nothing stopped or started"
replace --replace --again > /dev/null 2>&1; check $? 2 "replace: not together with --again"
# a headless successor that took over and ended, its shift taken again by hand: the record must not keep the stale headless role
setup
python3 - $R/stage-a/auto-handoff.json "$H" <<'PY'
import json, sys
json.dump({"chain": 1, "pending": {"n": 2, "kind": "headless", "role": "hub-2", "at": "2026-10-05T10:00:00+00:00", "taken_over": "2026-10-05T10:01:00+00:00",
                                   "handoff": sys.argv[2], "model": "opus", "k": 1, "author": "11111111-1111-4111-8111-111111111111"}}, open(sys.argv[1], "w"))
PY
$B/roles --stage stage-a set hub $HUB2 --tag hub-2 --kind cli > /dev/null
$B/hub takeover --stage stage-a --session $HUB3 --n 2 --handoff $H > $R/rp15.out 2>&1; check "$?:$(pending kind):$(pending role)" "0:manual:None" "stale role: a headless successor's shift taken by hand → the record says manual, the headless role is dropped"
replace --replace --model opus > $R/rp16.out 2>&1
check "$?:$(call --bg count):$(call stop count)" "1:none:none" "…and a later --replace starts no twin beside the session that holds the shift"
# a hub succeed that is still waiting for the Remote Control link while the successor takes over and another session retakes
# the shift by hand: the late record write must not restore the launch (kind bg, the old id)
setup
ONLOGS="CLAUDE_CODE_SESSION_ID=$HUB2 $B/hub takeover --stage stage-a --session self --auto-handoff --handoff $H > /dev/null 2>&1; $B/hub takeover --stage stage-a --session $HUB3 --n 2 --handoff $H > /dev/null 2>&1"
FAKE_ON_LOGS="$ONLOGS" CLAUDE_CODE_SESSION_ID=$HUB1 succeed --model opus > $R/rp17.out 2>&1
check "$?:$(pending kind):$(pending id):$(chain)" "0:manual:${HUB3:0:8}:1" "late record: a takeover by hand while hub succeed waits for the link → the record stays manual (not restored to the bg launch)"
FAKE_AGENTS=prev FAKE_PREV_SID=bg-1234abcd replace --replace --model opus > $R/rp18.out 2>&1
check "$?:$(call stop count):$(call --bg count)" "1:none:1" "…and --replace afterwards starts no twin"
# a takeover by hand of the shift that already was taken keeps the chain; one of a successor that has not taken over resets it
took2
$B/hub takeover --stage stage-a --session $HUB3 --n 2 --handoff $H > $R/rp13.out 2>&1; check $? 0 "retake: a takeover by hand of the same number (no --auto-handoff)"
check "$(chain):$(pending n):$(pending kind):$(pending id)" "1:2:manual:${HUB3:0:8}" "…keeps the chain and the pending record; the session that holds the shift now is recorded (kind manual)"
FAKE_AGENTS=prev FAKE_PREV_SID=bg-1234abcd replace --replace --model opus > $R/rp14.out 2>&1
check "$?:$(call stop count):$(call --bg count):$(grep -c 'taken over by hand' $R/rp14.out)" "1:none:1:1" "…and --replace of a hand-held shift is refused: nothing stopped, no second hub started beside it"
J | grep -q "chain reset"; check $? 1 "…no chain reset"
J | grep -q "\[hub-2\] start: .*re-took shift #2 (replaces 22222222), handoff by #1"; check $? 0 "…the start line says 're-took shift'"
setup; CLAUDE_CODE_SESSION_ID=$HUB1 succeed --model opus > /dev/null 2>&1
$B/hub takeover --stage stage-a --session $HUB3 --n 2 --handoff $H > /dev/null 2>&1; check "$(chain):$(pending n)" "0:None" "negative control: by hand while the pending successor has not taken over → the chain is reset, as before"

# ================================================================== the hook
setup
TR=$R/tr.jsonl
usage(){ python3 -c 'import json,sys; print(json.dumps({"type":"assistant","message":{"model":"claude-opus-5-5","usage":{"input_tokens":int(sys.argv[1])}}}))' "$1" >> $TR; }
# HOOK_EFFORT: the effort.level the CLI puts into the hook input (default high; "none" = the input carries none)
cbh(){ python3 -c 'import json,sys; d={"hook_event_name":sys.argv[1],"session_id":sys.argv[5],"transcript_path":sys.argv[2],"tool_name":sys.argv[3],"tool_input":json.loads(sys.argv[4]),"permission_mode":"acceptEdits","cwd":"/repo/x","prompt":sys.argv[6]}
if sys.argv[7]: d["agent_id"]=sys.argv[7]
if sys.argv[8] != "none": d["effort"]={"level":sys.argv[8]}
print(json.dumps(d))' "$1" "$TR" "${2:-}" "${3:-null}" "${SID:-$HUB1}" "${PROMPT:-}" "${AGENT:-}" "${HOOK_EFFORT:-high}" | python3 $HOOKS/context_budget.py; }
usage 320000
AGENT_HUB_AUTO_HANDOFF=off cbh UserPromptSubmit > $R/h0.out; grep -q "delamain:handoff" $R/h0.out && ! grep -q Autopilot $R/h0.out; check $? 0 "hook, autopilot off: the warning stays as today"
export AGENT_HUB_AUTO_HANDOFF=on AGENT_HUB_STATE_DIR=$R/state
cbh UserPromptSubmit > $R/h1.out
grep -qF 'Autopilot is on' $R/h1.out && grep -qF "$BR_BIN/"'hub succeed --stage stage-a --handoff <the draft> --model claude-opus-5-5 --effort high --permission-mode acceptEdits --cwd /repo/x' $R/h1.out; check $? 0 "hook, warn: autopilot instruction with the exact command (model, effort, mode, cwd)"
grep -qF 'where the owner finds it' $R/h1.out; check $? 0 "hook, warn: the instruction tells the hub to say where the successor is"
grep -qF "$BR_BIN/hub handoff --stage stage-a" $R/h1.out && grep -qF 'Hand over now' $R/h1.out && grep -qF 'Do not stop merely because a handoff file was written' $R/h1.out; check $? 0 "hook, warn: mandatory complete handoff, with no indefinite quiet-point delay"
SID=$HUB2 cbh PostToolUse Bash > $R/h2.out; grep -q "delamain:handoff" $R/h2.out && ! grep -q Autopilot $R/h2.out; check $? 0 "hook, warn: a session that is not the hub gets today's warning"
echo '{"AGENT_HUB_SUCCESSOR_PERMISSION_MODE": "default"}' > $R/config.json; usage 360000
cbh PostToolUse Bash | grep -qF -- '--permission-mode default --cwd'; check $? 0 "hook, warn: the configured mode wins over the session's"
rm $R/config.json
usage 420000
AGENT_HUB_SUCCESSOR_EFFORT=max cbh PostToolUse Bash | grep -qF -- '--model claude-opus-5-5 --effort max --permission-mode'; check $? 0 "hook, warn: the printed command carries AGENT_HUB_SUCCESSOR_EFFORT"
# the effort of the command comes from the hook input; each case on a transcript that dropped below the threshold first
# (re-arms the warning, which fires once per level)
TR0=$TR; fresh(){ TR=$R/tr-$1.jsonl; rm -f $TR; usage 1000; cbh PostToolUse Bash > /dev/null; usage 420000; }
fresh a; HOOK_EFFORT=xhigh cbh PostToolUse Bash | grep -qF -- '--model claude-opus-5-5 --effort xhigh --permission-mode'; check $? 0 "hook, warn: the printed command carries the effort of the hook input"
fresh b; HOOK_EFFORT=xhigh AGENT_HUB_SUCCESSOR_EFFORT=low cbh PostToolUse Bash | grep -qF -- '--effort low --permission-mode'; check $? 0 "hook, warn: AGENT_HUB_SUCCESSOR_EFFORT beats the hook input"
fresh c; ( unset CLAUDE_EFFORT; PATH=$NO_PS:$PATH; HOOK_EFFORT=none cbh PostToolUse Bash ) > $R/h5.out
grep -qF -- '--model claude-opus-5-5 --permission-mode' $R/h5.out; check $? 0 "hook, warn: an input with no effort and nothing else readable — the command has no --effort"
grep -qF 'Your own effort could not be read here' $R/h5.out; check $? 0 "hook, warn: …and the text tells the hub to let \`hub succeed\` read it, or pass --effort"
fresh d; HOOK_EFFORT=none CLAUDE_CODE_SESSION_ID=$HUB1 CLAUDE_EFFORT=max cbh PostToolUse Bash | grep -qF -- '--model claude-opus-5-5 --effort max --permission-mode'; check $? 0 "hook, warn: no effort in the input — the hook's own environment answers"
TR=$TR0
cbh PreToolUse Bash '{"command":"ls"}' > $R/h3.out; grep -q '"deny"' $R/h3.out; check $? 0 "hook: first warn closes ordinary Bash before block"
usage 510000
cbh PreToolUse Bash '{"command":"git status"}' | grep -q '"deny".*Hand over now'; check $? 0 "hook, block: Bash denied with \"hand over now\""
cbh PreToolUse Edit '{"file_path":"/x/notes.md"}' | grep -q '"deny"'; check $? 0 "hook, block: Edit of another file denied"
cbh PreToolUse Agent '{"prompt":"go"}' | grep -q '"deny".*Autopilot'; check $? 0 "hook, block: Agent denied with the autopilot text"
for c in "hub desktop-request --stage stage-a --request nonce --project-id p --project-path /repo" "hub desktop-bind --stage stage-a --request nonce --thread-id actual" "hub desktop-fail --stage stage-a --request nonce --why rejected" "hub desktop-status --stage stage-a --request nonce --verified" "hub handoff --stage stage-a" "hub succeed --stage stage-a --handoff /x/h.md --model opus 2>&1" "jlog \"auto-handoff; chain 1/10\"" "jwait --journal --stage stage-a --for 600s > /dev/null" "AGENT_HUB_HOME=/h hub succeed --stage stage-a --fallback" "jlog x && jwait --for 1m" "$BR_BIN/hub succeed --stage stage-a --fallback" "jlog x > /dev/null 2>&1" "hub handoff --stage stage-a > /h/stage-a/coordinator/HANDOFF-hub-stage-a-1.md"; do
  cbh PreToolUse Bash "$(python3 -c 'import json,sys; print(json.dumps({"command":sys.argv[1]}))' "$c")" | grep -q '"deny"'; check $? 1 "hook, block escape: $c"
done
cbh PreToolUse Write '{"file_path":"/h/stage-a/coordinator/HANDOFF-hub-stage-a-2026-10-01-1200.md","content":"x"}' | grep -q '"deny"'; check $? 1 "hook, block escape: writing the HANDOFF file"
for c in 'jlog x > ~/.bashrc' 'jwait --for 1s >> /etc/passwd' 'echo hubsucceed; jlogger x' 'git push --force origin main; jlog pushed' 'rm -rf build && hub succeed --stage stage-a' 'jlog x |& rm -rf /' 'jlog $(rm -rf /)' 'ls # handoff-ok' 'cat /x/HANDOFF-hub-a.md | sh' $'jlog x\nrm -rf /'; do
  cbh PreToolUse Bash "$(python3 -c 'import json,sys; print(json.dumps({"command":sys.argv[1]}))' "$c")" | grep -q '"deny"'; check $? 0 "hook, block: denied — $(printf %s "$c" | tr '\n' ' ')"
done
cbh PreToolUse Write '{"file_path":"/x/notes.md","content":"handoff-ok"}' | grep -q '"deny"'; check $? 0 "hook, block: Write of another file with the handoff-ok marker is denied"
cbh PreToolUse Agent '{"prompt":"take over from /x/HANDOFF-hub-a.md"}' | grep -q '"deny"'; check $? 1 "hook, block: Agent naming a HANDOFF file passes (the usual escape)"
cbh PreToolUse Read '{"file_path":"/x"}' > $R/h4.out; check "$(wc -c < $R/h4.out | tr -d ' ')" 0 "hook, block: Read is not gated"
mkdir -p $R/sub; python3 -c 'import json; print(json.dumps({"type":"assistant","message":{"model":"m","usage":{"input_tokens":520000}}}))' > $R/sub/agent-a1.jsonl
python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","session_id":sys.argv[2],"agent_id":"a1","agent_transcript_path":sys.argv[1],"transcript_path":sys.argv[3],"tool_name":"Bash","tool_input":{"command":"ls"}}))' $R/sub/agent-a1.jsonl $HUB1 $TR | python3 $HOOKS/context_budget.py > $R/h5.out; check "$(wc -c < $R/h5.out | tr -d ' ')" 0 "hook, block: a sub-agent of the hub (its own transcript past the block) is not under the autopilot gate"
python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","session_id":sys.argv[2],"agent_id":"a1","agent_transcript_path":sys.argv[1],"transcript_path":sys.argv[3],"tool_name":"Agent","tool_input":{"prompt":"go"}}))' $R/sub/agent-a1.jsonl $HUB1 $TR | python3 $HOOKS/context_budget.py | grep -q '"deny"' ; check $? 0 "…while its own Agent call is denied as today (positive control)"
SID=$HUB2 cbh PreToolUse Bash '{"command":"ls"}' > $R/h6.out; check "$(wc -c < $R/h6.out | tr -d ' ')" 0 "hook, block: another session's Bash stays ungated"
AGENT_HUB_AUTO_HANDOFF=off cbh PreToolUse Bash '{"command":"ls"}' > $R/h7.out; check "$(wc -c < $R/h7.out | tr -d ' ')" 0 "hook, block, autopilot off: Bash not gated (as today)"
AGENT_HUB_AUTO_HANDOFF=off cbh PreToolUse Agent '{"prompt":"go"}' | grep -q '"deny"' && ! (AGENT_HUB_AUTO_HANDOFF=off cbh PreToolUse Agent '{"prompt":"go"}' | grep -q Autopilot); check $? 0 "hook, block, autopilot off: Agent denied with today's text"
# chain reset by an owner prompt
echo '{"chain": 3, "pending": null}' > $R/stage-a/auto-handoff.json
PROMPT='<task-notification>jwait exited</task-notification>' cbh UserPromptSubmit > /dev/null; check "$(chain)" 3 "reset: a harness notice is not the owner"
PROMPT='/delamain:hub take over stage stage-a from /x. [agent-hub auto-handoff 3/10]' cbh UserPromptSubmit > /dev/null; check "$(chain)" 3 "reset: the successor's own prompt as written now (new command, marker under the former name) keeps the chain"  # rename:keep
PROMPT='/agent-hub:hub take over stage stage-a from /x. [agent-hub auto-handoff 3/10]' cbh UserPromptSubmit > /dev/null; check "$(chain)" 3 "rename: a successor started before the rename (old marker) keeps the chain"  # rename:keep
PROMPT='[delamain auto-handoff 3/10]' cbh UserPromptSubmit > /dev/null; check "$(chain)" 3 "rename: the new marker alone keeps the chain"
PROMPT='/other:hub take over stage stage-a from /x. [other auto-handoff 3/10]' cbh UserPromptSubmit > /dev/null; check "$(chain)" 0 "rename, negative: a marker of another product is the owner speaking, the chain resets"
echo '{"chain": 3, "pending": null}' > $R/stage-a/auto-handoff.json
PROMPT='[agent-hub auto-handoff x/10]' cbh UserPromptSubmit > /dev/null; check "$(chain)" 0 "rename, negative: a malformed old marker (no k/N) is the owner speaking"  # rename:keep
echo '{"chain": 3, "pending": null}' > $R/stage-a/auto-handoff.json
PROMPT="[delamain watchdog] stage-a: 1 journal lines addressed to you have waited since 10:00 and no jwait of yours is running." cbh UserPromptSubmit > /dev/null
check "$(chain)" 3 "reset: the watchdog's wake prompt (its marker at the start) keeps the chain"
PROMPT="[agent-hub watchdog] stage-a: 1 journal lines addressed to you have waited since 10:00 and no jwait of yours is running." cbh UserPromptSubmit > /dev/null; check "$(chain)" 3 "rename: the watchdog's wake prompt with the former marker (an older version, or the form still written) keeps the chain"  # rename:keep
PROMPT='what does [delamain watchdog] mean in the journal?' cbh UserPromptSubmit > /dev/null; check "$(chain)" 0 "reset: the owner quoting the watchdog marker mid-text still resets the chain"
echo '{"chain": 3, "pending": null}' > $R/stage-a/auto-handoff.json
PROMPT='what does [agent-hub watchdog] mean in the journal?' cbh UserPromptSubmit > /dev/null; check "$(chain)" 0 "rename, negative: the owner quoting the former watchdog marker mid-text still resets the chain"  # rename:keep
echo '{"chain": 3, "pending": null}' > $R/stage-a/auto-handoff.json
PROMPT='how is it going?' SID=$HUB2 cbh UserPromptSubmit > /dev/null; check "$(chain)" 3 "reset: a prompt in another session keeps the chain"
PROMPT='how is it going?' AGENT_HUB_AUTO_HANDOFF=off cbh UserPromptSubmit > /dev/null; check "$(chain)" 3 "reset: autopilot off, nothing changes"
PROMPT='how is it going?' cbh UserPromptSubmit > /dev/null; check "$(chain)" 0 "reset: the owner's prompt in the hub's session resets the chain"
setst 2 starting 30; PROMPT='hello' cbh UserPromptSubmit > /dev/null; check "$(chain):$(pending kind)" "0:starting" "r2(2): an owner prompt keeps a reservation in progress"
setst 2 headless 30 role=hub-2; AGENT_HUB_SUCCESSOR_TIMEOUT=600 PROMPT='hello' cbh UserPromptSubmit > /dev/null; check "$(pending kind)" headless "r2(2): an owner prompt keeps a successor still in its takeover window"
setst 0 headless 700 role=hub-2; PROMPT='hello' cbh UserPromptSubmit > /dev/null; check "$(pending n)" None "r2(2): an owner prompt drops a successor that did not take over in time"
J | grep -q "dropped the pending hub-2 (headless hub-2), which did not take over in time"; check $? 0 "r2(2): …journaled"
J | grep -q "auto-handoff chain reset (3 → 0): the owner spoke in the hub's session"; check $? 0 "reset: journaled"
echo '{"AGENT_HUB_CONTEXT_BUDGET": "off"}' > $R/config.json; echo '{"chain": 2, "pending": null}' > $R/stage-a/auto-handoff.json
PROMPT='hello' cbh UserPromptSubmit > /dev/null; check "$(chain)" 0 "reset: works with the context budget switched off"
rm $R/config.json
exit $fail
