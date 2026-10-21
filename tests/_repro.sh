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
#   busy:     a status other than idle/done (busy, blocked, working, waiting, none), ANY live descendant of the process (a shell, a
#             Python or Node child, a `sleep`, at any depth): reported once a day in the job output and the stage journal, never
#             stopped; a child that appears between the first look and the last one; a process table that cannot be read
#             completely (a row that cannot be parsed, `ps` failing): nothing is stopped
#   config:   the own home's config.json read fresh before each stop, and strictly (corrupt, or JSON that is no object: nothing is
#             stopped, also when the environment says on); a REAP value that is not understood, in the environment or the file:
#             off; REAP switched off while the last listing is being made: not stopped
#   json:     `null` (or another wrong type) in roles.json, auto-handoff.json, config.json (own and another home), homes.json: the
#             tick stops nothing; only a MISSING file means "nothing there"
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
REALPS=$(command -v ps)   # a ps that appends $FAKE_PS_EXTRA to its answer, or fails with FAKE_PS_FAIL=1, for the tests of the process table
printf '#!/bin/sh\n[ -n "$FAKE_PS_FAIL" ] && exit 1\n"%s" "$@"; rc=$?\n[ -n "$FAKE_PS_EXTRA" ] && printf "%%s\\n" "$FAKE_PS_EXTRA"\n[ -f "$FAKE_PS_FLAG" ] && cat "$FAKE_PS_FLAG"\nexit $rc\n' "$REALPS" > "$FB/ps"; chmod +x "$FB/ps"
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

# ================================================================== children
# a child of any kind protects the session: a `sleep`, a Python-like process (an MCP server, a long tool call); the control is
# the process with no child, which every other test of this file stops
X=$(sid e0000038); retire_hub a "$X" hub-62; quiet_for "$X" 30
spawn python3 -c 'import subprocess, time; subprocess.Popen(["sleep", "3002"]); time.sleep(3000)'; ROWPID=$SPAWNED; sleep 1
rows "$X"; tick "sleep child"; stopped "the process has a plain child (sleep): not stopped" ""
grep -q "retired hub e0000038 (a) is running a child process (sleep) for 30 min; stop it by hand: claude stop e0000038" "$R/tick.out"; check $? 0 "…and it is reported, once"
X=$(sid e0000039); retire_hub a "$X" hub-63; quiet_for "$X" 30
spawn python3 -c 'import subprocess, time; subprocess.Popen(["python3", "-c", "import time; time.sleep(3000)"]); time.sleep(3000)'; ROWPID=$SPAWNED; sleep 1
rows "$X"; tick "python child"; stopped "the process has a Python child: not stopped" ""
unset ROWPID
# a child that appears between the first look and the last one (the process table is read again right before the stop)
X=$(sid e000003a); retire_hub a "$X" hub-64; quiet_for "$X" 30; rm -f "$R/child.flag"
spawn python3 -c '
import os, subprocess, time
while not os.path.exists(os.environ["CHILD_FLAG"]): time.sleep(0.05)
subprocess.Popen(["sleep", "3003"]); time.sleep(3000)'; ROWPID=$SPAWNED
rows "$X"; reset_log; CHILD_FLAG=$R/child.flag FAKE_WD_ON_AGENTS="2:touch $R/child.flag; sleep 1" WD run > "$R/tick.out" 2>&1
stopped "a child starts between the first listing and the last look: not stopped" ""
unset ROWPID

# ================================================================== process table
# a `ps` row that cannot be parsed, or a `ps` that fails, makes the table unreadable: the child that the row might have been is
# unknown, so nothing is stopped (an empty line is no row)
X=$(sid e0000080); retire_hub a "$X" hub-110; quiet_for "$X" 30
for extra in "4242 1" "4243 1 Xxx Yyy 99 99:99:99 2026 cmd" "abc 1 Mon Oct 12 10:00:00 2026 cmd"; do
  rows "$X"; reset_log; FAKE_PS_EXTRA="$extra" WD run > "$R/tick.out" 2>&1; check $? 0 "ps row '$extra': the tick exits 0"
  stopped "a ps row that cannot be parsed ('$extra'): not stopped" ""
done
rows "$X"; reset_log; FAKE_PS_FAIL=1 WD run > "$R/tick.out" 2>&1; check $? 0 "ps fails: the tick exits 0"; stopped "ps fails: not stopped" ""
rows "$X"; reset_log; FAKE_PS_FLAG=$R/ps.flag FAKE_WD_ON_AGENTS="2:echo garbage > $R/ps.flag" WD run > "$R/tick.out" 2>&1
stopped "the table of the last look has a row that cannot be parsed: not stopped" ""; rm -f "$R/ps.flag"
rows "$X"; reset_log; FAKE_PS_EXTRA=" " WD run > "$R/tick.out" 2>&1; stopped "control: an empty line in the answer of ps is no row: stopped" "stop e0000080 "

# ================================================================== json
# JSON `null` (or another wrong type) is not a missing file: only a missing one says "nothing there"
X=$(sid e0000090); retire_hub a "$X" hub-120; quiet_for "$X" 30
nulltest(){   # LABEL FILE [CONTENT]: the file is there and says null (or CONTENT): nothing is stopped; removed: stopped
  mkdir -p "$(dirname "$2")"; printf '%s' "${3:-null}" > "$2"
  rows "$X"; tick "$1"; stopped "$1: JSON ${3:-null} is not an absent file: nothing is stopped" ""; aborted "$1" "$2"
  rm -f "$2"; rows "$X"; tick "control, $1 removed"; stopped "control: $1 removed: stopped" "stop e0000090 "
}
mkdir -p "$R/nz" "$H2/z"
nulltest "own roles.json" "$R/nz/roles.json"
nulltest "own auto-handoff.json" "$R/nz/auto-handoff.json"
nulltest "own config.json" "$R/config.json"
nulltest "own config.json holding a list" "$R/config.json" '[]'
nulltest "roles.json of home B" "$H2/z/roles.json"
nulltest "auto-handoff.json of home B" "$H2/z/auto-handoff.json"
nulltest "config.json of home B" "$H2/config.json"
REG=$XDG_CONFIG_HOME/delamain/homes.json; cp "$REG" "$R/homes.json.bak"
nulltest "registry of homes" "$REG"
cp "$R/homes.json.bak" "$REG"; rm -rf "$R/nz" "$H2/z"

# ================================================================== setting
# AGENT_HUB_WATCHDOG_REAP: the config.json is read (and must be sound) even when the environment says on; a value that is not
# understood, in the environment or the file, is off; REAP switched off during the last listing is seen
X=$(sid e00000a3); retire_hub a "$X" hub-130; quiet_for "$X" 30
envtick(){ rows "$X"; reset_log; AGENT_HUB_WATCHDOG_REAP=$2 WD run > "$R/tick.out" 2>&1; check $? 0 "$1: the tick exits 0"; }
echo '{' > "$R/config.json"; envtick "corrupt config.json, REAP=on in the environment" on
stopped "a corrupt config.json stops everything even when the environment says on" ""; aborted "corrupt config.json, REAP=on" "$R/config.json"
echo 'null' > "$R/config.json"; envtick "config.json null, REAP=on in the environment" on
stopped "config.json holding null, REAP=on in the environment: nothing is stopped" ""; aborted "config.json null, REAP=on" "$R/config.json"
rm -f "$R/config.json"
envtick "REAP=banana" banana; stopped "REAP=banana in the environment (not understood): nothing is stopped" ""
envtick "REAP=2" 2; stopped "REAP=2 in the environment (not understood): nothing is stopped" ""
echo '{"AGENT_HUB_WATCHDOG_REAP": "banana"}' > "$R/config.json"; rows "$X"; tick "REAP=banana in the file"
stopped "REAP=banana in the own config.json (not understood): nothing is stopped" ""
echo '{"AGENT_HUB_WATCHDOG_REAP": ["on"]}' > "$R/config.json"; rows "$X"; tick "REAP a list in the file"
stopped "REAP holding a list in the own config.json (not understood): nothing is stopped" ""
echo '{"AGENT_HUB_WATCHDOG_REAP": 0}' > "$R/config.json"; rows "$X"; tick "REAP=0 in the file"
stopped "REAP=0 (a JSON number) in the own config.json: nothing is stopped" ""
echo '{"AGENT_HUB_WATCHDOG_REAP": "off"}' > "$R/config.json"; envtick "REAP=on in the environment over off in the file" on
stopped "control: the environment is the stronger of the two: REAP=on stops" "stop e00000a3 "
rm -f "$R/config.json"
echo '{"AGENT_HUB_WATCHDOG_REAP": null}' > "$R/config.json"; rows "$X"; tick "REAP null in the file"
stopped "control: REAP null (not set) in the file is the default, on: stopped" "stop e00000a3 "
rm -f "$R/config.json"
printf '#!/bin/sh\necho %s > "%s/config.json"\n' "'{\"AGENT_HUB_WATCHDOG_REAP\": \"off\"}'" "$R" > "$R/cfg-off.sh"
rows "$X"; reset_log; FAKE_WD_ON_AGENTS="2:sh $R/cfg-off.sh" WD run > "$R/tick.out" 2>&1
stopped "REAP is switched off while the last listing is being made: not stopped" ""
rm -f "$R/config.json"; rows "$X"; tick "control, REAP stays on"; stopped "control: REAP stays on: stopped" "stop e00000a3 "

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


exit $fail
