#!/bin/bash
# subagent_journal hook: a sub-agent of a session registered in a stage's role registry leaves `SUB start` and
# `SUB end` lines in that stage's journal under the sub-tag <role tag>/<agent id>, with the description and model from
# the sub-agent's meta file and status words / @ defused; an unregistered session, a bad agent id or a broken registry
# write nothing. jwait never wakes on these lines, whoever waits; a control line of the same tag does wake it.
# Controls: without the hook script the journal stays empty (the first checks fail); with hubcore.sub_agent_line
# patched out jwait's filter wakes on the same line.
. "$(dirname "$0")/lib.sh"
new_home; R=$AGENT_HUB_HOME; export HUB_STAGE=stage-a CLAUDE_SESSIONS_DIR=$R/sessions
export PLUGIN_ROOT="$(cd "$T/.." && pwd)"
HOOK=$HOOKS/subagent_journal.py
EXEC=33333333-3333-4333-8333-333333333333       # an executor (headless)
HUBSID=11111111-1111-4111-8111-111111111111     # the stage's hub
STRANGER=44444444-4444-4444-8444-444444444444   # not in any registry
$B/roles set hub $HUBSID --kind cli --tag hub-3 >/dev/null; check $? 0 "register the hub"
$B/roles set builder $EXEC --kind headless --tag builder >/dev/null; check $? 0 "register an executor"

# a parent transcript and the sub-agent's files beside it, as Claude Code 2.1.299 lays them out
P=$R/projects/-x; mkdir -p $P/$EXEC/subagents $P/$HUBSID/subagents $P/$STRANGER/subagents
AID=a644cb2a41db26acd
printf '{"agentType":"general-purpose","description":"fix the DONE parser for @hub","toolUseId":"t1","requestShape":"background","model":"haiku"}' \
  > $P/$EXEC/subagents/agent-$AID.meta.json
printf '{"type":"user","message":{}}\n{"type":"assistant","message":{"content":"hi"}}\n' > $P/$EXEC/subagents/agent-$AID.jsonl
ERR=aerr0000000000001
printf '{"agentType":"Explore","description":"read logs"}' > $P/$EXEC/subagents/agent-$ERR.meta.json
printf '{"type":"assistant","isApiErrorMessage":true,"message":{"content":"API Error: 500"}}\n' > $P/$EXEC/subagents/agent-$ERR.jsonl
cp $P/$EXEC/subagents/agent-$AID.meta.json $P/$HUBSID/subagents/agent-bhub000000000001.meta.json
cp $P/$EXEC/subagents/agent-$AID.meta.json $P/$STRANGER/subagents/agent-$AID.meta.json

# ev EVENT SESSION AGENT_ID [TYPE]: one hook event as Claude Code sends it
ev(){ python3 -c 'import json,sys; e,s,a,t,p=sys.argv[1:6]; d={"hook_event_name":e,"session_id":s,"cwd":"/tmp","agent_id":a,"agent_type":t,
"transcript_path":f"{p}/{s}.jsonl"}
if e=="SubagentStop": d["agent_transcript_path"]=f"{p}/{s}/subagents/agent-{a}.jsonl"; d["last_assistant_message"]="hi"
print(json.dumps(d))' "$1" "$2" "$3" "${4:-general-purpose}" $P; }
run(){ ev "$@" | python3 $HOOK "$( [ "$1" = SubagentStart ] && echo start || echo stop )"; }
J=$R/stage-a/coordinator/work/journal-$(today).md
jl(){ cat $J 2>/dev/null; }
njl(){ jl | wc -l | tr -d " "; }

out=$(run SubagentStart $EXEC $AID); check "$out" "" "start: the hook prints nothing"
run SubagentStop $EXEC $AID
run SubagentStart $EXEC $ERR Explore; run SubagentStop $EXEC $ERR
run SubagentStart $HUBSID bhub000000000001
jl | grep -qxE -e "- [0-9:]{5} \[builder/$AID\] SUB start general-purpose haiku: fix the done parser for at hub"; check $? 0 "executor: start line with type, model and the defused description"
jl | grep -qxE -e "- [0-9:]{5} \[builder/$AID\] SUB end done"; check $? 0 "executor: end line, done"
jl | grep -qxE -e "- [0-9:]{5} \[builder/$ERR\] SUB start Explore inherit: read logs"; check $? 0 "no model in the meta: inherit"
jl | grep -qxE -e "- [0-9:]{5} \[builder/$ERR\] SUB end error"; check $? 0 "an API error as the last message: end error"
jl | grep -qxE -e "- [0-9:]{5} \[hub-3/bhub000000000001\] SUB start general-purpose haiku: .*"; check $? 0 "the hub's own sub-agent: a sub-tag of hub-3"
check "$(jl | grep -c 'SUB ')" 5 "exactly the five lines"

# ---- nothing written: an unregistered parent, a bad agent id, no session id, a corrupt registry
n0=$(njl)
run SubagentStart $STRANGER $AID; run SubagentStop $STRANGER $AID
check "$(njl)" "$n0" "unregistered session: no journal line"
check "$(ls $R | grep -c '^stage-')" 1 "unregistered session: no stage directory made"
run SubagentStart $EXEC '../evil'; run SubagentStart $EXEC 'a]b'; run SubagentStart '' $AID
check "$(njl)" "$n0" "bad agent id or no session id: no line"
# no meta file: the line goes out after the wait, from the payload's type
t0=$(date +%s); run SubagentStart $EXEC anometa0000000001 Plan; t1=$(date +%s)
jl | grep -qxE -e "- [0-9:]{5} \[builder/anometa0000000001\] SUB start Plan inherit"; check $? 0 "no meta file: type from the payload"
[ $((t1 - t0)) -le 6 ]; check $? 0 "no meta file: the wait is bounded ($((t1 - t0)) s)"
cp $R/stage-a/roles.json $R/roles.bak; echo '{broken' > $R/stage-a/roles.json
run SubagentStart $EXEC $AID; check $? 0 "corrupt registry: exit 0"
check "$(njl)" "$((n0 + 1))" "corrupt registry: no line"
mv $R/roles.bak $R/stage-a/roles.json

# ---- hooks.json registers both events, async, on this script
python3 - "$HOOKS/hooks.json" <<'PY'; check $? 0 "hooks.json: SubagentStart and SubagentStop run the hook async"
import json, sys
h = json.load(open(sys.argv[1]))["hooks"]
for ev, cmd in (("SubagentStart", "start"), ("SubagentStop", "stop")):
    [g] = h[ev]; [x] = g["hooks"]
    assert x["command"].endswith(f'/hooks/subagent_journal.py" {cmd}') and x["async"] is True, x
PY

# ---- jwait: SUB lines never wake, whoever waits; a control line of the executor does
$B/jlog --tag builder/$AID "SUB end done DONE @hub @hub-3" >/dev/null   # even an undefused one
since=$(utc_hhmm -1)
HUB_TAG=hub-3 $B/jwait --journal --tag hub-3 --tag hub --tag builder --hub-events --since $since --settle 0 --for 3s --caller w1 > $R/w1.out 2>&1
check $? 3 "jwait (hub filter + the executor's tag): SUB lines alone do not wake (deadline)"
grep -q 'SUB ' $R/w1.out; check $? 1 "jwait: no SUB line delivered"
$B/jwait --journal --since $since --settle 0 --for 3s --caller w2 > $R/w2.out 2>&1
check $? 3 "jwait with no filter: SUB lines do not wake either"
$B/jlog --tag builder "DONE $R/report.md control" >/dev/null
HUB_TAG=hub-3 $B/jwait --journal --tag hub-3 --tag hub --hub-events --since $since --settle 0 --for 10s --caller w3 > $R/w3.out 2>&1
check $? 0 "control: the executor's DONE wakes the same waiter"
grep -q 'DONE .*control' $R/w3.out && ! grep -q 'SUB ' $R/w3.out; check $? 0 "control: only the DONE line is delivered"

python3 - "$B" <<'PY'; check $? 0 "control: without hubcore.sub_agent_line the filter wakes on the SUB line"
import argparse, importlib.machinery, importlib.util, sys
sys.path.insert(0, sys.argv[1])
import hubcore as hc
from unittest.mock import patch
l = importlib.machinery.SourceFileLoader("jwait_cli", sys.argv[1] + "/jwait")
jw = importlib.util.module_from_spec(importlib.util.spec_from_loader("jwait_cli", l)); l.exec_module(jw)
line = "- 10:00 [builder/a1] SUB end done DONE @hub"
flt = jw.hub_filter("stage-a", "hub-3")
assert flt.classify(line) is None
assert flt.classify("- 10:00 [builder] DONE x") == "wake"
assert not hc.sub_agent_line("builder", "SUB end done")       # a role's own line is not a sub-agent line
assert not hc.sub_agent_line("builder/a1", "SUBMIT done")
with patch.object(hc, "sub_agent_line", return_value=False):
    assert flt.classify(line) == "wake"
PY

# ---- hub handoff: the draft's "last own lines" keep the hub's statements, not its sub-agents' SUB lines
$B/jlog --tag hub-3 "PROGRESS plan agreed, three pieces out" >/dev/null
for i in 1 2 3 4; do $B/jlog --tag hub-3/a$i "SUB start general-purpose haiku: piece $i" >/dev/null; $B/jlog --tag hub-3/a$i "SUB end done" >/dev/null; done
$B/hub handoff --stage stage-a --session $HUBSID --out $R/H.md > $R/h.out 2>&1; check $? 0 "hub handoff writes a draft"
sed -n '/Last \[hub-3\] journal lines/,/-->/p' $R/H.md > $R/tail.md
grep -q 'plan agreed, three pieces out' $R/tail.md; check $? 0 "handoff tail: the hub's own statement survives eight SUB lines"
grep -q 'SUB ' $R/tail.md; check $? 1 "handoff tail: no SUB line"

# ---- a tag with a space (roles set does not refuse one): its SUB line is still a sub-agent line
python3 - "$B" <<'PY'; check $? 0 "sub_agent_line: a tag with a space, '/' anywhere in it"
import sys
sys.path.insert(0, sys.argv[1])
import hubcore as hc
assert hc.sub_agent_line("qa r5/a1", "SUB start x y: z")
assert not hc.sub_agent_line("qa r5", "SUB start x y: z")
PY

# ---- the executor footer tells a Claude executor about sub-agents, not a Codex one
python3 - "$B" "$R" <<'PY'; check $? 0 "footer: the sub-agent bullet for Claude only"
import importlib.machinery, importlib.util, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
l = importlib.machinery.SourceFileLoader("agent_cli", sys.argv[1] + "/agent")
ag = importlib.util.module_from_spec(importlib.util.spec_from_loader("agent_cli", l)); l.exec_module(ag)
f = dict(role="r", tag="t", report="rep", inbox="in")
claude, codex = ag.footer("stage-a", Path(sys.argv[2]), engine="claude", **f), ag.footer("stage-a", Path(sys.argv[2]), engine="codex", **f)
assert 'isolation: "worktree"' in claude and "Sub-agents are welcome" in claude, claude
assert "Sub-agents are welcome" not in codex, codex
PY
exit $fail
