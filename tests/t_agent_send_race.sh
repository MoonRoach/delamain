#!/bin/bash
# `agent send` is one critical section per agent (a lock beside meta.json): a message queued while another send's resume
# is still waiting for its init event is not lost when the resume saves its meta; two sends to a dead agent resume it
# once; every run reads a prompt file of its own that is never rewritten.
. "$(dirname "$0")/lib.sh"
new_home; export HUB_STAGE=stage-a HUB_TAG=hub-test CLAUDE_BIN=$T/fake_claude.py
R=$AGENT_HUB_HOME; W=$R/w; mkdir -p $W; echo "brief: send race, the code word is wolfsbane" > $W/b.md
M=$R/stage-a/agents
meta(){ python3 -c "import json,sys;m=json.load(open(sys.argv[1]));print(eval(sys.argv[2]))" $M/$1/meta.json "$2"; }
wait_gone(){ for i in $(seq 1 40); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.25; done; return 1; }
trap 'for r in s1 s2; do $B/agent stop $r >/dev/null 2>&1; done; test_cleanup' EXIT

# 1. a message B queued while send A's resume waits for init survives A's save of the meta
FAKE_HOLD=60 $B/agent spawn --role s1 --cwd $W --model haiku --brief $W/b.md > $R/sp1.out 2>&1; check $? 0 "spawn s1"
P=$(meta s1 "m['pid']"); kill -KILL -- -$P; wait_gone $P
FAKE_INIT_DELAY=4 FAKE_HOLD=60 $B/agent send s1 "message A" > $R/sa.out 2>&1 & SA=$!
for i in $(seq 1 60); do [ "$(meta s1 "len(m['runs'])")" = 2 ] && break; sleep 0.1; done
check "$(meta s1 "len(m['runs'])")" 2 "send A's resume is under way (its run is on record, init not yet seen)"
FAKE_HOLD=60 $B/agent send s1 "message B" > $R/sb.out 2>&1; check $? 0 "send B"
wait $SA; check $? 0 "send A finished"
grep -q 'resumed' $R/sa.out; check $? 0 "A resumed the session"
grep -q 'queued in its inbox' $R/sb.out; check $? 0 "B found a live agent and queued"
meta s1 "' '.join(u['msg'] for u in m['inbox_unread'])" | grep -q 'message B'; check $? 0 "B is still in inbox_unread after A's resume saved its meta"
grep -q 'message B' $M/s1/inbox.md; check $? 0 "…and in inbox.md"
check "$(meta s1 "len(m['runs'])")" 2 "B did not start a second resume"

# 2. two sends to a dead agent at once: one resume, the other queues; no message is lost
P=$(meta s1 "m['pid']"); kill -KILL -- -$P; wait_gone $P
FAKE_HOLD=60 $B/agent send s1 "message C" > $R/sc.out 2>&1 &
FAKE_HOLD=60 $B/agent send s1 "message D" > $R/sd.out 2>&1 &
wait
check "$(meta s1 "sum(1 for r in m['runs'] if r['kind']=='resume')")" 2 "two sends to a dead agent: one resume (A's and one more, not two more)"
check "$(grep -l 'queued in its inbox' $R/sc.out $R/sd.out | wc -l | tr -d ' ')" 1 "…and the other send queued its message"
grep -q 'message C' $M/s1/inbox.md && grep -q 'message D' $M/s1/inbox.md; check $? 0 "both messages are in inbox.md"
grep -c 'message [CD]' $W/prompts.log | grep -qv '^0$'; check $? 0 "the resume's CLI read its message on stdin"

# 3. one immutable prompt file per run, each holding exactly what that run read
[ ! -e $M/s1/prompt.txt ]; check $? 0 "no shared prompt.txt"
check "$(ls $M/s1/prompt-*.txt | wc -l | tr -d ' ')" "$(meta s1 "len(m['runs'])")" "one prompt file per run"
python3 - "$M/s1" <<'PY'
import json, os, sys
d = sys.argv[1]
m = json.load(open(d + "/meta.json"))
files = [r["prompt"] for r in m["runs"]]
assert len(set(files)) == len(files), files
assert "wolfsbane" in open(f"{d}/{files[0]}").read(), "the spawn prompt file holds the brief"
for r in m["runs"][1:]:
    assert "wolfsbane" not in open(f"{d}/{r['prompt']}").read(), "a resume prompt is its message, not the brief"
assert all(oct(os.stat(f"{d}/{f}").st_mode & 0o777) == "0o600" for f in files)
PY
check $? 0 "each run record names its own file; brief in the first, message in a resume; mode 0600"
exit $fail
