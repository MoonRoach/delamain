#!/bin/bash
# Watchdog R7: the `claude --bg` session of a hub that is retired in its stage and live nowhere is stopped (`claude stop`,
# never removed) once it is idle and has been quiet for the wake-after time. Positive: an idle retired hub quiet 30 min (by
# its transcript and the start of its process, matched by session or cli_session_id). Negatives, each left alone (a busy one
# is reported once a day, not stopped):
# a hub that is live in its stage, a session retired in one stage and live in another, a pending successor (either
# taken_over value), quiet only 5 min, not background, no pid, an unknown age (no transcript), a busy one,
# AGENT_HUB_WATCHDOG_REAP=off, a dry run. The clock of the tick is 40 min ahead of the real one, so the real processes of the
# rows (started when the test did) are 40 min old. The least quiet time is 15 min whatever WAKE_AFTER says.
# tests/t_watchdog_reap_guards.sh has the guards of the cross-home and takeover audit.
# Also: `claude agents --json` failing, a failing `claude stop`, a stage whose registry or auto-handoff.json is broken,
# a session that becomes a live role while the watchdog is stopping others (the registries are read again before each stop). Stand-in CLI only.
. "$(dirname "$0")/lib.sh"
new_home; R=$AGENT_HUB_HOME
export HOME=$R/home; mkdir -p "$HOME"
export CLAUDE_CONFIG_DIR=$R/claude-home CLAUDE_SESSIONS_DIR=$R/desktop
export CLAUDE_BIN=$T/fake_claude_wd.py FAKE_WD_ROWS=$R/rows.json FAKE_WD_LOG=$R/claude.log
export AGENT_HUB_WATCHDOG=on
unset AGENT_HUB_NOTIFY_CMD AGENT_HUB_WATCHDOG_REAP AGENT_HUB_WATCHDOG_WAKE_AFTER FAKE_WD_AGENTS FAKE_WD_STOP
NOW=$(python3 -c 'import datetime as d; print((d.datetime.now(d.timezone.utc) + d.timedelta(minutes=40)).strftime("%Y-%m-%dT%H:%M:%S"))'); export FX_NOW=$NOW AGENT_HUB_WATCHDOG_NOW=$NOW
export AT5=$(python3 -c 'import datetime as d,sys; print((d.datetime.fromisoformat(sys.argv[1]) - d.timedelta(minutes=5)).strftime("%Y-%m-%dT%H:%M:%S"))' "$NOW")   # a pending successor that is 5 min old
FB=$R/fakebin; mkdir -p "$FB"; : > "$R/notify.log"; : > "$R/remote.log"; : > "$R/claude.log"
for n in osascript notify-send; do printf '#!/bin/sh\necho "local: $*" >> "%s"\n' "$R/notify.log" > "$FB/$n"; chmod +x "$FB/$n"; done
printf '#!/bin/sh\necho "remote: $*" >> "%s"\n' "$R/remote.log" > "$FB/remotecmd"; chmod +x "$FB/remotecmd"
export PATH="$FB:$PATH"
FX(){ python3 "$T/watchdog_fixture.py" "$@"; }
WD(){ "$B/watchdog" "$@"; }
J(){ echo "$R/$1/coordinator/work/journal-$(today).md"; }
count(){ local n; n=$(grep -c -- "$1" "$2" 2>/dev/null); echo "${n:-0}"; }
stops(){ FX claude-calls "$R/claude.log" | grep '^stop ' | sort | tr '\n' ' '; }   # the stop calls so far, sorted
reset_log(){ : > "$R/claude.log"; }
CWD=$R/cwd; mkdir -p "$CWD"; export FX_CWD=$CWD
sid(){ printf '%s-0000-4000-8000-000000000000' "$1"; }
# retire_hub STAGE SID TAG: the session is registered as the stage's hub, then retired
retire_hub(){ "$B/roles" set --stage "$1" hub "$2" --kind cli --tag "$3" > /dev/null; "$B/roles" retire --stage "$1" hub --note "test" > /dev/null; }
quiet_for(){ FX transcript "$1" "$2" ok; }                                  # a transcript last written N minutes ago
sleep 3000 > /dev/null 2>&1 < /dev/null & LIVE=$!   # a process that runs, with no children (and no descriptor of the test's): the rows below say their session has it
trap 'kill $LIVE 2>/dev/null; test_cleanup' EXIT

# the sessions of the world (the first 8 characters are the row id)
P1=$(sid a0000001); P2=$(sid a0000002); P3=$(sid a0000003); P4=$(sid a0000004)   # P1, P2, P4 stopped (P4: matched by cli_session_id); P3 busy: reported
NL=$(sid b0000001)   # live hub of stage a (it was retired once before and registered again)
NW=$(sid b0000002)   # retired hub of a, live worker of b
NP=$(sid b0000003); NT=$(sid b0000004)   # pending successor of a (not taken over / taken over)
N5=$(sid b0000005)   # quiet 5 min
NK=$(sid b0000006)   # interactive
NN=$(sid b0000007)   # no pid
NU=$(sid b0000008)   # age unknown
NS=$(sid b0000009)   # no transcript: what it did is unknown, so it is not judged
HUBB=$(sid c0000002)
NA=deadbeef-1111-4000-8000-000000000000; NB=deadbeef-2222-4000-8000-000000000000   # retired hub A; a different session B with A's first 8 characters
NR=$(sid b0000010)   # retired only as a worker role
NX=$(sid b0000011)   # in no registry at all

# registries: stage a (live hub NL), stage b (live hub HUBB, live worker NW)
"$B/roles" set --stage b hub "$HUBB" --kind cli --tag hub-2 > /dev/null
retire_hub a "$P1" hub-1; retire_hub a "$P2" hub-2; retire_hub a "$P3" hub-3
retire_hub a "$NW" hub-4; retire_hub a "$NP" hub-5; retire_hub a "$NT" hub-6; retire_hub a "$N5" hub-7
retire_hub a "$NK" hub-8; retire_hub a "$NN" hub-10; retire_hub a "$NU" hub-11; retire_hub a "$NS" hub-12
retire_hub a "$NA" hub-16
"$B/roles" set --stage a worker "$NR" --kind headless --tag worker > /dev/null; "$B/roles" retire --stage a worker --note "test" > /dev/null
retire_hub a "$NL" hub-13; "$B/roles" set --stage a hub "$NL" --kind cli --tag hub-14 > /dev/null    # NL is live: the stage's hub now
# P4: retired with its own id in `session` and the row's id in cli_session_id only
python3 - "$R/a/roles.json" "$P4" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["retired"].append({"role": "hub", "session": "local_never-a-uuid", "cli_session_id": sys.argv[2], "tag": "hub-15", "retired_at": "2026-10-01T10:00:00"})
json.dump(d, open(p, "w"))
PY
"$B/roles" set --stage b worker "$NW" --kind headless --tag worker > /dev/null
python3 - "$R/a/auto-handoff.json" "${NP:0:8}" "${NT:0:8}" <<'PY'
import json, sys
json.dump({"chain": 1, "pending": {"n": 5, "kind": "bg", "id": sys.argv[2], "at": __import__("os").environ["AT5"], "taken_over": False}}, open(sys.argv[1], "w"))
PY
python3 - "$R/b/auto-handoff.json" "${NT:0:8}" <<'PY'
import json, sys
json.dump({"chain": 1, "pending": {"n": 6, "kind": "bg", "id": sys.argv[2], "at": __import__("os").environ["AT5"], "taken_over": True}}, open(sys.argv[1], "w"))
PY
quiet_for "$P1" 30; quiet_for "$P3" 30; quiet_for "$P4" 30; quiet_for "$NW" 30; quiet_for "$NP" 30; quiet_for "$NT" 30
quiet_for "$NB" 30; quiet_for "$NR" 30; quiet_for "$NX" 30
quiet_for "$N5" 5; quiet_for "$NK" 30; quiet_for "$NN" 30; quiet_for "$NL" 30; quiet_for "$P2" 30
# NS: no transcript; NU: neither a transcript nor a start time
mkrows(){  # all rows: id sessionId kind status pid
  python3 - "$FAKE_WD_ROWS" "$LIVE" "$P1" "$P2" "$P3" "$P4" "$NW" "$NP" "$NT" "$N5" "$NK" "$NN" "$NU" "$NS" "$NL" "$NB" "$NR" "$NX" <<'PY'
import json, sys
out, live, p1, p2, p3, p4, nw, np_, nt, n5, nk, nn, nu, ns, nl, nb, nr, nx = sys.argv[1:]
def row(sid, kind="background", status="idle", pid=int(live)):
    r = {"id": sid[:8], "sessionId": sid, "kind": kind, "status": status, "state": "done", "pid": pid, "cwd": "/tmp", "name": "hub"}
    if pid is None:
        del r["pid"]
    return r
rows = [row(p1), row(p2), row(p3, status="busy"), row(p4), row(nw), row(np_), row(nt), row(n5),
        row(nk, kind="interactive"), row(nn, pid=None), row(nu), row(ns), row(nl), row(nb), row(nr), row(nx)]
json.dump(rows, open(out, "w"))
PY
}
mkrows
tick(){ WD run > "$R/tick.out" 2>&1; echo $?; }
EXPECT="stop a0000001 stop a0000002 stop a0000004 "

# ---- off, and a dry run: nothing is stopped
AGENT_HUB_WATCHDOG_REAP=off WD run > "$R/off.out" 2>&1; check $? 0 "REAP=off: the tick exits 0"
check "$(stops)" "" "REAP=off: nothing is stopped"
WD run --dry-run > "$R/dry.out" 2>&1; check $? 0 "dry run: exits 0"
check "$(stops)" "" "dry run: no stop call"
for id in a0000001 a0000002 a0000004; do
  grep -q "^\[plan\] a: would stop the background session of retired hub-[0-9]* ($id), quiet" "$R/dry.out"; check $? 0 "dry run: a [plan] line for $id"
done
check "$(count 'would stop' "$R/dry.out")" 3 "dry run: …and only for those three"
grep -q "^\[plan\] a: retired hub a0000003 (a) is busy/done for 30 min; stop it by hand: claude stop a0000003" "$R/dry.out"; check $? 0 "dry run: plans the report of the busy one"
check "$(count 'stopped the background' "$(J a)")" 0 "dry run: writes no journal line"

# ---- the real tick
reset_log
check "$(tick)" 0 "tick exits 0"
check "$(stops)" "$EXPECT" "the three idle quiet retired hubs are stopped, and only they (positives and every negative control in one world)"
check "$(count 'stopped the background session of retired hub-1 (a0000001), quiet 30 min' "$(J a)")" 1 "journal: one line with the tag, the id and the quiet minutes (the process is 40 min old, the transcript 30)"
check "$(count 'stopped the background session of retired hub-15 (a0000004)' "$(J a)")" 1 "journal: a hub matched by cli_session_id"
grep -q "a: retired hub a0000003 (a) is busy/done for 30 min; stop it by hand: claude stop a0000003" "$R/tick.out"; check $? 0 "a busy retired hub is not stopped: one report line says how to stop it by hand"
check "$(count 'retired hub a0000003 (a) is busy' "$(J a)")" 1 "…and the stage journal has it too"
check "$(count 'stopped the background' "$(J a)")" 3 "journal: three stop lines in all"
grep -q "remote:\|local:" "$R/notify.log" "$R/remote.log"; check $? 1 "nothing is notified: R7 stays on the machine"
grep -c "claude rm\|\"rm\"" "$R/claude.log" | grep -q '^0$'; check $? 0 "never claude rm"
check "$(FX claude-calls "$R/claude.log" | grep -c '^resume')" 0 "no resume either"
# the fake removes a stopped row, so a second tick has nothing to do; a repeat of the same rows is stopped again only by a new tick
reset_log; check "$(tick)" 0 "second tick exits 0"
check "$(stops)" "" "second tick: nothing left to stop"
check "$(count 'retired hub a0000003 (a) is busy' "$(J a)")" 1 "second tick: the busy one is not reported again the same day"
grep -q "remote:\|local:" "$R/notify.log" "$R/remote.log"; check $? 1 "…and no notification went out for it"

# ---- the same rows listed twice stay one stop; a failing stop is reported and retried
mkrows; reset_log
FAKE_WD_STOP=fail WD run > "$R/fail.out" 2>&1; check $? 0 "a failing claude stop: the tick exits 0"
grep -q "a: stopping the background session of retired hub-1 (a0000001) failed: claude stop exit 1: fake claude: stop failed" "$R/fail.out"; check $? 0 "…and says the exit code and the stderr tail"
check "$(count 'stopped the background' "$(J a)")" 3 "…writes no journal line for it (still the three of the real tick)"
check "$(count 'stop a0000001' <(FX claude-calls "$R/claude.log"))" 1 "…one attempt per tick"
reset_log; check "$(tick)" 0 "the next tick exits 0"
check "$(stops)" "$EXPECT" "…and retries: the three are stopped now"

# ---- `claude agents --json` failing
mkrows; reset_log
FAKE_WD_AGENTS=fail WD run > "$R/agfail.out" 2>&1; check $? 0 "agents --json failing: the tick exits 0"
check "$(stops)" "" "agents --json failing: no stop"
grep -q "Traceback" "$R/agfail.out"; check $? 1 "agents --json failing: no traceback"

# ---- a registry that cannot be read: nobody can tell whether a session is live there, so nothing is stopped
mkrows; reset_log; mkdir -p "$R/sbad"; echo '{' > "$R/sbad/roles.json"
WD run > "$R/bad.out" 2>&1; check $? 0 "a broken registry: the tick exits 0"
check "$(stops)" "" "a broken registry: nothing is stopped"
rm -r "$R/sbad"

# ---- an auto-handoff.json that cannot be read: a pending successor may be hidden in it, so nothing is stopped
mkrows; reset_log; mkdir -p "$R/sc"; "$B/roles" set --stage sc hub "$(sid d0000001)" --kind cli --tag hub-1 > /dev/null
for bad in '{' '[]' '{"pending": 7}' '{"pending":{"kind":"bg","id":7}}' '{"pending":{"kind":"bg","id":""}}'; do
  printf '%s' "$bad" > "$R/sc/auto-handoff.json"; reset_log
  WD run > "$R/corrupt.out" 2>&1; check $? 0 "auto-handoff.json $bad: the tick exits 0"
  check "$(stops)" "" "auto-handoff.json $bad: nothing is stopped"
  grep -q "^\[[0-9 :-]*\] machine: not stopping any retired hub's session this tick: .*auto-handoff.json" "$R/corrupt.out"; check $? 0 "auto-handoff.json $bad: one line says why"
done
rm "$R/sc/auto-handoff.json"; reset_log; mkrows
WD run > "$R/corrupt.out" 2>&1; check "$(stops)" "$EXPECT" "control: the same stage without the corrupt file does not hold R7 back"
rm -r "$R/sc"

# ---- `claude stop` is addressed by the 8-character id: a fresh listing right before it must show one and the same session
NC=deadbeef-3333-4000-8000-000000000000; quiet_for "$NA" 30; quiet_for "$NC" 30
rowsof(){ python3 - "$FAKE_WD_ROWS" "$LIVE" "$@" <<'PY'
import json, sys
out, live, *sids = sys.argv[1:]
json.dump([{"id": x[:8], "sessionId": x, "kind": "background", "status": "idle", "state": "done", "pid": int(live), "cwd": "/tmp", "name": "hub"} for x in sids], open(out, "w"))
PY
}
rowsof "$NA"; reset_log; check "$(tick)" 0 "short id, control: the retired hub A alone is listed, the tick exits 0"
check "$(stops)" "stop deadbeef " "short id, control: A is stopped by its short id"
"$B/roles" set --stage b worker3 "$NB" --kind headless --tag w3 > /dev/null          # B: a live role with A's first 8 characters
rowsof "$NA"; reset_log; check "$(tick)" 0 "short id, protected prefix (B live, not listed): the tick exits 0"
check "$(stops)" "" "short id, protected prefix: B's live role shares A's 8 characters, so A is not stopped by that id"
rowsof "$NA" "$NB"; reset_log; check "$(tick)" 0 "short id, A and B both listed: the tick exits 0"
check "$(stops)" "" "short id, A and B both listed with the id deadbeef: nothing is stopped"
"$B/roles" retire --stage b worker3 --note "test" > /dev/null                         # B is no longer protected
rowsof "$NA" "$NC"; reset_log; check "$(tick)" 0 "short id, two rows share the id: the tick exits 0"
check "$(stops)" "" "short id, two listed sessions share the id deadbeef (C is neither retired nor protected): nothing is stopped"
rowsof "$NA"; reset_log
FAKE_WD_AGENTS_FAIL_FROM=2 WD run > "$R/fresh.out" 2>&1; check $? 0 "a failing fresh listing: the tick exits 0"
check "$(stops)" "" "a failing fresh listing right before the stop: nothing is stopped"
grep -q "a: not stopping retired hub-16 (deadbeef): \`claude agents --json\` failed just before the stop" "$R/fresh.out"; check $? 0 "…and one line says so"
rowsof "$NA"; reset_log; check "$(tick)" 0 "control: with the listing healthy again A is stopped (the tick exits 0)"
check "$(stops)" "stop deadbeef " "control: A is stopped once the fresh listing works"

# ---- a quiet time set by the owner
mkrows; reset_log
AGENT_HUB_WATCHDOG_WAKE_AFTER=45m WD run > "$R/long.out" 2>&1; check $? 0 "WAKE_AFTER=45m: the tick exits 0"
check "$(stops)" "" "WAKE_AFTER=45m: sessions quiet 30 min are left alone"
mkrows; reset_log
AGENT_HUB_WATCHDOG_WAKE_AFTER=3m WD run > "$R/short.out" 2>&1; check $? 0 "WAKE_AFTER=3m: the tick exits 0"
check "$(stops)" "$EXPECT" "WAKE_AFTER=3m: the least quiet time of 15 min holds, the two sessions quiet 5 min are left alone"

# ---- a session that becomes a live role while the watchdog is stopping others: the registries are read again before each stop
mkrows; reset_log
printf '#!/bin/sh\n[ "$1" = a0000001 ] && "%s/roles" set --stage b worker2 "%s" --kind headless --tag w2 > /dev/null\nexit 0\n' "$B" "$P2" > "$R/onstop.sh"
FAKE_WD_ON_STOP="sh $R/onstop.sh \"\$1\"" WD run > "$R/race.out" 2>&1; check $? 0 "race: the tick exits 0"
check "$(stops)" "stop a0000001 stop a0000004 " "race: a0000002 became a live role of stage b during the first stop and is not stopped; the others are"
exit $fail
