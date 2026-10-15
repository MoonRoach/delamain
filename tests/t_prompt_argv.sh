#!/bin/bash
# The brief and every message reach the CLI through stdin, never argv (N2-01): a hub's `pkill -f "<words of a brief>"`
# matched the command lines of five agents in one night. Spawn, resume (agent send to a stopped agent) and the exit-note
# wrapper, for both engines: `ps -ww` shows no prompt text, `pkill -f <word>` leaves the agent alive, the CLI still gets
# the text (the stand-ins log what they read), and the brief footer carries the process and secret rules.
. "$(dirname "$0")/lib.sh"
new_home; export HUB_STAGE=stage-a HUB_TAG=hub-test
R=$AGENT_HUB_HOME; W=$R/w; mkdir -p $W
UNIQ=$(python3 -c 'import uuid; print(uuid.uuid4().hex[:12])')
BRIEFWORD=zebraquartz$UNIQ; MSGWORD=mangoplume$UNIQ; CBRIEF=quokkabrief$UNIQ; CMSG=quokkamsg$UNIQ
echo "brief: do the thing, the code word is $BRIEFWORD" > $W/b.md
echo "brief: do the codex thing, the code word is $CBRIEF" > $W/cb.md
pid_of(){ python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['pid'])" $R/stage-a/agents/$1/meta.json; }
wait_dead(){ for i in $(seq 1 60); do $B/agent status $1 | grep -q 'ALIVE' || return 0; sleep 0.5; done; }
# in_ps TEXT: how many processes have TEXT in their command line (the needle travels in the environment, so neither this
# helper's python nor a grep shows it in `ps`)
in_ps(){ NEEDLE="$1" python3 -c '
import os, subprocess
n = os.environ["NEEDLE"]
out = subprocess.run(["ps", "-ww", "-axo", "pid=,command="], capture_output=True, text=True).stdout
print(sum(1 for l in out.splitlines() if n in l and int(l.split(None, 1)[0]) != os.getpid()))'; }
cmd_of(){ ps -ww -o command= -p "$1"; }
cleanup(){ for r in cl cx; do $B/agent stop $r >/dev/null 2>&1; done; }
trap 'cleanup; test_cleanup' EXIT

# --- Claude: spawn
export CLAUDE_BIN=$T/fake_claude.py
FAKE_HOLD=25 $B/agent spawn --role cl --cwd $W --model haiku --brief $W/b.md > $R/sp1.out 2>&1; check $? 0 "claude: spawn"
P=$(pid_of cl)
cmd_of $P | grep -q -- "--session-id"; check $? 0 "control: the agent's own command line is in ps (the check can see it)"
[ "$(in_ps '--session-id')" -ge 1 ]; check $? 0 "control: in_ps finds a command line that has the text"
check "$(in_ps "$BRIEFWORD")" 0 "claude spawn: no brief text in any command line"
pkill -f "$BRIEFWORD"; check $? 1 "claude spawn: pkill -f <brief word> matches nothing"
kill -0 $P 2>/dev/null; check $? 0 "claude spawn: the agent is alive after the pkill"
grep -q "$BRIEFWORD" $W/prompts.log; check $? 0 "claude spawn: the CLI read the brief from stdin"
grep -q 'Stop only processes you started' $W/prompts.log; check $? 0 "footer: the process rule is there"
grep -q 'never `pkill -f` or `killall`' $W/prompts.log; check $? 0 "footer: …and names pkill -f / killall"
grep -q 'Never print environment variables or secret files' $W/prompts.log; check $? 0 "footer: the secret rule is there"
grep -q 'removed before DONE' $W/prompts.log; check $? 0 "footer: …and a secret is removed before DONE"
# --- Claude: resume (agent send to a stopped agent)
$B/agent stop cl >/dev/null; $B/roles get cl >/dev/null 2>&1; check $? 1 "claude: stopped"
FAKE_HOLD=25 $B/agent spawn --role cl --cwd $W --model haiku --brief $W/b.md > /dev/null 2>&1
P=$(pid_of cl); kill -KILL $P 2>/dev/null; wait_dead cl   # the wrapper dies: a stopped process the resume must replace
FAKE_HOLD=25 $B/agent send cl "message word $MSGWORD" > $R/sd1.out 2>&1; check $? 0 "claude: send to a stopped agent resumes"
grep -q 'resumed' $R/sd1.out; check $? 0 "claude: it was a resume"
check "$(in_ps "$MSGWORD")" 0 "claude resume: no message text in any command line"
check "$(in_ps "$BRIEFWORD")" 0 "claude resume: …and no brief text"
pkill -f "$MSGWORD"; check $? 1 "claude resume: pkill -f <message word> matches nothing"
kill -0 "$(pid_of cl)" 2>/dev/null; check $? 0 "claude resume: the agent is alive after the pkill"
grep -q "$MSGWORD" $W/prompts.log; check $? 0 "claude resume: the CLI read the message from stdin"
cmd_of "$(pid_of cl)" | grep -q -- 'exit-note'; check $? 0 "control: the wrapper (exit-note) is the process pkill would hit"
$B/agent stop cl >/dev/null

# --- Codex: spawn and resume
export CODEX_BIN=$T/fake_codex.py
FAKE_CODEX_HOLD=25 $B/agent spawn --engine codex --role cx --cwd $W --model gpt-fixture --brief $W/cb.md > $R/sp2.out 2>&1; check $? 0 "codex: spawn"
P=$(pid_of cx)
cmd_of $P | grep -q -- "fake_codex.py exec"; check $? 0 "control: the codex command line is in ps"
check "$(in_ps "$CBRIEF")" 0 "codex spawn: no brief text in any command line"
pkill -f "$CBRIEF"; check $? 1 "codex spawn: pkill -f <brief word> matches nothing"
kill -0 $P 2>/dev/null; check $? 0 "codex spawn: the agent is alive after the pkill"
grep -q "$CBRIEF" $W/codex-prompts.log; check $? 0 "codex spawn: the CLI read the brief from stdin"
grep -q 'Never print environment variables or secret files' $W/codex-prompts.log; check $? 0 "footer reaches a Codex agent too"
$B/agent stop cx >/dev/null
FAKE_CODEX_HOLD=25 $B/agent spawn --engine codex --role cx --cwd $W --model gpt-fixture --brief $W/cb.md > /dev/null 2>&1
P=$(pid_of cx); kill -KILL $P 2>/dev/null; wait_dead cx
FAKE_CODEX_HOLD=25 $B/agent send cx "message word $CMSG" > $R/sd2.out 2>&1; check $? 0 "codex: send to a stopped agent resumes"
check "$(in_ps "$CMSG")" 0 "codex resume: no message text in any command line"
pkill -f "$CMSG"; check $? 1 "codex resume: pkill -f <message word> matches nothing"
kill -0 "$(pid_of cx)" 2>/dev/null; check $? 0 "codex resume: the agent is alive after the pkill"
grep -q "$CMSG" $W/codex-prompts.log; check $? 0 "codex resume: the CLI read the message from stdin"
python3 - "$W" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1] + "/codex-argv.jsonl")]
assert rows[-1][:2] == ["exec", "resume"], rows[-1][:2]
PY
check $? 0 "codex resume: the resume form is kept (exec resume <id> -)"
$B/agent stop cx >/dev/null
exit $fail
