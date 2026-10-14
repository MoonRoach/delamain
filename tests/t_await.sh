#!/bin/bash
# await: a wait command runs detached; exactly one journal line on its terminal outcome, none on progress; outcome words,
# link, own timeout, a failing / unstartable / interrupted wait command, the hub's jwait wakes once on that line.
. "$(dirname "$0")/lib.sh"
new_home; export HUB_STAGE=stage-a HUB_TAG=hub-1; O=$AGENT_HUB_HOME
J=$(journal stage-a)
lines(){ [ -e "$J" ] || { echo 0; return; }; grep -c "$1" "$J" || true; }
# waitfor FILE [secs]: bounded wait for a file to exist
waitfor(){ local i; for i in $(seq 1 $(( ${2:-30} * 10 ))); do [ -e "$1" ] && return 0; sleep 0.1; done; return 1; }
# waitline PATTERN: bounded wait for a journal line
waitline(){ local i; for i in $(seq 1 300); do grep -q "$1" "$J" 2>/dev/null && return 0; sleep 0.1; done; return 1; }

# a fake wait command: three progress steps, each held until the test releases it, then a verdict from $EXIT
G=$O/gate; mkdir -p $G
cat > $O/fake_wait.sh <<'SH'
#!/bin/bash
for i in 1 2 3; do
  echo "step $i: pipeline running https://ci.example/pipelines/$i"
  touch "$GATE/step$i"
  for _ in $(seq 1 300); do [ -e "$GATE/ack$i" ] && break; sleep 0.1; done
done
echo "result https://ci.example/mr/12 ok"
exit ${EXIT:-0}
SH
chmod +x $O/fake_wait.sh

# 1. demonstration: 3 progress steps, then success -> no line on progress, exactly one on the result
export GATE=$G EXIT=0
t0=$(date +%s)
$B/await --ok MERGED --label "MR !12" -- $O/fake_wait.sh > $O/a1.out 2>&1; rc=$?
el=$(( $(date +%s) - t0 ))
check $rc 0 "detached await returns at once"
[ $el -le 5 ]; check $? 0 "…without waiting for the command (${el}s)"
grep -q '^await: started supervisor pid [0-9]* for "MR !12"; log ' $O/a1.out; check $? 0 "says where the log is"
waitfor $G/step1 && touch $G/ack1; waitfor $G/step2 && touch $G/ack2; waitfor $G/step3 || echo "step3 never reached"
check "$(lines '\[hub-1-await\]')" 0 "negative: three progress steps wrote no journal line"
check "$(grep -c step $(grep -o 'log [^;]*' $O/a1.out | head -1 | cut -c5-))" 3 "progress is in the log, not the journal"
touch $G/ack3
waitline '\[hub-1-await\]' ; check $? 0 "terminal outcome journaled"
sleep 1
check "$(grep -c '' $J)" 1 "exactly one journal line for the whole wait"
grep -q '^- [0-9:]* \[hub-1-await\] @hub MERGED MR !12 — https://ci.example/mr/12 (exit 0, ' $J; check $? 0 "line: @hub, status word, label, last URL, exit"
grep -q 'log .*/stage-a/coordinator/work/await/.*\.log)$' $J; check $? 0 "line names the log under the stage's work dir"

# 2. outcome words: default ok word, exit codes, --on, explicit --link beats the log
run(){ : > $J; rm -f $G/*; touch $G/ack1 $G/ack2 $G/ack3; "$@" > /dev/null 2>&1; }
run $B/await --wait -- $O/fake_wait.sh; check $? 0 "--wait stays attached and exits 0 when the line is written"
check "$(grep -c '@hub DONE ' $J)" 1 "exit 0 without --ok -> DONE"
EXIT=1 run $B/await --wait -- $O/fake_wait.sh
check "$(grep -c '@hub FAILED .*(exit 1, ' $J)" 1 "exit 1 -> FAILED"
EXIT=3 run $B/await --wait --on 3=CONFLICT --on 4=BLOCKED -- $O/fake_wait.sh
check "$(grep -c '@hub CONFLICT .*(exit 3, ' $J)" 1 "--on 3=CONFLICT -> CONFLICT"
EXIT=3 run $B/await --wait -- $O/fake_wait.sh
check "$(grep -c '@hub FAILED .*(exit 3, ' $J)" 1 "negative: an unmapped code stays FAILED"
EXIT=124 run $B/await --wait -- $O/fake_wait.sh
check "$(grep -c '@hub TIMEOUT .*(exit 124, ' $J)" 1 "exit 124 -> TIMEOUT"
EXIT=2 run $B/await --wait --on 2=TIMEOUT -- $O/fake_wait.sh
check "$(grep -c '@hub TIMEOUT .*(exit 2, ' $J)" 1 "--on overrides the default (ci_wait's 2)"
EXIT=1 run $B/await --wait --link https://git.example/mr/9 -- $O/fake_wait.sh
check "$(grep -c '— https://git.example/mr/9 (' $J)" 1 "--link beats the URL in the output"
check "$(grep -c '' $J)" 1 "…and still one line"

# 3. the supervisor's own timeout: the command is stopped (its process group), one TIMEOUT line
cat > $O/hang.sh <<'SH'
#!/bin/bash
sleep 300 &
echo $! > "$PIDFILE.child"
echo $$ > "$PIDFILE"
wait
SH
chmod +x $O/hang.sh
: > $J; export PIDFILE=$O/hang.pid
t0=$(date +%s)
$B/await --wait --timeout 2s --label hang -- $O/hang.sh > $O/a3.out 2>&1; rc=$?
el=$(( $(date +%s) - t0 ))
check $rc 0 "timeout: the line is written"
check "$(grep -c '@hub TIMEOUT hang .*stopped after 2s' $J)" 1 "one TIMEOUT line"
[ $el -le 20 ]; check $? 0 "the wait ended at the limit, not when the command would (${el}s)"
! kill -0 "$(cat $PIDFILE)" 2>/dev/null && ! kill -0 "$(cat $PIDFILE.child)" 2>/dev/null; check $? 0 "the command and its child were stopped"

# 4. a wait command that itself fails: non-zero exit with output, then one that cannot start, then one not found
: > $J
printf '#!/bin/bash\necho "glab: 401 Unauthorized" >&2\nexit 1\n' > $O/broken.sh; chmod +x $O/broken.sh
$B/await --wait -- $O/broken.sh >/dev/null 2>&1; check $? 0 "failing command: await itself succeeds"
check "$(grep -c '@hub FAILED .*(exit 1, ' $J)" 1 "failing command -> FAILED"
printf '#!/nonexistent/interpreter\n' > $O/nostart.sh; chmod +x $O/nostart.sh
: > $J; $B/await --wait -- $O/nostart.sh >/dev/null 2>&1
check "$(grep -c '@hub FAILED .*could not start' $J)" 1 "command that cannot start -> FAILED, not silence"
: > $J; $B/await --wait -- $O/no-such-command-xyz > $O/a4.out 2>&1; check $? 2 "command not found: usage error at once"
grep -q 'not found' $O/a4.out; check $? 0 "…saying so"; check "$(grep -c '' $J)" 0 "…and nothing journaled"
: > $J
EXIT=0 $B/await --wait -- /bin/sh -c 'kill -9 $$' >/dev/null 2>&1
check "$(grep -c '@hub FAILED .*killed by signal 9' $J)" 1 "command killed by a signal -> FAILED"

# 5. the supervisor is stopped by SIGTERM: the command is stopped too, one FAILED line
: > $J; rm -f $G/* $PIDFILE*
out=$($B/await --label stopme -- $O/hang.sh); pid=$(echo "$out" | sed -n 's/^await: started supervisor pid \([0-9]*\).*/\1/p')
waitfor $PIDFILE || echo "hang never started"
kill $pid
waitline 'FAILED stopme'; check $? 0 "SIGTERM on the supervisor journals FAILED"
check "$(grep -c '' $J)" 1 "…once"; grep -q 'interrupted by signal 15' $J; check $? 0 "…saying why"
sleep 0.5; ! kill -0 "$(cat $PIDFILE.child)" 2>/dev/null; check $? 0 "…and the command's process group is gone"

# 6. the hub's own jwait (digest filter) wakes once on the line, though the line is written under the hub's tag family
: > $J; rm -f $G/*; export EXIT=0
$B/jlog --tag old "old line" >/dev/null
( armed $O/j1.out
  $B/await --ok MERGED --label "MR !7" -- $O/fake_wait.sh >/dev/null
  for i in 1 2 3; do waitfor $G/step$i; touch $G/ack$i; done ) &
$B/jwait --journal --tag hub-1 --tag hub --hub-events --settle 1 --for 60s > $O/j1.out 2>&1; rc=$?
check $rc 0 "the hub's jwait wakes on the await line"
check "$(grep -c 'NEW: ' $O/j1.out)" 1 "…with one block"
check "$(grep -c '@hub MERGED MR !7' $O/j1.out)" 1 "…holding exactly that line"
wait

# 7. usage errors
$B/await --on 3=conflict -- true > $O/u1.out 2>&1; check $? 2 "bad --on word"
$B/await --on x -- true > $O/u2.out 2>&1; check $? 2 "bad --on shape"
$B/await --ok merged -- true > $O/u3.out 2>&1; check $? 2 "bad --ok word"
$B/await --timeout soon -- true > $O/u4.out 2>&1; check $? 2 "bad --timeout"
$B/await true > $O/u5.out 2>&1; check $? 2 "no -- command"
( unset HUB_TAG; $B/await --wait -- true > $O/u6.out 2>&1 ); check $? 2 "no tag"
exit $fail
