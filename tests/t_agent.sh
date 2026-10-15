#!/bin/bash
# agent spawn/status/send/stop against a stand-in CLI (fake_claude.py): detached start, inbox while alive,
# resume after exit, unread-message replay, EXIT journal line, stop, init timeout, flags and usage errors.
. "$(dirname "$0")/lib.sh"
new_home; export HUB_STAGE=stage-a HUB_TAG=hub-test CLAUDE_BIN=$T/fake_claude.py
R=$AGENT_HUB_HOME; W=$R/w; mkdir -p $W; echo "brief: do the thing" > $W/b.md
pid_of(){ python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['pid'])" $R/stage-a/agents/$1/meta.json; }
wait_dead(){ for i in $(seq 1 40); do $B/agent status $1 | grep -q 'ALIVE' || return 0; sleep 0.5; done; }

# 1. spawn from a wrapper in its own process group, then kill that group: the agent must survive
WR=$(FAKE_HOLD=8 python3 -c "
import os, subprocess, sys
os.setsid()
r = subprocess.run(['$B/agent-spawn', '--role', 'probe', '--cwd', '$W', '--model', 'haiku', '--brief', '$W/b.md'], capture_output=True, text=True)
sys.stderr.write(r.stdout + r.stderr)
print(os.getpgid(0), r.returncode)
" 2>$R/spawn.out)
read WPG WRC <<<"$WR"; check "$WRC" 0 "spawn exit 0"
kill -KILL -- -$WPG 2>/dev/null
PID=$(pid_of probe); sleep 1
kill -0 $PID 2>/dev/null; check $? 0 "agent alive after the spawning process group was killed"
check "$(ps -o pgid= -p $PID | tr -d ' ')" "$PID" "agent leads its own process group"
$B/agent status probe | grep -q 'ALIVE'; check $? 0 "status: alive"
grep -q 'started headless agent probe' $(journal stage-a); check $? 0 "spawn journals a start line"
grep -q -- '--model haiku --effort high' $W/argv.log; check $? 0 "haiku: alias passed through, with the default effort like any model"
grep -q -- '--permission-mode bypassPermissions' $W/argv.log; check $? 0 "default permission mode"
$B/agent-send probe "inbox check" > $R/send1.out; grep -q 'inbox check' $R/stage-a/agents/probe/inbox.md; check $? 0 "send while alive -> inbox"
grep -q '@probe inbox check' $(journal stage-a); check $? 0 "send while alive -> journal @tag line"
wait_dead probe
kill -0 $PID 2>/dev/null; check $? 1 "agent finished by itself"
$B/agent status probe > $R/st2.out
grep -q 'finished (success' $R/st2.out; check $? 0 "status: finished with success"
grep -q 'last: echo: ' $R/st2.out; check $? 0 "status: last assistant line"
grep -q 'unread inbox messages 1' $R/st2.out; check $? 0 "unread message (not read, no DONE) flagged after exit"
grep -q 'ENDED probe: finished, no status word in the journal' $(journal stage-a); check $? 0 "a clean run without a status word journals ENDED (EXIT is for abnormal ends: t_agent_ended.sh)"
# 2. send after exit resumes the same session and replays the unread message
$B/agent-send probe "Answer with one word: RESUMED" > $R/send2.out; rc=$?
check $rc 0 "send while dead -> resume"
PID2=$(pid_of probe); [ "$PID2" != "$PID" ]; check $? 0 "resume started a new process"
wait_dead probe
grep -q 'inbox check' $W/prompts.log && grep -q 'RESUMED' $W/prompts.log; check $? 0 "resume prompt carries the unread message and the new one"
SID=$(python3 -c "import json;print(json.load(open('$R/stage-a/agents/probe/meta.json'))['session_id'])")
N_INIT=$(grep -c '"subtype": "init"' $R/stage-a/agents/probe/log.jsonl)
[ "$N_INIT" -ge 2 ]; check $? 0 "spawn and resume both in one log ($N_INIT init events)"
check "$(grep '"subtype": "init"' $R/stage-a/agents/probe/log.jsonl | grep -c "$SID")" "$N_INIT" "every run is the same session id"
grep -q -- "--resume $SID" $W/argv.log; check $? 0 "resume uses --resume <session id>"
# 3. stop a live one
FAKE_HOLD=60 $B/agent-spawn --role probe2 --cwd $W --model sonnet --brief $W/b.md > /dev/null; check $? 0 "spawn probe2"
P3=$(pid_of probe2); sleep 1
tail -1 $W/argv.log | grep -q -- '--effort high'; check $? 0 "default effort high"
$B/agent-stop probe2; check $? 0 "stop exit 0"
kill -0 $P3 2>/dev/null; check $? 1 "stopped process is gone"
$B/roles get probe2 >/dev/null 2>&1; check $? 1 "stopped role retired"
$B/agent-send probe2 "more" >/dev/null 2>&1; check $? 1 "negative: send to a stopped agent refused"
$B/agent-stop probe >/dev/null; $B/agent-status nobody >/dev/null 2>&1; check $? 1 "negative: status of unknown agent"
$B/agent-spawn --role x --cwd $W --model opus --brief $W/nope.md >/dev/null 2>&1; check $? 2 "usage: missing brief"
$B/agent-spawn --role x --cwd $W --model gpt --brief $W/b.md >/dev/null 2>&1; check $? 2 "usage: unknown model alias"
HUB_TAG=hub-3 $B/agent-spawn --role x --tag hub-3/x --cwd $W --model opus --brief $W/b.md >/dev/null 2>&1; check $? 2 "usage: a sub-tag of the caller's own tag is refused"
# 3b. a stage without an owner-approved plan: spawn warns on stderr, never refuses; a recorded plan silences it
$B/agent-spawn --role noplan --cwd $W --model haiku --brief $W/b.md > $R/np1.out 2> $R/np1.err; check $? 0 "no plan: spawn still succeeds"
grep -q 'stage stage-a has no owner-approved plan' $R/np1.err; check $? 0 "no plan: spawn warns once on stderr"
check "$(grep -c 'no owner-approved plan' $R/np1.err)" 1 "no plan: exactly one warning line"
wait_dead noplan; $B/agent-stop noplan >/dev/null
$B/ask plan --stage stage-a "Do the thing" >/dev/null
$B/agent-spawn --role withplan --cwd $W --model haiku --brief $W/b.md > $R/np2.out 2> $R/np2.err; check $? 0 "plan on record: spawn succeeds"
grep -q 'no owner-approved plan' $R/np2.err; check $? 1 "plan on record: no warning"
wait_dead withplan; $B/agent-stop withplan >/dev/null
# Keep minimal-mode checks in the throwaway home even when the laptop has a real default stage.
mkdir -p "$R/default"
HUB_STAGE=default $B/agent-spawn --role dflt --cwd $W --model haiku --brief $W/b.md > $R/np3.out 2> $R/np3.err; check $? 0 "default stage: spawn succeeds"
grep -q 'no owner-approved plan' $R/np3.err; check $? 1 "default stage (minimal mode): no warning"
sleep 1; $B/agent-stop dflt --stage default >/dev/null
# 4. configurable defaults: model map, default effort, permission mode
AGENT_HUB_MODEL_MAP="sonnet=claude-sonnet-test-1" AGENT_HUB_DEFAULT_EFFORT=xhigh AGENT_HUB_PERMISSION_MODE=acceptEdits \
  $B/agent-spawn --role cfg --cwd $W --model sonnet --brief $W/b.md >/dev/null; check $? 0 "spawn with env defaults"
tail -1 $W/argv.log | grep -q -- '--model claude-sonnet-test-1 --effort xhigh .*--permission-mode acceptEdits'; check $? 0 "model map, default effort and permission mode reach the CLI"
wait_dead cfg; $B/agent-stop cfg >/dev/null
# 4b. background sub-agents of a headless run: no 10-minute CLI ceiling by default, configurable, validated
tail -1 $W/env.log | grep -qx 'CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0'; check $? 0 "default: the run waits for its background sub-agents (ceiling 0)"
CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=5000 AGENT_HUB_BG_WAIT_CEILING_MS=900000 \
  $B/agent-spawn --role bgw --cwd $W --model haiku --brief $W/b.md >/dev/null; check $? 0 "spawn with a ceiling setting"
tail -1 $W/env.log | grep -qx 'CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=900000'; check $? 0 "AGENT_HUB_BG_WAIT_CEILING_MS reaches the CLI, the caller's own value does not"
wait_dead bgw; $B/agent-stop bgw >/dev/null
N_ENV=$(wc -l < $W/env.log)
AGENT_HUB_BG_WAIT_CEILING_MS=10m $B/agent-spawn --role bgx --cwd $W --model haiku --brief $W/b.md > $R/o4b.out 2>&1; rc=$?
check $rc 2 "negative: a ceiling that is not milliseconds is a usage error"
check "$(wc -l < $W/env.log)" "$N_ENV" "…and no CLI was started"
[ ! -e $R/stage-a/agents/bgx ]; check $? 0 "…and no agent directory was created"
CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=5000 $B/agent-spawn --role bgc --cwd $W --model haiku --brief $W/b.md >/dev/null
tail -1 $W/env.log | grep -qx 'CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0'; check $? 0 "the caller's own CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS alone does not leak (0 wins)"
# 4c. idle compaction (CLI 2.1.290+): a detached worker waiting on a jwait is never compacted behind its hub's back; the caller's value wins
tail -2 $W/env.log | head -1 | grep -qx 'CLAUDE_CODE_IDLE_COMPACT_MIN_TOKENS=100000000'; check $? 0 "default: the worker's CLI gets an idle-compaction minimum above any window"
CLAUDE_CODE_IDLE_COMPACT_MIN_TOKENS=300000 $B/agent-spawn --role idc --cwd $W --model haiku --brief $W/b.md >/dev/null
tail -2 $W/env.log | head -1 | grep -qx 'CLAUDE_CODE_IDLE_COMPACT_MIN_TOKENS=300000'; check $? 0 "negative: the caller's own CLAUDE_CODE_IDLE_COMPACT_MIN_TOKENS is kept"
wait_dead bgc
INBOX_BEFORE=$(cat $R/stage-a/agents/bgc/inbox.md); N_ENV=$(wc -l < $W/env.log)
AGENT_HUB_BG_WAIT_CEILING_MS=x $B/agent-send bgc "resume me" > $R/o4c.out 2>&1; check $? 2 "negative: resume with a bad ceiling is a usage error"
[ "$(cat $R/stage-a/agents/bgc/inbox.md)" = "$INBOX_BEFORE" ] && [ "$(wc -l < $W/env.log)" = "$N_ENV" ]; check $? 0 "…before the message is queued or a CLI started"
AGENT_HUB_BG_WAIT_CEILING_MS=777 $B/agent-send bgc "resume me" > /dev/null; check $? 0 "resume a finished agent"
tail -1 $W/env.log | grep -qx 'CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=777'; check $? 0 "the resumed run gets the ceiling too"
wait_dead bgc; $B/agent-stop bgc >/dev/null
# 5. a CLI that dies without an init event is a failed spawn, and no role is recorded
FAKE_CLAUDE=die $B/agent-spawn --role d --cwd $W --model sonnet --brief $W/b.md > $R/o5.out 2>&1; rc=$?
check $rc 1 "spawn fails when claude never starts"
$B/roles get d >/dev/null 2>&1; check $? 1 "…and no role is recorded"
# 6. the init wait is env-overridable (default 120 s); a start that never inits is killed and reported
AGENT_INIT_TIMEOUT=3 FAKE_CLAUDE=hang $B/agent-spawn --role h --cwd $W --model sonnet --brief $W/b.md > $R/o6.out 2>&1; rc=$?
check $rc 1 "no init within AGENT_INIT_TIMEOUT → spawn fails"
grep -q 'no init event in 3 s' $R/o6.out; check $? 0 "…the message names the timeout"
grep -q 'return int(hc.setting("AGENT_INIT_TIMEOUT", cwd=cwd) or 120)' $B/agent; check $? 0 "default init wait is 120 s"
# 7. a 60 KB brief: still seen as alive (the session id stays at the head of the command line)
python3 -c "print('brief line '*6000)" > $W/big.md
FAKE_HOLD=6 $B/agent-spawn --role big --cwd $W --model sonnet --brief $W/big.md >/dev/null 2>&1; check $? 0 "spawn with a 60 KB brief"
$B/agent-status big | grep -q 'ALIVE'; check $? 0 "long-argv agent reads as alive"
$B/agent-stop big >/dev/null
# 8. a message the agent read (tool call on inbox.md) or a run ending in DONE is not "unread"
FAKE_HOLD=4 FAKE_READ_INBOX=1 $B/agent-spawn --role rd --cwd $W --model sonnet --brief $W/b.md >/dev/null 2>&1
$B/agent-send rd "hub answer" >/dev/null; wait_dead rd
$B/agent-status rd | grep -q 'unread'; check $? 1 "inbox read in the log → not flagged unread"
FAKE_HOLD=4 FAKE_FINAL="DONE work/dn-REPORT.md" $B/agent-spawn --role dn --cwd $W --model sonnet --brief $W/b.md >/dev/null 2>&1
$B/agent-send dn "hub answer" >/dev/null; wait_dead dn
$B/agent-status dn | grep -q 'unread'; check $? 1 "run ended with DONE → not flagged unread"
FAKE_HOLD=4 $B/agent-spawn --role nr --cwd $W --model sonnet --brief $W/b.md >/dev/null 2>&1
$B/agent-send nr "hub answer" >/dev/null; wait_dead nr
$B/agent-status nr | grep -q 'unread inbox messages 1'; check $? 0 "positive control: not read, no DONE → flagged"
for r in rd dn nr; do $B/agent-stop $r >/dev/null 2>&1; done
# 9. a status word journaled by the agent suppresses the EXIT line
cat > $W/jl.md <<'B2'
brief
B2
FAKE_HOLD=1 $B/agent-spawn --role quiet --tag hub-test-quiet --cwd $W --model sonnet --brief $W/jl.md >/dev/null 2>&1
$B/jlog --tag hub-test-quiet "DONE report at work/quiet-REPORT.md" >/dev/null
wait_dead quiet; sleep 1
grep -q 'EXIT quiet' $(journal stage-a); check $? 1 "a DONE line in the journal → no EXIT line"
$B/agent-stop quiet >/dev/null 2>&1
exit $fail
