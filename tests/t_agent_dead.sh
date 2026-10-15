#!/bin/bash
# An agent whose process is gone without a result (kill -9 of its whole group: the exit-note wrapper dies with it) is
# journaled once as `EXIT <role>: killed (no result)` by the first observer — `agent status` or the poll of `jwait
# --journal` — however many observe at once; a normal EXIT is not doubled, an `agent stop` and a resumed run are not
# reported, a `ps` that shows nothing is not a death, and the hub's default jwait match wakes on the line.
. "$(dirname "$0")/lib.sh"
new_home; export HUB_STAGE=stage-a HUB_TAG=hub-test CLAUDE_BIN=$T/fake_claude.py
R=$AGENT_HUB_HOME; W=$R/w; mkdir -p $W; echo "brief: do the thing" > $W/b.md
PAT=$(python3 -c "import sys; sys.path.insert(0, '$B'); import hubcore as hc; print(hc.status_pattern())")
pid_of(){ python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['pid'])" $R/stage-a/agents/$1/meta.json; }
spawn(){ FAKE_HOLD=${HOLD:-60} $B/agent spawn --role "$1" --cwd $W --model haiku --brief $W/b.md > $R/spawn-$1.out 2>&1; }
exits(){ grep -c "EXIT $1: " "$(journal stage-a)"; }          # EXIT lines of the role, whatever they say
killed(){ grep -c "EXIT $1: killed (no result)" "$(journal stage-a)"; }
wait_gone(){ for i in $(seq 1 40); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.25; done; return 1; }
trap 'chmod 755 $R/stage-a/agents/aro 2>/dev/null; for r in d1 d2 d3 d4 d5 d6 d7 d8 aro bok; do $B/agent stop $r >/dev/null 2>&1; done; test_cleanup' EXIT

# 1. kill -9 of the whole group, two observers at once, a jwait with the hub's default match waiting
spawn d1; check $? 0 "spawn d1"
P=$(pid_of d1)
$B/jwait --journal --stage stage-a --caller c1 --settle 1 --for 60s --match "$PAT" > $R/jw1.out 2>&1 & JW=$!
armed $R/jw1.out; check $? 0 "jwait armed"
kill -KILL -- -$P; wait_gone $P; check $? 0 "the whole process group is gone"
$B/agent status d1 > $R/st1a.out 2>&1 & S1=$!
$B/agent status d1 > $R/st1b.out 2>&1 & S2=$!
$B/agent status d1 > $R/st1c.out 2>&1 & S3=$!
wait $S1 $S2 $S3
grep -q 'no process, no result' $R/st1a.out; check $? 0 "status says: no process, no result"
check "$(killed d1)" 1 "three concurrent observers: exactly one 'EXIT d1: killed (no result)' line"
grep -q '^- [0-9:]* \[d1\] EXIT d1: killed (no result)' "$(journal stage-a)"; check $? 0 "…written under the agent's own tag"
for i in $(seq 1 60); do kill -0 $JW 2>/dev/null || break; sleep 0.5; done
kill -0 $JW 2>/dev/null; check $? 1 "the hub's default jwait woke"
grep -q 'EXIT d1: killed (no result)' $R/jw1.out; check $? 0 "…on that line"
$B/agent status d1 > /dev/null 2>&1; check "$(killed d1)" 1 "a later status does not write it again"
# 1b. resume: the new run is not reported as dead, and its own death is a new event
FAKE_HOLD=60 $B/agent send d1 "wake up" > $R/sd1.out 2>&1; check $? 0 "send to the killed agent resumes it"
$B/agent status d1 | grep -q ALIVE; check $? 0 "the resumed agent is alive"
check "$(killed d1)" 1 "a resumed agent is not reported as killed"
P2=$(pid_of d1); [ "$P2" != "$P" ]; check $? 0 "the resume has a new pid"
kill -KILL -- -$P2; wait_gone $P2
$B/agent status d1 > /dev/null 2>&1
check "$(killed d1)" 2 "the second run's death is journaled too (once per run)"
$B/agent status d1 > /dev/null 2>&1; check "$(killed d1)" 2 "…and only once"

# 2. jwait alone is enough: its poll writes the line (and wakes on it), a status afterwards adds nothing
spawn d2; P=$(pid_of d2)
$B/jwait --journal --stage stage-a --caller c2 --settle 1 --for 60s --match "$PAT" > $R/jw2.out 2>&1 & JW=$!
armed $R/jw2.out; check $? 0 "jwait armed (d2)"
kill -KILL -- -$P; wait_gone $P
for i in $(seq 1 60); do kill -0 $JW 2>/dev/null || break; sleep 0.5; done
kill -0 $JW 2>/dev/null; check $? 1 "jwait polled, wrote the line and woke on it"
grep -q 'EXIT d2: killed (no result)' $R/jw2.out; check $? 0 "…its output carries the EXIT line"
check "$(killed d2)" 1 "exactly one line"
$B/agent status d2 > /dev/null 2>&1 & $B/agent status d2 > /dev/null 2>&1 & wait
check "$(killed d2)" 1 "status after the jwait poll: still one"

# 3. only the CLI is killed, the wrapper survives: its own EXIT line is the one, nothing is doubled
spawn d3; P=$(pid_of d3)
C=$(pgrep -P $P | head -1); kill -KILL $C
wait_gone $P; check $? 0 "the wrapper exits after its child was killed"
$B/agent status d3 > /dev/null 2>&1 & $B/agent status d3 > /dev/null 2>&1 & wait
check "$(exits d3)" 1 "wrapper survived: exactly one EXIT line"
check "$(killed d3)" 0 "…it is the wrapper's, not an observer's"

# 4. agent stop is a known end: never reported as killed
spawn d4; $B/agent stop d4 > /dev/null; $B/agent status d4 --all > /dev/null 2>&1
$B/jwait --journal --stage stage-a --caller c4 --settle 1 --for 12s --match "EXIT d4" > $R/jw4.out 2>&1; check $? 3 "stop: jwait sees no EXIT line for the stopped agent"
check "$(exits d4)" 0 "stop: no EXIT line at all"
# 4b. a stop that leaves the role registered for a moment (the claim is made before the signal)
spawn d5; P=$(pid_of d5)
python3 - "$B" d5 <<'PY'
import importlib.machinery, importlib.util, sys
l = importlib.machinery.SourceFileLoader("agent_cli", sys.argv[1] + "/agent")
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("agent_cli", l)); l.exec_module(m)
import os
meta = m.load_meta("stage-a", sys.argv[2])
m.claim_exit("stage-a", meta)            # what `agent stop` does before the signal
os.killpg(meta["pid"], 9)
PY
wait_gone $P; $B/agent status d5 > /dev/null 2>&1
check "$(exits d5)" 0 "an exit claimed by stop is not reported by a status that sees the role still registered"

# 5. a ps that shows nothing (a sandbox) is not a death
spawn d6; P=$(pid_of d6)
BLIND=$(mktemp -d); printf '#!/bin/sh\nexit 0\n' > $BLIND/ps; chmod +x $BLIND/ps
PATH=$BLIND:$PATH $B/agent status d6 > $R/st6.out 2>&1
grep -q 'no process, no result' $R/st6.out; check $? 0 "control: status with a blind ps does call the live agent dead"
check "$(exits d6)" 0 "…but the observer, needing a certain answer, writes nothing"
kill -KILL -- -$P; wait_gone $P

# 6. a death older than a day is history
spawn d7; P=$(pid_of d7); kill -KILL -- -$P; wait_gone $P
touch -t 202001010000 $R/stage-a/agents/d7/log.jsonl
$B/agent status d7 > /dev/null 2>&1; check "$(exits d7)" 0 "a run that died long ago is not journaled on first sight"

# 7. the run wrote its result and exited between the observer's read of the log and its check of the process: not killed
spawn d8; P=$(pid_of d8)
python3 - "$B" d8 "$P" "$R" <<'PY'
import importlib.machinery, importlib.util, json, os, sys, time
b, role, pid, root = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
l = importlib.machinery.SourceFileLoader("agent_cli", b + "/agent")
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("agent_cli", l)); l.exec_module(m)
log = f"{root}/stage-a/agents/{role}/log.jsonl"
real_alive = m.alive
def alive_then_finish(meta):
    # what the agent does right after the caller read its log: DONE + a success result, then exit
    with open(log, "a") as fh:
        fh.write(json.dumps({"type": "result", "subtype": "success", "is_error": False, "result": "DONE x"}) + "\n")
    os.killpg(pid, 9)
    for _ in range(40):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            break
        time.sleep(0.1)
    return False
m.alive = alive_then_finish
m.status_line("stage-a", role)
PY
check "$(exits d8)" 0 "a result written just before the exit is re-read after the process is gone: no EXIT killed"

# 8. a read-only sandbox (a reviewer running `agent status`): no lock file can be made in the agent's directory; the observation
# is skipped, the status line is still printed, and a listing goes on past the agent
spawn aro; PA=$(pid_of aro); spawn bok
kill -KILL -- -$PA; wait_gone $PA
chmod 555 $R/stage-a/agents/aro
if touch $R/stage-a/agents/aro/.probe 2>/dev/null; then
    rm -f $R/stage-a/agents/aro/.probe; echo "PASS (running as a user that can write to a 555 directory: the read-only case cannot be made, skipped)"
else
    $B/agent status aro > $R/st-ro1.out 2> $R/st-ro1.err; check $? 0 "read-only agent dir: status exits 0"
    grep -q 'no process, no result' $R/st-ro1.out; check $? 0 "…and prints the status line"
    $B/agent status > $R/st-ro2.out 2> $R/st-ro2.err; check $? 0 "read-only agent dir: the all-agents listing exits 0"
    grep -q '^aro ' $R/st-ro2.out && grep -q '^bok .*ALIVE' $R/st-ro2.out && grep -q '^d1 ' $R/st-ro2.out; check $? 0 "…and goes on to the agents after it"
    grep -q 'Traceback\|Permission' $R/st-ro1.err $R/st-ro2.err; check $? 1 "…without an error on stderr"
    check "$(exits aro)" 0 "…and nothing was journaled: the observation was skipped"
fi
chmod 755 $R/stage-a/agents/aro
$B/agent status aro > /dev/null 2>&1; check "$(killed aro)" 1 "writable again: the death is journaled on the next look"
exit $fail
