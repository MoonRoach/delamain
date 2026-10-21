#!/bin/bash
# Watchdog R7, the false-positive audit: a session that is still needed is never stopped. Each risk has a test that leaves
# the session alone and a control in the same world that shows it IS stopped once the guard has nothing to hold on to.
#   homes:    a live role / a pending successor / a prefix of either in ANOTHER hub home; an unreadable registry, roles.json,
#             auto-handoff.json or config.json of another home, or an unreadable registry of homes: nothing is stopped;
#             AGENT_HUB_WATCHDOG_REAP=off in another home protects the hubs retired there
#   takeover: the sessions named by a running `hub takeover` / `hub start` (marker <stage>/.takeover-<pid>.json): alive,
#             dead pid, older than 6 h, unreadable; and the real command, which runs the watchdog from its own project step
#   activity: a process started a minute ago (real start time from `ps`; the row's startedAt is not used), a process that is not
#             there, a transcript dated in the future, a transcript that is not found (kept under another CLAUDE_CONFIG_DIR),
#             a running sub-agent (a file appended to in a directory whose own time is old), a scan that is cut short or fails,
#             a session that wrote between the first look and the stop
#   busy:     a status other than idle/done (busy, blocked, working, waiting, none), a shell child of the process: reported once a
#             day in the job output and the stage journal, never stopped; an MCP-like child is not a reason
#   config:   the own home's config.json read fresh before each stop, and strictly (corrupt: nothing is stopped)
#   homes:    …also a registered home that exists but cannot be reached (a parent that cannot be searched)
#   kinds:    a Desktop, terminal, headless or kind-less row; a grill session (live, or retired as a grill)
#   registry: a retired hub that is the hub of another stage now; a live role in a stage closed with `hub close`
# Stand-in CLI only. Run against a copy of bin/ (BIN=<dir>) with one guard removed, a test here must fail.
. "$(dirname "$0")/lib.sh"
new_home; R=$AGENT_HUB_HOME
export HOME=$R/home; mkdir -p "$HOME"
export CLAUDE_CONFIG_DIR=$R/claude-home CLAUDE_SESSIONS_DIR=$R/desktop
export CLAUDE_BIN=$T/fake_claude_wd.py FAKE_WD_ROWS=$R/rows.json FAKE_WD_LOG=$R/claude.log
export AGENT_HUB_WATCHDOG=on
unset AGENT_HUB_NOTIFY_CMD AGENT_HUB_WATCHDOG_REAP AGENT_HUB_WATCHDOG_WAKE_AFTER FAKE_WD_AGENTS FAKE_WD_STOP FAKE_WD_ON_AGENTS FAKE_WD_ON_STOP
# the tick's clock runs OFFSET minutes ahead of the real one: the real processes of the rows (started when the test did) are
# then OFFSET minutes old, and the transcripts and journals are dated from that clock
at_offset(){ python3 -c 'import datetime as d,sys; print((d.datetime.now(d.timezone.utc) + d.timedelta(minutes=int(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%S"))' "$1"; }
NOW=$(at_offset 40); export FX_NOW=$NOW AGENT_HUB_WATCHDOG_NOW=$NOW
export AT5=$(python3 -c 'import datetime as d,sys; print((d.datetime.fromisoformat(sys.argv[1]) - d.timedelta(minutes=5)).strftime("%Y-%m-%dT%H:%M:%S"))' "$NOW")
: > "$R/claude.log"
FB=$R/fakebin; mkdir -p "$FB"; : > "$R/notify.log"; : > "$R/remote.log"   # a notification would land here, never on the machine
for n in osascript notify-send; do printf '#!/bin/sh\necho "local: $*" >> "%s"\n' "$R/notify.log" > "$FB/$n"; chmod +x "$FB/$n"; done
export PATH="$FB:$PATH"
FX(){ python3 "$T/watchdog_fixture.py" "$@"; }
WD(){ "$B/watchdog" "$@"; }
stops(){ FX claude-calls "$R/claude.log" | grep '^stop ' | sort | tr '\n' ' '; }
reset_log(){ : > "$R/claude.log"; }
CWD=$R/cwd; mkdir -p "$CWD"; export FX_CWD=$CWD
sid(){ printf '%s-0000-4000-8000-000000000000' "$1"; }
# Real processes stand in for the sessions' processes (their start time is read with `ps`). They run with every descriptor
# closed (a leftover holding the test's stdout would hang whoever reads it to the end) and are killed with their children.
sleep 3000 > /dev/null 2>&1 < /dev/null & LIVE=$!   # a process that runs and has no children
PIDS=$LIVE
killtree(){ local c; for c in $(pgrep -P "$1" 2>/dev/null); do killtree "$c"; done; kill "$1" 2>/dev/null; return 0; }
trap 'for p in $PIDS; do killtree $p; done; chmod -R u+rwx "$R" 2>/dev/null; test_cleanup' EXIT
spawn(){ "$@" > /dev/null 2>&1 < /dev/null & SPAWNED=$!; PIDS="$PIDS $SPAWNED"; }   # a real process of its own: its start time is the real one
H2=$(mktemp -d)                                   # a second hub home, known to the registry of homes once a role is set in it
RB(){ AGENT_HUB_HOME=$H2 "$B/roles" "$@"; }       # roles of the second home
retire_hub(){ "$B/roles" set --stage "$1" hub "$2" --kind cli --tag "$3" > /dev/null; "$B/roles" retire --stage "$1" hub --note "test" > /dev/null; }
quiet_for(){ FX transcript "$1" "$2" ok; }
# rows "sid[|kind[|startedAt-minutes-ago[|status[|state]]]]"…: the rows `claude agents --json` prints, all with the process $ROWPID
# (default $LIVE); kind "-": no kind key; status/state "-": no such key. The startedAt of a row is there to show it is not used.
rows(){ python3 - "$FAKE_WD_ROWS" "${ROWPID:-$LIVE}" "$NOW" "$@" <<'PY'
import datetime as d, json, sys
out, live, now, *specs = sys.argv[1:]
t0 = d.datetime.fromisoformat(now).replace(tzinfo=d.timezone.utc)
res = []
for spec in specs:
    p = (spec.split("|") + ["", "", "", ""])[:5]
    sid, kind, started, status, state = p[0], p[1] or "background", p[2], p[3] or "idle", p[4] or "done"
    r = {"id": sid[:8], "sessionId": sid, "kind": kind, "status": status, "state": state, "pid": int(live), "cwd": "/tmp", "name": "hub"}
    for key, val in (("kind", kind), ("status", status), ("state", state)):
        if val == "-":
            del r[key]
    if started:
        r["startedAt"] = int((t0 - d.timedelta(minutes=int(started))).timestamp() * 1000)
    res.append(r)
json.dump(res, open(out, "w"))
PY
}
# tick LABEL: one real tick over the rows set; the exit code is checked, the stops are read with stopped
tick(){ reset_log; WD run > "$R/tick.out" 2>&1; check $? 0 "$1: the tick exits 0"; }
stopped(){ check "$(stops)" "$2" "$1"; }
aborted(){ grep -q "machine: not stopping any retired hub's session this tick: .*$2" "$R/tick.out"; check $? 0 "$1: one line says why"; }

# ================================================================== homes
# a live role of a session in another home
X=$(sid e0000001); retire_hub a "$X" hub-1; quiet_for "$X" 30
RB set --stage x hub "$X" --kind cli --tag hub-9 > /dev/null
rows "$X"; tick "live role in home B"; stopped "live role in home B (retired as a hub in A): not stopped" ""
RB retire --stage x hub --note t > /dev/null
rows "$X"; tick "control, role retired in B"; stopped "control: retired in B as well, quiet 30 min: stopped" "stop e0000001 "

# a pending successor in another home: its id, and the bg_id of a launch that became a headless fallback
X=$(sid e0000002); retire_hub a "$X" hub-2; quiet_for "$X" 30
python3 - "$H2/y" "${X:0:8}" <<'PY'
import json, os, sys
os.makedirs(sys.argv[1], exist_ok=True)
json.dump({"chain": 1, "pending": {"n": 4, "kind": "bg", "id": sys.argv[2], "at": __import__("os").environ["AT5"], "taken_over": False}}, open(sys.argv[1] + "/auto-handoff.json", "w"))
PY
rows "$X"; tick "pending successor in home B"; stopped "pending successor of a stage of home B: not stopped" ""
python3 - "$H2/y" "${X:0:8}" <<'PY'
import json, sys
json.dump({"chain": 1, "pending": {"n": 4, "kind": "headless", "id": "headless", "bg_id": sys.argv[2], "at": __import__("os").environ["AT5"]}}, open(sys.argv[1] + "/auto-handoff.json", "w"))
PY
rows "$X"; tick "bg_id of a pending launch in home B"; stopped "the bg_id of a pending launch in home B: not stopped" ""
rm "$H2/y/auto-handoff.json"
rows "$X"; tick "control, no pending record"; stopped "control: without the pending record: stopped" "stop e0000002 "

# a prefix: a live role of ANOTHER session in home B with the first 8 characters of the listed retired hub
X=deadbeef-aaaa-4000-8000-000000000000; Y=deadbeef-bbbb-4000-8000-000000000000
retire_hub a "$X" hub-3; quiet_for "$X" 30
RB set --stage x hub "$Y" --kind cli --tag hub-10 > /dev/null
rows "$X"; tick "prefix of a live role in home B"; stopped "a live role of home B shares the 8 characters (claude stop takes the short id): not stopped" ""
RB retire --stage x hub --note t > /dev/null
rows "$X"; tick "control, prefix gone"; stopped "control: the other session retired: stopped" "stop deadbeef "

# home B cannot be read: roles.json, auto-handoff.json, config.json; the registry of homes itself
X=$(sid e0000003); retire_hub a "$X" hub-4; quiet_for "$X" 30
mkdir -p "$H2/z"; echo '{' > "$H2/z/roles.json"
rows "$X"; tick "broken roles.json in home B"; stopped "roles.json of a stage of home B is broken: nothing is stopped" ""; aborted "broken roles.json in home B" "$H2/z/roles.json"
echo '{"roles": []}' > "$H2/z/roles.json"
rows "$X"; tick "roles.json of a wrong shape in home B"; stopped "roles.json of home B has the wrong shape: nothing is stopped" ""
rm "$H2/z/roles.json"; echo '[]' > "$H2/z/auto-handoff.json"
rows "$X"; tick "broken auto-handoff.json in home B"; stopped "auto-handoff.json of home B is broken: nothing is stopped" ""; aborted "broken auto-handoff.json in home B" "$H2/z/auto-handoff.json"
rm "$H2/z/auto-handoff.json"; echo '{' > "$H2/config.json"
rows "$X"; tick "broken config.json in home B"; stopped "config.json of home B is broken (its REAP setting is unknown): nothing is stopped" ""; aborted "broken config.json in home B" "$H2/config.json"
rm "$H2/config.json"
REG=$XDG_CONFIG_HOME/delamain/homes.json; cp "$REG" "$R/homes.json.bak"; echo 'not json' > "$REG"
rows "$X"; tick "broken registry of homes"; stopped "the registry of homes cannot be read (a home may be missing): nothing is stopped" ""; aborted "broken registry of homes" "registry of homes cannot be read"
cp "$R/homes.json.bak" "$REG"
rows "$X"; tick "control, everything readable"; stopped "control: with every file readable the session is stopped" "stop e0000003 "
rmdir "$H2/z"

# AGENT_HUB_WATCHDOG_REAP=off in another home protects the hubs retired there (the setting is per home)
X=$(sid e0000004); retire_hub a "$X" hub-5; quiet_for "$X" 30
RB set --stage w hub "$X" --kind cli --tag hub-1 > /dev/null; RB retire --stage w hub --note t > /dev/null
echo '{"AGENT_HUB_WATCHDOG_REAP": "off"}' > "$H2/config.json"
rows "$X"; tick "REAP=off in home B"; stopped "retired as a hub in home B too, where REAP=off: not stopped" ""
echo '{"AGENT_HUB_WATCHDOG_REAP": false}' > "$H2/config.json"
rows "$X"; tick "REAP=false in home B"; stopped "REAP false (a JSON boolean) in home B: not stopped" ""
echo '{"AGENT_HUB_WATCHDOG_REAP": "on"}' > "$H2/config.json"
rows "$X"; tick "REAP=on in home B"; stopped "control: REAP=on in home B: stopped" "stop e0000004 "
rm "$H2/config.json"
X=$(sid e0000005); retire_hub a "$X" hub-6; quiet_for "$X" 30; rows "$X"
reset_log; AGENT_HUB_WATCHDOG_REAP=off WD run > "$R/tick.out" 2>&1
stopped "REAP=off in the environment of the watchdog's own home: not stopped" ""

# ================================================================== takeover
# the marker of a running `hub takeover` / `hub start`: <stage>/.takeover-<pid>.json
mark(){ python3 - "$R/a/.takeover-$1.json" "$2" "$3" <<'PY'
import json, sys
json.dump({"pid": int(sys.argv[2]), "at": "2026-10-07T11:59:00", "sessions": [sys.argv[3]]}, open(sys.argv[1], "w"))
PY
}
X=$(sid e0000006); retire_hub a "$X" hub-7; quiet_for "$X" 30
mark 1 "$LIVE" "$X"; rows "$X"; tick "marker of a running takeover"; stopped "a running takeover names the session: not stopped" ""
DEAD=$(sh -c 'echo $$'); mark 1 "$DEAD" "$X"
rows "$X"; tick "marker of a dead process"; stopped "control: the marker's process is gone (a killed command): stopped" "stop e0000006 "
X=$(sid e0000007); retire_hub a "$X" hub-8; quiet_for "$X" 30
mark 1 "$LIVE" "$X"; FX age "$R/a/.takeover-1.json" 420
rows "$X"; tick "marker older than 6 h"; stopped "control: a marker older than 6 hours is a left-over: stopped" "stop e0000007 "
X=$(sid e0000008); retire_hub a "$X" hub-9; quiet_for "$X" 30
echo '{' > "$R/a/.takeover-1.json"
rows "$X"; tick "unreadable recent marker"; stopped "a marker that cannot be read and is recent may belong to a command that runs: nothing is stopped" ""; aborted "unreadable recent marker" "takeover-1.json"
FX age "$R/a/.takeover-1.json" 420
rows "$X"; tick "unreadable old marker"; stopped "control: the same marker, 7 hours old: stopped" "stop e0000008 "
rm -f "$R/a/.takeover-1.json"

# the real command: a retired hub takes the shift again and the watchdog runs inside its project step
X=$(sid e0000009); H=$(sid e000000a)
retire_hub tk "$X" hub-1; "$B/roles" set --stage tk hub "$H" --kind cli --tag hub-2 > /dev/null; quiet_for "$X" 30
cat > "$R/tk/takeover.sh" <<EOF
#!/bin/sh
if [ "\$1" = apply ]; then "$B/watchdog" run > "$R/inner.out" 2>&1; ls "$R"/tk/.takeover-*.json > "$R/inner.markers" 2>&1; : > "$R/tk.applied"; exit 0; fi
[ -f "$R/tk.applied" ]
EOF
chmod +x "$R/tk/takeover.sh"
rows "$X"; reset_log
CLAUDE_CODE_SESSION_ID=$X "$B/hub" takeover --stage tk --session "$X" --n 5 > "$R/take.out" 2>&1; check $? 0 "hub takeover by a retired hub: exits 0"
check "$(grep -c "takeover-[0-9]*.json" "$R/inner.markers")" 1 "hub takeover: the marker exists while the project step runs"
check "$(stops)" "" "hub takeover: the watchdog run by the project step does not stop the session that runs the takeover"
check "$(ls "$R"/tk/.takeover-*.json 2>/dev/null | wc -l | tr -d ' ')" 0 "hub takeover: the marker is gone when the command has ended"
check "$("$B/roles" list --stage tk 2>/dev/null | grep -c "$X")" 1 "hub takeover: the session is the registered hub afterwards"
rm -f "$R/tk.applied"
"$B/hub" takeover --stage tk --session "$X" --n 5 --dry-run > "$R/take-dry.out" 2>&1; check $? 0 "hub takeover --dry-run: exits 0"
check "$(ls "$R"/tk/.takeover-*.json 2>/dev/null | wc -l | tr -d ' ')" 0 "hub takeover --dry-run: no marker is left"

# ================================================================== activity
# resumed a minute ago and idle: the transcript is old, the process is new. The start is the real one, found with `ps`: the
# tick's clock is 2 minutes ahead of the real one for a process that started now, 40 for the control
X=$(sid e000000b); retire_hub a "$X" hub-10; spawn sleep 3000; ROWPID=$SPAWNED
NOW=$(at_offset 2); export FX_NOW=$NOW AGENT_HUB_WATCHDOG_NOW=$NOW; quiet_for "$X" 30
rows "$X|||"; tick "process 2 min old"; stopped "the process started 2 minutes ago (resumed, idle), the transcript is 30 min old: not stopped" ""
NOW=$(at_offset 40); export FX_NOW=$NOW AGENT_HUB_WATCHDOG_NOW=$NOW; quiet_for "$X" 30
rows "$X|||"; tick "process 40 min old"; stopped "control: the same process seen by a clock 40 minutes ahead: stopped" "stop e000000b "
# the row's own startedAt says nothing: an old one on a young process, a young one on an old process
X=$(sid e00000a1); retire_hub a "$X" hub-40; spawn sleep 3000; ROWPID=$SPAWNED
NOW=$(at_offset 2); export FX_NOW=$NOW AGENT_HUB_WATCHDOG_NOW=$NOW; quiet_for "$X" 30
rows "$X||300"; tick "old startedAt, young process"; stopped "startedAt says 300 min ago, the process started 2: not stopped" ""
NOW=$(at_offset 40); export FX_NOW=$NOW AGENT_HUB_WATCHDOG_NOW=$NOW; quiet_for "$X" 30
rows "$X||1"; tick "young startedAt, old process"; stopped "control: startedAt says 1 minute ago, the process is 40 min old: stopped" "stop e00000a1 "
unset ROWPID
# a pid that is not in the process table: the start of the process cannot be told
X=$(sid e00000a2); retire_hub a "$X" hub-41; quiet_for "$X" 30
DEADPID=$(sh -c 'echo $$'); ROWPID=$DEADPID rows "$X"; tick "pid not running"; stopped "the row names a pid that does not run: not stopped" ""
rows "$X"; tick "control, running pid"; stopped "control: a running process: stopped" "stop e00000a2 "
# a transcript dated in the future (clock skew, a synced directory): the quiet time is negative
X=$(sid e000000c); retire_hub a "$X" hub-11; FX transcript "$X" -30 ok
rows "$X"; tick "transcript from the future"; stopped "a transcript dated 30 minutes ahead of the clock: not stopped" ""
quiet_for "$X" 30
rows "$X"; tick "control, past transcript"; stopped "control: the same transcript dated 30 minutes ago: stopped" "stop e000000c "
# a transcript that is not found: the session may keep it under another CLAUDE_CONFIG_DIR
X=$(sid e000000d); retire_hub a "$X" hub-12
rows "$X||30"; tick "no transcript"; stopped "no transcript found, started 30 min ago: what it did since is unknown, not stopped" ""
mkdir -p "$R/elsewhere/projects/q"; CLAUDE_CONFIG_DIR=$R/elsewhere FX transcript "$X" 1 ok
rows "$X||30"; tick "transcript under another config dir"; stopped "a transcript written a minute ago under another CLAUDE_CONFIG_DIR is not seen: not stopped" ""
quiet_for "$X" 30
rows "$X||30"; tick "control, transcript here"; stopped "control: the transcript is found and 30 min old: stopped" "stop e000000d "
# a sub-agent that runs: the main transcript is quiet while <session>/subagents/ is written
X=$(sid e000000e); retire_hub a "$X" hub-13; quiet_for "$X" 30
SUB=$CLAUDE_CONFIG_DIR/projects/p/$X
mkdir -p "$SUB/subagents"; echo '{}' > "$SUB/subagents/agent-a1.jsonl"
FX age "$SUB/subagents/agent-a1.jsonl" 2; FX age "$SUB/subagents" 2; FX age "$SUB" 2
rows "$X"; tick "running sub-agent"; stopped "a sub-agent wrote 2 minutes ago, the main transcript 30: not stopped" ""
FX age "$SUB/subagents/agent-a1.jsonl" 30; FX age "$SUB/subagents" 30; FX age "$SUB" 30
rows "$X"; tick "finished sub-agent"; stopped "control: the sub-agent wrote 30 minutes ago too: stopped" "stop e000000e "
# a session that writes between the first look and the stop (the owner resumed it while the watchdog worked)
X=$(sid e000000f); retire_hub a "$X" hub-14; quiet_for "$X" 30; rows "$X"
reset_log; FAKE_WD_ON_AGENTS="2:python3 $T/watchdog_fixture.py transcript $X 1 ok" WD run > "$R/tick.out" 2>&1
stopped "the transcript is written between the first listing and the one right before the stop: not stopped" ""
quiet_for "$X" 30; rows "$X"; tick "control, nothing written"; stopped "control: nothing written: stopped" "stop e000000f "

# ================================================================== kinds
# only a `background` row is touched: a Desktop session, a terminal, a headless run, a row with no kind or an empty one
K1=$(sid e0000010); K2=$(sid e0000011); K3=$(sid e0000012); K4=$(sid e0000013); K5=$(sid e0000014); K6=$(sid e0000015)
n=20; for k in "$K1" "$K2" "$K3" "$K4" "$K5" "$K6"; do retire_hub a "$k" "hub-$n"; quiet_for "$k" 30; n=$((n + 1)); done
python3 - "$FAKE_WD_ROWS" "$LIVE" "$K1" "$K2" "$K3" "$K4" "$K5" "$K6" <<'PY'
import json, sys
out, live, *k = sys.argv[1:]
def row(sid, kind):
    r = {"id": sid[:8], "sessionId": sid, "kind": kind, "status": "idle", "state": "done", "pid": int(live), "cwd": "/tmp", "name": "hub"}
    if kind is None:
        del r["kind"]
    return r
json.dump([row(k[0], "interactive"), row(k[1], "desktop"), row(k[2], "headless"), row(k[3], None), row(k[4], ""), row(k[5], "background")], open(out, "w"))
PY
tick "row kinds"; stopped "interactive (a Desktop or terminal session), desktop, headless, no kind, empty kind: not stopped; background: stopped" "stop e0000015 "
# a grill session is a background session registered as the role `grill`: never a hub, so never a candidate
G1=$(sid e0000016); G2=$(sid e0000017)
"$B/roles" set --stage a grill "$G1" --kind cli --tag grill > /dev/null                                   # live grill
"$B/roles" set --stage a grill2 "$G2" --kind cli --tag grill > /dev/null; "$B/roles" retire --stage a grill2 --note "GRILLED" > /dev/null   # a finished one
quiet_for "$G1" 30; quiet_for "$G2" 30; rows "$G1" "$G2"; tick "grill sessions"
stopped "a live grill session and one retired as a grill (role is not hub): not stopped" ""

# ================================================================== registry
# a retired hub that is the registered hub of ANOTHER stage now
X=$(sid e0000018); retire_hub a "$X" hub-30; quiet_for "$X" 30
"$B/roles" set --stage d hub "$X" --kind cli --tag hub-1 > /dev/null
rows "$X"; tick "hub of another stage"; stopped "retired in stage a, registered hub of stage d: not stopped" ""
"$B/roles" retire --stage d hub --note t > /dev/null
rows "$X"; tick "control, retired in d as well"; stopped "control: retired in d too: stopped" "stop e0000018 "
# a live role in a stage closed with `hub close` (stage.json "closed"): the watchdog skips such a stage, the protection does not
X=$(sid e0000019); retire_hub a "$X" hub-31; quiet_for "$X" 30
"$B/roles" set --stage cl hub "$X" --kind cli --tag hub-1 > /dev/null
echo '{"closed": {"at": "2026-10-06T10:00", "why": "test"}}' > "$R/cl/stage.json"
rows "$X"; tick "live role in a closed stage"; stopped "a live role recorded in a closed stage still protects the session: not stopped" ""
"$B/roles" retire --stage cl hub --note t > /dev/null
rows "$X"; tick "control, role retired in the closed stage"; stopped "control: retired there too: stopped" "stop e0000019 "

# ================================================================== busy
# only an idle, done session is stopped; the others are reported once a day (job output, log.md, stage journal), no notification
JA=$AGENT_HUB_HOME/a/coordinator/work/journal-$(today).md
B1=$(sid e0000030); B2=$(sid e0000031); B3=$(sid e0000032); B4=$(sid e0000033); B5=$(sid e0000034); B6=$(sid e0000035); B7=$(sid e0000036)
n=50; for k in "$B1" "$B2" "$B3" "$B4" "$B5" "$B6" "$B7"; do retire_hub a "$k" "hub-$n"; quiet_for "$k" 30; n=$((n + 1)); done
rows "$B1|||busy|working" "$B2|||idle|blocked" "$B3|||idle|working" "$B4|||waiting|done" "$B5|||-|-" "$B6|||busy|done" "$B7"
tick "status and state"; stopped "busy/working, idle/blocked, idle/working, waiting/done, no status, busy/done: not stopped; idle/done: stopped" "stop e0000036 "
for pair in "e0000030 busy/working" "e0000031 idle/blocked" "e0000032 idle/working" "e0000033 waiting/done" "e0000034 ?/?" "e0000035 busy/done"; do
  set -- $pair
  grep -q "a: retired hub $1 (a) is $2 for 30 min; stop it by hand: claude stop $1" "$R/tick.out"; check $? 0 "report line for $1 ($2)"
  check "$(grep -c "retired hub $1 (a) is $2 for 30 min; stop it by hand: claude stop $1" "$JA")" 1 "…and one line in the stage journal for $1"
done
check "$(grep -c 'is .* for 30 min; stop it by hand' "$R/tick.out")" 6 "…and one report per not-idle session, nothing for the idle one"
reset_log; WD run > "$R/tick.out" 2>&1; check "$(grep -c 'stop it by hand' "$R/tick.out")" 0 "the second tick the same day: no report again"
check "$(grep -c 'stop it by hand' "$JA")" 6 "…and the journal keeps its six lines"
reset_log; FX_NOW=$(python3 -c 'import datetime as d,sys; print((d.datetime.fromisoformat(sys.argv[1]) + d.timedelta(days=1)).strftime("%Y-%m-%dT%H:%M:%S"))' "$NOW") \
  AGENT_HUB_WATCHDOG_NOW=$(python3 -c 'import datetime as d,sys; print((d.datetime.fromisoformat(sys.argv[1]) + d.timedelta(days=1)).strftime("%Y-%m-%dT%H:%M:%S"))' "$NOW") WD run > "$R/tick.out" 2>&1
check "$(grep -c 'stop it by hand' "$R/tick.out")" 6 "the next day: reported again, once"
grep -q "remote:\|local:" "$R/notify.log" "$R/remote.log"; check $? 1 "…and nothing was notified"
for k in "$B1" "$B2" "$B3" "$B4" "$B5" "$B6"; do "$B/roles" set --stage a hub "$k" --kind cli --tag live > /dev/null; done   # out of the way of the later scenarios
# a shell among the children of the process is a command in flight; an MCP-like child (not a shell) is not a reason
X=$(sid e0000037); retire_hub a "$X" hub-60; quiet_for "$X" 30
spawn python3 -c 'import subprocess, time; subprocess.Popen(["sh", "-c", "sleep 3001; true"]); time.sleep(3000)'; ROWPID=$SPAWNED; sleep 1
rows "$X"; tick "shell child"; stopped "the process has a shell child (a command in flight): not stopped" ""
grep -q "retired hub e0000037 (a) is running a shell command for 30 min; stop it by hand" "$R/tick.out"; check $? 0 "…and it is reported"
Y=$(sid e0000038); retire_hub a "$Y" hub-61; quiet_for "$Y" 30
spawn python3 -c 'import subprocess, time; subprocess.Popen(["sleep", "3002"]); time.sleep(3000)'; ROWPID=$SPAWNED; sleep 1
rows "$Y"; tick "MCP-like child"; stopped "control: a child that is not a shell (an MCP server): stopped" "stop e0000038 "
unset ROWPID

# the status or the process of the row changes between the first look and the fresh listing right before the stop
cat > "$R/hook-row.py" <<'PY'
import json, os
p = os.environ["FAKE_WD_ROWS"]; r = json.load(open(p))
for k, v in json.loads(os.environ["HOOK_SET"]).items():
    r[0][k] = v
json.dump(r, open(p, "w"))
PY
X=$(sid e0000070); retire_hub a "$X" hub-95; quiet_for "$X" 30; rows "$X"
reset_log; HOOK_SET='{"status": "busy", "state": "working"}' FAKE_WD_ON_AGENTS="2:python3 $R/hook-row.py" WD run > "$R/tick.out" 2>&1
stopped "the row turns busy between the first listing and the one right before the stop: not stopped" ""
rows "$X"
reset_log; HOOK_SET="{\"pid\": $$}" FAKE_WD_ON_AGENTS="2:python3 $R/hook-row.py" WD run > "$R/tick.out" 2>&1
stopped "the row names another process in the fresh listing: not stopped" ""
rows "$X"; tick "control, row unchanged"; stopped "control: nothing changes: stopped" "stop e0000070 "

# ================================================================== scans
# the activity of a session is unknown when its directory cannot be scanned completely: it is not stopped
X=$(sid e0000040); retire_hub a "$X" hub-70; quiet_for "$X" 30
SUB=$CLAUDE_CONFIG_DIR/projects/p/$X; mkdir -p "$SUB/subagents"
for i in 1 2 3 4 5; do echo '{}' > "$SUB/subagents/agent-$i.jsonl"; FX age "$SUB/subagents/agent-$i.jsonl" 30; done; FX age "$SUB/subagents" 30; FX age "$SUB" 30
rows "$X"; reset_log; AGENT_HUB_WATCHDOG_SCAN_CAP=3 WD run > "$R/tick.out" 2>&1
stopped "the session directory has more entries than the scan looks at: not stopped" ""
rows "$X"; tick "control, whole scan"; stopped "control: the whole directory scanned, all of it 30 min old: stopped" "stop e0000040 "
# a file appended to in a directory whose own time is old (the directory's time does not move on an append)
X=$(sid e0000041); retire_hub a "$X" hub-71; quiet_for "$X" 30
SUB=$CLAUDE_CONFIG_DIR/projects/p/$X; mkdir -p "$SUB/subagents/deep"; echo '{}' > "$SUB/subagents/deep/agent-1.jsonl"
FX age "$SUB/subagents/deep" 30; FX age "$SUB/subagents" 30; FX age "$SUB" 30; FX age "$SUB/subagents/deep/agent-1.jsonl" 2
rows "$X"; tick "appended file"; stopped "a file two levels down was written 2 min ago, every directory is 30 min old: not stopped" ""
FX age "$SUB/subagents/deep/agent-1.jsonl" 30
rows "$X"; tick "control, old file"; stopped "control: the file is 30 min old too: stopped" "stop e0000041 "
if [ "$(id -u)" != 0 ]; then   # a directory that cannot be read (root reads everything: skipped there)
  X=$(sid e0000042); retire_hub a "$X" hub-72; quiet_for "$X" 30
  SUB=$CLAUDE_CONFIG_DIR/projects/p/$X; mkdir -p "$SUB/subagents"; echo '{}' > "$SUB/subagents/agent-1.jsonl"
  FX age "$SUB/subagents/agent-1.jsonl" 30; FX age "$SUB/subagents" 30; FX age "$SUB" 30; chmod 000 "$SUB/subagents"
  rows "$X"; tick "unreadable sub-agent directory"; stopped "the sub-agent directory cannot be read: not stopped" ""
  chmod 755 "$SUB/subagents"
  rows "$X"; tick "control, readable"; stopped "control: readable and 30 min old: stopped" "stop e0000042 "
  X=$(sid e0000043); retire_hub a "$X" hub-73; quiet_for "$X" 30
  chmod 000 "$CLAUDE_CONFIG_DIR/projects/p"
  rows "$X"; tick "project directory that cannot be searched"; stopped "the project directory of the transcripts cannot be searched: not stopped" ""
  chmod 755 "$CLAUDE_CONFIG_DIR/projects/p"
  rows "$X"; tick "control, searchable"; stopped "control: searchable: stopped" "stop e0000043 "
fi

# ================================================================== the own home's setting
# AGENT_HUB_WATCHDOG_REAP in the own config.json: read strictly and afresh, before the tick and before each stop
C1=$(sid e0000050); C2=$(sid e0000051); retire_hub a "$C1" hub-80; retire_hub a "$C2" hub-81; quiet_for "$C1" 30; quiet_for "$C2" 30
echo '{' > "$R/config.json"; rows "$C1" "$C2"; tick "corrupt own config.json"
stopped "the own config.json cannot be read: nothing is stopped" ""; aborted "corrupt own config.json" "$R/config.json"
echo '{"AGENT_HUB_WATCHDOG_REAP": "off"}' > "$R/config.json"; rows "$C1" "$C2"; tick "REAP=off in the own config.json"
stopped "REAP=off in the own config.json: nothing is stopped" ""
echo '{"AGENT_HUB_WATCHDOG_REAP": "on"}' > "$R/config.json"; rows "$C1" "$C2"
printf '#!/bin/sh\n[ "$1" = e0000050 ] && echo %s > "%s/config.json"\nexit 0\n' "'{\"AGENT_HUB_WATCHDOG_REAP\": \"off\"}'" "$R" > "$R/onstop-cfg.sh"
reset_log; FAKE_WD_ON_STOP="sh $R/onstop-cfg.sh \"\$1\"" WD run > "$R/tick.out" 2>&1
stopped "REAP is switched off during the first stop: the second session is not stopped" "stop e0000050 "
echo '{"AGENT_HUB_WATCHDOG_REAP": "on"}' > "$R/config.json"; rows "$C2"; tick "control, REAP on"; stopped "control: REAP on: stopped" "stop e0000051 "
rm -f "$R/config.json"

# ================================================================== homes that cannot be reached
if [ "$(id -u)" != 0 ]; then
  X=$(sid e0000060); retire_hub a "$X" hub-90; quiet_for "$X" 30
  mkdir -p "$R/locked/home"; REG=$XDG_CONFIG_HOME/delamain/homes.json; cp "$REG" "$R/homes.json.bak"
  python3 - "$REG" "$R/locked/home" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["homes"].append({"path": sys.argv[2], "layer": "env"}); json.dump(d, open(sys.argv[1], "w"))
PY
  chmod 000 "$R/locked"
  rows "$X"; tick "registered home behind a closed directory"; stopped "a registered home whose path cannot be looked at: nothing is stopped" ""; aborted "unreachable registered home" "PermissionError"
  chmod 755 "$R/locked"
  rows "$X"; tick "control, reachable home"; stopped "control: the same home reachable and empty: stopped" "stop e0000060 "
  rm -r "$R/locked"
  X=$(sid e0000061); retire_hub a "$X" hub-91; quiet_for "$X" 30
  cp "$R/homes.json.bak" "$REG"; rows "$X"; tick "control, no such home"
  python3 - "$REG" "$R/no-such-home" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["homes"].append({"path": sys.argv[2], "layer": "env"}); json.dump(d, open(sys.argv[1], "w"))
PY
  rows "$X"; tick "registered home that does not exist"; stopped "a registered home that does not exist is no home: stopped" "stop e0000061 "
  cp "$R/homes.json.bak" "$REG"
fi
X=$(sid e0000062); retire_hub a "$X" hub-92; quiet_for "$X" 30
echo '{"homes": [1]}' > "$XDG_CONFIG_HOME/delamain/homes.json"
rows "$X"; tick "registry entry of the wrong shape"; stopped "an entry of the registry of homes of the wrong shape: nothing is stopped" ""; aborted "registry entry of the wrong shape" "not a registry of homes"
cp "$R/homes.json.bak" "$XDG_CONFIG_HOME/delamain/homes.json" 2>/dev/null

exit $fail
