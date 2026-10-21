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


exit $fail
