#!/bin/bash
# Watchdog R7, the false-positive audit: a session that is still needed is never stopped. Each risk has a test that leaves
# the session alone and a control in the same world that shows it IS stopped once the guard has nothing to hold on to.
#   homes:    a live role / a pending successor / a prefix of either in ANOTHER hub home; an unreadable registry, roles.json,
#             auto-handoff.json or config.json of another home, or an unreadable registry of homes: nothing is stopped;
#             AGENT_HUB_WATCHDOG_REAP=off in another home protects the hubs retired there
#   takeover: the sessions named by a running `hub takeover` / `hub start` (marker <stage>/.takeover-<pid>.json): alive,
#             dead pid, older than 6 h, unreadable; and the real command, which runs the watchdog from its own project step
#   activity: a session resumed a minute ago and idle, a transcript dated in the future, a transcript that is not found (kept
#             under another CLAUDE_CONFIG_DIR), a running sub-agent, a session that wrote between the first look and the stop
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
NOW=2026-10-07T12:00:00; export FX_NOW=$NOW AGENT_HUB_WATCHDOG_NOW=$NOW
: > "$R/claude.log"
FX(){ python3 "$T/watchdog_fixture.py" "$@"; }
WD(){ "$B/watchdog" "$@"; }
stops(){ FX claude-calls "$R/claude.log" | grep '^stop ' | sort | tr '\n' ' '; }
reset_log(){ : > "$R/claude.log"; }
CWD=$R/cwd; mkdir -p "$CWD"; export FX_CWD=$CWD
sid(){ printf '%s-0000-4000-8000-000000000000' "$1"; }
LIVE=$$   # a pid that runs
H2=$(mktemp -d)                                   # a second hub home, known to the registry of homes once a role is set in it
RB(){ AGENT_HUB_HOME=$H2 "$B/roles" "$@"; }       # roles of the second home
retire_hub(){ "$B/roles" set --stage "$1" hub "$2" --kind cli --tag "$3" > /dev/null; "$B/roles" retire --stage "$1" hub --note "test" > /dev/null; }
quiet_for(){ FX transcript "$1" "$2" ok; }
# rows "sid[|kind[|started-minutes-ago]]"…: the rows `claude agents --json` prints (kind "-": no kind key; started: no startedAt)
rows(){ python3 - "$FAKE_WD_ROWS" "$LIVE" "$NOW" "$@" <<'PY'
import datetime as d, json, sys
out, live, now, *specs = sys.argv[1:]
t0 = d.datetime.fromisoformat(now).replace(tzinfo=d.timezone.utc)
res = []
for spec in specs:
    p = spec.split("|")
    sid, kind, started = p[0], (p[1] if len(p) > 1 and p[1] else "background"), (p[2] if len(p) > 2 else "")
    r = {"id": sid[:8], "sessionId": sid, "kind": kind, "status": "idle", "state": "done", "pid": int(live), "cwd": "/tmp", "name": "hub"}
    if kind == "-":
        del r["kind"]
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
json.dump({"chain": 1, "pending": {"n": 4, "kind": "bg", "id": sys.argv[2], "at": "2026-10-07T11:55:00", "taken_over": False}}, open(sys.argv[1] + "/auto-handoff.json", "w"))
PY
rows "$X"; tick "pending successor in home B"; stopped "pending successor of a stage of home B: not stopped" ""
python3 - "$H2/y" "${X:0:8}" <<'PY'
import json, sys
json.dump({"chain": 1, "pending": {"n": 4, "kind": "headless", "id": "headless", "bg_id": sys.argv[2], "at": "2026-10-07T11:55:00"}}, open(sys.argv[1] + "/auto-handoff.json", "w"))
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
rows "$X"; tick "broken registry of homes"; stopped "the registry of homes cannot be read (a home may be missing): nothing is stopped" ""; aborted "broken registry of homes" "$REG"
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
# resumed a minute ago and idle: the transcript is old, the process is new
X=$(sid e000000b); retire_hub a "$X" hub-10; quiet_for "$X" 30
rows "$X||2"; tick "resumed 2 min ago"; stopped "started 2 minutes ago (resumed, idle), transcript 30 min old: not stopped" ""
rows "$X||30"; tick "started 30 min ago"; stopped "control: started 30 minutes ago too: stopped" "stop e000000b "
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

exit $fail
