#!/bin/bash
# The watchdog (bin/watchdog): one tick looks at every stage. R1 a dead agent → EXIT, R2 an overdue question with a default
# → one @hub line, R3 a silent hub with lines addressed to it waiting 15 min (or a night-queue item) and no jwait of its
# own → woken (a headless hub by `agent send`, an idle `claude --bg` hub by `claude stop` + `claude --bg --resume <same
# id>` with no flag, Desktop / terminal / not-bg hubs only notified), R4 a last turn that died on an API error. Safety:
# never a successor, do-not-wake marker, one wake per episode with backoff, a pending handoff, a replaced hub, one tick at
# a time, nothing leaves the machine but the stage name and counts, a dry run writes nothing. Stand-in CLIs only.
. "$(dirname "$0")/lib.sh"
new_home; R=$AGENT_HUB_HOME
export HOME=$R/home; mkdir -p "$HOME"
export CLAUDE_CONFIG_DIR=$R/claude-home CLAUDE_SESSIONS_DIR=$R/desktop
export CLAUDE_BIN=$T/fake_claude_wd.py FAKE_WD_ROWS=$R/rows.json FAKE_WD_LOG=$R/claude.log
export AGENT_HUB_WATCHDOG=on
unset AGENT_HUB_NOTIFY_CMD AGENT_HUB_WATCHDOG_NOW FX_NOW
FB=$R/fakebin; mkdir -p "$FB"; : > "$R/notify.log"; : > "$R/remote.log"; : > "$R/claude.log"; : > "$R/claude.all"
for n in osascript notify-send; do printf '#!/bin/sh\necho "local: $*" >> "%s"\n' "$R/notify.log" > "$FB/$n"; chmod +x "$FB/$n"; done
printf '#!/bin/sh\necho "remote: $*" >> "%s"\n' "$R/remote.log" > "$FB/remotecmd"; chmod +x "$FB/remotecmd"
export PATH="$FB:$PATH"
FX(){ python3 "$T/watchdog_fixture.py" "$@"; }
WD(){ "$B/watchdog" "$@"; }
J(){ echo "$R/$1/coordinator/work/journal-$(today).md"; }
nl(){ [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }          # lines of a file, 0 when absent
count(){ local n; n=$(grep -c -- "$1" "$2" 2>/dev/null); echo "${n:-0}"; }
sid_of(){ python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['session_id'])" "$R/$1/agents/$2/meta.json"; }
state_val(){ python3 - "$R/.state/watchdog/state.json" "$@" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for k in sys.argv[2:]:
    d = d.get(k) if isinstance(d, dict) else None
print("" if d is None else d)
PY
}
S1=11111111-1111-4111-8111-111111111111; S2=22222222-2222-4222-8222-222222222222; S3=33333333-3333-4333-8333-333333333333
CWD=$R/hubcwd; mkdir -p "$CWD"; export FX_CWD=$CWD
WAITER=; HOLDER=; LP=
cleanup(){ local f d; for f in $R/*/agents/*/meta.json; do d=$(dirname "$f"); "$B/agent" stop --stage "$(basename "$(dirname "$(dirname "$d")")")" "$(basename "$d")" >/dev/null 2>&1; done
  [ -n "$WAITER" ] && kill $WAITER 2>/dev/null; [ -n "$HOLDER" ] && kill $HOLDER 2>/dev/null; [ -n "$LP" ] && kill $LP 2>/dev/null; return 0; }
trap 'cleanup; test_cleanup' EXIT

# mk_dhub STAGE: a headless hub (role hub-3) whose run has ended, registered as the stage's hub; silent for 20 min
mk_dhub(){
  local s=$1 W=$R/w-$1; TS=$1; mkdir -p "$W"; echo "brief: hold" > "$W/b.md"
  (cd "$W" && FAKE_HOLD=0 "$B/agent" spawn --stage "$s" --role hub-3 --tag hub-3 --cwd "$W" --model haiku --brief "$W/b.md" > "$W/spawn.out" 2>&1)
  local sid; sid=$(sid_of "$s" hub-3)
  "$B/roles" set --stage "$s" hub "$sid" --kind cli --tag hub-3 > /dev/null
  local i pid; pid=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['pid'])" "$R/$s/agents/hub-3/meta.json")
  for i in $(seq 1 120); do kill -0 "$pid" 2>/dev/null || break; sleep 0.25; done     # the run (and its exit-note) is over: nothing writes to its log after this
  for i in $(seq 1 60); do "$B/agent" status --stage "$s" hub-3 2>/dev/null | grep -q finished && break; sleep 0.25; done
  FX age "$R/$s/agents/hub-3/log.jsonl" 20
  FX backdate "$s" 120
}
runs(){ nl "$R/w-$1/argv.log"; }                                        # runs of the headless hub of the stage (spawn + resumes)
# mk_bhub STAGE SID [STATUS]: a `claude --bg` hub (tag hub-4) listed idle/busy, with the daemon's saved options, silent 20 min
mk_bhub(){
  local s=$1 sid=$2 status=${3:-idle}; TS=$1
  mkdir -p "$R/$s/coordinator/work"
  "$B/roles" set --stage "$s" hub "$sid" --kind cli --tag hub-4 > /dev/null
  FX backdate "$s" 120; FX hubfield "$s" host bg
  FX transcript "$sid" 20 ok; FX job "$sid" "$CWD"
  FX rows "$FAKE_WD_ROWS" "${sid:0:8}" "$sid" background "$status" "$CWD"
}
calls(){ FX claude-calls "$R/claude.log"; }
reset_log(){ cat "$R/claude.log" >> "$R/claude.all"; : > "$R/claude.log"; }   # claude.all keeps every call of the suite for the last check
TS=                                                                      # the stage the next tick looks at: one stage per scenario
tick(){ WD run --stage "$TS" > "$R/tick.out" 2>&1; echo $?; }

# ---------------------------------------------------------------- R1: a dead agent
TS=s1; mkdir -p "$R/s1/coordinator/work"; W1=$R/w-s1; mkdir -p "$W1"; echo "brief: hold" > "$W1/b.md"
"$B/roles" set --stage s1 hub $S1 --kind cli --tag hub-4 > /dev/null; FX backdate s1 120
for r in w1 w2 w3; do (cd "$W1" && FAKE_HOLD=60 "$B/agent" spawn --stage s1 --role $r --cwd "$W1" --model haiku --brief "$W1/b.md" > "$W1/spawn-$r.out" 2>&1); done
P1=$(python3 -c "import json;print(json.load(open('$R/s1/agents/w1/meta.json'))['pid'])")
"$B/agent" stop --stage s1 w2 > /dev/null                                  # a known end: never reported as killed
kill -KILL -- -$P1; for i in $(seq 1 40); do kill -0 $P1 2>/dev/null || break; sleep 0.25; done
check "$(tick)" 0 "R1: tick exits 0"
check "$(count 'EXIT w1: killed (no result)' "$(J s1)")" 1 "R1: a killed agent gets one 'EXIT w1: killed (no result)' line"
check "$(count 'EXIT w2' "$(J s1)")" 0 "R1 negative: an agent that was stopped gets none"
check "$(count 'EXIT w3' "$(J s1)")" 0 "R1 negative: a live agent gets none"
check "$(tick)" 0 "R1: second tick exits 0"
check "$(count 'EXIT w1: killed (no result)' "$(J s1)")" 1 "R1 negative: the second tick writes no second line"
"$B/agent" stop --stage s1 w3 > /dev/null

# ---------------------------------------------------------------- R2: an overdue question with a default
TS=s2; mkdir -p "$R/s2/coordinator/work"; "$B/roles" set --stage s2 hub $S2 --kind cli --tag hub-4 > /dev/null; FX backdate s2 120
# the hub is busy-looking and has nothing waiting: only R2 is in play
Q1=$($B/ask add --print-id --stage s2 --blocks x --default "ship without the flag" --due 2020-01-01T10:00 "overdue with a default")
Q2=$($B/ask add --print-id --stage s2 --blocks x --due 2020-01-01T10:00 "overdue, default not set")
Q3=$($B/ask add --print-id --stage s2 --blocks x --default "later" --due 2099-01-01T10:00 "not due")
Q4=$($B/ask add --print-id --stage s2 --blocks x --default "taken" --due 2020-01-01T10:00 "default taken")
Q5=$($B/ask add --print-id --stage s2 --blocks x --default "answered" --due 2020-01-01T10:00 "answered")
$B/ask default-taken "$Q4" > /dev/null; $B/ask close "$Q5" --answer "yes" > /dev/null
check "$(tick)" 0 "R2: tick exits 0"
grep -q "^- [0-9:]* \[watchdog\] @hub OVERDUE $Q1 (due 2020-01-01T10:00) default: ship without the flag" "$(J s2)"; check $? 0 "R2: one @hub OVERDUE line with the default"
check "$(count OVERDUE "$(J s2)")" 1 "R2 negative: not for default 'not set', not due, default-taken, answered"
tick > /dev/null; check "$(count OVERDUE "$(J s2)")" 1 "R2 negative: the second tick writes no second line"
$B/ask close "$Q1" --answer ok > /dev/null
Q6=$($B/ask add --print-id --stage s2 --blocks x --default "another" --due 2020-02-02T10:00 "a second overdue one")
tick > /dev/null; check "$(count OVERDUE "$(J s2)")" 2 "R2: a new question gets its own line"
TS=s2b; mkdir -p "$R/s2b/coordinator/work"; "$B/roles" set --stage s2b worker $S3 --kind headless --tag worker > /dev/null
$B/ask add --stage s2b --blocks x --default "d" --due 2020-01-01T10:00 "no hub in this stage" > /dev/null
tick > /dev/null; check "$(count OVERDUE "$(J s2b)")" 0 "R2 negative: a stage without a hub role writes nothing"

# ---------------------------------------------------------------- R3 detached
mk_dhub sd
FX jline sd 16 "[exec-1] DONE the thing is finished"
check "$(runs sd)" 1 "R3 detached: the hub has run once so far"
check "$(tick)" 0 "R3 detached: tick exits 0"
check "$(runs sd)" 2 "R3 detached: a line 16 min old, hub silent, no waiter → resumed once (agent send)"
grep -q "\[watchdog\] woke hub-3 (agent send --stage sd hub-3, attempt 1): 1 lines waiting since" "$(J sd)"; check $? 0 "R3 detached: the record line names the transport"
grep -q "\[cli\] @hub-3 (session resumed, pid [0-9]*) \[agent-hub watchdog\] sd: 1 journal lines addressed to you have waited since [0-9:]* and no jwait of yours is running\. Run your digest jwait with --since [0-9:]*, handle what it shows, and keep one waiter\. Stop these wake-ups: watchdog quiet --stage sd --reason" "$(J sd)"  # rename:keep: the wake prefix stays on the former name for one release
check $? 0 "R3 detached: the hub got the wake text (digest jwait --since, one waiter, quiet)"
grep -q "\[delamain watchdog\]" "$(J sd)"; check $? 1 "rename: the wake prefix written now is the former name, not the new form (a hub on an older plugin copy reads only it)"
tick > /dev/null; check "$(runs sd)" 2 "R3 safety: a second tick in the same episode wakes no second time"
# R3 held: another stage's hub addressing @hub waits for the stream deadline (30 min), then wakes a hub without a waiter
mkdir -p "$R/sh-peer"; mk_dhub sh
FX jline sh 16 "[sh-peer-hub-4] @hub fyi my side is merged"
tick > /dev/null; check "$(runs sh)" 1 "R3 held negative: a 16-min-old line from another stage's hub does not wake"
mk_dhub sh2; FX jline sh2 31 "[sh-peer-hub-4] @hub fyi my side is merged"
tick > /dev/null; check "$(runs sh2)" 2 "R3 held: the same line 31 min old wakes a hub that has no waiter (late, not lost)"

# R3 detached negatives: nothing is resumed
neg_detached(){  # NAME MINUTES-OLD LINE [SETUP-COMMAND]: one stage, one waiting-line situation, the hub must stay asleep
  local s=$1; mk_dhub "$s"; [ -n "${4:-}" ] && eval "$4"; FX jline "$s" "$2" "$3"
  [ -n "${5:-}" ] && eval "$5"
  tick > /dev/null; check "$(runs $s)" 1 "R3 negative: $6"
}
neg_detached sd14 14 "[exec-1] DONE just finished" "" "" "a line 14 min old is not waiting yet"
neg_detached sdown 20 "[hub-3] DONE the hub's own line" "" "" "the hub's own line is not addressed to it"
neg_detached sdchat 20 "[exec-1] still working on the thing" "" "" "chatter without @ or a status word"
neg_detached sdmine 20 "[exec-1] @hub-3 please look at this" "" "FX consume sdmine hub-3" "a line in the seen-state of the hub's tag (.jwait-state/hub-3.json)"
neg_detached sdsess 20 "[exec-1] DONE seen under the session id" "" 'FX consume sdsess "$(sid_of sdsess hub-3)"' "a line in the seen-state of the hub's session id"
neg_detached sdold 20 "[exec-1] DONE before the hub took over" "FX backdate sdold 10" "" "a line stamped before the hub's set_at"
neg_detached sdq 20 "[exec-1] DONE but the hub is paused" "" '"$B/watchdog" quiet --stage sdq --reason "test" --for 8h > /dev/null' "a do-not-wake marker keeps the hub asleep"
grep -q "wake" "$R/notify.log"; check $? 1 "R3 negative: and no notification was sent"

# R3 and the hub's own waiter: a live armed jwait keeps it asleep, a dead or foreign one does not
mk_dhub sdw; FX jline sdw 20 "[exec-1] DONE waiting for the live waiter"
"$B/jwait" --journal --stage sdw --caller hub-3 --settle 1 --for 120s > "$R/waiter.out" 2>&1 & WAITER=$!
armed "$R/waiter.out"; check $? 0 "jwait armed (the hub's own waiter)"
test -f "$R/.jwait-state/sdw/hub-3.armed.json"; check $? 0 "jwait --journal writes <stage>/<caller>.armed.json while it waits"
python3 - "$R/.jwait-state/sdw/hub-3.armed.json" "$WAITER" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); assert d["pid"] == int(sys.argv[2]) and d["stage"] == "sdw" and d["caller"] == "hub-3", d
PY
check $? 0 "…with the pid, the stage and the caller"
tick > /dev/null; check "$(runs sdw)" 1 "R3 negative: a live jwait of the hub (pid alive, deadline ahead) → not woken"
grep -q "\[watchdog\] hub-3's jwait does not match 1 lines addressed to it" "$(J sdw)"; check $? 0 "R3: lines waiting under a live waiter are recorded once as a mismatch"
tick > /dev/null; check "$(count "jwait does not match" "$(J sdw)")" 1 "R3: …and only once"
kill -TERM $WAITER; wait $WAITER 2>/dev/null; WAITER=
test -f "$R/.jwait-state/sdw/hub-3.armed.json"; check $? 1 "jwait: the armed file is gone after SIGTERM"
# an armed file whose pid is dead (what SIGKILL leaves behind): ignored, deleted, the hub woken
mkdir -p "$R/.jwait-state/sdw"
python3 - "$R/.jwait-state/sdw/hub-3.armed.json" <<'PY'
import datetime as dt, json, subprocess, sys
p = subprocess.Popen(["true"]); p.wait()
json.dump({"pid": p.pid, "stage": "sdw", "caller": "hub-3", "tags": [], "deadline": (dt.datetime.now(dt.timezone.utc) + dt.timedelta(minutes=30)).isoformat()},
          open(sys.argv[1], "w"))
PY
tick > /dev/null; check "$(runs sdw)" 2 "R3: a stale armed file (dead pid) → the hub is woken"
test -f "$R/.jwait-state/sdw/hub-3.armed.json"; check $? 1 "…and the stale file is deleted"
# an armed file whose pid is alive but is not a jwait (pid reuse) is stale too; an executor's live waiter is not the hub's
mk_dhub sdx; FX jline sdx 20 "[exec-1] DONE nobody waits"
python3 -c "import time; time.sleep(120)" & SL=$!
mkdir -p "$R/.jwait-state/sdx"; python3 - "$R/.jwait-state/sdx/hub-3.armed.json" "$SL" <<'PY'
import datetime as dt, json, sys
json.dump({"pid": int(sys.argv[2]), "stage": "sdx", "caller": "hub-3", "tags": [], "deadline": (dt.datetime.now(dt.timezone.utc) + dt.timedelta(minutes=30)).isoformat()},
          open(sys.argv[1], "w"))
PY
"$B/jwait" --journal --stage sdx --caller exec-1 --settle 1 --for 120s > "$R/waiter2.out" 2>&1 & WAITER=$!
armed "$R/waiter2.out"
tick > /dev/null; check "$(runs sdx)" 2 "R3: a live pid that is not a jwait, and an executor's own live jwait, do not hold the hub back"
kill $SL 2>/dev/null; kill -TERM $WAITER 2>/dev/null; wait $WAITER 2>/dev/null; WAITER=
# two stages whose hubs are both `hub-3`: each waiter is seen under its own stage (one file per stage and caller)
mk_dhub sh2a; FX jline sh2a 20 "[exec-1] DONE a line for stage a"
mk_dhub sh2b; FX jline sh2b 20 "[exec-1] DONE a line for stage b"
"$B/jwait" --journal --stage sh2a --caller hub-3 --settle 1 --for 120s > "$R/wa.out" 2>&1 & WA=$!
"$B/jwait" --journal --stage sh2b --caller hub-3 --settle 1 --for 120s > "$R/wb.out" 2>&1 & WAITER=$!
armed "$R/wa.out"; armed "$R/wb.out"
test -f "$R/.jwait-state/sh2a/hub-3.armed.json" -a -f "$R/.jwait-state/sh2b/hub-3.armed.json"; check $? 0 "H2: two stages, both callers hub-3: each waiter has its own armed file"
TS=sh2a; tick > /dev/null; check "$(runs sh2a)" 1 "H2: the first stage's hub is not woken (its waiter is visible)"
TS=sh2b; tick > /dev/null; check "$(runs sh2b)" 1 "H2: the second stage's hub is not woken either"
kill -TERM $WA; wait $WA 2>/dev/null
test -f "$R/.jwait-state/sh2b/hub-3.armed.json"; check $? 0 "H2: the first waiter ending leaves the second stage's armed file"
TS=sh2a; tick > /dev/null; check "$(runs sh2a)" 2 "H2: …and the first stage's hub, now without a waiter, is woken"
TS=sh2b; tick > /dev/null; check "$(runs sh2b)" 1 "H2: …while the second stage's hub still is not"
kill -TERM $WAITER 2>/dev/null; wait $WAITER 2>/dev/null; WAITER=
# stage names that differ only by a trailing underscore are two stages (the stage name is the directory, unchanged)
mk_dhub release; FX jline release 20 "[exec-1] DONE a line for release"
mk_dhub release_; FX jline release_ 20 "[exec-1] DONE a line for release_"
"$B/jwait" --journal --stage release --caller hub-3 --settle 1 --for 120s > "$R/wr1.out" 2>&1 & WA=$!
"$B/jwait" --journal --stage release_ --caller hub-3 --settle 1 --for 120s > "$R/wr2.out" 2>&1 & WAITER=$!
armed "$R/wr1.out"; armed "$R/wr2.out"
test -f "$R/.jwait-state/release/hub-3.armed.json" -a -f "$R/.jwait-state/release_/hub-3.armed.json"; check $? 0 "H2: stages 'release' and 'release_' (same caller) have separate armed files"
TS=release; tick > /dev/null; check "$(runs release)" 1 "H2: …the hub of 'release' is not woken (its waiter is visible)"
TS=release_; tick > /dev/null; check "$(runs release_)" 1 "H2: …nor the hub of 'release_'"
kill -TERM $WA $WAITER 2>/dev/null; wait $WA $WAITER 2>/dev/null; WAITER=

# ---------------------------------------------------------------- R3 claude --bg
U(){ printf '%08d-0000-4000-8000-%012d' "$1" "$1"; }                    # a distinct session id per scenario
resumed(){ calls | grep -c '^resume'; }
stopped(){ calls | grep -c '^stop'; }
# positive: an idle listed hub, silent, one line waiting → claude stop, then --bg --resume <same id> with no other flag
B1=$(U 11); mk_bhub sb1 $B1; FX jline sb1 16 "[exec-1] DONE the build finished"
reset_log; check "$(tick)" 0 "R3 claude-bg: tick exits 0"
check "$(calls | tr '\n' '|')" "agents|agents|stop ${B1:0:8}|agents|agents|resume $B1 1 --bg|agents|" "R3 claude-bg: stop the listed idle hub, then resume the same id; the text is the only argument besides --bg --resume"
python3 - "$FAKE_WD_ROWS" "$B1" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1])); assert [r["sessionId"] for r in rows] == [sys.argv[2]], rows
PY
check $? 0 "R3 claude-bg: the session is listed again under the same id (no copy)"
python3 - "$R/claude.log" "$CWD" "$B" <<'PY'
import json, os, sys
calls = [json.loads(l) for l in open(sys.argv[1])]
resume = [c for c in calls if "--resume" in c["argv"]][0]
text = resume["argv"][-1]
assert text.startswith("[agent-hub watchdog] sb1: 1 journal lines addressed to you have waited since"), text  # rename:keep: the former name for one release
assert "Background commands of your last turn were stopped; re-arm what you need." in text, text
assert resume["cwd"] == os.path.realpath(sys.argv[2]), resume["cwd"]
sys.path.insert(0, sys.argv[3])
import autopilot
assert not autopilot.owner_spoke(text), "the wake text would reset the autopilot chain"
assert text.startswith(autopilot.WATCHDOG_MARKER), "the writer and the reader share one definition of the prefix"
assert not autopilot.owner_spoke(text.replace("[agent-hub watchdog]", "[delamain watchdog]", 1)), "the new form of the prefix is exempt too"  # rename:keep
assert autopilot.owner_spoke("how is it going?"), "negative control: an ordinary owner prompt still resets the chain"
assert autopilot.owner_spoke("is the watchdog [delamain watchdog] on?"), "positive control: a person's prompt still counts"
PY
check $? 0 "R3 claude-bg: the wake text names the stopped background commands; the resume runs in the hub's cwd; it is not read as the owner speaking (B)"
grep -q "\[watchdog\] woke hub-4 (claude stop ${B1:0:8}; claude --bg --resume ${B1:0:8}" "$(J sb1)"; check $? 0 "R3 claude-bg: the record line names stop + resume"
check "$(tick)" 0 "R3 claude-bg: a second tick exits 0"
check "$(resumed)" 1 "R3 claude-bg: the second tick does not resume again (one wake per episode)"

neg_bg(){  # NAME NUM SETUP-COMMAND TEXT: a hub that must not be stopped or resumed
  local s=$1 b SID; b=$(U $2); SID=$b; mk_bhub "$s" "$b"; FX jline "$s" 16 "[exec-1] DONE a line is waiting"
  eval "$3"; reset_log; tick > /dev/null
  check "$(( $(resumed) + $(stopped) ))" 0 "R3 negative: $4"
}
neg_bg sbbusy 12 'FX rows "$FAKE_WD_ROWS" ${SID:0:8} $SID background busy "$CWD"' "a busy hub is not touched"
neg_bg sbfresh 13 'FX transcript $SID 5 ok' "a hub whose transcript is 5 min old is not silent"
neg_bg sbnojob 14 'rm -rf "$CLAUDE_CONFIG_DIR/jobs/${SID:0:8}"' "no saved options of the background session → notify only"
grep -q "delamain: sbnojob — hub silent [0-9]* min, 1 lines waiting" "$R/notify.log"; check $? 0 "…and the owner is notified (stage name, minutes, count)"
neg_bg sbwaiting 15 'FX rows "$FAKE_WD_ROWS" ${SID:0:8} $SID background waiting "$CWD"' "a hub waiting for an answer (status waiting) is not stopped"
B16=$(U 16); mk_bhub sbfail $B16; FX jline sbfail 16 "[exec-1] DONE a line is waiting"
reset_log; FAKE_WD_AGENTS=fail WD run --stage "$TS" > "$R/tick.out" 2>&1
check "$(( $(resumed) + $(stopped) ))" 0 "R3 negative: \`claude agents --json\` fails (busy unknown) → no stop, no resume"
grep -q "delamain: sbfail — hub silent" "$R/notify.log"; check $? 0 "…the owner is notified instead"
# failures of the wake itself: the owner is told, nothing else is started
B17=$(U 17); mk_bhub sbcopy $B17; FX jline sbcopy 16 "[exec-1] DONE a line is waiting"
reset_log; FAKE_WD_RESUME=copy WD run --stage "$TS" > "$R/tick.out" 2>&1
check "$(calls | grep -c '^stop cc')" 1 "R3 claude-bg: the CLI reports a copy → the copy is stopped at once"
check "$(resumed)" 1 "R3 claude-bg: …and the wake is left to the next tick (no second resume in the same tick)"
python3 - "$FAKE_WD_ROWS" <<'PY'
import json, sys
assert not [r for r in json.load(open(sys.argv[1])) if r["id"].startswith("cc")], "a copy is still listed"
PY
check $? 0 "…and no copy is listed any more"
grep -q "\[watchdog\] wake of hub-4 failed (.*the CLI started a copy of the session" "$(J sbcopy)"; check $? 0 "…the journal records the failed wake"
grep -q "delamain: sbcopy — wake failed" "$R/notify.log"; check $? 0 "…and the owner is notified"
B18=$(U 18); mk_bhub sbstop $B18; FX jline sbstop 16 "[exec-1] DONE a line is waiting"
reset_log; FAKE_WD_STOP=fail WD run --stage "$TS" > "$R/tick.out" 2>&1
check "$(resumed)" 0 "R3 claude-bg: claude stop fails → no resume"
grep -q "delamain: sbstop — wake failed" "$R/notify.log"; check $? 0 "…the owner is notified"
# H1: a session that appears during the resume without the CLI naming it as a copy is not tied to this call: never stopped
B21=$(U 21); mk_bhub sbstr $B21; FX jline sbstr 16 "[exec-1] DONE a line is waiting"
reset_log; : > "$R/notify.log"; FAKE_WD_RESUME=stranger WD run --stage "$TS" > "$R/tick.out" 2>&1
check "$(calls | grep -c '^stop feedface')" 0 "H1 negative: an unrelated new session during the resume is not stopped"
check "$(stopped)" 1 "H1: …only the hub itself was stopped (before the resume)"
python3 - "$FAKE_WD_ROWS" <<'PY'
import json, sys
ids = [r["id"] for r in json.load(open(sys.argv[1]))]
assert "feedface" in ids, ids
PY
check $? 0 "H1: …and it is still listed"
grep -q "wake of hub-4 failed (.*a new session appeared during the resume, not stopped" "$(J sbstr)"; check $? 0 "H1: the journal says a new session appeared, not stopped"
grep -q "delamain: sbstr — wake failed" "$R/notify.log"; check $? 0 "H1: …and the owner is notified"
# M1: the session turned interactive (opened in a terminal) after the first look: not stopped, not resumed
B22=$(U 22); mk_bhub sbkind $B22; FX jline sbkind 16 "[exec-1] DONE a line is waiting"
reset_log; : > "$R/notify.log"; FAKE_WD_KIND=interactive FAKE_WD_KIND_FROM=2 WD run --stage "$TS" > "$R/tick.out" 2>&1
check "$(( $(resumed) + $(stopped) ))" 0 "M1 negative: the fresh row says interactive/idle → no stop, no resume"
grep -q "interactive/idle now: not woken" "$(J sbkind)"; check $? 0 "M1: …the journal says so"
# M2: the copy's `claude stop` fails, or exits 0 and leaves the copy listed: the result says the cleanup failed
B23=$(U 23); mk_bhub sbcf $B23; FX jline sbcf 16 "[exec-1] DONE a line is waiting"
reset_log; : > "$R/notify.log"; FAKE_WD_RESUME=copy FAKE_WD_STOP=copy-fail WD run --stage "$TS" > "$R/tick.out" 2>&1
grep -q "the cleanup failed (claude stop exit 1" "$(J sbcf)"; check $? 0 "M2: a failing stop of the copy → the journal says the cleanup failed"
grep -q "the copy was stopped" "$(J sbcf)"; check $? 1 "M2 negative: …and does not claim the copy was stopped"
grep -q "delamain: sbcf — wake failed" "$R/notify.log"; check $? 0 "M2: …the owner is notified"
B24=$(U 24); mk_bhub sbcg $B24; FX jline sbcg 16 "[exec-1] DONE a line is waiting"
reset_log; FAKE_WD_RESUME=copy FAKE_WD_STOP=copy-ghost WD run --stage "$TS" > "$R/tick.out" 2>&1
grep -q "the cleanup failed (it is still listed" "$(J sbcg)"; check $? 0 "M2: a stop that exits 0 but leaves the copy listed → the cleanup failed too"
grep -q "the copy was stopped" "$(J sbcg)"; check $? 1 "M2 negative: …not claimed as stopped"
# A1 (0.9.2): the listing drops a stopped hub before its process has exited and the daemon has released the session; a resume in
# that window starts a copy (live probe: work/watchdog-hotfix-probe.md). The wake waits for the stopped row's pid to exit.
B25=$(U 25); mk_bhub sblinger $B25; FX jline sblinger 16 "[exec-1] DONE a line is waiting"
sleep 120 & LP=$!; FX rows "$FAKE_WD_ROWS" ${B25:0:8} $B25 background idle "$CWD" $LP
reset_log; FAKE_WD_STOP_LINGER=2 WD run --stage "$TS" > "$R/tick.out" 2>&1
check "$(calls | tr '\n' '|')" "agents|agents|stop ${B25:0:8}|agents|agents|resume $B25 1 --bg|agents|" "A1 claude-bg: stop, then one resume of the same id"
python3 - "$FAKE_WD_ROWS" "$B25" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1])); assert [r["sessionId"] for r in rows] == [sys.argv[2]], rows
PY
check $? 0 "A1: a hub whose process lingers after claude stop is woken as the same session — no copy"
kill -0 $LP 2>/dev/null; check $? 1 "A1: …and the resume came after the old process had exited"
grep -q "\[watchdog\] woke hub-4" "$(J sblinger)"; check $? 0 "A1: …the journal says the hub was woken"
B26=$(U 26); mk_bhub sbstuck $B26; FX jline sbstuck 16 "[exec-1] DONE a line is waiting"
sleep 120 & LP=$!; FX rows "$FAKE_WD_ROWS" ${B26:0:8} $B26 background idle "$CWD" $LP
reset_log; : > "$R/notify.log"; AGENT_HUB_WATCHDOG_STOP_WAIT=1 FAKE_WD_STOP_LINGER=hold WD run --stage "$TS" > "$R/tick.out" 2>&1
check "$(resumed)" 0 "A1 negative: the old process still runs when the wait is over → no resume in this tick"
kill $LP; wait $LP 2>/dev/null; LP=
grep -q "wake of hub-4 failed (.*is still exiting after 1 s: not resuming now" "$(J sbstuck)"; check $? 0 "A1: …the journal says so"
grep -q "delamain: sbstuck — wake failed" "$R/notify.log"; check $? 0 "A1: …and the owner is notified"
python3 - "$FAKE_WD_ROWS" <<'PY'
import json, sys
assert not json.load(open(sys.argv[1])), "a session was started"
PY
check $? 0 "A1: …and no session was started (neither a copy nor the hub)"
# A1 r1: the stopped process's identity outlives the tick; a row without a pid; the hub resumed by the owner while we waited
A1T(){ local m=$1; shift  # MINUTES ENV=VAL...: one tick at a fixed offset from one base time (the ticks of a scenario share a clock)
  env AGENT_HUB_WATCHDOG_NOW=$(python3 -c 'import datetime as d,sys; print((d.datetime.fromtimestamp(int(sys.argv[1]), d.timezone.utc)+d.timedelta(minutes=int(sys.argv[2]))).strftime("%Y-%m-%dT%H:%M"))' "$A1_T0" "$m") "$@" \
    "$B/watchdog" run --stage "$TS" > "$R/tick.out" 2>&1; }
B27=$(U 27); mk_bhub sbpid $B27; FX jline sbpid 20 "[exec-1] DONE a line is waiting"
sleep 120 & LP=$!; FX rows "$FAKE_WD_ROWS" ${B27:0:8} $B27 background idle "$CWD" $LP
reset_log; A1_T0=$(date +%s); A1T 0 AGENT_HUB_WATCHDOG_STOP_WAIT=1 FAKE_WD_STOP_LINGER=hold
check "$(resumed)" 0 "A1 r1: the old process outlives the wait → no resume in the first tick"
check "$(state_val stages sbpid hub stopped pid)" "$LP" "A1 r1: …its pid is kept in the hub's state"
test -n "$(state_val stages sbpid hub stopped start)"; check $? 0 "A1 r1: …with its start time"
A1T 20; check "$(resumed)" 0 "A1 r1: the next tick (hub unlisted, backoff over) does not resume over the living process"
grep -q "still exiting: not resuming now, the next tick checks again" "$(J sbpid)"; check $? 0 "A1 r1: …and says why"
kill $LP; wait $LP 2>/dev/null; LP=
A1T 60; check "$(resumed)" 1 "A1 r1: once the process is gone, the tick after resumes"
python3 - "$FAKE_WD_ROWS" "$B27" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1])); assert [r["sessionId"] for r in rows] == [sys.argv[2]], rows
PY
check $? 0 "A1 r1: …the same session, no copy"
check "$(state_val stages sbpid hub stopped pid)" "" "A1 r1: …and the record of the stopped process is cleared"
# a reused pid is not the hub: the same pid with another start time does not hold the resume back
B28=$(U 28); mk_bhub sbreuse $B28; FX jline sbreuse 20 "[exec-1] DONE a line is waiting"
sleep 120 & LP=$!; FX rows "$FAKE_WD_ROWS" ${B28:0:8} $B28 background idle "$CWD" $LP
reset_log; A1_T0=$(date +%s); A1T 0 AGENT_HUB_WATCHDOG_STOP_WAIT=1 FAKE_WD_STOP_LINGER=hold
python3 - "$R/.state/watchdog/state.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["stages"]["sbreuse"]["hub"]["stopped"]["start"] = "Thu Jan  1 00:00:00 1970"
json.dump(d, open(sys.argv[1], "w"))
PY
A1T 20; check "$(resumed)" 1 "A1 r1: a live pid with another start time is another process → the resume is tried"
kill $LP; wait $LP 2>/dev/null; LP=
# a listed idle row without a pid: a stop's release cannot be told, so the hub is not stopped at all
B29=$(U 29); mk_bhub sbnopid $B29; FX jline sbnopid 20 "[exec-1] DONE a line is waiting"
FX rows "$FAKE_WD_ROWS" ${B29:0:8} $B29 background idle "$CWD" 0
python3 - "$FAKE_WD_ROWS" <<'PY'                                          # listed as running only by its status: no pid, state not done
import json, sys
rows = json.load(open(sys.argv[1]))
for r in rows:
    r["state"] = "working"
json.dump(rows, open(sys.argv[1], "w"))
PY
reset_log; : > "$R/notify.log"; A1_T0=$(date +%s); A1T 0
check "$(stopped):$(resumed)" "0:0" "A1 r2: a listed idle row without a pid → no claude stop, no resume"
grep -q "wake of hub-4 failed (.*the hub's row has no pid, so a stop's release cannot be told: not stopping" "$(J sbnopid)"; check $? 0 "A1 r2: …the journal says why"
grep -q "delamain: sbnopid — wake failed" "$R/notify.log"; check $? 0 "A1 r2: …and the owner is notified"
A1T 20; check "$(stopped):$(resumed)" "0:0" "A1 r2: …and a later tick does not stop or resume it either"
# stop succeeded but the re-list fails, or still shows the row: the process identity is saved at once; a later tick, with the hub
# unlisted and the old process alive, does not resume
for mode in relist-fails still-listed; do
  N=$([ "$mode" = relist-fails ] && echo 31 || echo 32); BN=$(U $N); st=sbr$N; mk_bhub $st $BN; FX jline $st 20 "[exec-1] DONE a line is waiting"
  sleep 120 & LP=$!; FX rows "$FAKE_WD_ROWS" ${BN:0:8} $BN background idle "$CWD" $LP
  reset_log; A1_T0=$(date +%s)
  if [ "$mode" = relist-fails ]; then A1T 0 FAKE_WD_STOP_LINGER=hold FAKE_WD_AGENTS_FAIL_FROM=3
  else A1T 0 FAKE_WD_STOP=ghost; fi
  check "$(stopped):$(resumed)" "1:0" "A1 r2 ($mode): stop ok, no resume in this tick"
  check "$(state_val stages $st hub stopped pid)" "$LP" "A1 r2 ($mode): …the identity of the stopped process is in the saved state"
  FX rows "$FAKE_WD_ROWS"                                                  # the row is gone (the daemon dropped it), the process hangs on
  reset_log; A1T 20
  check "$(resumed)" 0 "A1 r2 ($mode): a later tick, hub unlisted and its process alive → no resume"
  kill $LP; wait $LP 2>/dev/null; LP=
done
# the owner resumed the hub while the watchdog waited for the old process: the wake is cancelled
B30=$(U 30); mk_bhub sbrel $B30; FX jline sbrel 20 "[exec-1] DONE a line is waiting"
sleep 120 & LP=$!; FX rows "$FAKE_WD_ROWS" ${B30:0:8} $B30 background idle "$CWD" $LP
reset_log; A1_T0=$(date +%s); A1T 0 FAKE_WD_STOP_LINGER=1 FAKE_WD_STOP_RELIST=1
check "$(resumed)" 0 "A1 r1: the hub is listed again after the wait → no resume"
grep -q "listed again (resumed meanwhile): the wake is cancelled" "$(J sbrel)"; check $? 0 "A1 r1: …the journal says so"
wait $LP 2>/dev/null; LP=
# a hub that is not listed (its process is gone) but was started in the background: resumed without a stop
B19=$(U 19); mk_bhub sbgone $B19; FX jline sbgone 16 "[exec-1] DONE a line is waiting"; FX rows "$FAKE_WD_ROWS"
reset_log; tick > /dev/null
check "$(calls | tr '\n' '|')" "agents|agents|resume $B19 1 --bg|agents|" "R3 claude-bg: not listed, host bg → resumed (same id), nothing to stop"
B20=$(U 20); mk_bhub sbterm $B20; FX jline sbterm 16 "[exec-1] DONE a line is waiting"; FX hubfield sbterm host term; FX rows "$FAKE_WD_ROWS"
reset_log; tick > /dev/null
check "$(( $(resumed) + $(stopped) ))" 0 "R3 negative: not listed and not started in the background (host term) → notify only"
grep -q "delamain: sbterm — hub silent" "$R/notify.log"; check $? 0 "…the owner is notified"

# ---------------------------------------------------------------- R3 notify-only hosts
D1=$(U 31); D1CLI=$(U 32); mkdir -p "$CLAUDE_SESSIONS_DIR/a/b"
printf '{"sessionId":"local_%s","cliSessionId":"%s","title":"Hub desk","isArchived":false}' "$D1" "$D1CLI" > "$CLAUDE_SESSIONS_DIR/a/b/local_$D1.json"
TS=sdesk; mkdir -p "$R/sdesk/coordinator/work"; "$B/roles" set --stage sdesk hub "local_$D1" --kind desktop --tag hub-5 > /dev/null
FX backdate sdesk 120; FX transcript "$D1CLI" 20 ok; FX jline sdesk 16 "[exec-1] DONE a line for the desktop hub"
reset_log; tick > /dev/null
check "$(( $(resumed) + $(stopped) ))" 0 "R3 notify-only: a Desktop hub is never stopped or resumed"
grep -q "delamain: sdesk — hub silent [0-9]* min, 1 lines waiting" "$R/notify.log"; check $? 0 "R3 notify-only: …it gets a notification"
I1=$(U 33); mk_bhub sterm2 $I1; FX hubfield sterm2 host term; FX jline sterm2 16 "[exec-1] DONE a line for the terminal hub"
FX rows "$FAKE_WD_ROWS" ${I1:0:8} $I1 interactive idle "$CWD"; reset_log; tick > /dev/null
check "$(( $(resumed) + $(stopped) ))" 0 "R3 notify-only: a terminal (interactive) hub is never stopped or resumed"
grep -q "delamain: sterm2 — hub silent" "$R/notify.log"; check $? 0 "R3 notify-only: …it gets a notification"

# ---------------------------------------------------------------- R4: the last turn died on an API error
R4A=$(U 41); mk_bhub sr4 $R4A; FX transcript $R4A 16 error
reset_log; tick > /dev/null
check "$(resumed)" 1 "R4: the last transcript record is an API error 16 min old, nothing waiting → woken"
python3 - "$R/claude.log" <<'PY'
import json, sys
text = [json.loads(l)["argv"] for l in open(sys.argv[1]) if "--resume" in l][0][-1]
assert "your last turn ended on an API error at" in text and "(rate_limit)" in text and "continue where you stopped" in text, text
PY
check $? 0 "R4: the text names the error and says to continue where it stopped"
neg_r4(){  # NAME NUM TRANSCRIPT-ARGS TEXT [ENV]
  local s=$1 b; b=$(U $2); mk_bhub "$s" "$b"; FX transcript "$b" $3; reset_log
  env ${5:-X=1} "$B/watchdog" run --stage "$s" > "$R/tick.out" 2>&1
  check "$(( $(resumed) + $(stopped) ))" 0 "R4 negative: $4"
}
neg_r4 sr4user 42 "16 error-user" "a user record after the error (the turn went on)"
neg_r4 sr4young 43 "10 error" "the error is only 10 min old"
neg_r4 sr4off 44 "16 error" "AGENT_HUB_WATCHDOG_API_ERROR=off" AGENT_HUB_WATCHDOG_API_ERROR=off
neg_r4 sr4ok 45 "20 ok" "a normal last turn and nothing waiting"


# H3: a live own jwait holds R4 back as well (its completion wakes the hub; stop + resume would kill it)
R4W=$(U 46); mk_bhub sr4w $R4W; FX transcript $R4W 16 error
"$B/jwait" --journal --stage sr4w --caller hub-4 --settle 1 --for 120s > "$R/waiter3.out" 2>&1 & WAITER=$!
armed "$R/waiter3.out"; reset_log; tick > /dev/null
check "$(( $(resumed) + $(stopped) ))" 0 "H3 negative: an API-error turn 16 min old and a live own jwait → no stop, no resume"
kill -TERM $WAITER; wait $WAITER 2>/dev/null; WAITER=
reset_log; tick > /dev/null
check "$(resumed)" 1 "H3 control: the waiter gone → the same hub is woken"

# ---------------------------------------------------------------- R3 night: an open night-queue item inside AGENT_HUB_NIGHT
NIGHT=2026-10-07T02:00:00; DAY=2026-10-07T12:00:00
night_hub(){  # STAGE NUM [QUEUE-AGE-MIN] [ITEM-MARK]: a bg hub silent for 20 min at $FX_NOW, a night queue with one open item
  local s=$1 b; b=$(U $2); mk_bhub "$s" "$b"
  printf '# Night queue — %s\ncoordinator: x\nnight: 2026-10-06→07\nupdated: 2026-10-06T22:30 hub-4\n\n- [%s] run the nightly import | stop: when done | class: local\n' "$s" "${4:- }" > "$R/$s/night-queue.md"
  FX age "$R/$s/night-queue.md" "${3:-90}"
}
night_tick(){ reset_log; AGENT_HUB_WATCHDOG_NOW=$1 WD run --stage "$TS" > "$R/tick.out" 2>&1; }
export FX_NOW=$NIGHT
night_hub sn1 51; night_tick $NIGHT
check "$(resumed)" 1 "R3 night: an open night-queue item inside the window, the hub silent → woken"
python3 - "$R/claude.log" "$R" <<'PY'
import json, sys
text = [json.loads(l)["argv"] for l in open(sys.argv[1]) if "--resume" in l][0][-1]
assert f"Night queue: continue with {sys.argv[2]}/sn1/night-queue.md (open 1, next: run the nightly import | stop: when done | class: local)." in text, text
assert "anything outside it — `ask add` with a default action, then move on." in text, text
PY
check $? 0 "R3 night: the hub gets the night-queue sentence (file, open count, next item)"
export FX_NOW=$DAY; night_hub sn2 52; night_tick $DAY
check "$(resumed)" 0 "R3 night negative: outside the window (12:00)"
export FX_NOW=$NIGHT
night_hub sn3 53; AGENT_HUB_WATCHDOG_NIGHT_QUEUE=off; export AGENT_HUB_WATCHDOG_NIGHT_QUEUE; night_tick $NIGHT; unset AGENT_HUB_WATCHDOG_NIGHT_QUEUE
check "$(resumed)" 0 "R3 night negative: AGENT_HUB_WATCHDOG_NIGHT_QUEUE=off"
night_hub sn4 54 90 x; night_tick $NIGHT
check "$(resumed)" 0 "R3 night negative: no open item (all done)"
night_hub sn5 55 5; night_tick $NIGHT
check "$(resumed)" 0 "R3 night negative: the item was queued 5 min ago, not waiting yet"
unset FX_NOW

# ---------------------------------------------------------------- safety
# a do-not-wake marker: no wake, no notification; R1 and R2 still write; cleared → the hub is woken
mk_dhub ssm; FX jline ssm 16 "[exec-1] DONE a line while the hub is paused"
WM=$R/w-ssm; (cd "$WM" && FAKE_HOLD=60 "$B/agent" spawn --stage ssm --role w1 --cwd "$WM" --model haiku --brief "$WM/b.md" > "$WM/spawn-w1.out" 2>&1)
PM=$(python3 -c "import json;print(json.load(open('$R/ssm/agents/w1/meta.json'))['pid'])"); kill -KILL -- -$PM; for i in $(seq 1 40); do kill -0 $PM 2>/dev/null || break; sleep 0.25; done
$B/ask add --stage ssm --blocks x --default "go on" --due 2020-01-01T10:00 "a question while paused" > /dev/null
WD quiet --stage ssm --reason "the hub sleeps on purpose" --for 8h > "$R/q.out"; check $? 0 "quiet: sets the marker"
grep -q "stage ssm: wake-ups of stage ssm are paused by owner until .*: the hub sleeps on purpose" "$R/q.out"; check $? 0 "quiet: says who, until when and why"
WD quiet | grep -q "^ssm: wake-ups of stage ssm are paused"; check $? 0 "quiet: lists the marker"
: > "$R/notify.log"; tick > /dev/null
check "$(runs ssm)" 2 "safety: a marker keeps the hub asleep (runs: the hub and the killed worker)"
check "$(count ssm "$R/notify.log")" 0 "safety: …and sends no notification"
check "$(count 'EXIT w1: killed (no result)' "$(J ssm)")" 1 "safety: …but R1 still writes the EXIT line"
check "$(count 'OVERDUE' "$(J ssm)")" 1 "safety: …and R2 the overdue line"
WD quiet --stage ssm --clear > /dev/null; tick > /dev/null
check "$(runs ssm)" 3 "safety: the marker cleared → the hub is woken"
# an expired marker is ignored and removed
mk_dhub sse; FX jline sse 16 "[exec-1] DONE a line while an old marker lies there"
printf '{"by":"owner","at":"2020-01-01T00:00:00+00:00","until":"2020-01-01T08:00:00+00:00","reason":"old"}\n' > "$R/sse/do-not-wake.json"
tick > /dev/null; check "$(runs sse)" 2 "safety: an expired marker does not keep the hub asleep"
test -f "$R/sse/do-not-wake.json"; check $? 1 "safety: …and the tick removes it"
# a pending handoff: the stage is skipped; one that is stuck notifies once and starts nothing
B71=$(U 71); mk_bhub ssh $B71; FX jline ssh 16 "[exec-1] DONE a line while a successor starts"
python3 - "$R/ssh/auto-handoff.json" 2 <<'PY'
import datetime as dt, json, sys
at = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(minutes=float(sys.argv[2]))).isoformat(timespec="seconds")
json.dump({"chain": 1, "pending": {"n": 5, "kind": "bg", "at": at, "id": "abcd1234"}}, open(sys.argv[1], "w"))
PY
reset_log; : > "$R/notify.log"; tick > /dev/null
check "$(( $(resumed) + $(stopped) ))" 0 "safety: a pending successor (2 min old) → the stage is skipped"
check "$(count ssh "$R/notify.log")" 0 "safety: …and nobody is notified yet"
python3 - "$R/ssh/auto-handoff.json" 120 <<'PY'
import datetime as dt, json, sys
at = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(minutes=float(sys.argv[2]))).isoformat(timespec="seconds")
json.dump({"chain": 1, "pending": {"n": 5, "kind": "bg", "at": at, "id": "abcd1234"}}, open(sys.argv[1], "w"))
PY
tick > /dev/null; tick > /dev/null
check "$(count 'delamain: ssh — handoff stuck' "$R/notify.log")" 1 "safety: a handoff stuck for 2 h → the owner is notified once (two ticks)"
check "$(( $(resumed) + $(stopped) ))" 0 "safety: …and nothing is started or resumed"
check "$(python3 -c "import json;print(json.load(open('$R/ssh/auto-handoff.json'))['pending']['n'])")" 5 "safety: …the pending record is left alone"
# a replaced hub starts clean
B72=$(U 72); mk_bhub ssc $B72; FX jline ssc 16 "[exec-1] DONE a line for the old hub"
FAKE_WD_RESUME=fail WD run --stage ssc > /dev/null 2>&1
check "$(state_val stages ssc hub session)" "$B72" "safety: the state is keyed by the hub's session"
check "$(state_val stages ssc hub episode attempts)" 1 "safety: a failed wake leaves an episode with one attempt"
B73=$(U 73); "$B/roles" set --stage ssc hub $B73 --kind cli --tag hub-5 > /dev/null; reset_log; WD run --stage ssc > /dev/null 2>&1
check "$(state_val stages ssc hub session)" "$B73" "safety: a replaced hub (another session) → the old state is dropped"
check "$(state_val stages ssc hub episode)" "" "safety: …and the new hub has no episode"
check "$(( $(resumed) + $(stopped) ))" 0 "safety: …and the old hub's waiting lines (before the new hub's set_at) wake nobody"
# one tick at a time
python3 - "$R/.state/watchdog/lock" > "$R/holder.out" <<'PY' &
import fcntl, sys, time
fh = open(sys.argv[1], "a"); fcntl.flock(fh, fcntl.LOCK_EX); print("locked", flush=True); time.sleep(100)
PY
HOLDER=$!; for i in $(seq 1 50); do grep -q locked "$R/holder.out" && break; sleep 0.2; done
WD run > "$R/held.out" 2>&1; check $? 0 "safety: a tick that finds the lock held exits 0"
grep -q "another tick is running" "$R/held.out"; check $? 0 "safety: …and says so"
kill $HOLDER 2>/dev/null; wait $HOLDER 2>/dev/null; HOLDER=

# ---------------------------------------------------------------- backoff: 15 → 30 → 60 min while the wake keeps failing
B81=$(U 81); mk_bhub sbo $B81; FX jline sbo 16 "[exec-1] DONE a line while the wake fails"
reset_log
BO_T0=$(date +%s)                                                        # one base for every tick: utc_iso truncates to the minute of the moment it runs
bo(){ AGENT_HUB_WATCHDOG_NOW=$(python3 -c 'import datetime as d,sys; print((d.datetime.fromtimestamp(int(sys.argv[1]), d.timezone.utc)+d.timedelta(minutes=int(sys.argv[2]))).strftime("%Y-%m-%dT%H:%M"))' "$BO_T0" "$1") \
  FAKE_WD_RESUME=fail WD run --stage sbo > "$R/tick.out" 2>&1; }
bo 0;   check "$(resumed)" 1 "backoff: the first attempt is at once"
bo 14;  check "$(resumed)" 1 "backoff: …none at +14 min"
bo 15;  check "$(resumed)" 2 "backoff: …the second at +15 min"
bo 44;  check "$(resumed)" 2 "backoff: …none at +44 min"
bo 45;  check "$(resumed)" 3 "backoff: …the third at +45 min (30 min after the second)"
bo 104; check "$(resumed)" 3 "backoff: …none at +104 min"
bo 105; check "$(resumed)" 4 "backoff: …the fourth at +105 min (60 min after the third)"
check "$(count 'wake of hub-4 failed' "$(J sbo)")" 4 "backoff: every failed attempt is journaled"
check "$(count 'delamain: sbo — wake failed' "$R/notify.log")" 4 "backoff: …and the owner notified each time"
# the hub shows activity after a wake: the episode is over, a later silence starts a new one at once
FX_NOW=$(utc_iso 106) FX age "$R/claude-home/projects/p/$B81.jsonl" 0
bo 110; check "$(state_val stages sbo hub episode)" "" "backoff: activity after the wake resets the episode"
check "$(resumed)" 4 "backoff: …and nothing is done while the hub is not silent"
bo 140; check "$(resumed)" 5 "backoff: …a new silence of 15 min starts a new episode: woken at once"
check "$(state_val stages sbo hub episode attempts)" 1 "backoff: …with one attempt"

# a wake that shows no sign of life: failed after 5 min, once (the resume itself exited 0)
B82=$(U 82); mk_bhub sbv $B82; FX jline sbv 16 "[exec-1] DONE a line while the wake leaves no trace"; reset_log
bv(){ AGENT_HUB_WATCHDOG_NOW=$(utc_iso "$1") WD run --stage sbv > "$R/tick.out" 2>&1; }
: > "$R/notify.log"; bv 0; check "$(resumed)" 1 "wake verification: the wake exits 0"
bv 3; check "$(count 'delamain: sbv' "$R/notify.log")" 0 "wake verification: nothing is said within 5 min"
bv 6; check "$(count 'delamain: sbv — wake failed' "$R/notify.log")" 1 "wake verification: no activity of the hub 5 min after the wake → failed, the owner is notified"
grep -q "\[watchdog\] wake of hub-4 failed (no activity of the hub within 5 min)" "$(J sbv)"; check $? 0 "wake verification: …and the journal says so"
bv 7; check "$(count 'delamain: sbv — wake failed' "$R/notify.log")" 1 "wake verification: …only once"
# R4: a hub that fails again after the wake (another API error record) is not "recovered": the backoff goes on
B83=$(U 83); mk_bhub sr4loop $B83; FX transcript $B83 16 error; reset_log
bl(){ AGENT_HUB_WATCHDOG_NOW=$(utc_iso "$1") WD run --stage sr4loop > "$R/tick.out" 2>&1; }
bl 0; check "$(resumed)" 1 "R4 loop: the first wake"
python3 - "$CLAUDE_CONFIG_DIR/projects/p/$B83.jsonl" "$(utc_iso 1)" <<'PY'
import json, os, sys, datetime as dt
t = dt.datetime.fromisoformat(sys.argv[2]).replace(tzinfo=dt.timezone.utc)
rec = {"type": "assistant", "isSidechain": False, "timestamp": t.strftime("%Y-%m-%dT%H:%M:%S.000Z"), "error": "rate_limit",
       "isApiErrorMessage": True, "message": {"role": "assistant", "model": "<synthetic>", "content": []}}
open(sys.argv[1], "a").write(json.dumps(rec) + "\n"); os.utime(sys.argv[1], (t.timestamp(), t.timestamp()))
PY
bl 10; check "$(state_val stages sr4loop hub episode attempts)" 1 "R4 loop: a new API-error record after the wake keeps the episode (not a recovery)"
bl 20; check "$(resumed)" 2 "R4 loop: …the second wake when the new error is 15 min old and the backoff has passed"
bl 21; check "$(resumed)" 2 "R4 loop: …and the next one waits 30 min"

# ---------------------------------------------------------------- privacy: only the stage name and counts leave the machine
D2=$(U 91); D2CLI=$(U 92); printf '{"sessionId":"local_%s","cliSessionId":"%s","title":"Hub secret","isArchived":false}' "$D2" "$D2CLI" > "$CLAUDE_SESSIONS_DIR/a/b/local_$D2.json"
TS=spr; mkdir -p "$R/spr/coordinator/work"; "$B/roles" set --stage spr hub "local_$D2" --kind desktop --tag hub-5 > /dev/null
FX backdate spr 120; FX transcript "$D2CLI" 20 ok
FX jline spr 16 "[exec-1] DONE needle-zq41 the secret line text"
$B/ask add --stage spr --blocks x --default "needle-qq77 default" --due 2020-01-01T10:00 "needle-qq78 secret question" > /dev/null
: > "$R/notify.log"; : > "$R/remote.log"
AGENT_HUB_NOTIFY_CMD="[\"$FB/remotecmd\",\"--data\",\"{message}\"]" WD run --stage spr > "$R/tick.out" 2>&1
grep -q "delamain: spr — hub silent [0-9]* min, 1 lines waiting" "$R/notify.log"; check $? 0 "privacy: the local notification carries the stage name, minutes and the count"
grep -q "^remote: --data delamain: spr — hub silent [0-9]* min, 1 lines waiting$" "$R/remote.log"; check $? 0 "privacy: …and so does the remote one (the {message} placeholder replaced)"
leaks=$(cat "$R/notify.log" "$R/remote.log" | grep -c -e needle -e "$D2" -e "$D2CLI" -e 'hub-5' -e '/'); check "$leaks" 0 "privacy: no line text, question text, session id, tag or path in any notification"
grep -q needle-zq41 "$(J spr)"; check $? 0 "privacy control: the secret text is in the journal, so the grep above could have found it"

# ---------------------------------------------------------------- dry run: a plan, and nothing written
mk_dhub sdr; FX jline sdr 16 "[exec-1] DONE a line for the dry run"
WD2=$R/w-sdr; (cd "$WD2" && FAKE_HOLD=60 "$B/agent" spawn --stage sdr --role w1 --cwd "$WD2" --model haiku --brief "$WD2/b.md" > "$WD2/spawn-w1.out" 2>&1)
PD=$(python3 -c "import json;print(json.load(open('$R/sdr/agents/w1/meta.json'))['pid'])"); kill -KILL -- -$PD; for i in $(seq 1 40); do kill -0 $PD 2>/dev/null || break; sleep 0.25; done
$B/ask add --stage sdr --blocks x --default "plan it" --due 2020-01-01T10:00 "overdue in the dry run" > /dev/null
n0=$(nl "$R/claude.log"); before=$(snap "$R"); WD run --dry-run --stage sdr > "$R/dry.out" 2>&1; check $? 0 "dry run: exits 0"
# R7 reads `claude agents --json` even in a dry run: the fake logs that call, and only reads are allowed to show up there
check "$(tail -n +$((n0 + 1)) "$R/claude.log" | python3 -c 'import json,sys; print(sum(json.loads(l)["argv"][:1] != ["agents"] for l in sys.stdin if l.strip()))')" 0 "dry run: the only claude calls are reads (agents --json)"
head -n "$n0" "$R/claude.log" > "$R/claude.log.tmp"; mv "$R/claude.log.tmp" "$R/claude.log"; after=$(snap "$R")
check "$after" "$before" "dry run: not one file of the home changed (journal, state, markers, agents, notifications)"
grep -q "^\[plan\] sdr: would write \`EXIT w1: killed (no result)\`" "$R/dry.out"; check $? 0 "dry run: plans the EXIT line (R1)"
grep -q "^\[plan\] sdr: journal: @hub OVERDUE .* default: plan it" "$R/dry.out"; check $? 0 "dry run: plans the overdue line (R2)"
grep -q "^\[plan\] sdr: would wake hub-3 (agent send --stage sdr hub-3): 1 lines waiting since" "$R/dry.out"; check $? 0 "dry run: plans the wake with its transport (R3)"
check "$(runs sdr)" 2 "dry run: …and does not run it (runs: the hub and the killed worker)"
WD run --stage sdr > /dev/null 2>&1; [ "$(snap "$R")" != "$before" ]; check $? 0 "dry run control: a real tick does change the home"

# ---------------------------------------------------------------- the hub record and the takeover digest
mkdesk(){ printf '{"sessionId":"local_%s","cliSessionId":"%s","title":"%s","isArchived":false}' "$1" "$2" "$3" > "$CLAUDE_SESSIONS_DIR/a/b/local_$1.json"; }
host_of(){ python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['roles']['hub'].get('host',''))" "$R/$1/roles.json"; }
mkdir -p "$CLAUDE_CONFIG_DIR/sessions"
H1=$(U 101); H1C=$(U 102); mkdesk "$H1" "$H1C" "Hub sh1 #1"; mkdir -p "$R/sh1/coordinator/work"
$B/hub takeover --stage sh1 --session "local_$H1" > "$R/take1.out" 2>&1; check $? 0 "takeover: a Desktop hub"
check "$(host_of sh1)" desktop "takeover: host: desktop is recorded for a Desktop hub"
mkdir -p "$R/sh2/coordinator/work"; H2=$(U 103)
printf '{"kind":"bg","sessionId":"%s","pid":4242,"status":"idle"}' "$H2" > "$CLAUDE_CONFIG_DIR/sessions/4242.json"
$B/hub takeover --stage sh2 --session "$H2" > "$R/take2.out" 2>&1; check "$(host_of sh2)" bg "takeover: host: bg for a session the CLI lists as a background one"
mkdir -p "$R/sh3/coordinator/work"; H3=$(U 104)
printf '{"kind":"interactive","sessionId":"%s","pid":4243,"status":"idle"}' "$H3" > "$CLAUDE_CONFIG_DIR/sessions/4243.json"
$B/hub takeover --stage sh3 --session "$H3" > "$R/take3.out" 2>&1; check "$(host_of sh3)" term "takeover: host: term for an interactive session"
mkdir -p "$R/sh4/coordinator/work"; H4=$(U 105)
$B/hub takeover --stage sh4 --session "$H4" > "$R/take4.out" 2>&1; check "$(host_of sh4)" "" "takeover: no host when the session is not found (the watchdog guesses for such a record)"
$B/hub takeover --stage sd --session "$(sid_of sd hub-3)" > "$R/take5.out" 2>&1; check "$(host_of sd)" detached "takeover: host: detached for a headless hub"
grep -q "^watchdog is on (a tick every 5 min)" "$R/take2.out"; check $? 0 "takeover: the digest says the watchdog is on"
AGENT_HUB_WATCHDOG=off $B/hub takeover --stage sh2 --session "$H2" > "$R/take6.out" 2>&1
grep -q "^watchdog is on" "$R/take6.out"; check $? 1 "takeover negative: no watchdog line when it is off and nothing is paused"
WD quiet --stage sh2 --reason "owner away" --for 2h > /dev/null; AGENT_HUB_WATCHDOG=off $B/hub takeover --stage sh2 --session "$H2" > "$R/take7.out" 2>&1
grep -q "^wake-ups of stage sh2 are paused by owner until .*: owner away — \`watchdog quiet --stage sh2 --clear\` lifts it" "$R/take7.out"; check $? 0 "takeover: an active marker is in the digest (and a takeover does not clear it)"
test -f "$R/sh2/do-not-wake.json"; check $? 0 "takeover: the marker is still there"

# ---------------------------------------------------------------- jwait: the hub's filter, the armed file's end
python3 - "$B" <<'PY'
import importlib.machinery, importlib.util, sys
sys.path.insert(0, sys.argv[1])
import hubcore as hc
l = importlib.machinery.SourceFileLoader("jwait_t", sys.argv[1] + "/jwait")
jw = importlib.util.module_from_spec(importlib.util.spec_from_loader("jwait_t", l)); l.exec_module(jw)
f = jw.hub_filter("stage-a", "hub-3")
assert f.tags == ["hub-3", "hub"] and [p.pattern for p in f.patterns] == [hc.status_pattern()], (f.tags, f.patterns)
yes = ["- 10:00 [exec-1] DONE x", "- 10:00 [exec-1] @hub-3 look", "- 10:00 [exec-1] @hub look", "- 10:00 [core-c-hub-9] @stage-a-hub-3 look",
       "- 10:00 [watchdog] @hub OVERDUE Q-A-001 default: x"]
no = ["- 10:00 [hub-3] DONE x", "- 10:00 [hub-3/sub] DONE x", "- 10:00 [exec-1] chatter", "- 10:00 [exec-1] @hub-30 look",
      "- 10:00 [stage-a-hub-3] DONE x"]
bad = [t for t in yes if not f.accepts(t)] + [t for t in no if f.accepts(t)]
assert not bad, bad
PY
check $? 0 "jwait.hub_filter: the digest jwait's tags and pattern; the hub's own lines left out, @hub / @hub-N / @<stage>-hub-N in"
grep -q -- "--tag hub-1 --tag hub --hub-events" "$R/take1.out"; check $? 0 "jwait.hub_filter: …the same tags that hub takeover prints in its first jwait command"
mkdir -p "$R/sj/coordinator/work"
"$B/jwait" --journal --stage sj --caller hub-9 --settle 1 --for 3s > "$R/j1.out" 2>&1; check $? 3 "jwait: the deadline passes (exit 3)"
test -f "$R/.jwait-state/sj/hub-9.armed.json"; check $? 1 "jwait: the armed file is gone after exit 3"
"$B/jwait" --journal --stage sj --caller hub-9 --settle 1 --for 60s > "$R/j2.out" 2>&1 & JW=$!
armed "$R/j2.out"; "$B/jlog" --stage sj --tag exec-1 "DONE the thing" > /dev/null; wait $JW; check $? 0 "jwait: a line is delivered (exit 0)"
test -f "$R/.jwait-state/sj/hub-9.armed.json"; check $? 1 "jwait: the armed file is gone after exit 0"
"$B/jwait" --until "$(utc_hms 2)" --note "alarm only" > "$R/j3.out" 2>&1; check $? 3 "jwait: a pure alarm (no journal) exits 3"
find "$R/.jwait-state" -name '*anon*.armed.json' 2>/dev/null | grep -q .; check $? 1 "jwait negative: a pure alarm writes no armed file"

# M3: the backoff never overflows (attempt 100: 15 min * 2**99 would not fit a timedelta)
B81=$(U 81); mk_bhub sm3 $B81; FX jline sm3 16 "[exec-1] DONE a line is waiting"
reset_log; tick > /dev/null; check "$(resumed)" 1 "M3: first wake"
python3 - "$R/.state/watchdog/state.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); ep = d["stages"]["sm3"]["hub"]["episode"]
ep["attempts"] = 99; ep["next_try_at"] = None; ep["result"] = "notified"
json.dump(d, open(sys.argv[1], "w"))
PY
reset_log; check "$(tick)" 0 "M3: attempt 100 — the tick exits 0"
check "$(resumed)" 1 "M3: …and the hub is woken (no OverflowError)"
check "$(state_val stages sm3 hub episode attempts)" 100 "M3: …the attempt counter moved to 100"
python3 - "$R/.state/watchdog/state.json" <<'PY'
import datetime as dt, json, sys
ep = json.load(open(sys.argv[1]))["stages"]["sm3"]["hub"]["episode"]
gap = dt.datetime.fromisoformat(ep["next_try_at"]) - dt.datetime.fromisoformat(ep["acted_at"])
assert gap == dt.timedelta(hours=4), gap
PY
check $? 0 "M3: …and the next try is the backoff cap (4 h) away"

# M4: a damaged state file is normalised, with a warning; the tick goes on
B82=$(U 82); mk_bhub sm4 $B82; FX jline sm4 16 "[exec-1] DONE a line is waiting"
echo '{"stages": null}' > "$R/.state/watchdog/state.json"
reset_log; check "$(tick)" 0 "M4: {\"stages\": null} — the tick exits 0"
check "$(resumed)" 1 "M4: …and the stage is still handled (the hub woken)"
grep -q "state.json .stages. is not an object" "$R/tick.out"; check $? 0 "M4: …a warning on stderr"
python3 - "$R/.state/watchdog/state.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); assert isinstance(d["stages"], dict) and all(isinstance(v, dict) for v in d["stages"].values()), d
PY
check $? 0 "M4: …and the saved state is a dict of dicts"
echo '{"stages": {"sm4": 5}}' > "$R/.state/watchdog/state.json"
reset_log; check "$(tick)" 0 "M4: a stage entry that is not an object — the tick exits 0"
check "$(resumed)" 1 "M4: …the hub is woken"
grep -q "entry of stage sm4 is not an object" "$R/tick.out"; check $? 0 "M4: …with a warning"
echo '[1, 2]' > "$R/.state/watchdog/state.json"
check "$(tick)" 0 "M4: a state that is not even an object — the tick exits 0"

# M4 (nested): a corrupt value inside a stage's state resets that stage, with one stderr line; the next tick is normal
B83=$(U 83); mk_bhub sm5 $B83; FX jline sm5 16 "[exec-1] DONE a line is waiting"
reset_log; tick > /dev/null; check "$(resumed)" 1 "M4 nested: first wake"
python3 - "$R/.state/watchdog/state.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["stages"]["sm5"]["hub"]["episode"] = 5
json.dump(d, open(sys.argv[1], "w"))
PY
reset_log; check "$(tick)" 0 "M4 nested: hub.episode = 5 — the tick exits 0"
grep -q "watchdog: stage sm5: state reset after" "$R/tick.out"; check $? 0 "M4 nested: …one stderr line names the stage and the error"
check "$(state_val stages sm5)" "{}" "M4 nested: …the stage's state was reset, the corrupt value not saved back"
reset_log; check "$(tick)" 0 "M4 nested: the next tick exits 0"
grep -q "state reset after" "$R/tick.out"; check $? 1 "M4 nested negative: …with no error this time"
check "$(resumed)" 1 "M4 nested: …and handles the stage normally (the hub is woken)"
python3 - "$R/.state/watchdog/state.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["stages"]["sm5"]["r2_sent"] = 7; d["stages"]["sm5"]["hub"]["episode"].update(attempts="x", next_try_at=None)
json.dump(d, open(sys.argv[1], "w"))
PY
check "$(tick)" 0 "M4 nested: r2_sent not a dict, attempts not an int — the tick exits 0"
check "$(state_val stages sm5)" "{}" "M4 nested: …the stage's state is reset again"

# ---------------------------------------------------------------- never a successor, and one broken stage does not stop the rest
mkdir -p "$R/sbad"; echo '{' > "$R/sbad/roles.json"
reset_log; WD run > "$R/all.out" 2>&1; check $? 0 "a tick over every stage exits 0, also with one stage whose registry is broken"
grep -q "sbad: " "$R/all.out"; check $? 0 "…and names the broken stage"
cat "$R/claude.all" "$R/claude.log" > "$R/claude.everything"
python3 - "$R/claude.everything" <<'PY'
import json, sys
calls = [json.loads(l)["argv"] for l in open(sys.argv[1]) if l.strip()]
starts = [a for a in calls if "--bg" in a and "--resume" not in a]
fresh = [a for a in calls if "--session-id" in a or "-n" in a]
assert calls and not starts and not fresh, (starts, fresh)
assert all(a[0] in ("agents", "stop", "--bg") for a in calls), [a for a in calls if a[0] not in ("agents", "stop", "--bg")]
PY
check $? 0 "never a successor: across the whole suite the fake claude saw only agents, stop and --bg --resume (no --bg without --resume, no new session id)"
spawned=$(ls -d "$R"/*/agents/*/ | xargs -n1 basename | sort -u | tr '\n' ' ')
check "$spawned" "hub-3 w1 w2 w3 " "never a successor: no agent was spawned by the watchdog (only the fixtures' own)"
! grep -nE "\"(spawn|succeed)\"|'(spawn|succeed)'|--session-id|exec resume" "$B/watchdog" > /dev/null; check $? 0 "never a successor: the tool's source holds no spawn / succeed / new-session argv"
exit $fail
