#!/bin/bash
# gh-ci-wait: the checks of a GitHub PR decide by their buckets, not by gh's exit code (gh pr checks exits 0 on a CANCELLED
# check, PR #140, 26.10). A stub `gh` stands in; under `await --wait` the result is the verdict line and the exit code.
. "$(dirname "$0")/lib.sh"
new_home; export HUB_STAGE=stage-a HUB_TAG=hub-1; O=$AGENT_HUB_HOME
J=$(journal stage-a)
mkdir -p $O/bin
# the stub answers like gh 2.92: `--json` prints the checks and exits 0 whatever they say; the table form (what
# `--watch` uses) exits 0 on a cancelled check. STEPS: files $O/step.N hold successive JSON answers (the last repeats).
cat > $O/bin/gh <<'SH'
#!/bin/bash
n=$(cat "$GH_STATE" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$GH_STATE"
f="$GH_STEPS.$n"; [ -e "$f" ] || f="$GH_STEPS.last"
case "$*" in
  *--json*) cat "$f"; exit "${GH_RC:-0}" ;;
  *) echo "Refreshing checks status every 10 seconds. Press Ctrl+C to quit."
     python3 -c 'import json,sys; [print("%s\t%s\t0\t%s" % (c["name"], "fail" if c["bucket"]=="cancel" else c["bucket"], c["link"])) for c in json.load(open(sys.argv[1]))]' "$f"
     exit 0 ;;
esac
SH
chmod +x $O/bin/gh
export GH_STATE=$O/state GH_STEPS=$O/steps
U=https://github.com/o/r/actions/runs/1/job
chk(){ printf '{"name":"%s","bucket":"%s","state":"X","link":"%s/%s"}' "$1" "$2" "$U" "$3"; }
# answer FILE-SUFFIX JSON-LIST-ITEMS...: write one canned answer
answer(){ local s=$1; shift; local IFS=,; echo "[$*]" > "$GH_STEPS.$s"; }
reset(){ rm -f $GH_STATE $GH_STEPS.*; }
run(){ PATH=$O/bin:$PATH $B/gh-ci-wait "$@" > $O/w.out 2>&1; }

reset; answer last "$(chk ubuntu pass 1)" "$(chk macos pass 2)"
run 12 --interval 0.1s; check $? 0 "all pass: exit 0"
check "$(tail -2 $O/w.out | head -1)" "RESULT: passed (2 of 2)" "…and says so"
check "$(tail -1 $O/w.out)" "$U/2" "…the last line is a URL (await's link)"
reset; answer last "$(chk ubuntu pass 1)" "$(chk macos fail 2)"
run 12 --interval 0.1s; check $? 1 "a failed check: exit 1"
check "$(tail -1 $O/w.out)" "$U/2" "…the link is the failed check"
reset; answer last "$(chk ubuntu pass 1)" "$(chk macos cancel 2)"
GH_RC=0 run 12 --interval 0.1s; check $? 1 "a CANCELLED check: exit 1 although gh itself exits 0"
grep -q 'RESULT: failed (macos: cancel' $O/w.out; check $? 0 "…naming the check"
reset; answer last "$(chk ubuntu pass 1)" "$(chk macos weird 2)"
run 12 --interval 0.1s; check $? 1 "an unknown bucket is not a pass"
reset; answer 1 "$(chk ubuntu pending 1)" "$(chk macos pending 2)"; answer 2 "$(chk ubuntu pass 1)" "$(chk macos pending 2)"; answer last "$(chk ubuntu pass 1)" "$(chk macos pass 2)"
run 12 --interval 0.1s; check $? 0 "pending, then pass: waits, exit 0"
check "$(cat $GH_STATE)" 3 "…polled three times"
reset; answer 1 "$(chk ubuntu pending 1)" "$(chk macos pending 2)"; answer last "$(chk ubuntu pass 1)" "$(chk macos cancel 2)"
run 12 --interval 0.1s; check $? 1 "pending, then cancelled: exit 1"
reset; answer last "$(chk ubuntu pass 1)" "$(chk macos pending 2)"
run 12 --interval 0.1s --timeout 1s; check $? 124 "checks that stay pending: the deadline, exit 124"
grep -q 'RESULT: timeout' $O/w.out; check $? 0 "…saying so"
reset; echo '[]' > $GH_STEPS.last
run 12 --interval 0.1s --grace 1s; check $? 3 "no checks registered: exit 3 after the grace"
reset; answer 1; echo '[]' > $GH_STEPS.1; answer last "$(chk ubuntu pass 1)"
run 12 --interval 0.1s --grace 5s; check $? 0 "no checks yet, then they appear and pass: exit 0 (the grace is not a failure)"
reset; echo 'no checks reported on the '"'"'x'"'"' branch' > $GH_STEPS.last
GH_RC=1 run 12 --interval 0.1s --grace 1s; check $? 3 "gh's 'no checks reported' text is the same answer"
reset; answer last "$(chk ubuntu skipping 1)"
run 12 --interval 0.1s; check $? 3 "everything skipped: nothing passed, not ok"
reset; echo 'HTTP 502' > $GH_STEPS.last
GH_RC=1 run 12 --interval 0.1s; check $? 2 "gh unusable five polls in a row: exit 2"
check "$(cat $GH_STATE)" 5 "…after exactly five polls"
reset; answer 1 "$(chk ubuntu pass 1)"; echo 'HTTP 502' > $GH_STEPS.2; answer last "$(chk ubuntu pass 1)"
GH_RC=0 run 12 --interval 0.1s; check $? 0 "one answer from gh and the next fine: not an error"
run 12 --interval soon; check $? 2 "bad --interval: usage"

# under await --wait: the verdict line and the exit code. Control: the old recipe, gh pr checks --watch, called a
# cancelled check a success (the stub's table form exits 0 on it exactly like gh 2.92)
awaitc(){ : > $J; PATH=$O/bin:$PATH $B/await --wait --ok PASSED --label "PR #12" "$@" > $O/a.out 2>&1; }
reset; answer last "$(chk ubuntu pass 1)" "$(chk macos cancel 2)"
awaitc -- gh pr checks 12 --watch --fail-fast; check $? 0 "control: gh pr checks --watch on a cancelled check exits 0 (the trap)"
awaitc -- $B/gh-ci-wait 12 --interval 0.1s; check $? 3 "gh-ci-wait under await --wait: a cancelled check exits 3"
grep -q "^@hub FAILED PR #12 — $U/2 (exit 1, " $O/a.out; check $? 0 "…prints FAILED with the cancelled check's link"
check "$(grep -c PASSED $O/a.out $J | tr -d '\n')" "$O/a.out:0$J:0" "…and PASSED nowhere"
reset; answer last "$(chk ubuntu pass 1)" "$(chk macos pass 2)"
awaitc -- $B/gh-ci-wait 12 --interval 0.1s; check $? 0 "gh-ci-wait under await --wait: all pass, exit 0"
grep -q "^@hub PASSED PR #12 — $U/2 (exit 0, " $O/a.out; check $? 0 "…PASSED with the link"
reset; answer last "$(chk ubuntu pending 1)"
awaitc --timeout 1s -- $B/gh-ci-wait 12 --interval 0.1s; check $? 3 "pending for ever under await --timeout: exit 3"
grep -q '^@hub TIMEOUT PR #12 ' $O/a.out; check $? 0 "…TIMEOUT"
exit $fail
