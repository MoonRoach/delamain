#!/bin/bash
# `hub handoff` refuses to write a draft while a sub-agent (the Agent tool) of the hub's own session still runs, on the
# fake Claude Code transcripts of subagent_fixture.py: a live one, a finished one, a foreground one that finished, a
# foreground one still running, a resumed one; --allow-live-subagents, --session, the registry fallback, a session
# that is not the hub's, a parent known to be gone.
. "$(dirname "$0")/lib.sh"
new_home; export HUB_STAGE=stage-a PYTHONDONTWRITEBYTECODE=1 CLAUDE_SESSIONS_DIR=$(mktemp -d)
R=$AGENT_HUB_HOME; export CLAUDE_CONFIG_DIR=$R/cc
HUB=33333333-cccc-4ccc-8ccc-333333333333; EXE=44444444-dddd-4ddd-8ddd-444444444444; STR=55555555-eeee-4eee-8eee-555555555555
python3 $T/subagent_fixture.py $R/fx $HUB $EXE $STR > /dev/null; check $? 0 "fixture built"
$B/roles set hub $HUB --kind cli --tag hub-7 > /dev/null; check $? 0 "registry: hub"
# keep <agent id>...: a fresh copy of the fixture holding only these sub-agents of the hub's session (mtimes kept)
keep(){ rm -rf $CLAUDE_CONFIG_DIR; cp -Rp $R/fx $CLAUDE_CONFIG_DIR
  for f in $CLAUDE_CONFIG_DIR/projects/-w-proj/$HUB/subagents/agent-*; do b=${f##*/agent-}; id=${b%%.*}
    case " $* " in *" $id "*) ;; *) rm -f $f;; esac; done; }
handoff(){ rm -f $R/H.md; $B/hub handoff --stage stage-a --out $R/H.md "$@" > $R/h.out 2> $R/h.err; }

# ---- a live background sub-agent blocks the handoff
keep alive1 done1
handoff; check $? 2 "a live sub-agent: exit 2"
[ -e $R/H.md ]; check $? 1 "…and no draft is written"
grep -q 'alive1' $R/h.err && grep -q '"run the tests"' $R/h.err; check $? 0 "…the sub-agent is listed with its id and description"
grep -Eq 'alive1  "run the tests"  last write [0-9]+ s ago' $R/h.err; check $? 0 "…and its age"
grep -q 'done1' $R/h.err; check $? 1 "negative: a finished sub-agent of the same session is not listed"
grep -q 'wait for it' $R/h.err && grep -q 'agent spawn' $R/h.err && grep -q -- '--allow-live-subagents' $R/h.err; check $? 0 "…the three ways out are named"

# ---- --allow-live-subagents goes on and writes the list into the draft's TODO
handoff --allow-live-subagents; check $? 0 "--allow-live-subagents: exit 0"
[ -s $R/H.md ]; check $? 0 "…the draft is written"
grep -q 'TODO: sub-agents of this session still running at handoff' $R/H.md && grep -q 'alive1  "run the tests"' $R/H.md; check $? 0 "…with the live sub-agent in a TODO"
grep -q 'done1' $R/H.md; check $? 1 "…but not the finished one"

# ---- finished sub-agents: nothing blocks
keep done1 fail1 killed1 late1 nots1 old1
handoff; check $? 0 "only finished, dead and old sub-agents: exit 0"
grep -q 'sub-agent' $R/h.err; check $? 1 "…nothing said about sub-agents"
grep -q 'TODO: sub-agents of this session' $R/H.md; check $? 1 "…and no TODO about them in the draft"
keep fg1 fgerr1 fg2
handoff; check $? 0 "foreground sub-agents whose Agent call returned (a result, an error): exit 0"
keep fgrun1
handoff; check $? 2 "negative: a foreground sub-agent whose Agent call has no result yet: exit 2"
grep -q 'fgrun1' $R/h.err; check $? 0 "…listed"
keep resumed1
handoff; check $? 2 "a sub-agent resumed after its completion notice is live again: exit 2"
keep noshape1
handoff; check $? 2 "no requestShape in its meta: a tool result alone does not end it: exit 2"

# ---- whose session: --session, the registry, the caller
keep alive1 lost1
handoff --session $STR; check $? 2 "--session names another session: its sub-agent (ghost1) blocks"
grep -q 'ghost1' $R/h.err && ! grep -q 'alive1' $R/h.err; check $? 0 "…and the hub's own are not listed"
handoff --session 44444444 > /dev/null; check $? 2 "usage: a --session prefix that matches no session is refused"
grep -q 'not a session I can find' $R/h.err; check $? 0 "…with a reason"
handoff; grep -q 'lost1' $R/h.err; check $? 1 "no --session: the registered hub's session; its sub-agent silent 40 min with an unknown parent is dead, not listed"
CLAUDE_CODE_SESSION_ID=$HUB handoff; grep -q 'lost1' $R/h.err && grep -q 'alive1' $R/h.err; check $? 0 "run from the hub's own session (the parent is alive by definition): the quiet one is live too"
# a session registry that lists the hub's process: running parent -> live; one that does not -> its sub-agents died
mkdir -p $CLAUDE_CONFIG_DIR/sessions
python3 -c 'import time; time.sleep(600)' $HUB claude-stand-in & SLEEPER=$!
trap 'kill $SLEEPER 2>/dev/null; test_cleanup' EXIT
echo "{\"pid\": $SLEEPER, \"sessionId\": \"$HUB\"}" > $CLAUDE_CONFIG_DIR/sessions/$SLEEPER.json
handoff; grep -q 'lost1' $R/h.err && grep -q 'alive1' $R/h.err; check $? 0 "<claude config>/sessions lists the hub's process: both live"
rm $CLAUDE_CONFIG_DIR/sessions/$SLEEPER.json
echo "{\"pid\": $SLEEPER, \"sessionId\": \"99999999-0000-4000-8000-999999999999\"}" > $CLAUDE_CONFIG_DIR/sessions/$SLEEPER.json
handoff; check $? 0 "a session registry without the hub's session (not the caller): its unfinished sub-agents died, exit 0"
kill $SLEEPER; wait $SLEEPER 2>/dev/null

# ---- the calling session's own sub-agents when it is not the registered hub (review of 283b1ed)
keep done1
CLAUDE_CODE_SESSION_ID=$STR handoff; check $? 2 "the caller is another session than the registered hub: its live sub-agent (ghost1) blocks"
grep -q 'ghost1' $R/h.err && grep -q '5555555' $R/h.err; check $? 0 "…listed, with its session"
keep alive1
CLAUDE_CODE_SESSION_ID=$STR handoff; check $? 2 "both sessions have live sub-agents: exit 2"
grep -q '\[33333333\] alive1' $R/h.err && grep -q '\[55555555\] ghost1' $R/h.err; check $? 0 "…both are listed, each with its session"
grep -q "sessions\? 33333333 and 55555555\|session 33333333 and 55555555" $R/h.err; check $? 0 "…and the message names both sessions"
keep done1
CLAUDE_CODE_SESSION_ID=$STR handoff --session $HUB; check $? 0 "negative: --session given — only that session is checked, the caller's is not"
CLAUDE_CODE_SESSION_ID=local_not-a-uuid handoff; check $? 0 "negative: a caller id that is not a uuid is ignored"
CLAUDE_CODE_SESSION_ID=$HUB handoff; check $? 0 "the caller is the registered hub: one session, nothing live, exit 0"
CLAUDE_CODE_SESSION_ID=$STR handoff --allow-live-subagents; check $? 0 "--allow-live-subagents with the caller's sub-agent: exit 0…"
grep -q '\[55555555\] ghost1\|ghost1' $R/H.md; check $? 0 "…and it is in the draft's TODO"

# ---- no hub known: the guard says so and the handoff goes on
new_home; R=$AGENT_HUB_HOME; mkdir -p $R/stage-a/coordinator/work
$B/hub handoff --stage stage-a --n 7 --out $R/H.md > $R/h.out 2> $R/h.err; check $? 0 "no hub registered, --n given: exit 0"
grep -q 'no hub session known' $R/h.err; check $? 0 "…the guard says it did not check"
CLAUDE_CODE_SESSION_ID=$STR $B/hub handoff --stage stage-a --n 7 --out $R/H3.md > $R/h.out 2> $R/h.err; check $? 2 "no hub registered, but the caller is a session with a live sub-agent: exit 2"
grep -q 'ghost1' $R/h.err; check $? 0 "…listed"
exit $fail
