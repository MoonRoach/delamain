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
run $B/await --wait -- $O/fake_wait.sh; check $? 0 "--wait stays attached and exits 0 when the word is the --ok word"
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

# 2b. a CI wait that must never read as success: the caller reads await's own exit code and output (the 26.10 incidents:
# `await --wait --ok PASSED -- gh pr checks N --watch` exited 0 with an empty output on red checks, the FAILED line being
# only in the journal). A stub gh stands in for the real one; its rows are what `gh pr checks --watch` printed then.
mkdir -p $O/ghbin
cat > $O/ghbin/gh <<'SH'
#!/bin/bash
echo "Refreshing checks status every 10 seconds. Press Ctrl+C to quit."
case "$GH_CHECKS" in
  pass) printf 'tests (ubuntu-latest)\tpass\t5m49s\thttps://github.com/o/r/actions/runs/1/job/1\t\n'; exit 0 ;;
  fail) printf 'tests (macos-latest)\tfail\t7m59s\thttps://github.com/o/r/actions/runs/1/job/2\t\n'; exit 1 ;;
  none) echo "no checks reported on the 'x' branch"; exit 1 ;;
  killed) kill -9 $$ ;;
esac
SH
chmod +x $O/ghbin/gh
ghwait(){ : > $J; GH_CHECKS=$1 PATH=$O/ghbin:$PATH $B/await --wait --ok PASSED --label "PR #1 merge" -- gh pr checks 1 --watch --fail-fast > $O/gh.out 2>&1; }
ghwait pass; check $? 0 "checks pass: await --wait exits 0"
grep -q '^- [0-9:]* \[hub-1-await\] @hub PASSED PR #1 merge — https://github.com/o/r/actions/runs/1/job/1 (exit 0, ' $O/gh.out; check $? 0 "…and prints the PASSED line"
check "$(grep -c '@hub PASSED ' $J)" 1 "…which is the journal's line"
ghwait fail; rc=$?
check $rc 3 "checks fail: await --wait exits 3, not 0 (control: it used to exit 0 here)"
grep -q '@hub FAILED PR #1 merge — https://github.com/o/r/actions/runs/1/job/2 (exit 1, ' $O/gh.out; check $? 0 "…and prints the FAILED line, the output is not empty"
check "$(grep -c 'PASSED' $O/gh.out $J | tr -d '\n')" "$O/gh.out:0$J:0" "negative: no PASSED anywhere when the checks failed"
ghwait none; check $? 3 "no checks registered: not ok"
check "$(grep -c '@hub FAILED ' $O/gh.out)" 1 "…FAILED"
ghwait killed; check $? 3 "gh killed by a signal: not ok"
grep -q '@hub FAILED .*killed by signal 9' $O/gh.out; check $? 0 "…FAILED, saying so"
: > $J; PATH=$O/ghbin:$PATH GH_CHECKS=fail $B/await --wait --on 1=CONFLICT -- gh pr checks 1 > $O/gh.out 2>&1; check $? 3 "an --on word is not the ok word either"
# detached mode is unchanged: it returns at once with 0 whatever the wait later says, and the supervisor writes no
# stdout of its own into the caller's output
: > $J; GH_CHECKS=fail PATH=$O/ghbin:$PATH $B/await --ok PASSED --label detached-fail -- gh pr checks 1 --watch > $O/gh.out 2>&1; check $? 0 "detached: await returns 0 at once"
waitline 'FAILED detached-fail'; check $? 0 "…and the verdict still lands in the journal"
check "$(grep -c '@hub' $O/gh.out)" 0 "…and not in the caller's output"

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
check $rc 3 "timeout: the line is written and the exit says it is not the ok word"
grep -q '^- [0-9:]* \[hub-1-await\] @hub TIMEOUT hang ' $O/a3.out; check $? 0 "…and the line is printed"
check "$(grep -c '@hub TIMEOUT hang .*stopped after 2s' $J)" 1 "one TIMEOUT line"
[ $el -le 20 ]; check $? 0 "the wait ended at the limit, not when the command would (${el}s)"
! kill -0 "$(cat $PIDFILE)" 2>/dev/null && ! kill -0 "$(cat $PIDFILE.child)" 2>/dev/null; check $? 0 "the command and its child were stopped"

# 4. a wait command that itself fails: non-zero exit with output, then one that cannot start, then one not found
: > $J
printf '#!/bin/bash\necho "glab: 401 Unauthorized" >&2\nexit 1\n' > $O/broken.sh; chmod +x $O/broken.sh
$B/await --wait -- $O/broken.sh >/dev/null 2>&1; check $? 3 "failing command: await --wait does not exit 0"
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

# 5b. SIGINT (Ctrl-C of an attached await): the command is stopped, one FAILED line, no orphan
: > $J; rm -f $G/* $PIDFILE*
$B/await --wait --label ctrlc -- $O/hang.sh > /dev/null 2>&1 & pid=$!
waitfor $PIDFILE || echo "hang never started"
kill -INT $pid
for _ in $(seq 1 100); do kill -0 $pid 2>/dev/null || break; sleep 0.1; done
kill -0 $pid 2>/dev/null && kill -9 $pid   # the rule under test missing: do not hang the suite
wait $pid; rc=$?
check "$(grep -c '@hub FAILED ctrlc .*interrupted by signal 2' $J)" 1 "SIGINT journals one FAILED line"
check $rc 3 "…and the supervisor exits 3 (not the ok word), not 130"
sleep 0.5; ! kill -0 "$(cat $PIDFILE.child)" 2>/dev/null; check $? 0 "…the command's process group is gone"

# 5c. a grandchild that ignores SIGTERM survives the leader's exit on SIGTERM: the group still gets SIGKILL
cat > $O/stubborn.sh <<'SH'
#!/bin/bash
( trap '' TERM; exec sh -c 'echo $$ > "$PIDFILE.grand"; exec sleep 300' ) &
echo $$ > "$PIDFILE"
wait
SH
chmod +x $O/stubborn.sh
: > $J; rm -f $PIDFILE*
$B/await --wait --timeout 1s --label stubborn -- $O/stubborn.sh > /dev/null 2>&1
check "$(grep -c '@hub TIMEOUT stubborn ' $J)" 1 "stubborn grandchild: one TIMEOUT line"
[ -s $PIDFILE.grand ]; check $? 0 "positive control: the grandchild's pid was recorded (the next check is not vacuous)"
sleep 0.5; ! kill -0 "$(cat $PIDFILE.grand)" 2>/dev/null; check $? 0 "a grandchild that ignores SIGTERM is SIGKILLed with the group"

# 5d. a signal in the supervisor's start-up (while it is still importing) still ends in a FAILED line
: > $J
# a sitecustomize that sleeps stretches the interpreter start-up, so the kill lands inside it unless `await` waits for
# the supervisor's "ready" before it returns the pid
mkdir -p $O/slow; printf 'import time\ntime.sleep(1)\n' > $O/slow/sitecustomize.py
for i in 1 2 3; do
  out=$(PYTHONPATH=$O/slow $B/await --label early$i -- $O/hang.sh); kill "$(echo "$out" | sed -n 's/^await: started supervisor pid \([0-9]*\).*/\1/p')"
done
for _ in $(seq 1 150); do [ "$(grep -c 'FAILED early' $J)" = 3 ] && break; sleep 0.1; done
check "$(grep -c 'FAILED early.*interrupted by signal 15' $J)" 3 "kill right after the start (slow interpreter start-up): all three waits journal FAILED"
pkill -f "[$]O/hang.sh" 2>/dev/null; true

# 5e. a reused --log: the link comes from this run's output, not from the older content
: > $J; printf 'old https://old.example/1\n' > $O/reused.log
$B/await --wait --log $O/reused.log -- true >/dev/null 2>&1
check "$(grep -c 'old.example' $J)" 0 "reused log: the old URL is not the link"
printf '#!/bin/bash\necho new https://new.example/2\n' > $O/newurl.sh; chmod +x $O/newurl.sh
: > $J; $B/await --wait --log $O/reused.log -- $O/newurl.sh >/dev/null 2>&1
check "$(grep -c 'https://new.example/2 (' $J)" 1 "reused log: the link is this run's URL"

# 5f. killpg answered with EPERM. macOS says that, not ESRCH, while the group holds only zombies (the leader reaped, a
# child still dying), and it used to cost the supervisor its line (rc 1, no TIMEOUT / FAILED). The race is ~1% a call and
# cannot be forced, so the kernel's answer is injected. The same EPERM from a live leader of another uid means the signal
# went nowhere: stop_group must neither hang nor claim the command was stopped. And a crash of run_wait still journals.
cat > $O/stopgroup.py <<'PY'
import argparse, importlib.machinery, importlib.util, os, signal, subprocess, sys, time
path, work = sys.argv[1:3]
sys.argv = [path]
loader = importlib.machinery.SourceFileLoader("await_mod", path)
mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("await_mod", loader)); loader.exec_module(mod)
signal.alarm(60)  # a hang is a failed check, not a stuck suite
real, seen = os.killpg, []
def deliver_then_eperm(pgid, sig):
    try:
        real(pgid, sig)
    finally:
        raise PermissionError(1, "Operation not permitted")
def refuse(pgid, sig):
    seen.append(pgid)
    raise PermissionError(1, "Operation not permitted")
def leader():
    return subprocess.Popen(["/bin/sleep", "300"], start_new_session=True)

# a) the group is zombies / gone: EPERM after the signal did its work -> the command is stopped
os.killpg = deliver_then_eperm
p = subprocess.Popen(["/bin/bash", "-c", "sleep 300 & echo $! > \"$1\"; wait", "x", work + "/child.pid"], start_new_session=True)
for _ in range(100):
    if os.path.exists(work + "/child.pid") and os.path.getsize(work + "/child.pid"):
        break
    time.sleep(0.05)
try:
    print("zombies:", repr(mod.stop_group(p)))
except Exception as e:
    print("zombies: raised", type(e).__name__)

# b) a live leader the signals cannot reach: bounded, and it says why
os.killpg, mod.KILL_GRACE_S = refuse, 0.3
p = leader(); t0 = time.monotonic()
print("live:", repr(mod.stop_group(p)), "bounded" if time.monotonic() - t0 < 5 else "slow")
real(p.pid, signal.SIGKILL); p.wait()

# c) ...and the line's detail says so instead of "stopped"
seen.clear()
args = argparse.Namespace(timeout="1s", ok="DONE")
word, detail = mod.run_wait(args, ["/bin/sleep", "300"], __import__("pathlib").Path(work + "/c.log"), {})
print("detail:", word, detail)
for pg in seen:
    try:
        real(pg, signal.SIGKILL)
    except OSError:
        pass

# d) run_wait itself blows up: supervise still writes one FAILED line
os.killpg = real
def boom(*a):
    raise RuntimeError("boom")
mod.run_wait = boom
args = argparse.Namespace(link=None, to="hub", label="crash", timeout="1s", ok="DONE")
print("crash rc:", mod.supervise(args, ["true"], __import__("pathlib").Path(work + "/d.log"), "stage-a", "hub-1-await", {}))
PY
: > $J; mkdir -p $O/sg
sg=$(python3 -I $O/stopgroup.py $B/await $O/sg 2>&1)
check "$(echo "$sg" | grep '^zombies:')" "zombies: ''" "EPERM from a group of zombies (macOS) does not abort stop_group"
check "$(echo "$sg" | grep '^live:')" "live: 'EPERM' bounded" "a live leader that EPERM keeps is reported, not waited on for ever"
echo "$sg" | grep -q '^detail: TIMEOUT could not be stopped (EPERM) after 1s, no verdict yet$'; check $? 0 "…and the TIMEOUT line says it could not be stopped"
check "$(grep -c '@hub FAILED crash .*await crashed: RuntimeError' $J)" 1 "a crash of run_wait still journals one FAILED line"
check "$(echo "$sg" | grep '^crash rc:')" "crash rc: 3" "…and supervise exits 3: FAILED is not the ok word"

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
$B/await --tag 'x]y' -- true > $O/u7.out 2>&1; check $? 2 "a tag with brackets is refused before anything is started"
$B/await --help | grep -q -- 'ci_wait --mr 12 --on'; check $? 1 "negative: the help example does not put --on after the -- (there it is the command's own flag)"
$B/await --help | grep -q -- '--on 2=TIMEOUT -- python -m scripts.ci_wait'; check $? 0 "…positive control: the right example is there"
$B/await true > $O/u5.out 2>&1; check $? 2 "no -- command"
( unset HUB_TAG; $B/await --wait -- true > $O/u6.out 2>&1 ); check $? 2 "no tag"
exit $fail
