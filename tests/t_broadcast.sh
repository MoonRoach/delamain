#!/bin/bash
# broadcast: one line to the hub of every open stage of every known home, through tell; the caller's own hub, closed
# and excluded stages left out; one signature for all (registry tag qualified with its stage, else owner); --this-home,
# --dry-run, --json, a failing recipient, usage. Also tell --no-address.
. "$(dirname "$0")/lib.sh"
new_home; A=$AGENT_HUB_HOME
H2=$HOME/agent-hub; mkdir -p $H2   # ~/agent-hub of the throw-away HOME: a second known home
export CLAUDE_BIN=$T/fake_claude_bg.py FAKE_BG_LOG=$A/bg.log FAKE_AGENTS=none   # never the real `claude agents`
ME=bbbbbbbb-2222-4222-8222-222222222222
$B/roles --stage bc-core set hub aaaaaaaa-1111-4111-8111-111111111111 --kind cli --tag hub-30 --title "Hub bc-core #30" >/dev/null
$B/roles --stage bc-dolya set hub $ME --kind cli --tag hub-4 >/dev/null
$B/roles --stage bc-web set hub cccccccc-3333-4333-8333-333333333333 --kind cli --tag hub-2 >/dev/null
$B/roles --stage bc-closed set hub dddddddd-4444-4444-8444-444444444444 --kind cli --tag hub-1 >/dev/null
mkdir -p $A/bc-noone; $B/roles --stage bc-noone set qa eeeeeeee-5555-4555-8555-555555555555 --kind cli >/dev/null
AGENT_HUB_HOME=$H2 $B/roles --stage bc-far set hub ffffffff-6666-4666-8666-666666666666 --kind cli --tag hub-7 >/dev/null
python3 - $A/bc-closed/stage.json <<'PY'
import json, sys
json.dump({"closed": {"at": "2026-10-26T10:00:00", "why": "done", "by": "owner", "hub": "hub-1"}}, open(sys.argv[1], "w"))
PY
JC=$(journal bc-core); JD=$(journal bc-dolya); JW=$(journal bc-web); JX=$(journal bc-closed)
JF="$H2/bc-far/coordinator/work/journal-$(today).md"
bc(){ CLAUDE_CODE_SESSION_ID=$ME $B/broadcast "$@"; }

# 1. a hub broadcasts: every other open stage of both homes, signed with its stage-qualified tag, never its own
bc "release 1.0.20 is out" > $A/o1.txt 2>&1; check $? 0 "broadcast exits 0"
for j in $JC $JW $JF; do
  grep -q '^- [0-9:]* \[bc-dolya-hub-4\] @hub release 1.0.20 is out$' $j; check $? 0 "line in $(basename $(dirname $(dirname $(dirname $j))))'s journal, signed bc-dolya-hub-4"
done
[ ! -e $JD ] || ! grep -q 'release 1.0.20' $JD; check $? 0 "negative: not written to the caller's own hub"
[ ! -e $JX ] || ! grep -q 'release 1.0.20' $JX; check $? 0 "negative: not written to a closed stage"
[ ! -e $(journal bc-noone) ]; check $? 0 "negative: a stage without a hub gets nothing"
grep -q '^skip bc-dolya .*(your own)' $A/o1.txt && grep -q '^skip bc-closed .*(closed)' $A/o1.txt; check $? 0 "the summary names the skipped stages and why"
grep -q 'sent 3, failed 0, skipped 2' $A/o1.txt; check $? 0 "…and counts: 3 sent, 2 skipped"
grep -q "bc-far ($H2)" $A/o1.txt; check $? 0 "with two homes each line names the home"
grep -q 'direct address' $A/o1.txt; check $? 1 "negative: no direct address is printed (tell --no-address)"
# 2. --urgent / --question pass through; --exclude; --include-self
bc --urgent --exclude bc-web "stop merging" > $A/o2.txt 2>&1; check $? 0 "--urgent --exclude exits 0"
grep -q '\[bc-dolya-hub-4\] @hub URGENT stop merging$' $JC; check $? 0 "--urgent: @hub URGENT …"
grep -q 'stop merging' $JW; check $? 1 "negative: --exclude bc-web left it out"
bc --question --include-self --this-home "who holds main-merge?" > $A/o3.txt 2>&1; check $? 0 "--include-self --this-home exits 0"
grep -q '@hub QUESTION who holds main-merge?$' $JD; check $? 0 "--include-self: the caller's own hub gets it too"
grep -q 'who holds main-merge' $JF; check $? 1 "negative: --this-home left the second home out"
# 3. no registration and no HUB_TAG: signed owner
env -u CLAUDE_CODE_SESSION_ID $B/broadcast --this-home "owner here" > $A/o4.txt 2>&1; check $? 0 "an unregistered caller exits 0"
grep -q '\[owner\] @hub owner here$' $JC && grep -q '\[owner\] @hub owner here$' $JD; check $? 0 "…signed [owner], to every hub of the home"
HUB_TAG=hub-30 HUB_STAGE=bc-core $B/broadcast --this-home "from env" > $A/o5.txt 2>&1; check $? 0 "HUB_TAG + HUB_STAGE exits 0"
grep -q '\[bc-core-hub-30\] @hub from env$' $JW; check $? 0 "…signed with the qualified env tag"
# 4. --dry-run and --json write nothing
before=$(cat $JC $JW $JF | wc -l)
bc --dry-run "nothing" > $A/o6.txt 2>&1; check $? 0 "--dry-run exits 0"
check "$(cat $JC $JW $JF | wc -l)" "$before" "--dry-run writes nothing"
grep -q 'would send 3' $A/o6.txt && grep -q '^plan bc-core' $A/o6.txt; check $? 0 "--dry-run lists the recipients"
bc --dry-run --json > $A/o7.json 2>&1; check $? 0 "--dry-run --json without text exits 0"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["tag"]=="bc-dolya-hub-4" and sorted(r["stage"] for r in d["sent"])==["bc-core","bc-far","bc-web"] and {s["why"] for s in d["skipped"]}=={"closed","your own"} else 1)' $A/o7.json
check $? 0 "--json: tag, recipients and skipped with reasons"
# 5. a recipient that fails: exit 1, the others still get it, the failure is shown
$B/roles --stage bc-web set hub cccccccc-3333-4333-8333-333333333333 --kind headless --tag hub-2 >/dev/null   # headless, no agent dir: agent send fails
bc --this-home "partial" > $A/o8.txt 2>&1; check $? 1 "one failed recipient → exit 1"
grep -q '@hub partial$' $JC; check $? 0 "…the other stages still got the line"
grep -q '^FAIL bc-web' $A/o8.txt && grep -q 'failed 1' $A/o8.txt; check $? 0 "…and the failure is named"
# 6. usage and no recipient
bc > $A/o9.txt 2>&1; check $? 2 "no text → exit 2"
bc --urgent --question "x" > $A/o10.txt 2>&1; check $? 2 "--urgent with --question → exit 2"
bc --role nobody "x" > $A/o11.txt 2>&1; check $? 1 "no stage has the role → exit 1"
grep -q "no stage has a live 'nobody'" $A/o11.txt; check $? 0 "…saying so"
bc --this-home -- "-x dash" > $A/o12.txt 2>&1; grep -q '@hub -x dash$' $JC; check $? 0 "text with a dash after --"
# 7. tell --no-address
HUB_STAGE=bc-dolya CLAUDE_CODE_SESSION_ID=$ME $B/tell bc-core --no-address "quiet" > $A/t1.txt 2>&1; check $? 0 "tell --no-address exits 0"
grep -q 'direct address' $A/t1.txt; check $? 1 "…prints no address"
grep -q '@hub quiet$' $JC; check $? 0 "…and writes the line"
HUB_STAGE=bc-dolya CLAUDE_CODE_SESSION_ID=$ME $B/tell bc-core --address --no-address > $A/t2.txt 2>&1; check $? 2 "tell --address --no-address → exit 2"
python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import hubcore as hc; sys.exit(0 if "broadcast" in hc.plugin_tools() else 1)' $B; check $? 0 "plugin_tools() lists broadcast"
# 8. a tell that hangs: stopped with its children after the timeout, reported unknown; the child never delivers late
FB=$A/fakebin; mkdir -p $FB; LATE=$A/late.txt
cat > $FB/tell <<EOF
import subprocess, time   # broadcast runs tell with python: a child that would deliver late, then a hang
subprocess.Popen(["sh", "-c", "sleep 3; echo late > $LATE"])
time.sleep(30)
EOF
chmod +x $FB/tell
python3 - $B $FB > $A/o13.txt 2>&1 <<'PY2'
import importlib.machinery, importlib.util, pathlib, sys
loader = importlib.machinery.SourceFileLoader("broadcast_mod", sys.argv[1] + "/broadcast")
mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("broadcast_mod", loader)); loader.exec_module(mod)
mod.hc.BIN = pathlib.Path(sys.argv[2]); mod.TELL_TIMEOUT_S = 1
r = mod.deliver({"home": "/nonexistent", "stage": "x"}, ["--", "hi"], "owner")
print(r["state"], r["exit"])
PY2
grep -q '^unknown 1$' $A/o13.txt; check $? 0 "a hanging tell → state unknown, exit 1"
sleep 4; [ ! -e $LATE ]; check $? 0 "…and its child was stopped with it (nothing delivered after the report)"
# 9. a silent hub is named before the summary (also in --dry-run): lines addressed to it (this very broadcast, `[owner] @hub`)
# are not its activity; its own journal line or its session's transcript is; --silent-hours moves the threshold, 0 turns it off
export CLAUDE_CONFIG_DIR=$A/claude
WEB_SID=cccccccc-3333-4333-8333-333333333333
ago_line(){ python3 - "$1" "$2" "$3" "$4" <<'PY3'
import datetime as dt, sys   # ago_line STAGE HOURS TAG TEXT: a journal line written HOURS ago, in the journal of that day
home, hours, tag, text = sys.argv[1:5]
t = dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=float(hours))
path = f"{home}/coordinator/work/journal-{t.date()}.md"
import os; os.makedirs(os.path.dirname(path), exist_ok=True)
open(path, "a").write(f"- {t:%H:%M} [{tag}] {text}\n")
PY3
}
touch_ago(){ python3 -c 'import os,sys,time; os.makedirs(os.path.dirname(sys.argv[1]), exist_ok=True); open(sys.argv[1], "a").close(); t = time.time() - float(sys.argv[2]) * 3600; os.utime(sys.argv[1], (t, t))' "$1" "$2"; }
bc --this-home --dry-run "who is alive?" > $A/s1.txt 2>&1; check $? 0 "silent: --dry-run exits 0"
grep -q '^warn 2 of 2 @hub have not written for over 12 h' $A/s1.txt; check $? 0 "…hubs with only addressed lines (the broadcasts above, no line of their own) are silent"
grep -A3 '^warn' $A/s1.txt | grep -q 'bc-core .*no sign of life'; check $? 0 "…and the line names the stage and that no sign of life was found"
# bc-core's hub wrote 20 h ago; a line to it a minute ago does not make it alive (the failing case of the issue)
ago_line $A/bc-core 20 hub-30 "last words before the pause"
bc --this-home --dry-run "who is alive?" > $A/s2.txt 2>&1
grep -A3 '^warn' $A/s2.txt | grep -q 'bc-core .* 20 h$'; check $? 0 "own line 20 h ago + fresh lines addressed to it: silent for 20 h"
bc --this-home --dry-run --silent-hours 24 "who is alive?" > $A/s3.txt 2>&1
grep -A3 '^warn' $A/s3.txt | grep -q 'bc-core'; check $? 1 "negative: with --silent-hours 24 the 20-hour hub is not named"
# a transcript write of the session is a sign of life too (bc-web: 30 h ago -> still silent at 24, alive at 48)
touch_ago $A/claude/projects/p/$WEB_SID.jsonl 30
bc --this-home --dry-run --silent-hours 24 "who is alive?" > $A/s4.txt 2>&1
grep -A3 '^warn' $A/s4.txt | grep -q 'bc-web .* 30 h$'; check $? 0 "transcript written 30 h ago: bc-web is silent for 30 h (the journal has none of its lines)"
grep -q '^warn 1 of 2 ' $A/s4.txt; check $? 0 "…and it is the only one at 24 h"
bc --this-home --dry-run --silent-hours 48 "who is alive?" > $A/s5.txt 2>&1
grep -q '^warn' $A/s5.txt; check $? 1 "negative: --silent-hours 48 names nobody"
touch_ago $A/claude/projects/p/$WEB_SID.jsonl 0.01
ago_line $A/bc-core 0.05 hub-30 "back"
bc --this-home --dry-run "who is alive?" > $A/s6.txt 2>&1
grep -q '^warn' $A/s6.txt; check $? 1 "negative: a fresh transcript and a fresh own line — nobody is silent"
bc --this-home --dry-run --silent-hours 0 "x" > $A/s7.txt 2>&1; check $? 0 "--silent-hours 0 exits 0"
bc --this-home --dry-run --silent-hours 0 --json "x" > $A/s8.json 2>&1
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["silent_hours"]==0 and not any(r["silent"] for r in d["sent"]) else 1)' $A/s8.json; check $? 0 "--silent-hours 0: nobody is flagged"
ago_line $A/bc-core 40 hub-30 "x"   # older than the line of a minute ago: the newest own line decides
touch_ago $A/claude/projects/p/$WEB_SID.jsonl 50
bc --this-home --dry-run --json --silent-hours 36 "x" > $A/s9.json 2>&1
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); r={x["stage"]: x for x in d["sent"]}; sys.exit(0 if d["silent_hours"]==36 and r["bc-web"]["silent"] and 49*3600 <= r["bc-web"]["last_written_age_s"] <= 51*3600 and not r["bc-core"]["silent"] and r["bc-core"]["last_written_age_s"] < 600 else 1)' $A/s9.json
check $? 0 "--json: last_written_age_s and silent per recipient"
bc --silent-hours -1 "x" > $A/s10.txt 2>&1; check $? 2 "--silent-hours -1 → exit 2"
exit $fail
