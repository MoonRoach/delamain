#!/bin/bash
# agent-top lists the sub-agents of the sessions in a stage's role registry, read-only, from fake Claude Code
# transcripts (subagent_fixture.py): states from the parent's completion notices and Agent-call results, resumed and
# late-flushed ones, the parent's liveness from <claude config>/sessions (unknown, running, ended) and a headless
# parent's pid; negative controls — a quoted notice, a session outside the registry, an old one without --all,
# nothing written; card, feed and widget of a sub-agent.
. "$(dirname "$0")/lib.sh"
new_home; export HUB_STAGE=stage-a PYTHONDONTWRITEBYTECODE=1
R=$AGENT_HUB_HOME; export CLAUDE_CONFIG_DIR=$R/cc
HUB=33333333-cccc-4ccc-8ccc-333333333333; EXE=44444444-dddd-4ddd-8ddd-444444444444; STR=55555555-eeee-4eee-8eee-555555555555
python3 $T/subagent_fixture.py $CLAUDE_CONFIG_DIR $HUB $EXE $STR > /dev/null; check $? 0 "fixture built"
# a live process whose command line holds both parent session ids: the headless parent's pid and the hub's process
python3 -c 'import time; time.sleep(600)' $EXE $HUB claude-stand-in & SLEEPER=$!
trap 'kill $SLEEPER 2>/dev/null; test_cleanup' EXIT
$B/roles set hub $HUB --kind cli --tag hub-7 > /dev/null; check $? 0 "registry: hub"
$B/roles set exec $EXE --kind headless --tag hub-7-exec --pid $SLEEPER > /dev/null; check $? 0 "registry: headless exec"
fp(){ python3 - "$R" <<'PY'
import hashlib, os, sys
out = []
cache = os.path.join(sys.argv[1], ".state", "agent-top")   # agent-top's own read cache (bin/topcache.py): its one write
for d, _, files in os.walk(sys.argv[1]):
    if d == cache or d.startswith(cache + os.sep):
        continue
    for f in files:
        p = os.path.join(d, f)
        if f.endswith(".lock") or f.startswith(("fp-", "st-")):
            continue
        st = os.stat(p)
        out.append(f"{p} {st.st_mtime_ns} {hashlib.sha1(open(p, 'rb').read()).hexdigest()}")
print("\n".join(sorted(out)))
PY
}
snapshot(){ $B/agent-top --json > $R/st-json.out 2> $R/st-json.err; local rc=$?
  python3 -c '
import json, sys
for a in json.load(open(sys.argv[1]))["agents"]:
    if a.get("kind") == "subagent":
        print(a["role"], a["state"], a["effort"] or "-", (a["result"] or {}).get("subtype") or "-", a["background"], a["quiet"])
' $R/st-json.out > $R/st-states.txt; return $rc; }
st(){ awk -v r="$1" '$1==r {print $2}' $R/st-states.txt; }
col(){ awk -v r="$1" -v c="$2" '$1==r {print $c}' $R/st-states.txt; }

# ---- 1. the parent's liveness is unknown (no <config>/sessions): the silence rule
fp > $R/fp-before.txt
snapshot; check $? 0 "--json exit 0"
check "$(st hub/alive1)" live "live: written just now, no notice (a torn last line is skipped)"
check "$(col hub/alive1 3)" high "effort read from the transcript"
check "$(st hub/done1)" done "done: notice queued as a queue-operation"
check "$(col hub/done1 4)" completed "…result subtype is the notice status"
check "$(st hub/resumed)" live "resumed: a new user line after its notice -> live again"
check "$(st hub/late1)" done "late flush: an assistant line after the notice, no new user line -> still done"
check "$(st hub/nots1)" done "a notice without a timestamp still ends it"
check "$(st hub/fail1)" error "error: notice status failed (queued_command attachment)"
check "$(st hub/killed1)" dead "died: notice status killed"
check "$(st hub/lost1)" dead "unknown parent, no notice, silent 40 min -> died"
check "$(st hub/fg1)" done "foreground: the Agent call's tool result ends it"
check "$(col hub/fg1 5)" False "…and it is marked foreground"
check "$(st hub/fgerr1)" error "foreground: an error tool result -> error"
check "$(st hub/fgrun1)" live "foreground without a result yet -> live"
check "$(st hub/fg2)" done "foreground: another call's error on the same line does not make it an error"
check "$(st hub/noshape)" live "negative: no requestShape -> a tool result alone does not end it"
check "$(st hub/nolog1)" "" "a meta file without a transcript: no crash, not listed while the parent is unknown"
check "$(st exec/orphan1)" live "headless parent alive (pid) -> its sub-agent is live"
check "$(st hub/old1)" "" "negative: a finished sub-agent older than 1 h is hidden"
grep -q ghost $R/st-json.out; check $? 1 "negative: a session outside the registry is never scanned"
python3 -c '
import json, sys
ags = json.load(open(sys.argv[1]))["agents"]
a = next(a for a in ags if a["role"] == "hub/alive1")
assert a["action"]["tool"] == "Bash" and a["title"] == "run the tests" and a["model"] == "haiku", a
assert a["pid"] is None and a["unread"] == [] and a["ctx_tokens"] == 15903, a
d = next(a for a in ags if a["role"] == "hub/done1")
assert d["result"]["text"].startswith("DONE: 3 errors"), d
' $R/st-json.out; check $? 0 "fields: current action, description as task, model, context, result text"
$B/agent-top --json --all | grep -q '"role": "hub/old1"'; check $? 0 "--all shows the old one"

# ---- 2. the hub's process is registered in <config>/sessions with a live pid
mkdir -p $CLAUDE_CONFIG_DIR/sessions
echo "{\"pid\": $SLEEPER, \"sessionId\": \"$HUB\", \"kind\": \"interactive\"}" > $CLAUDE_CONFIG_DIR/sessions/$SLEEPER.json
snapshot
check "$(st hub/lost1)" live "parent session running -> a sub-agent silent 40 min stays live…"
check "$(col hub/lost1 6)" True "…flagged quiet"
check "$(st hub/alive1)" live "parent session running -> live"
python3 -c 'import time; time.sleep(600)' $HUB & OTHER=$!
mv $CLAUDE_CONFIG_DIR/sessions/$SLEEPER.json $CLAUDE_CONFIG_DIR/sessions/$OTHER.json
echo "{\"pid\": $OTHER, \"sessionId\": \"$HUB\"}" > $CLAUDE_CONFIG_DIR/sessions/$OTHER.json
snapshot
check "$(st hub/alive1)" dead "negative: a stale session file whose pid now runs something else is not a live parent"
kill $OTHER; wait $OTHER 2>/dev/null
echo "{\"pid\": $SLEEPER, \"sessionId\": \"$HUB\"}" > $CLAUDE_CONFIG_DIR/sessions/$SLEEPER.json; rm -f $CLAUDE_CONFIG_DIR/sessions/$OTHER.json
snapshot
check "$(st hub/nolog1)" live "…and a meta file without a transcript is listed under a running parent"

# ---- 3. the hub's session file is gone (its process ended), the folder exists
rm $CLAUDE_CONFIG_DIR/sessions/$SLEEPER.json
snapshot
check "$(st hub/alive1)" dead "parent session ended -> its unfinished sub-agent died"
check "$(st hub/done1)" done "…a finished one stays done"
check "$(st exec/orphan1)" live "a headless parent is still judged by its pid"
kill $SLEEPER; wait $SLEEPER 2>/dev/null
snapshot
check "$(st exec/orphan1)" dead "headless parent gone -> its sub-agent died"

# ---- text views: list row, card with the read-only note, feed from the transcript, widget
mkdir -p $CLAUDE_CONFIG_DIR/sessions
python3 -c 'import time; time.sleep(600)' $HUB claude-stand-in & SLEEPER=$!
echo "{\"pid\": $SLEEPER, \"sessionId\": \"$HUB\"}" > $CLAUDE_CONFIG_DIR/sessions/$SLEEPER.json
$B/agent-top --once --width 140 --agent hub/done1 --lines 10 > $R/st-once.out 2>&1; check $? 0 "--once --agent on a sub-agent exit 0"
grep -q 'hub/ali.*run the tests.*live.*Bash: Run the tests' $R/st-once.out; check $? 0 "list row: role, task, state, action"
grep -q 'read-only here — only its parent' $R/st-once.out; check $? 0 "card: read-only note with the address"
grep -q 'brief of scan the logs' $R/st-once.out && grep -q '✎ DONE: 3 errors' $R/st-once.out; check $? 0 "feed: brief and last text from the transcript"
$B/agent-top --widget > $R/st-widget.out 2>&1; check $? 0 "--widget exit 0 with sub-agents"
grep -q 'hub/alive1' $R/st-widget.out; check $? 0 "…and lists them"
rm $CLAUDE_CONFIG_DIR/sessions/$SLEEPER.json; rmdir $CLAUDE_CONFIG_DIR/sessions
fp > $R/fp-after.txt
diff -q $R/fp-before.txt $R/fp-after.txt > /dev/null; check $? 0 "agent-top wrote nothing (hub home and transcripts)"
exit $fail
